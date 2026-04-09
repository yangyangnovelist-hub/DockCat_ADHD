import Foundation

enum MindMapTaskSynchronizer {
    private static let htmlTagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: [])

    struct SyncResult {
        let tasks: [Task]
        let normalizedDataJSON: String
        let newTaskIDs: [UUID]
    }

    static func syncTasks(from dataJSON: String, existingTasks: [Task]) -> SyncResult? {
        guard var payload = jsonObject(from: dataJSON),
              var root = payload["root"] as? [String: Any] else {
            return nil
        }

        let existingTasksByID = Dictionary(uniqueKeysWithValues: existingTasks.map { ($0.id, $0) })
        let now = Date()
        var visibleTasks: [Task] = []
        var visibleTaskIDs = Set<UUID>()
        var newTaskIDs: [UUID] = []

        func normalizeNode(_ rawNode: [String: Any], parentTaskID: UUID?, sortIndex: Int) -> [String: Any] {
            var node = rawNode
            var data = node["data"] as? [String: Any] ?? [:]
            let taskID = resolveTaskID(from: &data, usedTaskIDs: &visibleTaskIDs)
            let title = normalizedNodeText(from: data)
            let note = normalizedNodeNote(from: data) ?? existingTasksByID[taskID]?.notes

            let children = ((node["children"] as? [[String: Any]]) ?? []).enumerated().map {
                normalizeNode($0.element, parentTaskID: taskID, sortIndex: $0.offset)
            }

            data["taskId"] = taskID.uuidString
            data["uid"] = taskID.uuidString
            node["data"] = data
            node["children"] = children

            let existingTask = existingTasksByID[taskID]
            if existingTask == nil {
                newTaskIDs.append(taskID)
            }
            visibleTasks.append(
                makeSyncedTask(
                    existingTask: existingTask,
                    id: taskID,
                    parentTaskID: parentTaskID,
                    sortIndex: sortIndex,
                    title: title,
                    notes: note,
                    now: now
                )
            )

            return node
        }

        let rootChildren = ((root["children"] as? [[String: Any]]) ?? []).enumerated().map {
            normalizeNode($0.element, parentTaskID: nil, sortIndex: $0.offset)
        }
        root["children"] = rootChildren
        payload["root"] = root

        let carriedArchivedTasks = existingTasks
            .filter { $0.status == .archived && !visibleTaskIDs.contains($0.id) }

        let recentCreationThreshold = now.addingTimeInterval(-5)
        let newlyArchivedTasks = existingTasks
            .filter { $0.status != .archived && !visibleTaskIDs.contains($0.id) && $0.createdAt < recentCreationThreshold }
            .map { task -> Task in
                var updated = task
                updated.status = .archived
                updated.isCurrent = false
                updated.touch()
                return updated
            }

        let normalizedDataJSON = jsonString(from: payload) ?? dataJSON
        return SyncResult(
            tasks: visibleTasks + newlyArchivedTasks + carriedArchivedTasks,
            normalizedDataJSON: normalizedDataJSON,
            newTaskIDs: newTaskIDs
        )
    }

    static func makeMindMapDataJSON(from tasks: [Task], existingDataJSON: String?) -> String {
        let visibleTasks = tasks.filter { $0.status != .archived }
        let groupedTasks = Dictionary(grouping: visibleTasks) { $0.parentTaskID }

        var payload = existingDataJSON.flatMap(jsonObject(from:))
            ?? jsonObject(from: AppSnapshot.empty.mindMapDocument.dataJSON)
            ?? [:]
        var root = payload["root"] as? [String: Any] ?? [:]
        let rootData = root["data"] as? [String: Any] ?? ["text": "任务树"]

        var existingNodesByTaskID: [UUID: [String: Any]] = [:]
        if let existingRoot = payload["root"] as? [String: Any] {
            collectNodes(from: existingRoot, into: &existingNodesByTaskID)
        }

        func makeNode(_ task: Task) -> [String: Any] {
            var node = existingNodesByTaskID[task.id] ?? [:]
            var data = node["data"] as? [String: Any] ?? [:]
            let existingText = stripHTMLTags(from: data["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if existingText != task.title {
                data["text"] = task.title
            }
            data["uid"] = task.id.uuidString
            data["taskId"] = task.id.uuidString
            if let note = task.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                data["note"] = note
            } else {
                data.removeValue(forKey: "note")
            }
            node["data"] = data
            node["children"] = (groupedTasks[task.id] ?? [])
                .sorted { lhs, rhs in
                    if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                    return lhs.createdAt < rhs.createdAt
                }
                .map(makeNode)
            return node
        }

        root["data"] = rootData
        root["children"] = (groupedTasks[nil] ?? [])
            .sorted { lhs, rhs in
                if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
                return lhs.createdAt < rhs.createdAt
            }
            .map(makeNode)
        payload["root"] = root
        payload["theme"] = payload["theme"] ?? ["template": "default", "config": [:]]
        payload["layout"] = payload["layout"] ?? "mindMap"
        payload["config"] = payload["config"] ?? [:]
        payload["view"] = payload["view"] ?? NSNull()

        return jsonString(from: payload) ?? AppSnapshot.empty.mindMapDocument.dataJSON
    }

    static func isEffectivelyEmpty(_ dataJSON: String) -> Bool {
        guard let payload = jsonObject(from: dataJSON),
              let root = payload["root"] as? [String: Any] else {
            return false
        }
        let children = (root["children"] as? [[String: Any]]) ?? []
        return children.isEmpty
    }

    static func hasStableTaskIDs(in dataJSON: String) -> Bool {
        guard let payload = jsonObject(from: dataJSON),
              let root = payload["root"] as? [String: Any] else {
            return false
        }

        func nodeHasStableTaskID(_ node: [String: Any]) -> Bool {
            let data = node["data"] as? [String: Any] ?? [:]
            let hasValidID = [data["taskId"], data["taskID"], data["uid"]]
                .compactMap { $0 as? String }
                .contains { UUID(uuidString: $0) != nil }
            guard hasValidID else { return false }

            let children = (node["children"] as? [[String: Any]]) ?? []
            return children.allSatisfy(nodeHasStableTaskID)
        }

        let rootChildren = (root["children"] as? [[String: Any]]) ?? []
        return rootChildren.allSatisfy(nodeHasStableTaskID)
    }

    private static func makeSyncedTask(
        existingTask: Task?,
        id: UUID,
        parentTaskID: UUID?,
        sortIndex: Int,
        title: String,
        notes: String?,
        now: Date
    ) -> Task {
        let normalizedNotes = notes?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        if var task = existingTask {
            let fieldsChanged = task.parentTaskID != parentTaskID
                || task.sortIndex != sortIndex
                || task.title != title
                || task.notes != normalizedNotes
                || task.status == .archived

            task.parentTaskID = parentTaskID
            task.sortIndex = sortIndex
            task.title = title
            task.notes = normalizedNotes
            if task.status == .archived {
                task.status = .todo
                task.completedAt = nil
            }
            if fieldsChanged {
                task.touch()
            }
            return task
        }

        let suggestedUrgency = QuadrantAdvisor.urgencyScore(for: title)
        let suggestedImportance = QuadrantAdvisor.importanceScore(for: title)
        let urgencyValue = PriorityVector.value(from: suggestedUrgency)
        let importanceValue = PriorityVector.value(from: suggestedImportance)
        let smartEntries = SmartEvaluator.seededEntries(title: title, notes: normalizedNotes)
        let smart = SmartEvaluator.evaluate(title: title, notes: normalizedNotes, smartEntries: smartEntries)

        return Task(
            id: id,
            projectID: nil,
            parentTaskID: parentTaskID,
            sortIndex: sortIndex,
            title: title,
            notes: normalizedNotes,
            status: .todo,
            priority: PriorityVector.derivedPriority(
                urgencyValue: urgencyValue,
                importanceValue: importanceValue
            ),
            urgencyScore: suggestedUrgency,
            importanceScore: suggestedImportance,
            urgencyValue: urgencyValue,
            importanceValue: importanceValue,
            quadrant: PriorityVector.quadrant(
                urgencyValue: urgencyValue,
                importanceValue: importanceValue
            ),
            estimatedMinutes: nil,
            dueAt: nil,
            smartSpecificMissing: smart.specificMissing,
            smartMeasurableMissing: smart.measurableMissing,
            smartActionableMissing: smart.actionableMissing,
            smartRelevantMissing: smart.relevantMissing,
            smartBoundedMissing: smart.boundedMissing,
            smartEntries: smartEntries,
            tags: [],
            isCurrent: false,
            createdAt: now,
            updatedAt: now,
            completedAt: nil
        )
    }

    private static func resolveTaskID(from data: inout [String: Any], usedTaskIDs: inout Set<UUID>) -> UUID {
        let candidates = [data["taskId"], data["taskID"], data["uid"]]
            .compactMap { $0 as? String }
            .compactMap(UUID.init(uuidString:))

        if let reusableID = candidates.first(where: { !usedTaskIDs.contains($0) }) {
            usedTaskIDs.insert(reusableID)
            return reusableID
        }

        let generatedID = UUID()
        usedTaskIDs.insert(generatedID)
        data["taskId"] = generatedID.uuidString
        return generatedID
    }

    private static func normalizedNodeText(from data: [String: Any]) -> String {
        let raw = (data["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = stripHTMLTags(from: raw)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stripped?.isEmpty == false ? stripped : nil) ?? "新节点"
    }

    private static func normalizedNodeNote(from data: [String: Any]) -> String? {
        guard let note = data["note"] as? String else { return nil }
        return note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func collectNodes(from node: [String: Any], into map: inout [UUID: [String: Any]]) {
        if let data = node["data"] as? [String: Any],
           let id = (data["taskId"] as? String).flatMap(UUID.init(uuidString:))
                ?? (data["uid"] as? String).flatMap(UUID.init(uuidString:)) {
            map[id] = node
        }

        for child in (node["children"] as? [[String: Any]]) ?? [] {
            collectNodes(from: child, into: &map)
        }
    }

    private static func jsonObject(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func jsonString(from object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private static func stripHTMLTags(from text: String?) -> String? {
        guard let text else { return nil }
        guard let htmlTagRegex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return htmlTagRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
