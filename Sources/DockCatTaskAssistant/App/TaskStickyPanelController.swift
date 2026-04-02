import AppKit
import SwiftUI

@MainActor
final class TaskStickyPanelController: NSWindowController, NSWindowDelegate {
    private let appModel: AppModel
    private let defaultPanelSize = NSSize(width: 760, height: 600)

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func toggle(anchorFrame: CGRect?) {
        guard let panel = ensurePanel() else { return }

        if panel.isVisible {
            closePanel()
            return
        }

        show(anchorFrame: anchorFrame)
    }

    func show(anchorFrame: CGRect?) {
        guard let panel = ensurePanel() else { return }
        let targetFrame = anchoredFrame(for: panel, anchorFrame: anchorFrame)
        panel.setFrame(targetFrame, display: false)
        panel.orderFrontRegardless()
    }

    func closePanel() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel? {
        if let panel = window as? NSPanel {
            refreshContent(of: panel)
            return panel
        }

        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: defaultPanelSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 480, height: 380)
        panel.delegate = self

        window = panel
        refreshContent(of: panel)
        return panel
    }

    private func refreshContent(of panel: NSPanel) {
        panel.contentView = NSHostingView(
            rootView: StickyTaskBoardView(
                appModel: appModel,
                title: "Dock Note",
                subtitle: "单击选中，双击展开，双击标题重命名",
                onClose: { [weak self] in
                    self?.closePanel()
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }

    private func anchoredFrame(for panel: NSPanel, anchorFrame: CGRect?) -> CGRect {
        let panelSize = panel.frame.size == .zero ? defaultPanelSize : panel.frame.size
        let screen = screen(for: anchorFrame) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? CGRect(origin: .zero, size: panelSize)
        var origin = CGPoint(
            x: visibleFrame.maxX - panelSize.width - 24,
            y: visibleFrame.midY - panelSize.height * 0.55
        )

        if let anchorFrame {
            let showOnLeft = anchorFrame.midX > visibleFrame.midX
            origin.x = showOnLeft
                ? anchorFrame.minX - panelSize.width - 14
                : anchorFrame.maxX + 14
            origin.y = anchorFrame.midY - panelSize.height * 0.5
        }

        origin.x = min(max(origin.x, visibleFrame.minX + 18), visibleFrame.maxX - panelSize.width - 18)
        origin.y = min(max(origin.y, visibleFrame.minY + 18), visibleFrame.maxY - panelSize.height - 18)

        return CGRect(origin: origin, size: panelSize)
    }

    private func screen(for anchorFrame: CGRect?) -> NSScreen? {
        guard let anchorFrame else { return NSScreen.main }
        return NSScreen.screens.first { $0.frame.intersects(anchorFrame) }
    }
}
