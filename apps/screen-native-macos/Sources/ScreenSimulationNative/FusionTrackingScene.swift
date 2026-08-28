import AppKit
import Foundation
import ScreenPhysicalBridge
import simd
import SwiftUI

struct TrackingPoint: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let label: String
    let sourcePosition: SIMD3<Double>
}

struct TrackingMesh: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let label: String
    let sourceVertices: [SIMD3<Double>]
    let faceVertexCounts: [Int]
    let faceVertexIndices: [Int]

    var triangleIndices: [Int] {
        var result: [Int] = [], cursor = 0
        for count in faceVertexCounts where count >= 3 && cursor + count <= faceVertexIndices.count {
            for corner in 1..<(count - 1) {
                result += [faceVertexIndices[cursor], faceVertexIndices[cursor + corner], faceVertexIndices[cursor + corner + 1]]
            }
            cursor += count
        }
        return result
    }
}

struct TrackingPlanePlacement: Equatable, Sendable {
    let center: SIMD3<Double>
    let orientation: simd_quatd
}

extension TrackingMesh {
    func planePlacement(toward viewer: SIMD3<Double>) -> TrackingPlanePlacement? {
        guard !sourceVertices.isEmpty, triangleIndices.count >= 3 else { return nil }
        let minimum = sourceVertices.reduce(SIMD3(repeating: Double.infinity)) { simd_min($0, $1) }
        let maximum = sourceVertices.reduce(SIMD3(repeating: -Double.infinity)) { simd_max($0, $1) }
        let center = (minimum + maximum) * 0.5
        var normal = SIMD3<Double>.zero
        var edgeUse: [TrackingMeshEdge: Int] = [:]
        for offset in stride(from: 0, to: triangleIndices.count, by: 3) {
            guard offset + 2 < triangleIndices.count else { return nil }
            let ids = [triangleIndices[offset], triangleIndices[offset + 1], triangleIndices[offset + 2]]
            guard ids.allSatisfy(sourceVertices.indices.contains) else { return nil }
            let a = sourceVertices[ids[0]], b = sourceVertices[ids[1]], c = sourceVertices[ids[2]]
            normal += simd_cross(b - a, c - a)
            for pair in [(ids[0], ids[1]), (ids[1], ids[2]), (ids[2], ids[0])] {
                edgeUse[TrackingMeshEdge(pair.0, pair.1), default: 0] += 1
            }
        }
        guard simd_length_squared(normal) > 1e-20 else { return nil }
        normal = simd_normalize(normal)
        let extent = simd_length(maximum - minimum)
        guard extent > 1e-10 else { return nil }
        let maximumPlaneDistance = sourceVertices.map { abs(simd_dot($0 - center, normal)) }.max() ?? 0
        guard maximumPlaneDistance <= extent * 1e-4 else { return nil }
        let boundaryEdges = edgeUse.compactMap { edge, count in count == 1 ? edge : nil }
        guard let longest = boundaryEdges.max(by: {
            simd_length_squared(sourceVertices[$0.a] - sourceVertices[$0.b])
                < simd_length_squared(sourceVertices[$1.a] - sourceVertices[$1.b])
        }) else { return nil }
        var right = sourceVertices[longest.b] - sourceVertices[longest.a]
        right -= normal * simd_dot(right, normal)
        guard simd_length_squared(right) > 1e-20 else { return nil }
        right = simd_normalize(right)
        if simd_dot(normal, viewer - center) < 0 {
            normal = -normal
            right = -right
        }
        let up = simd_normalize(simd_cross(normal, right))
        let rotation = simd_double3x3(columns: (right, up, normal))
        return TrackingPlanePlacement(center: center, orientation: simd_normalize(simd_quatd(rotation)))
    }
}

private struct TrackingMeshEdge: Hashable {
    let a: Int
    let b: Int

    init(_ first: Int, _ second: Int) {
        a = min(first, second)
        b = max(first, second)
    }
}

struct TrackingCameraSample: Codable, Equatable, Sendable {
    let frame: Int
    let sourcePosition: SIMD3<Double>
    let orientation: SIMD4<Double>
}

