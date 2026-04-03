import Foundation
import EventKit
import RemindersMenubarBridge
import VikunjaQuickAddBridge

struct ImportParseResult {
    var draft: ImportDraft
    var items: [ImportDraftItem]
    var runtimeNote: String
    var errorMessage: String?
}

@MainActor
enum ImportParser {
    static func parse(
        rawText: String,
        sourceType: ImportSourceType = .text,
        analysisPreference: ImportAnalysisPreference = .disabled
    ) async -> ImportParseResult {
        let now = Date()
        let draftID = UUID()
        let normalizedInput = normalizeLegacyStructure(in: rawText)

        if analysisPreference.isEnabled {
            do {
                let analysis = try await LocalModelImportAnalyzer.shared.analyze(
                    rawText: normalizedInput,
                    preference: analysisPreference,
                    referenceDate: now
                )
                let aiItems = await buildAIItems(
                    from: analysis.tasks,
                    draftID: draftID,
                    referenceDate: now
                )

                if !aiItems.isEmpty {
                    return makeResult(
                        rawText: rawText,
                        sourceType: sourceType,
                        draftID: draftID,
                        createdAt: now,
                        items: aiItems,
                        runtimeNote: "\(analysis.runtimeLabel) + Duckling 已生成 \(aiItems.count) 个候选块",
                        errorMessage: nil
                    )
                }

                let ruleBasedItems = await parseRuleBasedItems(
                    rawText: normalizedInput,
                    draftID: draftID,
                    referenceDate: now
                )
                if !ruleBasedItems.isEmpty {
                    return makeResult(
                        rawText: rawText,
                        sourceType: sourceType,
                        draftID: draftID,
                        createdAt: now,
                        items: ruleBasedItems,
                        runtimeNote: "\(analysis.runtimeLabel) 未返回可用任务，已回退 Vikunja + Duckling 生成 \(ruleBasedItems.count) 个候选块",
                        errorMessage: nil
                    )
                }

                return makeResult(
                    rawText: rawText,
                    sourceType: sourceType,
                    draftID: draftID,
                    createdAt: now,
                    items: [],
                    runtimeNote: "\(analysis.runtimeLabel) 没有返回可导入任务",
                    errorMessage: "本地模型没有识别出可导入的任务"
                )
            } catch {
                let ruleBasedItems = await parseRuleBasedItems(
                    rawText: normalizedInput,
                    draftID: draftID,
                    referenceDate: now
                )
                if !ruleBasedItems.isEmpty {
                    return makeResult(
                        rawText: rawText,
                        sourceType: sourceType,
                        draftID: draftID,
                        createdAt: now,
                        items: ruleBasedItems,
                        runtimeNote: "\(analysisPreference.runtimeLabel) 连接失败，已回退 Vikunja + Duckling 生成 \(ruleBasedItems.count) 个候选块",
                        errorMessage: nil
                    )
                }

                return makeResult(
                    rawText: rawText,
                    sourceType: sourceType,
                    draftID: draftID,
                    createdAt: now,
                    items: [],
                    runtimeNote: "本地模型分析失败",
                    errorMessage: error.localizedDescription
                )
            }
        }

        let ruleBasedItems = await parseRuleBasedItems(
            rawText: normalizedInput,
            draftID: draftID,
            referenceDate: now
        )
        return makeResult(
            rawText: rawText,
            sourceType: sourceType,
            draftID: draftID,
            createdAt: now,
            items: ruleBasedItems,
            runtimeNote: "Vikunja + Duckling + Reminders 已生成 \(ruleBasedItems.count) 个候选块",
            errorMessage: ruleBasedItems.isEmpty ? "没有识别出可导入的任务" : nil
        )
    }

