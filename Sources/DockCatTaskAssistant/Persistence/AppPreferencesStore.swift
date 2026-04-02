import Defaults
import Foundation

struct AppPreferencesStore {
    func load() -> AppPreference {
        AppPreference(
            petEdge: PetEdge(rawValue: Defaults[.petEdge]) ?? .right,
            petOffsetY: Defaults[.petOffsetY],
            lowDistractionMode: Defaults[.lowDistractionMode],
            backgroundTaskIDs: Defaults[.backgroundTaskIDs]
        )
    }

    func save(_ preference: AppPreference) {
        Defaults[.petEdge] = preference.petEdge.rawValue
        Defaults[.petOffsetY] = preference.petOffsetY
        Defaults[.lowDistractionMode] = preference.lowDistractionMode
        Defaults[.backgroundTaskIDs] = preference.backgroundTaskIDs
    }
}

extension Defaults.Keys {
    static let petEdge = Key<String>("petEdge", default: PetEdge.right.rawValue)
    static let petOffsetY = Key<Double>("petOffsetY", default: 220)
    static let lowDistractionMode = Key<Bool>("lowDistractionMode", default: false)
    static let backgroundTaskIDs = Key<[String]>("backgroundTaskIDs", default: [])
}
