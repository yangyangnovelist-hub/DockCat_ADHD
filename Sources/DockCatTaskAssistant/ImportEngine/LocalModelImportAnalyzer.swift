import Foundation

struct LocalModelImportAnalysis: Sendable {
    var tasks: [LocalModelImportAnalyzer.Payload.Task]
    var runtimeLabel: String
}

actor LocalModelImportAnalyzer {
    static let shared = LocalModelImportAnalyzer()

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    func analyze(
        rawText: String,
        preference: ImportAnalysisPreference,
        referenceDate: Date = .now
    ) async throws -> LocalModelImportAnalysis {
        guard preference.isEnabled else {
            throw AnalyzerError.missingConfiguration("未启用本地模型增强")
        }

        let prompt = Self.makePrompt(
            rawText: rawText,
            referenceDate: referenceDate
        )

        let content: String
        switch preference.provider {
        case .disabled:
            throw AnalyzerError.missingConfiguration("未启用本地模型增强")
        case .ollama:
            content = try await requestOllama(prompt: prompt, preference: preference)
        case .openAICompatible:
            content = try await requestOpenAICompatible(prompt: prompt, preference: preference)
        }

        let payload = try Self.decodePayload(from: content)
        return LocalModelImportAnalysis(
            tasks: payload.tasks,
            runtimeLabel: preference.runtimeLabel
        )
    }

    private func requestOllama(
        prompt: Prompt,
        preference: ImportAnalysisPreference
    ) async throws -> String {
        do {
            let modelFileURL = try await resolvedLocalModelFileURL(preference: preference)
            return try await EmbeddedLlamaRuntime.shared.analyze(
                systemPrompt: prompt.systemMessage,
                userPrompt: prompt.userMessage,
                modelFileURL: modelFileURL
            )
        } catch {
            throw AnalyzerError.requestFailed(error.localizedDescription)
        }
    }

    private func requestOpenAICompatible(
        prompt: Prompt,
        preference: ImportAnalysisPreference
    ) async throws -> String {
        let url = try endpointURL(baseURL: preference.resolvedBaseURL, path: "/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = preference.trimmedAPIKey.nilIfEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(
            OpenAICompatibleRequest(
                model: preference.trimmedModelName,
                temperature: 0.1,
                messages: prompt.messages
            )
        )

        let (data, response) = try await session.data(for: request)
        try Self.validateHTTPResponse(response, data: data)
        let decoded = try JSONDecoder().decode(OpenAICompatibleResponse.self, from: data)
        guard let content = Self.normalizedOptionalText(decoded.choices.first?.message.content) else {
            throw AnalyzerError.invalidResponse("模型接口没有返回可解析内容")
        }
        return content
    }

    private func endpointURL(baseURL: String, path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AnalyzerError.missingConfiguration("缺少模型接口地址")
        }

        let normalizedBase = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        let normalizedPath = path.hasPrefix("/") ? path : "/" + path

        guard let url = URL(string: normalizedBase + normalizedPath) else {
            throw AnalyzerError.missingConfiguration("模型接口地址无效：\(trimmed)")
        }

        return url
    }

    private func resolvedLocalModelFileURL(preference: ImportAnalysisPreference) async throws -> URL {
        if let explicitPath = preference.trimmedModelFilePath.nilIfEmpty {
            let explicitURL = URL(fileURLWithPath: explicitPath)
            guard FileManager.default.fileExists(atPath: explicitURL.path) else {
                throw AnalyzerError.missingConfiguration("已配置的 GGUF 文件不存在：\(explicitPath)")
            }
            return explicitURL
        }

        if let modelName = preference.trimmedModelName.nilIfEmpty,
           let discoveredURL = await OllamaCatalog.shared.modelFileURL(named: modelName) {
            return discoveredURL
        }

        throw AnalyzerError.missingConfiguration("未配置 GGUF 文件，请在设置里选择模型文件")
    }

    static func decodePayload(from content: String) throws -> Payload {
        let extracted = try extractJSONPayload(from: content)
        let decoder = JSONDecoder()

        if let data = extracted.data(using: .utf8) {
            if let payload = try? decoder.decode(Payload.self, from: data) {
                return payload
            }

            if let tasks = try? decoder.decode([Payload.Task].self, from: data) {
                return Payload(tasks: tasks)
            }
        }

        throw AnalyzerError.invalidResponse("模型输出不是约定的 JSON 结构")
    }

    static func extractJSONPayload(from content: String) throws -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AnalyzerError.invalidResponse("模型返回了空内容")
        }

        let strippedFence = stripCodeFence(from: trimmed)
        let candidate = strippedFence.trimmingCharacters(in: .whitespacesAndNewlines)

        if (candidate.hasPrefix("{") && candidate.hasSuffix("}")) ||
            (candidate.hasPrefix("[") && candidate.hasSuffix("]")) {
            return candidate
        }

        if let object = sliceBalancedJSON(in: candidate, open: "{", close: "}") {
            return object
        }

        if let array = sliceBalancedJSON(in: candidate, open: "[", close: "]") {
            return array
        }

        throw AnalyzerError.invalidResponse("没有找到可解析的 JSON")
    }

    private static func stripCodeFence(from content: String) -> String {
        guard content.hasPrefix("```") else { return content }
        let lines = content.components(separatedBy: .newlines)
        guard lines.count >= 3 else { return content }
        let body = lines.dropFirst().dropLast().joined(separator: "\n")
        return body
    }

    private static func sliceBalancedJSON(in content: String, open: Character, close: Character) -> String? {
        guard let start = content.firstIndex(of: open) else { return nil }

        var depth = 0
        var endIndex: String.Index?
        for index in content[start...].indices {
            let character = content[index]
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 {
                    endIndex = index
                    break
                }
            }
        }

        guard let endIndex else { return nil }
        return String(content[start...endIndex])
    }

    private static func makePrompt(
        rawText: String,
        referenceDate: Date
    ) -> Prompt {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]
        let referenceDateText = dateFormatter.string(from: referenceDate)

        let system = """
        你是 DockCat 的任务批量导入分析器。请把原始文本拆解成任务树，并且只输出 JSON。

        输出必须满足这个结构：
        {
          "tasks": [
            {
              "title": "任务标题",
              "notes": "补充说明，可为空字符串",
              "projectName": "项目名，可为空字符串",
              "priority": 1,
              "tags": ["标签1"],
              "dueText": "可被自然语言解析的时间描述，可为空字符串",
              "urgencyScore": 1,
              "importanceScore": 1,
              "smart": {
                "action": "",
                "deliverable": "",
                "measure": "",
                "relevance": "",
                "time": ""
              },
              "children": []
            }
          ]
        }

        规则：
        1. 只输出 JSON，不要 markdown，不要解释。
        2. 保持输入顺序。
        3. 能推断层级时使用 children。
        4. 只在有把握时填写字段；不确定就给空字符串、空数组或省略。
        5. priority 只能是 1-5；urgencyScore 和 importanceScore 只能是 1-4。
        6. dueText 用自然语言短语，不要自己生成 ISO 时间。
        """

        let user = """
        当前参考时间：\(referenceDateText)
        当前时区：\(TimeZone.current.identifier)

        原始输入：
        \(rawText)
        """

        return Prompt(
            messages: [
                ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: user),
            ]
        )
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnalyzerError.invalidResponse("模型接口没有返回 HTTP 响应")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let responseText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = normalizedOptionalText(responseText) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw AnalyzerError.requestFailed("模型接口返回 \(httpResponse.statusCode)：\(message)")
        }
    }

    private static func normalizedOptionalText(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

}

