import XCTest
@testable import DockCatTaskAssistant

final class WorkloadPerformanceTests: XCTestCase {
    @MainActor
    func test_rapidTaskEditBurstWorkload() async throws {
        let taskCount = Self.environmentInt("DOCKCAT_WORKLOAD_TASK_COUNT", default: 2_000)
        let editCount = Self.environmentInt("DOCKCAT_WORKLOAD_EDIT_COUNT", default: 120)
        let iterations = Self.environmentInt("DOCKCAT_WORKLOAD_ITERATIONS", default: 3)

        let metric = try await PerformanceHarnessSupport.measureWorkload(
            name: "rapid_task_edit_burst",
            iterations: iterations,
            warmupIterations: 1,
            workUnits: editCount
        ) {
            let baseDirectory = try PerformanceHarnessSupport.makeTemporaryBaseDirectory(prefix: "rapid-edit")
            defer { try? FileManager.default.removeItem(at: baseDirectory) }

            let repository = try PerformanceHarnessSupport.makeRepository(
                databaseURL: baseDirectory.appendingPathComponent("app.sqlite")
            )
            let coordinator = SnapshotPersistenceCoordinator(
                repository: repository,
                debounceDuration: .milliseconds(20)
            )

            var state = TaskUseCases.State(
                snapshot: PerformanceHarnessSupport.makeSnapshot(taskCount: taskCount, includeProjects: true),
                priorityPromptTaskID: nil
            )
            await repository.saveSnapshot(state.snapshot, generation: 0)

            var syncCount = 0
            var persistCount = 0
            let useCases = TaskUseCases(
                getState: { state },
                mutateState: { mutate in mutate(&state) },
                synchronizeMindMapFromTasks: { _ in
                    syncCount += 1
                    state.snapshot.mindMapDocument.dataJSON = MindMapTaskSynchronizer.makeMindMapDataJSON(
                        from: state.snapshot.tasks,
                        existingDataJSON: state.snapshot.mindMapDocument.dataJSON
                    )
                    return true
                },
                persist: { _, _ in
                    persistCount += 1
                },
                refreshPetState: {}
            )

            let taskIDs = state.snapshot.tasks.map(\.id)
            var lastEditedTaskID: UUID?
            for index in 0..<editCount {
                let taskID = taskIDs[index % taskIDs.count]
                lastEditedTaskID = taskID
                useCases.renameTask(id: taskID, title: "Burst \(index)")
                await coordinator.scheduleSave(snapshot: state.snapshot, generation: index + 1)
            }

            let loaded = try await Self.waitForSnapshot(repository: repository) { loaded in
                loaded.tasks.count == state.snapshot.tasks.count &&
                loaded.tasks.first(where: { $0.id == lastEditedTaskID })?.title == "Burst \(editCount - 1)"
            }

            return [
                "edits": "\(editCount)",
                "syncs": "\(syncCount)",
                "persist_events": "\(persistCount)",
                "saved_tasks": "\(loaded.tasks.count)"
            ]
        }

        try PerformanceHarnessSupport.assertWorkloadWithinBaseline(metric, file: "workload-baseline.json")
    }

    @MainActor
    func test_largeImportCommitWorkload() async throws {
        let itemCount = Self.environmentInt("DOCKCAT_WORKLOAD_IMPORT_ITEMS", default: 400)
        let iterations = Self.environmentInt("DOCKCAT_WORKLOAD_ITERATIONS", default: 3)

        let metric = try await PerformanceHarnessSupport.measureWorkload(
            name: "large_import_commit",
            iterations: iterations,
            warmupIterations: 1,
            workUnits: itemCount
        ) {
            let baseDirectory = try PerformanceHarnessSupport.makeTemporaryBaseDirectory(prefix: "import-commit")
            defer { try? FileManager.default.removeItem(at: baseDirectory) }

            let repository = try PerformanceHarnessSupport.makeRepository(
                databaseURL: baseDirectory.appendingPathComponent("app.sqlite")
            )
            var state = ImportUseCases.State(
                snapshot: PerformanceHarnessSupport.makeImportCommitSnapshot(itemCount: itemCount),
                importText: "",
                isImportParsing: false,
                isAudioTranscribing: false,
                importErrorMessage: nil,
                importRuntimeNote: nil
            )
            await repository.saveSnapshot(state.snapshot, generation: 0)

            var mirroredCount = 0
            var persistCount = 0
            var syncCount = 0
            let useCases = ImportUseCases(
                getState: { state },
                mutateState: { mutate in mutate(&state) },
                synchronizeMindMapFromTasks: { _ in
                    syncCount += 1
                    state.snapshot.mindMapDocument.dataJSON = MindMapTaskSynchronizer.makeMindMapDataJSON(
                        from: state.snapshot.tasks,
                        existingDataJSON: state.snapshot.mindMapDocument.dataJSON
                    )
                    return true
                },
                mirrorImportedItems: { items in
                    mirroredCount = items.count
                },
                persist: { _, _ in
                    persistCount += 1
                },
                refreshPetState: {}
            )

            let initialTaskCount = state.snapshot.tasks.count
            useCases.commitLatestDraft()
            await repository.saveSnapshot(state.snapshot, generation: 1)

            let loaded = await repository.loadSnapshot()
            XCTAssertEqual(loaded.tasks.count - initialTaskCount, itemCount)

            return [
                "accepted_items": "\(itemCount)",
                "mirrored_items": "\(mirroredCount)",
                "persist_events": "\(persistCount)",
                "syncs": "\(syncCount)"
            ]
        }

        try PerformanceHarnessSupport.assertWorkloadWithinBaseline(metric, file: "workload-baseline.json")
    }

