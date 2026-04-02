import CoreGraphics
import Foundation

public func printDebug(_ items: Any...) {
    #if DEBUG
    let message = items.map { String(describing: $0) }.joined(separator: " ")
    print(message)
    #endif
}

public extension CGPoint {
    func distance(from other: CGPoint) -> CGFloat {
        let dx = x - other.x
        let dy = y - other.y
        return sqrt((dx * dx) + (dy * dy))
    }
}

public extension Array {
    func randomElement(distribution weights: [Double]) -> Element? {
        guard !isEmpty, count == weights.count else {
            return randomElement()
        }

        let positiveWeights = weights.map { Swift.max(0, $0) }
        let total = positiveWeights.reduce(0, +)
        guard total > 0 else {
            return randomElement()
        }

        let threshold = Double.random(in: 0..<total)
        var runningTotal = 0.0

        for (index, weight) in positiveWeights.enumerated() {
            runningTotal += weight
            if threshold < runningTotal {
                return self[index]
            }
        }

        return last
    }
}

public extension Dictionary {
    func jsonString(prettyPrinted: Bool = false) -> String {
        guard JSONSerialization.isValidJSONObject(self) else {
            return "{}"
        }

        let options: JSONSerialization.WritingOptions = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        guard
            let data = try? JSONSerialization.data(withJSONObject: self, options: options),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }

        return string
    }
}
