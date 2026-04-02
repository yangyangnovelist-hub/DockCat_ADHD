import AppKit
import Foundation

@MainActor
public final class DateParser {
    public static let shared = DateParser()

    private let detector: NSDataDetector?

    public struct TextDateResult {
        private let range: NSRange
        public let string: String

        public var highlightedText: RmbHighlightedTextField.HighlightedText {
            RmbHighlightedTextField.HighlightedText(range: range, color: .systemBlue)
        }

        public init() {
            self.range = NSRange()
            self.string = ""
        }

        public init(range: NSRange, string: String) {
            self.range = range
            self.string = string
        }
    }

    public struct DateParserResult {
        public let date: Date
        public let hasTime: Bool
        public let isTimeOnly: Bool
        public let textDateResult: TextDateResult
    }

    private init() {
        let types: NSTextCheckingResult.CheckingType = [.date]
        detector = try? NSDataDetector(types: types.rawValue)
    }

    private func adjustDateAccordingToNow(_ dateResult: DateParserResult) -> DateParserResult? {
        guard dateResult.date.isPast,
              !dateResult.date.isToday,
              !dateResult.date.isYesterday,
              !dateResult.date.isDayBeforeYesterday else {
            return dateResult
        }

        if dateResult.date.isThisYear {
            return DateParserResult(
                date: .nextYear(of: dateResult.date),
                hasTime: dateResult.hasTime,
                isTimeOnly: dateResult.isTimeOnly,
                textDateResult: dateResult.textDateResult
            )
        }

        return dateResult
    }

    private func isTimeSignificant(in match: NSTextCheckingResult) -> Bool {
        let timeIsSignificantKey = "timeIsSignificant"
        if match.responds(to: NSSelectorFromString(timeIsSignificantKey)) {
            return match.value(forKey: timeIsSignificantKey) as? Bool ?? false
        }
        return false
    }

    private func isTimeOnlyResult(in match: NSTextCheckingResult) -> Bool {
        let underlyingResultKey = "underlyingResult"
        if match.responds(to: NSSelectorFromString(underlyingResultKey)) {
            let underlyingResult = match.value(forKey: underlyingResultKey)
            let description = underlyingResult.debugDescription
            return description.contains("Time") && !description.contains("Date")
        }
        return false
    }

    public func getDate(from textString: String) -> DateParserResult? {
        let range = NSRange(textString.startIndex..., in: textString)

        let matches = detector?.matches(in: textString, options: [], range: range)
        guard let match = matches?.first, let date = match.date else {
            return nil
        }

        let hasTime = isTimeSignificant(in: match)
        let isTimeOnly = isTimeOnlyResult(in: match)
        let textDateResult = TextDateResult(
            range: match.range,
            string: textString.substring(in: match.range)
        )

        let dateResult = DateParserResult(
            date: date,
            hasTime: hasTime,
            isTimeOnly: isTimeOnly,
            textDateResult: textDateResult
        )

        return adjustDateAccordingToNow(dateResult)
    }

    public func getTimeOnly(from textString: String, on date: Date) -> DateParserResult? {
        guard let dateResult = getDate(from: textString),
              dateResult.date.isSameDay(as: date) || dateResult.isTimeOnly,
              dateResult.hasTime else {
            return nil
        }

        return dateResult
    }
}
