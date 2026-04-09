import XCTest
import GRDB
@testable import DockCatTaskAssistant

final class PerformanceRegressionTests: XCTestCase {
    @MainActor
    func test_taskRenameHotPathBenchmark() throws {
        let taskCount = Self.environmentInt("DOCKCAT_PERF_TASK_COUNT", default: 2_000)
        let iterations = Self.environmentInt("DOCKCAT_PERF_RENAME_ITERATIONS", default: 300)
        var state = TaskUseCases.State(
            snapshot: Self.makeSnapshot(taskCount: taskCount),
            priorityPromptTaskID: nil
        )
        let targetTaskIDs = state.snapshot.tasks.map(\.id)
        let useCases = TaskUseCases(
            getState: { state },
            mutateState: { mutate in mutate(&state) },
            synchronizeMindMapFromTasks: { _ in false },
            persist: { _, _ in },
            refreshPetState: {}
        )

        let metric = Self.measure(
            name: "task_rename_hot_path",
            iterations: iterations,
            warmupIterations: 30,
            batchSize: 10
        ) { iteration in
            let taskID = targetTaskIDs[iteration % targetTaskIDs.count]
            useCases.renameTask(id: taskID, title: "Renamed \(iteration)")
        }

        try assertWithinBaseline(metric)
    }

    func test_mindMapSynchronizationBenchmark() throws {
        let taskCount = Self.environmentInt("DOCKCAT_PERF_TASK_COUNT", default: 2_000)
        let iterations = Self.environmentInt("DOCKCAT_PERF_MINDMAP_ITERATIONS", default: 120)
        var snapshot = Self.makeSnapshot(taskCount: taskCount)
        var currentJSON = MindMapTaskSynchronizer.makeMindMapDataJSON(
            from: snapshot.tasks,
            existingDataJSON: snapshot.mindMapDocument.dataJSON
        )

        let metric = Self.measure(
            name: "mind_map_sync",
            iterations: iterations,
            warmupIterations: 20,
            batchSize: 5
        ) { iteration in
            let index = iteration % snapshot.tasks.count
            snapshot.tasks[index].title = "Mind Map \(iteration)"
            snapshot.tasks[index].touch()
            currentJSON = MindMapTaskSynchronizer.makeMindMapDataJSON(
                from: snapshot.tasks,
                existingDataJSON: currentJSON
            )
        }

        XCTAssertFalse(currentJSON.isEmpty)
        try assertWithinBaseline(metric)
    }

    func test_repositorySaveSnapshotBenchmark() async throws {
        let taskCount = Self.environmentInt("DOCKCAT_PERF_TASK_COUNT", default: 2_000)
        let iterations = Self.environmentInt("DOCKCAT_PERF_SAVE_ITERATIONS", default: 25)
        let repository = try Self.makeRepository()
        var snapshot = Self.makeSnapshot(taskCount: taskCount)
        await repository.saveSnapshot(snapshot, generation: 0)

        let metric = try await Self.measureAsync(
            name: "repository_save_snapshot",
            iterations: iterations,
            warmupIterations: 4,
            batchSize: 2
        ) { iteration in
            let index = iteration % snapshot.tasks.count
            snapshot.tasks[index].title = "Persisted \(iteration)"
            snapshot.tasks[index].touch()
            await repository.saveSnapshot(snapshot, generation: iteration + 1)
        }

        try assertWithinBaseline(metric)
    }

