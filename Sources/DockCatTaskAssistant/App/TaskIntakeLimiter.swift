import Foundation

@MainActor
final class TaskIntakeLimiter {
    struct Admission {
        let admitted: Bool
        let queueDepth: Int
        let isBusy: Bool
        let message: String?
    }

    private enum OperationKind {
        case parse(textLength: Int, draftItemCount: Int, currentTaskCount: Int)
        case commit(acceptedItemCount: Int, currentTaskCount: Int)
    }

    private let maxConcurrentOperations: Int
    private let maxImportCharacters: Int
    private let maxPendingDraftItems: Int
    private let maxCommitBatchSize: Int
    private let maxTotalTaskCount: Int
    private var inFlightOperations = 0

    init(
        maxConcurrentOperations: Int = 1,
        maxImportCharacters: Int = 24_000,
        maxPendingDraftItems: Int = 600,
        maxCommitBatchSize: Int = 250,
        maxTotalTaskCount: Int = 5_000
    ) {
        self.maxConcurrentOperations = maxConcurrentOperations
        self.maxImportCharacters = maxImportCharacters
        self.maxPendingDraftItems = maxPendingDraftItems
        self.maxCommitBatchSize = maxCommitBatchSize
        self.maxTotalTaskCount = maxTotalTaskCount
    }

    var queueDepth: Int {
        max(0, inFlightOperations - maxConcurrentOperations)
    }

    var isBusy: Bool {
        inFlightOperations > 0
    }

    func beginParse(
        textLength: Int,
        draftItemCount: Int,
        currentTaskCount: Int
    ) -> Admission {
        begin(.parse(textLength: textLength, draftItemCount: draftItemCount, currentTaskCount: currentTaskCount))
    }

    func beginCommit(
        acceptedItemCount: Int,
        currentTaskCount: Int
    ) -> Admission {
        begin(.commit(acceptedItemCount: acceptedItemCount, currentTaskCount: currentTaskCount))
    }

    func finish() -> Admission {
        inFlightOperations = max(0, inFlightOperations - 1)
        return Admission(
            admitted: true,
            queueDepth: queueDepth,
            isBusy: isBusy,
            message: isBusy ? "入口仍有 \(queueDepth + 1) 个处理中的任务" : nil
        )
    }

    private func begin(_ operation: OperationKind) -> Admission {
        if let message = rejectionMessage(for: operation) {
            return Admission(
                admitted: false,
                queueDepth: max(inFlightOperations, 1),
                isBusy: isBusy,
                message: message
            )
        }

        inFlightOperations += 1
        return Admission(
            admitted: true,
            queueDepth: queueDepth,
            isBusy: true,
            message: inFlightOperations > 1 ? "入口队列中仍有待处理任务" : nil
        )
    }

    private func rejectionMessage(for operation: OperationKind) -> String? {
        if inFlightOperations >= maxConcurrentOperations {
            return "系统正忙，入口队列已满，请稍后再试。"
        }

        switch operation {
        case let .parse(textLength, draftItemCount, currentTaskCount):
            if textLength > maxImportCharacters {
                return "本次导入文本过长，请先拆分后再导入。"
            }
            if draftItemCount > maxPendingDraftItems {
                return "待处理导入草稿过多，请先清理或确认现有草稿。"
            }
            if currentTaskCount >= maxTotalTaskCount {
                return "当前任务总量已接近上限，请先归档或清理部分任务。"
            }
        case let .commit(acceptedItemCount, currentTaskCount):
            if acceptedItemCount > maxCommitBatchSize {
                return "本次确认导入的任务过多，请分批提交。"
            }
            if currentTaskCount + acceptedItemCount > maxTotalTaskCount {
                return "导入后任务总量会超过系统上限，请先归档或分批导入。"
            }
        }

        return nil
    }
}
