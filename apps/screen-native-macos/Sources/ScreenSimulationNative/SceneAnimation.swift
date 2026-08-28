import Foundation
import ScreenPhysicalBridge

enum SceneAnimationError: LocalizedError, Equatable {
    case invalidContract(String)

    var errorDescription: String? {
        switch self {
        case let .invalidContract(message): message
        }
    }
}

enum SceneAnimationInterpolation: String, Codable, CaseIterable, Sendable {
    case hold
    case linear
    case smooth

    var bridgeValue: UInt32 {
        switch self {
        case .hold: 0
        case .linear: 1
        case .smooth: 2
        }
    }

}

struct SceneAnimationPropertyPresentation: Equatable, Sendable {
    let propertyID: String
    let displayName: String
    let minimum: Double
    let maximum: Double
    let defaultValue: Double
    let defaultInterpolation: SceneAnimationInterpolation
    let interpolationLabels: [SceneAnimationInterpolation: String]

    var supportedInterpolations: [SceneAnimationInterpolation] {
        SceneAnimationInterpolation.allCases.filter { interpolationLabels[$0] != nil }
    }
}

struct SceneScalarKeyframe: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timeNumerator: Int64
    let timeDenominator: UInt64
    var value: Double
    var interpolation: SceneAnimationInterpolation

    init(
        id: UUID = UUID(), timeNumerator: Int64, timeDenominator: UInt64,
        value: Double, interpolation: SceneAnimationInterpolation
    ) {
        self.id = id
        self.timeNumerator = timeNumerator
        self.timeDenominator = timeDenominator
        self.value = value
        self.interpolation = interpolation
    }
}

struct SceneScalarAnimationTrack: Codable, Equatable, Identifiable, Sendable {
    static var simulationOpacityID: String {
        SimulationOpacityResolver.presentation.propertyID
    }

    let propertyID: String
    var keyframes: [SceneScalarKeyframe]
    var id: String { propertyID }

    static var defaultSimulationOpacity: Self {
        .init(
            propertyID: simulationOpacityID,
            keyframes: [.init(
                timeNumerator: 0, timeDenominator: 1,
                value: SimulationOpacityResolver.presentation.defaultValue,
                interpolation: .hold
            )]
        )
    }

    func validate() throws {
        guard propertyID == Self.simulationOpacityID,
              !keyframes.isEmpty,
              Set(keyframes.map(\.id)).count == keyframes.count else {
            throw SceneAnimationError.invalidContract(
                "La pista de opacidad contiene una identidad desconocida o duplicada."
            )
        }
        _ = try SimulationOpacityResolver.resolve(
            track: self,
            timeNumerator: keyframes[0].timeNumerator,
            timeDenominator: keyframes[0].timeDenominator
        )
    }

    func keyframeIndex(
        timeNumerator: Int64, timeDenominator: UInt64
    ) -> Int? {
        keyframes.firstIndex {
            Self.sameRational(
                $0.timeNumerator, $0.timeDenominator,
                timeNumerator, timeDenominator
            )
        }
    }

    private static func sameRational(
        _ leftNumerator: Int64, _ leftDenominator: UInt64,
        _ rightNumerator: Int64, _ rightDenominator: UInt64
    ) -> Bool {
        guard leftDenominator != 0, rightDenominator != 0 else { return false }
        let left = Decimal(leftNumerator) * Decimal(rightDenominator)
        let right = Decimal(rightNumerator) * Decimal(leftDenominator)
        return left == right
    }
}

