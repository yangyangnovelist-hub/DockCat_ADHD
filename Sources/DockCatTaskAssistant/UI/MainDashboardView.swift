import SwiftUI
import CompactSlider
import SplitView

struct MainDashboardView: View {
    @ObservedObject var appModel: AppModel

    private let dashboardDesignSize = CGSize(width: 1360, height: 820)
    @StateObject private var microphoneCapture = MicrophoneCaptureService()
    @StateObject private var dashboardSplitFraction = FractionHolder.usingUserDefaults(0.36, key: "dashboard.mainSplitFraction")
    @State private var quickTaskTitle = ""
    @State private var selectedTaskID: UUID?
    @State private var expandedTaskID: UUID?
    @State private var canvasMode: TaskCanvasMode = .list
    @State private var canvasTimeRange: TaskCanvasTimeRange = .today
    @State private var taskDraft = TaskSnapshotDraft(
        title: "",
        notes: "",
        status: .todo,
        urgencyValue: 50,
        importanceValue: 50,
        quadrant: nil,
        estimatedMinutes: 25,
        dueAt: Date(),
        hasDueDate: false,
        tagsText: "",
        smartEntries: SmartFieldKey.allCases.map(SmartEntry.empty)
    )
    var body: some View {
        GeometryReader { proxy in
            let availableCanvasSize = CGSize(
                width: max(proxy.size.width - (dashboardCanvasOuterPadding * 2), 1),
                height: max(proxy.size.height - (dashboardCanvasOuterPadding * 2), 1)
            )
            let canvasScale = dashboardCanvasScale(for: availableCanvasSize)
            let canvasSize = dashboardCanvasSize(for: availableCanvasSize, scale: canvasScale)

            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [
                        TaskBoardPalette.canvas,
                        Color.white.opacity(0.92),
                        TaskBoardPalette.canvasAlt,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                dashboardCanvas(canvasSize: canvasSize)
                    .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
                    .scaleEffect(canvasScale, anchor: .topLeading)
                    .frame(width: availableCanvasSize.width, height: availableCanvasSize.height, alignment: .topLeading)
                    .padding(dashboardCanvasOuterPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear {
                clampDashboardSplitFraction(for: dashboardContentWidth(for: canvasSize))
            }
            .onChange(of: proxy.size) { newValue in
                let nextAvailableCanvasSize = CGSize(
                    width: max(newValue.width - (dashboardCanvasOuterPadding * 2), 1),
                    height: max(newValue.height - (dashboardCanvasOuterPadding * 2), 1)
                )
                let nextScale = dashboardCanvasScale(for: nextAvailableCanvasSize)
                let nextCanvasSize = dashboardCanvasSize(for: nextAvailableCanvasSize, scale: nextScale)
                clampDashboardSplitFraction(for: dashboardContentWidth(for: nextCanvasSize))
            }
        }
        .onAppear {
            appModel.bootstrapIfNeeded()
            selectedTaskID = selectedTaskID ?? appModel.currentTask?.id ?? appModel.tasks.first?.id
            syncSelectionForPriorityPrompt(appModel.priorityPromptTaskID)
        }
        .onChange(of: appModel.snapshot.selectedTaskID) { newValue in
            guard selectedTaskID != newValue else { return }
            selectedTaskID = newValue
        }
        .onChange(of: expandedTaskID) { newValue in
            loadDraft(for: newValue)
        }
        .onChange(of: appModel.priorityPromptTaskID) { newValue in
            syncSelectionForPriorityPrompt(newValue)
        }
        .sheet(isPresented: priorityPromptIsPresented) {
            priorityPromptSheet
        }
    }

    private func dashboardCanvas(canvasSize: CGSize) -> some View {
        let splitConfig = dashboardSplitConfig(for: dashboardContentWidth(for: canvasSize))

        return taskInputColumn(importHeight: dashboardImportHeight(for: canvasSize))
            .split(.Horizontal, fraction: dashboardSplitFraction, config: splitConfig) {
                taskTreeColumn
            }
            .padding(.horizontal, dashboardHorizontalPadding(for: canvasSize))
            .padding(.vertical, dashboardVerticalPadding(for: canvasSize))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func dashboardHorizontalPadding(for canvasSize: CGSize) -> CGFloat {
        max(4, min(canvasSize.width * 0.004, 8))
    }

    private func dashboardVerticalPadding(for canvasSize: CGSize) -> CGFloat {
        max(4, min(canvasSize.height * 0.005, 8))
    }

    private func dashboardImportHeight(for canvasSize: CGSize) -> CGFloat {
        min(max(canvasSize.height * 0.11, 84), 132)
    }

    private func dashboardContentWidth(for canvasSize: CGSize) -> CGFloat {
        max(canvasSize.width - (dashboardHorizontalPadding(for: canvasSize) * 2), 1)
    }

    private var dashboardCanvasOuterPadding: CGFloat {
        2
    }

    private func dashboardCanvasScale(for availableSize: CGSize) -> CGFloat {
        let widthScale = max(availableSize.width / dashboardDesignSize.width, 0.01)
        let heightScale = max(availableSize.height / dashboardDesignSize.height, 0.01)
        return min(widthScale, heightScale)
    }

    private func dashboardCanvasSize(for availableSize: CGSize, scale: CGFloat) -> CGSize {
        CGSize(
            width: max(dashboardDesignSize.width, availableSize.width / max(scale, 0.01)),
            height: max(dashboardDesignSize.height, availableSize.height / max(scale, 0.01))
        )
    }

    private func taskInputColumn(importHeight: CGFloat) -> some View {
        GeometryReader { proxy in
            let columnWidth = proxy.size.width
            let columnHeight = proxy.size.height
            let embeddedContentWidth = max(columnWidth - 28, 1)

            ScrollView {
                PaperCard(tint: Color.white.opacity(0.82), cornerRadius: 28, padding: 14) {
                    currentTaskCardContent(availableWidth: embeddedContentWidth)

                    Divider()
                        .overlay(TaskBoardPalette.line)
                        .padding(.vertical, 2)

                    quickAddSectionContent(importHeight: importHeight, availableWidth: embeddedContentWidth)

                    Divider()
                        .overlay(TaskBoardPalette.line)
                        .padding(.vertical, 2)

                    inputStatusPanelContent(availableWidth: embeddedContentWidth)
                }
                .frame(maxWidth: .infinity, minHeight: columnHeight, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .scrollIndicators(.never)
        }
    }

    private var taskTreeColumn: some View {
        TaskCanvasView(
            appModel: appModel,
            selectedTaskID: $selectedTaskID,
            expandedTaskID: $expandedTaskID,
            draft: $taskDraft,
            mode: $canvasMode,
            timeRange: $canvasTimeRange,
            onSelectTask: selectTask,
            onExpandTask: expandTaskDrawer
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func dashboardSplitConfig(for availableWidth: CGFloat) -> SplitConfig {
        let minimumPaneWidths = dashboardMinimumPaneWidths(for: availableWidth)

        return SplitConfig(
            minPFraction: minimumPaneWidths.primary / max(availableWidth, 1),
            minSFraction: minimumPaneWidths.secondary / max(availableWidth, 1),
            color: TaskBoardPalette.line.opacity(0.92),
            inset: 10,
            visibleThickness: 6,
            invisibleThickness: 24
        )
    }

    private func dashboardMinimumPaneWidths(for availableWidth: CGFloat) -> (primary: CGFloat, secondary: CGFloat) {
        let width = max(availableWidth, 1)
        let compactPrimary: CGFloat = 220
        let relaxedPrimary: CGFloat = 320
        let compactSecondary: CGFloat = 300
        let relaxedSecondary: CGFloat = 560
        let progress = min(max((width - 360) / 760, 0), 1)
        let desiredPrimary = compactPrimary + ((relaxedPrimary - compactPrimary) * progress)
        let desiredSecondary = compactSecondary + ((relaxedSecondary - compactSecondary) * progress)
        let reservedBreathingRoom = min(max(width * 0.08, 18), 72)
        let maxCombinedMinimums = max(width - reservedBreathingRoom, 0)
        let combinedDesiredMinimums = desiredPrimary + desiredSecondary
        let shrinkRatio = combinedDesiredMinimums > maxCombinedMinimums && combinedDesiredMinimums > 0
            ? maxCombinedMinimums / combinedDesiredMinimums
            : 1

        return (
            primary: desiredPrimary * shrinkRatio,
            secondary: desiredSecondary * shrinkRatio
        )
    }

    private func clampDashboardSplitFraction(for availableWidth: CGFloat) {
        let splitConfig = dashboardSplitConfig(for: availableWidth)
        let minimumPrimaryFraction = splitConfig.minPFraction ?? 0
        let maximumPrimaryFraction = max(minimumPrimaryFraction, 1 - (splitConfig.minSFraction ?? 0))
        let preferredRange = preferredDashboardSplitRange(
            for: availableWidth,
            minimumPrimaryFraction: minimumPrimaryFraction,
            maximumPrimaryFraction: maximumPrimaryFraction
        )
        let correctedFraction = min(preferredRange.upperBound, max(preferredRange.lowerBound, dashboardSplitFraction.value))
        let clampedFraction = min(maximumPrimaryFraction, max(minimumPrimaryFraction, correctedFraction))

        guard abs(clampedFraction - dashboardSplitFraction.value) > 0.0001 else { return }
        dashboardSplitFraction.value = clampedFraction
    }

    private func preferredDashboardSplitRange(
        for availableWidth: CGFloat,
        minimumPrimaryFraction: CGFloat,
        maximumPrimaryFraction: CGFloat
    ) -> ClosedRange<CGFloat> {
        let lowerPrimaryFraction = min(maximumPrimaryFraction, max(minimumPrimaryFraction, 0.20))
        let upperPrimaryFraction = min(maximumPrimaryFraction, max(lowerPrimaryFraction, 0.25))
        return lowerPrimaryFraction...upperPrimaryFraction
    }

    private func inputStatusPanel(availableWidth: CGFloat) -> some View {
        PaperCard(tint: Color.white.opacity(0.82)) {
            inputStatusPanelContent(availableWidth: availableWidth)
        }
        .frame(maxWidth: .infinity)
    }

    private func inputStatusPanelContent(availableWidth: CGFloat) -> some View {
        let metricsUseSingleColumn = availableWidth < 390
        let metricColumns: [GridItem] = metricsUseSingleColumn
            ? [GridItem(.flexible(), spacing: 10)]
            : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        let completedTasks = recentCompletedTasks

        return VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    Text("任务记录")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(TaskBoardPalette.ink)

                    Spacer(minLength: 0)

                    compactTimeRangePicker
                        .frame(width: 208)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("任务记录")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(TaskBoardPalette.ink)

                    compactTimeRangePicker
                }
            }

            LazyVGrid(columns: metricColumns, spacing: 10) {
                metricCard(title: "已完成", value: "\(appModel.todayStats.completedCount)")
                metricCard(
                    title: "后台进行中",
                    value: "\(appModel.backgroundTasks.filter { $0.status == .doing }.count)"
                )
                metricCard(title: "待处理", value: "\(appModel.tasks.filter { $0.status != .done && $0.status != .archived }.count)")
            }

            Divider()
                .overlay(TaskBoardPalette.line)
                .padding(.top, 2)

            Button {
                withAnimation(taskDetailDrawerAnimation) {
                    canvasMode = .recentCompleted
                }
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Text("最近完成")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(TaskBoardPalette.ink)

                    Spacer(minLength: 0)

                    StatusBadge(title: "\(completedTasks.count) 条", color: TaskBoardPalette.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(TaskBoardPalette.canvas.opacity(0.56), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func currentTaskCard(availableWidth: CGFloat) -> some View {
        PaperCard(tint: Color.white.opacity(0.84)) {
            currentTaskCardContent(availableWidth: availableWidth)
        }
        .frame(maxWidth: .infinity)
    }

    private func currentTaskCardContent(availableWidth: CGFloat) -> some View {
        let avatarSize: CGFloat
        if availableWidth < 320 {
            avatarSize = 100
        } else if availableWidth < 420 {
            avatarSize = 118
        } else {
            avatarSize = 132
        }
        let horizontalContentWidth = max(availableWidth - 36, 1)
        let summaryWidth = max(horizontalContentWidth - avatarSize - 14, 120)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                CatAvatarView(size: avatarSize)

                currentTaskSummary
                    .frame(width: summaryWidth, alignment: .leading)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    completeCurrentTaskButton
                    backgroundCurrentTaskButton
                }

                VStack(spacing: 8) {
                    completeCurrentTaskButton
                        .frame(maxWidth: .infinity)
                    backgroundCurrentTaskButton
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(TaskBoardPalette.accent)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    quickTaskField
                    quickTaskCreateButton
                }

                VStack(spacing: 10) {
                    quickTaskField
                    quickTaskCreateButton
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func quickAddSection(importHeight: CGFloat, availableWidth: CGFloat) -> some View {
        PaperCard(tint: TaskBoardPalette.paperSoft) {
            quickAddSectionContent(importHeight: importHeight, availableWidth: availableWidth)
        }
        .frame(maxWidth: .infinity)
    }

    private func quickAddSectionContent(importHeight: CGFloat, availableWidth: CGFloat) -> some View {
        let stacksImportStatusVertically = availableWidth < 380

        return VStack(alignment: .leading, spacing: 12) {
            Text("批量导入")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(TaskBoardPalette.ink)

            TextEditor(text: $appModel.importText)
                .scrollContentBackground(.hidden)
                .frame(height: importHeight)
                .padding(12)
                .background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    importActionButtons(stacksVertically: false)
                    Spacer(minLength: 0)
                    voiceImportButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    importActionButtons(stacksVertically: true)
                    voiceImportButton
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Group {
                if stacksImportStatusVertically {
                    VStack(alignment: .leading, spacing: 8) {
                        if let latestDraft = appModel.latestDraft {
                            BadgeFlow(spacing: 8, rowSpacing: 6) {
                                StatusBadge(title: latestDraft.parseStatus.rawValue, color: TaskBoardPalette.accentWarm)
                                StatusBadge(title: "\(appModel.latestDraftItems.count) 条", color: TaskBoardPalette.accent)
                            }
                        }

                        if microphoneCapture.isRecording {
                            StatusBadge(title: "录音中", color: .red)
                        }

                        StatusBadge(
                            title: "入口队列 \(appModel.taskIntakeQueueDepth)",
                            color: appModel.isTaskIntakeBusy ? TaskBoardPalette.accentWarm : TaskBoardPalette.quiet
                        )
                    }
                } else {
                    HStack(spacing: 8) {
                        if let latestDraft = appModel.latestDraft {
                            BadgeFlow(spacing: 8, rowSpacing: 6) {
                                StatusBadge(title: latestDraft.parseStatus.rawValue, color: TaskBoardPalette.accentWarm)
                                StatusBadge(title: "\(appModel.latestDraftItems.count) 条", color: TaskBoardPalette.accent)
                            }
                        }

                        Spacer()

                        if microphoneCapture.isRecording {
                            StatusBadge(title: "录音中", color: .red)
                        }

                        StatusBadge(
                            title: "入口队列 \(appModel.taskIntakeQueueDepth)",
                            color: appModel.isTaskIntakeBusy ? TaskBoardPalette.accentWarm : TaskBoardPalette.quiet
                        )
                    }
                }
            }

            if let statusMessage = microphoneCapture.statusMessage {
                Text(statusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(microphoneCapture.isRecording ? .red.opacity(0.82) : .black.opacity(0.56))
            }

            if let runtimeNote = appModel.importRuntimeNote?.nilIfEmpty {
                Text(runtimeNote)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.black.opacity(0.56))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = appModel.importErrorMessage?.nilIfEmpty {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metricCard(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black.opacity(0.48))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(TaskBoardPalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(TaskBoardPalette.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var completeCurrentTaskButton: some View {
        Button("完成") { completeCurrentTaskFromSummary() }
    }

    private var backgroundCurrentTaskButton: some View {
        Button("后台运行") { moveCurrentTaskToBackgroundFromSummary() }
    }

    private var quickTaskField: some View {
        TextField("添加新任务", text: $quickTaskTitle)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(TaskBoardPalette.canvas.opacity(0.75), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onSubmit(handleQuickTaskCreation)
    }

    private var quickTaskCreateButton: some View {
        Button {
            handleQuickTaskCreation()
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 16))
        }
        .buttonStyle(.borderedProminent)
        .tint(TaskBoardPalette.accent)
        .disabled(quickTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var compactTimeRangePicker: some View {
        Picker("", selection: $canvasTimeRange) {
            ForEach(TaskCanvasTimeRange.allCases) { range in
                Text(range.title).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var currentTaskSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("当前焦点")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.5))

                Spacer(minLength: 0)

                StatusBadge(title: appModel.petState.title, color: TaskBoardPalette.accentWarm)
            }

            TaskHeaderBlock {
                Text(appModel.currentTask?.title ?? "还没有当前任务")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(TaskBoardPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            } badges: {
                currentTaskStateBadges
            }

            BadgeFlow(spacing: 8, rowSpacing: 6) {
                petStateBadges
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentCompletedTasks: [Task] {
        appModel.tasks
            .filter { task in
                guard task.status == .done, let completedAt = task.completedAt else { return false }
                return canvasTimeRange.contains(completedAt)
            }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(4)
            .map { $0 }
    }

    @ViewBuilder
    private var currentTaskStateBadges: some View {
        if let currentTask = appModel.currentTask {
            StatusBadge(
                title: currentTask.status.title,
                color: currentTask.status == .doing ? TaskBoardPalette.accent : TaskBoardPalette.accentWarm
            )
            StatusBadge(title: currentTask.quadrant?.title ?? "无", color: TaskBoardPalette.accentWarm)
            if appModel.isBackgroundTask(currentTask.id) {
                StatusBadge(title: "后台运行", color: TaskBoardPalette.quiet)
            }
        }
    }

    @ViewBuilder
    private var petStateBadges: some View {
        let backgroundCount = appModel.backgroundTasks.filter { $0.status == .doing && $0.id != appModel.currentTask?.id }.count
        if backgroundCount > 0 {
            StatusBadge(title: "\(backgroundCount) 个后台进行中", color: TaskBoardPalette.quiet)
        }
    }

    private func importActionButtons(stacksVertically: Bool) -> some View {
        Group {
            if stacksVertically {
                VStack(alignment: .leading, spacing: 8) {
                    importRecognitionButton
                    importCommitButton
                }
            } else {
                HStack(spacing: 10) {
                    importRecognitionButton
                    importCommitButton
                }
            }
        }
    }

    private var importRecognitionButton: some View {
        Button(appModel.isImportParsing ? "识别中..." : "识别任务") {
            _Concurrency.Task {
                await appModel.createDraftFromImportText()
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(TaskBoardPalette.accentWarm)
        .disabled(appModel.isTaskIntakeBusy || appModel.isImportParsing || appModel.importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var importCommitButton: some View {
        Button("确认导入") {
            appModel.commitLatestDraft()
            selectedTaskID = appModel.currentTask?.id ?? appModel.tasks.first?.id
        }
        .buttonStyle(.bordered)
        .disabled(appModel.isTaskIntakeBusy || appModel.latestDraftItems.isEmpty)
    }

    private var voiceImportButton: some View {
        Button {
            handleQuickVoiceCapture()
        } label: {
            Label(
                microphoneCapture.isRecording ? "停止录音" : "语音导入",
                systemImage: microphoneCapture.isRecording ? "stop.circle.fill" : "mic.fill"
            )
            .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .tint(microphoneCapture.isRecording ? .red.opacity(0.86) : TaskBoardPalette.accent)
        .disabled(appModel.isTaskIntakeBusy && !microphoneCapture.isRecording)
    }

    private func handleQuickVoiceCapture() {
        _Concurrency.Task {
            do {
                if microphoneCapture.isRecording {
                    guard let recordedURL = try await microphoneCapture.stopRecording() else { return }
                    await appModel.transcribeAudioImport(from: recordedURL)
                    await MainActor.run {
                        microphoneCapture.statusMessage = "语音已完成转写。"
                    }
                } else {
                    try await microphoneCapture.startRecording()
                }
            } catch {
                await MainActor.run {
                    microphoneCapture.statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func loadDraft(for taskID: UUID?) {
        guard let taskID, let loaded = appModel.buildTaskDraft(for: taskID) else { return }
        taskDraft = loaded
    }

    private func handleQuickTaskCreation() {
        // 有选中任务 → 添加同级（相同 parentTaskID）；无选中 → 添加根任务
        let parentTaskID = appModel.task(id: selectedTaskID)?.parentTaskID ?? nil
        guard let createdTaskID = appModel.addTask(
            title: quickTaskTitle,
            parentTaskID: selectedTaskID == nil ? nil : parentTaskID,
            promptForPriority: true
        ) else { return }
        quickTaskTitle = ""
        selectedTaskID = createdTaskID
        expandedTaskID = createdTaskID
    }

    private func completeCurrentTaskFromSummary() {
        let previousCurrentID = appModel.currentTask?.id
        let nextTaskID = appModel.completeCurrentTask()

        guard expandedTaskID == previousCurrentID else { return }
        guard let nextTaskID, nextTaskID != previousCurrentID else {
            expandedTaskID = nil
            return
        }

        expandedTaskID = nextTaskID
        loadDraft(for: nextTaskID)
    }

    private func moveCurrentTaskToBackgroundFromSummary() {
        let previousCurrentID = appModel.currentTask?.id
        let nextTaskID = appModel.moveCurrentTaskToBackground()

        guard expandedTaskID == previousCurrentID else { return }
        guard let nextTaskID, nextTaskID != previousCurrentID else {
            expandedTaskID = nil
            return
        }

        expandedTaskID = nextTaskID
        loadDraft(for: nextTaskID)
    }

    private func selectTask(_ taskID: UUID) {
        selectedTaskID = taskID
        // 仅对进行中的任务更新 currentTask，已完成任务只做视觉选中，不恢复状态
        if let task = appModel.task(id: taskID), task.status != .done {
            appModel.setCurrentTask(id: taskID)
        }
    }

    private func expandTaskDrawer(for taskID: UUID) {
        selectTask(taskID)
        expandedTaskID = taskID
        loadDraft(for: taskID)
    }

    private var priorityPromptIsPresented: Binding<Bool> {
        Binding(
            get: { appModel.priorityPromptTaskID != nil },
            set: { isPresented in
                if !isPresented {
                    appModel.dismissPriorityPrompt()
                }
            }
        )
    }

    @ViewBuilder
    private var priorityPromptSheet: some View {
        if let taskID = appModel.priorityPromptTaskID,
           let task = appModel.task(id: taskID) {
            TaskPrioritySelectionSheet(
                taskTitle: task.title,
                initialUrgencyValue: task.urgencyValue,
                initialImportanceValue: task.importanceValue,
                initialQuadrant: task.quadrant,
                onConfirm: { urgencyValue, importanceValue in
                    appModel.applyPrioritySelection(
                        for: taskID,
                        urgencyValue: urgencyValue,
                        importanceValue: importanceValue
                    )
                    loadDraft(for: taskID)
                },
                onSkip: {
                    appModel.dismissPriorityPrompt()
                }
            )
        } else {
            Color.clear
                .frame(width: 1, height: 1)
        }
    }

    private func syncSelectionForPriorityPrompt(_ taskID: UUID?) {
        guard let taskID else { return }
        selectedTaskID = taskID
        expandedTaskID = taskID
        loadDraft(for: taskID)
    }
}

private struct TaskPrioritySelectionSheet: View {
    let taskTitle: String
    let initialQuadrant: TaskQuadrant?
    let onConfirm: (Double, Double) -> Void
    let onSkip: () -> Void

    @State private var urgencyValue: Double
    @State private var importanceValue: Double
    @State private var hasExplicitSelection: Bool

    init(
        taskTitle: String,
        initialUrgencyValue: Double,
        initialImportanceValue: Double,
        initialQuadrant: TaskQuadrant?,
        onConfirm: @escaping (Double, Double) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.taskTitle = taskTitle
        self.initialQuadrant = initialQuadrant
        self.onConfirm = onConfirm
        self.onSkip = onSkip
        _urgencyValue = State(initialValue: initialUrgencyValue)
        _importanceValue = State(initialValue: initialImportanceValue)
        _hasExplicitSelection = State(initialValue: initialQuadrant != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("先选任务优先级")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(TaskBoardPalette.ink)

            Text(taskTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black.opacity(0.68))
                .lineLimit(2)

            PriorityQuadrantPicker(
                urgencyValue: Binding(
                    get: { urgencyValue },
                    set: { newValue in
                        urgencyValue = newValue
                        hasExplicitSelection = true
                    }
                ),
                importanceValue: Binding(
                    get: { importanceValue },
                    set: { newValue in
                        importanceValue = newValue
                        hasExplicitSelection = true
                    }
                )
            )

            HStack(spacing: 8) {
                StatusBadge(title: selectedQuadrant?.title ?? "无", color: TaskBoardPalette.accentWarm)
                if !hasExplicitSelection {
                    Text("请先选择四象限，再进行计划。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.black.opacity(0.48))
                }
            }

            HStack {
                Button("稍后再选") {
                    onSkip()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("确认优先级") {
                    onConfirm(
                        PriorityVector.clampedPercentage(urgencyValue),
                        PriorityVector.clampedPercentage(importanceValue)
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(TaskBoardPalette.accent)
                .disabled(!hasExplicitSelection)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(
            LinearGradient(
                colors: [TaskBoardPalette.paper, Color.white.opacity(0.96), TaskBoardPalette.canvasAlt],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var selectedQuadrant: TaskQuadrant? {
        guard hasExplicitSelection else { return nil }
        return PriorityVector.quadrant(
            urgencyValue: PriorityVector.clampedPercentage(urgencyValue),
            importanceValue: PriorityVector.clampedPercentage(importanceValue)
        )
    }
}

private struct TaskDetailPanel: View {
    @ObservedObject var appModel: AppModel
    @Binding var selectedTaskID: UUID?
    @Binding var draft: TaskSnapshotDraft

    var body: some View {
        PaperCard(tint: TaskBoardPalette.paperSoft, cornerRadius: 28, padding: 0) {
            Group {
                if let selectedTaskID, let task = appModel.task(id: selectedTaskID) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            labeledField("任务名") {
                                TextField("任务名", text: $draft.title)
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }

                            labeledField("备注") {
                                TextEditor(text: $draft.notes)
                                    .frame(height: 104)
                                    .padding(10)
                                    .background(TaskBoardPalette.canvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }

                            Picker("状态", selection: $draft.status) {
                                ForEach(TaskStatus.activeCases, id: \.rawValue) { status in
                                    Text(status.title).tag(status)
                                }
                            }
                            .pickerStyle(.menu)

                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text("预估时间")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.black.opacity(0.55))
                                    Spacer()
                                    Text("\(draft.estimatedMinutes) 分钟")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(TaskBoardPalette.ink)
                                }

                                CompactSlider(
                                    value: Binding(
                                        get: { Double(draft.estimatedMinutes) },
                                        set: { draft.estimatedMinutes = Int($0.rounded()) }
                                    ),
                                    in: 5...240,
                                    step: 5
                                )
                                .compactSliderOptionsByAdding(.tapToSlide, .snapToSteps, .scrollWheel)
                                .accentColor(TaskBoardPalette.accent)
                                .frame(height: 42)

                                HStack {
                                    Text("5 分钟")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.black.opacity(0.44))
                                    Spacer()
                                    StatusBadge(title: draft.quadrant?.title ?? "无", color: TaskBoardPalette.accentWarm)
                                    Spacer()
                                    Text("240 分钟")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.black.opacity(0.44))
                                }
                            }

                            PriorityQuadrantPicker(
                                urgencyValue: Binding(
                                    get: { draft.urgencyValue },
                                    set: { newValue in
                                        draft.urgencyValue = newValue
                                        syncPriorityMetadata()
                                    }
                                ),
                                importanceValue: Binding(
                                    get: { draft.importanceValue },
                                    set: { newValue in
                                        draft.importanceValue = newValue
                                        syncPriorityMetadata()
                                    }
                                )
                            )

                            Toggle("设置截止日期", isOn: $draft.hasDueDate)
                            if draft.hasDueDate {
                                DatePicker("截止日期", selection: $draft.dueAt, displayedComponents: .date)
                            }

                            TextField("标签，逗号分隔", text: $draft.tagsText)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                            TaskSmartColumnsEditor(entries: $draft.smartEntries)

                            HStack {
                                Button("设为当前任务") {
                                    appModel.setCurrentTask(id: task.id)
                                }

                                Spacer()

                                Button("保存修改") {
                                    syncPriorityMetadata()
                                    appModel.applyTaskDraft(draft, to: task.id)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(TaskBoardPalette.accent)
                                .disabled(draft.quadrant == nil)
                            }

                            if draft.quadrant == nil {
                                Text("请先选择四象限，再继续计划。")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.black.opacity(0.48))
                            }
                        }
                        .padding(20)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("从中间选一个任务后，这里会直接展开编辑。")
                            .foregroundStyle(.black.opacity(0.56))
                        Spacer()
                    }
                    .padding(20)
                }
            }
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.black.opacity(0.55))
            content()
        }
    }

    private func syncPriorityMetadata() {
        draft.urgencyValue = PriorityVector.clampedPercentage(draft.urgencyValue)
        draft.importanceValue = PriorityVector.clampedPercentage(draft.importanceValue)
        draft.quadrant = PriorityVector.quadrant(
            urgencyValue: draft.urgencyValue,
            importanceValue: draft.importanceValue
        )
    }
}

struct TaskDetailWindowView: View {
    @ObservedObject var appModel: AppModel
    @State private var selectedTaskID: UUID?
    @State private var draft = TaskSnapshotDraft(
        title: "",
        notes: "",
        status: .todo,
        urgencyValue: 50,
        importanceValue: 50,
        quadrant: nil,
        estimatedMinutes: 25,
        dueAt: Date(),
        hasDueDate: false,
        tagsText: "",
        smartEntries: SmartFieldKey.allCases.map(SmartEntry.empty)
    )

    var body: some View {
        TaskDetailPanel(appModel: appModel, selectedTaskID: $selectedTaskID, draft: $draft)
            .padding(18)
            .background(
                LinearGradient(
                    colors: [TaskBoardPalette.canvas, Color.white.opacity(0.93), TaskBoardPalette.canvasAlt],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .onAppear {
                syncFromSelection(appModel.snapshot.selectedTaskID ?? appModel.currentTask?.id)
            }
            .onChange(of: appModel.snapshot.selectedTaskID) { newValue in
                syncFromSelection(newValue)
            }
    }

    private func syncFromSelection(_ taskID: UUID?) {
        selectedTaskID = taskID
        guard let taskID, let loaded = appModel.buildTaskDraft(for: taskID) else { return }
        draft = loaded
    }
}
