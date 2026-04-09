import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()

    private var petWindowController: PetWindowController?
    private var taskPanelController: TaskStickyPanelController?
    private var dashboardPresenter: (() -> Void)?
    private var configured = false
    private weak var dashboardWindow: NSWindow?
    private var dashboardVisibleObserver: NSObjectProtocol?
    private var suppressUnexpectedDashboardUntil = Date.distantPast
    private var explicitDashboardPresentationUntil = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = AppIconProvider.applicationIconImage {
            NSApp.applicationIconImage = icon
        }
        configureIfNeeded()
    }

    func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        if let icon = AppIconProvider.applicationIconImage {
            NSApp.applicationIconImage = icon
        }
        self.taskPanelController = TaskStickyPanelController(appModel: appModel)
        self.petWindowController = PetWindowController(appModel: appModel)
        self.petWindowController?.onSingleClick = { [weak self] anchorFrame in
            self?.showDockNote(anchorFrame: anchorFrame)
        }
        self.petWindowController?.onDoubleClick = { [weak self] in
            self?.taskPanelController?.closePanel()
            self?.showDashboard()
        }
        self.petWindowController?.onLongPress = { [weak self] in
            self?.taskPanelController?.closePanel()
            self?.appModel.toggleLowDistractionMode()
        }
        self.petWindowController?.updatePosition(animated: false)
    }

    func toggleDockNote() {
        taskPanelController?.toggle(anchorFrame: nil)
    }

    func showDashboard() {
        explicitDashboardPresentationUntil = Date().addingTimeInterval(0.9)
        suppressUnexpectedDashboardUntil = .distantPast
        if let dashboardWindow {
            dashboardWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        dashboardPresenter?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func registerDashboardPresenter(_ presenter: @escaping () -> Void) {
        dashboardPresenter = presenter
    }

    func registerDashboardWindow(_ window: NSWindow) {
        dashboardWindow = window

        if let dashboardVisibleObserver {
            NotificationCenter.default.removeObserver(dashboardVisibleObserver)
        }

        dashboardVisibleObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            _Concurrency.Task { @MainActor [weak self] in
                self?.handleUnexpectedDashboardVisibility()
            }
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        petWindowController?.updatePosition(animated: false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard flag else {
            showDashboard()
            return true
        }
        return true
    }

    private func showDockNote(anchorFrame: CGRect?) {
        suppressUnexpectedDashboardUntil = Date().addingTimeInterval(max(NSEvent.doubleClickInterval, 0.35))
        taskPanelController?.show(anchorFrame: anchorFrame)
    }

    private func handleUnexpectedDashboardVisibility() {
        let now = Date()
        guard now < suppressUnexpectedDashboardUntil else { return }
        guard now > explicitDashboardPresentationUntil else { return }
        dashboardWindow?.orderOut(nil)
    }
}
