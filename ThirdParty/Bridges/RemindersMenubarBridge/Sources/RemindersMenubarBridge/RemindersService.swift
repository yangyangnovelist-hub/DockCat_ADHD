import EventKit
import Foundation

@MainActor
public final class RemindersService {
    public static let shared = RemindersService()

    private let eventStore = EKEventStore()

    private init() {}

    public func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    public func requestAccess(completion: @Sendable @escaping (Bool, String?) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { granted, error in
                completion(granted, error?.localizedDescription)
            }
        } else {
            eventStore.requestAccess(to: .reminder) { granted, error in
                completion(granted, error?.localizedDescription)
            }
        }
    }

    public func getCalendar(withIdentifier calendarIdentifier: String) -> EKCalendar? {
        eventStore.calendar(withIdentifier: calendarIdentifier)
    }

    public func getCalendars() -> [EKCalendar] {
        let calendars = eventStore.calendars(for: .reminder)
        CalendarParser.updateShared(with: calendars)
        return calendars
    }

    public func getDefaultCalendar() -> EKCalendar? {
        let calendar = eventStore.defaultCalendarForNewReminders() ?? getCalendars().first
        if let calendar {
            CalendarParser.updateShared(with: getCalendars() + [calendar])
        }
        return calendar
    }

    public func save(reminder: EKReminder) {
        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            print("Error saving reminder:", error.localizedDescription)
        }
    }

    public func createNew(with rmbReminder: RmbReminder, in calendar: EKCalendar) {
        let newReminder = EKReminder(eventStore: eventStore)
        newReminder.update(with: rmbReminder)
        newReminder.calendar = calendar
        save(reminder: newReminder)
    }

    public func remove(reminder: EKReminder) {
        do {
            try eventStore.remove(reminder, commit: true)
        } catch {
            print("Error removing reminder:", error.localizedDescription)
        }
    }
}
