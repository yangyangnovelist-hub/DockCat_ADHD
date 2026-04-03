import Foundation

enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case doing
    case paused
    case done
    case archived

    var title: String {
        switch self {
        case .todo: "待办"
        case .doing: "进行中"
        case .paused: "已暂停"
        case .done: "已完成"
        case .archived: "已归档"
        }
    }
}

extension TaskStatus {
    static let activeCases: [TaskStatus] = [.todo, .doing, .paused, .done]
}

enum SessionState: String, Codable, Sendable {
    case active
    case paused
    case stopped
}

enum TaskTimerMode: String, Codable, CaseIterable, Sendable {
    case countUp
    case countdown
    case untimed

    var title: String {
        switch self {
        case .countUp: "正向计时"
        case .countdown: "倒计时"
        case .untimed: "不计时"
        }
    }

    var startTitle: String {
        switch self {
        case .countUp: "正向计时开始"
        case .countdown: "倒计时开始"
        case .untimed: "不计时开始"
        }
    }
}

enum TaskQuadrant: String, Codable, CaseIterable, Sendable {
    case urgentImportant
    case notUrgentImportant
    case urgentNotImportant
    case notUrgentNotImportant

    var title: String {
        switch self {
        case .urgentImportant: "紧急且重要"
        case .notUrgentImportant: "重要不紧急"
        case .urgentNotImportant: "紧急不重要"
        case .notUrgentNotImportant: "不紧急不重要"
        }
    }
}

enum PriorityVector {
    static func value(from score: Int) -> Double {
        let clamped = max(1, min(4, score))
        return roundedPercentage(Double(clamped - 1) / 3.0 * 100)
    }

    static func score(from value: Double) -> Int {
        let clamped = clampedPercentage(value)
        return max(1, min(4, Int(((clamped / 100) * 3).rounded()) + 1))
    }

    static func clampedPercentage(_ value: Double) -> Double {
        roundedPercentage(max(0, min(100, value)))
    }

    static func roundedPercentage(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    static func quadrant(urgencyValue: Double, importanceValue: Double) -> TaskQuadrant {
        switch (clampedPercentage(urgencyValue) >= 50, clampedPercentage(importanceValue) >= 50) {
        case (true, true): .urgentImportant
        case (false, true): .notUrgentImportant
        case (true, false): .urgentNotImportant
        case (false, false): .notUrgentNotImportant
        }
    }

    static func projection(urgencyValue: Double, importanceValue: Double) -> Double {
        let clampedUrgency = clampedPercentage(urgencyValue) / 100
        let clampedImportance = clampedPercentage(importanceValue) / 100
        return (clampedUrgency + clampedImportance) / sqrt(2)
    }

    static func derivedPriority(urgencyValue: Double, importanceValue: Double) -> Int {
        let dominant = max(clampedPercentage(urgencyValue), clampedPercentage(importanceValue))
        return switch dominant {
        case 80...100: 5
        case 60..<80: 4
        case 40..<60: 3
        case 20..<40: 2
        case 0..<20: 1
        default: 0
        }
    }
}

enum SmartFieldKey: String, Codable, CaseIterable, Sendable {
    case action
    case deliverable
    case measure
    case relevance
    case time

    var title: String {
        switch self {
        case .action: "可实现性"
        case .deliverable: "具体任务"
        case .measure: "可量化"
        case .relevance: "相关性"
        case .time: "时限"
        }
    }

    var helper: String {
        switch self {
        case .action: ""
        case .deliverable: "把任务写成单一、清晰、可交付的结果"
        case .measure: "写下数量、时长或明确的验收标准"
        case .relevance: "说明它为什么值得做，和当前目标有什么关系"
        case .time: ""
        }
    }

    var placeholder: String {
        switch self {
        case .deliverable, .relevance:
            return helper
        case .action, .measure, .time:
            return ""
        }
    }
}

struct SmartEntry: Codable, Hashable, Identifiable, Sendable {
    var key: SmartFieldKey
    var value: String

