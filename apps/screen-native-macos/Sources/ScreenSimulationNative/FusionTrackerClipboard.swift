import Foundation
import simd

enum TrackingSceneMethod: String, CaseIterable, Identifiable, Sendable {
    case fusionComposition
    case deviceCorners
    case fusionTrackerClipboard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fusionComposition: "Fusion / SynthEyes"
        case .deviceCorners: "Esquinas del Device"
        case .fusionTrackerClipboard: "Tracker copiado de Fusion"
        }
    }
}

enum FusionTrackerTarget: String, CaseIterable, Identifiable, Codable, Sendable {
    case camera
    case device

    var id: String { rawValue }
    var label: String { self == .camera ? "Cámara" : "Device" }
}

enum FusionTrackerCorner: String, CaseIterable, Identifiable, Codable, Sendable {
    case unassigned
    case topLeft
    case topRight
    case bottomRight
    case bottomLeft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unassigned: "Sin asignar"
        case .topLeft: "TL"
        case .topRight: "TR"
        case .bottomRight: "BR"
        case .bottomLeft: "BL"
        }
    }
}

enum FusionTrackerClipboardError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message): "El Tracker de Fusion no es válido: \(message)."
        }
    }
}

struct FusionTrackerSample: Codable, Equatable, Sendable {
    let frame: Int
    let position: SIMD2<Double>
}

struct FusionTrackerPointCurve: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let label: String
    let samples: [FusionTrackerSample]
}

struct FusionTrackerPoseSample: Codable, Equatable, Sendable {
    let frame: Int
    let position: SIMD3<Double>
    let orientation: SIMD4<Double>
}

struct FusionTrackerPoseTrack: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.FusionTrackerPoseTrack.v1"

    let schema: String
    let target: FusionTrackerTarget
    let anchorFrame: Int
    let frameRateNumerator: UInt32
    let frameRateDenominator: UInt32
    let samples: [FusionTrackerPoseSample]

    init(
        target: FusionTrackerTarget,
        anchorFrame: Int,
        frameRateNumerator: UInt32,
        frameRateDenominator: UInt32,
        samples: [FusionTrackerPoseSample]
    ) throws {
        schema = Self.schema
        self.target = target
        self.anchorFrame = anchorFrame
        self.frameRateNumerator = frameRateNumerator
        self.frameRateDenominator = frameRateDenominator
        self.samples = samples
        try validate()
    }

    func validate() throws {
        guard schema == Self.schema, frameRateNumerator > 0, frameRateDenominator > 0,
              !samples.isEmpty, samples.map(\.frame) == samples.map(\.frame).sorted(),
              Set(samples.map(\.frame)).count == samples.count,
              samples.allSatisfy({ sample in
                  sample.position.x.isFinite && sample.position.y.isFinite
                    && sample.position.z.isFinite && sample.orientation.x.isFinite
                    && sample.orientation.y.isFinite && sample.orientation.z.isFinite
                    && sample.orientation.w.isFinite
                    && abs(simd_length_squared(sample.orientation) - 1) < 1e-8
              })
        else { throw FusionTrackerClipboardError.invalid("el track de pose materializado no es válido") }
    }
}

struct FusionTrackerMotionComponents: Equatable, Sendable {
    let x: Bool
    let y: Bool
    let scale: Bool
    let rotation: Bool
    let cornerPin: Bool
}