    private static func parseRuleBasedItems(
        rawText: String,
        draftID: UUID,
        referenceDate: Date
    ) async -> [ImportDraftItem] {
        let quickAddLines = VikunjaQuickAdd.parseMultiline(rawText)
        var lineIDToItemID: [Int: UUID] = [:]
        var items: [ImportDraftItem] = []

        for (sortIndex, line) in quickAddLines.enumerated() {
            let itemID = UUID()
            lineIDToItemID[line.id] = itemID

            let parsedText = line.parsed.text.cleanedTaskTitle()
            guard !parsedText.isEmpty else {
                continue
            }

            let reminder = parsedReminder(from: line.originalTitle)
            let parsedPriority = line.parsed.priority ?? priorityValue(from: reminder.priority)
            let dueAt = await DucklingRuntime.shared.resolveDueDate(
                from: line.originalTitle,
                referenceDate: referenceDate
            ) ?? (reminder.hasDueDate ? reminder.date : nil)

            items.append(
                makeItem(
                    draftID: draftID,
                    sortIndex: sortIndex,
                    parentItemID: line.parentID.flatMap { lineIDToItemID[$0] },
                    title: parsedText,
                    notes: notes(from: line.parsed),
                    projectName: line.project?.nilIfBlank,
                    priority: parsedPriority,
                    tags: mergedTags(parsed: line.parsed, rawText: line.originalTitle),
                    dueAt: dueAt,
                    reminder: reminder
                )
            )
        }

        return items
    }

    private static func buildAIItems(
        from tasks: [LocalModelImportAnalyzer.Payload.Task],
        draftID: UUID,
        referenceDate: Date
    ) async -> [ImportDraftItem] {
        var items: [ImportDraftItem] = []
        var nextSortIndex = 0

        for task in tasks {
            let flattened = await flattenAITask(
                task,
                draftID: draftID,
                parentItemID: nil,
                sortIndex: nextSortIndex,
                referenceDate: referenceDate
            )
            items.append(contentsOf: flattened.items)
            nextSortIndex = flattened.nextSortIndex
        }

        return items
    }

    private static func flattenAITask(
        _ task: LocalModelImportAnalyzer.Payload.Task,
        draftID: UUID,
        parentItemID: UUID?,
        sortIndex: Int,
        referenceDate: Date
    ) async -> (items: [ImportDraftItem], nextSortIndex: Int) {
        let title = task.title.cleanedTaskTitle()
        guard !title.isEmpty else { return ([], sortIndex) }

        let dueAt = await resolveAIDueDate(for: task, referenceDate: referenceDate)
        let itemID = UUID()
        let priority = task.priority.map { min(5, max(1, $0)) }
        let notes = normalizedOptionalText(task.notes)
        let reminderSource = [title, notes, task.dueText].compactMap { $0 }.joined(separator: " ")
        let reminder = parsedReminder(from: reminderSource)

        let currentItem = makeItem(
            id: itemID,
            draftID: draftID,
            sortIndex: sortIndex,
            parentItemID: parentItemID,
            title: title,
            notes: notes,
            projectName: normalizedOptionalText(task.projectName),
            priority: priority,
            tags: normalizedTags(task.tags),
            dueAt: dueAt,
            reminder: reminder,
            urgencyOverride: task.urgencyScore.map { min(4, max(1, $0)) },
            importanceOverride: task.importanceScore.map { min(4, max(1, $0)) },
            smartOverride: smartEntries(from: task.smart, title: title, notes: notes, dueAt: dueAt)
        )
        var flattenedItems = [currentItem]
        var nextSortIndex = sortIndex + 1

        for child in task.childTasks {
            let childFlattened = await flattenAITask(
                child,
                draftID: draftID,
                parentItemID: itemID,
                sortIndex: nextSortIndex,
                referenceDate: referenceDate
            )
            flattenedItems.append(contentsOf: childFlattened.items)
            nextSortIndex = childFlattened.nextSortIndex
        }

        return (flattenedItems, nextSortIndex)
    }

    private static func resolveAIDueDate(
        for task: LocalModelImportAnalyzer.Payload.Task,
        referenceDate: Date
    ) async -> Date? {
        let candidates = [
            normalizedOptionalText(task.dueText),
            normalizedOptionalText(task.smart?.time),
            normalizedOptionalText(task.notes),
        ].compactMap { $0 }

        for candidate in candidates {
            if let dueAt = await DucklingRuntime.shared.resolveDueDate(from: candidate, referenceDate: referenceDate) {
                return dueAt
            }
        }

        return nil
    }