    var id: SmartFieldKey { key }
    var title: String { key.title }
    var placeholder: String { key.placeholder }

    var trimmedValue: String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool {
        trimmedValue.isEmpty
    }

    static func empty(_ key: SmartFieldKey) -> SmartEntry {
        SmartEntry(key: key, value: "")
    }
}

extension Collection where Element == SmartEntry {
    func value(for key: SmartFieldKey) -> String? {
        first(where: { $0.key == key })?.trimmedValue.nilIfEmpty
    }
}

extension Array where Element == SmartEntry {
    func mergedWithDefaults() -> [SmartEntry] {
        SmartFieldKey.allCases.map { key in
            first(where: { $0.key == key }) ?? .empty(key)
        }
    }
}

enum ImportSourceType: String, Codable, Sendable {
    case text
    case voice
    case markdown
    case csv
}

enum ParseStatus: String, Codable, Sendable {
    case pending
    case parsed
    case accepted
    case rejected
    case failed
}

enum PetEdge: String, Codable, CaseIterable, Sendable {
    case left
    case right
}

enum PetVisualState: String, Codable, Sendable {
    case idle
    case peek
    case active
    case focus
    case alert
    case celebrate

    var title: String {
        switch self {
        case .idle: "空闲"
        case .peek: "探头"
        case .active: "待命"
        case .focus: "专注"
        case .alert: "提醒"
        case .celebrate: "庆祝"
        }
    }
}

struct Project: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
}