enum FusionTrackerMotionMath {
    static func transformedCorners(
        base: [CGPoint],
        anchorPoints: [CGPoint],
        currentPoints: [CGPoint],
        components: FusionTrackerMotionComponents
    ) throws -> [CGPoint] {
        guard base.count == 4, anchorPoints.count == currentPoints.count,
              !anchorPoints.isEmpty else {
            throw FusionTrackerClipboardError.invalid("las correspondencias 2D no coinciden")
        }
        if components.cornerPin {
            guard anchorPoints.count == 4 else {
                throw FusionTrackerClipboardError.invalid("Corner Pin requiere cuatro correspondencias")
            }
            let homography = try solveHomography(from: anchorPoints, to: currentPoints)
            return try base.map { point in
                let x = Double(point.x), y = Double(point.y)
                let denominator = homography[6] * x + homography[7] * y + 1
                guard denominator.isFinite, abs(denominator) > 1e-12 else {
                    throw FusionTrackerClipboardError.invalid("Corner Pin cruza el plano proyectivo")
                }
                return CGPoint(
                    x: (homography[0] * x + homography[1] * y + homography[2]) / denominator,
                    y: (homography[3] * x + homography[4] * y + homography[5]) / denominator
                )
            }
        }

        let anchorCenter = centroid(anchorPoints)
        let currentCenter = centroid(currentPoints)
        let paired = zip(anchorPoints, currentPoints).map { anchor, current in
            (
                SIMD2(Double(anchor.x - anchorCenter.x), Double(anchor.y - anchorCenter.y)),
                SIMD2(Double(current.x - currentCenter.x), Double(current.y - currentCenter.y))
            )
        }
        var scale = 1.0
        if components.scale {
            let anchorEnergy = paired.reduce(0.0) { $0 + simd_length_squared($1.0) }
            let currentEnergy = paired.reduce(0.0) { $0 + simd_length_squared($1.1) }
            guard anchorEnergy > 1e-12, currentEnergy > 1e-12 else {
                throw FusionTrackerClipboardError.invalid("la escala requiere dos puntos separados")
            }
            scale = sqrt(currentEnergy / anchorEnergy)
        }
        var angle = 0.0
        if components.rotation {
            let dot = paired.reduce(0.0) { $0 + simd_dot($1.0, $1.1) }
            let cross = paired.reduce(0.0) { $0 + $1.0.x * $1.1.y - $1.0.y * $1.1.x }
            guard hypot(dot, cross) > 1e-12 else {
                throw FusionTrackerClipboardError.invalid("la rotación requiere dos puntos separados")
            }
            angle = atan2(cross, dot)
        }
        let cosine = cos(angle), sine = sin(angle)
        let translation = SIMD2(
            components.x ? Double(currentCenter.x - anchorCenter.x) : 0,
            components.y ? Double(currentCenter.y - anchorCenter.y) : 0
        )
        return base.map { point in
            let local = SIMD2(Double(point.x - anchorCenter.x), Double(point.y - anchorCenter.y))
            let rotated = SIMD2(
                local.x * cosine - local.y * sine,
                local.x * sine + local.y * cosine
            ) * scale
            return CGPoint(
                x: Double(anchorCenter.x) + rotated.x + translation.x,
                y: Double(anchorCenter.y) + rotated.y + translation.y
            )
        }
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { result, point in
            CGPoint(x: result.x + point.x, y: result.y + point.y)
        }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private static func solveHomography(from source: [CGPoint], to destination: [CGPoint]) throws -> [Double] {
        var matrix: [[Double]] = [], vector: [Double] = []
        for (sourcePoint, destinationPoint) in zip(source, destination) {
            let x = Double(sourcePoint.x), y = Double(sourcePoint.y)
            let u = Double(destinationPoint.x), v = Double(destinationPoint.y)
            matrix.append([x, y, 1, 0, 0, 0, -u * x, -u * y]); vector.append(u)
            matrix.append([0, 0, 0, x, y, 1, -v * x, -v * y]); vector.append(v)
        }
        return try solve(matrix, vector)
    }

    private static func solve(_ matrix: [[Double]], _ vector: [Double]) throws -> [Double] {
        var augmented = matrix.indices.map { matrix[$0] + [vector[$0]] }
        let count = augmented.count
        for column in 0..<count {
            guard let pivot = (column..<count).max(by: {
                abs(augmented[$0][column]) < abs(augmented[$1][column])
            }), abs(augmented[pivot][column]) > 1e-12 else {
                throw FusionTrackerClipboardError.invalid("las cuatro esquinas son degeneradas")
            }
            if pivot != column { augmented.swapAt(pivot, column) }
            let divisor = augmented[column][column]
            for index in column...count { augmented[column][index] /= divisor }
            for row in 0..<count where row != column {
                let factor = augmented[row][column]
                for index in column...count {
                    augmented[row][index] -= factor * augmented[column][index]
                }
            }
        }
        return augmented.map { $0[count] }
    }
}

struct FusionTrackerClipboard: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.FusionTrackerClipboard.v1"

    let schema: String
    let points: [FusionTrackerPointCurve]

    init(points: [FusionTrackerPointCurve]) throws {
        schema = Self.schema
        self.points = points
        try validate()
    }

    var frameRange: ClosedRange<Int> {
        let frames = points.flatMap(\.samples).map(\.frame)
        return (frames.min() ?? 0)...(frames.max() ?? 0)
    }

    func validate() throws {
        guard schema == Self.schema, !points.isEmpty,
              Set(points.map(\.id)).count == points.count
        else { throw FusionTrackerClipboardError.invalid("no contiene puntos identificables") }
        for point in points {
            guard !point.id.isEmpty, !point.label.isEmpty, !point.samples.isEmpty,
                  point.samples.map(\.frame) == point.samples.map(\.frame).sorted(),
                  Set(point.samples.map(\.frame)).count == point.samples.count,
                  point.samples.allSatisfy({ sample in
                      sample.position.x.isFinite && sample.position.y.isFinite
                  })
            else { throw FusionTrackerClipboardError.invalid("la curva \(point.label) está incompleta") }
        }
        guard Set(points.map { $0.samples.map(\.frame) }).count == 1 else {
            throw FusionTrackerClipboardError.invalid("todos los puntos deben compartir los mismos frames")
        }
    }

