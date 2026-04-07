import Foundation

struct PersistenceScope: OptionSet, Sendable {
    let rawValue: Int

    static let projects = PersistenceScope(rawValue: 1 << 0)
    static let tasks = PersistenceScope(rawValue: 1 << 1)
    static let sessions = PersistenceScope(rawValue: 1 << 2)
    static let interrupts = PersistenceScope(rawValue: 1 << 3)
    static let importDrafts = PersistenceScope(rawValue: 1 << 4)
    static let importDraftItems = PersistenceScope(rawValue: 1 << 5)
    static let appState = PersistenceScope(rawValue: 1 << 6)
    static let preferences = PersistenceScope(rawValue: 1 << 7)

    static let taskDomain: PersistenceScope = [.projects, .tasks, .appState, .preferences]
    static let importDomain: PersistenceScope = [.projects, .tasks, .importDrafts, .importDraftItems, .appState, .preferences]
    static let mindMapDomain: PersistenceScope = [.tasks, .appState, .preferences]
    static let preferencesDomain: PersistenceScope = [.preferences]
    static let full: PersistenceScope = [.projects, .tasks, .sessions, .interrupts, .importDrafts, .importDraftItems, .appState, .preferences]
}

actor SnapshotPersistenceCoordinator {
    private struct SaveRequest {
        let snapshot: AppSnapshot
        let generation: Int
        let scope: PersistenceScope
    }

    private let repository: AppRepository
    private let debounceDuration: Duration
    private var pendingRequest: SaveRequest?
    private var workerTask: _Concurrency.Task<Void, Never>?

    init(
        repository: AppRepository,
        debounceDuration: Duration = .milliseconds(200)
    ) {
        self.repository = repository
        self.debounceDuration = debounceDuration
    }

    func scheduleSave(snapshot: AppSnapshot, generation: Int, scope: PersistenceScope = .full) {
        if let pendingRequest {
            self.pendingRequest = SaveRequest(
                snapshot: snapshot,
                generation: generation,
                scope: pendingRequest.scope.union(scope)
            )
        } else {
            self.pendingRequest = SaveRequest(snapshot: snapshot, generation: generation, scope: scope)
        }

        guard workerTask == nil else { return }
        workerTask = _Concurrency.Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        while pendingRequest != nil {
            try? await _Concurrency.Task.sleep(for: debounceDuration)

            guard let request = pendingRequest else { continue }
            pendingRequest = nil
            await repository.saveSnapshot(
                request.snapshot,
                generation: request.generation,
                scope: request.scope
            )
        }

        workerTask = nil
    }
}
