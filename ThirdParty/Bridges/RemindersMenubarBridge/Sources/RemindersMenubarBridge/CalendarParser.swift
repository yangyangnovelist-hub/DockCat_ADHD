import AppKit
import EventKit
import Foundation

@MainActor
public final class CalendarParser {
    public struct TextCalendarResult {
        private let range: NSRange
        public let string: String
        public let calendar: EKCalendar?

        public var highlightedText: RmbHighlightedTextField.HighlightedText {
            RmbHighlightedTextField.HighlightedText(range: range, color: color(for: calendar))
        }

        public init() {
            self.range = NSRange()
            self.string = ""
            self.calendar = nil
        }

        public init(range: NSRange, string: String, calendar: EKCalendar?) {
            self.range = range
            self.string = string
            self.calendar = calendar
        }

        private func color(for calendar: EKCalendar?) -> NSColor {
            guard let cgColor = calendar?.cgColor, let color = NSColor(cgColor: cgColor) else {
                return .white
            }
            return color
        }
    }

    private var calendarsByTitle: [String: EKCalendar] = [:]
    private var simplifiedCalendarTitles: [String] = []

    private static let validInitialChars: Set<String?> = ["/", "@"]

    public static let shared = CalendarParser()

    private init() {}

    public static func updateShared(with calendars: [EKCalendar]) {
        CalendarParser.shared.calendarsByTitle = calendars.reduce(into: [String: EKCalendar]()) { partialResult, calendar in
            let simplifiedTitle = calendar.title.lowercased().replacingOccurrences(of: " ", with: "-")
            partialResult[simplifiedTitle] = calendar
        }
        CalendarParser.shared.simplifiedCalendarTitles = Array(CalendarParser.shared.calendarsByTitle.keys)
    }

    public static func isInitialCharValid(_ char: String?) -> Bool {
        validInitialChars.contains(char)
    }

    public static func getCalendar(from textString: String) -> TextCalendarResult? {
        let candidates = textString.split(separator: " ").filter {
            CalendarParser.isInitialCharValid(String($0.prefix(1)))
        }

        guard let substringMatch = candidates.first(where: {
            let title = $0.dropFirst().lowercased()
            return CalendarParser.shared.calendarsByTitle[String(title)] != nil
        }) else {
            return nil
        }

        let range = NSRange(substringMatch.startIndex..<substringMatch.endIndex, in: textString)
        let title = String(substringMatch.dropFirst().lowercased())
        let calendar = CalendarParser.shared.calendarsByTitle[title]
        return TextCalendarResult(range: range, string: String(substringMatch), calendar: calendar)
    }

    public static func autoCompleteSuggestions(_ typingWord: String) -> [String] {
        let lowercasedTypingWord = typingWord.lowercased()
        let maxSuggestions = 3
        let matches = CalendarParser.shared.simplifiedCalendarTitles
            .filter { $0.count > lowercasedTypingWord.count && $0.hasPrefix(lowercasedTypingWord) }
            .sorted(by: { $0.count < $1.count })
            .prefix(maxSuggestions)
        return matches.map { typingWord + $0.dropFirst(typingWord.count) }
    }
}
