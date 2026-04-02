import AppKit
import Foundation

public enum RmbHighlightedTextField {
    public struct HighlightedText: Equatable {
        public let range: NSRange
        public let color: NSColor

        public init(range: NSRange, color: NSColor) {
            self.range = range
            self.color = color
        }
    }
}
