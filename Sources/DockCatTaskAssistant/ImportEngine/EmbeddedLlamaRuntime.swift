import Foundation

actor EmbeddedLlamaRuntime {
    static let shared = EmbeddedLlamaRuntime()

    private let fileManager: FileManager
    private var buildTask: _Concurrency.Task<URL, Error>?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func analyze(
        systemPrompt: String,
        userPrompt: String,
        modelFileURL: URL
    ) async throws -> String {
        guard fileManager.fileExists(atPath: modelFileURL.path) else {
            throw RuntimeError.modelNotFound("未找到 GGUF 模型文件：\(modelFileURL.path)")
        }

        let cliURL = try await prepareRuntime()
        return try runCLI(
            cliURL: cliURL,
            modelFileURL: modelFileURL,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
    }

    func prepareRuntime() async throws -> URL {
        if let buildTask {
            return try await buildTask.value
        }

        let buildTask = _Concurrency.Task(priority: .utility) { [self] in
            try ensureCLIAvailable()
        }
        self.buildTask = buildTask

        defer {
            self.buildTask = nil
        }

        return try await buildTask.value
    }

    private func runCLI(
        cliURL: URL,
        modelFileURL: URL,
        systemPrompt: String,
        userPrompt: String
    ) throws -> String {
        let jsonSchema = """
        {
          "type": "object",
          "properties": {
            "tasks": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "title": { "type": "string" },
                  "notes": { "type": "string" },
                  "projectName": { "type": "string" },
                  "priority": { "type": "integer", "minimum": 1, "maximum": 5 },
                  "tags": { "type": "array", "items": { "type": "string" } },
                  "dueText": { "type": "string" },
                  "urgencyScore": { "type": "integer", "minimum": 1, "maximum": 4 },
                  "importanceScore": { "type": "integer", "minimum": 1, "maximum": 4 },
                  "smart": {
                    "type": "object",
                    "properties": {
                      "action": { "type": "string" },
                      "deliverable": { "type": "string" },
                      "measure": { "type": "string" },
                      "relevance": { "type": "string" },
                      "time": { "type": "string" }
                    }
                  },
                  "children": {
                    "type": "array",
                    "items": { "type": "object" }
                  }
                },
                "required": ["title"]
              }
            }
          },
          "required": ["tasks"]
        }
        """

        let output = try runProcess(
            executableURL: cliURL,
            arguments: [
                "--log-disable",
                "--no-display-prompt",
                "--single-turn",
                "-ngl", "0",
                "-c", "4096",
                "-n", "512",
                "-t", "\(min(max(ProcessInfo.processInfo.activeProcessorCount, 4), 8))",
                "--temp", "0.1",
                "--json-schema", jsonSchema,
                "-m", modelFileURL.path,
                "-sys", systemPrompt,
                "-p", userPrompt,
            ]
        )

        guard let content = Self.normalizedOptionalText(output.stdout) else {
            throw RuntimeError.invalidOutput(Self.normalizedOptionalText(output.stderr) ?? "llama-cli 没有返回内容")
        }

        return content
    }

    @discardableResult
    private func runProcess(
        executableURL: URL,
        arguments: [String]
    ) throws -> ProcessOutput {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = Self.normalizedOptionalText(stderr)
                ?? Self.normalizedOptionalText(stdout)
                ?? "\(executableURL.lastPathComponent) exited with \(process.terminationStatus)"
            throw RuntimeError.commandFailed(message)
        }

        return ProcessOutput(stdout: stdout, stderr: stderr)
    }

    private static func normalizedOptionalText(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func ensureCLIAvailable() throws -> URL {
        let cliURL = cpuBuildDirectory.appendingPathComponent("bin/llama-cli", isDirectory: false)
        if fileManager.isExecutableFile(atPath: cliURL.path) {
            return cliURL
        }

        guard let llamaSourceDirectory = resolveLlamaSourceDirectory() else {
            throw RuntimeError.buildFailed("未找到 llama.cpp 源码目录，请确认仓库已包含 ThirdParty/Upstreams/llama.cpp")
        }

        try fileManager.createDirectory(at: runtimeRootDirectory, withIntermediateDirectories: true)
        try runProcess(
            executableURL: cmakeExecutableURL,
            arguments: [
                "-S", llamaSourceDirectory.path,
                "-B", cpuBuildDirectory.path,
                "-DCMAKE_BUILD_TYPE=Release",
                "-DLLAMA_BUILD_TESTS=OFF",
                "-DLLAMA_BUILD_EXAMPLES=OFF",
                "-DGGML_METAL=OFF",
            ]
        )
        try runProcess(
            executableURL: cmakeExecutableURL,
            arguments: [
                "--build", cpuBuildDirectory.path,
                "--target", "llama-cli",
                "-j", "\(max(ProcessInfo.processInfo.activeProcessorCount, 1))",
            ]
        )

        guard fileManager.isExecutableFile(atPath: cliURL.path) else {
            throw RuntimeError.buildFailed("llama-cli 编译完成后仍不可执行")
        }

        return cliURL
    }

    private func resolveLlamaSourceDirectory() -> URL? {
        if let bundledSource = Bundle.module.resourceURL?
            .appendingPathComponent("llama.cpp", isDirectory: true),
           fileManager.fileExists(atPath: bundledSource.path) {
            return bundledSource
        }

        var repoRelativeURL = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            repoRelativeURL.deleteLastPathComponent()
        }
        repoRelativeURL.appendPathComponent("ThirdParty/Upstreams/llama.cpp", isDirectory: true)

        guard fileManager.fileExists(atPath: repoRelativeURL.path) else {
            return nil
        }

        return repoRelativeURL
    }

    private var runtimeRootDirectory: URL {
        let baseDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return baseDirectory
            .appendingPathComponent("DockCatTaskAssistant", isDirectory: true)
            .appendingPathComponent("LocalModelRuntime", isDirectory: true)
    }

    private var cpuBuildDirectory: URL {
        runtimeRootDirectory.appendingPathComponent("llama.cpp-cpu", isDirectory: true)
    }

    private var cmakeExecutableURL: URL {
        let candidates = [
            "/opt/homebrew/bin/cmake",
            "/usr/local/bin/cmake",
            "/usr/bin/cmake",
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        return URL(fileURLWithPath: "/opt/homebrew/bin/cmake")
    }
}

private extension EmbeddedLlamaRuntime {
    struct ProcessOutput {
        var stdout: String
        var stderr: String
    }

    enum RuntimeError: LocalizedError {
        case modelNotFound(String)
        case buildFailed(String)
        case commandFailed(String)
        case invalidOutput(String)

        var errorDescription: String? {
            switch self {
            case let .modelNotFound(message):
                return message
            case let .buildFailed(message):
                return message
            case let .commandFailed(message):
                return message
            case let .invalidOutput(message):
                return message
            }
        }
    }
}
