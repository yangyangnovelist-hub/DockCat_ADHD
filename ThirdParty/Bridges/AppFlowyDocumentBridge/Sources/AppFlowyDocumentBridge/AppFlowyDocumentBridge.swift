import Foundation

public struct FlowDocument: Hashable, Sendable {
    public var title: String
    public var blocks: [FlowBlock]

    public init(title: String, blocks: [FlowBlock]) {
        self.title = title
        self.blocks = blocks
    }
}

public struct FlowBlock: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case heading
        case todo
        case paragraph
        case metadata
        case note
    }

    public let id: UUID
    public var kind: Kind
    public var text: String
    public var checked: Bool
    public var metadata: [FlowMetadata]
    public var children: [FlowBlock]

    public init(
        id: UUID = UUID(),
        kind: Kind,
        text: String,
        checked: Bool = false,
        metadata: [FlowMetadata] = [],
        children: [FlowBlock] = []
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.checked = checked
        self.metadata = metadata
        self.children = children
    }
}

public struct FlowMetadata: Hashable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
