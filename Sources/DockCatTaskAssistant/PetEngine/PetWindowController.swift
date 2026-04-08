import AppKit
import Combine

@MainActor
final class PetWindowController: NSWindowController {
    var onSingleClick: ((CGRect?) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onLongPress: (() -> Void)?

    private let appModel: AppModel
    private var cancellables = Set<AnyCancellable>()
    private var petView: StaticPetView?

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init(window: nil)
        bindAppModel()
        updatePosition(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func updatePosition(animated: Bool) {
        let config = PetWindowConfiguration(snapshot: appModel.snapshot)
        syncWindow(with: config, animated: animated)
    }

    private func bindAppModel() {
        appModel.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.syncWindow(with: PetWindowConfiguration(snapshot: snapshot), animated: false)
            }
            .store(in: &cancellables)
    }

    private func syncWindow(with configuration: PetWindowConfiguration, animated: Bool) {
        guard let panel = ensurePanel() else { return }

        petView?.apply(configuration: configuration)
        let targetFrame = anchoredFrame(for: configuration)
        panel.setFrame(targetFrame, display: true, animate: animated)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> PetPanel? {
        if let panel = window as? PetPanel {
            return panel
        }

        let initialFrame = CGRect(origin: .zero, size: CGSize(width: 96, height: 96))
        let panel = PetPanel(contentRect: initialFrame)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let view = StaticPetView(
            onHoverChange: { [weak appModel] hovering in
                appModel?.setPetHovering(hovering)
            },
            onSingleClick: { [weak self] anchorFrame in
                self?.onSingleClick?(anchorFrame)
            },
            onDoubleClick: { [weak self] in
                self?.onDoubleClick?()
            },
            onLongPress: { [weak self] in
                self?.onLongPress?()
            },
            onDragEnd: { [weak self] frame in
                self?.persistPlacement(for: frame)
            }
        )
        view.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = view
        view.constrainToFillParent()
        petView = view
        window = panel
        return panel
    }

    private func anchoredFrame(for configuration: PetWindowConfiguration) -> CGRect {
        let screen = NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(origin: .zero, size: configuration.windowSize)
        let xInset: CGFloat = 18
        let yInset: CGFloat = 18

        let x = configuration.edge == .left
            ? visibleFrame.minX + xInset
            : visibleFrame.maxX - configuration.windowSize.width - xInset
        let unclampedY = configuration.centerY - configuration.windowSize.height * 0.5
        let y = min(
            max(unclampedY, visibleFrame.minY + yInset),
            visibleFrame.maxY - configuration.windowSize.height - yInset
        )

        return CGRect(origin: CGPoint(x: x, y: y), size: configuration.windowSize)
    }

    private func persistPlacement(for frame: CGRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) ?? NSScreen.main else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let edge: PetEdge = frame.midX < visibleFrame.midX ? .left : .right
        appModel.updatePetPlacement(edge: edge, centerY: frame.midY)
    }
}

private struct PetWindowConfiguration {
    let edge: PetEdge
    let centerY: CGFloat
    let windowSize: CGSize
    let image: NSImage

    @MainActor
    init(snapshot: AppSnapshot) {
        edge = snapshot.preferences.petEdge
        centerY = snapshot.preferences.petOffsetY

        let side = snapshot.preferences.lowDistractionMode ? 82.0 : 98.0
        windowSize = CGSize(width: side, height: side)
        image = Self.petImage()
    }

    @MainActor
    private static func petImage() -> NSImage {
        if let url = Bundle.module.url(forResource: "PetIdleFront", withExtension: "jpg"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.module.url(forResource: "DashCatAvatar", withExtension: "jpg"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return AppIconProvider.applicationIconImage ?? NSImage(size: CGSize(width: 96, height: 96))
    }
}

private final class PetPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class StaticPetView: NSView {
    private let imageView = NSImageView()
    private let onHoverChange: (Bool) -> Void
    private let onSingleClick: (CGRect?) -> Void
    private let onDoubleClick: () -> Void
    private let onLongPress: () -> Void
    private let onDragEnd: (CGRect) -> Void

    private var trackingAreaRef: NSTrackingArea?
    private var longPressTask: _Concurrency.Task<Void, Never>?
    private var mouseDownScreenLocation: CGPoint?
    private var mouseDownWindowOrigin: CGPoint?
    private var isDragging = false
    private var didTriggerLongPress = false

    init(
        onHoverChange: @escaping (Bool) -> Void,
        onSingleClick: @escaping (CGRect?) -> Void,
        onDoubleClick: @escaping () -> Void,
        onLongPress: @escaping () -> Void,
        onDragEnd: @escaping (CGRect) -> Void
    ) {
        self.onHoverChange = onHoverChange
        self.onSingleClick = onSingleClick
        self.onDoubleClick = onDoubleClick
        self.onLongPress = onLongPress
        self.onDragEnd = onDragEnd
        super.init(frame: .zero)
        setupView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func apply(configuration: PetWindowConfiguration) {
        imageView.image = configuration.image
        imageView.frame = bounds
        window?.contentAspectRatio = configuration.windowSize
        frame.size = configuration.windowSize
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.animates = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange(false)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenLocation = NSEvent.mouseLocation
        mouseDownWindowOrigin = window?.frame.origin
        isDragging = false
        didTriggerLongPress = false
        longPressTask?.cancel()
        longPressTask = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(600))
            await MainActor.run {
                guard let self else { return }
                guard !self.isDragging else { return }
                guard self.mouseDownScreenLocation != nil else { return }
                self.didTriggerLongPress = true
                self.onLongPress()
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownScreenLocation, let mouseDownWindowOrigin, let window else { return }

        let currentLocation = NSEvent.mouseLocation
        let deltaX = currentLocation.x - mouseDownScreenLocation.x
        let deltaY = currentLocation.y - mouseDownScreenLocation.y

        if !isDragging, hypot(deltaX, deltaY) < 6 {
            return
        }

        isDragging = true
        didTriggerLongPress = false
        longPressTask?.cancel()
        longPressTask = nil

        window.setFrameOrigin(
            CGPoint(
                x: mouseDownWindowOrigin.x + deltaX,
                y: mouseDownWindowOrigin.y + deltaY
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        longPressTask?.cancel()
        longPressTask = nil

        defer {
            mouseDownScreenLocation = nil
            mouseDownWindowOrigin = nil
            isDragging = false
            didTriggerLongPress = false
        }

        guard let window else { return }

        if isDragging {
            onDragEnd(window.frame)
            return
        }

        guard !didTriggerLongPress else { return }

        if event.clickCount >= 2 {
            onDoubleClick()
        } else {
            onSingleClick(window.frame)
        }
    }
}

private extension NSView {
    func constrainToFillParent() {
        guard let superview else { return }
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: superview.leadingAnchor),
            trailingAnchor.constraint(equalTo: superview.trailingAnchor),
            topAnchor.constraint(equalTo: superview.topAnchor),
            bottomAnchor.constraint(equalTo: superview.bottomAnchor),
        ])
    }
}
