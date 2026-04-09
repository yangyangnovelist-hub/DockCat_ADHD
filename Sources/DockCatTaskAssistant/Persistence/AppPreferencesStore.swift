import Defaults
import Foundation

struct AppPreferencesStore {
    func load() -> AppPreference {
        AppPreference(
            petEdge: PetEdge(rawValue: Defaults[.petEdge]) ?? .right,
            petOffsetY: Defaults[.petOffsetY],
            lowDistractionMode: Defaults[.lowDistractionMode],
            backgroundTaskIDs: Defaults[.backgroundTaskIDs],
            importAnalysis: ImportAnalysisPreference(
                provider: ImportAnalysisProvider(rawValue: Defaults[.importAnalysisProvider]) ?? .disabled,
                baseURL: Defaults[.importAnalysisBaseURL],
                modelName: Defaults[.importAnalysisModelName],
                modelFilePath: Defaults[.importAnalysisModelFilePath],
                apiKey: Defaults[.importAnalysisAPIKey]
            )
        )
    }

    func save(_ preference: AppPreference) {
        Defaults[.petEdge] = preference.petEdge.rawValue
        Defaults[.petOffsetY] = preference.petOffsetY
        Defaults[.lowDistractionMode] = preference.lowDistractionMode
        Defaults[.backgroundTaskIDs] = preference.backgroundTaskIDs
        Defaults[.importAnalysisProvider] = preference.importAnalysis.provider.rawValue
        Defaults[.importAnalysisBaseURL] = preference.importAnalysis.baseURL
        Defaults[.importAnalysisModelName] = preference.importAnalysis.modelName
        Defaults[.importAnalysisModelFilePath] = preference.importAnalysis.modelFilePath
        Defaults[.importAnalysisAPIKey] = preference.importAnalysis.apiKey
    }
}

extension Defaults.Keys {
    static let petEdge = Key<String>("petEdge", default: PetEdge.right.rawValue)
    static let petOffsetY = Key<Double>("petOffsetY", default: 220)
    static let lowDistractionMode = Key<Bool>("lowDistractionMode", default: false)
    static let backgroundTaskIDs = Key<[String]>("backgroundTaskIDs", default: [])
    static let importAnalysisProvider = Key<String>("importAnalysisProvider", default: ImportAnalysisProvider.disabled.rawValue)
    static let importAnalysisBaseURL = Key<String>("importAnalysisBaseURL", default: "")
    static let importAnalysisModelName = Key<String>("importAnalysisModelName", default: "")
    static let importAnalysisModelFilePath = Key<String>("importAnalysisModelFilePath", default: "")
    static let importAnalysisAPIKey = Key<String>("importAnalysisAPIKey", default: "")
}