struct TrackingCamera: Identifiable, Codable, Equatable, Sendable {
    enum Distortion: Codable, Equatable, Sendable {
        case pinhole
        case de4RadialStandardDegree4(degree2: Double, degree4: Double)
    }

    let id: String
    let label: String
    let frameRateNumerator: UInt32
    let frameRateDenominator: UInt32
    let focalLengthMillimeters: Double
    let gateWidthMillimeters: Double
    let gateHeightMillimeters: Double
    let plateWidth: UInt32
    let plateHeight: UInt32
    let distortion: Distortion
    let samples: [TrackingCameraSample]

    func sample(atTimelineFrame frame: Int, timelineFrameRate: Double) -> TrackingCameraSample? {
        guard !samples.isEmpty, timelineFrameRate.isFinite, timelineFrameRate > 0 else { return nil }
        let trackingFrameRate = Double(frameRateNumerator) / Double(frameRateDenominator)
        let samplePosition = max(0, Double(frame)) * trackingFrameRate / timelineFrameRate
        let lowerIndex = min(Int(floor(samplePosition)), samples.count - 1)
        let upperIndex = min(lowerIndex + 1, samples.count - 1)
        let amount = min(max(samplePosition - Double(lowerIndex), 0), 1)
        let lower = samples[lowerIndex]
        guard upperIndex != lowerIndex, amount > 0 else {
            return TrackingCameraSample(
                frame: frame,
                sourcePosition: lower.sourcePosition,
                orientation: lower.orientation
            )
        }
        let upper = samples[upperIndex]
        let lowerRotation = simd_normalize(simd_quatd(
            ix: lower.orientation.x, iy: lower.orientation.y,
            iz: lower.orientation.z, r: lower.orientation.w
        ))
        let upperRotation = simd_normalize(simd_quatd(
            ix: upper.orientation.x, iy: upper.orientation.y,
            iz: upper.orientation.z, r: upper.orientation.w
        ))
        let rotation = simd_slerp(lowerRotation, upperRotation, amount)
        return TrackingCameraSample(
            frame: frame,
            sourcePosition: lower.sourcePosition + (upper.sourcePosition - lower.sourcePosition) * amount,
            orientation: .init(rotation.imag.x, rotation.imag.y, rotation.imag.z, rotation.real)
        )
    }
}

private extension TrackingCamera.Distortion {
    var hasFiniteCoefficients: Bool {
        switch self {
        case .pinhole: true
        case let .de4RadialStandardDegree4(degree2, degree4):
            degree2.isFinite && degree4.isFinite
        }
    }
}

struct TrackingPointGroup: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let label: String
    let points: [TrackingPoint]
}

