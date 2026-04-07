import Foundation
import XCTest
import GRDB
@testable import DockCatTaskAssistant

final class PersistenceHarnessTests: XCTestCase {
    func test_snapshotRoundTripPersistsAllPrimaryTables() async throws {
        let baseDirectory = try Self.makeTemporaryBaseDirectory(name: "round-trip")
        defer {
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let snapshot = Self.makeFullSnapshot()
        let databaseURL = baseDirectory.appendingPathComponent("app.sqlite")

        do {
            let repository = try Self.makeRepository(databaseURL: databaseURL)
            await repository.saveSnapshot(snapshot, generation: 1)
        }

        let reopenedRepository = try Self.makeRepository(databaseURL: databaseURL)
        let loaded = await reopenedRepository.loadSnapshot()

        XCTAssertEqual(loaded.projects, snapshot.projects)
        XCTAssertEqual(loaded.tasks, snapshot.tasks)
        XCTAssertEqual(loaded.sessions, snapshot.sessions)
        XCTAssertEqual(loaded.interrupts, snapshot.interrupts)
        XCTAssertEqual(loaded.importDrafts, snapshot.importDrafts)
        XCTAssertEqual(loaded.importDraftItems, snapshot.importDraftItems)
        XCTAssertEqual(loaded.mindMapDocument, snapshot.mindMapDocument)
        XCTAssertEqual(loaded.preferences, snapshot.preferences)
        XCTAssertEqual(loaded.selectedTaskID, snapshot.selectedTaskID)
        XCTAssertEqual(loaded.lastCelebrationAt, snapshot.lastCelebrationAt)
    }

    func test_snapshotPersistenceCoordinatorKeepsLatestSave() async throws {
        let baseDirectory = try Self.makeTemporaryBaseDirectory(name: "debounce")
        defer {
            try? FileManager.default.removeItem(at: baseDirectory)
        }

        let databaseURL = baseDirectory.appendingPathComponent("app.sqlite")
        let repository = try Self.makeRepository(databaseURL: databaseURL)
        let coordinator = SnapshotPersistenceCoordinator(repository: repository, debounceDuration: .milliseconds(5))

        var first = Self.makeFullSnapshot()
        first.tasks[0].title = "First"

        var second = Self.makeFullSnapshot()
        second.tasks[0].title = "Second"

        var third = Self.makeFullSnapshot()
        third.tasks[0].title = "Third"

        await coordinator.scheduleSave(snapshot: first, generation: 1)
        await coordinator.scheduleSave(snapshot: second, generation: 2)
        await coordinator.scheduleSave(snapshot: third, generation: 3)

        try await _Concurrency.Task.sleep(for: .milliseconds(80))

        let loaded = await repository.loadSnapshot()
        XCTAssertEqual(loaded.tasks.first?.title, "Third")
    }
}

private extension PersistenceHarnessTests {
    static func makeRepository(databaseURL: URL) throws -> AppRepository {
        let dbQueue = try DatabaseQueue(path: databaseURL.path)
        return try AppRepository(dbQueue: dbQueue)
    }