struct Task: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var projectID: UUID?
    var parentTaskID: UUID?
    var sortIndex: Int
    var title: String
    var notes: String?
    var status: TaskStatus
    var priority: Int
    var urgencyScore: Int
    var importanceScore: Int
    var urgencyValue: Double
    var importanceValue: Double
    var quadrant: TaskQuadrant?
    var estimatedMinutes: Int?
    var dueAt: Date?
    var smartSpecificMissing: Bool
    var smartMeasurableMissing: Bool
    var smartActionableMissing: Bool
    var smartRelevantMissing: Bool
    var smartBoundedMissing: Bool
    var smartEntries: [SmartEntry]
    var tags: [String]
    var isCurrent: Bool
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var version: Int
    var tombstone: Bool
    var device_id: String?

    init(
        id: UUID,
        projectID: UUID?,
        parentTaskID: UUID?,
        sortIndex: Int = 0,
        title: String,
        notes: String?,
        status: TaskStatus,
        priority: Int,
        urgencyScore: Int,
        importanceScore: Int,
        urgencyValue: Double,
        importanceValue: Double,
        quadrant: TaskQuadrant?,
        estimatedMinutes: Int?,
        dueAt: Date?,
        smartSpecificMissing: Bool,
        smartMeasurableMissing: Bool,
        smartActionableMissing: Bool,
        smartRelevantMissing: Bool,
        smartBoundedMissing: Bool,
        smartEntries: [SmartEntry],
        tags: [String],
        isCurrent: Bool,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date?,
        version: Int = 1,
        tombstone: Bool = false,
        device_id: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.parentTaskID = parentTaskID
        self.sortIndex = sortIndex
        self.title = title
        self.notes = notes
        self.status = status
        self.priority = priority
        self.urgencyScore = urgencyScore
        self.importanceScore = importanceScore
        self.urgencyValue = urgencyValue
        self.importanceValue = importanceValue
        self.quadrant = quadrant
        self.estimatedMinutes = estimatedMinutes
        self.dueAt = dueAt
        self.smartSpecificMissing = smartSpecificMissing
        self.smartMeasurableMissing = smartMeasurableMissing
        self.smartActionableMissing = smartActionableMissing
        self.smartRelevantMissing = smartRelevantMissing
        self.smartBoundedMissing = smartBoundedMissing
        self.smartEntries = smartEntries
        self.tags = tags
        self.isCurrent = isCurrent
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.version = version
        self.tombstone = tombstone
        self.device_id = device_id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID
        case parentTaskID
        case sortIndex
        case title
        case notes
        case status
        case priority
        case urgencyScore
        case importanceScore
        case urgencyValue
        case importanceValue
        case quadrant
        case estimatedMinutes
        case dueAt
        case smartSpecificMissing
        case smartMeasurableMissing
        case smartActionableMissing
        case smartRelevantMissing
        case smartBoundedMissing
        case smartEntries
        case tags
        case isCurrent
        case createdAt
        case updatedAt
        case completedAt
        case version
        case tombstone
        case device_id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        parentTaskID = try container.decodeIfPresent(UUID.self, forKey: .parentTaskID)
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        title = try container.decode(String.self, forKey: .title)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        status = try container.decode(TaskStatus.self, forKey: .status)
        priority = try container.decode(Int.self, forKey: .priority)
        urgencyScore = try container.decode(Int.self, forKey: .urgencyScore)
        importanceScore = try container.decode(Int.self, forKey: .importanceScore)
        urgencyValue = try container.decode(Double.self, forKey: .urgencyValue)
        importanceValue = try container.decode(Double.self, forKey: .importanceValue)
        quadrant = try container.decodeIfPresent(TaskQuadrant.self, forKey: .quadrant)
        estimatedMinutes = try container.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        dueAt = try container.decodeIfPresent(Date.self, forKey: .dueAt)
        smartSpecificMissing = try container.decode(Bool.self, forKey: .smartSpecificMissing)
        smartMeasurableMissing = try container.decode(Bool.self, forKey: .smartMeasurableMissing)
        smartActionableMissing = try container.decode(Bool.self, forKey: .smartActionableMissing)
        smartRelevantMissing = try container.decode(Bool.self, forKey: .smartRelevantMissing)
        smartBoundedMissing = try container.decode(Bool.self, forKey: .smartBoundedMissing)
        smartEntries = try container.decode([SmartEntry].self, forKey: .smartEntries)
        tags = try container.decode([String].self, forKey: .tags)
        isCurrent = try container.decode(Bool.self, forKey: .isCurrent)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tombstone = try container.decodeIfPresent(Bool.self, forKey: .tombstone) ?? false
        device_id = try container.decodeIfPresent(String.self, forKey: .device_id)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(projectID, forKey: .projectID)
        try container.encodeIfPresent(parentTaskID, forKey: .parentTaskID)
        try container.encode(sortIndex, forKey: .sortIndex)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encode(status, forKey: .status)
        try container.encode(priority, forKey: .priority)
        try container.encode(urgencyScore, forKey: .urgencyScore)
        try container.encode(importanceScore, forKey: .importanceScore)
        try container.encode(urgencyValue, forKey: .urgencyValue)
        try container.encode(importanceValue, forKey: .importanceValue)
        try container.encodeIfPresent(quadrant, forKey: .quadrant)
        try container.encodeIfPresent(estimatedMinutes, forKey: .estimatedMinutes)
        try container.encodeIfPresent(dueAt, forKey: .dueAt)
        try container.encode(smartSpecificMissing, forKey: .smartSpecificMissing)
        try container.encode(smartMeasurableMissing, forKey: .smartMeasurableMissing)
        try container.encode(smartActionableMissing, forKey: .smartActionableMissing)
        try container.encode(smartRelevantMissing, forKey: .smartRelevantMissing)
        try container.encode(smartBoundedMissing, forKey: .smartBoundedMissing)
        try container.encode(smartEntries, forKey: .smartEntries)
        try container.encode(tags, forKey: .tags)
        try container.encode(isCurrent, forKey: .isCurrent)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encode(version, forKey: .version)
        try container.encode(tombstone, forKey: .tombstone)
        try container.encodeIfPresent(device_id, forKey: .device_id)
    }

    var smartHints: [String] {
        var hints: [String] = []
        if smartSpecificMissing { hints.append("目标还不够具体") }
        if smartMeasurableMissing { hints.append("缺少可衡量结果") }
        if smartActionableMissing { hints.append("建议先确认它是否能直接落地") }
        if smartRelevantMissing { hints.append("建议说明为什么值得做") }
        if smartBoundedMissing { hints.append("缺少时限") }
        return hints
    }

    var priorityVectorScore: Double {
        PriorityVector.projection(urgencyValue: urgencyValue, importanceValue: importanceValue)
    }

    mutating func touch() {
        version += 1
        updatedAt = Date()
    }
}

