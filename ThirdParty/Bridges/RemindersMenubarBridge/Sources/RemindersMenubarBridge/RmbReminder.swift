import EventKit
import Foundation

@MainActor
public struct RmbReminder {
    private var originalReminder: EKReminder?
    private var isPreparingToSave = false
    private var isAutoSuggestingTodayForCreation = false

    public var hasDateChanges: Bool {
        guard let originalReminder else {
            return true
        }

        return hasDueDate != originalReminder.hasDueDate ||
            hasTime != originalReminder.hasTime ||
            date != originalReminder.dueDateComponents?.date
    }

    public var title: String {
        willSet {
            guard !isPreparingToSave else {
                return
            }
            updateTextDateResult(with: newValue)
            updateTextCalendarResult(with: newValue)
            updateTextPriorityResult(with: newValue)
        }
    }

    public var notes: String?
    public var date: Date {
        didSet {
            textDateResult = DateParser.TextDateResult()
            isAutoSuggestingTodayForCreation = false
        }
    }
    public var hasDueDate: Bool {
        didSet {
            if !hasDueDate {
                hasTime = false
            }
        }
    }
    public var hasTime: Bool {
        didSet {
            if hasTime {
                date = .nextExactHour(of: date)
                hasDueDate = true
            }
        }
    }
    public var priority: EKReminderPriority
    public var calendar: EKCalendar?

    public var textDateResult = DateParser.TextDateResult()
    public var textCalendarResult = CalendarParser.TextCalendarResult()
    public var textPriorityResult = PriorityParser.PriorityParserResult()

    public var highlightedTexts: [RmbHighlightedTextField.HighlightedText] {
        [textDateResult.highlightedText, textCalendarResult.highlightedText, textPriorityResult.highlightedText]
    }

    public init() {
        title = ""
        date = .nextExactHour()
        hasDueDate = false
        hasTime = false
        priority = .none
    }

    public init(reminder: EKReminder) {
        originalReminder = reminder
        title = reminder.title
        notes = reminder.notes
        date = reminder.dueDateComponents?.date ?? .nextExactHour()
        hasDueDate = reminder.hasDueDate
        hasTime = reminder.hasTime
        priority = reminder.ekPriority
        calendar = reminder.calendar
    }

    public mutating func setIsAutoSuggestingTodayForCreation() {
        guard !hasDueDate else {
            return
        }
        hasDueDate = true
        isAutoSuggestingTodayForCreation = true
    }

    public mutating func prepareToSave() {
        isPreparingToSave = true
        textDateResult = DateParser.TextDateResult()
        textCalendarResult = CalendarParser.TextCalendarResult()
        textPriorityResult = PriorityParser.PriorityParserResult()
    }

    private mutating func updateTextDateResult(with newTitle: String) {
        if isAutoSuggestingTodayForCreation {
            updateTextDateResultTimeOnly(with: newTitle, isAutoSuggestingToday: true)
            return
        }

        if hasDueDate && textDateResult.string.isEmpty {
            return
        }

        guard let dateResult = DateParser.shared.getDate(from: newTitle) else {
            hasDueDate = false
            hasTime = false
            date = .nextExactHour()
            textDateResult = DateParser.TextDateResult()
            return
        }

        hasDueDate = true
        hasTime = dateResult.hasTime
        date = dateResult.date
        textDateResult = dateResult.textDateResult
    }

    private mutating func updateTextDateResultTimeOnly(with newTitle: String, isAutoSuggestingToday: Bool) {
        if hasTime && textDateResult.string.isEmpty {
            return
        }

        guard let dateResult = DateParser.shared.getTimeOnly(from: newTitle, on: date) else {
            hasTime = false
            textDateResult = DateParser.TextDateResult()
            isAutoSuggestingTodayForCreation = isAutoSuggestingToday
            return
        }

        hasTime = true
        date = dateResult.date
        textDateResult = dateResult.textDateResult
        isAutoSuggestingTodayForCreation = isAutoSuggestingToday
    }

    private mutating func updateTextCalendarResult(with newTitle: String) {
        guard let calendarResult = CalendarParser.getCalendar(from: newTitle) else {
            textCalendarResult = CalendarParser.TextCalendarResult()
            return
        }
        textCalendarResult = calendarResult
    }

    private mutating func updateTextPriorityResult(with newTitle: String) {
        if priority != .none && textPriorityResult.string.isEmpty {
            return
        }

        guard let priorityResult = PriorityParser.getPriority(from: newTitle) else {
            textPriorityResult = PriorityParser.PriorityParserResult()
            priority = .none
            return
        }

        priority = priorityResult.priority
        textPriorityResult = priorityResult
    }
}