    static func makeTemporaryBaseDirectory(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockCatTaskAssistantHarness", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func makeFullSnapshot() -> AppSnapshot {
        let projectA = Project(
            id: UUID(),
            name: "Project A",
            notes: "Harness project A",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let projectB = Project(
            id: UUID(),
            name: "Project B",
            notes: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_100),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let taskA = Task(
            id: UUID(),
            projectID: projectA.id,
            parentTaskID: nil,
            sortIndex: 0,
            title: "Task A",
            notes: "Harness task A",
            status: .todo,
            priority: 3,
            urgencyScore: 2,
            importanceScore: 4,
            urgencyValue: 60,
            importanceValue: 80,
            quadrant: .urgentImportant,
            estimatedMinutes: 45,
            dueAt: Date(timeIntervalSince1970: 1_700_001_000),
            smartSpecificMissing: false,
            smartMeasurableMissing: false,
            smartActionableMissing: false,
            smartRelevantMissing: false,
            smartBoundedMissing: false,
            smartEntries: SmartFieldKey.allCases.map(SmartEntry.empty),
            tags: ["harness", "perf"],
            isCurrent: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_200),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200),
            completedAt: nil
        )
        let taskB = Task(
            id: UUID(),
            projectID: projectB.id,
            parentTaskID: taskA.id,
            sortIndex: 1,
            title: "Task B",
            notes: nil,
            status: .doing,
            priority: 4,
            urgencyScore: 3,
            importanceScore: 3,
            urgencyValue: 45,
            importanceValue: 55,
            quadrant: .notUrgentImportant,
            estimatedMinutes: 30,
            dueAt: nil,
            smartSpecificMissing: true,
            smartMeasurableMissing: false,
            smartActionableMissing: true,
            smartRelevantMissing: false,
            smartBoundedMissing: true,
            smartEntries: SmartFieldKey.allCases.map(SmartEntry.empty),
            tags: ["review"],
            isCurrent: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_300),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_300),
            completedAt: nil
        )

        let session = Session(
            id: UUID(),
            taskID: taskA.id,
            startedAt: Date(timeIntervalSince1970: 1_700_000_400),
            endedAt: Date(timeIntervalSince1970: 1_700_000_700),
            totalSeconds: 300,
            state: .stopped,
            interruptionCount: 1,
            timerMode: .countUp
        )

        let interrupt = Interrupt(
            id: UUID(),
            sessionID: session.id,
            reason: "Harness interruption",
            startedAt: Date(timeIntervalSince1970: 1_700_000_500),
            endedAt: Date(timeIntervalSince1970: 1_700_000_530)
        )

        let draft = ImportDraft(
            id: UUID(),
            rawText: "First draft line\nSecond draft line",
            sourceType: .text,
            parseStatus: .parsed,
            createdAt: Date(timeIntervalSince1970: 1_700_000_600),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_650)
        )

        let draftItem = ImportDraftItem(
            id: UUID(),
            draftID: draft.id,
            sortIndex: 0,
            parentItemID: nil,
            proposedTitle: "Harness import item",
            proposedNotes: "Harness notes",
            proposedProjectName: projectA.name,
            proposedPriority: 3,
            proposedTags: ["perf", "harness"],
            proposedUrgencyScore: 3,
            proposedImportanceScore: 4,
            proposedUrgencyValue: 60,
            proposedImportanceValue: 80,
            proposedQuadrant: .urgentImportant,
            proposedDueAt: Date(timeIntervalSince1970: 1_700_001_200),
            smartEntries: SmartFieldKey.allCases.map(SmartEntry.empty),
            smartHints: ["具体", "可执行"],
            isAccepted: true
        )

        var snapshot = AppSnapshot.empty
        snapshot.projects = [projectA, projectB]
        snapshot.tasks = [taskA, taskB]
        snapshot.sessions = [session]
        snapshot.interrupts = [interrupt]
        snapshot.importDrafts = [draft]
        snapshot.importDraftItems = [draftItem]
        snapshot.mindMapDocument = MindMapDocument(
            dataJSON: """
            {"root":{"data":{"text":"Harness"},"children":[{"data":{"text":"Node A"},"children":[]}]},"theme":{"template":"default","config":{}},"layout":"logicalStructure","config":{},"view":null}
            """,
            configJSON: #"{"theme":"default"}"#,
            localConfigJSON: #"{"viewport":{"zoom":1}}"#,
            language: "zh",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_800)
        )
        snapshot.preferences = AppPreference(
            petEdge: .left,
            petOffsetY: 168,
            lowDistractionMode: true,
            backgroundTaskIDs: ["harness.persist", "harness.restore"],
            importAnalysis: .disabled
        )
        snapshot.selectedTaskID = taskA.id
        snapshot.lastCelebrationAt = Date(timeIntervalSince1970: 1_700_000_900)
        return snapshot
    }
}
