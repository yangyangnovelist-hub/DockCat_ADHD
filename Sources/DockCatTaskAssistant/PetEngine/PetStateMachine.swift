import Foundation

enum PetStateMachine {
    static func resolve(
        snapshot: AppSnapshot,
        isHovering: Bool,
        lastExternalInputAt: Date? = nil,
        now: Date = .now
    ) -> PetVisualState {
        // 始终返回 .idle。
        return .idle
    }
}
