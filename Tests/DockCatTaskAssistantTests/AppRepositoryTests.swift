import XCTest
import GRDB
@testable import DockCatTaskAssistant

final class AppRepositoryTests: XCTestCase {
    func test_saveSnapshot_insertsNewTasks() async throws {
        let (repository, _) = try makeRepository()
        let taskA = makeTask(title: "Task A")
        let taskB = makeTask(title: "Task B")

        var snapshot = AppSnapshot.empty
        snapshot.tasks = [taskA, taskB]

        await repository.saveSnapshot(snapshot)
        let loaded = await repository.loadSnapshot()

        XCTAssertEqual(loaded.tasks.count, 2)
        XCTAssertEqual(Set(loaded.tasks.map(\.id)), Set([taskA.id, taskB.id]))
    }

    func test_saveSnapshot_updatesExistingTasks() async throws {
        let (repository, dbQueue) = try makeRepository()
        let originalTask = makeTask(title: "Original", status: .todo)

        var snapshot = AppSnapshot.empty
        snapshot.tasks = [originalTask]
        await repository.saveSnapshot(snapshot)

        var updatedTask = originalTask
        updatedTask.title = "Updated"
        updatedTask.status = .doing
        updatedTask.updatedAt = Date(timeIntervalSince1970: 1_700_000_100)

        snapshot.tasks = [updatedTask]
        await repository.saveSnapshot(snapshot)

        let loaded = await repository.loadSnapshot()
        XCTAssertEqual(loaded.tasks.count, 1)
        XCTAssertEqual(loaded.tasks.first?.title, "Updated")
        XCTAssertEqual(loaded.tasks.first?.status, .doing)

        let totalCount = try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks")
        }
        XCTAssertEqual(totalCount, 1)
    }

    func test_saveSnapshot_softDeletesMissingTasks() async throws {
        let (repository, dbQueue) = try makeRepository()
        let taskA = makeTask(title: "Task A")
        let taskB = makeTask(title: "Task B")

        var firstSnapshot = AppSnapshot.empty
        firstSnapshot.tasks = [taskA, taskB]
        await repository.saveSnapshot(firstSnapshot)

        var secondSnapshot = AppSnapshot.empty
        secondSnapshot.tasks = [taskA]
        await repository.saveSnapshot(secondSnapshot)

        let loaded = await repository.loadSnapshot()
        XCTAssertEqual(loaded.tasks.map(\.id), [taskA.id])

        let row: Row? = try dbQueue.read { db in
            return try Row.fetchOne(
                db,
                sql: "SELECT id, tombstone, version FROM tasks WHERE id = ?",
                arguments: [taskB.id.uuidString]
            )
        }

        XCTAssertNotNil(row)
        XCTAssertEqual(row?["id"], taskB.id.uuidString)
        XCTAssertEqual(row?["tombstone"], true)
        XCTAssertEqual(row?["version"], 2)
    }

    func test_loadSnapshot_filtersOutTombstones() async throws {
        let (repository, dbQueue) = try makeRepository()
        let visibleTask = makeTask(title: "Visible")
        let deletedTask = makeTask(title: "Deleted", tombstone: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let visibleRecord = try makeTaskRecord(from: visibleTask, encoder: encoder)
        let deletedRecord = try makeTaskRecord(from: deletedTask, encoder: encoder)

        try await dbQueue.write { db in
            try visibleRecord.insert(db)
            try deletedRecord.insert(db)
        }

        let loaded = await repository.loadSnapshot()

        XCTAssertEqual(loaded.tasks.count, 1)
        XCTAssertEqual(loaded.tasks.first?.id, visibleTask.id)
        XCTAssertFalse(loaded.tasks.contains(where: { $0.id == deletedTask.id }))
    }

    func test_saveSnapshot_ignoresOlderGenerationWhenSavesArriveOutOfOrder() async throws {
        let (repository, _) = try makeRepository()
        let olderTask = makeTask(title: "Older")
        let newerTask = makeTask(title: "Newer")

        var newerSnapshot = AppSnapshot.empty
        newerSnapshot.tasks = [newerTask]
        await repository.saveSnapshot(newerSnapshot, generation: 2)

        var olderSnapshot = AppSnapshot.empty
        olderSnapshot.tasks = [olderTask]
        await repository.saveSnapshot(olderSnapshot, generation: 1)

        let loaded = await repository.loadSnapshot()
        XCTAssertEqual(loaded.tasks.map(\.id), [newerTask.id])
        XCTAssertEqual(loaded.tasks.first?.title, "Newer")
    }

    private func makeRepository() throws -> (repository: AppRepository, dbQueue: DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let repository = try AppRepository(dbQueue: dbQueue)
        return (repository, dbQueue)
    }

    private func makeTask(
        id: UUID = UUID(),
        title: String,
        status: TaskStatus = .todo,
        tombstone: Bool = false,
        version: Int = 1
    ) -> Task {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return Task(
            id: id,
            projectID: nil,
            parentTaskID: nil,
            sortIndex: 0,
            title: title,
            notes: nil,
            status: status,
            priority: 3,
            urgencyScore: 2,
            importanceScore: 2,
            urgencyValue: 50,
            importanceValue: 50,
            quadrant: .notUrgentImportant,
            estimatedMinutes: nil,
            dueAt: nil,
            smartSpecificMissing: false,
            smartMeasurableMissing: false,
            smartActionableMissing: false,
            smartRelevantMissing: false,
            smartBoundedMissing: false,
            smartEntries: SmartFieldKey.allCases.map(SmartEntry.empty),
            tags: [],
            isCurrent: false,
            createdAt: now,
            updatedAt: now,
            completedAt: nil,
            version: version,
            tombstone: tombstone,
            device_id: "test-device"
        )
    }

    private func makeTaskRecord(from task: Task, encoder: JSONEncoder) throws -> PersistableTaskRecord {
        PersistableTaskRecord(
            id: task.id.uuidString,
            projectID: task.projectID?.uuidString,
            parentTaskID: task.parentTaskID?.uuidString,
            sortIndex: task.sortIndex,
            title: task.title,
            notes: task.notes,
            status: task.status.rawValue,
            priority: task.priority,
            urgencyScore: task.urgencyScore,
            importanceScore: task.importanceScore,
            urgencyValue: task.urgencyValue,
            importanceValue: task.importanceValue,
            quadrant: task.quadrant?.rawValue,
            estimatedMinutes: task.estimatedMinutes,
            dueAt: task.dueAt?.timeIntervalSince1970,
            smartSpecificMissing: task.smartSpecificMissing,
            smartMeasurableMissing: task.smartMeasurableMissing,
            smartActionableMissing: task.smartActionableMissing,
            smartRelevantMissing: task.smartRelevantMissing,
            smartBoundedMissing: task.smartBoundedMissing,
            smartEntriesJSON: try encodeJSON(task.smartEntries, encoder: encoder),
            tagsJSON: try encodeJSON(task.tags, encoder: encoder),
            isCurrent: task.isCurrent,
            createdAt: task.createdAt.timeIntervalSince1970,
            updatedAt: task.updatedAt.timeIntervalSince1970,
            completedAt: task.completedAt?.timeIntervalSince1970,
            version: task.version,
            tombstone: task.tombstone,
            device_id: task.device_id
        )
    }

    private func encodeJSON<T: Encodable>(_ value: T, encoder: JSONEncoder) throws -> String {
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw TestError.invalidUTF8
        }
        return string
    }
}

private struct PersistableTaskRecord: Codable, FetchableRecord, PersistableRecord, TableRecord {
    static let databaseTableName = "tasks"

    var id: String
    var projectID: String?
    var parentTaskID: String?
    var sortIndex: Int
    var title: String
    var notes: String?
    var status: String
    var priority: Int
    var urgencyScore: Int
    var importanceScore: Int
    var urgencyValue: Double
    var importanceValue: Double
    var quadrant: String?
    var estimatedMinutes: Int?
    var dueAt: Double?
    var smartSpecificMissing: Bool
    var smartMeasurableMissing: Bool
    var smartActionableMissing: Bool
    var smartRelevantMissing: Bool
    var smartBoundedMissing: Bool
    var smartEntriesJSON: String
    var tagsJSON: String
    var isCurrent: Bool
    var createdAt: Double
    var updatedAt: Double
    var completedAt: Double?
    var version: Int
    var tombstone: Bool
    var device_id: String?
}

private enum TestError: Error {
    case invalidUTF8
}
