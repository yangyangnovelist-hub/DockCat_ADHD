import AppKit
import Combine
import OnScreen

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel = AppModel()

    private var petWindowController: PetWindowController?
    private var taskPanelController: TaskStickyPanelController?
    private var dashboardPresenter: (() -> Void)?
    private var configured = false
    private var cancellables = Set<AnyCancellable>()
    private var pendingPetPrimaryClick: DispatchWorkItem?
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
        self.petWindowController?.updatePosition(animated: false)
        bindNotifications()
    }

    func toggleDockNote() {
        taskPanelController?.toggle(anchorFrame: nil)
    }

    func showDashboard() {
        explicitDashboardPresentationUntil = Date().addingTimeInterval(0.9)
        suppressUnexpectedDashboardUntil = .distantPast
        if let dashboardPresenter {
            dashboardPresenter()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
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
        guard flag else { return false }
        return true
    }

    private func bindNotifications() {
        NotificationCenter.default.publisher(for: .onScreenEntityPrimaryClick)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let self else { return }
                let anchorFrame = (notification.userInfo?[OnScreenNotificationUserInfoKey.windowFrame] as? NSValue)?.rectValue
                let clickCount = notification.userInfo?[OnScreenNotificationUserInfoKey.clickCount] as? Int ?? 1
                if clickCount >= 2 {
                    self.pendingPetPrimaryClick?.cancel()
                    self.pendingPetPrimaryClick = nil
                    self.showDashboard()
                } else {
                    self.scheduleDockNotePresentation(anchorFrame: anchorFrame)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.petWindowController?.updatePosition(animated: false)
            }
            .store(in: &cancellables)
    }

    private func scheduleDockNotePresentation(anchorFrame: CGRect?) {
        pendingPetPrimaryClick?.cancel()
        suppressUnexpectedDashboardUntil = Date().addingTimeInterval(max(NSEvent.doubleClickInterval, 0.35))

        let workItem = DispatchWorkItem { [weak self] in
            self?.taskPanelController?.show(anchorFrame: anchorFrame)
            self?.pendingPetPrimaryClick = nil
        }

        pendingPetPrimaryClick = workItem
        let singleClickDelay = min(max(NSEvent.doubleClickInterval * 0.38, 0.1), 0.16)
        DispatchQueue.main.asyncAfter(deadline: .now() + singleClickDelay, execute: workItem)
    }

    private func handleUnexpectedDashboardVisibility() {
        let now = Date()
        guard now < suppressUnexpectedDashboardUntil else { return }
        guard now > explicitDashboardPresentationUntil else { return }
        dashboardWindow?.orderOut(nil)
    }
}