extension LocalModelImportAnalyzer {
    struct Payload: Decodable, Sendable {
        var tasks: [Task]

        struct Task: Decodable, Sendable {
            var title: String
            var notes: String?
            var projectName: String?
            var priority: Int?
            var tags: [String]?
            var dueText: String?
            var urgencyScore: Int?
            var importanceScore: Int?
            var smart: Smart?
            var children: [Task]?
            var subtasks: [Task]?

            var childTasks: [Task] {
                let nested = (children ?? []) + (subtasks ?? [])
                return nested
            }

            private enum CodingKeys: String, CodingKey {
                case title
                case taskName = "task_name"
                case notes
                case details
                case projectName
                case project
                case priority
                case tags
                case dueText
                case dueDate = "due_date"
                case urgencyScore
                case importanceScore
                case smart
                case children
                case subtasks
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                title = try container.decodeIfPresent(String.self, forKey: .title)
                    ?? container.decodeIfPresent(String.self, forKey: .taskName)
                    ?? ""
                notes = try container.decodeIfPresent(String.self, forKey: .notes)
                    ?? container.decodeIfPresent(String.self, forKey: .details)
                projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
                    ?? container.decodeIfPresent(String.self, forKey: .project)
                priority = try container.decodeIfPresent(Int.self, forKey: .priority)
                tags = try container.decodeIfPresent([String].self, forKey: .tags)
                dueText = try container.decodeIfPresent(String.self, forKey: .dueText)
                    ?? container.decodeIfPresent(String.self, forKey: .dueDate)
                urgencyScore = try container.decodeIfPresent(Int.self, forKey: .urgencyScore)
                importanceScore = try container.decodeIfPresent(Int.self, forKey: .importanceScore)
                smart = try container.decodeIfPresent(Smart.self, forKey: .smart)
                children = try container.decodeIfPresent([Task].self, forKey: .children)
                subtasks = try container.decodeIfPresent([Task].self, forKey: .subtasks)
            }
        }

