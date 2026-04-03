import SwiftUI

struct StickyTaskBoardView: View {
    @ObservedObject var appModel: AppModel
    var title: String = "Today"
    var subtitle: String = "点猫即可看到这张任务便签"
    var onClose: (() -> Void)?

    private let noteDesignSize = CGSize(width: 760, height: 600)
    @State private var selectedTaskID: UUID?
    @State private var expandedTaskID: UUID?
    @State private var renamingTaskID: UUID?
    @State private var renameTitle = ""
    @FocusState private var focusedRenameTaskID: UUID?
    @State private var suppressedExpansionTaskID: UUID?
    @State private var pressedTaskID: UUID?
    @State private var quickTaskTitle = ""
    @State private var showingCompletedSubtasks = false
    @State private var isSubtaskSectionExpanded = true
    @State private var completionSwitchDropIsTargeted = false
    @State private var rootSwitchPromptTaskID: UUID?
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

    private var filteredSubtasks: [Task] {
        guard let focusTask = appModel.currentTask ?? dockNoteRootTask else { return [] }
        return appModel.tasks.filter {
            guard $0.parentTaskID == focusTask.id else { return false }
            guard $0.status != .archived else { return false }
            return showingCompletedSubtasks ? $0.status == .done : $0.status != .done
        }
    }

    private var otherRootTasks: [Task] {
        let currentRootTaskID = rootAncestorID(for: appModel.currentTask?.id)
        return appModel.tasks.filter {
            $0.parentTaskID == nil &&
            $0.status != .done &&
            $0.status != .archived &&
            $0.id != currentRootTaskID
        }
    }

    private var backgroundMonitorTasks: [Task] {
        appModel.backgroundTasks.filter {
            $0.status == .doing && $0.id != appModel.currentTask?.id
        }
    }

    private var dockNoteRootTask: Task? {
        appModel.task(id: rootAncestorID(for: appModel.currentTask?.id)) ?? appModel.currentTask
    }

    private var rootSwitchPromptTask: Task? {
        appModel.task(id: rootSwitchPromptTaskID)
    }

    private var noteLabelWidth: CGFloat { 64 }

    var body: some View {
        GeometryReader { proxy in
            let availableCanvasSize = CGSize(
                width: max(proxy.size.width - (noteOuterPadding * 2), 1),
                height: max(proxy.size.height - (noteOuterPadding * 2), 1)
            )
            let noteScale = noteCanvasScale(for: availableCanvasSize)
            let noteCanvasSize = noteCanvasSize(for: availableCanvasSize, scale: noteScale)

            noteSurface
                .frame(width: noteCanvasSize.width, height: noteCanvasSize.height, alignment: .topLeading)
                .scaleEffect(noteScale, anchor: .topLeading)
                .frame(width: availableCanvasSize.width, height: availableCanvasSize.height, alignment: .topLeading)
                .padding(noteOuterPadding)
        }
        .onAppear {
            selectedTaskID = appModel.currentTask?.id
            expandedTaskID = nil
        }
        .onChange(of: focusedRenameTaskID) { newValue in
            if renamingTaskID != nil, newValue == nil {
                commitRename()
            }
        }
        .onChange(of: appModel.currentTask?.id) { newValue in
            if renamingTaskID == nil {
                selectedTaskID = newValue
            }
        }
    }

    private var noteSurface: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [
                    TaskBoardPalette.paper,
                    TaskBoardPalette.paperSoft,
                    Color.white.opacity(0.94),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            mainNote
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .trailing) {
                    if let expandedTaskID, let task = appModel.task(id: expandedTaskID) {
                        drawer(task: task)
                            .frame(width: 320)
                            .frame(maxHeight: .infinity)
                            .background(
                                Rectangle()
                                    .fill(Color.white.opacity(0.42))
                                    .overlay(alignment: .leading) {
                                        Rectangle()
                                            .fill(TaskBoardPalette.line)
                                            .frame(width: 1)
                                    }
                            )
                            .transition(taskDetailDrawerTransition)
                    }
                }

