import Foundation
import ScreenPhysicalBridge
import StudioColor

enum DeviceCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case phone = "Phone"
    case laptop = "Laptop"
    case television = "Television"
    case desktopMonitor = "Desktop monitor"

    var id: String { rawValue }
}

enum DevicePanelTechnology: String, Codable, CaseIterable, Identifiable, Sendable {
    case ipsLCD = "IPS LCD"

    var id: String { rawValue }
}

enum DeviceEmissionModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case powerEOTF = "Power EOTF"

    var id: String { rawValue }
}

enum DeviceStripeLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case rgb = "RGB"
    case bgr = "BGR"

    var id: String { rawValue }
}

struct DeviceChromaticity: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

struct DeviceExactTime: Codable, Equatable, Sendable {
    var numerator: Int64
    var denominator: UInt32

    var seconds: Double {
        Double(numerator) / Double(denominator)
    }
}

struct DevicePanelLightSpread: Codable, Equatable, Sendable {
    var characterStrength: Double
    var coreRadiusMicrometers: [Double]
    var coreWeight: [Double]
    var tailRadiusMicrometers: [Double]
    var tailWeight: [Double]
}

struct DevicePanelUniformity: Codable, Equatable, Sendable {
    var characterStrength: Double
    var seed: UInt32
    var broadLuminancePeakToPeak: Double
    var midLuminancePeakToPeak: Double
    var fineLuminancePeakToPeak: Double
    var chromaticPeakToPeak: Double
    var midScaleMillimeters: Double
    var fineScaleMillimeters: Double
    var lowDriveEmphasis: Double
}

