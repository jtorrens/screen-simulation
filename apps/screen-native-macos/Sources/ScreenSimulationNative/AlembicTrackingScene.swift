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
    let triangleIndices: [Int]
}

struct TrackingCameraSample: Codable, Equatable, Sendable {
    let frame: Int
    let sourcePosition: SIMD3<Double>
    let orientation: SIMD4<Double>
}

struct TrackingCamera: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let label: String
    let frameRateNumerator: UInt32
    let frameRateDenominator: UInt32
    let focalLengthMillimeters: Double
    let gateWidthMillimeters: Double
    let gateHeightMillimeters: Double
    let samples: [TrackingCameraSample]
}

struct TrackingPointGroup: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let label: String
    let points: [TrackingPoint]
}

struct ImportedTrackingScene: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.TrackingScene.v1"
    let schema: String
    let sourceFileName: String
    let cameras: [TrackingCamera]
    let pointGroups: [TrackingPointGroup]
    let meshes: [TrackingMesh]

    init(sourceFileName: String, cameras: [TrackingCamera], pointGroups: [TrackingPointGroup], meshes: [TrackingMesh]) {
        schema = Self.schema
        self.sourceFileName = sourceFileName
        self.cameras = cameras
        self.pointGroups = pointGroups
        self.meshes = meshes
    }
}

enum AlembicTrackingError: LocalizedError {
    case invalid(String)
    case converter(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(message), let .converter(message): message
        }
    }
}

struct AlembicTrackingImporter {
    private struct Prim {
        let type: String
        let name: String
        let start: String.Index
        let open: String.Index
        let close: String.Index
        var parent: Int?
        var path: String = ""
    }

