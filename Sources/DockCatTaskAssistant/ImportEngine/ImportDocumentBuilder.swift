import Foundation
import AppFlowyDocumentBridge

enum ImportDocumentBuilder {
    static func build(draft: ImportDraft?, items: [ImportDraftItem]) -> FlowDocument {
        let title = title(for: draft?.sourceType)
        let grouped = Dictionary(grouping: items) { $0.parentItemID }
        let roots = (grouped[nil] ?? []).sorted { $0.sortIndex < $1.sortIndex }

        var blocks: [FlowBlock] = []

        if let draft, !draft.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(FlowBlock(kind: .heading, text: title))
            blocks.append(FlowBlock(kind: .paragraph, text: draft.rawText.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        blocks.append(contentsOf: roots.map { block(for: $0, grouped: grouped) })
        return FlowDocument(title: title, blocks: blocks)
    }

    private static func block(
        for item: ImportDraftItem,
        grouped: [UUID?: [ImportDraftItem]]
    ) -> FlowBlock {
        let children = (grouped[item.id] ?? [])
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { block(for: $0, grouped: grouped) }

        return FlowBlock(
            id: item.id,
            kind: .todo,
            text: item.proposedTitle,
            checked: item.isAccepted,
            metadata: metadata(for: item),
            children: children
        )
    }

    private static func metadata(for item: ImportDraftItem) -> [FlowMetadata] {
        var values: [FlowMetadata] = []

        if let urgency = item.proposedUrgencyValue {
            values.append(FlowMetadata(key: "Urgency", value: percentageText(for: urgency)))
        }
        if let importance = item.proposedImportanceValue {
            values.append(FlowMetadata(key: "Importance", value: percentageText(for: importance)))
        }
        if let dueAt = item.proposedDueAt {
            values.append(FlowMetadata(key: "Due", value: formatDate(dueAt)))
        }
        if let quadrant = item.proposedQuadrant {
            values.append(FlowMetadata(key: "Quadrant", value: quadrant.title))
        }
        if !item.proposedTags.isEmpty {
            values.append(FlowMetadata(key: "Tags", value: item.proposedTags.joined(separator: ", ")))
        }
        if !item.smartHints.isEmpty {
            values.append(FlowMetadata(key: "SMART", value: item.smartHints.joined(separator: " · ")))
        }

        return values
    }

    private static func title(for sourceType: ImportSourceType?) -> String {
        switch sourceType {
        case .voice:
            return "Voice Capture"
        case .markdown:
            return "Markdown Capture"
        case .csv:
            return "CSV Capture"
        case .text, .none:
            return "Quick Capture"
        }
    }

    private static func percentageText(for value: Double) -> String {
        String(format: "%.2f%%", PriorityVector.clampedPercentage(value))
    }
}
