import AppKit
import BongoCatInputBridge
import Combine
import OnScreen
import Pets

@MainActor
final class PetWindowController: NSWindowController {
    private let appModel: AppModel
    private let settings: DockCatOnScreenSettings
    private let inputMonitor: InputMonitor
    private var cancellables = Set<AnyCancellable>()
    private var isVisible = false

    init(appModel: AppModel) {
        self.appModel = appModel
        self.settings = DockCatOnScreenSettings()
        self.inputMonitor = InputMonitor { [weak appModel] _ in
            _Concurrency.Task { @MainActor in
                appModel?.noteExternalInput()
            }
        }
        super.init(window: nil)

        bindAppModel()
        render(forceRestart: true)
        inputMonitor.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func updatePosition(animated: Bool) {
        _ = animated
        let didChange = settings.apply(snapshot: appModel.snapshot, petState: appModel.petState)
        render(forceRestart: didChange || !isVisible)
    }

    deinit {
        OnScreen.hide()
    }

    private func bindAppModel() {
        appModel.$snapshot
            .combineLatest(appModel.$petState)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot, petState in
                guard let self else { return }
                let didChange = self.settings.apply(snapshot: snapshot, petState: petState)
                self.render(forceRestart: didChange || !self.isVisible)
            }
            .store(in: &cancellables)
    }

    private func render(forceRestart: Bool = false) {
        guard forceRestart || !isVisible else { return }

        if isVisible {
            OnScreen.hide()
        }

        OnScreen.show(with: settings)
        isVisible = true
    }
}

private final class DockCatOnScreenSettings: @MainActor OnScreenSettings {
    var gravityEnabled: Bool = false
    var petSize: CGFloat = 75
    var speedMultiplier: CGFloat = 1
    var animationFPS: TimeInterval = 0
    var desktopInteractions: Bool = false
    var selectedPets: [String] = ["cat"]
    var ufoAbductionSchedule: String = ""
    var spawnEdge: OnScreenSpawnEdge = .right
    var preferredVerticalRatio: CGFloat = 0.24
    private var signature = Signature(
        gravityEnabled: false,
        petSize: 75,
        desktopInteractions: false,
        selectedPets: ["cat"],
        spawnEdge: .right,
        preferredVerticalRatio: 0.24
    )

    @discardableResult
    func apply(snapshot: AppSnapshot, petState: PetVisualState) -> Bool {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let verticalRatio = CGFloat(min(max(snapshot.preferences.petOffsetY / screenHeight, 0.14), 0.82))
        let edge: OnScreenSpawnEdge = snapshot.preferences.petEdge == .left ? .left : .right
        let nextSignature = Signature(
            gravityEnabled: false,
            petSize: snapshot.preferences.lowDistractionMode ? 82 : 98,
            desktopInteractions: !snapshot.preferences.lowDistractionMode,
            selectedPets: species(for: petState),
            spawnEdge: edge,
            preferredVerticalRatio: verticalRatio
        )

        gravityEnabled = nextSignature.gravityEnabled
        petSize = nextSignature.petSize
        speedMultiplier = speed(for: petState)
        animationFPS = speedMultiplier == 0 ? 0 : 8
        desktopInteractions = nextSignature.desktopInteractions
        selectedPets = nextSignature.selectedPets
        spawnEdge = nextSignature.spawnEdge
        preferredVerticalRatio = nextSignature.preferredVerticalRatio

        let changed = nextSignature != signature
        signature = nextSignature
        return changed
    }

    func remove(pet: Pet) {
        selectedPets.removeAll { $0 == pet.id }
        if selectedPets.isEmpty {
            selectedPets = ["cat"]
        }
    }

    private func speed(for state: PetVisualState) -> CGFloat {
        switch state {
        case .idle: 0
        default: 0
        }
    }

    private func species(for state: PetVisualState) -> [String] {
        switch state {
        case .alert:
            return ["cat_grumpy"]
        case .celebrate:
            return ["cat_blue"]
        default:
            return ["cat_black"]
        }
    }
}

private extension DockCatOnScreenSettings {
    struct Signature: Equatable {
        var gravityEnabled: Bool
        var petSize: CGFloat
        var desktopInteractions: Bool
        var selectedPets: [String]
        var spawnEdge: OnScreenSpawnEdge
        var preferredVerticalRatio: CGFloat
    }
}
