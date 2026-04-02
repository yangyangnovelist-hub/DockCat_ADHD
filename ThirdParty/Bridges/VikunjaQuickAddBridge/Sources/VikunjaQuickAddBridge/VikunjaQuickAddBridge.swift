import Foundation

public enum PrefixMode: String, Sendable {
    case disabled
    case vikunja
    case todoist
}

public struct ParsedTaskText: Hashable, Sendable {
    public var text: String
    public var labels: [String]
    public var project: String?
    public var priority: Int?
    public var assignees: [String]

    public init(
        text: String,
        labels: [String] = [],
        project: String? = nil,
        priority: Int? = nil,
        assignees: [String] = []
    ) {
        self.text = text
        self.labels = labels
        self.project = project
        self.priority = priority
        self.assignees = assignees
    }
}

public struct QuickAddLine: Identifiable, Hashable, Sendable {
    public let id: Int
    public let originalTitle: String
    public let parentID: Int?
    public let project: String?
    public let parsed: ParsedTaskText

    public init(
        id: Int,
        originalTitle: String,
        parentID: Int?,
        project: String?,
        parsed: ParsedTaskText
    ) {
        self.id = id
        self.originalTitle = originalTitle
        self.parentID = parentID
        self.project = project
        self.parsed = parsed
    }
}

public enum VikunjaQuickAdd {
    public static func parseTaskText(
        _ text: String,
        prefixMode: PrefixMode = .vikunja
    ) -> ParsedTaskText {
        guard let prefixes = Prefixes(prefixMode: prefixMode) else {
            return ParsedTaskText(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var result = ParsedTaskText(text: text)
        result.labels = getItems(from: result.text, prefix: prefixes.label)
        result.text = cleanupItemText(result.text, items: result.labels, prefix: prefixes.label)

        result.project = getProject(from: result.text, prefixMode: prefixMode)
        if let project = result.project {
            result.text = cleanupItemText(result.text, items: [project], prefix: prefixes.project)
        }

        result.priority = getPriority(from: result.text, prefix: prefixes.priority)
        if let priority = result.priority {
            result.text = cleanupItemText(result.text, items: [String(priority)], prefix: prefixes.priority)
        }

        result.assignees = getItems(from: result.text, prefix: prefixes.assignee)
        result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    public static func parseMultiline(
        _ text: String,
        prefixMode: PrefixMode = .vikunja
    ) -> [QuickAddLine] {
        let preparedLines = normalize(lines: text.components(separatedBy: .newlines))
        guard !preparedLines.isEmpty else { return [] }

        var parsedLines: [QuickAddLine] = []

        for (index, line) in preparedLines.enumerated() {
            let indentation = line.indentation
            let cleaned = cleanupTitle(line.text)
            var parentID: Int?
            var inheritedProject: String?

            if indentation > 0 {
                var probe = index - 1
                while probe >= 0 {
                    let candidate = preparedLines[probe]
                    if candidate.indentation < indentation {
                        parentID = probe
                        inheritedProject = parsedLines[probe].project
                        break
                    }
                    probe -= 1
                }
            }

            var parsed = parseTaskText(cleaned, prefixMode: prefixMode)
            if parsed.project == nil {
                parsed.project = inheritedProject
            }

            parsedLines.append(
                QuickAddLine(
                    id: index,
                    originalTitle: cleaned,
                    parentID: parentID,
                    project: parsed.project,
                    parsed: parsed
                )
            )
        }

        return parsedLines
    }
}

private extension VikunjaQuickAdd {
    struct Prefixes {
        let label: Character
        let project: Character
        let priority: Character
        let assignee: Character

        init?(prefixMode: PrefixMode) {
            switch prefixMode {
            case .disabled:
                return nil
            case .vikunja:
                self.label = "*"
                self.project = "+"
                self.priority = "!"
                self.assignee = "@"
            case .todoist:
                self.label = "@"
                self.project = "#"
                self.priority = "!"
                self.assignee = "+"
            }
        }
    }

    struct PreparedLine: Sendable {
        let text: String
        let indentation: Int
    }

    static func normalize(lines: [String]) -> [PreparedLine] {
        let filtered = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !filtered.isEmpty else { return [] }

        let leadingCounts = filtered
            .map(\.leadingWhitespaceCount)
            .filter { $0 > 0 }
        let minimumIndent = leadingCounts.min() ?? 0

        return filtered.map { line in
            let adjusted = minimumIndent > 0 && line.leadingWhitespaceCount >= minimumIndent
                ? String(line.dropFirst(minimumIndent))
                : line
            return PreparedLine(text: adjusted, indentation: adjusted.leadingWhitespaceCount)
        }
    }

    static func cleanupTitle(_ title: String) -> String {
        title
            .replacingOccurrences(
                of: #"^((\* |\+ |- )(\[ \] )?)"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func getProject(from text: String, prefixMode: PrefixMode) -> String? {
        guard let projectPrefix = Prefixes(prefixMode: prefixMode)?.project else {
            return nil
        }
        return getItems(from: text, prefix: projectPrefix).first
    }

    static func getPriority(from text: String, prefix: Character) -> Int? {
        let allowed = Set(1...5)
        for item in getItems(from: text, prefix: prefix) {
            guard let priority = Int(item), allowed.contains(priority) else {
                continue
            }
            return priority
        }
        return nil
    }

    static func getItems(from text: String, prefix: Character) -> [String] {
        var items: [String] = []
        let needle = " \(prefix)"
        var parts = text.components(separatedBy: needle)

        if text.hasPrefix(String(prefix)) {
            parts.insert(String(text.dropFirst()), at: 0)
        }

        for (index, rawPart) in parts.enumerated() {
            if index == 0 {
                continue
            }

            var part = rawPart
            if part.first == prefix {
                part.removeFirst()
            }

            let item: String
            if part.first == "'" {
                item = String(part.dropFirst().prefix { $0 != "'" })
            } else if part.first == "\"" {
                item = String(part.dropFirst().prefix { $0 != "\"" })
            } else {
                item = String(part.prefix { !$0.isWhitespace })
            }

            if !item.isEmpty, !items.contains(item) {
                items.append(item)
            }
        }

        return items
    }

    static func cleanupItemText(_ text: String, items: [String], prefix: Character) -> String {
        items.reduce(text) { partial, item in
            guard !item.isEmpty else { return partial }
            let escaped = NSRegularExpression.escapedPattern(for: item)
            let prefixPattern = NSRegularExpression.escapedPattern(for: String(prefix))
            let patterns = [
                #"\#(prefixPattern)'\#(escaped)' ?"#,
                #"\#(prefixPattern)"\#(escaped)" ?"#,
                #"\#(prefixPattern)\#(escaped) ?"#,
            ]

            return patterns.reduce(partial) { candidate, pattern in
                candidate.replacingOccurrences(
                    of: pattern,
                    with: "",
                    options: [.regularExpression, .caseInsensitive]
                )
            }
        }
    }
}

private extension String {
    var leadingWhitespaceCount: Int {
        prefix { $0 == " " || $0 == "\t" }.reduce(into: 0) { count, character in
            count += character == "\t" ? 2 : 1
        }
    }
}
