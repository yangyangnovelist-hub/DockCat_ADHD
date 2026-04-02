import Foundation

actor DucklingRuntime {
    static let shared = DucklingRuntime()

    private let session = URLSession(configuration: .ephemeral)
    private let port = 8765
    private var serverProcess: Process?

    func resolveDueDate(from text: String, referenceDate: Date = .now) async -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            try await ensureServerRunning()
            return try await requestDate(from: trimmed, locale: preferredLocale(for: trimmed), referenceDate: referenceDate)
        } catch {
            return nil
        }
    }

    private func ensureServerRunning() async throws {
        if try await pingServer() {
            return
        }

        if serverProcess?.isRunning != true {
            try startServer()
        }

        for _ in 0..<20 {
            try await _Concurrency.Task.sleep(nanoseconds: 500_000_000)
            if try await pingServer() {
                return
            }
        }

        throw DucklingError.startupTimedOut
    }

    private func pingServer() async throws -> Bool {
        let url = URL(string: "http://127.0.0.1:\(port)")!
        let (_, response) = try await session.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func startServer() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["stack", "exec", "duckling-example-exe"]
        process.currentDirectoryURL = ducklingDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = "\(port)"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        serverProcess = process
    }

    private func requestDate(
        from text: String,
        locale: String,
        referenceDate: Date
    ) async throws -> Date? {
        let url = URL(string: "http://127.0.0.1:\(port)/parse")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "locale": locale,
            "text": text,
            "dims": "[\"time\"]",
            "reftime": String(Int(referenceDate.timeIntervalSince1970 * 1000)),
            "tz": TimeZone.current.identifier,
            "latent": "false",
        ])

        let (data, _) = try await session.data(for: request)
        let entities = try JSONDecoder().decode([DucklingEntity].self, from: data)

        for entity in entities where entity.dim == "time" {
            if let direct = entity.value.value.flatMap(Self.decodeDate) {
                return direct
            }
            if let value = entity.value.values?.first?.value.flatMap(Self.decodeDate) {
                return value
            }
        }

        return nil
    }

    private func preferredLocale(for text: String) -> String {
        text.containsChineseCharacters ? "zh_CN" : "en_US"
    }

    private func formBody(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = values
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .sorted()
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private static func decodeDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private var ducklingDirectory: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("ThirdParty/Upstreams/duckling", isDirectory: true)
    }
}

private extension DucklingRuntime {
    struct DucklingEntity: Decodable {
        let dim: String
        let value: DucklingResolvedValue
    }

    struct DucklingResolvedValue: Decodable {
        let value: String?
        let values: [DucklingValueOption]?
    }

    struct DucklingValueOption: Decodable {
        let value: String?
    }

    enum DucklingError: Error {
        case startupTimedOut
    }
}

private extension String {
    var containsChineseCharacters: Bool {
        unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
        }
    }
}
