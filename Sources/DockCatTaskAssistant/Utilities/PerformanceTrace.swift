import Foundation
import OSLog

enum PerformanceTrace {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DockCatTaskAssistant",
        category: "Performance"
    )
    private static let signposter = OSSignposter(logger: logger)

    static func begin(_ name: StaticString, details: String) -> OSSignpostIntervalState {
        logger.debug("\(String(describing: name), privacy: .public) begin: \(details, privacy: .public)")
        return signposter.beginInterval(name, id: .exclusive)
    }

    static func end(_ name: StaticString, state: OSSignpostIntervalState, details: String) {
        signposter.endInterval(name, state)
        logger.debug("\(String(describing: name), privacy: .public) end: \(details, privacy: .public)")
    }
}
