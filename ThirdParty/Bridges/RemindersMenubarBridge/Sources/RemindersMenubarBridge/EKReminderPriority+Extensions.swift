import EventKit

extension EKReminderPriority {
    var title: String {
        switch self {
        case .high:
            rmbLocalized(.editReminderPriorityHighOption)
        case .medium:
            rmbLocalized(.editReminderPriorityMediumOption)
        case .low:
            rmbLocalized(.editReminderPriorityLowOption)
        default:
            rmbLocalized(.editReminderPriorityNoneOption)
        }
    }
}
