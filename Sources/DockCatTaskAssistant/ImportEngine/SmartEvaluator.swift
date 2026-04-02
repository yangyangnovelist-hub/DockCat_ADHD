import Foundation

struct SmartAssessment {
    var specificMissing: Bool
    var measurableMissing: Bool
    var actionableMissing: Bool
    var relevantMissing: Bool
    var boundedMissing: Bool
    var hints: [String]
}

enum SmartEvaluator {
    static func evaluate(
        title: String,
        notes: String? = nil,
        smartEntries: [SmartEntry] = [],
        dueAt: Date? = nil
    ) -> SmartAssessment {
        let entries = seededEntries(
            title: title,
            notes: notes,
            dueAt: dueAt,
            existingEntries: smartEntries
        )

        let specificMissing = entries.value(for: .deliverable) == nil
        let measurableMissing = meaningfulMeasure(entries.value(for: .measure)) == nil
        let actionableMissing = entries.value(for: .action) == nil
        let relevantMissing = entries.value(for: .relevance) == nil
        let boundedMissing = dueAt == nil && entries.value(for: .time) == nil

        var hints: [String] = []
        if specificMissing { hints.append("建议把任务改写成更具体的交付结果") }
        if measurableMissing { hints.append("建议加入数量、时长或验收标准") }
        if actionableMissing { hints.append("建议先判断它是否可直接执行，或是否还需要拆分") }
        if relevantMissing { hints.append("建议写下任务价值，便于判断重要度") }
        if boundedMissing { hints.append("建议加上截止时间或时间窗口") }

        return SmartAssessment(
            specificMissing: specificMissing,
            measurableMissing: measurableMissing,
            actionableMissing: actionableMissing,
            relevantMissing: relevantMissing,
            boundedMissing: boundedMissing,
            hints: hints
        )
    }

    static func seededEntries(
        title: String,
        notes: String? = nil,
        dueAt: Date? = nil,
        existingEntries: [SmartEntry] = []
    ) -> [SmartEntry] {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullText = [normalizedTitle, normalizedNotes].compactMap { $0 }.joined(separator: " ")

        return SmartFieldKey.allCases.map { key in
            if let existingEntry = existingEntries.first(where: { $0.key == key }) {
                return SmartEntry(key: key, value: existingEntry.value)
            }

            let generatedValue: String?
            switch key {
            case .action:
                generatedValue = extractAchievability(from: normalizedTitle, notes: normalizedNotes)
            case .deliverable:
                generatedValue = extractDeliverable(from: normalizedTitle)
            case .measure:
                generatedValue = extractMeasure(from: fullText)
            case .relevance:
                generatedValue = extractRelevance(title: normalizedTitle, notes: normalizedNotes)
            case .time:
                generatedValue = dueAt.map(formatDate) ?? extractTimeframe(from: fullText)
            }

            return SmartEntry(key: key, value: generatedValue ?? "")
        }
    }

    private static func meaningfulMeasure(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["数量", "时长", "验收"].contains(trimmed) {
            return nil
        }
        let normalized = trimmed
            .replacingOccurrences(of: "数量：", with: "")
            .replacingOccurrences(of: "时长：", with: "")
            .replacingOccurrences(of: "验收：", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func extractAchievability(from title: String, notes: String?) -> String? {
        let fullText = [title, notes].compactMap { $0?.lowercased() }.joined(separator: " ")
        let collaborationTokens = ["联系", "评审", "审批", "同步", "对齐", "确认", "等待", "review", "approve", "align"]
        if collaborationTokens.contains(where: fullText.contains) {
            return "需协作"
        }

        let splitTokens = ["并", "以及", "同时", "和", "、"]
        if splitTokens.contains(where: title.contains), title.count >= 8 {
            return "需拆分"
        }

        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "可直接做"
    }

    private static func extractDeliverable(from title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        let separators = ["：", ":", "-", "—"]
        if let token = separators.compactMap({ separator in
            trimmed.components(separatedBy: separator).last?.trimmingCharacters(in: .whitespacesAndNewlines)
        }).first(where: { $0.count >= 2 }) {
            return token
        }
        let cleaned = trimmed
            .replacingOccurrences(of: #"^(做|写|整理|联系|完成|发布|准备|修复)\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func extractMeasure(from text: String) -> String? {
        guard let match = text.range(of: #"\d+\s*(分钟|小时|天|页|个|版|次|%|人|项)?"#, options: .regularExpression) else {
            return nil
        }
        let value = String(text[match])
        let durationUnits = ["分钟", "小时", "天"]
        let prefix = durationUnits.contains(where: value.contains) ? "时长" : "数量"
        return "\(prefix)：\(value)"
    }

    private static func extractRelevance(title: String, notes: String?) -> String? {
        let lowered = title.lowercased()
        let tokens = ["发布", "客户", "营收", "核心", "上线", "战略", "launch", "ship"]
        if tokens.contains(where: lowered.contains) {
            return "推进目标"
        }
        if let notes, notes.count >= 6 {
            return "降低风险"
        }
        return nil
    }

    private static func extractTimeframe(from text: String) -> String? {
        let tokens = ["今天", "明天", "本周", "下周", "月底", "周一", "周二", "周三", "周四", "周五", "before", "tomorrow", "next week"]
        return tokens.first { text.lowercased().contains($0.lowercased()) }
    }
}