    @MainActor
    func test_debouncedSnapshotBurstWorkload() async throws {
        let taskCount = Self.environmentInt("DOCKCAT_WORKLOAD_SAVE_TASK_COUNT", default: 1_200)
        let saveRequests = Self.environmentInt("DOCKCAT_WORKLOAD_SAVE_REQUESTS", default: 150)
        let iterations = Self.environmentInt("DOCKCAT_WORKLOAD_ITERATIONS", default: 3)

        let metric = try await PerformanceHarnessSupport.measureWorkload(
            name: "debounced_snapshot_burst",
            iterations: iterations,
            warmupIterations: 1,
            workUnits: saveRequests
        ) {
            let baseDirectory = try PerformanceHarnessSupport.makeTemporaryBaseDirectory(prefix: "snapshot-burst")
            defer { try? FileManager.default.removeItem(at: baseDirectory) }

            let repository = try PerformanceHarnessSupport.makeRepository(
                databaseURL: baseDirectory.appendingPathComponent("app.sqlite")
            )
            let coordinator = SnapshotPersistenceCoordinator(
                repository: repository,
                debounceDuration: .milliseconds(20)
            )
            var snapshot = PerformanceHarnessSupport.makeSnapshot(
                taskCount: taskCount,
                includeProjects: true,
                includeSessions: true,
                includeImportDrafts: true
            )

            for index in 0..<saveRequests {
                let taskIndex = index % snapshot.tasks.count
                snapshot.tasks[taskIndex].title = "Save \(index)"
                snapshot.tasks[taskIndex].touch()
                await coordinator.scheduleSave(snapshot: snapshot, generation: index + 1)
            }

            let expectedTitle = "Save \(saveRequests - 1)"
            let loaded = try await Self.waitForSnapshot(repository: repository) { loaded in
                loaded.tasks[(saveRequests - 1) % loaded.tasks.count].title == expectedTitle
            }
            XCTAssertEqual(loaded.tasks[(saveRequests - 1) % loaded.tasks.count].title, expectedTitle)

            return [
                "save_requests": "\(saveRequests)",
                "task_count": "\(snapshot.tasks.count)",
                "latest_title": expectedTitle
            ]
        }

        try PerformanceHarnessSupport.assertWorkloadWithinBaseline(metric, file: "workload-baseline.json")
    }

    @MainActor
    func test_coldRestoreSnapshotWorkload() async throws {
        let taskCount = Self.environmentInt("DOCKCAT_WORKLOAD_RESTORE_TASK_COUNT", default: 2_000)
        let reopenCount = Self.environmentInt("DOCKCAT_WORKLOAD_REOPEN_COUNT", default: 16)
        let iterations = Self.environmentInt("DOCKCAT_WORKLOAD_ITERATIONS", default: 3)

        let metric = try await PerformanceHarnessSupport.measureWorkload(
            name: "cold_restore_snapshot",
            iterations: iterations,
            warmupIterations: 1,
            workUnits: reopenCount
        ) {
            let baseDirectory = try PerformanceHarnessSupport.makeTemporaryBaseDirectory(prefix: "cold-restore-workload")
            defer { try? FileManager.default.removeItem(at: baseDirectory) }

            let databaseURL = baseDirectory.appendingPathComponent("app.sqlite")
            let repository = try PerformanceHarnessSupport.makeRepository(databaseURL: databaseURL)
            let snapshot = PerformanceHarnessSupport.makeSnapshot(
                taskCount: taskCount,
                includeProjects: true,
                includeSessions: true,
                includeImportDrafts: true
            )
            await repository.saveSnapshot(snapshot, generation: 1)

            for _ in 0..<reopenCount {
                let reopened = try PerformanceHarnessSupport.makeRepository(databaseURL: databaseURL)
                let loaded = await reopened.loadSnapshot()
                XCTAssertEqual(loaded.tasks.count, snapshot.tasks.count)
                XCTAssertEqual(loaded.projects.count, snapshot.projects.count)
                XCTAssertEqual(loaded.importDraftItems.count, snapshot.importDraftItems.count)
            }

            return [
                "reopens": "\(reopenCount)",
                "task_count": "\(snapshot.tasks.count)",
                "draft_items": "\(snapshot.importDraftItems.count)"
            ]
        }

        try PerformanceHarnessSupport.assertWorkloadWithinBaseline(metric, file: "workload-baseline.json")
    }
}

private extension WorkloadPerformanceTests {
    static func environmentInt(_ key: String, default defaultValue: Int) -> Int {
        guard let rawValue = ProcessInfo.processInfo.environment[key],
              let value = Int(rawValue),
              value > 0 else {
            return defaultValue
        }
        return value
    }

    @MainActor
    static func waitForSnapshot(
        repository: AppRepository,
        timeout: Duration = .seconds(3),
        pollInterval: Duration = .milliseconds(50),
        until predicate: (AppSnapshot) -> Bool
    ) async throws -> AppSnapshot {
        let deadline = ContinuousClock().now + timeout
        while true {
            let loaded = await repository.loadSnapshot()
            if predicate(loaded) {
                return loaded
            }
            if ContinuousClock().now >= deadline {
                XCTFail("Timed out waiting for snapshot to reach expected state.")
                return loaded
            }
            try await _Concurrency.Task.sleep(for: pollInterval)
        }
    }
}
