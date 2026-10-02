import Foundation
import ScreenPhysicalBridge

enum SceneSimulationModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case physical = "physical"
    case vfxContinuity = "vfx-continuity"

    var id: String { rawValue }

}

struct SceneSimulationModelPresentation: Sendable {
    struct Option: Identifiable, Sendable {
        let id: SceneSimulationModel
        let label: String
    }

    let options: [Option]
    let relativeLevelID: String
    let relativeLevelLabel: String
    let relativeLevelUnit: String
    let relativeLevelRange: ClosedRange<Double>
    let relativeLevelDefault: Double
    let emissionPresenceID: String
    let emissionPresenceLabel: String
    let emissionPresenceUnit: String
    let emissionPresenceRange: ClosedRange<Double>
    let emissionPresenceDefault: Double
    let chromaticFringeID: String
    let chromaticFringeLabel: String
    let chromaticFringeUnit: String
    let chromaticFringeRange: ClosedRange<Double>
    let chromaticFringeDefault: Double

    static let current = try! load()

    static func load() throws -> Self {
        var raw = ScreenSimulationModelAuthoringDescriptorV2()
        guard screen_application_simulation_model_descriptor_v2(&raw),
              let physicalID = raw.physical_id,
              let physicalLabel = raw.physical_label,
              let vfxID = raw.vfx_continuity_id,
              let vfxLabel = raw.vfx_continuity_label,
              let levelID = raw.relative_level_id,
              let levelLabel = raw.relative_level_label,
              let levelUnit = raw.relative_level_unit,
              let emissionID = raw.emission_presence_id,
              let emissionLabel = raw.emission_presence_label,
              let emissionUnit = raw.emission_presence_unit,
              let fringeID = raw.chromatic_fringe_id,
              let fringeLabel = raw.chromatic_fringe_label,
              let fringeUnit = raw.chromatic_fringe_unit,
              let physical = SceneSimulationModel(rawValue: String(cString: physicalID)),
              let vfx = SceneSimulationModel(rawValue: String(cString: vfxID)),
              physical == .physical,
              vfx == .vfxContinuity,
              raw.relative_level_minimum.isFinite,
              raw.relative_level_maximum.isFinite,
              raw.relative_level_default.isFinite,
              raw.relative_level_minimum <= raw.relative_level_default,
              raw.relative_level_default <= raw.relative_level_maximum,
              raw.emission_presence_minimum.isFinite,
              raw.emission_presence_maximum.isFinite,
              raw.emission_presence_default.isFinite,
              raw.emission_presence_minimum <= raw.emission_presence_default,
              raw.emission_presence_default <= raw.emission_presence_maximum,
              raw.chromatic_fringe_minimum.isFinite,
              raw.chromatic_fringe_maximum.isFinite,
              raw.chromatic_fringe_default.isFinite,
              raw.chromatic_fringe_minimum <= raw.chromatic_fringe_default,
              raw.chromatic_fringe_default <= raw.chromatic_fringe_maximum
        else {
            throw SceneLibraryError.invalidDocument(
                "El contrato de modelos de simulación no está disponible."
            )
        }
        return .init(
            options: [
                .init(id: physical, label: String(cString: physicalLabel)),
                .init(id: vfx, label: String(cString: vfxLabel)),
            ],
            relativeLevelID: String(cString: levelID),
            relativeLevelLabel: String(cString: levelLabel),
            relativeLevelUnit: String(cString: levelUnit),
            relativeLevelRange: raw.relative_level_minimum ... raw.relative_level_maximum,
            relativeLevelDefault: raw.relative_level_default,
            emissionPresenceID: String(cString: emissionID),
            emissionPresenceLabel: String(cString: emissionLabel),
            emissionPresenceUnit: String(cString: emissionUnit),
            emissionPresenceRange:
                raw.emission_presence_minimum ... raw.emission_presence_maximum,
            emissionPresenceDefault: raw.emission_presence_default,
            chromaticFringeID: String(cString: fringeID),
            chromaticFringeLabel: String(cString: fringeLabel),
            chromaticFringeUnit: String(cString: fringeUnit),
            chromaticFringeRange:
                raw.chromatic_fringe_minimum ... raw.chromatic_fringe_maximum,
            chromaticFringeDefault: raw.chromatic_fringe_default
        )
    }
}

/// Model-specific authoring retained beside the complete physical authoring.
/// Standard Device, Camera, Lens, Sensor and Cover Glass identities and every
/// geometrical value remain scene-owned and shared; this record contains only
/// semantics unique to the parallel continuity evaluator.
struct VfxContinuityAuthoringState: Codable, Equatable, Sendable {
    var relativePanelLevel: Double
    var emissionPresence: Double
    var chromaticFringe: Double

    init(
        relativePanelLevel: Double = SceneSimulationModelPresentation.current.relativeLevelDefault,
        emissionPresence: Double = SceneSimulationModelPresentation.current.emissionPresenceDefault,
        chromaticFringe: Double = SceneSimulationModelPresentation.current.chromaticFringeDefault
    ) {
        self.relativePanelLevel = relativePanelLevel
        self.emissionPresence = emissionPresence
        self.chromaticFringe = chromaticFringe
    }

    func validate() throws {
        let descriptor = SceneSimulationModelPresentation.current
        guard relativePanelLevel.isFinite,
              descriptor.relativeLevelRange.contains(relativePanelLevel),
              emissionPresence.isFinite,
              descriptor.emissionPresenceRange.contains(emissionPresence),
              chromaticFringe.isFinite,
              descriptor.chromaticFringeRange.contains(chromaticFringe)
        else {
            throw SceneLibraryError.invalidDocument(
                "El estado de continuidad VFX no cumple su contrato vigente."
            )
        }
    }
}