/// Host-neutral 3D authoring owned by the scene. Importers create this value, but its
/// identity and lifetime are independent of the file or application it came from.
struct TrackingScene: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.TrackingScene.v1"
    let schema: String
    let cameras: [TrackingCamera]
    let pointGroups: [TrackingPointGroup]
    let meshes: [TrackingMesh]

    init(cameras: [TrackingCamera], pointGroups: [TrackingPointGroup], meshes: [TrackingMesh]) {
        schema = Self.schema
        self.cameras = cameras
        self.pointGroups = pointGroups
        self.meshes = meshes
    }

    func freezingCamera(
        id cameraID: String,
        sourcePosition: SIMD3<Double>,
        orientation: SIMD4<Double>
    ) throws -> TrackingScene {
        guard let index = cameras.firstIndex(where: { $0.id == cameraID }),
              sourcePosition.x.isFinite, sourcePosition.y.isFinite,
              sourcePosition.z.isFinite,
              orientation.x.isFinite, orientation.y.isFinite,
              orientation.z.isFinite, orientation.w.isFinite,
              abs(simd_length_squared(orientation) - 1) < 1e-8
        else {
            throw FusionTrackingError.invalid(
                "La cámara seleccionada no puede congelarse en el frame actual."
            )
        }
        let camera = cameras[index]
        var frozenCameras = cameras
        frozenCameras[index] = TrackingCamera(
            id: camera.id,
            label: camera.label,
            frameRateNumerator: camera.frameRateNumerator,
            frameRateDenominator: camera.frameRateDenominator,
            focalLengthMillimeters: camera.focalLengthMillimeters,
            gateWidthMillimeters: camera.gateWidthMillimeters,
            gateHeightMillimeters: camera.gateHeightMillimeters,
            plateWidth: camera.plateWidth,
            plateHeight: camera.plateHeight,
            distortion: camera.distortion,
            samples: [
                TrackingCameraSample(
                    frame: 0,
                    sourcePosition: sourcePosition,
                    orientation: orientation
                ),
            ]
        )
        let frozen = TrackingScene(
            cameras: frozenCameras,
            pointGroups: pointGroups,
            meshes: meshes
        )
        try frozen.validate()
        return frozen
    }

    func validate() throws {
        guard schema == Self.schema,
              !cameras.isEmpty,
              !pointGroups.isEmpty,
              Set(cameras.map(\.id)).count == cameras.count,
              Set(pointGroups.map(\.id)).count == pointGroups.count,
              Set(meshes.map(\.id)).count == meshes.count,
              cameras.allSatisfy({ camera in
                  !camera.id.isEmpty && !camera.label.isEmpty
                    && camera.frameRateNumerator > 0 && camera.frameRateDenominator > 0
                    && camera.focalLengthMillimeters.isFinite
                    && camera.focalLengthMillimeters > 0
                    && camera.gateWidthMillimeters.isFinite && camera.gateWidthMillimeters > 0
                    && camera.gateHeightMillimeters.isFinite && camera.gateHeightMillimeters > 0
                    && camera.plateWidth > 0 && camera.plateHeight > 0
                    && camera.distortion.hasFiniteCoefficients
                    && !camera.samples.isEmpty
                    && Set(camera.samples.map(\.frame)).count == camera.samples.count
                    && camera.samples.map(\.frame) == camera.samples.map(\.frame).sorted()
                    && camera.samples.allSatisfy({ sample in
                        sample.sourcePosition.x.isFinite
                            && sample.sourcePosition.y.isFinite
                            && sample.sourcePosition.z.isFinite
                            && sample.orientation.x.isFinite
                            && sample.orientation.y.isFinite
                            && sample.orientation.z.isFinite
                            && sample.orientation.w.isFinite
                            && abs(simd_length_squared(sample.orientation) - 1) < 1e-8
                    })
              }),
              pointGroups.allSatisfy({ group in
                  !group.id.isEmpty && !group.label.isEmpty && !group.points.isEmpty
                    && Set(group.points.map(\.id)).count == group.points.count
                    && group.points.allSatisfy({ point in
                        !point.id.isEmpty && !point.label.isEmpty
                            && point.sourcePosition.x.isFinite
                            && point.sourcePosition.y.isFinite
                            && point.sourcePosition.z.isFinite
                    })
              }),
              meshes.allSatisfy({ mesh in
                  !mesh.id.isEmpty && !mesh.label.isEmpty && !mesh.sourceVertices.isEmpty
                    && mesh.sourceVertices.allSatisfy({ vertex in
                        vertex.x.isFinite && vertex.y.isFinite && vertex.z.isFinite
                    })
                    && mesh.faceVertexCounts.allSatisfy({ $0 >= 3 })
                    && mesh.faceVertexCounts.reduce(0, +) == mesh.faceVertexIndices.count
                    && mesh.faceVertexIndices.allSatisfy(mesh.sourceVertices.indices.contains)
              })
        else {
            throw SceneLibraryError.invalidDocument("La autoría 3D guardada no es válida.")
        }
    }
}

enum FusionTrackingError: LocalizedError {
    case invalid(String)
    case converter(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message), let .converter(message): message
        }
    }
}

struct FusionTrackingImporter {
    func load(_ url: URL) throws -> TrackingScene {
        guard url.pathExtension.lowercased() == "comp" else {
            throw FusionTrackingError.invalid("La solución de tracking debe ser una composición Fusion .comp.")
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text)
    }