            if let task = rootSwitchPromptTask {
                rootTaskActionCard(for: task)
                    .padding(.top, 18)
                    .padding(.trailing, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if onClose != nil {
                Button(action: handleCloseButton) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black.opacity(0.56))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.8), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
        .animation(taskDetailDrawerAnimation, value: expandedTaskID)
        .overlay(alignment: .topLeading) {
            TapeAccent(rotation: -7)
                .padding(.leading, 30)
                .padding(.top, -10)
        }
        .overlay(alignment: .topTrailing) {
            TapeAccent(rotation: 8)
                .padding(.trailing, 56)
                .padding(.top, -12)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(TaskBoardPalette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.13), radius: 28, x: 0, y: 18)
    }

    private func rootTaskActionCard(for task: Task) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(TaskBoardPalette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Button("切换到这个母任务") {
                switchToRootTask(task.id)
            }
            .buttonStyle(.borderedProminent)
            .tint(TaskBoardPalette.accent)

            Button("编辑这个母任务") {
                editTask(task.id)
            }
            .buttonStyle(.bordered)

            Button("取消") {
                rootSwitchPromptTaskID = nil
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 220, alignment: .leading)
        .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(TaskBoardPalette.line, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 18, x: 0, y: 10)
    }

    private var noteOuterPadding: CGFloat { 0 }

    private func noteCanvasScale(for availableSize: CGSize) -> CGFloat {
        let widthScale = max(availableSize.width / noteDesignSize.width, 0.01)
        let heightScale = max(availableSize.height / noteDesignSize.height, 0.01)
        return min(widthScale, heightScale)
    }

    private func noteCanvasSize(for availableSize: CGSize, scale: CGFloat) -> CGSize {
        CGSize(
            width: max(noteDesignSize.width, availableSize.width / max(scale, 0.01)),
            height: max(noteDesignSize.height, availableSize.height / max(scale, 0.01))
        )
    }

    private var mainNote: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            currentTaskSection
            quickAddSection
            primaryTaskSection
            otherRootTasksSection
            backgroundMonitoringSection
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            CatAvatarView(size: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(TaskBoardPalette.ink)
                Text(headerSubtitleText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.black.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }

    private var currentTaskSection: some View {
        PaperCard(tint: Color.white.opacity(0.76), cornerRadius: 22, padding: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("当前主任务")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.5))
                }
                    .frame(width: noteLabelWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    TaskHeaderBlock {
                        Text(dockNoteRootTask?.title ?? "还没有选中任务")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(TaskBoardPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                    } badges: {
                        currentTaskHeaderBadges
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    completionSwitchDropIsTargeted ? TaskBoardPalette.accent.opacity(0.44) : .clear,
                    lineWidth: 2
                )
        )
        .dropDestination(for: String.self) { items, _ in
            handleRootTaskReplacementDrop(items)
        } isTargeted: { isTargeted in
            completionSwitchDropIsTargeted = isTargeted
        }
    }

