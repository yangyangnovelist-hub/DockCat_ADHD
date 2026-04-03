import XCTest
@testable import DockCatTaskAssistant

final class LocalModelImportAnalyzerTests: XCTestCase {
    func testImportAnalysisPreferenceDecodesLegacyPayloadWithoutModelFilePath() throws {
        let data = Data(
            """
            {
              "provider": "ollama",
              "baseURL": "",
              "modelName": "qwen2.5:7b-instruct",
              "apiKey": ""
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(ImportAnalysisPreference.self, from: data)

        XCTAssertEqual(decoded.provider, .ollama)
        XCTAssertEqual(decoded.modelName, "qwen2.5:7b-instruct")
        XCTAssertEqual(decoded.modelFilePath, "")
    }

    func testDecodePayload_extractsJSONInsideCodeFence() throws {
        let payload = try LocalModelImportAnalyzer.decodePayload(
            from: """
            ```json
            {
              "tasks": [
                {
                  "title": "准备发布",
                  "children": [
                    { "title": "写发布说明" }
                  ]
                }
              ]
            }
            ```
            """
        )

        XCTAssertEqual(payload.tasks.count, 1)
        XCTAssertEqual(payload.tasks.first?.title, "准备发布")
        XCTAssertEqual(payload.tasks.first?.childTasks.first?.title, "写发布说明")
    }

    func testDecodePayload_supportsBareTaskArray() throws {
        let payload = try LocalModelImportAnalyzer.decodePayload(
            from: """
            [
              {
                "title": "整理需求",
                "subtasks": [
                  { "title": "补充验收标准" }
                ]
              }
            ]
            """
        )

        XCTAssertEqual(payload.tasks.count, 1)
        XCTAssertEqual(payload.tasks.first?.title, "整理需求")
        XCTAssertEqual(payload.tasks.first?.childTasks.first?.title, "补充验收标准")
    }

    func testAppPreferenceDecodesLegacyPayloadWithoutImportAnalysis() throws {
        let data = Data(
            """
            {
              "petEdge": "right",
              "petOffsetY": 220,
              "lowDistractionMode": false,
              "backgroundTaskIDs": []
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(AppPreference.self, from: data)

        XCTAssertEqual(decoded.petEdge, .right)
        XCTAssertEqual(decoded.importAnalysis, .disabled)
    }

    func testOllamaCatalogPreferredSelectionUsesManifestBlobPath() async throws {
        let rootDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manifestsDirectory = rootDirectory
            .appendingPathComponent("manifests/library/qwen2.5", isDirectory: true)
        let blobsDirectory = rootDirectory.appendingPathComponent("blobs", isDirectory: true)

        try FileManager.default.createDirectory(at: manifestsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)

        let manifestURL = manifestsDirectory.appendingPathComponent("7b-instruct", isDirectory: false)
        try Data(
            """
            {
              "layers": [
                {
                  "mediaType": "application/vnd.ollama.image.model",
                  "digest": "sha256:abc123"
                }
              ]
            }
            """.utf8
        ).write(to: manifestURL)

        let blobURL = blobsDirectory.appendingPathComponent("sha256-abc123", isDirectory: false)
        FileManager.default.createFile(atPath: blobURL.path, contents: Data("gguf".utf8))

        let catalog = OllamaCatalog(modelsRootURL: rootDirectory)
        let selection = await catalog.preferredTaskImportSelection()

        XCTAssertEqual(selection?.name, "qwen2.5:7b-instruct")
        XCTAssertEqual(selection?.fileURL, blobURL)
    }
}
