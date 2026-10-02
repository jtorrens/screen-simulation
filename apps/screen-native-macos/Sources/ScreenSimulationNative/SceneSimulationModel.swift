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

    static let current = try! load()

    static func load() throws -> Self {
        var raw = ScreenSimulationModelAuthoringDescriptorV1()
        guard screen_application_simulation_model_descriptor_v1(&raw),
              let physicalID = raw.physical_id,
              let physicalLabel = raw.physical_label,
              let vfxID = raw.vfx_continuity_id,
              let vfxLabel = raw.vfx_continuity_label,
              let levelID = raw.relative_level_id,
              let levelLabel = raw.relative_level_label,
              let levelUnit = raw.relative_level_unit,
              let physical = SceneSimulationModel(rawValue: String(cString: physicalID)),
              let vfx = SceneSimulationModel(rawValue: String(cString: vfxID)),
              physical == .physical,
              vfx == .vfxContinuity,
              raw.relative_level_minimum.isFinite,
              raw.relative_level_maximum.isFinite,
              raw.relative_level_default.isFinite,
              raw.relative_level_minimum <= raw.relative_level_default,
              raw.relative_level_default <= raw.relative_level_maximum
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
            relativeLevelDefault: raw.relative_level_default
        )
    }
}

/// Model-specific authoring retained beside the complete physical authoring.
/// Standard Device, Camera, Lens, Sensor and Cover Glass identities and every
/// geometrical value remain scene-owned and shared; this record contains only
/// semantics unique to the parallel continuity evaluator.
struct VfxContinuityAuthoringState: Codable, Equatable, Sendable {
    var relativePanelLevel: Double

    init(
        relativePanelLevel: Double = SceneSimulationModelPresentation.current.relativeLevelDefault
    ) {
        self.relativePanelLevel = relativePanelLevel
    }

    func validate() throws {
        let descriptor = SceneSimulationModelPresentation.current
        guard relativePanelLevel.isFinite,
              descriptor.relativeLevelRange.contains(relativePanelLevel)
        else {
            throw SceneLibraryError.invalidDocument(
                "El estado de continuidad VFX no cumple su contrato vigente."
            )
        }
    }
}