    func load(_ url: URL) throws -> ImportedTrackingScene {
        guard url.pathExtension.lowercased() == "abc" else {
            throw AlembicTrackingError.invalid("La escena de tracking debe ser un archivo Alembic .abc.")
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("usda")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/usdcat")
        process.arguments = [url.path, "--out", temporary.path]
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw AlembicTrackingError.converter("macOS no pudo iniciar el conversor Alembic/USD: \(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AlembicTrackingError.converter("macOS no pudo leer el Alembic. \(detail)")
        }
        let text = try String(contentsOf: temporary, encoding: .utf8)
        return try parse(text, sourceFileName: url.lastPathComponent)
    }

    func parse(_ text: String, sourceFileName: String) throws -> ImportedTrackingScene {
        guard text.contains("#usda 1.0"), text.contains("upAxis = \"Y\"") else {
            throw AlembicTrackingError.invalid("El Alembic convertido debe declarar USD 1.0 y eje vertical Y.")
        }
        var prims = try parsePrims(text)
        for index in prims.indices {
            let containers = prims.indices.filter {
                $0 != index && prims[$0].open < prims[index].start && prims[$0].close > prims[index].close
            }
            prims[index].parent = containers.min { a, b in
                text.distance(from: prims[a].open, to: prims[a].close)
                    < text.distance(from: prims[b].open, to: prims[b].close)
            }
        }
        for index in prims.indices {
            var names = [prims[index].name]
            var parent = prims[index].parent
            while let value = parent {
                names.append(prims[value].name)
                parent = prims[value].parent
            }
            prims[index].path = "/" + names.reversed().joined(separator: "/")
        }

        let sampleTimes = prims.filter { $0.type == "Xform" }.flatMap {
            matrixSamples(in: body($0, text)).map(\.time)
        }.sorted()
        let frameRate = try exactFrameRate(sampleTimes: sampleTimes)

        var cameras: [TrackingCamera] = []
        for (index, xform) in prims.enumerated() where xform.type == "Xform" {
            guard let cameraPrim = prims.first(where: { $0.parent == index && $0.type == "Camera" }) else { continue }
            let transforms = matrixSamples(in: body(xform, text))
            guard !transforms.isEmpty else { continue }
            let cameraBody = body(cameraPrim, text)
            let focal = try requiredScalarSample("focalLength", in: cameraBody)
            let gateWidth = try requiredScalarSample("horizontalAperture", in: cameraBody)
            let gateHeight = try requiredScalarSample("verticalAperture", in: cameraBody)
            let samples = transforms.enumerated().map { offset, sample in
                TrackingCameraSample(
                    frame: offset,
                    sourcePosition: sample.translation,
                    orientation: quaternion(fromUSDMatrix: sample.matrix)
                )
            }
            cameras.append(.init(
                id: xform.path, label: xform.name,
                frameRateNumerator: frameRate.0, frameRateDenominator: frameRate.1,
                focalLengthMillimeters: focal,
                gateWidthMillimeters: gateWidth,
                gateHeightMillimeters: gateHeight,
                samples: samples
            ))
        }

        var groups: [TrackingPointGroup] = []
        for (index, xform) in prims.enumerated() where xform.type == "Xform" {
            let children = prims.filter { $0.parent == index && $0.type == "Mesh" }
            let points = children.compactMap { child -> TrackingPoint? in
                guard let transform = matrixSamples(in: body(child, text)).first else { return nil }
                return .init(id: child.path, label: child.name, sourcePosition: transform.translation)
            }
            if !points.isEmpty {
                groups.append(.init(id: xform.path, label: xform.name, points: points))
            }
        }

        let groupedMeshPaths = Set(groups.flatMap { $0.points.map(\.id) })
        var meshes: [TrackingMesh] = []
        for mesh in prims where mesh.type == "Mesh" && !groupedMeshPaths.contains(mesh.path) {
            let meshBody = body(mesh, text)
            guard let vertices = vectorArray(property: "point3f[] points.timeSamples", in: meshBody),
                  let counts = integerArray(property: "int[] faceVertexCounts.timeSamples", in: meshBody),
                  let indices = integerArray(property: "int[] faceVertexIndices.timeSamples", in: meshBody)
            else { continue }
            let transform = matrixSamples(in: meshBody).first?.matrix ?? matrix_identity_double4x4
            let worldVertices = vertices.map { transformPoint($0, usd: transform) }
            var triangles: [Int] = []
            var cursor = 0
            for count in counts {
                guard count >= 3, cursor + count <= indices.count else {
                    throw AlembicTrackingError.invalid("La geometría \(mesh.path) contiene caras inválidas.")
                }
                for corner in 1..<(count - 1) {
                    triangles += [indices[cursor], indices[cursor + corner], indices[cursor + corner + 1]]
                }
                cursor += count
            }
            meshes.append(.init(id: mesh.path, label: mesh.name, sourceVertices: worldVertices, triangleIndices: triangles))
        }
        guard !cameras.isEmpty else { throw AlembicTrackingError.invalid("El Alembic no contiene una cámara utilizable.") }
        guard !groups.isEmpty else { throw AlembicTrackingError.invalid("El Alembic no contiene ningún grupo seleccionable como nube de puntos.") }
        return .init(sourceFileName: sourceFileName, cameras: cameras, pointGroups: groups, meshes: meshes)
    }

    private func parsePrims(_ text: String) throws -> [Prim] {
        let regex = try NSRegularExpression(pattern: #"(?m)^\s*def\s+(Xform|Mesh|Camera)\s+\"([^\"]+)\"\s*$"#)
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return try regex.matches(in: text, range: nsRange).map { match in
            guard let typeRange = Range(match.range(at: 1), in: text),
                  let nameRange = Range(match.range(at: 2), in: text),
                  let matchRange = Range(match.range, in: text),
                  let open = text[matchRange.upperBound...].firstIndex(of: "{")
            else { throw AlembicTrackingError.invalid("La jerarquía USD del Alembic está incompleta.") }
            var depth = 0
            var cursor = open
            var close: String.Index?
            while cursor < text.endIndex {
                if text[cursor] == "{" { depth += 1 }
                if text[cursor] == "}" {
                    depth -= 1
                    if depth == 0 { close = cursor; break }
                }
                cursor = text.index(after: cursor)
            }
            guard let close else { throw AlembicTrackingError.invalid("Un objeto USD no está cerrado.") }
            return Prim(type: String(text[typeRange]), name: String(text[nameRange]), start: matchRange.lowerBound, open: open, close: close, parent: nil)
        }
    }

    private func body(_ prim: Prim, _ text: String) -> String {
        String(text[text.index(after: prim.open)..<prim.close])
    }

    private struct MatrixSample {
        let time: Double
        let matrix: simd_double4x4
        var translation: SIMD3<Double> { .init(matrix.columns.0.w, matrix.columns.1.w, matrix.columns.2.w) }
    }

    private func matrixSamples(in body: String) -> [MatrixSample] {
        guard let property = propertyBlock("matrix4d xformOp:transform.timeSamples", in: body) else { return [] }
        return property.split(separator: "\n").compactMap { line in
            let numbers = numericValues(String(line))
            guard numbers.count == 17 else { return nil }
            let m = simd_double4x4(rows: [
                SIMD4(numbers[1], numbers[2], numbers[3], numbers[4]),
                SIMD4(numbers[5], numbers[6], numbers[7], numbers[8]),
                SIMD4(numbers[9], numbers[10], numbers[11], numbers[12]),
                SIMD4(numbers[13], numbers[14], numbers[15], numbers[16]),
            ])
            return MatrixSample(time: numbers[0], matrix: m)
        }
    }

    private func propertyBlock(_ name: String, in body: String) -> String? {
        guard let nameRange = body.range(of: name),
              let open = body[nameRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var cursor = open
        while cursor < body.endIndex {
            if body[cursor] == "{" { depth += 1 }
            if body[cursor] == "}" {
                depth -= 1
                if depth == 0 { return String(body[body.index(after: open)..<cursor]) }
            }
            cursor = body.index(after: cursor)
        }
        return nil
    }

    private func vectorArray(property: String, in body: String) -> [SIMD3<Double>]? {
        guard let block = propertyBlock(property, in: body),
              let open = block.firstIndex(of: "["), let close = block.lastIndex(of: "]") else { return nil }
        let values = numericValues(String(block[open...close]))
        guard values.count.isMultiple(of: 3) else { return nil }
        return stride(from: 0, to: values.count, by: 3).map { .init(values[$0], values[$0 + 1], values[$0 + 2]) }
    }

    private func integerArray(property: String, in body: String) -> [Int]? {
        guard let block = propertyBlock(property, in: body),
              let open = block.firstIndex(of: "["), let close = block.lastIndex(of: "]") else { return nil }
        return numericValues(String(block[open...close])).map { Int($0) }
    }

    private func requiredScalarSample(_ name: String, in body: String) throws -> Double {
        guard let block = propertyBlock("float \(name).timeSamples", in: body),
              let value = numericValues(block).last else {
            throw AlembicTrackingError.invalid("La cámara no declara \(name).")
        }
        return value
    }

    private func numericValues(_ text: String) -> [Double] {
        let pattern = #"[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {
            Range($0.range, in: text).flatMap { Double(text[$0]) }
        }
    }

    private func exactFrameRate(sampleTimes: [Double]) throws -> (UInt32, UInt32) {
        let distinct = Array(Set(sampleTimes)).sorted()
        guard distinct.count >= 2 else { return (24, 1) }
        let delta = distinct[1] - distinct[0]
        guard delta > 0, distinct.dropFirst().enumerated().allSatisfy({ index, value in
            index == 0 || abs((value - distinct[index]) - delta) < 1e-6
        }) else { throw AlembicTrackingError.invalid("La cámara Alembic no usa muestras temporales uniformes.") }
        // USD's normative default timeCodesPerSecond is 24. SynthEyes' 0.96
        // time-code step therefore represents exactly 25 frames per second.
        let rate = 24.0 / delta
        for denominator in 1...1001 {
            let numerator = (rate * Double(denominator)).rounded()
            if abs(rate - numerator / Double(denominator)) < 1e-8 {
                return (UInt32(numerator), UInt32(denominator))
            }
        }
        throw AlembicTrackingError.invalid("La cadencia Alembic no puede representarse como racional exacta.")
    }

    private func quaternion(fromUSDMatrix matrix: simd_double4x4) -> SIMD4<Double> {
        let rotation = simd_double3x3(columns: (
            SIMD3(matrix[0, 0], matrix[0, 1], matrix[0, 2]),
            SIMD3(matrix[1, 0], matrix[1, 1], matrix[1, 2]),
            SIMD3(matrix[2, 0], matrix[2, 1], matrix[2, 2])
        ))
        let q = simd_normalize(simd_quatd(rotation))
        return .init(q.imag.x, q.imag.y, q.imag.z, q.real)
    }

    private func transformPoint(_ point: SIMD3<Double>, usd matrix: simd_double4x4) -> SIMD3<Double> {
        let value = SIMD4(point.x, point.y, point.z, 1) * matrix
        return .init(value.x, value.y, value.z)
    }
}

@MainActor
final class TrackingScenePanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    private var panel: NSPanel?
    private weak var activeModel: WorkspaceModel?

    func toggle(model: WorkspaceModel) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            isVisible = false
            return
        }
        activeModel = model
        let content = TrackingScenePanel(model: model)
        if let panel {
            panel.contentView = NSHostingView(rootView: content)
            panel.makeKeyAndOrderFront(nil)
            isVisible = true
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 520),
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

