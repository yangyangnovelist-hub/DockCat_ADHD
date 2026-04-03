import AppKit
import Foundation
import Combine
import AppFlowyDocumentBridge
import UniformTypeIdentifiers

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

    private let repository: AppRepository
    private let appleRemindersBridge: AppleRemindersBridge
    private var saveTask: _Concurrency.Task<Void, Never>?
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
            self.persist(event: event, details: details)
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
            self.persist(event: event, details: details)
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
            self.persist(event: event, details: details)
        },
        refreshPetState: { [unowned self] in
            self.refreshPetState()
        }
    )

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

        _Concurrency.Task(priority: .utility) { [repository] in
            let restored = await repository.loadSnapshot()
            await MainActor.run {
                let (sanitizedSnapshot, didSanitizeSnapshot) = Self.sanitizeRestoredSnapshot(restored)
                self.snapshot = sanitizedSnapshot
                let didReconcileMindMap = self.syncUseCases.reconcileMindMapAndTasksOnRestore()
                self.importText = sanitizedSnapshot.importDrafts.last?.rawText ?? Self.seedImportText
                self.refreshPetState(shouldPersist: false)
                self.startAutosaveTimer()
                if didSanitizeSnapshot || didReconcileMindMap {
                    self.scheduleSave()
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

    func draftItem(id: UUID?) -> ImportDraftItem? {
        snapshot.importDraftItems.first { $0.id == id }
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

    func updateImportAnalysisProvider(_ provider: ImportAnalysisProvider) {
        snapshot.preferences.importAnalysis.provider = provider
        persist(event: "preferences.import_analysis.provider", details: provider.rawValue)
        if provider == .ollama {
            _Concurrency.Task { [weak self] in
                await self?.autoconfigureLocalImportModelIfNeeded()
                await self?.prepareEmbeddedImportRuntimeIfNeeded()
            }
        }
    }

    func updateImportAnalysisBaseURL(_ baseURL: String) {
        snapshot.preferences.importAnalysis.baseURL = baseURL
        persist(event: "preferences.import_analysis.base_url", details: baseURL)
    }

    func updateImportAnalysisModelName(_ modelName: String) {
        snapshot.preferences.importAnalysis.modelName = modelName
        persist(event: "preferences.import_analysis.model", details: modelName)
    }

    func updateImportAnalysisModelFilePath(_ modelFilePath: String) {
        snapshot.preferences.importAnalysis.modelFilePath = modelFilePath
        persist(event: "preferences.import_analysis.model_file", details: modelFilePath)

        if snapshot.preferences.importAnalysis.provider == .ollama {
            _Concurrency.Task { [weak self] in
                await self?.prepareEmbeddedImportRuntimeIfNeeded()
            }
        }
    }

    func updateImportAnalysisAPIKey(_ apiKey: String) {
        snapshot.preferences.importAnalysis.apiKey = apiKey
        persist(event: "preferences.import_analysis.api_key", details: apiKey.isEmpty ? "empty" : "set")
    }

    func chooseImportAnalysisModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择 GGUF"
        panel.title = "选择本地 GGUF 模型文件"
        panel.message = "DockCat 会记住这份 GGUF 文件路径，之后直接用于任务分析。"
        if let ggufType = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [ggufType]
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        snapshot.preferences.importAnalysis.provider = .ollama
        snapshot.preferences.importAnalysis.baseURL = ""
        snapshot.preferences.importAnalysis.apiKey = ""
        snapshot.preferences.importAnalysis.modelFilePath = selectedURL.path
        if snapshot.preferences.importAnalysis.trimmedModelName.isEmpty {
            snapshot.preferences.importAnalysis.modelName = selectedURL.deletingPathExtension().lastPathComponent
        }
        persist(event: "preferences.import_analysis.model_file.picked", details: selectedURL.path)

        _Concurrency.Task { [weak self] in
            await self?.prepareEmbeddedImportRuntimeIfNeeded()
        }
    }

    func autodetectLocalImportModel() async {
        guard let selection = await OllamaCatalog.shared.preferredTaskImportSelection() else {
            localImportRuntimeStatus = "未在 ~/.ollama/models 中发现可用的 GGUF 模型"
            localImportRuntimeStatusIsError = true
            return
        }

        snapshot.preferences.importAnalysis.provider = .ollama
        snapshot.preferences.importAnalysis.baseURL = ""
        snapshot.preferences.importAnalysis.modelName = selection.name
        snapshot.preferences.importAnalysis.modelFilePath = selection.fileURL.path
        snapshot.preferences.importAnalysis.apiKey = ""
        importRuntimeNote = "已连接本机 GGUF 模型：\(selection.name)"
        localImportRuntimeStatus = "已锁定模型文件：\(selection.fileURL.lastPathComponent)"
        localImportRuntimeStatusIsError = false
        persist(event: "preferences.import_analysis.autoconfigured", details: selection.name)

        await prepareEmbeddedImportRuntimeIfNeeded()
    }

    func prepareEmbeddedImportRuntimeIfNeeded() async {
        let preference = snapshot.preferences.importAnalysis
        guard preference.provider == .ollama else {
            localImportRuntimeStatus = nil
            localImportRuntimeStatusIsError = false
            return
        }

        let modelPath = preference.trimmedModelFilePath
        guard !modelPath.isEmpty else {
            localImportRuntimeStatus = "请选择 GGUF 文件，或使用自动检测写入固定路径"
            localImportRuntimeStatusIsError = true
            return
        }

        isPreparingLocalImportRuntime = true
        localImportRuntimeStatus = "正在准备内嵌运行时…"
        localImportRuntimeStatusIsError = false

        do {
            let cliURL = try await EmbeddedLlamaRuntime.shared.prepareRuntime()
            localImportRuntimeStatus = "内嵌运行时已就绪：\(cliURL.lastPathComponent) · 模型 \(URL(fileURLWithPath: modelPath).lastPathComponent)"
            localImportRuntimeStatusIsError = false
        } catch {
            localImportRuntimeStatus = "内嵌运行时准备失败：\(error.localizedDescription)"
            localImportRuntimeStatusIsError = true
        }

        isPreparingLocalImportRuntime = false
    }

    private func finishLocalImportBootstrap() async {
        await autoconfigureLocalImportModelIfNeeded()
        await prepareEmbeddedImportRuntimeIfNeeded()
    }

    private func autoconfigureLocalImportModelIfNeeded() async {
        let currentPreference = await MainActor.run { snapshot.preferences.importAnalysis }
        guard currentPreference.provider == .disabled
            || (currentPreference.trimmedModelName.isEmpty && currentPreference.trimmedModelFilePath.isEmpty) else {
            return
        }

        guard let selection = await OllamaCatalog.shared.preferredTaskImportSelection() else {
            return
        }

        await MainActor.run {
            let latestPreference = snapshot.preferences.importAnalysis
            guard latestPreference.provider == .disabled
                || (latestPreference.trimmedModelName.isEmpty && latestPreference.trimmedModelFilePath.isEmpty) else {
                return
            }

            snapshot.preferences.importAnalysis.provider = .ollama
            snapshot.preferences.importAnalysis.baseURL = ""
            snapshot.preferences.importAnalysis.modelName = selection.name
            snapshot.preferences.importAnalysis.modelFilePath = selection.fileURL.path
            snapshot.preferences.importAnalysis.apiKey = ""
            importRuntimeNote = "已自动连接本机 GGUF 模型：\(selection.name)"
            localImportRuntimeStatus = "已锁定模型文件：\(selection.fileURL.lastPathComponent)"
            localImportRuntimeStatusIsError = false
            persist(event: "preferences.import_analysis.autoconfigured", details: selection.name)
        }
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

    private func persist(event: String, details: String) {
        scheduleSave()
        let repository = repository
        _Concurrency.Task(priority: .utility) {
            await repository.appendEvent(event, details: details)
        }
    }

    private func scheduleSave() {
        let snapshot = snapshot
        let repository = repository
        saveGeneration += 1
        let generation = saveGeneration
        saveTask?.cancel()
        saveTask = _Concurrency.Task(priority: .utility) {
            guard !_Concurrency.Task.isCancelled else { return }
            await repository.saveSnapshot(snapshot, generation: generation)
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
