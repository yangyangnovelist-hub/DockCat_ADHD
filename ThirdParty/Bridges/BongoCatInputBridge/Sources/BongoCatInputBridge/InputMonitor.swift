import Cocoa

public enum InputType {
    case keyboardDown(key: String)
    case keyboardUp(key: String)
    case leftClickDown
    case leftClickUp
    case rightClickDown
    case rightClickUp
    case scroll
    case trackpadTouch
}

public final class InputMonitor {
    private var keyboardEventMonitor: Any?
    private var mouseEventMonitor: Any?
    private let callback: (InputType) -> Void

    public init(callback: @escaping (InputType) -> Void) {
        self.callback = callback
    }

    public func start() {
        startKeyboardMonitoring()
        startMouseMonitoring()
    }

    public func stop() {
        if let monitor = keyboardEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardEventMonitor = nil
        }

        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
    }

    private func startKeyboardMonitoring() {
        keyboardEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let key = event.charactersIgnoringModifiers ?? "unknown"

            switch event.type {
            case .keyDown:
                if event.isARepeat {
                    return
                }
                self?.callback(.keyboardDown(key: key))
            case .keyUp:
                self?.callback(.keyboardUp(key: key))
            default:
                break
            }
        }
    }

    private func startMouseMonitoring() {
        mouseEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            switch event.type {
            case .leftMouseDown:
                self?.callback(.leftClickDown)
            case .leftMouseUp:
                self?.callback(.leftClickUp)
            case .rightMouseDown:
                self?.callback(.rightClickDown)
            case .rightMouseUp:
                self?.callback(.rightClickUp)
            case .scrollWheel:
                self?.callback(.scroll)
            case .mouseMoved:
                if event.subtype == .touch {
                    self?.callback(.trackpadTouch)
                }
            default:
                break
            }
        }
    }

    deinit {
        stop()
    }
}
