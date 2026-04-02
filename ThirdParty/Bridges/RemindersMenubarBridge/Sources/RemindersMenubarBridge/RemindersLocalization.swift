import Foundation

public enum RemindersMenuBarLocalizedKeys: String {
    case editReminderPriorityHighOption
    case editReminderPriorityMediumOption
    case editReminderPriorityLowOption
    case editReminderPriorityNoneOption
    case upcomingRemindersDueFilterOption
    case upcomingRemindersTodayFilterOption
    case upcomingRemindersInAWeekFilterOption
    case upcomingRemindersInAMonthFilterOption
    case upcomingRemindersAllFilterOption
    case upcomingRemindersDueSectionTitle
    case upcomingRemindersTodaySectionTitle
    case upcomingRemindersInAWeekSectionTitle
    case upcomingRemindersInAMonthSectionTitle
    case upcomingRemindersScheduledSectionTitle
}

public func rmbLocalized(_ key: RemindersMenuBarLocalizedKeys, arguments: CVarArg...) -> String {
    String(format: key.rawValue, arguments: arguments)
}

public func rmbTimeFormattedLocale() -> Locale {
    Locale.current
}
