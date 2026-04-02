import SwiftUI

enum TaskCanvasMode: String, CaseIterable, Identifiable {
    case list
    case mindMap
    case recentCompleted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "列表"
        case .mindMap: "思维导图"
        case .recentCompleted: "最近完成"
        }
    }
}

enum TaskCanvasTimeRange: String, CaseIterable, Identifiable {
    case today
    case week
    case month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "今日任务"
        case .week: "本周任务"
        case .month: "月度任务"
        }
    }

    func contains(_ date: Date, calendar: Calendar = .current, now: Date = .now) -> Bool {
        switch self {
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .week:
            guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return false }
            return interval.contains(date)
        case .month:
            let nowComponents = calendar.dateComponents([.year, .month], from: now)
            let dateComponents = calendar.dateComponents([.year, .month], from: date)
            return nowComponents.year == dateComponents.year && nowComponents.month == dateComponents.month
        }
    }
}

struct PriorityQuadrantPicker: View {
    @Binding var urgencyValue: Double
    @Binding var importanceValue: Double

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            let markerRadius: CGFloat = 9
            let usableWidth = max(width - (markerRadius * 2), 1)
            let usableHeight = max(height - (markerRadius * 2), 1)
            let normalizedImportance = PriorityVector.clampedPercentage(importanceValue) / 100
            let normalizedUrgency = PriorityVector.clampedPercentage(urgencyValue) / 100
            let point = CGPoint(
                x: markerRadius + (normalizedImportance * usableWidth),
                y: markerRadius + ((1 - normalizedUrgency) * usableHeight)
            )

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.7))

                quadrantBackground
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                Path { path in
                    path.move(to: CGPoint(x: width / 2, y: 0))
                    path.addLine(to: CGPoint(x: width / 2, y: height))
                    path.move(to: CGPoint(x: 0, y: height / 2))
                    path.addLine(to: CGPoint(x: width, y: height / 2))
                }
                .stroke(Color.black.opacity(0.42), style: StrokeStyle(lineWidth: 3.2))

                quadrantLabels

                Circle()
                    .fill(markerColor)
                    .frame(width: 18, height: 18)
                    .overlay {
                        Circle()
                            .stroke(.white, lineWidth: 3.5)
                    }
                    .shadow(color: markerColor.opacity(0.34), radius: 10, x: 0, y: 6)
                    .position(point)

            }
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(TaskBoardPalette.line, lineWidth: 1)
                )
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let clampedX = min(max(gesture.location.x, markerRadius), width - markerRadius)
                        let clampedY = min(max(gesture.location.y, markerRadius), height - markerRadius)
                        let normalizedX = PriorityVector.roundedPercentage((Double(clampedX - markerRadius) / Double(usableWidth)) * 100)
                        let normalizedY = PriorityVector.roundedPercentage((1 - (Double(clampedY - markerRadius) / Double(usableHeight))) * 100)
                        importanceValue = PriorityVector.clampedPercentage(normalizedX)
                        urgencyValue = PriorityVector.clampedPercentage(normalizedY)
                    }
            )
        }
        .frame(height: 240)
    }

    private var quadrantBackground: some View {
        let activeQuadrant = PriorityVector.quadrant(urgencyValue: urgencyValue, importanceValue: importanceValue)

        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                quadrantFill(.urgentNotImportant, base: Color(red: 0.98, green: 0.91, blue: 0.84), activeQuadrant: activeQuadrant)
                quadrantFill(.urgentImportant, base: Color(red: 0.99, green: 0.84, blue: 0.74), activeQuadrant: activeQuadrant)
            }
            HStack(spacing: 0) {
                quadrantFill(.notUrgentNotImportant, base: Color(red: 0.90, green: 0.94, blue: 0.98), activeQuadrant: activeQuadrant)
                quadrantFill(.notUrgentImportant, base: Color(red: 0.96, green: 0.93, blue: 0.80), activeQuadrant: activeQuadrant)
            }
        }
    }

    private var quadrantLabels: some View {
        ZStack {
            quadrantLabel("紧急且重要", alignment: .topTrailing)
            quadrantLabel("重要不紧急", alignment: .bottomTrailing)
            quadrantLabel("紧急不重要", alignment: .topLeading)
            quadrantLabel("不紧急不重要", alignment: .bottomLeading)
        }
    }

    private var markerColor: Color {
        let urgencyRatio = PriorityVector.clampedPercentage(urgencyValue) / 100
        let importanceRatio = PriorityVector.clampedPercentage(importanceValue) / 100
        return Color(
            red: min(0.98, 0.52 + (0.28 * urgencyRatio) + (0.08 * importanceRatio)),
            green: min(0.88, 0.34 + (0.24 * importanceRatio)),
            blue: min(0.64, 0.22 + (0.12 * (1 - urgencyRatio)))
        )
    }

    private func quadrantFill(_ quadrant: TaskQuadrant, base: Color, activeQuadrant: TaskQuadrant) -> some View {
        base
            .opacity(activeQuadrant == quadrant ? 0.96 : 0.52)
            .overlay(
                activeQuadrant == quadrant
                    ? base.opacity(0.22)
                    : Color.white.opacity(0.16)
            )
    }

    @ViewBuilder
    private func quadrantLabel(_ title: String, alignment: Alignment) -> some View {
        VStack {
            if alignment == .bottomLeading || alignment == .bottomTrailing {
                Spacer()
            }

            HStack {
                if alignment == .topTrailing || alignment == .bottomTrailing {
                    Spacer()
                }
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.84), in: Capsule())
                    .foregroundStyle(.black.opacity(0.62))
                if alignment == .topLeading || alignment == .bottomLeading {
                    Spacer()
                }
            }

            if alignment == .topLeading || alignment == .topTrailing {
                Spacer()
            }
        }
        .padding(10)
    }
}