    private var primaryTaskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(taskDetailDrawerAnimation) {
                        isSubtaskSectionExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isSubtaskSectionExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                        Text("子任务")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.black.opacity(0.56))
                }
                .buttonStyle(.plain)

                Picker("", selection: $showingCompletedSubtasks) {
                    Text("未完成").tag(false)
                    Text("已完成").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 132)

                Spacer()

                if !filteredSubtasks.isEmpty {
                    Text("\(filteredSubtasks.count) 个")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.black.opacity(0.46))
                }

                HStack(spacing: 8) {
                    Button("完成") { completeFocusedTask() }
                        .buttonStyle(.borderedProminent)
                        .tint(TaskBoardPalette.accent)

                    Button("后台运行") {
                        moveFocusedTaskToBackground()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if isSubtaskSectionExpanded {
                if filteredSubtasks.isEmpty {
                    Text(showingCompletedSubtasks ? "当前任务还没有已完成子任务。" : "当前任务还没有未完成子任务。")
                        .font(.system(size: 13))
                        .foregroundStyle(.black.opacity(0.52))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredSubtasks) { task in
                            primaryTaskRow(task)
                        }
                    }
                }
            }
        }
    }

    private var quickAddSection: some View {
        PaperCard(tint: Color.white.opacity(0.72), cornerRadius: 22, padding: 14) {
            HStack(spacing: 10) {
                Text("快速新建")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.56))
                    .frame(width: noteLabelWidth, alignment: .leading)

                TextField("添加任务，默认放到当前任务下面", text: $quickTaskTitle)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onSubmit(handleQuickTaskCreation)

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
        }
    }

    private var backgroundMonitoringSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("后台进行中")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.56))
                Spacer()
                if !backgroundMonitorTasks.isEmpty {
                    Text("切到别的母任务后也会继续")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.black.opacity(0.46))
                }
            }

            if backgroundMonitorTasks.isEmpty {
                Text("还没有后台进行中的任务。点一下“后台运行”，这里就会出现监控卡片。")
                    .font(.system(size: 13))
                    .foregroundStyle(.black.opacity(0.52))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(backgroundMonitorTasks.prefix(4)) { task in
                        backgroundTaskRow(task)
                    }
                }
            }
        }
    }

    private var otherRootTasksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("其他母任务")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.56))
                Spacer()
                Text("按优先级自动排序")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.black.opacity(0.46))
            }

            if otherRootTasks.isEmpty {
                Text("目前没有其他顶级母任务。")
                    .font(.system(size: 13))
                    .foregroundStyle(.black.opacity(0.52))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(otherRootTasks.prefix(4)) { task in
                            HStack(spacing: 6) {
                                primaryTaskRow(
                                    task,
                                    allowsTitleRename: false,
                                    allowsDragging: true,
                                    doubleTapAction: {
                                        rootSwitchPromptTaskID = task.id
                                    }
                                )

                                Button("切换") {
                                    switchToRootTask(task.id)
                                }
                                .buttonStyle(.bordered)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(TaskBoardPalette.accent)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 168)
                .scrollIndicators(.never)
            }
        }
    }

    private func backgroundTaskRow(_ task: Task) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(stripeColor(for: task))
                .frame(width: 6, height: 36)

            VStack(alignment: .leading, spacing: 6) {
                TaskHeaderBlock {
                    Text(task.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TaskBoardPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                } badges: {
                    taskRowBadges(for: task, includeHierarchy: true, includeChildCount: false)
                    StatusBadge(title: "后台运行", color: TaskBoardPalette.quiet)
                }
            }

            HStack(spacing: 6) {
                Button("切换") {
                    appModel.setCurrentTask(id: task.id)
                    selectTask(task.id)
                }
                .buttonStyle(.bordered)

                Button("完成") {
                    appModel.completeTask(id: task.id)
                }
                .buttonStyle(.borderless)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(TaskBoardPalette.accent)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(TaskBoardPalette.line, lineWidth: 1)
        )
    }

    private func primaryTaskRow(
        _ task: Task,
        allowsTitleRename: Bool = true,
        allowsDragging: Bool = false,
        doubleTapAction: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(stripeColor(for: task))
                .frame(width: 6, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                if renamingTaskID == task.id {
                    TextField("任务名", text: $renameTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(TaskBoardPalette.ink)
                        .lineLimit(1)
                        .focused($focusedRenameTaskID, equals: task.id)
                        .submitLabel(.done)
                        .onSubmit(commitRename)
                } else {
                    TaskHeaderBlock(spacing: 6, rowSpacing: 4) {
                        Group {
                            if allowsTitleRename {
                                Text(task.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(TaskBoardPalette.ink)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(1)
                                    .contentShape(Rectangle())
                                    .highPriorityGesture(
                                        TapGesture(count: 2).onEnded {
                                            beginRenaming(task)
                                        }
                                    )
                            } else {
                                Text(task.title)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(TaskBoardPalette.ink)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(1)
                                    .contentShape(Rectangle())
                            }
                        }
                    } badges: {
                        dockNoteRowBadges(for: task)
                    }
                }
            }

            Button {
                expandTask(task.id)
            } label: {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TaskBoardPalette.accent)
                    .frame(width: 22, height: 22)
                    .background(TaskBoardPalette.canvas.opacity(0.78), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(selectedTaskID == task.id ? Color.white.opacity(0.92) : Color.black.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(selectedTaskID == task.id ? TaskBoardPalette.accent.opacity(0.4) : .clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .simultaneousGesture(pressSelectionGesture(for: task.id))
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if let doubleTapAction {
                suppressExpansion(for: task.id)
                doubleTapAction()
            } else {
                expandTask(task.id)
            }
        })
        .optionalDraggable(allowsDragging, payload: task.id.uuidString)
    }

    private func drawer(task: Task) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("任务名")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black.opacity(0.56))
                    TextField("任务名", text: $draft.title)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                TaskSmartColumnsEditor(
                    entries: $draft.smartEntries,
                    hasDueDate: $draft.hasDueDate,
                    dueAt: $draft.dueAt
                )

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

                HStack(spacing: 8) {
                    StatusBadge(title: draft.quadrant?.title ?? "无", color: TaskBoardPalette.accentWarm)
                    if draft.quadrant == nil {
                        Text("请先选择四象限，再进行计划。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.black.opacity(0.48))
                    }
                }

                HStack {
                    Button("设为当前") {
                        appModel.setCurrentTask(id: task.id)
                    }
                    Spacer()
                    Button("保存") {
                        syncPriorityMetadata()
                        appModel.applyTaskDraft(draft, to: task.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TaskBoardPalette.accent)
                    .disabled(draft.quadrant == nil)
                }
            }
            .padding(16)
        }
        .background(
            Rectangle()
                .fill(Color.white.opacity(0.42))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(TaskBoardPalette.line)
                        .frame(width: 1)
                }
        )
    }

    private func handleCloseButton() {
        if expandedTaskID != nil {
            withAnimation(taskDetailDrawerAnimation) {
                expandedTaskID = nil
            }
            return
        }

        onClose?()
    }

    private func toggleDrawer(for taskID: UUID, allowCollapse: Bool = true) {
        if allowCollapse, expandedTaskID == taskID {
            expandedTaskID = nil
            return
        }

        expandedTaskID = taskID
        selectedTaskID = taskID
        if let loaded = appModel.buildTaskDraft(for: taskID) {
            draft = loaded
        }
    }

    private func handleQuickTaskCreation() {
        let parentTaskID = appModel.currentTask?.id
        guard let createdTaskID = appModel.addTask(
            title: quickTaskTitle,
            parentTaskID: parentTaskID,
            promptForPriority: false
        ) else { return }

        quickTaskTitle = ""
        selectTask(createdTaskID)
        toggleDrawer(for: createdTaskID, allowCollapse: false)
    }

    private func completeCurrentTask() {
        let previousCurrentID = appModel.currentTask?.id
        let nextTaskID = appModel.completeCurrentTask()

        guard expandedTaskID == previousCurrentID else { return }
        guard let nextTaskID = nextTaskID ?? appModel.currentTask?.id, nextTaskID != previousCurrentID else {
            expandedTaskID = nil
            return
        }

        toggleDrawer(for: nextTaskID, allowCollapse: false)
    }

    private func selectTask(_ taskID: UUID) {
        selectedTaskID = taskID
    }

    private func expandTask(_ taskID: UUID) {
        if suppressedExpansionTaskID == taskID {
            suppressedExpansionTaskID = nil
            return
        }
        toggleDrawer(for: taskID)
    }

    private func pressSelectionGesture(for taskID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pressedTaskID != taskID else { return }
                pressedTaskID = taskID
                selectTask(taskID)
            }
            .onEnded { _ in
                pressedTaskID = nil
            }
    }

    private func beginRenaming(_ task: Task) {
        suppressExpansion(for: task.id)
        selectTask(task.id)
        renameTitle = task.title
        renamingTaskID = task.id
        DispatchQueue.main.async {
            focusedRenameTaskID = task.id
        }
    }

    private func commitRename() {
        guard let renamingTaskID else { return }
        let newTitle = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newTitle.isEmpty {
            appModel.renameTask(id: renamingTaskID, title: newTitle)
        }
        self.renamingTaskID = nil
        renameTitle = ""
        focusedRenameTaskID = nil
    }

    private func suppressExpansion(for taskID: UUID) {
        suppressedExpansionTaskID = taskID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if suppressedExpansionTaskID == taskID {
                suppressedExpansionTaskID = nil
            }
        }
    }

    @ViewBuilder
    private var currentTaskHeaderBadges: some View {
        if let currentTask = dockNoteRootTask {
            taskRowBadges(for: currentTask, includeHierarchy: false, includeChildCount: false)
        }
    }

    @ViewBuilder
    private func dockNoteRowBadges(for task: Task) -> some View {
        StatusBadge(title: task.status.title, color: stripeColor(for: task))
        StatusBadge(title: hierarchyLabel(for: task), color: TaskBoardPalette.quiet)
    }

    @ViewBuilder
    private func taskRowBadges(for task: Task, includeHierarchy: Bool, includeChildCount: Bool) -> some View {
        StatusBadge(title: task.status.title, color: stripeColor(for: task))
        StatusBadge(title: task.quadrant?.title ?? "无", color: TaskBoardPalette.accentWarm)
        if includeHierarchy {
            StatusBadge(title: hierarchyLabel(for: task), color: TaskBoardPalette.quiet)
        }
        if includeChildCount {
            let childCount = appModel.childTaskCount(for: task.id)
            if childCount > 0 {
                StatusBadge(title: "\(childCount) 个子项", color: TaskBoardPalette.accent.opacity(0.92))
            }
        }
        if let dueAt = task.dueAt {
            StatusBadge(title: formatDate(dueAt), color: TaskBoardPalette.accentWarm)
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

    private func stripeColor(for task: Task) -> Color {
        switch task.status {
        case .doing: return TaskBoardPalette.accent
        case .paused: return TaskBoardPalette.accentWarm
        case .done: return .green
        case .archived: return .gray
        case .todo: return Color(red: 0.37, green: 0.44, blue: 0.55)
        }
    }

    private func hierarchyLabel(for task: Task) -> String {
        let depth = appModel.taskDepths[task.id] ?? 0
        switch depth {
        case 0: return "母任务"
        case 1: return "子任务"
        default: return "\(depth + 1)级任务"
        }
    }

    // MARK: - 以本地选中的任务为操作对象

    private var focusedTaskID: UUID? {
        selectedTaskID ?? appModel.currentTask?.id
    }

    private func completeFocusedTask() {
        guard let id = focusedTaskID else { return }
        let nextTaskID = appModel.completeTask(id: id)
        if expandedTaskID == id {
            if let nextTaskID, nextTaskID != id {
                toggleDrawer(for: nextTaskID, allowCollapse: false)
            } else {
                expandedTaskID = nil
            }
        }
    }

    private func moveFocusedTaskToBackground() {
        guard let id = focusedTaskID else { return }
        let nextTaskID = appModel.moveTaskToBackground(id: id)
        if expandedTaskID == id {
            if let nextTaskID, nextTaskID != id {
                toggleDrawer(for: nextTaskID, allowCollapse: false)
            } else {
                expandedTaskID = nil
            }
        }
    }

    private func moveCurrentTaskToBackground() {
        let previousCurrentID = appModel.currentTask?.id
        let nextTaskID = appModel.moveCurrentTaskToBackground()

        guard expandedTaskID == previousCurrentID else { return }
        guard let nextTaskID, nextTaskID != previousCurrentID else {
            expandedTaskID = nil
            return
        }

        toggleDrawer(for: nextTaskID, allowCollapse: false)
    }

    private func handleRootTaskReplacementDrop(_ items: [String]) -> Bool {
        guard
            let firstID = items.first,
            let taskID = UUID(uuidString: firstID),
            let task = appModel.task(id: taskID),
            task.parentTaskID == nil,
            task.status != .done,
            task.status != .archived,
            task.id != dockNoteRootTask?.id
        else {
            return false
        }

        switchToRootTask(taskID)
        return true
    }

    private var headerSubtitleText: String {
        "\(appModel.petState.title) · \(subtitle)"
    }

    private func switchToRootTask(_ taskID: UUID) {
        rootSwitchPromptTaskID = nil
        appModel.setCurrentTask(id: taskID)
        selectTask(taskID)
        expandedTaskID = nil
    }

    private func editTask(_ taskID: UUID) {
        rootSwitchPromptTaskID = nil
        selectTask(taskID)
        toggleDrawer(for: taskID, allowCollapse: false)
    }

    private func rootAncestorID(for taskID: UUID?) -> UUID? {
        guard var currentTask = appModel.task(id: taskID) else { return nil }
        while let parentID = currentTask.parentTaskID, let parentTask = appModel.task(id: parentID) {
            currentTask = parentTask
        }
        return currentTask.id
    }
}

private struct TapeAccent: View {
    let rotation: Double

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.white.opacity(0.4))
            .frame(width: 62, height: 16)
            .rotationEffect(.degrees(rotation))
            .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 3)
    }
}

private extension View {
    @ViewBuilder
    func optionalDraggable(_ enabled: Bool, payload: String) -> some View {
        if enabled {
            draggable(payload)
        } else {
            self
        }
    }
}