        struct Smart: Decodable, Sendable {
            var action: String?
            var deliverable: String?
            var measure: String?
            var relevance: String?
            var time: String?

            private enum CodingKeys: String, CodingKey {
                case action
                case deliverable
                case measure
                case relevance
                case time
                case result
                case reason
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                action = try container.decodeIfPresent(String.self, forKey: .action)
                deliverable = try container.decodeIfPresent(String.self, forKey: .deliverable)
                    ?? container.decodeIfPresent(String.self, forKey: .result)
                measure = try container.decodeIfPresent(String.self, forKey: .measure)
                relevance = try container.decodeIfPresent(String.self, forKey: .relevance)
                    ?? container.decodeIfPresent(String.self, forKey: .reason)
                time = try container.decodeIfPresent(String.self, forKey: .time)
            }
        }
    }
}

private extension LocalModelImportAnalyzer {
    struct Prompt: Sendable {
        var messages: [ChatMessage]

        var systemMessage: String {
            messages.first(where: { $0.role == "system" })?.content ?? ""
        }

        var userMessage: String {
            messages.first(where: { $0.role == "user" })?.content ?? ""
        }
    }

    struct ChatMessage: Codable, Sendable {
        var role: String
        var content: String
    }

    struct OpenAICompatibleRequest: Codable, Sendable {
        var model: String
        var temperature: Double
        var messages: [ChatMessage]
    }

    struct OpenAICompatibleResponse: Decodable, Sendable {
        var choices: [Choice]

        struct Choice: Decodable, Sendable {
            var message: Message
        }

        struct Message: Decodable, Sendable {
            var content: String
        }
    }

    enum AnalyzerError: LocalizedError {
        case missingConfiguration(String)
        case requestFailed(String)
        case invalidResponse(String)

        var errorDescription: String? {
            switch self {
            case let .missingConfiguration(message):
                return message
            case let .requestFailed(message):
                return message
            case let .invalidResponse(message):
                return message
            }
        }
    }
}
