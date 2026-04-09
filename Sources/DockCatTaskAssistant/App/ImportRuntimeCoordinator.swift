import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ImportRuntimeCoordinator {
    struct State {
        var snapshot: AppSnapshot
        var importRuntimeNote: String?
        var localImportRuntimeStatus: String?
        var localImportRuntimeStatusIsError: Bool
        var isPreparingLocalImportRuntime: Bool
    }

    private let getState: () -> State
    private let mutateState: (@escaping (inout State) -> Void) -> Void
    private let persist: (String, String) -> Void

    init(
        getState: @escaping () -> State,
        mutateState: @escaping (@escaping (inout State) -> Void) -> Void,
        persist: @escaping (String, String) -> Void
    ) {
        self.getState = getState
        self.mutateState = mutateState
        self.persist = persist
    }

    func updateImportAnalysisProvider(_ provider: ImportAnalysisProvider) {
        mutateState { state in
            state.snapshot.preferences.importAnalysis.provider = provider
        }
        persist("preferences.import_analysis.provider", provider.rawValue)

        if provider == .ollama {
            _Concurrency.Task { [weak self] in
                await self?.autoconfigureLocalImportModelIfNeeded()
                await self?.prepareEmbeddedImportRuntimeIfNeeded()
            }
        }
    }

    func updateImportAnalysisBaseURL(_ baseURL: String) {
        mutateState { state in
            state.snapshot.preferences.importAnalysis.baseURL = baseURL
        }
        persist("preferences.import_analysis.base_url", baseURL)
    }

    func updateImportAnalysisModelName(_ modelName: String) {
        mutateState { state in
            state.snapshot.preferences.importAnalysis.modelName = modelName
        }
        persist("preferences.import_analysis.model", modelName)
    }

    func updateImportAnalysisModelFilePath(_ modelFilePath: String) {
        let shouldPrepareRuntime = getState().snapshot.preferences.importAnalysis.provider == .ollama
        mutateState { state in
            state.snapshot.preferences.importAnalysis.modelFilePath = modelFilePath
        }
        persist("preferences.import_analysis.model_file", modelFilePath)

        guard shouldPrepareRuntime else { return }
        _Concurrency.Task { [weak self] in
            await self?.prepareEmbeddedImportRuntimeIfNeeded()
        }
    }

    func updateImportAnalysisAPIKey(_ apiKey: String) {
        mutateState { state in
            state.snapshot.preferences.importAnalysis.apiKey = apiKey
        }
        persist("preferences.import_analysis.api_key", apiKey.isEmpty ? "empty" : "set")
    }

    func chooseImportAnalysisModelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择 GGUF"
        panel.title = "选择本地 GGUF 模型文件"
        panel.message = "DockCat 会记住这份 GGUF 文件路径，之后直接用于任务分析。"
        if let ggufType = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [ggufType]
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        mutateState { state in
            state.snapshot.preferences.importAnalysis.provider = .ollama
            state.snapshot.preferences.importAnalysis.baseURL = ""
            state.snapshot.preferences.importAnalysis.apiKey = ""
            state.snapshot.preferences.importAnalysis.modelFilePath = selectedURL.path
            if state.snapshot.preferences.importAnalysis.trimmedModelName.isEmpty {
                state.snapshot.preferences.importAnalysis.modelName = selectedURL.deletingPathExtension().lastPathComponent
            }
        }
        persist("preferences.import_analysis.model_file.picked", selectedURL.path)

        _Concurrency.Task { [weak self] in
            await self?.prepareEmbeddedImportRuntimeIfNeeded()
        }
    }

    func autodetectLocalImportModel() async {
        guard let selection = await OllamaCatalog.shared.preferredTaskImportSelection() else {
            mutateState { state in
                state.localImportRuntimeStatus = "未在 ~/.ollama/models 中发现可用的 GGUF 模型"
                state.localImportRuntimeStatusIsError = true
            }
            return
        }

        mutateState { state in
            state.snapshot.preferences.importAnalysis.provider = .ollama
            state.snapshot.preferences.importAnalysis.baseURL = ""
            state.snapshot.preferences.importAnalysis.modelName = selection.name
            state.snapshot.preferences.importAnalysis.modelFilePath = selection.fileURL.path
            state.snapshot.preferences.importAnalysis.apiKey = ""
            state.importRuntimeNote = "已连接本机 GGUF 模型：\(selection.name)"
            state.localImportRuntimeStatus = "已锁定模型文件：\(selection.fileURL.lastPathComponent)"
            state.localImportRuntimeStatusIsError = false
        }
        persist("preferences.import_analysis.autoconfigured", selection.name)

        await prepareEmbeddedImportRuntimeIfNeeded()
    }

    func prepareEmbeddedImportRuntimeIfNeeded() async {
        let preference = getState().snapshot.preferences.importAnalysis
        guard preference.provider == .ollama else {
            mutateState { state in
                state.localImportRuntimeStatus = nil
                state.localImportRuntimeStatusIsError = false
            }
            return
        }

        let modelPath = preference.trimmedModelFilePath
        guard !modelPath.isEmpty else {
            mutateState { state in
                state.localImportRuntimeStatus = "请选择 GGUF 文件，或使用自动检测写入固定路径"
                state.localImportRuntimeStatusIsError = true
            }
            return
        }

        mutateState { state in
            state.isPreparingLocalImportRuntime = true
            state.localImportRuntimeStatus = "正在准备内嵌运行时…"
            state.localImportRuntimeStatusIsError = false
        }

        do {
            let cliURL = try await EmbeddedLlamaRuntime.shared.prepareRuntime()
            mutateState { state in
                state.localImportRuntimeStatus = "内嵌运行时已就绪：\(cliURL.lastPathComponent) · 模型 \(URL(fileURLWithPath: modelPath).lastPathComponent)"
                state.localImportRuntimeStatusIsError = false
                state.isPreparingLocalImportRuntime = false
            }
        } catch {
            mutateState { state in
                state.localImportRuntimeStatus = "内嵌运行时准备失败：\(error.localizedDescription)"
                state.localImportRuntimeStatusIsError = true
                state.isPreparingLocalImportRuntime = false
            }
        }
    }

    func finishLocalImportBootstrap() async {
        await autoconfigureLocalImportModelIfNeeded()
        await prepareEmbeddedImportRuntimeIfNeeded()
    }

    private func autoconfigureLocalImportModelIfNeeded() async {
        let currentPreference = await MainActor.run { getState().snapshot.preferences.importAnalysis }
        guard currentPreference.provider == .disabled
            || (currentPreference.trimmedModelName.isEmpty && currentPreference.trimmedModelFilePath.isEmpty) else {
            return
        }

        guard let selection = await OllamaCatalog.shared.preferredTaskImportSelection() else {
            return
        }

        mutateState { state in
            let latestPreference = state.snapshot.preferences.importAnalysis
            guard latestPreference.provider == .disabled
                || (latestPreference.trimmedModelName.isEmpty && latestPreference.trimmedModelFilePath.isEmpty) else {
                return
            }

            state.snapshot.preferences.importAnalysis.provider = .ollama
            state.snapshot.preferences.importAnalysis.baseURL = ""
            state.snapshot.preferences.importAnalysis.modelName = selection.name
            state.snapshot.preferences.importAnalysis.modelFilePath = selection.fileURL.path
            state.snapshot.preferences.importAnalysis.apiKey = ""
            state.importRuntimeNote = "已自动连接本机 GGUF 模型：\(selection.name)"
            state.localImportRuntimeStatus = "已锁定模型文件：\(selection.fileURL.lastPathComponent)"
            state.localImportRuntimeStatusIsError = false
        }
        persist("preferences.import_analysis.autoconfigured", selection.name)
    }
}