    func test_repositoryColdRestoreBenchmark() async throws {
        let taskCount = Self.environmentInt("DOCKCAT_PERF_TASK_COUNT", default: 2_000)
        let iterations = Self.environmentInt("DOCKCAT_PERF_RESTORE_ITERATIONS", default: 20)
        let databaseURL = try Self.makeTemporaryDatabaseURL(prefix: "cold-restore")
        defer {
            try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
        }

        var snapshot = Self.makeSnapshot(taskCount: taskCount)
        snapshot.projects = Self.makeProjects()
        snapshot.sessions = Self.makeSessions(taskIDs: [snapshot.tasks[0].id])
        snapshot.interrupts = Self.makeInterrupts(sessionIDs: [snapshot.sessions[0].id])
        snapshot.importDrafts = Self.makeDrafts()
        snapshot.importDraftItems = Self.makeDraftItems(draftID: snapshot.importDrafts[0].id)
        snapshot.mindMapDocument = Self.makeMindMapDocument()
        snapshot.preferences = Self.makePreferences()
        snapshot.selectedTaskID = snapshot.tasks.first?.id
        snapshot.lastCelebrationAt = Date(timeIntervalSince1970: 1_700_000_500)

        do {
            let primedRepository = try Self.makeRepository(databaseURL: databaseURL)
            await primedRepository.saveSnapshot(snapshot, generation: 1)
        }

        let metric = try await Self.measureAsync(
            name: "repository_cold_restore",
            iterations: iterations,
            warmupIterations: 2,
            batchSize: 1
        ) { iteration in
            let reopenedRepository = try Self.makeRepository(databaseURL: databaseURL)
            let loaded = await reopenedRepository.loadSnapshot()

            XCTAssertEqual(loaded.projects, snapshot.projects)
            XCTAssertEqual(loaded.tasks.count, snapshot.tasks.count)
            XCTAssertEqual(loaded.sessions, snapshot.sessions)
            XCTAssertEqual(loaded.interrupts, snapshot.interrupts)
            XCTAssertEqual(loaded.importDrafts, snapshot.importDrafts)
            XCTAssertEqual(loaded.importDraftItems, snapshot.importDraftItems)
            XCTAssertEqual(loaded.mindMapDocument, snapshot.mindMapDocument)
            XCTAssertEqual(loaded.preferences, snapshot.preferences)
            XCTAssertEqual(loaded.selectedTaskID, snapshot.selectedTaskID)
            XCTAssertEqual(loaded.lastCelebrationAt, snapshot.lastCelebrationAt)

            snapshot.tasks[iteration % snapshot.tasks.count].title = "Restore \(iteration)"
            snapshot.tasks[iteration % snapshot.tasks.count].touch()
        }

        try assertWithinBaseline(metric)
    }
}

private extension PerformanceRegressionTests {
    struct Metric {
        let name: String
        let medianMilliseconds: Double
        let p95Milliseconds: Double
        let iterations: Int
    }

    struct BaselineManifest: Decodable {
        struct Scenario: Decodable {
            let medianMilliseconds: Double
            let p95Milliseconds: Double

            private enum CodingKeys: String, CodingKey {
                case medianMilliseconds = "median_ms"
                case p95Milliseconds = "p95_ms"
            }
        }

        let allowedRegressionPercent: Double
        let scenarios: [String: Scenario]

        private enum CodingKeys: String, CodingKey {
            case allowedRegressionPercent = "allowed_regression_percent"
            case scenarios
        }
    }

    static func makeRepository() throws -> AppRepository {
        try AppRepository(dbQueue: DatabaseQueue())
    }

    static func makeRepository(databaseURL: URL) throws -> AppRepository {
        let dbQueue = try DatabaseQueue(path: databaseURL.path)
        return try AppRepository(dbQueue: dbQueue)
    }

    static func makeTemporaryDatabaseURL(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockCatTaskAssistantPerf", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("app.sqlite")
    }

