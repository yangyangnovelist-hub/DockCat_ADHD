import AppKit
import Foundation
import Combine

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
    @Published private(set) var localImportRuntimeStatus: String?
    @Published private(set) var localImportRuntimeStatusIsError = false
    @Published private(set) var isPreparingLocalImportRuntime = false
    @Published private(set) var taskIntakeQueueDepth = 0
    @Published private(set) var isTaskIntakeBusy = false

    private let repository: AppRepository
    private let persistenceCoordinator: SnapshotPersistenceCoordinator
    private let taskIntakeLimiter = TaskIntakeLimiter()
    private let appleRemindersBridge: AppleRemindersBridge
    private var inputIdleTask: _Concurrency.Task<Void, Never>?
    private var autosaveTimer: Timer?
    private var lastExternalInputAt: Date?
    private var saveGeneration = 0
    private lazy var syncUseCases = SyncUseCases(
        getState: { [unowned self] in
            SyncUseCases.State(
                snapshot: self.snapshot,
                priorityPromptTaskID: self.priorityPromptTaskID
            )
        },
        mutateState: { [unowned self] mutate in
            self.withMutableSyncUseCasesState(mutate)
        },
        persist: { [unowned self] event, details in
            self.persist(event: event, details: details, scope: .mindMapDomain)
        },
        mirrorImportedItemsBridge: { [appleRemindersBridge] items in
            await appleRemindersBridge.mirrorImportedItems(items)
        }
    )
    private lazy var taskUseCases = TaskUseCases(
        getState: { [unowned self] in
            TaskUseCases.State(
                snapshot: self.snapshot,
                priorityPromptTaskID: self.priorityPromptTaskID
            )
        },
        mutateState: { [unowned self] mutate in
            self.withMutableTaskUseCasesState(mutate)
        },
        synchronizeMindMapFromTasks: { [unowned self] force in
            self.syncUseCases.synchronizeMindMapFromTasks(force: force)
        },
        persist: { [unowned self] event, details in
            self.persist(event: event, details: details, scope: .taskDomain)
        },
        refreshPetState: { [unowned self] in
            self.refreshPetState()
        }
    )
    private lazy var importUseCases = ImportUseCases(
        getState: { [unowned self] in
            ImportUseCases.State(
                snapshot: self.snapshot,
                importText: self.importText,
                isImportParsing: self.isImportParsing,
                isAudioTranscribing: self.isAudioTranscribing,
                importErrorMessage: self.importErrorMessage,
                importRuntimeNote: self.importRuntimeNote
            )
        },
        mutateState: { [unowned self] mutate in
            self.withMutableImportUseCasesState(mutate)
        },
        synchronizeMindMapFromTasks: { [unowned self] force in
            self.syncUseCases.synchronizeMindMapFromTasks(force: force)
        },
        mirrorImportedItems: { [unowned self] items in
            await self.syncUseCases.mirrorImportedItems(items)
        },
        persist: { [unowned self] event, details in
            self.persist(event: event, details: details, scope: .importDomain)
        },
        refreshPetState: { [unowned self] in
            self.refreshPetState()
        }
    )
    private lazy var importRuntimeCoordinator = ImportRuntimeCoordinator(
        getState: { [unowned self] in
            ImportRuntimeCoordinator.State(
                snapshot: self.snapshot,
                importRuntimeNote: self.importRuntimeNote,
                localImportRuntimeStatus: self.localImportRuntimeStatus,
                localImportRuntimeStatusIsError: self.localImportRuntimeStatusIsError,
                isPreparingLocalImportRuntime: self.isPreparingLocalImportRuntime
            )
        },
        mutateState: { [unowned self] mutate in
            self.withMutableImportRuntimeState(mutate)
        },
        persist: { [unowned self] event, details in
            self.persist(event: event, details: details, scope: .preferencesDomain)
        }
    )

    init(
        repository: AppRepository = AppRepository(),
        appleRemindersBridge: AppleRemindersBridge = AppleRemindersBridge()
    ) {
        self.repository = repository
        self.persistenceCoordinator = SnapshotPersistenceCoordinator(repository: repository)
        self.appleRemindersBridge = appleRemindersBridge
        let loadedSnapshot = AppSnapshot.empty
        self.snapshot = loadedSnapshot
        self.importText = ""
        self.petState = PetStateMachine.resolve(snapshot: loadedSnapshot, isHovering: false, lastExternalInputAt: nil)

        _Concurrency.Task(priority: .utility) { [repository] in
            let restored = await repository.loadSnapshot()
            await MainActor.run {
                let (sanitizedSnapshot, didSanitizeSnapshot) = Self.sanitizeRestoredSnapshot(restored)
                self.snapshot = sanitizedSnapshot
                let didReconcileMindMap = self.syncUseCases.reconcileMindMapAndTasksOnRestore()
                self.importText = sanitizedSnapshot.importDrafts.last?.rawText ?? Self.seedImportText
                self.refreshPetState()
                self.startAutosaveTimer()
                if didSanitizeSnapshot || didReconcileMindMap {
                    self.scheduleSave(scope: .full)
                }
                _Concurrency.Task { [weak self] in
                    await self?.finishLocalImportBootstrap()
                }
            }
        }
    }

    static let seedImportText = ""
    private static let legacySeedPreviewNote = "作为首个父任务示例"

    var tasks: [Task] { TaskService.sortedTasks(in: snapshot) }
    var taskDepths: [UUID: Int] { TaskService.depthMap(in: snapshot) }
    var currentTask: Task? { TaskService.currentTask(in: snapshot) }
    var backgroundTaskIDs: Set<UUID> {
        Set(snapshot.preferences.backgroundTaskIDs.compactMap(UUID.init(uuidString:)))
    }
    var backgroundTasks: [Task] {
        tasks.filter { backgroundTaskIDs.contains($0.id) && $0.status != .done && $0.status != .archived }
    }
    var todayStats: DailyStats { StatsAggregator.todayStats(snapshot: snapshot) }
    var latestDraft: ImportDraft? { snapshot.importDrafts.last }
    var mindMapDocument: MindMapDocument { snapshot.mindMapDocument }
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

    func bootstrapIfNeeded() {
        taskUseCases.bootstrapIfNeeded()
    }

    @discardableResult
    func addTask(
        title: String,
        notes: String? = nil,
        parentTaskID: UUID? = nil,
        promptForPriority: Bool = false
    ) -> UUID? {
        taskUseCases.addTask(
            title: title,
            notes: notes,
            parentTaskID: parentTaskID,
            promptForPriority: promptForPriority
        )
    }

    func task(id: UUID?) -> Task? {
        snapshot.tasks.first { $0.id == id }
    }

    func isBackgroundTask(_ taskID: UUID?) -> Bool {
        guard let taskID else { return false }
        return backgroundTaskIDs.contains(taskID)
    }

    func childTaskCount(for taskID: UUID) -> Int {
        snapshot.tasks.filter { $0.parentTaskID == taskID }.count
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

    func setCurrentTask(id: UUID) {
        taskUseCases.setCurrentTask(id: id)
    }

    @discardableResult
    func addChildTask(parentID: UUID, promptForPriority: Bool = false) -> UUID? {
        taskUseCases.addChildTask(parentID: parentID, promptForPriority: promptForPriority)
    }

    func renameTask(id: UUID, title: String) {
        taskUseCases.renameTask(id: id, title: title)
    }

    func indentTask(id: UUID) {
        taskUseCases.indentTask(id: id)
    }

    func outdentTask(id: UUID) {
        taskUseCases.outdentTask(id: id)
    }

    func archiveTask(id: UUID) {
        taskUseCases.archiveTask(id: id)
    }

    func applyTaskDraft(_ draft: TaskSnapshotDraft, to taskID: UUID) {
        taskUseCases.applyTaskDraft(draft, to: taskID)
    }

    func applyPrioritySelection(for taskID: UUID, urgencyValue: Double, importanceValue: Double) {
        taskUseCases.applyPrioritySelection(for: taskID, urgencyValue: urgencyValue, importanceValue: importanceValue)
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
            let normalizedStatus: TaskStatus = task.status == .paused ? .todo : task.status
            let normalizedSortIndex = normalizedSortIndices[task.id] ?? 0
            if updated.status != normalizedStatus {
                updated.status = normalizedStatus
                didChange = true
            }
            if updated.sortIndex != normalizedSortIndex {
                updated.sortIndex = normalizedSortIndex
                didChange = true
            }
            return updated
        }

        if !sanitizedSnapshot.sessions.isEmpty {
            sanitizedSnapshot.sessions = []
            didChange = true
        }

        if !sanitizedSnapshot.interrupts.isEmpty {
            sanitizedSnapshot.interrupts = []
            didChange = true
        }

        return (sanitizedSnapshot, didChange)
    }

    @discardableResult
    func completeCurrentTask(switchToTaskID preferredTaskID: UUID? = nil) -> UUID? {
        taskUseCases.completeCurrentTask(switchToTaskID: preferredTaskID)
    }

    @discardableResult
    func completeTask(id taskID: UUID, switchToTaskID preferredTaskID: UUID? = nil) -> UUID? {
        taskUseCases.completeTask(id: taskID, switchToTaskID: preferredTaskID)
    }

    @discardableResult
    func moveCurrentTaskToBackground() -> UUID? {
        taskUseCases.moveCurrentTaskToBackground()
    }

    @discardableResult
    func moveTaskToBackground(id taskID: UUID) -> UUID? {
        taskUseCases.moveTaskToBackground(id: taskID)
    }

    func createDraftFromImportText(sourceType: ImportSourceType = .text) async {
        let trimmed = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        let admission = taskIntakeLimiter.beginParse(
            textLength: trimmed.count,
            draftItemCount: snapshot.importDraftItems.count,
            currentTaskCount: snapshot.tasks.count
        )
        applyTaskIntakeAdmission(admission)
        guard admission.admitted else {
            importErrorMessage = admission.message
            persist(event: "task_intake.rejected", details: admission.message ?? "parse")
            return
        }

        defer {
            applyTaskIntakeAdmission(taskIntakeLimiter.finish())
        }
        await importUseCases.createDraftFromImportText(sourceType: sourceType)
    }

    func transcribeAudioImport(from url: URL) async {
        await importUseCases.transcribeAudioImport(from: url)
    }

    func updateDraftItemTitle(id: UUID, title: String) {
        importUseCases.updateDraftItemTitle(id: id, title: title)
    }

    func applyDraftItemDraft(_ draft: DraftItemSnapshotDraft, to draftItemID: UUID) {
        importUseCases.applyDraftItemDraft(draft, to: draftItemID)
    }

    func toggleDraftItemAccepted(id: UUID) {
        importUseCases.toggleDraftItemAccepted(id: id)
    }

    func commitLatestDraft() {
        let acceptedItems = latestDraftItems.filter(\.isAccepted)
        let admission = taskIntakeLimiter.beginCommit(
            acceptedItemCount: acceptedItems.count,
            currentTaskCount: snapshot.tasks.count
        )
        applyTaskIntakeAdmission(admission)
        guard admission.admitted else {
            importErrorMessage = admission.message
            persist(event: "task_intake.rejected", details: admission.message ?? "commit")
            return
        }

        defer {
            applyTaskIntakeAdmission(taskIntakeLimiter.finish())
        }
        importUseCases.commitLatestDraft()
    }

    func updateMindMapDocument(
        dataJSON: String? = nil,
        configJSON: String? = nil,
        localConfigJSON: String? = nil,
        language: String? = nil
    ) {
        syncUseCases.updateMindMapDocument(
            dataJSON: dataJSON,
            configJSON: configJSON,
            localConfigJSON: localConfigJSON,
            language: language
        )
    }

    func setPetHovering(_ hovering: Bool) {
        isPetHovering = hovering
        refreshPetState()
    }

    func noteExternalInput(at date: Date = .now) {
        lastExternalInputAt = date
        refreshPetState()

        inputIdleTask?.cancel()
        inputIdleTask = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(1600))
            await MainActor.run {
                guard let self, self.lastExternalInputAt == date else { return }
                self.refreshPetState()
            }
        }
    }

    func toggleLowDistractionMode() {
        snapshot.preferences.lowDistractionMode.toggle()
        persist(event: "preferences.low_distraction", details: "\(snapshot.preferences.lowDistractionMode)", scope: .preferencesDomain)
        refreshPetState()
    }

    func updatePetPlacement(edge: PetEdge, centerY: CGFloat) {
        snapshot.preferences.petEdge = edge
        snapshot.preferences.petOffsetY = centerY
        persist(event: "preferences.pet_placement", details: "\(edge.rawValue):\(centerY)", scope: .preferencesDomain)
        refreshPetState()
    }

    func updateImportAnalysisProvider(_ provider: ImportAnalysisProvider) {
        importRuntimeCoordinator.updateImportAnalysisProvider(provider)
    }

    func updateImportAnalysisBaseURL(_ baseURL: String) {
        importRuntimeCoordinator.updateImportAnalysisBaseURL(baseURL)
    }

    func updateImportAnalysisModelName(_ modelName: String) {
        importRuntimeCoordinator.updateImportAnalysisModelName(modelName)
    }

    func updateImportAnalysisModelFilePath(_ modelFilePath: String) {
        importRuntimeCoordinator.updateImportAnalysisModelFilePath(modelFilePath)
    }

    func updateImportAnalysisAPIKey(_ apiKey: String) {
        importRuntimeCoordinator.updateImportAnalysisAPIKey(apiKey)
    }

    func chooseImportAnalysisModelFile() {
        importRuntimeCoordinator.chooseImportAnalysisModelFile()
    }

    func autodetectLocalImportModel() async {
        await importRuntimeCoordinator.autodetectLocalImportModel()
    }

    func prepareEmbeddedImportRuntimeIfNeeded() async {
        await importRuntimeCoordinator.prepareEmbeddedImportRuntimeIfNeeded()
    }

    private func finishLocalImportBootstrap() async {
        await importRuntimeCoordinator.finishLocalImportBootstrap()
    }

    private func refreshPetState() {
        petState = PetStateMachine.resolve(
            snapshot: snapshot,
            isHovering: isPetHovering,
            lastExternalInputAt: lastExternalInputAt
        )
    }

    private func withMutableTaskUseCasesState(_ mutate: (inout TaskUseCases.State) -> Void) {
        var state = TaskUseCases.State(
            snapshot: snapshot,
            priorityPromptTaskID: priorityPromptTaskID
        )
        mutate(&state)
        snapshot = state.snapshot
        priorityPromptTaskID = state.priorityPromptTaskID
    }

    private func withMutableImportUseCasesState(_ mutate: (inout ImportUseCases.State) -> Void) {
        var state = ImportUseCases.State(
            snapshot: snapshot,
            importText: importText,
            isImportParsing: isImportParsing,
            isAudioTranscribing: isAudioTranscribing,
            importErrorMessage: importErrorMessage,
            importRuntimeNote: importRuntimeNote
        )
        mutate(&state)
        snapshot = state.snapshot
        importText = state.importText
        isImportParsing = state.isImportParsing
        isAudioTranscribing = state.isAudioTranscribing
        importErrorMessage = state.importErrorMessage
        importRuntimeNote = state.importRuntimeNote
    }

    private func withMutableSyncUseCasesState(_ mutate: (inout SyncUseCases.State) -> Void) {
        var state = SyncUseCases.State(
            snapshot: snapshot,
            priorityPromptTaskID: priorityPromptTaskID
        )
        mutate(&state)
        snapshot = state.snapshot
        priorityPromptTaskID = state.priorityPromptTaskID
    }

    private func withMutableImportRuntimeState(_ mutate: (inout ImportRuntimeCoordinator.State) -> Void) {
        var state = ImportRuntimeCoordinator.State(
            snapshot: snapshot,
            importRuntimeNote: importRuntimeNote,
            localImportRuntimeStatus: localImportRuntimeStatus,
            localImportRuntimeStatusIsError: localImportRuntimeStatusIsError,
            isPreparingLocalImportRuntime: isPreparingLocalImportRuntime
        )
        mutate(&state)
        snapshot = state.snapshot
        importRuntimeNote = state.importRuntimeNote
        localImportRuntimeStatus = state.localImportRuntimeStatus
        localImportRuntimeStatusIsError = state.localImportRuntimeStatusIsError
        isPreparingLocalImportRuntime = state.isPreparingLocalImportRuntime
    }

    private func applyTaskIntakeAdmission(_ admission: TaskIntakeLimiter.Admission) {
        taskIntakeQueueDepth = admission.queueDepth
        isTaskIntakeBusy = admission.isBusy
    }

    private func persist(event: String, details: String, scope: PersistenceScope = []) {
        if !scope.isEmpty {
            scheduleSave(scope: scope)
        }
        let repository = repository
        _Concurrency.Task(priority: .utility) {
            await repository.appendEvent(event, details: details)
        }
    }

    private func scheduleSave(scope: PersistenceScope = .full) {
        let snapshot = snapshot
        let persistenceCoordinator = persistenceCoordinator
        saveGeneration += 1
        let generation = saveGeneration
        _Concurrency.Task(priority: .utility) {
            await persistenceCoordinator.scheduleSave(snapshot: snapshot, generation: generation, scope: scope)
        }
    }

    private func startAutosaveTimer() {
        autosaveTimer?.invalidate()
        autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            _Concurrency.Task { @MainActor [weak self] in
                guard let self else { return }
                let nextPetState = PetStateMachine.resolve(
                    snapshot: self.snapshot,
                    isHovering: self.isPetHovering,
                    lastExternalInputAt: self.lastExternalInputAt
                )
                if self.petState != nextPetState {
                    self.petState = nextPetState
                }
            }
        }
    }
}
