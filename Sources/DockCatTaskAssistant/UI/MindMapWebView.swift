import SwiftUI
import WebKit

struct MindMapWebView: NSViewRepresentable {
    @ObservedObject var appModel: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(appModel: appModel)
    }

    func makeNSView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: Coordinator.bridgeName)
        userContentController.addUserScript(
            WKUserScript(
                source: context.coordinator.bootstrapScript(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.bind(webView)

        if let indexURL = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "MindMapApp"),
           let resourceRootURL = Optional(indexURL.deletingLastPathComponent()) {
            webView.loadFileURL(indexURL, allowingReadAccessTo: resourceRootURL)
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.appModel = appModel
        context.coordinator.syncStateIfNeeded()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let bridgeName = "mindMapBridge"

        var appModel: AppModel
        private weak var webView: WKWebView?
        private var lastRenderedDocument: MindMapDocument?
        private var isEditorReady = false
        private var hasSyncedInitialState = false
        /// 推送 mindMapData 后记录的推送代次；回显代次 < 当前代次时视为过期回显
        private var pushGeneration: UInt = 0
        /// 回显代次：收到的最新 mindMapData 对应的推送代次
        private var echoGeneration: UInt = 0

        init(appModel: AppModel) {
            self.appModel = appModel
        }

        func bind(_ webView: WKWebView) {
            self.webView = webView
            self.lastRenderedDocument = nil
            self.isEditorReady = false
            self.hasSyncedInitialState = false
            self.pushGeneration = 0
            self.echoGeneration = 0
        }

        func bootstrapScript() -> String {
            let document = appModel.mindMapDocument
            let configJSON = document.configJSON ?? "{}"
            let localConfigJSON = document.localConfigJSON ?? "null"
            let languageJSON = Self.jsonString(document.language)

            return """
            localStorage.setItem("webUseTip", "1");
            window.codexMindMapState = {
              mindMapData: \(document.dataJSON),
              mindMapConfig: \(configJSON),
              lang: \(languageJSON),
              localConfig: \(localConfigJSON)
            };
            """
        }

        func syncStateIfNeeded(force: Bool = false) {
            guard isEditorReady, let webView else { return }
            let document = appModel.mindMapDocument

            let dataChanged    = force || lastRenderedDocument?.dataJSON        != document.dataJSON
            let configChanged  = force || lastRenderedDocument?.configJSON      != document.configJSON
            let localChanged   = force || lastRenderedDocument?.localConfigJSON != document.localConfigJSON
            let langChanged    = force || lastRenderedDocument?.language        != document.language

            guard dataChanged || configChanged || localChanged || langChanged else { return }

            // 只在 dataJSON 变化时才包含 mindMapData，避免无谓的视觉刷新（JS 端 setData）
            var fields: [String] = []
            if dataChanged {
                fields.append("mindMapData: \(document.dataJSON)")
                // 递增推送代次；JS 端 codexMindMapHydrating 会阻止 500ms 内的回显，
                // 但 500ms 后仍可能到达的旧回显需要靠代次判定丢弃
                pushGeneration &+= 1
            }
            if configChanged {
                fields.append("mindMapConfig: \(document.configJSON ?? "{}")")
            }
            if localChanged {
                fields.append("localConfig: \(document.localConfigJSON ?? "null")")
            }
            if langChanged {
                fields.append("lang: \(Self.jsonString(document.language))")
            }

            let script = "window.codexApplyMindMapState({\(fields.joined(separator: ","))});"
            let capturedGeneration = pushGeneration

            webView.evaluateJavaScript(script) { [weak self] _, _ in
                guard let self else { return }
                self.lastRenderedDocument = document
                self.hasSyncedInitialState = true
                // 回显代次 = 本次推送代次；后续第一个回显会匹配该代次
                self.echoGeneration = capturedGeneration
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.bridgeName,
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            switch type {
            case "mindMapData":
                guard isEditorReady, hasSyncedInitialState else { return }
                // 回显代次 < 当前推送代次：这是过期推送的回显（如启动时空数据的回显），丢弃
                if echoGeneration < pushGeneration { return }
                if let payload = body["payload"], let json = Self.jsonString(from: payload) {
                    let payloadHasStableTaskIDs = MindMapTaskSynchronizer.hasStableTaskIDs(in: json)
                    let tasksBefore = appModel.snapshot.tasks
                    appModel.updateMindMapDocument(dataJSON: json)
                    let tasksAfter = appModel.snapshot.tasks
                    // 已有稳定 taskId 的脑图编辑，Web 端已经拿着最新内容，不需要再整图 setData，
                    // 否则会导致视图重新布局、位置跳动。只有新节点还缺少稳定 taskId 时，才允许回推归一化数据。
                    if tasksBefore == tasksAfter || payloadHasStableTaskIDs {
                        lastRenderedDocument = appModel.mindMapDocument
                    }
                }
            case "mindMapConfig":
                if let payload = body["payload"], let json = Self.jsonString(from: payload) {
                    appModel.updateMindMapDocument(configJSON: json)
                    lastRenderedDocument = appModel.mindMapDocument
                }
            case "localConfig":
                if let payload = body["payload"] {
                    let json = Self.jsonString(from: payload) ?? "null"
                    appModel.updateMindMapDocument(localConfigJSON: json)
                    lastRenderedDocument = appModel.mindMapDocument
                }
            case "language":
                if let language = body["payload"] as? String {
                    appModel.updateMindMapDocument(language: language)
                    lastRenderedDocument = appModel.mindMapDocument
                }
            case "appInited":
                isEditorReady = true
                syncStateIfNeeded(force: true)
            default:
                break
            }
        }

        private static func jsonString(from value: Any) -> String? {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: []),
                  let json = String(data: data, encoding: .utf8) else {
                return nil
            }
            return json
        }

        private static func jsonString(_ value: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
            let json = String(data: data ?? Data("[\"\"]".utf8), encoding: .utf8) ?? "[\"\"]"
            return String(json.dropFirst().dropLast())
        }
    }
}