struct Session: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var taskID: UUID
    var startedAt: Date
    var endedAt: Date?
    var totalSeconds: Int
    var state: SessionState
    var interruptionCount: Int
    var timerMode: TaskTimerMode
    var countdownTargetSeconds: Int?

    init(
        id: UUID,
        taskID: UUID,
        startedAt: Date,
        endedAt: Date?,
        totalSeconds: Int,
        state: SessionState,
        interruptionCount: Int,
        timerMode: TaskTimerMode = .countUp,
        countdownTargetSeconds: Int? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.totalSeconds = totalSeconds
        self.state = state
        self.interruptionCount = interruptionCount
        self.timerMode = timerMode
        self.countdownTargetSeconds = countdownTargetSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case taskID
        case startedAt
        case endedAt
        case totalSeconds
        case state
        case interruptionCount
        case timerMode
        case countdownTargetSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        taskID = try container.decode(UUID.self, forKey: .taskID)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        totalSeconds = try container.decode(Int.self, forKey: .totalSeconds)
        state = try container.decode(SessionState.self, forKey: .state)
        interruptionCount = try container.decode(Int.self, forKey: .interruptionCount)
        timerMode = try container.decodeIfPresent(TaskTimerMode.self, forKey: .timerMode) ?? .countUp
        countdownTargetSeconds = try container.decodeIfPresent(Int.self, forKey: .countdownTargetSeconds)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encode(totalSeconds, forKey: .totalSeconds)
        try container.encode(state, forKey: .state)
        try container.encode(interruptionCount, forKey: .interruptionCount)
        try container.encode(timerMode, forKey: .timerMode)
        try container.encodeIfPresent(countdownTargetSeconds, forKey: .countdownTargetSeconds)
    }
}

struct Interrupt: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var sessionID: UUID
    var reason: String?
    var startedAt: Date
    var endedAt: Date?
}

struct ImportDraft: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var rawText: String
    var sourceType: ImportSourceType
    var parseStatus: ParseStatus
    var createdAt: Date
    var updatedAt: Date
}

struct ImportDraftItem: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var draftID: UUID
    var sortIndex: Int
    var parentItemID: UUID?
    var proposedTitle: String
    var proposedNotes: String?
    var proposedProjectName: String?
    var proposedPriority: Int?
    var proposedTags: [String]
    var proposedUrgencyScore: Int?
    var proposedImportanceScore: Int?
    var proposedUrgencyValue: Double?
    var proposedImportanceValue: Double?
    var proposedQuadrant: TaskQuadrant?
    var proposedDueAt: Date?
    var smartEntries: [SmartEntry]
    var smartHints: [String]
    var isAccepted: Bool
}

struct Tag: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
}

struct AppPreference: Codable, Hashable, Sendable {
    var petEdge: PetEdge
    var petOffsetY: Double
    var lowDistractionMode: Bool
    var backgroundTaskIDs: [String]
}

struct MindMapDocument: Codable, Hashable, Sendable {
    var dataJSON: String
    var configJSON: String?
    var localConfigJSON: String?
    var language: String
    var updatedAt: Date
}

struct AppSnapshot: Codable, Sendable {
    var projects: [Project]
    var tasks: [Task]
    var sessions: [Session]
    var interrupts: [Interrupt]
    var importDrafts: [ImportDraft]
    var importDraftItems: [ImportDraftItem]
    var mindMapDocument: MindMapDocument
    var preferences: AppPreference
    var selectedTaskID: UUID?
    var lastCelebrationAt: Date?

