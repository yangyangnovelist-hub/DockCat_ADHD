import Foundation

enum StatsAggregator {
    static func todayStats(snapshot: AppSnapshot, now: Date = .now, calendar: Calendar = .current) -> DailyStats {
        let completedCount = snapshot.tasks.filter {
            guard let completedAt = $0.completedAt else { return false }
            return calendar.isDate(completedAt, inSameDayAs: now)
        }.count

        return DailyStats(
            completedCount: completedCount,
            focusSeconds: 0,
            interruptionCount: 0
        )
    }
}