    func parse(_ text: String) throws -> TrackingScene {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-- Fusion Exporter:"),
              text.contains("Composition {") else {
            throw FusionTrackingError.invalid("El archivo no es una composición ASCII exportada por SynthEyes para Fusion.")
        }
        let format = try requiredBlock(after: "FrameFormat =", in: text)
        let width = try requiredUInt("Width", in: format)
        let height = try requiredUInt("Height", in: format)
        let rate = try requiredUInt("Rate", in: format)
        guard width > 0, height > 0, rate > 0 else {
            throw FusionTrackingError.invalid("El raster o la cadencia Fusion no son válidos.")
        }
        let cameraEntries = try toolEntries(ofType: "Camera3D", in: text)
        var cameras: [TrackingCamera] = []
        for entry in cameraEntries {
            let body = entry.body
            let focal = try requiredInput("FLength", in: body)
            let gateWidth = try requiredInput("ApertureW", in: body) * 25.4
            let gateHeight = try requiredInput("ApertureH", in: body) * 25.4
            let channels = try ["XOffset", "YOffset", "ZOffset", "XRotation", "YRotation", "ZRotation"].map {
                try spline(named: entry.name + $0, in: text)
            }
            guard Set(channels.map { Set($0.keys) }).count == 1,
                  let frames = channels.first?.keys.sorted(), !frames.isEmpty else {
                throw FusionTrackingError.invalid("La cámara Fusion no contiene seis canales animados coincidentes.")
            }
            let samples = frames.map { frame -> TrackingCameraSample in
                let position = SIMD3(channels[0][frame]!, channels[1][frame]!, channels[2][frame]!)
                let degrees = SIMD3(channels[3][frame]!, channels[4][frame]!, channels[5][frame]!)
                let qx = simd_quatd(angle: degrees.x * .pi / 180, axis: SIMD3(1, 0, 0))
                let qy = simd_quatd(angle: degrees.y * .pi / 180, axis: SIMD3(0, 1, 0))
                let qz = simd_quatd(angle: degrees.z * .pi / 180, axis: SIMD3(0, 0, 1))
                let q = simd_normalize(qz * qy * qx)
                return .init(frame: frame, sourcePosition: position,
                    orientation: .init(q.imag.x, q.imag.y, q.imag.z, q.real))
            }
            cameras.append(.init(
                id: entry.name, label: entry.name,
                frameRateNumerator: rate, frameRateDenominator: 1,
                focalLengthMillimeters: focal,
                gateWidthMillimeters: gateWidth, gateHeightMillimeters: gateHeight,
                plateWidth: width, plateHeight: height,
                distortion: try distortion(for: entry.name, gateWidth: gateWidth, gateHeight: gateHeight, in: text),
                samples: samples
            ))
        }
        let pointGroups: [TrackingPointGroup] = try toolEntries(ofType: "PointCloud3D", in: text).map { entry in
            let positions = try requiredBlock(after: "Positions =", in: entry.body)
            let regex = try NSRegularExpression(pattern: #"\[(\d+)\]\s*=\s*\{\s*([-+0-9.eE]+),\s*([-+0-9.eE]+),\s*([-+0-9.eE]+),\s*\"([^\"]+)\""#)
            let points = regex.matches(in: positions, range: NSRange(positions.startIndex..., in: positions)).compactMap { match -> TrackingPoint? in
                guard let i = Range(match.range(at: 1), in: positions), let x = Range(match.range(at: 2), in: positions),
                      let y = Range(match.range(at: 3), in: positions), let z = Range(match.range(at: 4), in: positions),
                      let label = Range(match.range(at: 5), in: positions),
                      let xv = Double(positions[x]), let yv = Double(positions[y]), let zv = Double(positions[z]) else { return nil }
                return .init(id: "\(entry.name)/\(positions[i])", label: String(positions[label]), sourcePosition: .init(xv, yv, zv))
            }
            guard !points.isEmpty else { throw FusionTrackingError.invalid("La nube \(entry.name) no contiene puntos válidos.") }
            return .init(id: entry.name, label: entry.name, points: points)
        }
        let meshes: [TrackingMesh] = try toolEntries(ofType: "Shape3D", in: text).map { entry in
            let t = try vector3(prefix: "Transform3DOp.Translate", in: entry.body, defaultValue: 0)
            let r = try vector3(prefix: "Transform3DOp.Rotate", in: entry.body, defaultValue: 0)
            let s = try vector3(prefix: "Transform3DOp.Scale", in: entry.body, defaultValue: 1)
            let qx = simd_quatd(angle: r.x * .pi / 180, axis: SIMD3(1, 0, 0))
            let qy = simd_quatd(angle: r.y * .pi / 180, axis: SIMD3(0, 1, 0))
            let qz = simd_quatd(angle: r.z * .pi / 180, axis: SIMD3(0, 0, 1))
            let q = simd_normalize(qz * qy * qx)
            let local = [SIMD3(-0.5, -0.5, 0), SIMD3(0.5, -0.5, 0), SIMD3(0.5, 0.5, 0), SIMD3(-0.5, 0.5, 0)]
            return .init(id: entry.name, label: entry.name,
                sourceVertices: local.map { q.act($0 * s) + t },
                faceVertexCounts: [4], faceVertexIndices: [0, 1, 2, 3])
        }
        guard !cameras.isEmpty else { throw FusionTrackingError.invalid("La composición no contiene una cámara Fusion utilizable.") }
        guard !pointGroups.isEmpty else { throw FusionTrackingError.invalid("La composición no contiene ninguna nube de puntos.") }
        return .init(cameras: cameras, pointGroups: pointGroups, meshes: meshes)
    }

    private struct ToolEntry { let name: String; let body: String }

    private func toolEntries(ofType type: String, in text: String) throws -> [ToolEntry] {
        let regex = try NSRegularExpression(pattern: #"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"# + NSRegularExpression.escapedPattern(for: type) + #"\s*\{"#)
        return try regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            guard let full = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text),
                  let open = text[full].lastIndex(of: "{") else { throw FusionTrackingError.invalid("Un nodo Fusion está incompleto.") }
            return .init(name: String(text[name]), body: try balancedBody(open: open, in: text))
        }
    }

