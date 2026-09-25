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
    var timeNumerator: Int64
    var timeDenominator: UInt64
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

struct SceneScalarKeyframePresentation: Equatable, Identifiable, Sendable {
    let id: UUID
    let frame: Int
    let interpolation: SceneAnimationInterpolation
}

enum SceneTransformAnimationID: String, Codable, CaseIterable, Sendable {
    case deviceGeometry = "device-geometry"
    case cameraGeometry = "camera-geometry"

    var displayName: String {
        switch self {
        case .deviceGeometry: "Geometría Device"
        case .cameraGeometry: "Geometría Camera"
        }
    }
}

struct SceneTransformKeyframe: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var timeNumerator: Int64
    var timeDenominator: UInt64
    var position: [Double]
    var quaternion: [Double]
    var interpolation: SceneAnimationInterpolation

    init(
        id: UUID = UUID(), timeNumerator: Int64, timeDenominator: UInt64,
        position: [Double], quaternion: [Double],
        interpolation: SceneAnimationInterpolation = .smooth
    ) {
        self.id = id
        self.timeNumerator = timeNumerator
        self.timeDenominator = timeDenominator
        self.position = position
        self.quaternion = quaternion
        self.interpolation = interpolation
    }

    /// Authoring crosses a Float ABI before returning to the workstation. Re-normalize that
    /// resolved canonical rotation once when materializing a key; persisted decoding remains
    /// strict and never repairs malformed authored data.
    static func authored(
        id: UUID = UUID(), timeNumerator: Int64, timeDenominator: UInt64,
        position: [Double], quaternion: [Double],
        interpolation: SceneAnimationInterpolation = .smooth
    ) throws -> Self {
        guard position.count == 3, quaternion.count == 4,
              position.allSatisfy(\.isFinite), quaternion.allSatisfy(\.isFinite)
        else {
            throw SceneAnimationError.invalidContract(
                "La pose resuelta para el keyframe no es válida."
            )
        }
        let magnitude = quaternion.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard magnitude.isFinite, magnitude > 1e-12 else {
            throw SceneAnimationError.invalidContract(
                "La rotación resuelta para el keyframe no es válida."
            )
        }
        return .init(
            id: id,
            timeNumerator: timeNumerator,
            timeDenominator: timeDenominator,
            position: position,
            quaternion: quaternion.map { $0 / magnitude },
            interpolation: interpolation
        )
    }
}

struct SceneTransformAnimationTrack: Codable, Equatable, Identifiable, Sendable {
    let trackID: SceneTransformAnimationID
    var keyframes: [SceneTransformKeyframe]
    var id: SceneTransformAnimationID { trackID }

    func validate() throws {
        guard !keyframes.isEmpty,
              Set(keyframes.map(\.id)).count == keyframes.count else {
            throw SceneAnimationError.invalidContract(
                "La pista de \(trackID.displayName) no contiene keys válidos."
            )
        }
        var prior: (Int64, UInt64)?
        for keyframe in keyframes {
            guard keyframe.timeDenominator > 0,
                  keyframe.timeDenominator <= UInt64(UInt32.max),
                  keyframe.position.count == 3,
                  keyframe.quaternion.count == 4,
                  keyframe.position.allSatisfy(\.isFinite),
                  keyframe.quaternion.allSatisfy(\.isFinite) else {
                throw SceneAnimationError.invalidContract(
                    "La pista de \(trackID.displayName) contiene una pose inválida."
                )
            }
            let magnitude = keyframe.quaternion.reduce(0) { $0 + $1 * $1 }
            guard abs(magnitude - 1) < 1e-8 else {
                throw SceneAnimationError.invalidContract(
                    "La rotación de \(trackID.displayName) no está normalizada."
                )
            }
            if let prior {
                let left = Decimal(prior.0) * Decimal(keyframe.timeDenominator)
                let right = Decimal(keyframe.timeNumerator) * Decimal(prior.1)
                guard left < right else {
                    throw SceneAnimationError.invalidContract(
                        "Los keys de \(trackID.displayName) no están ordenados."
                    )
                }
            }
            prior = (keyframe.timeNumerator, keyframe.timeDenominator)
        }
    }

    func keyframeIndex(timeNumerator: Int64, timeDenominator: UInt64) -> Int? {
        keyframes.firstIndex {
            Decimal($0.timeNumerator) * Decimal(timeDenominator)
                == Decimal(timeNumerator) * Decimal($0.timeDenominator)
        }
    }

    func movingKeyframe(id: UUID, timeNumerator: Int64, timeDenominator: UInt64) throws -> Self {
        guard timeDenominator > 0 else {
            throw SceneAnimationError.invalidContract("El tiempo de destino no es válido.")
        }
        var moved = self
        guard let source = moved.keyframes.firstIndex(where: { $0.id == id }) else {
            throw SceneAnimationError.invalidContract("El key de geometría ya no existe.")
        }
        if let occupied = moved.keyframeIndex(
            timeNumerator: timeNumerator, timeDenominator: timeDenominator
        ), occupied != source {
            throw SceneAnimationError.invalidContract("El frame de destino ya contiene un key.")
        }
        moved.keyframes[source].timeNumerator = timeNumerator
        moved.keyframes[source].timeDenominator = timeDenominator
        moved.keyframes.sort {
            Decimal($0.timeNumerator) * Decimal($1.timeDenominator)
                < Decimal($1.timeNumerator) * Decimal($0.timeDenominator)
        }
        try moved.validate()
        return moved
    }
}

