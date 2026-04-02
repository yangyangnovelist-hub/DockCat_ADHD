import Foundation
import EventKit
import RemindersMenubarBridge
import VikunjaQuickAddBridge

@MainActor
enum ImportParser {
    static func parse(
        rawText: String,
        sourceType: ImportSourceType = .text
    ) async -> (draft: ImportDraft, items: [ImportDraftItem]) {
        let now = Date()
        let draftID = UUID()
        let normalizedInput = normalizeLegacyStructure(in: rawText)
        let quickAddLines = VikunjaQuickAdd.parseMultiline(normalizedInput)

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
                referenceDate: now
            ) ?? (reminder.hasDueDate ? reminder.date : nil)

            let urgency = urgencyScore(
                for: parsedText,
                priority: parsedPriority,
                dueAt: dueAt,
                reminder: reminder
            )
            let importance = importanceScore(for: parsedText, priority: parsedPriority)
            let urgencyValue = PriorityVector.value(from: urgency)
            let importanceValue = PriorityVector.value(from: importance)
            let parsedNotes = notes(from: line.parsed)
            let smartEntries = SmartEvaluator.seededEntries(
                title: parsedText,
                notes: parsedNotes,
                dueAt: dueAt
            )
            let smart = SmartEvaluator.evaluate(
                title: parsedText,
                notes: parsedNotes,
                smartEntries: smartEntries,
                dueAt: dueAt
            )

            items.append(
                ImportDraftItem(
                    id: itemID,
                    draftID: draftID,
                    sortIndex: sortIndex,
                    parentItemID: line.parentID.flatMap { lineIDToItemID[$0] },
                    proposedTitle: parsedText,
                    proposedNotes: parsedNotes,
                    proposedProjectName: line.project?.nilIfBlank,
                    proposedPriority: parsedPriority,
                    proposedTags: mergedTags(parsed: line.parsed, rawText: line.originalTitle),
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
            )
        }

        let status: ParseStatus = items.isEmpty ? .failed : .parsed
        let draft = ImportDraft(
            id: draftID,
            rawText: rawText,
            sourceType: sourceType,
            parseStatus: status,
            createdAt: now,
            updatedAt: now
        )

        return (draft, items)
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
