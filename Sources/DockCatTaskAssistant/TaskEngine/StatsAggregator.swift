import Foundation

enum StatsAggregator {
    static func todayStats(snapshot: AppSnapshot, now: Date = .now, calendar: Calendar = .current) -> DailyStats {
        let completedCount = snapshot.tasks.filter {
            guard let completedAt = $0.completedAt else { return false }
            return calendar.isDate(completedAt, inSameDayAs: now)
        }.count

        let focusSeconds = snapshot.sessions.reduce(into: 0) { total, session in
            let relevantDate = session.endedAt ?? session.startedAt
            guard calendar.isDate(relevantDate, inSameDayAs: now) else { return }
            total += TaskService.liveSeconds(for: session, now: now)
        }

        let interruptionCount = snapshot.interrupts.filter {
            calendar.isDate($0.startedAt, inSameDayAs: now)
        }.count

        return DailyStats(
            completedCount: completedCount,
            focusSeconds: focusSeconds,
            interruptionCount: interruptionCount
        )
    }
}
