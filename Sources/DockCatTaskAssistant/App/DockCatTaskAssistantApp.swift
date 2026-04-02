import AppKit
import SwiftUI

@main
struct DockCatTaskAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let appModel = appDelegate.appModel
        let dashboardMinimumSize = NSSize(width: 360, height: 260)

        Window("Dock Cat", id: "dashboard") {
            MainDashboardView(appModel: appModel)
                .background(
                    DashboardWindowBridge(
                        minimumSize: dashboardMinimumSize,
                        registerWindow: { window in
                            appDelegate.registerDashboardWindow(window)
                        }
                    ) { presenter in
                        appDelegate.registerDashboardPresenter(presenter)
                    }
                )
        }
        .defaultSize(width: 1360, height: 820)
        .commands {
            DockCatCommands(
                appModel: appModel,
                toggleDockNote: {
                    appDelegate.toggleDockNote()
                },
                showDashboard: {
                    appDelegate.showDashboard()
                }
            )
        }

        Window("Task Detail", id: "task-detail") {
            TaskDetailWindowView(appModel: appModel)
                .frame(minWidth: 420, minHeight: 720)
        }
        .defaultSize(width: 480, height: 820)

        MenuBarExtra("Dock Cat", systemImage: "pawprint.fill") {
            MenuBarContentView(appModel: appModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            Form {
                Toggle("低打扰模式", isOn: Binding(
                    get: { appModel.snapshot.preferences.lowDistractionMode },
                    set: { _ in appModel.toggleLowDistractionMode() }
                ))

                Picker("停靠边缘", selection: Binding(
                    get: { appModel.snapshot.preferences.petEdge },
                    set: { appModel.updatePetPlacement(edge: $0, centerY: appModel.snapshot.preferences.petOffsetY) }
                )) {
                    Text("左侧").tag(PetEdge.left)
                    Text("右侧").tag(PetEdge.right)
                }
            }
            .padding(20)
            .frame(width: 320)
        }
    }
}

private struct DashboardWindowBridge: View {
    let minimumSize: NSSize
    let registerWindow: (NSWindow) -> Void
    let registerPresenter: (@escaping () -> Void) -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        WindowAccessor { window in
            window.minSize = minimumSize
            registerWindow(window)
        }
        .frame(width: 0, height: 0)
        .onAppear {
            registerPresenter {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        AccessorView(onResolve: onResolve)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class AccessorView: NSView {
    private let onResolve: (NSWindow) -> Void

    init(onResolve: @escaping (NSWindow) -> Void) {
        self.onResolve = onResolve
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [onResolve] in
            onResolve(window)
        }
    }
}