    func windowWillClose(_ notification: Notification) { isVisible = false }
}

private struct TrackingScenePanel: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        Form {
            Section("Alembic") {
                Button("Importar .abc…", action: model.importAlembicTrackingScene)
                if let scene = model.trackingScene {
                    LabeledContent("Archivo", value: scene.sourceFileName)
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
                }
            }
            if let scene = model.trackingScene {
                Section("Visibilidad") {
                    Toggle("Mostrar point cloud", isOn: $model.trackingPointsVisible)
                    Toggle("Mostrar geometrías", isOn: $model.trackingGeometryVisible)
                    ForEach(scene.meshes) { mesh in
                        Toggle(mesh.label, isOn: Binding(
                            get: { model.visibleTrackingMeshIDs.contains(mesh.id) },
                            set: { model.setTrackingMesh(mesh.id, visible: $0) }
                        ))
                    }
                }
                Section("Escala métrica") {
                    Text("Activa A o B y haz clic sobre dos puntos en el Viewer. Después introduce su distancia real.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(model.trackingScalePointAID == nil ? "Elegir A" : "A ✓") {
                            model.beginTrackingScalePointSelection(slot: 0)
                        }
                        Button(model.trackingScalePointBID == nil ? "Elegir B" : "B ✓") {
                            model.beginTrackingScalePointSelection(slot: 1)
                        }
                        Button("Limpiar", action: model.clearTrackingScaleCalibration)
                    }
                    LabeledContent("Distancia real") {
                        TextField("m", value: $model.trackingMeasuredDistanceMeters, format: .number)
                            .frame(width: 90)
                        Text("m")
                    }
                    Button("Resolver escala", action: model.resolveTrackingScale)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.trackingScalePointAID == nil || model.trackingScalePointBID == nil)
                    if let scale = model.trackingMetersPerSourceUnit {
                        Text("1 unidad Alembic = \(scale.formatted(.number.precision(.fractionLength(6)))) m")
                            .font(.caption.monospacedDigit())
                    } else {
                        Text("La cámara y la geometría no se aplican hasta resolver la escala.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 390, height: 520)
    }
}
