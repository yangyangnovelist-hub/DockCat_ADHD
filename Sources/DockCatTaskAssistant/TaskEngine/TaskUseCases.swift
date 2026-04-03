import Foundation

@MainActor
final class TaskUseCases {
    struct State {
        var snapshot: AppSnapshot
        var priorityPromptTaskID: UUID?
    }

    private let getState: () -> State
    private let mutateState: (@escaping (inout State) -> Void) -> Void
    private let synchronizeMindMapFromTasks: (Bool) -> Bool
    private let persist: (String, String) -> Void
    private let refreshPetState: () -> Void

    init(
        getState: @escaping () -> State,
        mutateState: @escaping (@escaping (inout State) -> Void) -> Void,
        synchronizeMindMapFromTasks: @escaping (Bool) -> Bool,
        persist: @escaping (String, String) -> Void,
        refreshPetState: @escaping () -> Void
    ) {
        self.getState = getState
        self.mutateState = mutateState
        self.synchronizeMindMapFromTasks = synchronizeMindMapFromTasks
        self.persist = persist
        self.refreshPetState = refreshPetState
    }

    func bootstrapIfNeeded() {
        let state = getState()
        guard state.snapshot.tasks.isEmpty else { return }

        mutateState { state in
            if state.snapshot.preferences.lowDistractionMode == false {
                state.snapshot.preferences.lowDistractionMode = true
            }
        }

        let seedTasks: [(title: String, urgency: Double, importance: Double)] = [
            ("今天回客户定价邮件", 92, 88),
            ("这周整理官网 FAQ", 58, 76),
            ("补充下一版灵感池", 28, 34),
        ]

        for (index, seed) in seedTasks.enumerated() {
            guard let taskID = addTask(title: seed.title) else { continue }
            applyPrioritySelection(for: taskID, urgencyValue: seed.urgency, importanceValue: seed.importance)
            if index == 0 {
                setCurrentTask(id: taskID)
            }
        }

        _ = synchronizeMindMapFromTasks(true)
    }

    @discardableResult
    func addTask(
        title: String,
        notes: String? = nil,
        parentTaskID: UUID? = nil,
        promptForPriority: Bool = false
    ) -> UUID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let now = Date()
        let suggestedUrgency = QuadrantAdvisor.urgencyScore(for: trimmed)
        let suggestedImportance = QuadrantAdvisor.importanceScore(for: trimmed)
        let urgency = promptForPriority ? 0 : suggestedUrgency
        let importance = promptForPriority ? 0 : suggestedImportance
        let urgencyValue = promptForPriority ? 50.0 : PriorityVector.value(from: suggestedUrgency)
        let importanceValue = promptForPriority ? 50.0 : PriorityVector.value(from: suggestedImportance)
        let smartEntries = SmartEvaluator.seededEntries(title: trimmed, notes: notes)
        let smart = SmartEvaluator.evaluate(title: trimmed, notes: notes, smartEntries: smartEntries)

        var createdTaskID: UUID?
        mutateState { state in
            let task = Task(
                id: UUID(),
                projectID: nil,
                parentTaskID: parentTaskID,
                sortIndex: self.nextSortIndex(for: parentTaskID, in: state.snapshot),
                title: trimmed,
                notes: notes,
                status: .todo,
                priority: promptForPriority
                    ? 0
                    : PriorityVector.derivedPriority(
                        urgencyValue: urgencyValue,
                        importanceValue: importanceValue
                    ),
                urgencyScore: urgency,
                importanceScore: importance,
                urgencyValue: urgencyValue,
                importanceValue: importanceValue,
                quadrant: promptForPriority
                    ? nil
                    : PriorityVector.quadrant(
                        urgencyValue: urgencyValue,
                        importanceValue: importanceValue
                    ),
                estimatedMinutes: nil,
                dueAt: nil,
                smartSpecificMissing: smart.specificMissing,
                smartMeasurableMissing: smart.measurableMissing,
                smartActionableMissing: smart.actionableMissing,
                smartRelevantMissing: smart.relevantMissing,
                smartBoundedMissing: smart.boundedMissing,
                smartEntries: smartEntries,
                tags: [],
                isCurrent: state.snapshot.selectedTaskID == nil,
                createdAt: now,
                updatedAt: now,
                completedAt: nil
            )

            state.snapshot.tasks.append(task)
            if state.snapshot.selectedTaskID == nil {
                state.snapshot.selectedTaskID = task.id
            }
            if promptForPriority {
                state.priorityPromptTaskID = task.id
            }
            createdTaskID = task.id
        }

