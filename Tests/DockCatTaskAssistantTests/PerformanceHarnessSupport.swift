import XCTest
import GRDB
@testable import DockCatTaskAssistant

enum PerformanceHarnessSupport {
    struct Metric {
        let name: String
        let medianMilliseconds: Double
        let p95Milliseconds: Double
        let iterations: Int
    }

    struct WorkloadMetric {
        let name: String
        let medianMilliseconds: Double
        let p95Milliseconds: Double
        let throughputPerSecond: Double
        let iterations: Int
        let metadata: [String: String]
    }

    struct PerformanceBaselineManifest: Decodable {
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

    struct WorkloadBaselineManifest: Decodable {
        struct Scenario: Decodable {
            let medianMilliseconds: Double
            let minThroughputPerSecond: Double

            private enum CodingKeys: String, CodingKey {
                case medianMilliseconds = "median_ms"
                case minThroughputPerSecond = "min_throughput_per_second"
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

    static func makeTemporaryBaseDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockCatTaskAssistantPerf", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func makeSnapshot(
        taskCount: Int,
        includeProjects: Bool = false,
        includeSessions: Bool = false,
        includeImportDrafts: Bool = false
    ) -> AppSnapshot {
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
                projectID: includeProjects && index.isMultiple(of: 8) ? UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index % 8 + 1))") : nil,
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
                dueAt: index.isMultiple(of: 11) ? now.addingTimeInterval(Double(index) * 600) : nil,
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

        if includeProjects {
            snapshot.projects = (0..<8).map { index in
                Project(
                    id: UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", index + 1))") ?? UUID(),
                    name: "Project \(index)",
                    notes: index.isMultiple(of: 2) ? "Project note \(index)" : nil,
                    createdAt: now.addingTimeInterval(TimeInterval(index)),
                    updatedAt: now.addingTimeInterval(TimeInterval(index))
                )
            }
        }

        if includeSessions, let taskID = tasks.first?.id {
            snapshot.sessions = (0..<12).map { index in
                Session(
                    id: UUID(),
                    taskID: taskID,
                    startedAt: now.addingTimeInterval(TimeInterval(index * 90)),
                    endedAt: index.isMultiple(of: 3) ? nil : now.addingTimeInterval(TimeInterval(index * 90 + 60)),
                    totalSeconds: index * 60,
                    state: index.isMultiple(of: 4) ? .active : .stopped,
                    interruptionCount: index % 3,
                    timerMode: .countUp,
                    countdownTargetSeconds: nil
                )
            }
            snapshot.interrupts = snapshot.sessions.enumerated().compactMap { index, session in
                guard index.isMultiple(of: 2) else { return nil }
                return Interrupt(
                    id: UUID(),
                    sessionID: session.id,
                    reason: "Interrupt \(index)",
                    startedAt: session.startedAt.addingTimeInterval(15),
                    endedAt: session.startedAt.addingTimeInterval(45)
                )
            }
        }

        if includeImportDrafts {
            let draftID = UUID()
            snapshot.importDrafts = [
                ImportDraft(
                    id: draftID,
                    rawText: "alpha\nbeta\ngamma",
                    sourceType: .text,
                    parseStatus: .pending,
                    createdAt: now,
                    updatedAt: now
                )
            ]
            snapshot.importDraftItems = (0..<48).map { index in
                ImportDraftItem(
                    id: UUID(),
                    draftID: draftID,
                    sortIndex: index,
                    parentItemID: nil,
                    proposedTitle: "Draft Item \(index)",
                    proposedNotes: index.isMultiple(of: 3) ? "Draft note \(index)" : nil,
                    proposedProjectName: index.isMultiple(of: 5) ? "Project \(index % 4)" : nil,
                    proposedPriority: index % 5,
                    proposedTags: index.isMultiple(of: 2) ? ["draft", "benchmark"] : [],
                    proposedUrgencyScore: 2 + (index % 2),
                    proposedImportanceScore: 3,
                    proposedUrgencyValue: 55,
                    proposedImportanceValue: 70,
                    proposedQuadrant: .notUrgentImportant,
                    proposedDueAt: index.isMultiple(of: 7) ? now.addingTimeInterval(Double(index) * 900) : nil,
                    smartEntries: SmartFieldKey.allCases.map(SmartEntry.empty),
                    smartHints: index.isMultiple(of: 6) ? ["Add acceptance criteria"] : [],
                    isAccepted: !index.isMultiple(of: 5)
                )
            }
        }

        snapshot.mindMapDocument = MindMapDocument(
            dataJSON: MindMapTaskSynchronizer.makeMindMapDataJSON(
                from: snapshot.tasks,
                existingDataJSON: snapshot.mindMapDocument.dataJSON
            ),
            configJSON: snapshot.mindMapDocument.configJSON,
            localConfigJSON: snapshot.mindMapDocument.localConfigJSON,
            language: snapshot.mindMapDocument.language,
            updatedAt: now
        )
        snapshot.lastCelebrationAt = now
        return snapshot
    }