struct TaskSmartColumnsEditor: View {
    @Binding var entries: [SmartEntry]
    var hasDueDate: Binding<Bool>? = nil
    var dueAt: Binding<Date>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(SmartFieldKey.allCases, id: \.rawValue) { key in
                smartEntrySection(for: key)
            }
        }
        .onAppear {
            entries = entries.mergedWithDefaults()
            syncTimeEntry()
        }
        .onChange(of: trackedHasDueDate) { _ in
            syncTimeEntry()
        }
        .onChange(of: trackedDueDate.timeIntervalSinceReferenceDate) { _ in
            syncTimeEntry()
        }
    }

    private var trackedHasDueDate: Bool {
        hasDueDate?.wrappedValue ?? false
    }

    private var trackedDueDate: Date {
        dueAt?.wrappedValue ?? .now
    }

    @ViewBuilder
    private func smartEntrySection(for key: SmartFieldKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(key.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(TaskBoardPalette.ink)

            if shouldShowHelper(for: key) {
                Text(key.helper)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.black.opacity(0.48))
            }

            switch key {
            case .deliverable:
                smartTextField(
                    placeholder: key.placeholder,
                    text: entryBinding(for: key),
                    lineLimit: 1...2
                )
            case .measure:
                measurableSection
            case .action:
                VStack(alignment: .leading, spacing: 10) {
                    SmartOptionChips(
                        options: ["可直接做", "需拆分", "需协作"],
                        selection: simpleOptionBinding(for: key, defaultValue: "可直接做")
                    )
                }
            case .relevance:
                smartTextField(
                    placeholder: key.placeholder,
                    text: entryBinding(for: key),
                    lineLimit: 1...2
                )
            case .time:
                if let hasDueDate, let dueAt {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 10) {
                            Toggle("设置截止日期", isOn: hasDueDate)
                                .toggleStyle(.switch)

                            Spacer(minLength: 0)

                            if hasDueDate.wrappedValue {
                                DatePicker("截止日期", selection: dueAt, displayedComponents: .date)
                                    .labelsHidden()
                                    .datePickerStyle(.compact)
                            }
                        }

                        if hasDueDate.wrappedValue {
                            HStack(spacing: 8) {
                                quickTimeButton("今天") {
                                    applyQuickDueDate(daysFromToday: 0)
                                }
                                quickTimeButton("明天") {
                                    applyQuickDueDate(daysFromToday: 1)
                                }
                                quickTimeButton("本周") {
                                    applyEndOfWeekDueDate()
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(TaskBoardPalette.line, lineWidth: 1)
                    )
                } else {
                    smartTextField(
                        placeholder: "例如：本周五前完成",
                        text: entryBinding(for: key),
                        lineLimit: 1...2
                    )
                }
            }
        }
    }

    private var measurableSection: some View {
        let modeBinding = prefixedOptionBinding(for: .measure, options: ["数量", "时长", "验收"], defaultValue: "验收")
        let detailBinding = prefixedDetailBinding(for: .measure, options: ["数量", "时长", "验收"], defaultValue: "验收")

        return VStack(alignment: .leading, spacing: 10) {
            SmartOptionChips(
                options: ["数量", "时长", "验收"],
                selection: modeBinding
            )

            smartTextField(
                placeholder: measurePlaceholder(for: modeBinding.wrappedValue),
                text: detailBinding,
                lineLimit: 1...3
            )
        }
    }

    private func smartTextField(
        placeholder: String,
        text: Binding<String>,
        lineLimit: ClosedRange<Int>
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.84))

            TextField(placeholder, text: text, axis: .vertical)
                .lineLimit(lineLimit)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TaskBoardPalette.line, lineWidth: 1)
        )
    }

    private func entryBinding(for key: SmartFieldKey) -> Binding<String> {
        Binding(
            get: {
                entries.mergedWithDefaults().first(where: { $0.key == key })?.value ?? ""
            },
            set: { newValue in
                var merged = entries.mergedWithDefaults()
                if let index = merged.firstIndex(where: { $0.key == key }) {
                    merged[index].value = newValue
                }
                entries = merged
            }
        )
    }

    private func shouldShowHelper(for key: SmartFieldKey) -> Bool {
        !key.helper.isEmpty && key != .deliverable && key != .relevance
    }

    private func simpleOptionBinding(for key: SmartFieldKey, defaultValue: String) -> Binding<String> {
        Binding(
            get: {
                let value = entryBinding(for: key).wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? defaultValue : value
            },
            set: { newValue in
                entryBinding(for: key).wrappedValue = newValue
            }
        )
    }

    private func prefixedOptionBinding(
        for key: SmartFieldKey,
        options: [String],
        defaultValue: String
    ) -> Binding<String> {
        Binding(
            get: {
                splitPrefixedValue(entryBinding(for: key).wrappedValue, options: options, defaultValue: defaultValue).prefix
            },
            set: { newValue in
                let current = splitPrefixedValue(entryBinding(for: key).wrappedValue, options: options, defaultValue: defaultValue)
                entryBinding(for: key).wrappedValue = joinPrefixedValue(prefix: newValue, detail: current.detail)
            }
        )
    }

    private func prefixedDetailBinding(
        for key: SmartFieldKey,
        options: [String],
        defaultValue: String
    ) -> Binding<String> {
        Binding(
            get: {
                splitPrefixedValue(entryBinding(for: key).wrappedValue, options: options, defaultValue: defaultValue).detail
            },
            set: { newValue in
                let current = splitPrefixedValue(entryBinding(for: key).wrappedValue, options: options, defaultValue: defaultValue)
                entryBinding(for: key).wrappedValue = joinPrefixedValue(prefix: current.prefix, detail: newValue)
            }
        )
    }

    private func splitPrefixedValue(_ value: String, options: [String], defaultValue: String) -> (prefix: String, detail: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for option in options {
            let prefix = "\(option)："
            if trimmed.hasPrefix(prefix) {
                return (option, String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if trimmed == option {
                return (option, "")
            }
        }
        return (defaultValue, trimmed)
    }

    private func joinPrefixedValue(prefix: String, detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? prefix : "\(prefix)：\(trimmed)"
    }

    private func measurePlaceholder(for mode: String) -> String {
        switch mode {
        case "数量":
            return "例如：3 页文档 / 5 张截图"
        case "时长":
            return "例如：90 分钟 / 2 天"
        default:
            return "例如：能演示、能自测通过、能发给客户"
        }
    }

    private func syncTimeEntry() {
        guard let hasDueDate, let dueAt else { return }
        entryBinding(for: .time).wrappedValue = hasDueDate.wrappedValue ? formatDate(dueAt.wrappedValue) : ""
    }

    private func applyQuickDueDate(daysFromToday: Int) {
        guard let hasDueDate, let dueAt else { return }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        components.day = (components.day ?? 0) + daysFromToday
        components.hour = 18
        components.minute = 0
        if let date = Calendar.current.date(from: components) {
            hasDueDate.wrappedValue = true
            dueAt.wrappedValue = date
            syncTimeEntry()
        }
    }

    private func applyEndOfWeekDueDate() {
        guard let hasDueDate, let dueAt else { return }
        let calendar = Calendar.current
        guard
            let weekInterval = calendar.dateInterval(of: .weekOfYear, for: .now),
            let friday = calendar.date(byAdding: .day, value: 4, to: weekInterval.start),
            let finalDate = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: friday)
        else { return }

        hasDueDate.wrappedValue = true
        dueAt.wrappedValue = finalDate
        syncTimeEntry()
    }

    private func quickTimeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .tint(TaskBoardPalette.accent.opacity(0.92))
            .controlSize(.small)
    }
}

