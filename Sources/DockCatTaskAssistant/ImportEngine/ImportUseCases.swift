import Foundation

@MainActor
final class ImportUseCases {
    struct State {
        var snapshot: AppSnapshot
        var importText: String
        var isImportParsing: Bool
        var isAudioTranscribing: Bool
        var importErrorMessage: String?
        var importRuntimeNote: String?
    }

    private let getState: () -> State
    private let mutateState: (@escaping (inout State) -> Void) -> Void
    private let synchronizeMindMapFromTasks: (Bool) -> Bool
    private let mirrorImportedItems: ([ImportDraftItem]) async -> Void
    private let persist: (String, String) -> Void
    private let refreshPetState: () -> Void

    init(
        getState: @escaping () -> State,
        mutateState: @escaping (@escaping (inout State) -> Void) -> Void,
        synchronizeMindMapFromTasks: @escaping (Bool) -> Bool,
        mirrorImportedItems: @escaping ([ImportDraftItem]) async -> Void,
        persist: @escaping (String, String) -> Void,
        refreshPetState: @escaping () -> Void
    ) {
        self.getState = getState
        self.mutateState = mutateState
        self.synchronizeMindMapFromTasks = synchronizeMindMapFromTasks
        self.mirrorImportedItems = mirrorImportedItems
        self.persist = persist
        self.refreshPetState = refreshPetState
    }

    func createDraftFromImportText(sourceType: ImportSourceType = .text) async {
        let state = getState()
        let trimmed = state.importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            mutateState { state in
                state.importErrorMessage = "先输入一些要导入的内容。"
            }
            return
        }

        mutateState { state in
            state.isImportParsing = true
            state.importErrorMessage = nil
        }
        defer {
            mutateState { state in
                state.isImportParsing = false
            }
        }

        let result = await ImportParser.parse(rawText: trimmed, sourceType: sourceType)
        mutateState { state in
            state.snapshot.importDrafts.append(result.draft)
            state.snapshot.importDraftItems.removeAll { $0.draftID == result.draft.id }
            state.snapshot.importDraftItems.append(contentsOf: result.items)
            state.importRuntimeNote = "Vikunja + Duckling + Reminders 已生成 \(result.items.count) 个候选块"
        }