    static func makeImportCommitSnapshot(itemCount: Int) -> AppSnapshot {
        var snapshot = makeSnapshot(taskCount: 120, includeProjects: true)
        let now = Date(timeIntervalSince1970: 1_700_001_000)
        let draftID = UUID()
        snapshot.importDrafts = [
            ImportDraft(
                id: draftID,
                rawText: "bulk import",
                sourceType: .text,
                parseStatus: .parsed,
                createdAt: now,
                updatedAt: now
            )
        ]
        var items: [ImportDraftItem] = []
        items.reserveCapacity(itemCount)
        for index in 0..<itemCount {
            let parentItemID = index > 0 && index.isMultiple(of: 4) ? items[safe: index - 4]?.id : nil
            let item = ImportDraftItem(
                id: UUID(),
                draftID: draftID,
                sortIndex: index,
                parentItemID: parentItemID,
                proposedTitle: "Imported Task \(index)",
                proposedNotes: index.isMultiple(of: 3) ? "Imported note \(index)" : nil,
                proposedProjectName: "Project \(index % 6)",
                proposedPriority: (index % 5) + 1,
                proposedTags: ["imported", "bulk"],
                proposedUrgencyScore: 2 + (index % 2),
                proposedImportanceScore: 3 + (index % 2),
                proposedUrgencyValue: 60,
                proposedImportanceValue: 72,
                proposedQuadrant: .urgentImportant,
                proposedDueAt: index.isMultiple(of: 9) ? now.addingTimeInterval(Double(index) * 1_200) : nil,
                smartEntries: SmartFieldKey.allCases.map(SmartEntry.empty),
                smartHints: [],
                isAccepted: true
            )
            items.append(item)
        }
        snapshot.importDraftItems = items
        return snapshot
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

    @MainActor
    static func measureWorkload(
        name: String,
        iterations: Int,
        warmupIterations: Int = 0,
        workUnits: Int = 1,
        block: () async throws -> [String: String]
    ) async throws -> WorkloadMetric {
        let clock = ContinuousClock()
        var samples: [Double] = []
        var metadata: [String: String] = [:]

        for _ in 0..<warmupIterations {
            _ = try await block()
        }

        for _ in 0..<iterations {
            let start = clock.now
            metadata = try await block()
            let elapsed = start.duration(to: clock.now)
            samples.append(elapsed.milliseconds)
        }

        let sorted = samples.sorted()
        let medianIndex = sorted.count / 2
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        let median = sorted[medianIndex]
        let throughputPerSecond = median > 0 ? (Double(max(1, workUnits)) * 1_000) / median : 0
        let metric = WorkloadMetric(
            name: name,
            medianMilliseconds: median,
            p95Milliseconds: sorted[p95Index],
            throughputPerSecond: throughputPerSecond,
            iterations: iterations,
            metadata: metadata
        )

        let metadataString = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        print(
            String(
                format: "WORKLOAD_RESULT name=%@ median_ms=%.3f p95_ms=%.3f throughput_per_second=%.3f iterations=%d%@",
                metric.name,
                metric.medianMilliseconds,
                metric.p95Milliseconds,
                metric.throughputPerSecond,
                metric.iterations,
                metadataString.isEmpty ? "" : " " + metadataString
            )
        )
        return metric
    }

    static func assertBenchmarkWithinBaseline(_ metric: Metric, file fixtureName: String) throws {
        guard ProcessInfo.processInfo.environment["DOCKCAT_PERF_ENFORCE"] == "1" else { return }
        let manifest = try loadPerformanceBaselineManifest(named: fixtureName)
        guard let scenario = manifest.scenarios[metric.name] else {
            XCTFail("Missing performance baseline for \(metric.name)")
            return
        }

        let multiplier = 1 + (manifest.allowedRegressionPercent / 100)
        XCTAssertLessThanOrEqual(
            metric.medianMilliseconds,
            scenario.medianMilliseconds * multiplier,
            "Median regression in \(metric.name)"
        )
    }

    static func assertWorkloadWithinBaseline(_ metric: WorkloadMetric, file fixtureName: String) throws {
        guard ProcessInfo.processInfo.environment["DOCKCAT_PERF_ENFORCE"] == "1" else { return }
        let manifest = try loadWorkloadBaselineManifest(named: fixtureName)
        guard let scenario = manifest.scenarios[metric.name] else {
            XCTFail("Missing workload baseline for \(metric.name)")
            return
        }

        let multiplier = 1 + (manifest.allowedRegressionPercent / 100)
        XCTAssertLessThanOrEqual(
            metric.medianMilliseconds,
            scenario.medianMilliseconds * multiplier,
            "Median regression in \(metric.name)"
        )
        XCTAssertGreaterThanOrEqual(
            metric.throughputPerSecond,
            scenario.minThroughputPerSecond,
            "Throughput regression in \(metric.name)"
        )
    }

    static func canonicalized(_ snapshot: AppSnapshot) -> AppSnapshot {
        var copy = snapshot
        copy.projects.sort { $0.id.uuidString < $1.id.uuidString }
        copy.tasks.sort { $0.id.uuidString < $1.id.uuidString }
        copy.sessions.sort { $0.id.uuidString < $1.id.uuidString }
        copy.interrupts.sort { $0.id.uuidString < $1.id.uuidString }
        copy.importDrafts.sort { $0.id.uuidString < $1.id.uuidString }
        copy.importDraftItems.sort { $0.id.uuidString < $1.id.uuidString }
        return copy
    }

    static func encodeCanonicalSnapshot(_ snapshot: AppSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(canonicalized(snapshot))
    }

    private static func loadPerformanceBaselineManifest(named fixtureName: String) throws -> PerformanceBaselineManifest {
        let data = try Data(contentsOf: fixtureURL(named: fixtureName))
        return try JSONDecoder().decode(PerformanceBaselineManifest.self, from: data)
    }

    private static func loadWorkloadBaselineManifest(named fixtureName: String) throws -> WorkloadBaselineManifest {
        let data = try Data(contentsOf: fixtureURL(named: fixtureName))
        return try JSONDecoder().decode(WorkloadBaselineManifest.self, from: data)
    }

    private static func fixtureURL(named fixtureName: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(fixtureName)
    }
}

private extension Duration {
    var milliseconds: Double {
        let secondsComponent = Double(components.seconds) * 1_000
        let attosecondsComponent = Double(components.attoseconds) / 1_000_000_000_000_000
        return secondsComponent + attosecondsComponent
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