struct DeviceDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var category: DeviceCategory
    var nativeWidth: Int
    var nativeHeight: Int
    var activeWidthMeters: Double
    var activeHeightMeters: Double
    var panelTechnology: DevicePanelTechnology
    var emissionModel: DeviceEmissionModel
    var colorModeIDs: [String]
    var colorModeID: String
    var eotfGamma: Double
    var blackLevelNits: Double
    var minimumWhiteLuminance: Double
    var maximumWhiteLuminance: Double
    var whiteLuminanceStep: Double
    var whiteLevelNits: Double
    var whiteBasis: String
    var stripeLayout: DeviceStripeLayout
    var blackMatrixFraction: Double
    var red: DeviceChromaticity
    var green: DeviceChromaticity
    var blue: DeviceChromaticity
    var white: DeviceChromaticity
    var angularEmissionPower: [Double]
    var panelUniformity: DevicePanelUniformity
    var panelLightSpread: DevicePanelLightSpread
    var residualFlickerPeriod: DeviceExactTime
    var residualFlickerAmplitude: Double
    var residualFlickerPhase: DeviceExactTime
    var bandingPeriod: DeviceExactTime
    var bandingOnDuration: DeviceExactTime
    var bandingPhase: DeviceExactTime
    var bandingAmount: Double
    var defaultCoverGlassPresetID: String

    var diagonalInches: Double {
        hypot(activeWidthMeters, activeHeightMeters) / 0.0254
    }

    var pixelsPerInch: Double {
        hypot(Double(nativeWidth), Double(nativeHeight)) / diagonalInches
    }

    var pixelPitchMicrometers: Double {
        activeWidthMeters / Double(nativeWidth) * 1_000_000
    }

    func resolved() throws -> ResolvedDevice {
        try validateTextContract()
        let parameters = try bridgeParameters()
        var error: UnsafePointer<CChar>?
        guard let profile = withUnsafePointer(to: parameters, {
            screen_device_profile_create($0, &error)
        }) else {
            throw DeviceDomainError.invalidPhysicalProfile(
                error.map(String.init(cString:))
                    ?? "El motor Rust rechazó el perfil físico."
            )
        }
        screen_device_profile_release(profile)
        return ResolvedDevice(definition: self, parameters: parameters)
    }

    private func validateTextContract() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceDomainError.invalidIdentity
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceDomainError.invalidName
        }
        guard !whiteBasis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceDomainError.invalidWhiteBasis
        }
        guard !colorModeIDs.isEmpty,
              Set(colorModeIDs).count == colorModeIDs.count,
              colorModeIDs.allSatisfy({ id in
                  StudioColorMode.catalog.contains(where: { $0.id == id })
              }),
              colorModeIDs.contains(colorModeID)
        else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "Los Color Modes del Device son desconocidos, están duplicados o no incluyen el modo seleccionado."
            )
        }
        guard !defaultCoverGlassPresetID.isEmpty else {
            throw DeviceDomainError.invalidCoverAssociation
        }
        guard minimumWhiteLuminance.isFinite,
              maximumWhiteLuminance.isFinite,
              whiteLuminanceStep.isFinite,
              minimumWhiteLuminance > 0,
              minimumWhiteLuminance <= whiteLevelNits,
              whiteLevelNits <= maximumWhiteLuminance,
              whiteLuminanceStep > 0
        else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "La capacidad White Luminance del Device es inválida."
            )
        }
        guard angularEmissionPower.count == 3,
              panelLightSpread.coreRadiusMicrometers.count == 3,
              panelLightSpread.coreWeight.count == 3,
              panelLightSpread.tailRadiusMicrometers.count == 3,
              panelLightSpread.tailWeight.count == 3
        else {
            throw DeviceDomainError.invalidAngularResponse
        }
    }

    fileprivate func bridgeParameters() throws -> ScreenDeviceParametersV3 {
        guard nativeWidth <= Int(UInt32.max), nativeHeight <= Int(UInt32.max) else {
            throw DeviceDomainError.invalidPhysicalProfile("La resolución nativa excede el ABI.")
        }
        guard angularEmissionPower.count == 3 else {
            throw DeviceDomainError.invalidAngularResponse
        }
        var value = ScreenDeviceParametersV3()
        value.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        value.native_width = UInt32(clamping: nativeWidth)
        value.native_height = UInt32(clamping: nativeHeight)
        value.panel_technology = 0
        value.stripe_layout = stripeLayout == .rgb ? 0 : 1
        value.active_width_meters = Float(activeWidthMeters)
        value.active_height_meters = Float(activeHeightMeters)
        value.black_matrix_fraction = Float(blackMatrixFraction)
        value.eotf_gamma = Float(eotfGamma)
        value.black_level_nits = Float(blackLevelNits)
        value.white_level_nits = Float(whiteLevelNits)
        value.primary_xy = (
            Float(red.x), Float(red.y),
            Float(green.x), Float(green.y),
            Float(blue.x), Float(blue.y)
        )
        value.white_xy = (Float(white.x), Float(white.y))
        value.angular_emission_power = (
            Float(angularEmissionPower[0]),
            Float(angularEmissionPower[1]),
            Float(angularEmissionPower[2])
        )
        value.uniformity_character_strength = Float(panelUniformity.characterStrength)
        value.uniformity_seed = panelUniformity.seed
        value.uniformity_broad_luminance_peak_to_peak = Float(
            panelUniformity.broadLuminancePeakToPeak
        )
        value.uniformity_mid_luminance_peak_to_peak = Float(
            panelUniformity.midLuminancePeakToPeak
        )
        value.uniformity_fine_luminance_peak_to_peak = Float(
            panelUniformity.fineLuminancePeakToPeak
        )
        value.uniformity_chromatic_peak_to_peak = Float(
            panelUniformity.chromaticPeakToPeak
        )
        value.uniformity_mid_scale_millimeters = Float(panelUniformity.midScaleMillimeters)
        value.uniformity_fine_scale_millimeters = Float(panelUniformity.fineScaleMillimeters)
        value.uniformity_low_drive_emphasis = Float(panelUniformity.lowDriveEmphasis)
        value.light_spread_character_strength = Float(panelLightSpread.characterStrength)
        value.light_spread_core_radius_micrometers = (
            Float(panelLightSpread.coreRadiusMicrometers[0]),
            Float(panelLightSpread.coreRadiusMicrometers[1]),
            Float(panelLightSpread.coreRadiusMicrometers[2])
        )
        value.light_spread_core_weight = (
            Float(panelLightSpread.coreWeight[0]),
            Float(panelLightSpread.coreWeight[1]),
            Float(panelLightSpread.coreWeight[2])
        )
        value.light_spread_tail_radius_micrometers = (
            Float(panelLightSpread.tailRadiusMicrometers[0]),
            Float(panelLightSpread.tailRadiusMicrometers[1]),
            Float(panelLightSpread.tailRadiusMicrometers[2])
        )
        value.light_spread_tail_weight = (
            Float(panelLightSpread.tailWeight[0]),
            Float(panelLightSpread.tailWeight[1]),
            Float(panelLightSpread.tailWeight[2])
        )
        value.residual_period_numerator = residualFlickerPeriod.numerator
        value.residual_period_denominator = residualFlickerPeriod.denominator
        value.residual_amplitude = Float(residualFlickerAmplitude)
        value.residual_phase_numerator = residualFlickerPhase.numerator
        value.residual_phase_denominator = residualFlickerPhase.denominator
        value.banding_period_numerator = bandingPeriod.numerator
        value.banding_period_denominator = bandingPeriod.denominator
        value.banding_on_numerator = bandingOnDuration.numerator
        value.banding_on_denominator = bandingOnDuration.denominator
        value.banding_phase_numerator = bandingPhase.numerator
        value.banding_phase_denominator = bandingPhase.denominator
        value.banding_amount = Float(bandingAmount)
        return value
    }
}