    static func makeSnapshot(taskCount: Int) -> AppSnapshot {
        var snapshot = AppSnapshot.empty
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var tasks: [Task] = []
        tasks.reserveCapacity(taskCount)

        for index in 0..<taskCount {
            let parentIndex = index == 0 ? nil : (index - 1) / 4
            let parentTaskID = parentIndex.flatMap { tasks.indices.contains($0) ? tasks[$0].id : nil }
            let status: TaskStatus = index.isMultiple(of: 19) ? .doing : .todo
            let urgencyValue = Double((index % 100) + 1)
            let importanceValue = Double(((index * 7) % 100) + 1)
            let task = Task(
                id: UUID(),
                projectID: nil,
                parentTaskID: parentTaskID,
                sortIndex: index % 4,
                title: "Task \(index)",
                notes: index.isMultiple(of: 3) ? "Benchmark note \(index)" : nil,
                status: status,
                priority: PriorityVector.derivedPriority(
                    urgencyValue: urgencyValue,
                    importanceValue: importanceValue
                ),
                urgencyScore: PriorityVector.score(from: urgencyValue),
                importanceScore: PriorityVector.score(from: importanceValue),
                urgencyValue: urgencyValue,
                importanceValue: importanceValue,
                quadrant: PriorityVector.quadrant(
                    urgencyValue: urgencyValue,
                    importanceValue: importanceValue
                ),
                estimatedMinutes: 25,
                dueAt: nil,
                smartSpecificMissing: false,
                smartMeasurableMissing: false,
                smartActionableMissing: false,
                smartRelevantMissing: false,
                smartBoundedMissing: false,
                smartEntries: SmartFieldKey.allCases.map(SmartEntry.empty),
                tags: index.isMultiple(of: 5) ? ["benchmark", "perf"] : [],
                isCurrent: index == 0,
                createdAt: now.addingTimeInterval(TimeInterval(index)),
                updatedAt: now.addingTimeInterval(TimeInterval(index)),
                completedAt: nil
            )
            tasks.append(task)
        }

        snapshot.tasks = tasks
        snapshot.selectedTaskID = tasks.first?.id
        return snapshot
    }