        persist("import.parsed", "\(sourceType.rawValue):\(result.items.count) items")
        refreshPetState()
    }

    func transcribeAudioImport(from url: URL) async {
        mutateState { state in
            state.isAudioTranscribing = true
            state.importErrorMessage = nil
        }
        defer {
            mutateState { state in
                state.isAudioTranscribing = false
            }
        }

        do {
            let transcript = try await WhisperTranscriber.shared.transcribe(audioFileURL: url)
            mutateState { state in
                state.importText = transcript
                state.importRuntimeNote = "Whisper 已转写 \(url.lastPathComponent)"
            }
            await createDraftFromImportText(sourceType: .voice)
        } catch {
            mutateState { state in
                state.importErrorMessage = error.localizedDescription
            }
        }
    }

    func updateDraftItemTitle(id: UUID, title: String) {
        mutateState { state in
            self.mutateDraftItem(in: &state.snapshot, id: id) { updated in
                updated.proposedTitle = title
                updated.smartEntries = SmartEvaluator.seededEntries(
                    title: title,
                    notes: updated.proposedNotes,
                    dueAt: updated.proposedDueAt,
                    existingEntries: updated.smartEntries
                )
                let smart = SmartEvaluator.evaluate(
                    title: title,
                    notes: updated.proposedNotes,
                    smartEntries: updated.smartEntries,
                    dueAt: updated.proposedDueAt
                )
                updated.smartHints = smart.hints
            }
        }
        persist("import.item.updated", id.uuidString)
    }

    func applyDraftItemDraft(_ draft: DraftItemSnapshotDraft, to draftItemID: UUID) {
        let urgencyValue = PriorityVector.clampedPercentage(draft.urgencyValue)
        let importanceValue = PriorityVector.clampedPercentage(draft.importanceValue)
        let urgency = PriorityVector.score(from: urgencyValue)
        let importance = PriorityVector.score(from: importanceValue)
        let smartEntries = draft.smartEntries.mergedWithDefaults()
        let tags = draft.tagsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        mutateState { state in
            self.mutateDraftItem(in: &state.snapshot, id: draftItemID) { item in
                item.proposedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                item.proposedNotes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                item.proposedPriority = PriorityVector.derivedPriority(
                    urgencyValue: urgencyValue,
                    importanceValue: importanceValue
                )
                item.proposedUrgencyScore = urgency
                item.proposedImportanceScore = importance
                item.proposedUrgencyValue = urgencyValue
                item.proposedImportanceValue = importanceValue
                item.proposedQuadrant = PriorityVector.quadrant(
                    urgencyValue: urgencyValue,
                    importanceValue: importanceValue
                )
                item.proposedDueAt = draft.hasDueDate ? draft.dueAt : nil
                item.proposedTags = tags
                item.smartEntries = smartEntries
                item.isAccepted = draft.isAccepted

                let smart = SmartEvaluator.evaluate(
                    title: item.proposedTitle,
                    notes: item.proposedNotes,
                    smartEntries: smartEntries,
                    dueAt: item.proposedDueAt
                )
                item.smartHints = smart.hints
            }
        }
        persist("import.item.updated", draftItemID.uuidString)
    }

    func toggleDraftItemAccepted(id: UUID) {
        mutateState { state in
            self.mutateDraftItem(in: &state.snapshot, id: id) { item in
                item.isAccepted.toggle()
            }
        }
        persist("import.item.toggled", id.uuidString)
    }

    func commitLatestDraft() {
        let state = getState()
        guard let latestDraft = state.snapshot.importDrafts.last else { return }

        let acceptedItems = latestDraftItems(in: state.snapshot, latestDraft: latestDraft).filter(\.isAccepted)
        guard !acceptedItems.isEmpty else { return }

        var createdTaskIDsByDraftItemID: [UUID: UUID] = [:]
        var projectIDsByName: [String: UUID] = [:]
        let now = Date()

        mutateState { state in
            for item in acceptedItems {
                let smartEntries = item.smartEntries.mergedWithDefaults()
                let smart = SmartEvaluator.evaluate(
                    title: item.proposedTitle,
                    notes: item.proposedNotes,
                    smartEntries: smartEntries,
                    dueAt: item.proposedDueAt
                )
                let projectID = self.ensureProjectID(
                    named: item.proposedProjectName,
                    cache: &projectIDsByName,
                    now: now,
                    in: &state.snapshot
                )
                let task = Task(
                    id: UUID(),
                    projectID: projectID,
                    parentTaskID: item.parentItemID.flatMap { createdTaskIDsByDraftItemID[$0] },
                    sortIndex: item.sortIndex,
                    title: item.proposedTitle,
                    notes: item.proposedNotes,
                    status: .todo,
                    priority: item.proposedPriority ?? PriorityVector.derivedPriority(
                        urgencyValue: item.proposedUrgencyValue ?? PriorityVector.value(from: item.proposedUrgencyScore ?? 1),
                        importanceValue: item.proposedImportanceValue ?? PriorityVector.value(from: item.proposedImportanceScore ?? 1)
                    ),
                    urgencyScore: item.proposedUrgencyScore ?? 1,
                    importanceScore: item.proposedImportanceScore ?? 1,
                    urgencyValue: item.proposedUrgencyValue ?? PriorityVector.value(from: item.proposedUrgencyScore ?? 1),
                    importanceValue: item.proposedImportanceValue ?? PriorityVector.value(from: item.proposedImportanceScore ?? 1),
                    quadrant: item.proposedQuadrant ?? PriorityVector.quadrant(
                        urgencyValue: item.proposedUrgencyValue ?? PriorityVector.value(from: item.proposedUrgencyScore ?? 1),
                        importanceValue: item.proposedImportanceValue ?? PriorityVector.value(from: item.proposedImportanceScore ?? 1)
                    ),
                    estimatedMinutes: nil,
                    dueAt: item.proposedDueAt,
                    smartSpecificMissing: smart.specificMissing,
                    smartMeasurableMissing: smart.measurableMissing,
                    smartActionableMissing: smart.actionableMissing,
                    smartRelevantMissing: smart.relevantMissing,
                    smartBoundedMissing: smart.boundedMissing,
                    smartEntries: smartEntries,
                    tags: item.proposedTags,
                    isCurrent: false,
                    createdAt: now,
                    updatedAt: now,
                    completedAt: nil
                )
                createdTaskIDsByDraftItemID[item.id] = task.id
                state.snapshot.tasks.append(task)
            }

            state.snapshot.importDrafts = state.snapshot.importDrafts.map { draft in
                guard draft.id == latestDraft.id else { return draft }
                var updated = draft
                updated.parseStatus = .accepted
                updated.updatedAt = Date()
                return updated
            }

            if state.snapshot.selectedTaskID == nil, let firstTaskID = createdTaskIDsByDraftItemID.values.first {
                state.snapshot.selectedTaskID = firstTaskID
            }

            state.importRuntimeNote = "已导入 \(acceptedItems.count) 条任务，并同步到 Apple Reminders"
        }

        _ = synchronizeMindMapFromTasks(false)
        _Concurrency.Task { [mirrorImportedItems] in
            await mirrorImportedItems(acceptedItems)
        }
        persist("import.accepted", latestDraft.id.uuidString)
        refreshPetState()
    }

    private func latestDraftItems(in snapshot: AppSnapshot, latestDraft: ImportDraft) -> [ImportDraftItem] {
        let grouped = Dictionary(grouping: snapshot.importDraftItems.filter { $0.draftID == latestDraft.id }) { $0.parentItemID }
        let roots = (grouped[nil] ?? []).sorted { $0.sortIndex < $1.sortIndex }
        var ordered: [ImportDraftItem] = []

        func walk(_ item: ImportDraftItem) {
            ordered.append(item)
            (grouped[item.id] ?? []).sorted { $0.sortIndex < $1.sortIndex }.forEach(walk)
        }

        roots.forEach(walk)
        return ordered
    }

    private func mutateDraftItem(in snapshot: inout AppSnapshot, id: UUID, _ mutate: (inout ImportDraftItem) -> Void) {
        snapshot.importDraftItems = snapshot.importDraftItems.map { item in
            guard item.id == id else { return item }
            var updated = item
            mutate(&updated)
            return updated
        }
    }

    private func ensureProjectID(
        named projectName: String?,
        cache: inout [String: UUID],
        now: Date,
        in snapshot: inout AppSnapshot
    ) -> UUID? {
        guard let normalized = projectName?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else {
            return nil
        }

        let key = normalized.lowercased()
        if let cached = cache[key] {
            return cached
        }
        if let existing = snapshot.projects.first(where: { $0.name.caseInsensitiveCompare(normalized) == .orderedSame }) {
            cache[key] = existing.id
            return existing.id
        }

        let project = Project(
            id: UUID(),
            name: normalized,
            notes: nil,
            createdAt: now,
            updatedAt: now
        )
        snapshot.projects.append(project)
        cache[key] = project.id
        return project.id
    }
}