private struct SmartOptionChips: View {
    let options: [String]
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 8)], spacing: 8) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(option)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selection == option ? TaskBoardPalette.paper.opacity(0.96) : Color.white.opacity(0.84))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selection == option ? TaskBoardPalette.accent.opacity(0.34) : TaskBoardPalette.line, lineWidth: 1)
                )
                .foregroundStyle(selection == option ? TaskBoardPalette.ink : .black.opacity(0.62))
            }
        }
    }
}

struct TaskCanvasView: View {
    @ObservedObject var appModel: AppModel
    @Binding var selectedTaskID: UUID?
    @Binding var expandedTaskID: UUID?
    @Binding var draft: TaskSnapshotDraft
    @Binding var mode: TaskCanvasMode
    @Binding var timeRange: TaskCanvasTimeRange
    var onSelectTask: (UUID) -> Void
    var onExpandTask: (UUID) -> Void

    @State private var collapsedTaskIDs = Set<UUID>()

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width, 1)
            let usesOverlayDrawer = availableWidth < 920
            let drawerWidth = min(388, max(280, availableWidth * (usesOverlayDrawer ? 0.54 : 0.36)))

            PaperCard(tint: Color.white.opacity(0.82), cornerRadius: 28, padding: 0) {
                VStack(spacing: 0) {
                    header(availableWidth: availableWidth, usesOverlayDrawer: usesOverlayDrawer)
                    Divider()
                        .overlay(TaskBoardPalette.line)

                    Group {
                        if usesOverlayDrawer {
                            ZStack(alignment: .trailing) {
                                canvasContent

                                if mode != .mindMap, let expandedTaskID, let task = appModel.task(id: expandedTaskID) {
                                    builderDrawer(task: task)
                                        .frame(width: drawerWidth)
                                        .frame(maxHeight: .infinity)
                                        .background(Color.white.opacity(0.08))
                                        .transition(taskDetailDrawerTransition)
                                }
                            }
                        } else {
                            HStack(spacing: 0) {
                                canvasContent

                                if mode != .mindMap, let expandedTaskID, let task = appModel.task(id: expandedTaskID) {
                                    builderDrawer(task: task)
                                        .frame(width: drawerWidth)
                                        .frame(maxHeight: .infinity)
                                        .transition(taskDetailDrawerTransition)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .animation(taskDetailDrawerAnimation, value: expandedTaskID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func header(availableWidth: CGFloat, usesOverlayDrawer: Bool) -> some View {
        let shouldStackHeader = availableWidth < (usesOverlayDrawer ? 760 : 960)

        Group {
            if shouldStackHeader {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: modeBinding) {
                        ForEach(TaskCanvasMode.allCases) { canvasMode in
                            Text(canvasMode.title).tag(canvasMode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Picker("", selection: $timeRange) {
                        ForEach(TaskCanvasTimeRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    ScrollView(.horizontal) {
                        headerActions
                    }
                    .scrollIndicators(.never)
                }
            } else {
                HStack(spacing: 10) {
                    Picker("", selection: modeBinding) {
                        ForEach(TaskCanvasMode.allCases) { canvasMode in
                            Text(canvasMode.title).tag(canvasMode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 320, alignment: .leading)
                    .offset(x: 2)

                    Picker("", selection: $timeRange) {
                        ForEach(TaskCanvasTimeRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 260, alignment: .leading)

                    Spacer(minLength: 8)

                    headerActions
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .padding(.vertical, 12)
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if mode == .recentCompleted {
                StatusBadge(
                    title: "\(completedTasksInRange.count) 条已完成",
                    color: TaskBoardPalette.accentWarm
                )
            } else if mode == .mindMap {
                StatusBadge(
                    title: "完整脑图编辑器",
                    color: TaskBoardPalette.accent
                )
            } else {
                canvasActionButton("展开", systemImage: "arrow.down.right.and.arrow.up.left") {
                    collapsedTaskIDs.removeAll()
                }

                canvasActionButton("折叠", systemImage: "arrow.up.left.and.arrow.down.right") {
                    collapsedTaskIDs = Set(appModel.snapshot.tasks.map(\.id))
                }

                if let selectedTaskID {
                    canvasActionButton("缩进", systemImage: "arrow.right.to.line") {
                        appModel.indentTask(id: selectedTaskID)
                    }

                    canvasActionButton("提升", systemImage: "arrow.left.to.line") {
                        appModel.outdentTask(id: selectedTaskID)
                    }

                    canvasActionButton("子任务", systemImage: "plus") {
                        let parentTaskID = selectedTaskID
                        guard let childTaskID = appModel.addChildTask(parentID: parentTaskID, promptForPriority: true) else { return }
                        collapsedTaskIDs.remove(parentTaskID)
                        selectTask(childTaskID)
                        expandedTaskID = childTaskID
                    }
                }
            }
        }
    }

    private func canvasActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .tint(TaskBoardPalette.accent.opacity(0.92))
    }

    private func builderDrawer(task: Task) -> some View {
        TaskComponentBuilderView(
            appModel: appModel,
            task: task,
            draft: $draft
        )
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

    private var canvasContent: some View {
        ZStack {
            if mode == .list {
                TaskTreeCanvasList(
                    appModel: appModel,
                    selectedTaskID: $selectedTaskID,
                    collapsedTaskIDs: $collapsedTaskIDs,
                    timeRange: timeRange,
                    onSelectTask: selectTask,
                    onExpandTask: toggleTaskDrawer
                )
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            if mode == .mindMap {
                TaskMindMapCanvas(
                    appModel: appModel,
                    selectedTaskID: $selectedTaskID,
                    collapsedTaskIDs: $collapsedTaskIDs,
                    timeRange: timeRange,
                    onSelectTask: selectTask,
                    onExpandTask: toggleTaskDrawer
                )
                .transition(.opacity)
            }

            if mode == .recentCompleted {
                TaskCompletedCanvas(
                    appModel: appModel,
                    selectedTaskID: $selectedTaskID,
                    timeRange: timeRange,
                    onSelectTask: selectTask,
                    onExpandTask: toggleTaskDrawer
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var completedTasksInRange: [Task] {
        taskCompletedItems(in: appModel.tasks, timeRange: timeRange)
    }

    private var modeBinding: Binding<TaskCanvasMode> {
        Binding(
            get: { mode },
            set: { newMode in
                mode = newMode
            }
        )
    }

    private func selectTask(_ taskID: UUID) {
        selectedTaskID = taskID
        onSelectTask(taskID)
    }

    private func toggleTaskDrawer(_ taskID: UUID) {
        if expandedTaskID == taskID {
            expandedTaskID = nil
            return
        }

        expandedTaskID = taskID
        onExpandTask(taskID)
    }
}

private struct TaskTreeCanvasList: View {
    @ObservedObject var appModel: AppModel
    @Binding var selectedTaskID: UUID?
    @Binding var collapsedTaskIDs: Set<UUID>
    let timeRange: TaskCanvasTimeRange
    let onSelectTask: (UUID) -> Void
    let onExpandTask: (UUID) -> Void

    @State private var renamingTaskID: UUID?
    @State private var renameTitle = ""
    @FocusState private var focusedRenameTaskID: UUID?
    @State private var suppressedExpansionTaskID: UUID?
    @State private var pressedTaskID: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(rootTasks) { task in
                    treeRow(task: task, depth: 0)
                }
            }
            .padding(18)
        }
        .background(renameDismissBackground)
        .onChange(of: focusedRenameTaskID) { newValue in
            if renamingTaskID != nil, newValue == nil {
                commitRename()
            }
        }
    }

    private var orderedTasks: [Task] {
        appModel.tasks.filter { visibleTaskIDs.contains($0.id) }
    }

    private var groupedTasks: [UUID?: [Task]] {
        Dictionary(grouping: orderedTasks) { $0.parentTaskID }
    }

    private var orderIndex: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: orderedTasks.enumerated().map { ($0.element.id, $0.offset) })
    }

    private var rootTasks: [Task] {
        ordered(groupedTasks[nil] ?? [])
    }

    private var visibleTaskIDs: Set<UUID> {
        openTaskVisibilitySet(in: appModel.snapshot, timeRange: timeRange)
    }

    private func treeRow(task: Task, depth: Int) -> AnyView {
        let children = ordered(groupedTasks[task.id] ?? [])
        let isCollapsed = collapsedTaskIDs.contains(task.id)

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                taskRowContent(task: task, depth: depth, hasChildren: !children.isEmpty, isCollapsed: isCollapsed)

                if !isCollapsed {
                    ForEach(children) { child in
                        treeRow(task: child, depth: depth + 1)
                    }
                }
            }
        )
    }

    private func taskRowContent(task: Task, depth: Int, hasChildren: Bool, isCollapsed: Bool) -> some View {
        let isChild = depth > 0
        let stripeHeight: CGFloat = isChild ? 34 : 40
        let titleFontSize: CGFloat = isChild ? 13 : 15
        let verticalPadding: CGFloat = isChild ? 8 : 10
        let horizontalPadding: CGFloat = isChild ? 12 : 14
        let indent: CGFloat = CGFloat(depth) * 18
        let showsMetadata = !hasChildren || isCollapsed

        return HStack(alignment: .top, spacing: 0) {
            Color.clear
                .frame(width: indent, height: 1)

            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(task.status == .doing ? TaskBoardPalette.accent : (isChild ? TaskBoardPalette.quiet.opacity(0.76) : TaskBoardPalette.accentWarm.opacity(0.75)))
                    .frame(width: isChild ? 5 : 6, height: stripeHeight)

                VStack(alignment: .leading, spacing: 4) {
                    TaskHeaderBlock {
                        taskTitle(task, fontSize: titleFontSize, isChild: isChild)
                    } badges: {
                        if showsMetadata {
                            taskRowBadges(for: task, depth: depth, isChild: isChild)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                expandButton(for: task.id, accentColor: isChild ? TaskBoardPalette.quiet : TaskBoardPalette.accent)

                if hasChildren {
                    Button {
                        toggleBranch(task.id, isCollapsed: isCollapsed)
                    } label: {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isChild ? TaskBoardPalette.quiet : TaskBoardPalette.accent)
                            .frame(width: 22, height: 22)
                            .background((isChild ? TaskBoardPalette.canvasAlt : TaskBoardPalette.canvas).opacity(0.78), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: isChild ? 18 : 20, style: .continuous)
                    .fill(
                        selectedTaskID == task.id
                            ? (isChild ? TaskBoardPalette.canvasAlt.opacity(0.92) : TaskBoardPalette.paper.opacity(0.9))
                            : (isChild ? TaskBoardPalette.canvasAlt.opacity(0.66) : TaskBoardPalette.paperSoft.opacity(0.76))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: isChild ? 18 : 20, style: .continuous)
                    .stroke(
                        selectedTaskID == task.id
                            ? TaskBoardPalette.accent.opacity(0.28)
                            : (isChild ? TaskBoardPalette.quiet.opacity(0.18) : .clear),
                        lineWidth: 1
                    )
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: isChild ? 18 : 20, style: .continuous))
        .simultaneousGesture(pressSelectionGesture(for: task.id))
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            expandTask(task.id)
        })
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ordered(_ tasks: [Task]) -> [Task] {
        tasks.sorted { orderIndex[$0.id, default: 0] < orderIndex[$1.id, default: 0] }
    }

    private func toggleBranch(_ taskID: UUID, isCollapsed: Bool) {
        var transaction = Transaction(animation: .linear(duration: 0.12))
        transaction.disablesAnimations = false
        withTransaction(transaction) {
            if isCollapsed {
                collapsedTaskIDs.remove(taskID)
            } else {
                collapsedTaskIDs.insert(taskID)
            }
        }
    }

    @ViewBuilder
    private func taskTitle(_ task: Task, fontSize: CGFloat, isChild: Bool) -> some View {
        if renamingTaskID == task.id {
            TextField("任务名", text: $renameTitle, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize, weight: isChild ? .semibold : .bold))
                .foregroundStyle(TaskBoardPalette.ink.opacity(isChild ? 0.82 : 1))
                .lineLimit(1...2)
                .focused($focusedRenameTaskID, equals: task.id)
                .submitLabel(.done)
                .onSubmit(commitRename)
        } else {
            Text(task.title)
                .font(.system(size: fontSize, weight: isChild ? .semibold : .bold))
                .foregroundStyle(TaskBoardPalette.ink.opacity(isChild ? 0.82 : 1))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    TapGesture(count: 2).onEnded {
                        beginRenaming(task)
                    }
                )
        }
    }

    private func expandButton(for taskID: UUID, accentColor: Color) -> some View {
        Button {
            expandTask(taskID)
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accentColor)
                .frame(width: 22, height: 22)
                .background(TaskBoardPalette.canvas.opacity(0.78), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func selectTask(_ taskID: UUID) {
        selectedTaskID = taskID
        onSelectTask(taskID)
    }

    private func expandTask(_ taskID: UUID) {
        if suppressedExpansionTaskID == taskID {
            suppressedExpansionTaskID = nil
            return
        }
        onExpandTask(taskID)
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

    private func hierarchyLabel(for depth: Int) -> String {
        switch depth {
        case 0: return "母任务"
        case 1: return "子任务"
        default: return "\(depth + 1)级任务"
        }
    }

    @ViewBuilder
    private func taskRowBadges(for task: Task, depth: Int, isChild: Bool) -> some View {
        // 层级标签：点击弹出菜单可直接调整级别
        HierarchyMenuBadge(
            appModel: appModel,
            task: task,
            depth: depth,
            isChild: isChild,
            hierarchyLabel: hierarchyLabel(for:)
        )
        StatusBadge(title: task.status.title, color: task.status == .doing ? TaskBoardPalette.accent : TaskBoardPalette.accentWarm)
        StatusBadge(title: task.quadrant?.title ?? "无", color: isChild ? TaskBoardPalette.quiet : TaskBoardPalette.accentWarm)
        if let dueAt = task.dueAt {
            StatusBadge(title: formatDate(dueAt), color: isChild ? TaskBoardPalette.quiet : TaskBoardPalette.accent)
        }
    }

    private var renameDismissBackground: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                selectedTaskID = nil
                focusedRenameTaskID = nil
                commitRename()
            }
    }
}

/// 层级标签：外观与 StatusBadge 一致，点击弹出菜单可直接升降级
private struct HierarchyMenuBadge: View {
    @ObservedObject var appModel: AppModel
    let task: Task
    let depth: Int
    let isChild: Bool
    let hierarchyLabel: (Int) -> String

    private var badgeColor: Color {
        isChild ? TaskBoardPalette.quiet : TaskBoardPalette.accent
    }

    var body: some View {
        Menu {
            if depth > 0 {
                Button {
                    appModel.outdentTask(id: task.id)
                } label: {
                    Label("升一级 → \(hierarchyLabel(depth - 1))", systemImage: "arrow.left.to.line")
                }
            }
            Divider()
            // 当前级别（不可点击，作为提示）
            Text("当前：\(hierarchyLabel(depth))")
                .foregroundStyle(.secondary)
            Divider()
            Button {
                appModel.indentTask(id: task.id)
            } label: {
                Label("降一级 → \(hierarchyLabel(depth + 1))", systemImage: "arrow.right.to.line")
            }
        } label: {
            HStack(spacing: 3) {
                Text(hierarchyLabel(depth))
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(0.7)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor.opacity(0.14), in: Capsule())
            .foregroundStyle(badgeColor)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct TaskMindMapCanvas: View {
    @ObservedObject var appModel: AppModel
    @Binding var selectedTaskID: UUID?
    @Binding var collapsedTaskIDs: Set<UUID>
    let timeRange: TaskCanvasTimeRange
    let onSelectTask: (UUID) -> Void
    let onExpandTask: (UUID) -> Void

    var body: some View {
        MindMapWebView(appModel: appModel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TaskCompletedCanvas: View {
    @ObservedObject var appModel: AppModel
    @Binding var selectedTaskID: UUID?
    let timeRange: TaskCanvasTimeRange
    let onSelectTask: (UUID) -> Void
    let onExpandTask: (UUID) -> Void

    @State private var renamingTaskID: UUID?
    @State private var renameTitle = ""
    @FocusState private var focusedRenameTaskID: UUID?
    @State private var suppressedExpansionTaskID: UUID?
    @State private var pressedTaskID: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if completedTasks.isEmpty {
                    Text(emptyStateText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.black.opacity(0.48))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(TaskBoardPalette.paperSoft.opacity(0.72))
                        )
                } else {
                    ForEach(completedTasks) { task in
                        completedTaskRow(task)
                    }
                }
            }
            .padding(18)
        }
        .background(renameDismissBackground)
        .onChange(of: focusedRenameTaskID) { newValue in
            if renamingTaskID != nil, newValue == nil {
                commitRename()
            }
        }
    }

    private var completedTasks: [Task] {
        taskCompletedItems(in: appModel.tasks, timeRange: timeRange)
    }

    private var emptyStateText: String {
        switch timeRange {
        case .today:
            return "今天还没有完成的任务。"
        case .week:
            return "本周还没有完成的任务。"
        case .month:
            return "本月还没有完成的任务。"
        }
    }

    private func completedTaskRow(_ task: Task) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.green.opacity(0.78))
                .frame(width: 6, height: 38)

            VStack(alignment: .leading, spacing: 6) {
                TaskHeaderBlock {
                    taskTitle(task)
                } badges: {
                    StatusBadge(title: "已完成", color: .green)
                    StatusBadge(title: task.quadrant?.title ?? "无", color: TaskBoardPalette.accentWarm)
                    if let completedAt = task.completedAt {
                        StatusBadge(title: completedAt.formatted(.dateTime.month().day().hour().minute()), color: TaskBoardPalette.quiet)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(selectedTaskID == task.id ? TaskBoardPalette.paper.opacity(0.9) : Color.white.opacity(0.84))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(selectedTaskID == task.id ? TaskBoardPalette.accent.opacity(0.28) : TaskBoardPalette.line, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .simultaneousGesture(pressSelectionGesture(for: task.id))
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            expandTask(task.id)
        })
    }

    @ViewBuilder
    private func taskTitle(_ task: Task) -> some View {
        if renamingTaskID == task.id {
            TextField("任务名", text: $renameTitle, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(TaskBoardPalette.ink)
                .lineLimit(1...2)
                .focused($focusedRenameTaskID, equals: task.id)
                .submitLabel(.done)
                .onSubmit(commitRename)
        } else {
            Text(task.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(TaskBoardPalette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    TapGesture(count: 2).onEnded {
                        beginRenaming(task)
                    }
                )
        }
    }

    private func selectTask(_ taskID: UUID) {
        selectedTaskID = taskID
        onSelectTask(taskID)
    }

    private func expandTask(_ taskID: UUID) {
        if suppressedExpansionTaskID == taskID {
            suppressedExpansionTaskID = nil
            return
        }
        onExpandTask(taskID)
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

    private var renameDismissBackground: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                selectedTaskID = nil
                focusedRenameTaskID = nil
                commitRename()
            }
    }
}

private func taskReferenceDate(_ task: Task) -> Date {
    // 优先用 dueAt，否则用 updatedAt/createdAt 中较新的
    // 保证被 indent/outdent/rename 修改过的任务也在当前时间范围内可见
    task.dueAt ?? max(task.updatedAt, task.createdAt)
}

private func openTaskVisibilitySet(in snapshot: AppSnapshot, timeRange: TaskCanvasTimeRange) -> Set<UUID> {
    let groupedTasks = TaskService.groupedTasks(in: snapshot)
    var visibleTaskIDs = Set<UUID>()

    @discardableResult
    func include(_ task: Task) -> Bool {
        let visibleChildren = (groupedTasks[task.id] ?? []).contains { include($0) }
        guard task.status != .archived && task.status != .done else {
            return visibleChildren
        }

        // 根任务（顶级）永远可见，不受时间范围过滤限制
        let isRootTask = task.parentTaskID == nil
        let matchesRange = isRootTask || timeRange.contains(taskReferenceDate(task))
        if matchesRange || visibleChildren {
            visibleTaskIDs.insert(task.id)
            return true
        }

        return false
    }

    for rootTask in groupedTasks[nil] ?? [] {
        _ = include(rootTask)
    }

    return visibleTaskIDs
}

private func taskCompletedItems(in tasks: [Task], timeRange: TaskCanvasTimeRange) -> [Task] {
    tasks
        .filter { task in
            guard task.status == .done, let completedAt = task.completedAt else { return false }
            return timeRange.contains(completedAt)
        }
        .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
}

private struct TaskComponentBuilderView: View {
    @ObservedObject var appModel: AppModel
    let task: Task
    @Binding var draft: TaskSnapshotDraft

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                builderSection(title: "任务名") {
                    HStack(alignment: .top, spacing: 12) {
                        TextField("任务名", text: $draft.title)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.86), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                        Picker("状态", selection: $draft.status) {
                            ForEach(TaskStatus.activeCases, id: \.rawValue) { status in
                                Text(status.title).tag(status)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 110)
                    }
                }

                notesSection
                quadrantSection

                builderSection(title: "SMART 栏目") {
                    TaskSmartColumnsEditor(
                        entries: $draft.smartEntries,
                        hasDueDate: $draft.hasDueDate,
                        dueAt: $draft.dueAt
                    )
                }

                HStack {
                    Button("设为当前") {
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
            }
            .padding(20)
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

    private var notesSection: some View {
        builderSection(title: "任务备注") {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.86))

                TextEditor(text: $draft.notes)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .frame(minHeight: 110)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(TaskBoardPalette.line, lineWidth: 1)
            )
        }
    }

    private var quadrantSection: some View {
        builderSection(title: "四象限") {
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
                StatusBadge(
                    title: draft.quadrant?.title ?? "无",
                    color: TaskBoardPalette.accentWarm
                )
                if draft.quadrant == nil {
                    Text("请先选择四象限，再进行计划。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.black.opacity(0.48))
                }
            }
        }
    }

    private func builderSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(TaskBoardPalette.ink)

            content()
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(TaskBoardPalette.paperSoft.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(TaskBoardPalette.line, lineWidth: 1)
        )
    }
}
