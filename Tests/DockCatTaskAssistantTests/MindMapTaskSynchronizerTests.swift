import XCTest
@testable import DockCatTaskAssistant

final class MindMapTaskSynchronizerTests: XCTestCase {
    func testSyncTasksCreatesTasksFromMindMapNodes() throws {
        let result = try XCTUnwrap(
            MindMapTaskSynchronizer.syncTasks(
                from: """
                {"root":{"data":{"text":"任务树"},"children":[{"data":{"text":"父任务"},"children":[{"data":{"text":"子任务","note":"拆解说明"}}]}]}}
                """,
                existingTasks: []
            )
        )

        XCTAssertEqual(result.tasks.count, 2)
        XCTAssertEqual(result.newTaskIDs.count, 2)

        let parent = try XCTUnwrap(result.tasks.first(where: { $0.parentTaskID == nil }))
        let child = try XCTUnwrap(result.tasks.first(where: { $0.parentTaskID == parent.id }))

        XCTAssertEqual(parent.title, "父任务")
        XCTAssertEqual(child.title, "子任务")
        XCTAssertEqual(child.notes, "拆解说明")
    }

    func testSyncTasksArchivesRemovedTasksAfterGracePeriod() throws {
        let removedTaskID = UUID()
        let createdAt = Date(timeIntervalSinceNow: -60)
        let existingTask = makeTask(
            id: removedTaskID,
            title: "已消失任务",
            createdAt: createdAt,
            updatedAt: createdAt
        )

        let result = try XCTUnwrap(
            MindMapTaskSynchronizer.syncTasks(
                from: AppSnapshot.empty.mindMapDocument.dataJSON,
                existingTasks: [existingTask]
            )
        )

        let archivedTask = try XCTUnwrap(result.tasks.first(where: { $0.id == removedTaskID }))
        XCTAssertEqual(archivedTask.status, .archived)
        XCTAssertFalse(archivedTask.isCurrent)
    }

    func testMakeMindMapDataJSONSkipsArchivedTasks() throws {
        let rootID = UUID()
        let childID = UUID()
        let archivedID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tasks = [
            makeTask(id: rootID, parentTaskID: nil, sortIndex: 0, title: "根任务", notes: "上下文", createdAt: now, updatedAt: now),
            makeTask(id: childID, parentTaskID: rootID, sortIndex: 0, title: "进行中的子任务", createdAt: now, updatedAt: now),
            makeTask(id: archivedID, parentTaskID: nil, sortIndex: 1, title: "归档任务", status: .archived, createdAt: now, updatedAt: now),
        ]

        let dataJSON = MindMapTaskSynchronizer.makeMindMapDataJSON(
            from: tasks,
            existingDataJSON: AppSnapshot.empty.mindMapDocument.dataJSON
        )

        let payload = try XCTUnwrap(jsonObject(from: dataJSON))
        let root = try XCTUnwrap(payload["root"] as? [String: Any])
        let rootChildren = try XCTUnwrap(root["children"] as? [[String: Any]])

        XCTAssertEqual(rootChildren.count, 1)
        let serializedRootTask = try XCTUnwrap(rootChildren.first)
        let serializedData = try XCTUnwrap(serializedRootTask["data"] as? [String: Any])
        let childNodes = try XCTUnwrap(serializedRootTask["children"] as? [[String: Any]])

        XCTAssertEqual(serializedData["text"] as? String, "根任务")
        XCTAssertEqual(serializedData["note"] as? String, "上下文")
        XCTAssertEqual(serializedData["taskId"] as? String, rootID.uuidString)
        XCTAssertEqual(childNodes.count, 1)
        XCTAssertEqual(((childNodes.first?["data"] as? [String: Any])?["taskId"] as? String), childID.uuidString)
    }

    func testHasStableTaskIDsReturnsTrueWhenAllNodesCarryUUIDs() {
        let parentID = UUID()
        let childID = UUID()

        let hasStableIDs = MindMapTaskSynchronizer.hasStableTaskIDs(
            in: """
            {"root":{"data":{"text":"任务树"},"children":[{"data":{"text":"父任务","taskId":"\(parentID.uuidString)"},"children":[{"data":{"text":"子任务","uid":"\(childID.uuidString)"}}]}]}}
            """
        )

        XCTAssertTrue(hasStableIDs)
    }

    func testHasStableTaskIDsReturnsFalseWhenNodeIsMissingUUID() {
        let hasStableIDs = MindMapTaskSynchronizer.hasStableTaskIDs(
            in: """
            {"root":{"data":{"text":"任务树"},"children":[{"data":{"text":"父任务"},"children":[{"data":{"text":"子任务","uid":"temporary-node-id"}}]}]}}
            """
        )
        
        XCTAssertFalse(hasStableIDs)
    }

    private func makeTask(
        id: UUID,
        parentTaskID: UUID? = nil,
        sortIndex: Int = 0,
        title: String,
        notes: String? = nil,
        status: TaskStatus = .todo,
        createdAt: Date,
        updatedAt: Date
    ) -> Task {
        Task(
            id: id,
            projectID: nil,
            parentTaskID: parentTaskID,
            sortIndex: sortIndex,
            title: title,
            notes: notes,
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
            isCurrent: true,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: nil
        )
    }

    private func jsonObject(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }
}
