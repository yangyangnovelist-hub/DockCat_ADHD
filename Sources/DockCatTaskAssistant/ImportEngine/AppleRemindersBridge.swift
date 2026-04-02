import EventKit
import Foundation
import RemindersMenubarBridge

@MainActor
final class AppleRemindersBridge {
    private let service: RemindersService

    init(service: RemindersService = .shared) {
        self.service = service
    }

    func mirrorImportedItems(_ items: [ImportDraftItem]) async {
        guard await ensureAccessGranted(), let calendar = service.getDefaultCalendar() else {
            return
        }

        for item in items {
            var reminder = RmbReminder()
            reminder.title = item.proposedTitle
            reminder.notes = item.proposedNotes
            reminder.calendar = calendar

            if reminder.priority == .none {
                reminder.priority = mappedPriority(for: item)
            }

            if let dueAt = item.proposedDueAt {
                reminder.date = dueAt
                reminder.hasDueDate = true
                reminder.hasTime = dueAt.includesExplicitTime
            }

            reminder.prepareToSave()
            service.createNew(with: reminder, in: calendar)
        }
    }

    private func ensureAccessGranted() async -> Bool {
        let status = service.authorizationStatus()
        if #available(macOS 14.0, *) {
            if status == .fullAccess || status == .writeOnly || status == .authorized {
                return true
            }
        } else if status == .authorized {
            return true
        }

        guard status == .notDetermined else {
            return false
        }

        return await withCheckedContinuation { continuation in
            service.requestAccess { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func mappedPriority(for item: ImportDraftItem) -> EKReminderPriority {
        switch item.proposedUrgencyScore ?? 1 {
        case 4: .high
        case 3: .medium
        case 2: .low
        default: .none
        }
    }
}

private extension Date {
    var includesExplicitTime: Bool {
        let components = Calendar.current.dateComponents([.hour, .minute, .second], from: self)
        return (components.hour ?? 0) != 0 || (components.minute ?? 0) != 0 || (components.second ?? 0) != 0
    }
}