    private static func makeItem(
        id: UUID = UUID(),
        draftID: UUID,
        sortIndex: Int,
        parentItemID: UUID?,
        title: String,
        notes: String?,
        projectName: String?,
        priority: Int?,
        tags: [String],
        dueAt: Date?,
        reminder: RmbReminder,
        urgencyOverride: Int? = nil,
        importanceOverride: Int? = nil,
        smartOverride: [SmartEntry]? = nil
    ) -> ImportDraftItem {
        let urgency = urgencyOverride ?? urgencyScore(
            for: title,
            priority: priority,
            dueAt: dueAt,
            reminder: reminder
        )
        let importance = importanceOverride ?? importanceScore(for: title, priority: priority)
        let urgencyValue = PriorityVector.value(from: urgency)
        let importanceValue = PriorityVector.value(from: importance)
        let smartEntries = smartOverride ?? SmartEvaluator.seededEntries(
            title: title,
            notes: notes,
            dueAt: dueAt
        )
        let smart = SmartEvaluator.evaluate(
            title: title,
            notes: notes,
            smartEntries: smartEntries,
            dueAt: dueAt
        )

        return ImportDraftItem(
            id: id,
            draftID: draftID,
            sortIndex: sortIndex,
            parentItemID: parentItemID,
            proposedTitle: title,
            proposedNotes: notes,
            proposedProjectName: projectName,
            proposedPriority: priority,
            proposedTags: tags,
            proposedUrgencyScore: urgency,
            proposedImportanceScore: importance,
            proposedUrgencyValue: urgencyValue,
            proposedImportanceValue: importanceValue,
            proposedQuadrant: PriorityVector.quadrant(
                urgencyValue: urgencyValue,
                importanceValue: importanceValue
            ),
            proposedDueAt: dueAt,
            smartEntries: smartEntries,
            smartHints: smart.hints,
            isAccepted: true
        )
    }