    static func makeProjects() -> [Project] {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            Project(id: UUID(), name: "Project A", notes: "Harness project A", createdAt: now, updatedAt: now),
            Project(id: UUID(), name: "Project B", notes: nil, createdAt: now.addingTimeInterval(1), updatedAt: now.addingTimeInterval(1))
        ]
    }

    static func makeSessions(taskIDs: [UUID]) -> [Session] {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        guard let taskID = taskIDs.first else { return [] }
        return [
            Session(
                id: UUID(),
                taskID: taskID,
                startedAt: now,
                endedAt: now.addingTimeInterval(300),
                totalSeconds: 300,
                state: .stopped,
                interruptionCount: 1,
                timerMode: .countUp
            )
        ]
    }

    static func makeInterrupts(sessionIDs: [UUID]) -> [Interrupt] {
        let now = Date(timeIntervalSince1970: 1_700_000_200)
        guard let sessionID = sessionIDs.first else { return [] }
        return [
            Interrupt(
                id: UUID(),
                sessionID: sessionID,
                reason: "Harness interruption",
                startedAt: now,
                endedAt: now.addingTimeInterval(30)
            )
        ]
    }

    static func makeDrafts() -> [ImportDraft] {
        let now = Date(timeIntervalSince1970: 1_700_000_300)
        return [
            ImportDraft(
                id: UUID(),
                rawText: "First draft item\nSecond draft item",
                sourceType: .text,
                parseStatus: .parsed,
                createdAt: now,
                updatedAt: now.addingTimeInterval(1)
            )
        ]
    }

    static func makeDraftItems(draftID: UUID) -> [ImportDraftItem] {
        let now = Date(timeIntervalSince1970: 1_700_000_400)
        return [
            ImportDraftItem(
                id: UUID(),
                draftID: draftID,
                sortIndex: 0,
                parentItemID: nil,
                proposedTitle: "Harness item",
                proposedNotes: "Harness notes",
                proposedProjectName: "Project A",
                proposedPriority: 3,
                proposedTags: ["perf", "harness"],
                proposedUrgencyScore: 3,
                proposedImportanceScore: 4,
                proposedUrgencyValue: 60,
                proposedImportanceValue: 80,
                proposedQuadrant: .urgentImportant,
                proposedDueAt: now.addingTimeInterval(3600),
                smartEntries: SmartFieldKey.allCases.map(SmartEntry.empty),
                smartHints: ["具体", "可执行"],
                isAccepted: true
            )
        ]
    }

    static func makeMindMapDocument() -> MindMapDocument {
        MindMapDocument(
            dataJSON: """
            {"root":{"data":{"text":"Harness"},"children":[{"data":{"text":"Node A"},"children":[]}]},"theme":{"template":"default","config":{}},"layout":"logicalStructure","config":{},"view":null}
            """,
            configJSON: #"{"theme":"default"}"#,
            localConfigJSON: #"{"viewport":{"zoom":1}}"#,
            language: "zh",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_450)
        )
    }

    static func makePreferences() -> AppPreference {
        AppPreference(
            petEdge: .left,
            petOffsetY: 168,
            lowDistractionMode: true,
            backgroundTaskIDs: ["harness.persist", "harness.restore"],
            importAnalysis: .disabled
        )
    }

    static func measure(
        name: String,
        iterations: Int,
        warmupIterations: Int = 0,
        batchSize: Int = 1,
        block: (Int) -> Void
    ) -> Metric {
        let clock = ContinuousClock()
        var samples: [Double] = []
        let sanitizedBatchSize = max(1, batchSize)
        samples.reserveCapacity(max(1, iterations / sanitizedBatchSize))

        for iteration in 0..<warmupIterations {
            block(iteration)
        }

        var iteration = 0
        while iteration < iterations {
            let upperBound = min(iteration + sanitizedBatchSize, iterations)
            let start = clock.now
            for currentIteration in iteration..<upperBound {
                block(currentIteration + warmupIterations)
            }
            let elapsed = start.duration(to: clock.now)
            samples.append(elapsed.milliseconds / Double(upperBound - iteration))
            iteration = upperBound
        }

        return makeMetric(name: name, samples: samples, iterations: iterations)
    }

    static func measureAsync(
        name: String,
        iterations: Int,
        warmupIterations: Int = 0,
        batchSize: Int = 1,
        block: (Int) async throws -> Void
    ) async throws -> Metric {
        let clock = ContinuousClock()
        var samples: [Double] = []
        let sanitizedBatchSize = max(1, batchSize)
        samples.reserveCapacity(max(1, iterations / sanitizedBatchSize))

        for iteration in 0..<warmupIterations {
            try await block(iteration)
        }

        var iteration = 0
        while iteration < iterations {
            let upperBound = min(iteration + sanitizedBatchSize, iterations)
            let start = clock.now
            for currentIteration in iteration..<upperBound {
                try await block(currentIteration + warmupIterations)
            }
            let elapsed = start.duration(to: clock.now)
            samples.append(elapsed.milliseconds / Double(upperBound - iteration))
            iteration = upperBound
        }

        return makeMetric(name: name, samples: samples, iterations: iterations)
    }

    static func makeMetric(name: String, samples: [Double], iterations: Int) -> Metric {
        let sorted = samples.sorted()
        let medianIndex = sorted.count / 2
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        let metric = Metric(
            name: name,
            medianMilliseconds: sorted[medianIndex],
            p95Milliseconds: sorted[p95Index],
            iterations: iterations
        )

        print(
            String(
                format: "BENCHMARK_RESULT name=%@ median_ms=%.3f p95_ms=%.3f iterations=%d",
                metric.name,
                metric.medianMilliseconds,
                metric.p95Milliseconds,
                metric.iterations
            )
        )
        return metric
    }

    func assertWithinBaseline(_ metric: Metric) throws {
        guard ProcessInfo.processInfo.environment["DOCKCAT_PERF_ENFORCE"] == "1" else { return }
        let manifest = try Self.loadBaselineManifest()
        guard let scenario = manifest.scenarios[metric.name] else {
            XCTFail("Missing performance baseline for \(metric.name)")
            return
        }

        let multiplier = 1 + (manifest.allowedRegressionPercent / 100)
        XCTAssertLessThanOrEqual(metric.medianMilliseconds, scenario.medianMilliseconds * multiplier, "Median regression in \(metric.name)")
    }

    static func loadBaselineManifest() throws -> BaselineManifest {
        let baselineURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("performance-baseline.json")
        let data = try Data(contentsOf: baselineURL)
        return try JSONDecoder().decode(BaselineManifest.self, from: data)
    }

    static func environmentInt(_ key: String, default defaultValue: Int) -> Int {
        guard let rawValue = ProcessInfo.processInfo.environment[key],
              let value = Int(rawValue),
              value > 0 else {
            return defaultValue
        }
        return value
    }
}

private extension Duration {
    var milliseconds: Double {
        let secondsComponent = Double(components.seconds) * 1_000
        let attosecondsComponent = Double(components.attoseconds) / 1_000_000_000_000_000
        return secondsComponent + attosecondsComponent
    }
}
