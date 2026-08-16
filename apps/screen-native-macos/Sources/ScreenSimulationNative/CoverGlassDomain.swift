import Foundation
import ScreenPhysicalBridge

enum CoverGlassAuthority: String, Codable, CaseIterable, Identifiable, Sendable {
    case genericApproximation = "Aproximación genérica"
    case publishedCategoryApproximation = "Aproximación de categoría publicada"

    var id: String { rawValue }
}

struct CoverGlassDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var authority: CoverGlassAuthority
    var characterStrength: Double
    var thicknessMillimeters: Double
    var refractiveIndex: Double
    var antiReflectiveEfficiency: Double
    var absorptionPerMillimeter: [Double]
    var roughness: Double
    var haze: Double
    var agMicrotextureCharacterStrength: Double
    var agMicrotextureRMSSlope: Double
    var agMicrotextureCorrelationLengthMicrometers: Double
    var agMicrotextureAnisotropy: Double
    var agMicrotextureSeed: UInt32
    var glowCharacterStrength: Double
    var glowScatterFraction: Double
    var glowCoreRadiusMillimeters: Double
    var glowTailRadiusMillimeters: Double
    var glowTailFraction: Double
    var glowThresholdRelativeWhite: Double

    func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoverGlassDomainError.invalidIdentity
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoverGlassDomainError.invalidName
        }
        guard absorptionPerMillimeter.count == 3 else {
            throw CoverGlassDomainError.invalidAbsorption
        }
        let parameters = try bridgeParameters()
        var error: UnsafePointer<CChar>?
        guard let profile = withUnsafePointer(to: parameters, {
            screen_cover_glass_profile_create($0, &error)
        }) else {
            throw CoverGlassDomainError.invalidPhysicalProfile(
                error.map(String.init(cString:))
                    ?? "El motor Rust rechazó el perfil de Cover Glass."
            )
        }
        screen_cover_glass_profile_release(profile)
    }

    func bridgeParameters() throws -> ScreenCoverGlassParametersV2 {
        guard absorptionPerMillimeter.count == 3 else {
            throw CoverGlassDomainError.invalidAbsorption
        }
        var parameters = ScreenCoverGlassParametersV2()
        parameters.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        parameters.authority = authority == .genericApproximation ? 0 : 1
        parameters.character_strength = Float(characterStrength)
        parameters.thickness_millimeters = Float(thicknessMillimeters)
        parameters.refractive_index = Float(refractiveIndex)
        parameters.anti_reflective_efficiency = Float(antiReflectiveEfficiency)
        parameters.absorption_per_millimeter = (
            Float(absorptionPerMillimeter[0]),
            Float(absorptionPerMillimeter[1]),
            Float(absorptionPerMillimeter[2])
        )
        parameters.roughness = Float(roughness)
        parameters.haze = Float(haze)
        parameters.ag_microtexture_character_strength = Float(agMicrotextureCharacterStrength)
        parameters.ag_microtexture_rms_slope = Float(agMicrotextureRMSSlope)
        parameters.ag_microtexture_correlation_length_micrometers = Float(
            agMicrotextureCorrelationLengthMicrometers
        )
        parameters.ag_microtexture_anisotropy = Float(agMicrotextureAnisotropy)
        parameters.ag_microtexture_seed = agMicrotextureSeed
        parameters.glow_character_strength = Float(glowCharacterStrength)
        parameters.glow_scatter_fraction = Float(glowScatterFraction)
        parameters.glow_core_radius_millimeters = Float(glowCoreRadiusMillimeters)
        parameters.glow_tail_radius_millimeters = Float(glowTailRadiusMillimeters)
        parameters.glow_tail_fraction = Float(glowTailFraction)
        parameters.glow_threshold_relative_white = Float(glowThresholdRelativeWhite)
        return parameters
    }
}

enum RustCoverGlassCatalog {
    static func builtIns() throws -> [CoverGlassDefinition] {
        try (0..<screen_cover_glass_preset_count()).map { index in
            var parameters = ScreenCoverGlassParametersV2()
            guard screen_cover_glass_preset_parameters(index, &parameters),
                  parameters.abi_version == SCREEN_PHYSICAL_FRAME_ABI_VERSION,
                  let authority = parameters.authority == 0
                    ? CoverGlassAuthority.genericApproximation
                    : parameters.authority == 1
                        ? .publishedCategoryApproximation : nil
            else { throw CoverGlassDomainError.invalidCatalog(index) }
            let definition = CoverGlassDefinition(
                id: string(screen_cover_glass_preset_id(index)),
                name: string(screen_cover_glass_preset_label(index)),
                authority: authority,
                characterStrength: Double(parameters.character_strength),
                thicknessMillimeters: Double(parameters.thickness_millimeters),
                refractiveIndex: Double(parameters.refractive_index),
                antiReflectiveEfficiency: Double(parameters.anti_reflective_efficiency),
                absorptionPerMillimeter: [
                    Double(parameters.absorption_per_millimeter.0),
                    Double(parameters.absorption_per_millimeter.1),
                    Double(parameters.absorption_per_millimeter.2),
                ],
                roughness: Double(parameters.roughness),
                haze: Double(parameters.haze),
                agMicrotextureCharacterStrength: Double(
                    parameters.ag_microtexture_character_strength
                ),
                agMicrotextureRMSSlope: Double(parameters.ag_microtexture_rms_slope),
                agMicrotextureCorrelationLengthMicrometers: Double(
                    parameters.ag_microtexture_correlation_length_micrometers
                ),
                agMicrotextureAnisotropy: Double(parameters.ag_microtexture_anisotropy),
                agMicrotextureSeed: parameters.ag_microtexture_seed,
                glowCharacterStrength: Double(parameters.glow_character_strength),
                glowScatterFraction: Double(parameters.glow_scatter_fraction),
                glowCoreRadiusMillimeters: Double(parameters.glow_core_radius_millimeters),
                glowTailRadiusMillimeters: Double(parameters.glow_tail_radius_millimeters),
                glowTailFraction: Double(parameters.glow_tail_fraction),
                glowThresholdRelativeWhite: Double(parameters.glow_threshold_relative_white)
            )
            try definition.validate()
            return definition
        }
    }

    private static func string(_ view: ScreenUTF8View) -> String {
        guard let bytes = view.bytes, view.count > 0 else { return "" }
        return String(
            decoding: UnsafeBufferPointer(start: bytes, count: view.count),
            as: UTF8.self
        )
    }
}

enum CoverGlassDomainError: Error, LocalizedError {
    case invalidIdentity
    case invalidName
    case invalidAbsorption
    case invalidPhysicalProfile(String)
    case invalidCatalog(Int)

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: "Cover Glass necesita una identidad estable."
        case .invalidName: "Cover Glass necesita nombre."
        case .invalidAbsorption: "La absorción de Cover Glass debe declarar RGB."
        case let .invalidPhysicalProfile(message): message
        case let .invalidCatalog(index):
            "El preset Rust de Cover Glass en el índice \(index) no cumple el contrato."
        }
    }
}