struct ResolvedDevice: @unchecked Sendable {
    let definition: DeviceDefinition
    let parameters: ScreenDeviceParametersV3

    var id: String { definition.id }

}

enum RustDeviceCatalog {
    static func builtIns() throws -> [DeviceDefinition] {
        try (0..<screen_device_preset_count()).map { index in
            var parameters = ScreenDeviceParametersV3()
            guard screen_device_preset_parameters(index, &parameters) else {
                throw DeviceDomainError.invalidCatalog(index)
            }
            let categoryText = string(screen_device_preset_category(index))
            guard let category = DeviceCategory(rawValue: categoryText) else {
                throw DeviceDomainError.invalidCatalog(index)
            }
            let definition = DeviceDefinition(
                id: string(screen_device_preset_id(index)),
                name: string(screen_device_preset_label(index)),
                category: category,
                nativeWidth: Int(parameters.native_width),
                nativeHeight: Int(parameters.native_height),
                activeWidthMeters: Double(parameters.active_width_meters),
                activeHeightMeters: Double(parameters.active_height_meters),
                panelTechnology: .ipsLCD,
                emissionModel: .powerEOTF,
                colorModeIDs: (0..<screen_device_preset_color_mode_count(index)).map {
                    string(screen_device_preset_color_mode_id(index, $0))
                },
                colorModeID: string(screen_device_preset_default_color_mode_id(index)),
                eotfGamma: Double(parameters.eotf_gamma),
                blackLevelNits: Double(parameters.black_level_nits),
                minimumWhiteLuminance: Double(
                    screen_device_preset_minimum_white_nits(index)
                ),
                maximumWhiteLuminance: Double(
                    screen_device_preset_maximum_white_nits(index)
                ),
                whiteLuminanceStep: Double(screen_device_preset_white_step_nits(index)),
                whiteLevelNits: Double(parameters.white_level_nits),
                whiteBasis: string(screen_device_preset_white_basis(index)),
                stripeLayout: parameters.stripe_layout == 0 ? .rgb : .bgr,
                blackMatrixFraction: Double(parameters.black_matrix_fraction),
                red: .init(
                    x: Double(parameters.primary_xy.0),
                    y: Double(parameters.primary_xy.1)
                ),
                green: .init(
                    x: Double(parameters.primary_xy.2),
                    y: Double(parameters.primary_xy.3)
                ),
                blue: .init(
                    x: Double(parameters.primary_xy.4),
                    y: Double(parameters.primary_xy.5)
                ),
                white: .init(
                    x: Double(parameters.white_xy.0),
                    y: Double(parameters.white_xy.1)
                ),
                angularEmissionPower: [
                    Double(parameters.angular_emission_power.0),
                    Double(parameters.angular_emission_power.1),
                    Double(parameters.angular_emission_power.2),
                ],
                panelUniformity: .init(
                    characterStrength: Double(parameters.uniformity_character_strength),
                    seed: parameters.uniformity_seed,
                    broadLuminancePeakToPeak: Double(
                        parameters.uniformity_broad_luminance_peak_to_peak
                    ),
                    midLuminancePeakToPeak: Double(
                        parameters.uniformity_mid_luminance_peak_to_peak
                    ),
                    fineLuminancePeakToPeak: Double(
                        parameters.uniformity_fine_luminance_peak_to_peak
                    ),
                    chromaticPeakToPeak: Double(parameters.uniformity_chromatic_peak_to_peak),
                    midScaleMillimeters: Double(parameters.uniformity_mid_scale_millimeters),
                    fineScaleMillimeters: Double(parameters.uniformity_fine_scale_millimeters),
                    lowDriveEmphasis: Double(parameters.uniformity_low_drive_emphasis)
                ),
                panelLightSpread: .init(
                    characterStrength: Double(parameters.light_spread_character_strength),
                    coreRadiusMicrometers: [
                        Double(parameters.light_spread_core_radius_micrometers.0),
                        Double(parameters.light_spread_core_radius_micrometers.1),
                        Double(parameters.light_spread_core_radius_micrometers.2),
                    ],
                    coreWeight: [
                        Double(parameters.light_spread_core_weight.0),
                        Double(parameters.light_spread_core_weight.1),
                        Double(parameters.light_spread_core_weight.2),
                    ],
                    tailRadiusMicrometers: [
                        Double(parameters.light_spread_tail_radius_micrometers.0),
                        Double(parameters.light_spread_tail_radius_micrometers.1),
                        Double(parameters.light_spread_tail_radius_micrometers.2),
                    ],
                    tailWeight: [
                        Double(parameters.light_spread_tail_weight.0),
                        Double(parameters.light_spread_tail_weight.1),
                        Double(parameters.light_spread_tail_weight.2),
                    ]
                ),
                residualFlickerPeriod: .init(
                    numerator: parameters.residual_period_numerator,
                    denominator: parameters.residual_period_denominator
                ),
                residualFlickerAmplitude: Double(parameters.residual_amplitude),
                residualFlickerPhase: .init(
                    numerator: parameters.residual_phase_numerator,
                    denominator: parameters.residual_phase_denominator
                ),
                bandingPeriod: .init(
                    numerator: parameters.banding_period_numerator,
                    denominator: parameters.banding_period_denominator
                ),
                bandingOnDuration: .init(
                    numerator: parameters.banding_on_numerator,
                    denominator: parameters.banding_on_denominator
                ),
                bandingPhase: .init(
                    numerator: parameters.banding_phase_numerator,
                    denominator: parameters.banding_phase_denominator
                ),
                bandingAmount: Double(parameters.banding_amount),
                defaultCoverGlassPresetID: string(
                    screen_device_preset_default_cover_id(index)
                )
            )
            _ = try definition.resolved()
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

enum DeviceDomainError: Error, LocalizedError {
    case invalidIdentity
    case invalidName
    case invalidWhiteBasis
    case invalidCoverAssociation
    case invalidAngularResponse
    case invalidPhysicalProfile(String)
    case invalidCatalog(Int)

    var errorDescription: String? {
        switch self {
        case .invalidIdentity: "El device necesita una identidad estable."
        case .invalidName: "El device necesita nombre."
        case .invalidWhiteBasis: "El device debe declarar la base de su blanco."
        case .invalidCoverAssociation: "El device necesita una asociación explícita de cover glass."
        case .invalidAngularResponse: "La respuesta angular debe tener tres canales."
        case let .invalidPhysicalProfile(message): message
        case let .invalidCatalog(index):
            "El preset Rust de device en el índice \(index) no cumple el contrato vigente."
        }
    }
}
