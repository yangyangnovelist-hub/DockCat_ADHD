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
                Section("通用") {
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

                Section("批量导入 AI 增强") {
                    let provider = appModel.snapshot.preferences.importAnalysis.provider

                    Picker("模型接口", selection: Binding(
                        get: { appModel.snapshot.preferences.importAnalysis.provider },
                        set: { appModel.updateImportAnalysisProvider($0) }
                    )) {
                        ForEach(ImportAnalysisProvider.allCases, id: \.rawValue) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }

                    TextField("模型名", text: Binding(
                        get: { appModel.snapshot.preferences.importAnalysis.modelName },
                        set: { appModel.updateImportAnalysisModelName($0) }
                    ), prompt: Text("例如 qwen2.5:7b-instruct"))
                    .disabled(provider == .disabled)

                    if provider == .ollama {
                        TextField("GGUF 文件", text: Binding(
                            get: { appModel.snapshot.preferences.importAnalysis.modelFilePath },
                            set: { appModel.updateImportAnalysisModelFilePath($0) }
                        ), prompt: Text("/path/to/model.gguf"))

                        HStack {
                            Button("自动检测本机模型") {
                                _Concurrency.Task {
                                    await appModel.autodetectLocalImportModel()
                                }
                            }

                            Button("选择 GGUF 文件…") {
                                appModel.chooseImportAnalysisModelFile()
                            }

                            Button(appModel.isPreparingLocalImportRuntime ? "准备中…" : "准备内嵌运行时") {
                                _Concurrency.Task {
                                    await appModel.prepareEmbeddedImportRuntimeIfNeeded()
                                }
                            }
                            .disabled(appModel.isPreparingLocalImportRuntime)
                        }

                        if let runtimeStatus = appModel.localImportRuntimeStatus?.nilIfEmpty {
                            Text(runtimeStatus)
                                .font(.footnote)
                                .foregroundStyle(appModel.localImportRuntimeStatusIsError ? .red : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if provider == .openAICompatible {
                        TextField("基础 URL", text: Binding(
                            get: { appModel.snapshot.preferences.importAnalysis.baseURL },
                            set: { appModel.updateImportAnalysisBaseURL($0) }
                        ), prompt: Text(appModel.snapshot.preferences.importAnalysis.resolvedBaseURL))
                        .disabled(provider == .disabled)

                        SecureField("API Key（可选）", text: Binding(
                            get: { appModel.snapshot.preferences.importAnalysis.apiKey },
                            set: { appModel.updateImportAnalysisAPIKey($0) }
                        ))
                        .disabled(provider == .disabled)
                    }

                    Text(provider == .ollama
                         ? "内嵌 GGUF 模式会把你选中的 GGUF 文件路径固定保存到 DockCat 配置里，并在首次使用时自动准备 llama.cpp 运行时。任务拆分全程本机完成，不走 Ollama HTTP API；模型失败时才会回退到当前规则解析。"
                         : "OpenAI 兼容接口模式会通过你填写的模型地址访问服务。模型失败时会回退到当前规则解析。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(width: 420)
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