    func smoothed(window: Int, degree: Int) throws -> FusionTrackerClipboard {
        guard window >= 3, window.isMultiple(of: 2) == false,
              degree >= 1, degree < window,
              points.allSatisfy({ $0.samples.count >= window })
        else {
            throw FusionTrackerClipboardError.invalid(
                "el suavizado exige una ventana impar, grado menor que la ventana y suficientes muestras"
            )
        }
        return try FusionTrackerClipboard(points: points.map { point in
            let x = try Self.savitzkyGolay(point.samples, window: window, degree: degree, axis: 0)
            let y = try Self.savitzkyGolay(point.samples, window: window, degree: degree, axis: 1)
            return FusionTrackerPointCurve(
                id: point.id,
                label: point.label,
                samples: point.samples.indices.map { index in
                    FusionTrackerSample(
                        frame: point.samples[index].frame,
                        position: SIMD2(x[index], y[index])
                    )
                }
            )
        })
    }

    private static func savitzkyGolay(
        _ samples: [FusionTrackerSample], window: Int, degree: Int, axis: Int
    ) throws -> [Double] {
        let radius = window / 2
        return try samples.indices.map { center in
            let lower = min(max(0, center - radius), samples.count - window)
            let indices = lower..<(lower + window)
            let origin = Double(samples[center].frame)
            var normal = Array(repeating: Array(repeating: 0.0, count: degree + 1), count: degree + 1)
            var right = Array(repeating: 0.0, count: degree + 1)
            for index in indices {
                let t = Double(samples[index].frame) - origin
                let value = axis == 0 ? samples[index].position.x : samples[index].position.y
                var powers = Array(repeating: 1.0, count: degree * 2 + 1)
                if powers.count > 1 {
                    for power in 1..<powers.count { powers[power] = powers[power - 1] * t }
                }
                for row in 0...degree {
                    right[row] += powers[row] * value
                    for column in 0...degree {
                        normal[row][column] += powers[row + column]
                    }
                }
            }
            let coefficients = try solve(normal, right)
            guard let value = coefficients.first, value.isFinite else {
                throw FusionTrackerClipboardError.invalid("el suavizado produce un valor no finito")
            }
            return value
        }
    }

    private static func solve(_ matrix: [[Double]], _ vector: [Double]) throws -> [Double] {
        var augmented = matrix.indices.map { matrix[$0] + [vector[$0]] }
        let count = augmented.count
        for column in 0..<count {
            guard let pivot = (column..<count).max(by: {
                abs(augmented[$0][column]) < abs(augmented[$1][column])
            }), abs(augmented[pivot][column]) > 1e-14 else {
                throw FusionTrackerClipboardError.invalid("la curva no permite ajustar el grado elegido")
            }
            if pivot != column { augmented.swapAt(pivot, column) }
            let divisor = augmented[column][column]
            for index in column...count { augmented[column][index] /= divisor }
            for row in 0..<count where row != column {
                let factor = augmented[row][column]
                for index in column...count {
                    augmented[row][index] -= factor * augmented[column][index]
                }
            }
        }
        return augmented.map { $0[count] }
    }
}

struct FusionTrackerClipboardImporter {
    func parse(_ text: String) throws -> FusionTrackerClipboard {
        let tools = try namedBlock("Tools", in: text)
        let tracker = try firstNode(ofType: "Tracker", in: tools)
        let inputs = try namedBlock("Inputs", in: tracker.body)
        let pointCount = try trackerPointCount(in: tracker.body)
        guard pointCount > 0 else {
            throw FusionTrackerClipboardError.invalid("el nodo no contiene puntos")
        }

        var points: [FusionTrackerPointCurve] = []
        for index in 1...pointCount {
            let label = try stringInput("Name\(index)", in: inputs)
            let pathName = try sourceOpInput("TrackedCenter\(index)", in: inputs)
            let path = try node(named: pathName, type: "PolyPath", in: tools)
            let displacementName = try sourceOpInput("Displacement", in: path.body)
            let displacement = try node(named: displacementName, type: "BezierSpline", in: tools)
            let frames = try keyFrames(in: displacement.body)
            let positions = try polylinePoints(in: path.body)
            guard frames.count == positions.count else {
                throw FusionTrackerClipboardError.invalid(
                    "\(label) tiene \(positions.count) posiciones y \(frames.count) frames"
                )
            }
            points.append(FusionTrackerPointCurve(
                id: "tracker-\(index)", label: label,
                samples: zip(frames, positions).map { frame, position in
                    FusionTrackerSample(frame: frame, position: position)
                }
            ))
        }
        return try FusionTrackerClipboard(points: points)
    }