struct SceneAnimationDocument: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.SceneAnimation.v1"
    let schema: String
    var scalarTracks: [SceneScalarAnimationTrack]

    init(scalarTracks: [SceneScalarAnimationTrack] = [.defaultSimulationOpacity]) {
        schema = Self.schema
        self.scalarTracks = scalarTracks
    }

    var simulationOpacityTrack: SceneScalarAnimationTrack {
        get {
            guard let track = scalarTracks.first(where: {
                $0.propertyID == SceneScalarAnimationTrack.simulationOpacityID
            }) else {
                preconditionFailure("SceneAnimation.v1 requires simulation-opacity")
            }
            return track
        }
        set {
            if let index = scalarTracks.firstIndex(where: {
                $0.propertyID == SceneScalarAnimationTrack.simulationOpacityID
            }) {
                scalarTracks[index] = newValue
            } else {
                scalarTracks.append(newValue)
            }
        }
    }

    func validate() throws {
        guard schema == Self.schema,
              Set(scalarTracks.map(\.propertyID)).count == scalarTracks.count,
              scalarTracks.count == 1,
              scalarTracks[0].propertyID == SceneScalarAnimationTrack.simulationOpacityID else {
            throw SceneAnimationError.invalidContract(
                "El documento de animación contiene propiedades desconocidas o duplicadas."
            )
        }
        try scalarTracks.forEach { try $0.validate() }
    }

    static func hasStrictShape(_ value: Any) -> Bool {
        guard let animation = value as? [String: Any],
              Set(animation.keys) == ["schema", "scalarTracks"],
              animation["schema"] as? String == schema,
              let tracks = animation["scalarTracks"] as? [[String: Any]] else { return false }
        return tracks.allSatisfy { track in
            Set(track.keys) == ["propertyID", "keyframes"]
                && (track["keyframes"] as? [[String: Any]])?.allSatisfy { keyframe in
                    Set(keyframe.keys) == [
                        "id", "timeNumerator", "timeDenominator", "value", "interpolation",
                    ]
                } == true
        }
    }
}

enum SimulationOpacityResolver {
    static let presentation: SceneAnimationPropertyPresentation = {
        var raw = ScreenApplicationScalarPropertyDescriptorV1()
        guard screen_application_simulation_opacity_descriptor_v1(&raw),
              let propertyID = raw.property_id,
              let displayName = raw.display_name,
              let holdLabel = raw.hold_label,
              let linearLabel = raw.linear_label,
              let smoothLabel = raw.smooth_label else {
            preconditionFailure("Application did not publish simulation-opacity")
        }
        let labels: [(SceneAnimationInterpolation, UnsafePointer<CChar>)] = [
            (.hold, holdLabel), (.linear, linearLabel), (.smooth, smoothLabel),
        ]
        var interpolationLabels: [SceneAnimationInterpolation: String] = [:]
        for (index, pair) in labels.enumerated()
            where raw.supported_interpolation_mask & (1 << UInt32(index)) != 0 {
            interpolationLabels[pair.0] = String(cString: pair.1)
        }
        guard let defaultInterpolation = SceneAnimationInterpolation.allCases.first(where: {
            $0.bridgeValue == raw.default_interpolation
        }), interpolationLabels[defaultInterpolation] != nil else {
            preconditionFailure("Application published an invalid default interpolation")
        }
        return .init(
            propertyID: String(cString: propertyID),
            displayName: String(cString: displayName),
            minimum: raw.minimum,
            maximum: raw.maximum,
            defaultValue: raw.default_value,
            defaultInterpolation: defaultInterpolation,
            interpolationLabels: interpolationLabels
        )
    }()

    static func resolve(
        track: SceneScalarAnimationTrack,
        timeNumerator: Int64,
        timeDenominator: UInt64
    ) throws -> Double {
        let raw = track.keyframes.map {
            ScreenApplicationScalarKeyframeV1(
                time_numerator: $0.timeNumerator,
                time_denominator: $0.timeDenominator,
                value: $0.value,
                interpolation: $0.interpolation.bridgeValue
            )
        }
        var output = 0.0
        var error: UnsafePointer<CChar>?
        let accepted = raw.withUnsafeBufferPointer { buffer in
            screen_application_resolve_simulation_opacity_v1(
                buffer.baseAddress, buffer.count,
                timeNumerator, timeDenominator, &output, &error
            )
        }
        guard accepted, output.isFinite, (0 ... 1).contains(output) else {
            throw SceneAnimationError.invalidContract(
                error.map { String(cString: $0) }
                    ?? "La pista de opacidad no se pudo resolver."
            )
        }
        return output
    }

    static func requiresPhysicalEvaluation(_ opacity: Double) -> Bool {
        opacity != 0
    }

    static func apply(_ opacity: Double, to rgba: inout [Float]) throws {
        guard opacity.isFinite, (0 ... 1).contains(opacity) else {
            throw SceneAnimationError.invalidContract("La opacidad resuelta no es válida.")
        }
        guard opacity != 1 else { return }
        let multiplier = Float(opacity)
        for index in rgba.indices { rgba[index] *= multiplier }
    }
}