    private func requiredBlock(after marker: String, in text: String) throws -> String {
        guard let markerRange = text.range(of: marker), let open = text[markerRange.upperBound...].firstIndex(of: "{") else {
            throw FusionTrackingError.invalid("Falta el bloque Fusion \(marker).")
        }
        return try balancedBody(open: open, in: text)
    }

    private func balancedBody(open: String.Index, in text: String) throws -> String {
        var depth = 0, quoted = false, escaped = false
        var cursor = open
        while cursor < text.endIndex {
            let c = text[cursor]
            if quoted {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
            } else if c == "\"" { quoted = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return String(text[text.index(after: open)..<cursor]) } }
            cursor = text.index(after: cursor)
        }
        throw FusionTrackingError.invalid("Un bloque Fusion no está cerrado.")
    }

    private func requiredInput(_ name: String, in text: String) throws -> Double {
        let pattern = NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*Input\s*\{\s*Value\s*=\s*([-+0-9.eE]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let value = Double(text[range]), value.isFinite else {
            throw FusionTrackingError.invalid("Falta el valor Fusion \(name).")
        }
        return value
    }

    private func requiredUInt(_ name: String, in text: String) throws -> UInt32 {
        let regex = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(\d+)"#)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text), let value = UInt32(text[range]) else {
            throw FusionTrackingError.invalid("Falta el entero Fusion \(name).")
        }
        return value
    }

    private func spline(named name: String, in text: String) throws -> [Int: Double] {
        guard let entry = try toolEntries(ofType: "BezierSpline", in: text).first(where: { $0.name == name }) else {
            throw FusionTrackingError.invalid("Falta la curva Fusion \(name).")
        }
        let keys = try requiredBlock(after: "KeyFrames =", in: entry.body)
        let regex = try NSRegularExpression(pattern: #"\[(-?\d+)\]\s*=\s*\{\s*([-+0-9.eE]+)"#)
        let pairs = regex.matches(in: keys, range: NSRange(keys.startIndex..., in: keys)).compactMap { match -> (Int, Double)? in
            guard let f = Range(match.range(at: 1), in: keys), let v = Range(match.range(at: 2), in: keys),
                  let frame = Int(keys[f]), let value = Double(keys[v]) else { return nil }
            return (frame, value)
        }
        guard !pairs.isEmpty, Set(pairs.map(\.0)).count == pairs.count else { throw FusionTrackingError.invalid("La curva \(name) no contiene claves únicas.") }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    private func distortion(for camera: String, gateWidth: Double, gateHeight: Double, in text: String) throws -> TrackingCamera.Distortion {
        let nodes = try toolEntries(ofType: "LensDistort", in: text).filter { $0.name.hasPrefix(camera) }
        guard !nodes.isEmpty else { return .pinhole }
        let modelNodes = nodes.filter { $0.body.contains(#"Model = Input { Value = FuID { "DE4RadialStandardDegree4" }"#) }
        guard modelNodes.count == nodes.count else { throw FusionTrackingError.invalid("La composición contiene un modelo de distorsión no compatible.") }
        let values = try modelNodes.map { node in
            (try requiredInput("[\"DE4RadialStandardDegree4.DistortionDegree2\"]", in: node.body),
             try requiredInput("[\"DE4RadialStandardDegree4.QuarticDistortionDegree4\"]", in: node.body))
        }
        guard values.dropFirst().allSatisfy({ abs($0.0 - values[0].0) < 1e-12 && abs($0.1 - values[0].1) < 1e-12 }) else {
            throw FusionTrackingError.invalid("Los nodos de distorsión y redistorsión no coinciden.")
        }
        let value = values[0]
        return abs(value.0) < 1e-15 && abs(value.1) < 1e-15 ? .pinhole : .de4RadialStandardDegree4(degree2: value.0, degree4: value.1)
    }

    private func vector3(prefix: String, in text: String, defaultValue: Double) throws -> SIMD3<Double> {
        func component(_ axis: String) throws -> Double {
            let key = "[\"\(prefix).\(axis)\"]"
            if !text.contains(key) { return defaultValue }
            return try requiredInput(key, in: text)
        }
        return try .init(component("X"), component("Y"), component("Z"))
    }
}

@MainActor
final class TrackingScenePanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    private var panel: NSPanel?
    private weak var activeModel: WorkspaceModel?

    func toggle(
        model: WorkspaceModel,
        undoManager: UndoManager?,
        method: TrackingSceneMethod? = nil
    ) {
        let switchesVisibleMethod = method.map { $0 != model.trackingSceneMethod } ?? false
        if let method { model.setTrackingSceneMethod(method) }
        if let panel, panel.isVisible {
            if switchesVisibleMethod {
                model.setReferenceMatchEnabled(model.trackingSceneMethod == .deviceCorners)
                panel.makeKeyAndOrderFront(nil)
                isVisible = true
                return
            }
            model.setReferenceMatchEnabled(false)
            panel.orderOut(nil)
            isVisible = false
            return
        }
        activeModel = model
        model.setReferenceMatchEnabled(model.trackingSceneMethod == .deviceCorners)
        let content = TrackingScenePanel(model: model, undoManager: undoManager)
        if let panel {
            panel.contentView = NSHostingView(rootView: content)
            panel.makeKeyAndOrderFront(nil)
            isVisible = true
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 650),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false
        )
        panel.title = "Tracking 3D"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: content)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        isVisible = true
    }

    func windowWillClose(_ notification: Notification) {
        activeModel?.setReferenceMatchEnabled(false)
        isVisible = false
    }
}

private struct TrackingScenePanel: View {
    @ObservedObject var model: WorkspaceModel
    let undoManager: UndoManager?
    @State private var pendingRemoval: TrackingRemoval?

    private enum TrackingRemoval {
        case cameraAnimation

        var title: String {
            switch self {
            case .cameraAnimation: "¿Eliminar la animación de cámara?"
            }
        }

        var message: String {
            switch self {
            case .cameraAnimation:
                "La cámara quedará congelada con el encuadre del frame actual. Se conservarán focal, gate, distorsión, nube de puntos, geometrías y escala."
            }
        }
    }

    var body: some View {
        Form {
            Section("Método") {
                Picker("Generar escena 3D", selection: Binding(
                    get: { model.trackingSceneMethod },
                    set: { model.setTrackingSceneMethod($0) }
                )) {
                    ForEach(TrackingSceneMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
            }
            if model.trackingSceneMethod == .fusionComposition {
                fusionCompositionSection
            } else if model.trackingSceneMethod == .deviceCorners {
                deviceCornersSection
            } else {
                fusionTrackerSection
            }
            if model.trackingSceneMethod == .fusionComposition, let scene = model.trackingScene {
                importedElementsSection(scene)
                metricScaleSection
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 650)
        .confirmationDialog(
            pendingRemoval?.title ?? "Confirmar",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let removal = pendingRemoval {
                Button("Eliminar", role: .destructive) {
                    pendingRemoval = nil
                    switch removal {
                    case .cameraAnimation:
                        model.freezeTrackingCameraAnimation(undoManager: undoManager)
                    }
                }
            }
            Button("Cancelar", role: .cancel) { pendingRemoval = nil }
        } message: {
            if let removal = pendingRemoval { Text(removal.message) }
        }
    }

    private var fusionCompositionSection: some View {
        Section("SynthEyes / Fusion") {
                Button("Importar .comp…", action: model.importFusionTrackingScene)
                if let scene = model.trackingScene {
                    LabeledContent("Origen", value: "Autoría 3D de la escena")
                    Picker("Cámara", selection: $model.selectedTrackingCameraID) {
                        Text("Seleccionar…").tag(String?.none)
                        ForEach(scene.cameras) { Text($0.label).tag(Optional($0.id)) }
                    }
                    .onChange(of: model.selectedTrackingCameraID) { _, _ in
                        model.refreshTrackingCamera()
                    }
                    Picker("Nube de puntos", selection: $model.selectedTrackingPointGroupID) {
                        Text("Seleccionar…").tag(String?.none)
                        ForEach(scene.pointGroups) { Text("\($0.label) · \($0.points.count)").tag(Optional($0.id)) }
                    }
                    Toggle("Aplicar cámara animada", isOn: $model.trackingCameraEnabled)
                        .onChange(of: model.trackingCameraEnabled) { _, _ in
                            model.refreshTrackingCamera()
                        }
                    Button("Eliminar animación de cámara…", role: .destructive) {
                        pendingRemoval = .cameraAnimation
                    }
                    .disabled(!model.canFreezeTrackingCameraAnimation)
                }
            }
    }

    private var deviceCornersSection: some View {
        Section("Esquinas del Device") {
            HStack {
                Label(
                    "4 objetivos directos",
                    systemImage: model.referenceMatchCorners.count == 4
                        ? "checkmark.circle.fill" : "circle.dashed"
                )
                .foregroundStyle(model.referenceMatchCorners.count == 4 ? .green : .secondary)
                Spacer()
                if let error = model.referenceMatchErrorPixels {
                    Text("Máx. ±\(error.formatted(.number.precision(.fractionLength(1)))) px")
                        .font(.caption.monospacedDigit())
                }
            }
            Text("Arrastra los cuatro objetivos amarillos sobre la referencia. La solución conserva el Device rígido y modifica solamente la cámara.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Resolver") { model.solveReferenceMatchTargets(undoManager: undoManager) }
                Button("Buscar focal") { model.searchReferenceMatchFocalLength(undoManager: undoManager) }
                    .buttonStyle(.borderedProminent)
            }
            .disabled(model.referenceMatchCorners.count != 4)
            HStack {
                Button("Reiniciar objetivos", action: model.clearReferenceMatchTargets)
                    .disabled(model.referenceMatchCorners.count != 4)
                Spacer()
                if let focal = model.referenceMatchFocalLengthMillimeters {
                    Text("Focal \(focal.formatted(.number.precision(.fractionLength(2)))) mm")
                        .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private var fusionTrackerSection: some View {
        Group {
            Section("Tracker en portapapeles") {
                Button("Pegar nodo Tracker", action: model.importFusionTrackerFromClipboard)
                if let tracker = model.fusionTrackerClipboard {
                    Text("\(tracker.points.count) puntos · frames \(tracker.frameRange.lowerBound)–\(tracker.frameRange.upperBound) · origen \(model.fusionTrackerAnchorFrame ?? 0)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    ForEach(tracker.points) { point in
                        HStack {
                            Text(point.label).lineLimit(1)
                            Spacer()
                            Picker("Esquina", selection: Binding(
                                get: { model.fusionTrackerCornerAssignments[point.id] ?? .unassigned },
                                set: { model.setFusionTrackerCorner($0, for: point.id) }
                            )) {
                                ForEach(FusionTrackerCorner.allCases) { corner in
                                    Text(corner.label).tag(corner)
                                }
                            }
                            .labelsHidden().frame(width: 110)
                        }
                    }
                }
            }
            Section("Offset rígido") {
                Picker("Aplicar a", selection: $model.fusionTrackerTarget) {
                    ForEach(FusionTrackerTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                Group {
                    Toggle("Traslación X", isOn: $model.fusionTrackerMovesX)
                    Toggle("Traslación Y", isOn: $model.fusionTrackerMovesY)
                    Toggle("Escala mediante profundidad", isOn: $model.fusionTrackerScales)
                    Toggle("Rotación alrededor de Z local", isOn: $model.fusionTrackerRotates)
                }
                .disabled(model.fusionTrackerUsesCornerPin)
                Toggle("Corner Pin como pose 3D rígida", isOn: $model.fusionTrackerUsesCornerPin)
            }
            Section("Suavizado") {
                Toggle("Savitzky–Golay", isOn: $model.fusionTrackerSmoothingEnabled)
                if model.fusionTrackerSmoothingEnabled {
                    Stepper("Ventana · \(model.fusionTrackerSmoothingWindow) frames", value: $model.fusionTrackerSmoothingWindow, in: 3...101, step: 2)
                    Stepper("Grado · \(model.fusionTrackerSmoothingDegree)", value: $model.fusionTrackerSmoothingDegree, in: 1...5)
                }
                Button("Aplicar tracker") {
                    model.applyFusionTrackerMotion(undoManager: undoManager)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.fusionTrackerClipboard == nil)
            }
        }
    }

    private func importedElementsSection(_ scene: TrackingScene) -> some View {
        Section("Elementos 3D") {
                    Text("Clic derecho sobre un punto verde para colocar el centro del Device. Clic derecho sobre el centro naranja de un plano para colocarlo y orientarlo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(isOn: $model.trackingPointsVisible) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Nube de puntos")
                            if let group = selectedPointGroup(in: scene) {
                                Text("\(group.label) · \(group.points.count) puntos")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Ninguna seleccionada")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle(isOn: $model.trackingGeometryVisible) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Geometrías")
                            Text("\(scene.meshes.count) elementos importados")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(scene.meshes) { mesh in
                        Toggle(isOn: Binding(
                            get: { model.visibleTrackingMeshIDs.contains(mesh.id) },
                            set: { model.setTrackingMesh(mesh.id, visible: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mesh.label)
                                Text(mesh.id)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(mesh.sourceVertices.count) vértices · \(mesh.faceVertexCounts.count) caras")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let dimensions = model.trackingMeshDimensions(mesh) {
                                    Text("\(dimensions.x.formatted(.number.precision(.fractionLength(2)))) × \(dimensions.y.formatted(.number.precision(.fractionLength(2)))) × \(dimensions.z.formatted(.number.precision(.fractionLength(2)))) m")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .help(mesh.id)
                    }
                }
    }

    private var metricScaleSection: some View {
        Section("Escala métrica") {
                    Text("Define directamente cuánto mide una unidad de SynthEyes.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("1 unidad SynthEyes") {
                        TextField("Valor", value: $model.trackingSynthEyesUnitValue, format: .number)
                            .frame(width: 90)
                        Picker("Unidad", selection: $model.trackingSynthEyesUnit) {
                            Text("m").tag("m")
                            Text("cm").tag("cm")
                        }.labelsHidden().frame(width: 80)
                    }
                    Button("Aplicar escala", action: model.applyTrackingUnitScale)
                        .buttonStyle(.borderedProminent)
                    if let scale = model.trackingMetersPerSourceUnit {
                        Text("1 unidad Fusion = \(scale.formatted(.number.precision(.fractionLength(6)))) m")
                            .font(.caption.monospacedDigit())
                    } else {
                        Text("La cámara y la geometría no se aplican hasta resolver la escala.")
                            .font(.caption).foregroundStyle(.orange)
                    }
        }
    }

    private func selectedPointGroup(in scene: TrackingScene) -> TrackingPointGroup? {
        guard let selectedID = model.selectedTrackingPointGroupID else { return nil }
        return scene.pointGroups.first { $0.id == selectedID }
    }
}
