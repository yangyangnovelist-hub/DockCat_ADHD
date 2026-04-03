import Foundation
import Combine
import AppFlowyDocumentBridge

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: AppSnapshot
    @Published var importText: String
    @Published private(set) var petState: PetVisualState
    @Published private(set) var isPetHovering = false
    @Published private(set) var isImportParsing = false
    @Published private(set) var isAudioTranscribing = false
    @Published private(set) var priorityPromptTaskID: UUID?
    @Published var importErrorMessage: String?
    @Published var importRuntimeNote: String?

    private let repository: AppRepository
    private let appleRemindersBridge: AppleRemindersBridge
    private var saveTask: _Concurrency.Task<Void, Never>?
    private var inputIdleTask: _Concurrency.Task<Void, Never>?
    private var autosaveTimer: Timer?
    private var lastExternalInputAt: Date?

    init(
        repository: AppRepository = AppRepository(),
        appleRemindersBridge: AppleRemindersBridge = AppleRemindersBridge()
    ) {
        self.repository = repository
        self.appleRemindersBridge = appleRemindersBridge
        let loadedSnapshot = AppSnapshot.empty
        self.snapshot = loadedSnapshot
        self.importText = ""
        self.petState = PetStateMachine.resolve(snapshot: loadedSnapshot, isHovering: false, lastExternalInputAt: nil)

        _Concurrency.Task {
            let restored = await repository.loadSnapshot()
            await MainActor.run {
                let (sanitizedSnapshot, didSanitizeSnapshot) = Self.sanitizeRestoredSnapshot(restored)
                self.snapshot = sanitizedSnapshot
                let didReconcileMindMap = self.reconcileMindMapAndTasksOnRestore()
                self.importText = sanitizedSnapshot.importDrafts.last?.rawText ?? Self.seedImportText
                self.refreshPetState(shouldPersist: false)
                self.startAutosaveTimer()
                if didSanitizeSnapshot || didReconcileMindMap {
                    self.scheduleSave()
                }
            }
        }
    }

    static let seedImportText = ""
    private static let legacySeedPreviewNote = "作为首个父任务示例"

    var tasks: [Task] { TaskService.sortedTasks(in: snapshot) }
    var taskDepths: [UUID: Int] { TaskService.depthMap(in: snapshot) }
    var currentTask: Task? { TaskService.currentTask(in: snapshot) }
    var activeSession: Session? { TaskService.activeSession(in: snapshot) }
    var activeTaskID: UUID? { activeSession?.taskID }
    var backgroundTaskIDs: Set<UUID> {
        Set(snapshot.preferences.backgroundTaskIDs.compactMap(UUID.init(uuidString:)))
    }
    var backgroundTasks: [Task] {
        tasks.filter { backgroundTaskIDs.contains($0.id) && $0.status != .done && $0.status != .archived }
    }
    var todayStats: DailyStats { StatsAggregator.todayStats(snapshot: snapshot) }
    var latestDraft: ImportDraft? { snapshot.importDrafts.last }
    var mindMapDocument: MindMapDocument { snapshot.mindMapDocument }
    var shouldPetStayExpanded: Bool {
        !snapshot.preferences.lowDistractionMode || petState == .focus || petState == .alert || petState == .celebrate
    }

    var latestDraftItems: [ImportDraftItem] {
        guard let latestDraft else { return [] }
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

    var latestImportDocument: FlowDocument {
        ImportDocumentBuilder.build(draft: latestDraft, items: latestDraftItems)
    }

    func bootstrapIfNeeded() {
        guard snapshot.tasks.isEmpty else { return }
        if snapshot.preferences.lowDistractionMode == false {
            snapshot.preferences.lowDistractionMode = true
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
        synchronizeMindMapFromTasks(force: true)
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

        let task = Task(
            id: UUID(),
            projectID: nil,
            parentTaskID: parentTaskID,
            sortIndex: nextSortIndex(for: parentTaskID),
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
            isCurrent: snapshot.selectedTaskID == nil,
            createdAt: now,
            updatedAt: now,
            completedAt: nil
        )

        snapshot.tasks.append(task)
        if snapshot.selectedTaskID == nil {
            snapshot.selectedTaskID = task.id
        }
        if promptForPriority {
            priorityPromptTaskID = task.id
        }
        synchronizeMindMapFromTasks()
        persist(event: "task.created", details: task.title)
        refreshPetState()
        return task.id
    }

    func task(id: UUID?) -> Task? {
        snapshot.tasks.first { $0.id == id }
    }

    func draftItem(id: UUID?) -> ImportDraftItem? {
        snapshot.importDraftItems.first { $0.id == id }
    }

    func taskSessions(taskID: UUID) -> [Session] {
        snapshot.sessions
            .filter { $0.taskID == taskID }
            .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
    }

    func latestSession(for taskID: UUID?) -> Session? {
        guard let taskID else { return nil }
        return taskSessions(taskID: taskID).first
    }

    func isBackgroundTask(_ taskID: UUID?) -> Bool {
        guard let taskID else { return false }
        return backgroundTaskIDs.contains(taskID)
    }

    func childTaskCount(for taskID: UUID) -> Int {
        snapshot.tasks.filter { $0.parentTaskID == taskID }.count
    }

    func projectName(for taskID: UUID?) -> String? {
        guard let task = task(id: taskID), let projectID = task.projectID else { return nil }
        return snapshot.projects.first(where: { $0.id == projectID })?.name
    }

    func buildTaskDraft(for taskID: UUID) -> TaskSnapshotDraft? {
        guard let task = task(id: taskID) else { return nil }
        return TaskSnapshotDraft(
            title: task.title,
            notes: task.notes ?? "",
            status: task.status,
            urgencyValue: task.urgencyValue,
            importanceValue: task.importanceValue,
            quadrant: task.quadrant,
            estimatedMinutes: task.estimatedMinutes ?? 25,
            dueAt: task.dueAt ?? Date(),
            hasDueDate: task.dueAt != nil,
            tagsText: task.tags.joined(separator: ", "),
            smartEntries: task.smartEntries.mergedWithDefaults()
        )
    }

    func buildDraftItemDraft(for draftItemID: UUID) -> DraftItemSnapshotDraft? {
        guard let item = draftItem(id: draftItemID) else { return nil }
        return DraftItemSnapshotDraft(
            title: item.proposedTitle,
            notes: item.proposedNotes ?? "",
            urgencyValue: item.proposedUrgencyValue ?? PriorityVector.value(from: item.proposedUrgencyScore ?? 1),
            importanceValue: item.proposedImportanceValue ?? PriorityVector.value(from: item.proposedImportanceScore ?? 1),
            quadrant: item.proposedQuadrant ?? .notUrgentImportant,
            dueAt: item.proposedDueAt ?? Date(),
            hasDueDate: item.proposedDueAt != nil,
            tagsText: item.proposedTags.joined(separator: ", "),
            smartEntries: item.smartEntries.mergedWithDefaults(),
            isAccepted: item.isAccepted
        )
    }

    func setCurrentTask(id: UUID) {
        let previousTaskID = snapshot.selectedTaskID ?? snapshot.tasks.first(where: \.isCurrent)?.id
        if previousTaskID != id {
            pauseLeavingTaskIfNeeded(previousTaskID)
        }
        snapshot.selectedTaskID = id
        let now = Date()
        snapshot.tasks = snapshot.tasks.map { task in
            var updated = task
            let newIsCurrent = updated.id == id
            let isCurrentChanged = updated.isCurrent != newIsCurrent
            let statusChanged = updated.id == id && updated.status == .done
            updated.isCurrent = newIsCurrent
            if statusChanged {
                updated.status = .todo
            }
            if isCurrentChanged || statusChanged {
                updated.updatedAt = now
            }
            return updated
        }
        persist(event: "task.selected", details: id.uuidString)
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
        mutateTask(id: id) { task in
            task.title = trimmed
        }
        synchronizeMindMapFromTasks()
        persist(event: "task.renamed", details: id.uuidString)
        refreshPetState()
    }

    func indentTask(id: UUID) {
        guard let currentIndex = tasks.firstIndex(where: { $0.id == id }), currentIndex > 0 else { return }
        let candidateParent = tasks[currentIndex - 1]
        mutateTask(id: id) { task in
            task.parentTaskID = candidateParent.id
            task.sortIndex = nextSortIndex(for: candidateParent.id, excluding: task.id)
        }
        synchronizeMindMapFromTasks()
        persist(event: "task.indented", details: id.uuidString)
        refreshPetState()
    }

    func outdentTask(id: UUID) {
        guard let task = task(id: id), let parentID = task.parentTaskID, let parent = self.task(id: parentID) else { return }
        mutateTask(id: id) { mutableTask in
            mutableTask.parentTaskID = parent.parentTaskID
            mutableTask.sortIndex = nextSortIndex(for: parent.parentTaskID, excluding: mutableTask.id)
        }
        synchronizeMindMapFromTasks()
        persist(event: "task.outdented", details: id.uuidString)
        refreshPetState()
    }

    func archiveTask(id: UUID) {
        mutateTask(id: id) { task in
            task.status = .archived
            task.isCurrent = false
        }
        clearBackgroundTask(id)
        if snapshot.selectedTaskID == id {
            snapshot.selectedTaskID = tasks.first(where: { $0.status != .archived && $0.id != id })?.id
        }
        synchronizeMindMapFromTasks()
        persist(event: "task.archived", details: id.uuidString)
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

        mutateTask(id: taskID) { task in
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
        }

        synchronizeMindMapFromTasks()
        persist(event: "task.updated", details: taskID.uuidString)
        if priorityPromptTaskID == taskID {
            priorityPromptTaskID = nil
        }
        refreshPetState()
    }

    func applyPrioritySelection(for taskID: UUID, urgencyValue: Double, importanceValue: Double) {
        let normalizedUrgencyValue = PriorityVector.clampedPercentage(urgencyValue)
        let normalizedImportanceValue = PriorityVector.clampedPercentage(importanceValue)

        mutateTask(id: taskID) { task in
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
        }

        priorityPromptTaskID = nil
        persist(event: "task.priority.selected", details: taskID.uuidString)
        refreshPetState()
    }

    func dismissPriorityPrompt() {
        priorityPromptTaskID = nil
    }

    private static func sanitizeRestoredSnapshot(_ snapshot: AppSnapshot) -> (snapshot: AppSnapshot, didChange: Bool) {
        var sanitizedSnapshot = snapshot
        var didChange = false

        sanitizedSnapshot.tasks = sanitizedSnapshot.tasks.map { task in
            var updated = task

            if updated.notes == legacySeedPreviewNote {
                updated.notes = nil
                didChange = true
            }

            return updated
        }

        let groupedTasks = Dictionary(grouping: sanitizedSnapshot.tasks) { $0.parentTaskID }
        var normalizedSortIndices: [UUID: Int] = [:]

        func assignSortIndices(parentTaskID: UUID?) {
            let siblings = (groupedTasks[parentTaskID] ?? []).sorted {
                if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
                return $0.createdAt < $1.createdAt
            }

            for (index, task) in siblings.enumerated() {
                normalizedSortIndices[task.id] = index
                assignSortIndices(parentTaskID: task.id)
            }
        }

        assignSortIndices(parentTaskID: nil)

        sanitizedSnapshot.tasks = sanitizedSnapshot.tasks.map { task in
            var updated = task
            let normalizedSortIndex = normalizedSortIndices[task.id] ?? 0
            if updated.sortIndex != normalizedSortIndex {
                updated.sortIndex = normalizedSortIndex
                didChange = true
            }
            return updated
        }

        return (sanitizedSnapshot, didChange)
    }

    @discardableResult
    func startCurrentTask(timerMode: TaskTimerMode = .countUp) -> UUID? {
        guard let currentTask else { return nil }
        return startTask(id: currentTask.id, timerMode: timerMode)
    }

    @discardableResult
    func startTask(id taskID: UUID, timerMode: TaskTimerMode = .countUp) -> UUID? {
        guard let task = task(id: taskID) else { return nil }
        if let activeTaskID {
            pauseTask(id: activeTaskID)
        }

        let now = Date()
        snapshot.tasks = snapshot.tasks.map { existingTask in
            guard existingTask.id == taskID else { return existingTask }
            var updated = existingTask
            updated.status = .doing
            updated.completedAt = nil
            updated.updatedAt = now
            return updated
        }
        setBackgroundState(for: taskID, enabled: false)

        if timerMode != .untimed {
            snapshot.sessions.insert(
                Session(
                    id: UUID(),
                    taskID: taskID,
                    startedAt: now,
                    endedAt: nil,
                    totalSeconds: 0,
                    state: .active,
                    interruptionCount: 0,
                    timerMode: timerMode,
                    countdownTargetSeconds: timerMode == .countdown ? countdownTargetSeconds(for: task) : nil
                ),
                at: 0
            )
            persist(
                event: "session.started",
                details: "\(task.title):\(timerMode.rawValue)"
            )
        } else {
            persist(
                event: "task.started.untimed",
                details: task.title
            )
        }
        refreshPetState()
        return taskID
    }

    func pauseCurrentTask() {
        guard let currentTask else { return }
        pauseTask(id: currentTask.id)
    }

    func pauseTask(id taskID: UUID) {
        guard let task = task(id: taskID) else { return }
        guard task.status == .doing || activeTaskID == taskID else { return }
        let now = Date()
        if let activeSession, activeSession.taskID == taskID {
            snapshot.sessions = snapshot.sessions.map { session in
                guard session.id == activeSession.id else { return session }
                var updated = session
                updated.state = .paused
                updated.endedAt = now
                updated.totalSeconds = TaskService.liveSeconds(for: session, now: now)
                return updated
            }
        }

        snapshot.tasks = snapshot.tasks.map { existingTask in
            guard existingTask.id == taskID else { return existingTask }
            var updated = existingTask
            updated.status = .paused
            updated.updatedAt = now
            return updated
        }
        clearBackgroundTask(taskID)

        persist(event: "session.paused", details: task.id.uuidString)
        refreshPetState()
    }

    func interruptCurrentTask(reason: String) {
        guard let activeSession else { return }
        let now = Date()
        snapshot.interrupts.insert(
            Interrupt(
                id: UUID(),
                sessionID: activeSession.id,
                reason: reason.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                startedAt: now,
                endedAt: now
            ),
            at: 0
        )
        snapshot.sessions = snapshot.sessions.map { session in
            guard session.id == activeSession.id else { return session }
            var updated = session
            updated.interruptionCount += 1
            return updated
        }
        pauseTask(id: activeSession.taskID)
        persist(event: "session.interrupted", details: reason)
    }

    @discardableResult
    func completeCurrentTask(switchToTaskID preferredTaskID: UUID? = nil) -> UUID? {
        guard let currentTask else { return nil }
        return completeTask(id: currentTask.id, switchToTaskID: preferredTaskID)
    }

    @discardableResult
    func completeTask(id taskID: UUID, switchToTaskID preferredTaskID: UUID? = nil) -> UUID? {
        let now = Date()
        stopActiveSessionIfNeeded(for: taskID, newState: .stopped, now: now)

        let resolvedPreferredTaskID = preferredTaskID.flatMap { candidateID -> UUID? in
            guard let candidateTask = task(id: candidateID) else { return nil }
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

        snapshot.tasks = snapshot.tasks.map { task in
            guard task.id == taskID else {
                guard isSelectedTask || resolvedPreferredTaskID != nil else { return task }
                var updated = task
                updated.isCurrent = task.id == nextFocusTaskID
                return updated
            }
            var updated = task
            updated.status = .done
            updated.completedAt = now
            updated.updatedAt = now
            updated.isCurrent = false
            return updated
        }
        // 归档所有直接子任务（父任务完成，子任务失去意义）
        let childIDs = snapshot.tasks.filter { $0.parentTaskID == taskID && $0.status != .archived }.map(\.id)
        if !childIDs.isEmpty {
            snapshot.tasks = snapshot.tasks.map { task in
                guard childIDs.contains(task.id) else { return task }
                var updated = task
                updated.status = .archived
                updated.isCurrent = false
                updated.updatedAt = now
                return updated
            }
        }

        clearBackgroundTask(taskID)
        if isSelectedTask || resolvedPreferredTaskID != nil {
            snapshot.selectedTaskID = nextFocusTaskID
        }
        snapshot.lastCelebrationAt = now
        synchronizeMindMapFromTasks()
        persist(event: "task.completed", details: taskID.uuidString)
        refreshPetState()
        return nextFocusTaskID
    }

    @discardableResult
    func moveCurrentTaskToBackground() -> UUID? {
        guard let currentTask else { return nil }
        return moveTaskToBackground(id: currentTask.id)
    }

    @discardableResult
    func moveTaskToBackground(id taskID: UUID) -> UUID? {
        guard let task = task(id: taskID) else { return nil }

        let now = Date()
        stopActiveSessionIfNeeded(for: taskID, newState: .stopped, now: now)

        snapshot.tasks = snapshot.tasks.map { existingTask in
            guard existingTask.id == taskID else { return existingTask }
            var updated = existingTask
            updated.status = .doing
            updated.completedAt = nil
            updated.updatedAt = now
            return updated
        }
        setBackgroundState(for: taskID, enabled: true)

        let isSelectedTask = snapshot.selectedTaskID == taskID
        let preferredRootTaskID = TaskService.rootAncestorID(for: taskID, in: snapshot)
        let nextFocusTaskID = isSelectedTask
            ? TaskService.nextFocusableTask(
                after: taskID,
                preferringRootTaskID: preferredRootTaskID,
                in: snapshot
            )?.id
            : snapshot.selectedTaskID

        if isSelectedTask, let nextFocusTaskID, nextFocusTaskID != taskID {
            snapshot.selectedTaskID = nextFocusTaskID
            snapshot.tasks = snapshot.tasks.map { existingTask in
                var updated = existingTask
                updated.isCurrent = existingTask.id == nextFocusTaskID
                return updated
            }
        }

        persist(event: "task.backgrounded", details: task.title)
        refreshPetState()
        return nextFocusTaskID ?? snapshot.selectedTaskID
    }

    func createDraftFromImportText(sourceType: ImportSourceType = .text) async {
        let trimmed = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            importErrorMessage = "先输入一些要导入的内容。"
            return
        }

        isImportParsing = true
        importErrorMessage = nil
        defer { isImportParsing = false }

        let result = await ImportParser.parse(rawText: trimmed, sourceType: sourceType)
        snapshot.importDrafts.append(result.draft)
        snapshot.importDraftItems.removeAll { $0.draftID == result.draft.id }
        snapshot.importDraftItems.append(contentsOf: result.items)
        importRuntimeNote = "Vikunja + Duckling + Reminders 已生成 \(result.items.count) 个候选块"
        persist(event: "import.parsed", details: "\(sourceType.rawValue):\(result.items.count) items")
        refreshPetState()
    }

    func transcribeAudioImport(from url: URL) async {
        isAudioTranscribing = true
        importErrorMessage = nil
        defer { isAudioTranscribing = false }

        do {
            let transcript = try await WhisperTranscriber.shared.transcribe(audioFileURL: url)
            importText = transcript
            importRuntimeNote = "Whisper 已转写 \(url.lastPathComponent)"
            await createDraftFromImportText(sourceType: .voice)
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    func updateDraftItemTitle(id: UUID, title: String) {
        mutateDraftItem(id: id) { updated in
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
        persist(event: "import.item.updated", details: id.uuidString)
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

        mutateDraftItem(id: draftItemID) { item in
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
        persist(event: "import.item.updated", details: draftItemID.uuidString)
    }

    func toggleDraftItemAccepted(id: UUID) {
        mutateDraftItem(id: id) { item in
            item.isAccepted.toggle()
        }
        persist(event: "import.item.toggled", details: id.uuidString)
    }

    func commitLatestDraft() {
        guard let latestDraft else { return }
        let acceptedItems = latestDraftItems.filter(\.isAccepted)
        guard !acceptedItems.isEmpty else { return }

        var createdTaskIDsByDraftItemID: [UUID: UUID] = [:]
        var projectIDsByName: [String: UUID] = [:]
        let now = Date()

        for item in acceptedItems {
            let smartEntries = item.smartEntries.mergedWithDefaults()
            let smart = SmartEvaluator.evaluate(
                title: item.proposedTitle,
                notes: item.proposedNotes,
                smartEntries: smartEntries,
                dueAt: item.proposedDueAt
            )
            let projectID = ensureProjectID(
                named: item.proposedProjectName,
                cache: &projectIDsByName,
                now: now
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
            snapshot.tasks.append(task)
        }

        let remindersItems = acceptedItems
        _Concurrency.Task { @MainActor [appleRemindersBridge] in
            await appleRemindersBridge.mirrorImportedItems(remindersItems)
        }

        snapshot.importDrafts = snapshot.importDrafts.map { draft in
            guard draft.id == latestDraft.id else { return draft }
            var updated = draft
            updated.parseStatus = .accepted
            updated.updatedAt = Date()
            return updated
        }

        if snapshot.selectedTaskID == nil, let firstTaskID = createdTaskIDsByDraftItemID.values.first {
            snapshot.selectedTaskID = firstTaskID
        }
        synchronizeMindMapFromTasks()
        importRuntimeNote = "已导入 \(acceptedItems.count) 条任务，并同步到 Apple Reminders"
        persist(event: "import.accepted", details: latestDraft.id.uuidString)
        refreshPetState()
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
        if let configJSON, snapshot.mindMapDocument.configJSON != configJSON {
            snapshot.mindMapDocument.configJSON = configJSON
            didChange = true
        }
        if let localConfigJSON, snapshot.mindMapDocument.localConfigJSON != localConfigJSON {
            snapshot.mindMapDocument.localConfigJSON = localConfigJSON
            didChange = true
        }
        if let language, snapshot.mindMapDocument.language != language {
            snapshot.mindMapDocument.language = language
            didChange = true
        }

        guard didChange else { return }
        snapshot.mindMapDocument.updatedAt = Date()
        persist(event: "mind_map.updated", details: snapshot.mindMapDocument.updatedAt.ISO8601Format())
    }

    func setPetHovering(_ hovering: Bool) {
        isPetHovering = hovering
        refreshPetState(shouldPersist: false)
    }

    func noteExternalInput(at date: Date = .now) {
        lastExternalInputAt = date
        refreshPetState(shouldPersist: false)

        inputIdleTask?.cancel()
        inputIdleTask = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(1600))
            await MainActor.run {
                guard let self, self.lastExternalInputAt == date else { return }
                self.refreshPetState(shouldPersist: false)
            }
        }
    }

    func toggleLowDistractionMode() {
        snapshot.preferences.lowDistractionMode.toggle()
        persist(event: "preferences.low_distraction", details: "\(snapshot.preferences.lowDistractionMode)")
        refreshPetState()
    }

    func updatePetPlacement(edge: PetEdge, centerY: CGFloat) {
        snapshot.preferences.petEdge = edge
        snapshot.preferences.petOffsetY = centerY
        persist(event: "preferences.pet_placement", details: "\(edge.rawValue):\(centerY)")
        refreshPetState()
    }

    private func pauseLeavingTaskIfNeeded(_ taskID: UUID?) {
        guard let taskID else { return }
        guard !isBackgroundTask(taskID) else { return }
        guard let leavingTask = task(id: taskID) else { return }
        guard leavingTask.status == .doing || activeTaskID == taskID else { return }
        pauseTask(id: taskID)
    }

    private func stopActiveSessionIfNeeded(for taskID: UUID, newState: SessionState, now: Date) {
        guard let activeSession, activeSession.taskID == taskID else { return }
        snapshot.sessions = snapshot.sessions.map { session in
            guard session.id == activeSession.id else { return session }
            var updated = session
            updated.state = newState
            updated.endedAt = now
            updated.totalSeconds = TaskService.liveSeconds(for: session, now: now)
            return updated
        }
    }

    private func setBackgroundState(for taskID: UUID, enabled: Bool) {
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

    private func clearBackgroundTask(_ taskID: UUID) {
        setBackgroundState(for: taskID, enabled: false)
    }

    private func nextSortIndex(for parentTaskID: UUID?, excluding taskID: UUID? = nil) -> Int {
        let siblings = snapshot.tasks.filter {
            $0.parentTaskID == parentTaskID &&
            $0.id != taskID &&
            $0.status != .archived
        }
        return (siblings.map(\.sortIndex).max() ?? -1) + 1
    }

    private func reconcileMindMapAndTasksOnRestore() -> Bool {
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
                snapshot.mindMapDocument.updatedAt = max(snapshot.mindMapDocument.updatedAt, Date())
            }
            return didChange
        }

        return synchronizeMindMapFromTasks(force: true)
    }

    @discardableResult
    private func applyMindMapDataChange(_ dataJSON: String) -> Bool {
        guard let syncResult = MindMapTaskSynchronizer.syncTasks(from: dataJSON, existingTasks: snapshot.tasks) else {
            guard snapshot.mindMapDocument.dataJSON != dataJSON else { return false }
            snapshot.mindMapDocument.dataJSON = dataJSON
            return true
        }

        var didChange = false

        if snapshot.tasks != syncResult.tasks {
            snapshot.tasks = syncResult.tasks
            didChange = true
        }
        if snapshot.mindMapDocument.dataJSON != syncResult.normalizedDataJSON {
            snapshot.mindMapDocument.dataJSON = syncResult.normalizedDataJSON
            didChange = true
        }

        guard didChange else { return false }

        normalizeSelectedTaskAfterMindMapSync()
        pruneBackgroundTasksAfterMindMapSync()
        stopSessionsForArchivedTasksAfterMindMapSync()

        // 脑图新建的任务弹出四象限选择，和列表建任务流程一致
        if let firstNewTaskID = syncResult.newTaskIDs.first {
            priorityPromptTaskID = firstNewTaskID
            snapshot.selectedTaskID = firstNewTaskID
        }

        return true
    }

    @discardableResult
    private func synchronizeMindMapFromTasks(force: Bool = false) -> Bool {
        let nextDataJSON = MindMapTaskSynchronizer.makeMindMapDataJSON(
            from: snapshot.tasks,
            existingDataJSON: snapshot.mindMapDocument.dataJSON
        )
        guard force || snapshot.mindMapDocument.dataJSON != nextDataJSON else { return false }
        snapshot.mindMapDocument.dataJSON = nextDataJSON
        snapshot.mindMapDocument.updatedAt = Date()
        return true
    }

    private func normalizeSelectedTaskAfterMindMapSync() {
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

    private func pruneBackgroundTasksAfterMindMapSync() {
        let validTaskIDs = Set(snapshot.tasks.filter { $0.status != .archived }.map(\.id.uuidString))
        snapshot.preferences.backgroundTaskIDs = snapshot.preferences.backgroundTaskIDs.filter { validTaskIDs.contains($0) }
    }

    private func stopSessionsForArchivedTasksAfterMindMapSync() {
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

    private func countdownTargetSeconds(for task: Task) -> Int {
        max(task.estimatedMinutes ?? 25, 1) * 60
    }

    private func refreshPetState(shouldPersist: Bool = true) {
        petState = PetStateMachine.resolve(
            snapshot: snapshot,
            isHovering: isPetHovering,
            lastExternalInputAt: lastExternalInputAt
        )
        if shouldPersist {
            scheduleSave()
        }
    }

    private func mutateTask(id: UUID, _ mutate: (inout Task) -> Void) {
        let now = Date()
        snapshot.tasks = snapshot.tasks.map { task in
            guard task.id == id else { return task }
            var updated = task
            mutate(&updated)
            updated.updatedAt = now
            return updated
        }
    }

    private func mutateDraftItem(id: UUID, _ mutate: (inout ImportDraftItem) -> Void) {
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
        now: Date
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

    private func persist(event: String, details: String) {
        scheduleSave()
        _Concurrency.Task {
            await repository.appendEvent(event, details: details)
        }
    }

    private func scheduleSave() {
        let snapshot = snapshot
        saveTask?.cancel()
        saveTask = _Concurrency.Task {
            await repository.saveSnapshot(snapshot)
        }
    }

    private func startAutosaveTimer() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            _Concurrency.Task { @MainActor [weak self] in
                guard let self else { return }
                if self.activeSession != nil {
                    self.objectWillChange.send()
                }
                self.petState = PetStateMachine.resolve(
                    snapshot: self.snapshot,
                    isHovering: self.isPetHovering,
                    lastExternalInputAt: self.lastExternalInputAt
                )
            }
        }
    }

}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