enum SceneAnimationKeyframeShape: Equatable, Sendable {
    case square
    case diamond
    case circle

    init(interpolation: SceneAnimationInterpolation) {
        self = switch interpolation {
        case .hold: .square
        case .linear: .diamond
        case .smooth: .circle
        }
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

    func movingKeyframe(
        id: UUID,
        timeNumerator: Int64,
        timeDenominator: UInt64
    ) throws -> Self {
        guard timeDenominator != 0 else {
            throw SceneAnimationError.invalidContract(
                "El tiempo exacto de destino del keyframe no es válido."
            )
        }
        var moved = self
        guard let sourceIndex = moved.keyframes.firstIndex(where: { $0.id == id }) else {
            throw SceneAnimationError.invalidContract("El keyframe arrastrado ya no existe.")
        }
        if let occupied = moved.keyframeIndex(
            timeNumerator: timeNumerator,
            timeDenominator: timeDenominator
        ), occupied != sourceIndex {
            throw SceneAnimationError.invalidContract(
                "El tiempo de destino ya contiene otro keyframe."
            )
        }
        moved.keyframes[sourceIndex].timeNumerator = timeNumerator
        moved.keyframes[sourceIndex].timeDenominator = timeDenominator
        moved.keyframes.sort {
            Decimal($0.timeNumerator) * Decimal($1.timeDenominator)
                < Decimal($1.timeNumerator) * Decimal($0.timeDenominator)
        }
        try moved.validate()
        return moved
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
    static let schema = "ScreenSimulation.SceneAnimation.v2"
    let schema: String
    var scalarTracks: [SceneScalarAnimationTrack]
    var transformTracks: [SceneTransformAnimationTrack]

    init(
        scalarTracks: [SceneScalarAnimationTrack] = [.defaultSimulationOpacity],
        transformTracks: [SceneTransformAnimationTrack] = []
    ) {
        schema = Self.schema
        self.scalarTracks = scalarTracks
        self.transformTracks = transformTracks
    }

    func transformTrack(_ id: SceneTransformAnimationID) -> SceneTransformAnimationTrack? {
        transformTracks.first { $0.trackID == id }
    }

    mutating func setTransformTrack(_ track: SceneTransformAnimationTrack?) {
        guard let track else { return }
        if let index = transformTracks.firstIndex(where: { $0.trackID == track.trackID }) {
            transformTracks[index] = track
        } else {
            transformTracks.append(track)
            transformTracks.sort { $0.trackID.rawValue < $1.trackID.rawValue }
        }
    }

    mutating func removeTransformTrack(_ id: SceneTransformAnimationID) {
        transformTracks.removeAll { $0.trackID == id }
    }

    var simulationOpacityTrack: SceneScalarAnimationTrack {
        get {
            guard let track = scalarTracks.first(where: {
                $0.propertyID == SceneScalarAnimationTrack.simulationOpacityID
            }) else {
                preconditionFailure("SceneAnimation.v2 requires simulation-opacity")
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
              scalarTracks[0].propertyID == SceneScalarAnimationTrack.simulationOpacityID,
              Set(transformTracks.map(\.trackID)).count == transformTracks.count else {
            throw SceneAnimationError.invalidContract(
                "El documento de animación contiene propiedades desconocidas o duplicadas."
            )
        }
        try scalarTracks.forEach { try $0.validate() }
        try transformTracks.forEach { try $0.validate() }
    }

    static func hasStrictShape(_ value: Any) -> Bool {
        guard let animation = value as? [String: Any],
              Set(animation.keys) == ["schema", "scalarTracks", "transformTracks"],
              animation["schema"] as? String == schema,
              let tracks = animation["scalarTracks"] as? [[String: Any]],
              let transformTracks = animation["transformTracks"] as? [[String: Any]]
        else { return false }
        return tracks.allSatisfy { track in
            Set(track.keys) == ["propertyID", "keyframes"]
                && (track["keyframes"] as? [[String: Any]])?.allSatisfy { keyframe in
                    Set(keyframe.keys) == [
                        "id", "timeNumerator", "timeDenominator", "value", "interpolation",
                    ]
                } == true
        } && transformTracks.allSatisfy { track in
            Set(track.keys) == ["trackID", "keyframes"]
                && (track["keyframes"] as? [[String: Any]])?.allSatisfy { keyframe in
                    Set(keyframe.keys) == [
                        "id", "timeNumerator", "timeDenominator", "position",
                        "quaternion", "interpolation",
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
