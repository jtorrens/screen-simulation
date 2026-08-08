import Foundation
import ScreenPhysicalBridge

struct EnvironmentPresetDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let parameters: ScreenEnvironmentParametersV2

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    static func catalog() throws -> [Self] {
        try (0..<screen_environment_preset_count()).map { index in
            var parameters = ScreenEnvironmentParametersV2()
            guard screen_environment_preset_parameters(index, &parameters),
                  parameters.abi_version == SCREEN_PHYSICAL_FRAME_ABI_VERSION
            else { throw EnvironmentPresetError.invalidCatalog(index) }
            return Self(
                id: text(screen_environment_preset_id(index)),
                name: text(screen_environment_preset_label(index)),
                parameters: parameters
            )
        }
    }

    func apply(to state: inout PhysicalPipelineAuthoringState) {
        state.environment.ambientRadianceACEScg = tuple3(parameters.ambient_radiance_acescg)
        state.environment.keyRadianceACEScg = tuple3(parameters.key_radiance_acescg)
        state.environment.keyDirectionLocal = tuple3(parameters.key_direction_local)
        state.environment.keyAngularRadiusDegrees = Double(
            parameters.key_angular_radius_degrees
        )
        state.environment.rotationDegrees = Double(parameters.rotation_degrees)
        state.environment.pattern = parameters.pattern
    }

    private func tuple3(_ value: (Float, Float, Float)) -> [Double] {
        [Double(value.0), Double(value.1), Double(value.2)]
    }

    private static func text(_ view: ScreenUTF8View) -> String {
        guard let bytes = view.bytes, view.count > 0 else { return "" }
        return String(
            decoding: UnsafeBufferPointer(start: bytes, count: view.count),
            as: UTF8.self
        )
    }
}

enum EnvironmentPresetError: Error {
    case invalidCatalog(Int)
}
