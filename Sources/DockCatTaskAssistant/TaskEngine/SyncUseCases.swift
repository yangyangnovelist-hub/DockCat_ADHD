import Foundation

@MainActor
final class SyncUseCases {
    struct State {
        var snapshot: AppSnapshot
        var priorityPromptTaskID: UUID?
    }

    private let getState: () -> State
    private let mutateState: (@escaping (inout State) -> Void) -> Void
    private let persist: (String, String) -> Void
    private let mirrorImportedItemsBridge: ([ImportDraftItem]) async -> Void

    init(
        getState: @escaping () -> State,
        mutateState: @escaping (@escaping (inout State) -> Void) -> Void,
        persist: @escaping (String, String) -> Void,
        mirrorImportedItemsBridge: @escaping ([ImportDraftItem]) async -> Void
    ) {
        self.getState = getState
        self.mutateState = mutateState
        self.persist = persist
        self.mirrorImportedItemsBridge = mirrorImportedItemsBridge
    }

    func mirrorImportedItems(_ items: [ImportDraftItem]) async {
        await mirrorImportedItemsBridge(items)
    }

    func updateMindMapDocument(
        dataJSON: String? = nil,
        configJSON: String? = nil,
        localConfigJSON: String? = nil,
        language: String? = nil
    ) {
        var didChange = false

        if let dataJSON {
            didChange = applyMindMapDataChange(dataJSON) || didChange
        }
        if let configJSON {
            mutateState { state in
                if state.snapshot.mindMapDocument.configJSON != configJSON {
                    state.snapshot.mindMapDocument.configJSON = configJSON
                    didChange = true
                }
            }
        }
        if let localConfigJSON {
            mutateState { state in
                if state.snapshot.mindMapDocument.localConfigJSON != localConfigJSON {
                    state.snapshot.mindMapDocument.localConfigJSON = localConfigJSON
                    didChange = true
                }
            }
        }
        if let language {
            mutateState { state in
                if state.snapshot.mindMapDocument.language != language {
                    state.snapshot.mindMapDocument.language = language
                    didChange = true
                }
            }
        }

        guard didChange else { return }

        let timestamp = Date()
        mutateState { state in
            state.snapshot.mindMapDocument.updatedAt = timestamp
        }
        persist("mind_map.updated", timestamp.ISO8601Format())
    }

    func reconcileMindMapAndTasksOnRestore() -> Bool {
        let state = getState()
        let snapshot = state.snapshot

        guard !snapshot.tasks.isEmpty else {
            return synchronizeMindMapFromTasks(force: true)
        }

        let visibleTasks = snapshot.tasks.filter { $0.status != .archived }
        if !visibleTasks.isEmpty,
           MindMapTaskSynchronizer.isEffectivelyEmpty(snapshot.mindMapDocument.dataJSON) {
            return synchronizeMindMapFromTasks(force: true)
        }

        let latestTaskUpdate = snapshot.tasks.map(\.updatedAt).max() ?? .distantPast
        if snapshot.mindMapDocument.dataJSON == AppSnapshot.empty.mindMapDocument.dataJSON {
            return synchronizeMindMapFromTasks(force: true)
        }

        if snapshot.mindMapDocument.updatedAt >= latestTaskUpdate {
            let didChange = applyMindMapDataChange(snapshot.mindMapDocument.dataJSON)
            if didChange {
                mutateState { state in
                    state.snapshot.mindMapDocument.updatedAt = max(state.snapshot.mindMapDocument.updatedAt, Date())
                }
            }
            return didChange
        }

        return synchronizeMindMapFromTasks(force: true)
    }

    @discardableResult
    func synchronizeMindMapFromTasks(force: Bool = false) -> Bool {
        let state = getState()
        let nextDataJSON = MindMapTaskSynchronizer.makeMindMapDataJSON(
            from: state.snapshot.tasks,
            existingDataJSON: state.snapshot.mindMapDocument.dataJSON
        )
        guard force || state.snapshot.mindMapDocument.dataJSON != nextDataJSON else { return false }

        mutateState { state in
            state.snapshot.mindMapDocument.dataJSON = nextDataJSON
            state.snapshot.mindMapDocument.updatedAt = Date()
        }
        return true
    }

    @discardableResult
    private func applyMindMapDataChange(_ dataJSON: String) -> Bool {
        let state = getState()
        guard let syncResult = MindMapTaskSynchronizer.syncTasks(from: dataJSON, existingTasks: state.snapshot.tasks) else {
            guard state.snapshot.mindMapDocument.dataJSON != dataJSON else { return false }
            mutateState { state in
                state.snapshot.mindMapDocument.dataJSON = dataJSON
            }
            return true
        }

        var didChange = false
        mutateState { state in
            if state.snapshot.tasks != syncResult.tasks {
                state.snapshot.tasks = syncResult.tasks
                didChange = true
            }
            if state.snapshot.mindMapDocument.dataJSON != syncResult.normalizedDataJSON {
                state.snapshot.mindMapDocument.dataJSON = syncResult.normalizedDataJSON
                didChange = true
            }

            guard didChange else { return }

            self.normalizeSelectedTaskAfterMindMapSync(in: &state.snapshot)
            self.pruneBackgroundTasksAfterMindMapSync(in: &state.snapshot)
            self.stopSessionsForArchivedTasksAfterMindMapSync(in: &state.snapshot)

            if let firstNewTaskID = syncResult.newTaskIDs.first {
                state.priorityPromptTaskID = firstNewTaskID
                state.snapshot.selectedTaskID = firstNewTaskID
            }
        }

        return didChange
    }

    private func normalizeSelectedTaskAfterMindMapSync(in snapshot: inout AppSnapshot) {
        let visibleTasks = snapshot.tasks.filter { $0.status != .archived }
        let visibleTaskIDs = Set(visibleTasks.map(\.id))
        let fallbackSelectedTaskID = visibleTasks.sorted { lhs, rhs in
            if (lhs.parentTaskID == nil) != (rhs.parentTaskID == nil) {
                return lhs.parentTaskID == nil
            }
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            return lhs.createdAt < rhs.createdAt
        }.first?.id

        let selectedTaskID = snapshot.selectedTaskID.flatMap { visibleTaskIDs.contains($0) ? $0 : nil }
            ?? fallbackSelectedTaskID

        snapshot.selectedTaskID = selectedTaskID
        snapshot.tasks = snapshot.tasks.map { task in
            var updated = task
            updated.isCurrent = task.id == selectedTaskID
            return updated
        }
    }

    private func pruneBackgroundTasksAfterMindMapSync(in snapshot: inout AppSnapshot) {
        let validTaskIDs = Set(snapshot.tasks.filter { $0.status != .archived }.map(\.id.uuidString))
        snapshot.preferences.backgroundTaskIDs = snapshot.preferences.backgroundTaskIDs.filter { validTaskIDs.contains($0) }
    }

    private func stopSessionsForArchivedTasksAfterMindMapSync(in snapshot: inout AppSnapshot) {
        let now = Date()
        let archivedTaskIDs = Set(snapshot.tasks.filter { $0.status == .archived }.map(\.id))
        guard !archivedTaskIDs.isEmpty else { return }

        snapshot.sessions = snapshot.sessions.map { session in
            guard archivedTaskIDs.contains(session.taskID),
                  session.endedAt == nil else {
                return session
            }
            var updated = session
            updated.state = .paused
            updated.endedAt = now
            updated.totalSeconds = TaskService.liveSeconds(for: session, now: now)
            return updated
        }
    }
}
