import Foundation

actor WhisperTranscriber {
    static let shared = WhisperTranscriber()

    func transcribe(audioFileURL: URL) throws -> String {
        let fileManager = FileManager.default
        let outputDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DockCatWhisper", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "python3",
            "-m",
            "whisper",
            audioFileURL.path,
            "--model",
            "base",
            "--task",
            "transcribe",
            "--language",
            "Chinese",
            "--output_format",
            "json",
            "--output_dir",
            outputDirectory.path,
            "--fp16",
            "False",
            "--verbose",
            "False",
        ]
        process.environment = whisperEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw WhisperError.commandFailed(errorOutput.nilIfBlank ?? "Whisper exited with \(process.terminationStatus)")
        }

        let jsonURL = outputDirectory.appendingPathComponent(audioFileURL.deletingPathExtension().lastPathComponent + ".json")
        guard fileManager.fileExists(atPath: jsonURL.path) else {
            throw WhisperError.missingOutput(jsonURL.path)
        }

        let data = try Data(contentsOf: jsonURL)
        let result = try JSONDecoder().decode(WhisperOutput.self, from: data)
        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty else {
            throw WhisperError.emptyTranscript
        }

        return transcript
    }

    private func whisperEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        if let certPath = try? pythonCommandOutput(arguments: [
            "python3",
            "-c",
            "import certifi; print(certifi.where())",
        ]).nilIfBlank {
            environment["SSL_CERT_FILE"] = certPath
            environment["REQUESTS_CA_BUNDLE"] = certPath
        }

        return environment
    }

    private func pythonCommandOutput(arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw WhisperError.commandFailed(errorOutput.nilIfBlank ?? "Failed to inspect Python environment")
        }

        return String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private extension WhisperTranscriber {
    struct WhisperOutput: Decodable {
        let text: String
    }

    enum WhisperError: LocalizedError {
        case commandFailed(String)
        case missingOutput(String)
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case let .commandFailed(message):
                return message
            case let .missingOutput(path):
                return "Whisper 没有生成转写结果：\(path)"
            case .emptyTranscript:
                return "Whisper 没有识别到可用文本"
            }
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
