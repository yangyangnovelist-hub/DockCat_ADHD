import EventKit

@MainActor
extension EKReminder {
    var hasDueDate: Bool {
        dueDateComponents != nil
    }

    var hasTime: Bool {
        dueDateComponents?.hour != nil
    }

    var ekPriority: EKReminderPriority {
        get {
            EKReminderPriority(rawValue: UInt(priority)) ?? .none
        }
        set {
            priority = Int(newValue.rawValue)
        }
    }

    func update(with rmbReminder: RmbReminder) {
        let trimmedTitle = rmbReminder.title.trimmingCharacters(in: .whitespaces)
        if !trimmedTitle.isEmpty {
            title = trimmedTitle
        }

        notes = rmbReminder.notes

        if rmbReminder.hasDateChanges {
            removeDueDateAndAlarms()
            if rmbReminder.hasDueDate {
                addDueDateAndAlarm(for: rmbReminder.date, withTime: rmbReminder.hasTime)
            } else {
                removeAllRecurrenceRules()
            }
        }

        ekPriority = rmbReminder.priority
        calendar = rmbReminder.calendar
    }

    private func removeDueDateAndAlarms() {
        dueDateComponents = nil
        alarms?.forEach { alarm in
            removeAlarm(alarm)
        }
    }

    private func removeAllRecurrenceRules() {
        recurrenceRules?.forEach { rule in
            removeRecurrenceRule(rule)
        }
    }

    private func addDueDateAndAlarm(for date: Date, withTime hasTime: Bool) {
        let dateComponents = date.dateComponents(withTime: hasTime)
        dueDateComponents = dateComponents

        if hasTime, let absoluteDate = dateComponents.date {
            addAlarm(EKAlarm(absoluteDate: absoluteDate))
        }
    }
}