    static let empty = AppSnapshot(
        projects: [],
        tasks: [],
        sessions: [],
        interrupts: [],
        importDrafts: [],
        importDraftItems: [],
        mindMapDocument: MindMapDocument(
            dataJSON: """
            {"root":{"data":{"text":"任务树"},"children":[]},"theme":{"template":"default","config":{}},"layout":"logicalStructure","config":{},"view":null}
            """,
            configJSON: nil,
            localConfigJSON: nil,
            language: "zh",
            updatedAt: .now
        ),
        preferences: AppPreference(
            petEdge: .right,
            petOffsetY: 220,
            lowDistractionMode: false,
            backgroundTaskIDs: []
        ),
        selectedTaskID: nil,
        lastCelebrationAt: nil
    )

    private enum CodingKeys: String, CodingKey {
        case projects
        case tasks
        case sessions
        case interrupts
        case importDrafts
        case importDraftItems
        case mindMapDocument
        case preferences
        case selectedTaskID
        case lastCelebrationAt
    }

    init(
        projects: [Project],
        tasks: [Task],
        sessions: [Session],
        interrupts: [Interrupt],
        importDrafts: [ImportDraft],
        importDraftItems: [ImportDraftItem],
        mindMapDocument: MindMapDocument,
        preferences: AppPreference,
        selectedTaskID: UUID?,
        lastCelebrationAt: Date?
    ) {
        self.projects = projects
        self.tasks = tasks
        self.sessions = sessions
        self.interrupts = interrupts
        self.importDrafts = importDrafts
        self.importDraftItems = importDraftItems
        self.mindMapDocument = mindMapDocument
        self.preferences = preferences
        self.selectedTaskID = selectedTaskID
        self.lastCelebrationAt = lastCelebrationAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decode([Project].self, forKey: .projects)
        tasks = try container.decode([Task].self, forKey: .tasks)
        sessions = try container.decode([Session].self, forKey: .sessions)
        interrupts = try container.decode([Interrupt].self, forKey: .interrupts)
        importDrafts = try container.decode([ImportDraft].self, forKey: .importDrafts)
        importDraftItems = try container.decode([ImportDraftItem].self, forKey: .importDraftItems)
        mindMapDocument = try container.decodeIfPresent(MindMapDocument.self, forKey: .mindMapDocument)
            ?? AppSnapshot.empty.mindMapDocument
        preferences = try container.decode(AppPreference.self, forKey: .preferences)
        selectedTaskID = try container.decodeIfPresent(UUID.self, forKey: .selectedTaskID)
        lastCelebrationAt = try container.decodeIfPresent(Date.self, forKey: .lastCelebrationAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projects, forKey: .projects)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(interrupts, forKey: .interrupts)
        try container.encode(importDrafts, forKey: .importDrafts)
        try container.encode(importDraftItems, forKey: .importDraftItems)
        try container.encode(mindMapDocument, forKey: .mindMapDocument)
        try container.encode(preferences, forKey: .preferences)
        try container.encodeIfPresent(selectedTaskID, forKey: .selectedTaskID)
        try container.encodeIfPresent(lastCelebrationAt, forKey: .lastCelebrationAt)
    }
}

struct DailyStats: Sendable {
    var completedCount: Int
    var focusSeconds: Int
    var interruptionCount: Int
}

struct TaskSnapshotDraft {
    var title: String
    var notes: String
    var status: TaskStatus
    var urgencyValue: Double
    var importanceValue: Double
    var quadrant: TaskQuadrant?
    var estimatedMinutes: Int
    var dueAt: Date
    var hasDueDate: Bool
    var tagsText: String
    var smartEntries: [SmartEntry]
}

struct DraftItemSnapshotDraft {
    var title: String
    var notes: String
    var urgencyValue: Double
    var importanceValue: Double
    var quadrant: TaskQuadrant
    var dueAt: Date
    var hasDueDate: Bool
    var tagsText: String
    var smartEntries: [SmartEntry]
    var isAccepted: Bool
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