    private func trackerPointCount(in body: String) throws -> Int {
        let trackers = try namedBlock("Trackers", in: body)
        let ids = try matches(#"\bID\s*=\s*([0-9]+)\s*,"#, in: trackers)
            .compactMap { Int($0[1]) }
        guard !ids.isEmpty, Set(ids).count == ids.count,
              ids.sorted() == Array(0..<ids.count)
        else { throw FusionTrackerClipboardError.invalid("los identificadores de punto no son consecutivos") }
        return ids.count
    }

    private func polylinePoints(in body: String) throws -> [SIMD2<Double>] {
        let polyline = try namedBlock("PolyLine", in: body)
        let entries = try matches(
            #"\{[^{}]*\bX\s*=\s*([-+0-9.eE]+)\s*,\s*Y\s*=\s*([-+0-9.eE]+)[^{}]*\}"#,
            in: polyline
        )
        let result = try entries.map { entry -> SIMD2<Double> in
            guard let x = Double(entry[1]), let y = Double(entry[2]), x.isFinite, y.isFinite else {
                throw FusionTrackerClipboardError.invalid("una posición no es finita")
            }
            // Fusion PolyPath stores coordinates around the composition centre.
            return SIMD2(x + 0.5, y + 0.5)
        }
        guard !result.isEmpty else {
            throw FusionTrackerClipboardError.invalid("una curva no contiene posiciones PolyPath")
        }
        return result
    }

    private func keyFrames(in body: String) throws -> [Int] {
        let keyFrames = try namedBlock("KeyFrames", in: body)
        let result = try matches(#"\[(-?[0-9]+)\]\s*=\s*\{"#, in: keyFrames).map { match in
            guard let frame = Int(match[1]) else {
                throw FusionTrackerClipboardError.invalid("un frame no es entero")
            }
            return frame
        }
        guard !result.isEmpty, result == result.sorted(), Set(result).count == result.count else {
            throw FusionTrackerClipboardError.invalid("los frames no son únicos y ordenados")
        }
        return result
    }

    private func stringInput(_ name: String, in body: String) throws -> String {
        let values = try matches(
            "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*Input\\s*\\{\\s*Value\\s*=\\s*\"([^\"]+)\"",
            in: body
        )
        guard values.count == 1 else {
            throw FusionTrackerClipboardError.invalid("falta el nombre \(name)")
        }
        return values[0][1]
    }

    private func sourceOpInput(_ name: String, in body: String) throws -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let values = try matches(
            "\\b\(escaped)\\s*=\\s*Input\\s*\\{[^{}]*SourceOp\\s*=\\s*\"([^\"]+)\"[^{}]*\\}",
            in: body
        )
        guard values.count == 1 else {
            throw FusionTrackerClipboardError.invalid("falta el enlace \(name)")
        }
        return values[0][1]
    }

    private func firstNode(ofType type: String, in body: String) throws -> (name: String, body: String) {
        let results = try matches("\\b([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*\(type)\\s*\\{", in: body)
        guard results.count == 1 else {
            throw FusionTrackerClipboardError.invalid("debe copiarse exactamente un nodo \(type)")
        }
        return try node(named: results[0][1], type: type, in: body)
    }

    private func node(named name: String, type: String, in text: String) throws -> (name: String, body: String) {
        let marker = "\(name) = \(type)"
        guard let markerRange = text.range(of: marker),
              let open = text[markerRange.upperBound...].firstIndex(of: "{")
        else { throw FusionTrackerClipboardError.invalid("falta el nodo \(name)") }
        return (name, try balancedBody(in: text, openingAt: open))
    }

    private func namedBlock(_ name: String, in text: String) throws -> String {
        guard let nameRange = text.range(of: name),
              let open = text[nameRange.upperBound...].firstIndex(of: "{")
        else { throw FusionTrackerClipboardError.invalid("falta el bloque \(name)") }
        return try balancedBody(in: text, openingAt: open)
    }

    private func balancedBody(in text: String, openingAt open: String.Index) throws -> String {
        var depth = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[text.index(after: open)..<index]) }
            default: break
            }
            index = text.index(after: index)
        }
        throw FusionTrackerClipboardError.invalid("un bloque no está cerrado")
    }

    private func matches(_ pattern: String, in text: String) throws -> [[String]] {
        let regex: NSRegularExpression
        do { regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) }
        catch { throw FusionTrackerClipboardError.invalid("el importador no puede compilar su contrato") }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
        }
    }
}