    private static func smartEntries(
        from smart: LocalModelImportAnalyzer.Payload.Smart?,
        title: String,
        notes: String?,
        dueAt: Date?
    ) -> [SmartEntry] {
        let existingEntries = [
            SmartEntry(key: .action, value: smart?.action?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
            SmartEntry(key: .deliverable, value: smart?.deliverable?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
            SmartEntry(key: .measure, value: smart?.measure?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
            SmartEntry(key: .relevance, value: smart?.relevance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
            SmartEntry(key: .time, value: smart?.time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
        ]

        return SmartEvaluator.seededEntries(
            title: title,
            notes: notes,
            dueAt: dueAt,
            existingEntries: existingEntries
        )
    }

    private static func normalizedTags(_ tags: [String]?) -> [String] {
        Array(
            Set(
                (tags ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .compactMap(\.nilIfBlank)
            )
        ).sorted()
    }

    private static func normalizedOptionalText(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private static func makeResult(
        rawText: String,
        sourceType: ImportSourceType,
        draftID: UUID,
        createdAt: Date,
        items: [ImportDraftItem],
        runtimeNote: String,
        errorMessage: String?
    ) -> ImportParseResult {
        let draft = ImportDraft(
            id: draftID,
            rawText: rawText,
            sourceType: sourceType,
            parseStatus: items.isEmpty ? .failed : .parsed,
            createdAt: createdAt,
            updatedAt: createdAt
        )

        return ImportParseResult(
            draft: draft,
            items: items,
            runtimeNote: runtimeNote,
            errorMessage: errorMessage
        )
    }

    private static func parsedReminder(from text: String) -> RmbReminder {
        var reminder = RmbReminder()
        reminder.title = text
        return reminder
    }

    private static func notes(from parsed: ParsedTaskText) -> String? {
        guard !parsed.assignees.isEmpty else { return nil }
        return "Assignees: \(parsed.assignees.joined(separator: ", "))"
    }

    private static func priorityValue(from priority: EKReminderPriority) -> Int? {
        switch priority {
        case .high:
            return 5
        case .medium:
            return 3
        case .low:
            return 1
        default:
            return nil
        }
    }

    private static func urgencyScore(
        for text: String,
        priority: Int?,
        dueAt: Date?,
        reminder: RmbReminder
    ) -> Int {
        var score = QuadrantAdvisor.urgencyScore(for: text)

        if let priority {
            score = max(score, urgencyScoreForPriority(priority))
        }

        switch reminder.priority {
        case .high:
            score = max(score, 4)
        case .medium:
            score = max(score, 3)
        case .low:
            score = max(score, 2)
        default:
            break
        }

        if let dueAt {
            let hours = dueAt.timeIntervalSinceNow / 3600
            if hours <= 24 {
                score = max(score, 4)
            } else if hours <= 24 * 7 {
                score = max(score, 3)
            }
        }

        return min(4, max(1, score))
    }

    private static func importanceScore(for text: String, priority: Int?) -> Int {
        var score = QuadrantAdvisor.importanceScore(for: text)
        if let priority {
            score = max(score, importanceScoreForPriority(priority))
        }
        return min(4, max(1, score))
    }

    private static func mergedTags(parsed: ParsedTaskText, rawText: String) -> [String] {
        let hashtags = rawText
            .split(separator: " ")
            .compactMap { token -> String? in
                guard token.hasPrefix("#") else { return nil }
                return String(token.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            }

        return Array(Set(parsed.labels + hashtags)).sorted()
    }

    private static func normalizeLegacyStructure(in rawText: String) -> String {
        let lines = rawText.components(separatedBy: .newlines)
        var normalized: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let leadingWhitespace = String(line.prefix { $0 == " " || $0 == "\t" })
            guard let colonIndex = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
                normalized.append(line)
                continue
            }

            let parentTitle = String(trimmed[..<colonIndex]).cleanedTaskTitle()
            let childrenRaw = String(trimmed[trimmed.index(after: colonIndex)...])
            let childParts = childrenRaw.splitForTasks()

            guard !parentTitle.isEmpty, childParts.count > 1 else {
                normalized.append(line)
                continue
            }

            normalized.append("\(leadingWhitespace)\(parentTitle)")
            for child in childParts {
                normalized.append("\(leadingWhitespace)  \(child)")
            }
        }

        return normalized.joined(separator: "\n")
    }

    private static func urgencyScoreForPriority(_ priority: Int) -> Int {
        switch priority {
        case 5:
            return 4
        case 3...4:
            return 3
        case 1...2:
            return 2
        default:
            return 1
        }
    }

    private static func importanceScoreForPriority(_ priority: Int) -> Int {
        switch priority {
        case 4...5:
            return 4
        case 2...3:
            return 3
        case 1:
            return 2
        default:
            return 1
        }
    }
}

enum QuadrantAdvisor {
    static func urgencyScore(for text: String) -> Int {
        let lowered = text.lowercased()
        if containsAny(lowered, tokens: ["今天", "今晚", "明天", "立刻", "马上", "urgent", "asap", "周三前"]) { return 4 }
        if containsAny(lowered, tokens: ["本周", "soon", "尽快", "before", "月底", "next monday"]) { return 3 }
        if containsAny(lowered, tokens: ["下周", "later", "next week"]) { return 2 }
        return 1
    }

    static func importanceScore(for text: String) -> Int {
        let lowered = text.lowercased()
        if containsAny(lowered, tokens: ["发布", "客户", "营收", "核心", "上线", "战略", "launch", "ship"]) { return 4 }
        if containsAny(lowered, tokens: ["文档", "demo", "faq", "计划", "方案", "design", "roadmap"]) { return 3 }
        if containsAny(lowered, tokens: ["整理", "清理", "回顾"]) { return 2 }
        return 1
    }

    static func quadrant(urgency: Int, importance: Int) -> TaskQuadrant {
        switch (urgency >= 3, importance >= 3) {
        case (true, true): .urgentImportant
        case (false, true): .notUrgentImportant
        case (true, false): .urgentNotImportant
        case (false, false): .notUrgentNotImportant
        }
    }

    private static func containsAny(_ text: String, tokens: [String]) -> Bool {
        tokens.contains(where: text.contains)
    }
}

private extension String {
    func cleanedTaskTitle() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[-*•\d\.\)\s]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func splitForTasks() -> [String] {
        split(whereSeparator: { "、，,;；/".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