        _ = synchronizeMindMapFromTasks(false)
        persist("task.created", trimmed)
        refreshPetState()
        return createdTaskID
    }

    func setCurrentTask(id: UUID) {
        let state = getState()
        let previousTaskID = state.snapshot.selectedTaskID
            ?? state.snapshot.tasks.first(where: \.isCurrent)?.id
        if previousTaskID != id {
            pauseLeavingTaskIfNeeded(previousTaskID)
        }

        mutateState { state in
            state.snapshot.selectedTaskID = id
            state.snapshot.tasks = state.snapshot.tasks.map { task in
                var updated = task
                let newIsCurrent = updated.id == id
                let isCurrentChanged = updated.isCurrent != newIsCurrent
                let statusChanged = updated.id == id && updated.status == .done
                updated.isCurrent = newIsCurrent
                if statusChanged {
                    updated.status = .todo
                }
                if isCurrentChanged || statusChanged {
                    updated.touch()
                }
                return updated
            }
        }

        persist("task.selected", id.uuidString)
        refreshPetState()
    }

    @discardableResult
    func addChildTask(parentID: UUID, promptForPriority: Bool = false) -> UUID? {
        addTask(
            title: "新的子任务",
            notes: nil,
            parentTaskID: parentID,
            promptForPriority: promptForPriority
        )
    }

    func renameTask(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        mutateState { state in
            self.mutateTask(in: &state.snapshot, id: id) { task in
                task.title = trimmed
                task.touch()
            }
        }

        _ = synchronizeMindMapFromTasks(false)
        persist("task.renamed", id.uuidString)
        refreshPetState()
    }

    func indentTask(id: UUID) {
        let state = getState()
        let orderedTasks = TaskService.sortedTasks(in: state.snapshot)
        guard let currentIndex = orderedTasks.firstIndex(where: { $0.id == id }), currentIndex > 0 else { return }

        let candidateParent = orderedTasks[currentIndex - 1]
        mutateState { state in
            let nextIndex = self.nextSortIndex(for: candidateParent.id, excluding: id, in: state.snapshot)
            self.mutateTask(in: &state.snapshot, id: id) { task in
                task.parentTaskID = candidateParent.id
                task.sortIndex = nextIndex
                task.touch()
            }
        }

        _ = synchronizeMindMapFromTasks(false)
        persist("task.indented", id.uuidString)
        refreshPetState()
    }

    func outdentTask(id: UUID) {
        let state = getState()
        guard let currentTask = self.task(id: id, in: state.snapshot),
              let parentID = currentTask.parentTaskID,
              let parent = self.task(id: parentID, in: state.snapshot) else {
            return
        }

        mutateState { state in
            let nextIndex = self.nextSortIndex(for: parent.parentTaskID, excluding: id, in: state.snapshot)
            self.mutateTask(in: &state.snapshot, id: id) { mutableTask in
                mutableTask.parentTaskID = parent.parentTaskID
                mutableTask.sortIndex = nextIndex
                mutableTask.touch()
            }
        }

        _ = synchronizeMindMapFromTasks(false)
        persist("task.outdented", id.uuidString)
        refreshPetState()
    }

    func archiveTask(id: UUID) {
        mutateState { state in
            self.mutateTask(in: &state.snapshot, id: id) { task in
                task.status = .archived
                task.isCurrent = false
                task.touch()
            }
            self.clearBackgroundTask(id, in: &state.snapshot)
            if state.snapshot.selectedTaskID == id {
                let fallbackTaskID = TaskService.sortedTasks(in: state.snapshot)
                    .first(where: { $0.status != .archived && $0.id != id })?
                    .id
                state.snapshot.selectedTaskID = fallbackTaskID
            }
        }

        _ = synchronizeMindMapFromTasks(false)
        persist("task.archived", id.uuidString)
        refreshPetState()
    }

    func applyTaskDraft(_ draft: TaskSnapshotDraft, to taskID: UUID) {
        let normalizedUrgencyValue = PriorityVector.clampedPercentage(draft.urgencyValue)
        let normalizedImportanceValue = PriorityVector.clampedPercentage(draft.importanceValue)
        let normalizedUrgency = draft.quadrant == nil ? 0 : PriorityVector.score(from: normalizedUrgencyValue)
        let normalizedImportance = draft.quadrant == nil ? 0 : PriorityVector.score(from: normalizedImportanceValue)
        let smartEntries = draft.smartEntries.mergedWithDefaults()
        let tags = draft.tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        mutateState { state in
            self.mutateTask(in: &state.snapshot, id: taskID) { task in
                task.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                task.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                task.status = draft.status
                task.priority = draft.quadrant == nil
                    ? 0
                    : PriorityVector.derivedPriority(
                        urgencyValue: normalizedUrgencyValue,
                        importanceValue: normalizedImportanceValue
                    )
                task.urgencyScore = normalizedUrgency
                task.importanceScore = normalizedImportance
                task.urgencyValue = normalizedUrgencyValue
                task.importanceValue = normalizedImportanceValue
                task.quadrant = draft.quadrant
                task.estimatedMinutes = max(0, draft.estimatedMinutes)
                task.dueAt = draft.hasDueDate ? draft.dueAt : nil
                task.smartEntries = smartEntries
                task.tags = tags

                let smart = SmartEvaluator.evaluate(
                    title: task.title,
                    notes: task.notes,
                    smartEntries: smartEntries,
                    dueAt: task.dueAt
                )
                task.smartSpecificMissing = smart.specificMissing
                task.smartMeasurableMissing = smart.measurableMissing
                task.smartActionableMissing = smart.actionableMissing
                task.smartRelevantMissing = smart.relevantMissing
                task.smartBoundedMissing = smart.boundedMissing

                if task.status == .done, task.completedAt == nil {
                    task.completedAt = Date()
                } else if task.status != .done {
                    task.completedAt = nil
                }
                task.touch()
            }

            if state.priorityPromptTaskID == taskID {
                state.priorityPromptTaskID = nil
            }
        }

        _ = synchronizeMindMapFromTasks(false)
        persist("task.updated", taskID.uuidString)
        refreshPetState()
    }

    func applyPrioritySelection(for taskID: UUID, urgencyValue: Double, importanceValue: Double) {
        let normalizedUrgencyValue = PriorityVector.clampedPercentage(urgencyValue)
        let normalizedImportanceValue = PriorityVector.clampedPercentage(importanceValue)

        mutateState { state in
            self.mutateTask(in: &state.snapshot, id: taskID) { task in
                task.priority = PriorityVector.derivedPriority(
                    urgencyValue: normalizedUrgencyValue,
                    importanceValue: normalizedImportanceValue
                )
                task.urgencyScore = PriorityVector.score(from: normalizedUrgencyValue)
                task.importanceScore = PriorityVector.score(from: normalizedImportanceValue)
                task.urgencyValue = normalizedUrgencyValue
                task.importanceValue = normalizedImportanceValue
                task.quadrant = PriorityVector.quadrant(
                    urgencyValue: normalizedUrgencyValue,
                    importanceValue: normalizedImportanceValue
                )
                task.touch()
            }
            state.priorityPromptTaskID = nil
        }

        persist("task.priority.selected", taskID.uuidString)
        refreshPetState()
    }

    func startCurrentTask(timerMode: TaskTimerMode = .countUp) -> UUID? {
        let state = getState()
        guard let currentTask = TaskService.currentTask(in: state.snapshot) else { return nil }
        return startTask(id: currentTask.id, timerMode: timerMode)
    }

    @discardableResult
    func startTask(id taskID: UUID, timerMode: TaskTimerMode = .countUp) -> UUID? {
        let state = getState()
        guard let task = task(id: taskID, in: state.snapshot) else { return nil }

        if let activeTaskID = activeTaskID(in: state.snapshot) {
            pauseTask(id: activeTaskID)
        }

        mutateState { state in
            state.snapshot.tasks = state.snapshot.tasks.map { existingTask in
                guard existingTask.id == taskID else { return existingTask }
                var updated = existingTask
                updated.status = .doing
                updated.completedAt = nil
                updated.touch()
                return updated
            }
            self.setBackgroundState(for: taskID, enabled: false, in: &state.snapshot)

            if timerMode != .untimed {
                state.snapshot.sessions.insert(
                    Session(
                        id: UUID(),
                        taskID: taskID,
                        startedAt: Date(),
                        endedAt: nil,
                        totalSeconds: 0,
                        state: .active,
                        interruptionCount: 0,
                        timerMode: timerMode,
                        countdownTargetSeconds: timerMode == .countdown ? self.countdownTargetSeconds(for: task) : nil
                    ),
                    at: 0
                )
            }
        }

        if timerMode != .untimed {
            persist("session.started", "\(task.title):\(timerMode.rawValue)")
        } else {
            persist("task.started.untimed", task.title)
        }
        refreshPetState()
        return taskID
    }

    func pauseCurrentTask() {
        let state = getState()
        guard let currentTask = TaskService.currentTask(in: state.snapshot) else { return }
        pauseTask(id: currentTask.id)
    }

    func pauseTask(id taskID: UUID) {
        let state = getState()
        guard let task = task(id: taskID, in: state.snapshot) else { return }
        guard task.status == .doing || activeTaskID(in: state.snapshot) == taskID else { return }

        let now = Date()
        let activeSession = TaskService.activeSession(in: state.snapshot)

        mutateState { state in
            if let activeSession, activeSession.taskID == taskID {
                state.snapshot.sessions = state.snapshot.sessions.map { session in
                    guard session.id == activeSession.id else { return session }
                    var updated = session
                    updated.state = .paused
                    updated.endedAt = now
                    updated.totalSeconds = TaskService.liveSeconds(for: session, now: now)
                    return updated
                }
            }

            state.snapshot.tasks = state.snapshot.tasks.map { existingTask in
                guard existingTask.id == taskID else { return existingTask }
                var updated = existingTask
                updated.status = .paused
                updated.touch()
                return updated
            }
            self.clearBackgroundTask(taskID, in: &state.snapshot)
        }

        persist("session.paused", task.id.uuidString)
        refreshPetState()
    }

    func interruptCurrentTask(reason: String) {
        let state = getState()
        guard let activeSession = TaskService.activeSession(in: state.snapshot) else { return }

        let now = Date()
        mutateState { state in
            state.snapshot.interrupts.insert(
                Interrupt(
                    id: UUID(),
                    sessionID: activeSession.id,
                    reason: reason.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                    startedAt: now,
                    endedAt: now
                ),
                at: 0
            )
            state.snapshot.sessions = state.snapshot.sessions.map { session in
                guard session.id == activeSession.id else { return session }
                var updated = session
                updated.interruptionCount += 1
                return updated
            }
        }

        pauseTask(id: activeSession.taskID)
        persist("session.interrupted", reason)
    }

    func completeCurrentTask(switchToTaskID preferredTaskID: UUID? = nil) -> UUID? {
        let state = getState()
        guard let currentTask = TaskService.currentTask(in: state.snapshot) else { return nil }
        return completeTask(id: currentTask.id, switchToTaskID: preferredTaskID)
    }

    @discardableResult
    func completeTask(id taskID: UUID, switchToTaskID preferredTaskID: UUID? = nil) -> UUID? {
        let state = getState()
        let snapshot = state.snapshot
        let now = Date()

        let resolvedPreferredTaskID = preferredTaskID.flatMap { candidateID -> UUID? in
            guard let candidateTask = task(id: candidateID, in: snapshot) else { return nil }
            guard candidateTask.id != taskID else { return nil }
            guard candidateTask.status != .done && candidateTask.status != .archived else { return nil }
            return candidateTask.id
        }

        let isSelectedTask = snapshot.selectedTaskID == taskID
        let preferredRootTaskID = TaskService.rootAncestorID(for: taskID, in: snapshot)
        let nextFocusTaskID = resolvedPreferredTaskID
            ?? (isSelectedTask
                ? TaskService.nextFocusableTask(
                    after: taskID,
                    preferringRootTaskID: preferredRootTaskID,
                    in: snapshot
                )?.id
                : snapshot.selectedTaskID)

        mutateState { state in
            self.stopActiveSessionIfNeeded(for: taskID, newState: .stopped, now: now, in: &state.snapshot)

            state.snapshot.tasks = state.snapshot.tasks.map { task in
                guard task.id == taskID else {
                    guard isSelectedTask || resolvedPreferredTaskID != nil else { return task }
                    var updated = task
                    updated.isCurrent = task.id == nextFocusTaskID
                    if updated.isCurrent != task.isCurrent {
                        updated.touch()
                    }
                    return updated
                }
                var updated = task
                updated.status = .done
                updated.completedAt = now
                updated.isCurrent = false
                updated.touch()
                return updated
            }

            let childIDs = state.snapshot.tasks
                .filter { $0.parentTaskID == taskID && $0.status != .archived }
                .map(\.id)
            if !childIDs.isEmpty {
                state.snapshot.tasks = state.snapshot.tasks.map { task in
                    guard childIDs.contains(task.id) else { return task }
                    var updated = task
                    updated.status = .archived
                    updated.isCurrent = false
                    updated.touch()
                    return updated
                }
            }

            self.clearBackgroundTask(taskID, in: &state.snapshot)
            if isSelectedTask || resolvedPreferredTaskID != nil {
                state.snapshot.selectedTaskID = nextFocusTaskID
            }
            state.snapshot.lastCelebrationAt = now
        }

        _ = synchronizeMindMapFromTasks(false)
        persist("task.completed", taskID.uuidString)
        refreshPetState()
        return nextFocusTaskID
    }

    func moveCurrentTaskToBackground() -> UUID? {
        let state = getState()
        guard let currentTask = TaskService.currentTask(in: state.snapshot) else { return nil }
        return moveTaskToBackground(id: currentTask.id)
    }

    @discardableResult
    func moveTaskToBackground(id taskID: UUID) -> UUID? {
        let state = getState()
        let snapshot = state.snapshot
        guard let task = task(id: taskID, in: snapshot) else { return nil }

        let now = Date()
        let isSelectedTask = snapshot.selectedTaskID == taskID
        let preferredRootTaskID = TaskService.rootAncestorID(for: taskID, in: snapshot)
        let nextFocusTaskID = isSelectedTask
            ? TaskService.nextFocusableTask(
                after: taskID,
                preferringRootTaskID: preferredRootTaskID,
                in: snapshot
            )?.id
            : snapshot.selectedTaskID

        mutateState { state in
            self.stopActiveSessionIfNeeded(for: taskID, newState: .stopped, now: now, in: &state.snapshot)

            state.snapshot.tasks = state.snapshot.tasks.map { existingTask in
                guard existingTask.id == taskID else { return existingTask }
                var updated = existingTask
                updated.status = .doing
                updated.completedAt = nil
                updated.touch()
                return updated
            }
            self.setBackgroundState(for: taskID, enabled: true, in: &state.snapshot)

            if isSelectedTask, let nextFocusTaskID, nextFocusTaskID != taskID {
                state.snapshot.selectedTaskID = nextFocusTaskID
                state.snapshot.tasks = state.snapshot.tasks.map { existingTask in
                    var updated = existingTask
                    updated.isCurrent = existingTask.id == nextFocusTaskID
                    if updated.isCurrent != existingTask.isCurrent {
                        updated.touch()
                    }
                    return updated
                }
            }
        }

        persist("task.backgrounded", task.title)
        refreshPetState()
        return nextFocusTaskID ?? snapshot.selectedTaskID
    }

    private func pauseLeavingTaskIfNeeded(_ taskID: UUID?) {
        let state = getState()
        guard let taskID else { return }
        guard !isBackgroundTask(taskID, in: state.snapshot) else { return }
        guard let leavingTask = task(id: taskID, in: state.snapshot) else { return }
        guard leavingTask.status == .doing || activeTaskID(in: state.snapshot) == taskID else { return }
        pauseTask(id: taskID)
    }

    private func task(id: UUID?, in snapshot: AppSnapshot) -> Task? {
        guard let id else { return nil }
        return snapshot.tasks.first(where: { $0.id == id })
    }

    private func activeTaskID(in snapshot: AppSnapshot) -> UUID? {
        TaskService.activeSession(in: snapshot)?.taskID
    }

    private func isBackgroundTask(_ taskID: UUID?, in snapshot: AppSnapshot) -> Bool {
        guard let taskID else { return false }
        let backgroundTaskIDs = Set(snapshot.preferences.backgroundTaskIDs.compactMap(UUID.init(uuidString:)))
        return backgroundTaskIDs.contains(taskID)
    }

    private func nextSortIndex(for parentTaskID: UUID?, excluding taskID: UUID? = nil, in snapshot: AppSnapshot) -> Int {
        let siblings = snapshot.tasks.filter {
            $0.parentTaskID == parentTaskID &&
            $0.id != taskID &&
            $0.status != .archived
        }
        return (siblings.map(\.sortIndex).max() ?? -1) + 1
    }

    private func mutateTask(in snapshot: inout AppSnapshot, id: UUID, _ mutate: (inout Task) -> Void) {
        snapshot.tasks = snapshot.tasks.map { task in
            guard task.id == id else { return task }
            var updated = task
            mutate(&updated)
            return updated
        }
    }

    private func stopActiveSessionIfNeeded(
        for taskID: UUID,
        newState: SessionState,
        now: Date,
        in snapshot: inout AppSnapshot
    ) {
        guard let activeSession = TaskService.activeSession(in: snapshot), activeSession.taskID == taskID else { return }
        snapshot.sessions = snapshot.sessions.map { session in
            guard session.id == activeSession.id else { return session }
            var updated = session
            updated.state = newState
            updated.endedAt = now
            updated.totalSeconds = TaskService.liveSeconds(for: session, now: now)
            return updated
        }
    }

    private func setBackgroundState(for taskID: UUID, enabled: Bool, in snapshot: inout AppSnapshot) {
        var ids = snapshot.preferences.backgroundTaskIDs.filter { UUID(uuidString: $0) != nil }
        let serializedID = taskID.uuidString
        if enabled {
            if !ids.contains(serializedID) {
                ids.append(serializedID)
            }
        } else {
            ids.removeAll { $0 == serializedID }
        }
        snapshot.preferences.backgroundTaskIDs = ids
    }

    private func clearBackgroundTask(_ taskID: UUID, in snapshot: inout AppSnapshot) {
        setBackgroundState(for: taskID, enabled: false, in: &snapshot)
    }

    private func countdownTargetSeconds(for task: Task) -> Int {
        max(task.estimatedMinutes ?? 25, 1) * 60
    }
}
