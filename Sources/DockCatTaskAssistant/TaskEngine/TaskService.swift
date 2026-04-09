import Foundation

enum TaskService {
    static func groupedTasks(in snapshot: AppSnapshot) -> [UUID?: [Task]] {
        Dictionary(grouping: snapshot.tasks) { $0.parentTaskID }
    }

    static func currentTask(in snapshot: AppSnapshot) -> Task? {
        let selectedID = snapshot.selectedTaskID ?? snapshot.tasks.first(where: \.isCurrent)?.id
        return snapshot.tasks.first(where: { $0.id == selectedID })
    }

    static func task(id: UUID?, in snapshot: AppSnapshot) -> Task? {
        guard let id else { return nil }
        return snapshot.tasks.first(where: { $0.id == id })
    }

    static func sortedTasks(in snapshot: AppSnapshot) -> [Task] {
        let grouped = groupedTasks(in: snapshot)
        let rootTasks = sortedBranch(grouped[nil] ?? [])

        var result: [Task] = []

        func walk(_ task: Task) {
            result.append(task)
            let children = sortedBranch(grouped[task.id] ?? [])
            children.forEach(walk)
        }

        rootTasks.forEach(walk)
        return result
    }

    static func depthMap(in snapshot: AppSnapshot) -> [UUID: Int] {
        let grouped = groupedTasks(in: snapshot)
        var map: [UUID: Int] = [:]

        func walk(parentID: UUID?, depth: Int) {
            for task in sortedBranch(grouped[parentID] ?? []) {
                map[task.id] = depth
                walk(parentID: task.id, depth: depth + 1)
            }
        }

        walk(parentID: nil, depth: 0)
        return map
    }

    static func rootAncestorID(for taskID: UUID, in snapshot: AppSnapshot) -> UUID {
        guard var currentTask = task(id: taskID, in: snapshot) else { return taskID }
        while let parentID = currentTask.parentTaskID, let parentTask = task(id: parentID, in: snapshot) {
            currentTask = parentTask
        }
        return currentTask.id
    }

    static func nextFocusableTask(after currentTaskID: UUID, in snapshot: AppSnapshot) -> Task? {
        let orderedTasks = sortedTasks(in: snapshot)
        let isOpenTask: (Task) -> Bool = { task in
            task.id != currentTaskID && task.status != .done && task.status != .archived
        }

        guard let currentIndex = orderedTasks.firstIndex(where: { $0.id == currentTaskID }) else {
            return orderedTasks.first(where: isOpenTask)
        }

        if currentIndex + 1 < orderedTasks.count,
           let next = orderedTasks[(currentIndex + 1)...].first(where: isOpenTask) {
            return next
        }

        if currentIndex > 0 {
            return orderedTasks[..<currentIndex].first(where: isOpenTask)
        }

        return nil
    }

    static func nextFocusableTask(
        after currentTaskID: UUID,
        preferringRootTaskID preferredRootTaskID: UUID?,
        in snapshot: AppSnapshot
    ) -> Task? {
        guard let preferredRootTaskID else {
            return nextFocusableTask(after: currentTaskID, in: snapshot)
        }

        let orderedTasks = sortedTasks(in: snapshot)
        let isPreferredOpenTask: (Task) -> Bool = { task in
            task.id != currentTaskID &&
            task.status != .done &&
            task.status != .archived &&
            rootAncestorID(for: task.id, in: snapshot) == preferredRootTaskID
        }

        if let currentIndex = orderedTasks.firstIndex(where: { $0.id == currentTaskID }),
           currentIndex + 1 < orderedTasks.count,
           let nextPreferred = orderedTasks[(currentIndex + 1)...].first(where: isPreferredOpenTask) {
            return nextPreferred
        }

        if let firstPreferred = orderedTasks.first(where: isPreferredOpenTask) {
            return firstPreferred
        }

        return nextFocusableTask(after: currentTaskID, in: snapshot)
    }

    private static func sortedBranch(_ tasks: [Task]) -> [Task] {
        tasks.sorted { lhs, rhs in
            if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
            if lhs.status != rhs.status { return statusRank(lhs.status) < statusRank(rhs.status) }
            if abs(lhs.priorityVectorScore - rhs.priorityVectorScore) > 0.0001 {
                return lhs.priorityVectorScore > rhs.priorityVectorScore
            }
            if abs(lhs.importanceValue - rhs.importanceValue) > 0.0001 {
                return lhs.importanceValue > rhs.importanceValue
            }
            if abs(lhs.urgencyValue - rhs.urgencyValue) > 0.0001 {
                return lhs.urgencyValue > rhs.urgencyValue
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private static func statusRank(_ status: TaskStatus) -> Int {
        switch status {
        case .doing: return 0
        case .todo: return 1
        case .paused: return 2
        case .done: return 3
        case .archived: return 4
        }
    }
}
