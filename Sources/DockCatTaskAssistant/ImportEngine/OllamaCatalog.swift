import Foundation

actor OllamaCatalog {
    static let shared = OllamaCatalog()

    private let fileManager: FileManager
    private let modelsRootURL: URL

    init(
        fileManager: FileManager = .default,
        modelsRootURL: URL? = nil
    ) {
        self.fileManager = fileManager
        if let modelsRootURL {
            self.modelsRootURL = modelsRootURL
        } else {
            let homeDirectory = fileManager.homeDirectoryForCurrentUser
            self.modelsRootURL = homeDirectory
                .appendingPathComponent(".ollama", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
        }
    }

    func preferredTaskImportSelection() async -> LocalModelSelection? {
        let manifests = loadManifests()

        if let exact = manifests.first(where: { $0.name.caseInsensitiveCompare("qwen2.5:7b-instruct") == .orderedSame }) {
            return LocalModelSelection(name: exact.name, fileURL: exact.modelFileURL)
        }

        if let instruct = manifests.first(where: { manifest in
            let lowered = manifest.name.lowercased()
            return lowered.contains("qwen2.5") && lowered.contains("instruct")
        }) {
            return LocalModelSelection(name: instruct.name, fileURL: instruct.modelFileURL)
        }

        if let qwen = manifests.first(where: { $0.name.lowercased().contains("qwen2.5") }) {
            return LocalModelSelection(name: qwen.name, fileURL: qwen.modelFileURL)
        }

        guard let fallback = manifests.first(where: { $0.name.lowercased().contains("qwen") })
            ?? manifests.first else {
            return nil
        }

        return LocalModelSelection(name: fallback.name, fileURL: fallback.modelFileURL)
    }

    func modelFileURL(named modelName: String) async -> URL? {
        loadManifests().first(where: { $0.name == modelName })?.modelFileURL
    }

    private func loadManifests() -> [ModelManifest] {
        let manifestsDirectory = modelsRootURL.appendingPathComponent("manifests", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: manifestsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var manifests: [ModelManifest] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }

            guard let manifest = loadManifest(from: fileURL) else {
                continue
            }

            manifests.append(manifest)
        }

        return manifests.sorted { $0.name < $1.name }
    }

    private func loadManifest(from fileURL: URL) -> ModelManifest? {
        let relativeComponents = fileURL.pathComponents
        guard let libraryIndex = relativeComponents.lastIndex(of: "library"),
              libraryIndex + 2 < relativeComponents.count else {
            return nil
        }

        let namespace = relativeComponents[libraryIndex + 1]
        let tag = relativeComponents[libraryIndex + 2]
        let modelName = "\(namespace):\(tag)"

        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(ManifestPayload.self, from: data),
              let modelLayer = decoded.layers.first(where: { $0.mediaType == "application/vnd.ollama.image.model" }) else {
            return nil
        }

        let blobName = modelLayer.digest.replacingOccurrences(of: ":", with: "-")
        let blobURL = modelsRootURL
            .appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(blobName, isDirectory: false)

        guard fileManager.fileExists(atPath: blobURL.path) else {
            return nil
        }

        return ModelManifest(name: modelName, modelFileURL: blobURL)
    }
}

struct LocalModelSelection: Sendable, Equatable {
    var name: String
    var fileURL: URL
}

private extension OllamaCatalog {
    struct ManifestPayload: Decodable {
        var layers: [Layer]
    }

    struct Layer: Decodable {
        var mediaType: String
        var digest: String
    }

    struct ModelManifest {
        var name: String
        var modelFileURL: URL
    }
}
