import AppKit
import ScreenPhysicalBridge
import simd
import SwiftUI

enum AuthoredReflectionEmitterKind: String, CaseIterable, Identifiable, Sendable {
    case practical
    case window
    case sun

    var id: String { rawValue }
    var label: String {
        switch self {
        case .practical: "Luz práctica"
        case .window: "Ventana / puerta"
        case .sun: "Fuente lejana"
        }
    }
    var systemImage: String {
        switch self {
        case .practical: "lightbulb.max"
        case .window: "rectangle.on.rectangle"
        case .sun: "sun.max"
        }
    }
}

struct AuthoredReflectionEmitter: Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: AuthoredReflectionEmitterKind
    /// Delivery-Raster pixel coordinates. Practical uses center/radius,
    /// window uses four ordered corners and sun uses one center point.
    var handles: [CGPoint]
    var distanceMeters: Double
    var radianceCandelasPerSquareMeter: Double
    var temperatureKelvin: Double
    var tint: Double
    var softnessDegrees: Double
    var sunAngularDiameterDegrees: Double
}

enum ReflectionEnvironmentEditorError: LocalizedError {
    case noEmitters
    case invalidGeometry
    case compilation(String)
    case exrEncoding(String)

    var errorDescription: String? {
        switch self {
        case .noEmitters: "Añade al menos una fuente de reflexión."
        case .invalidGeometry: "La geometría dibujada no produce direcciones de reflexión válidas."
        case let .compilation(message): "No se pudo crear el entorno: \(message)"
        case let .exrEncoding(message): "No se pudo guardar el OpenEXR: \(message)"
        }
    }
}

enum ReflectionEnvironmentCompiler {
    static func compile(
        emitters: [ScreenReflectionEmitterV2], width: Int, height: Int
    ) throws -> [Float] {
        guard !emitters.isEmpty else { throw ReflectionEnvironmentEditorError.noEmitters }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        var message: UnsafePointer<CChar>?
        let success = emitters.withUnsafeBufferPointer { emitterBuffer in
            pixels.withUnsafeMutableBufferPointer { pixelBuffer in
                screen_reflection_environment_compile_rgba32f(
                    emitterBuffer.baseAddress, emitterBuffer.count,
                    pixelBuffer.baseAddress, UInt32(width), UInt32(height), &message
                )
            }
        }
        guard success else {
            throw ReflectionEnvironmentEditorError.compilation(
                message.map(String.init(cString:)) ?? "contrato desconocido"
            )
        }
        return pixels
    }

    static func encodeEXR(_ pixels: [Float], width: Int, height: Int) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        var message: UnsafeMutablePointer<CChar>?
        let success = pixels.withUnsafeBufferPointer {
            screen_openexr_encode_rgba_half(
                $0.baseAddress, UInt32(width), UInt32(height), &bytes, &count, &message
            )
        }
        guard success, let bytes else {
            defer { if let message { screen_openexr_free(message) } }
            throw ReflectionEnvironmentEditorError.exrEncoding(
                message.map { String(cString: $0) } ?? "error desconocido"
            )
        }
        defer { screen_openexr_free(bytes) }
        return Data(bytes: bytes, count: count)
    }
}

@MainActor
final class ReflectionEnvironmentPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    private var panel: NSPanel?
    private weak var activeModel: WorkspaceModel?

    func toggle(model: WorkspaceModel) {
        if let panel, panel.isVisible {
            hide(model: model)
            return
        }
        activeModel = model
        model.setReflectionEnvironmentEditorEnabled(true)
        let content = ReflectionEnvironmentPanel(model: model)
        if let panel {
            panel.contentView = NSHostingView(rootView: content)
            panel.makeKeyAndOrderFront(nil)
            isVisible = true
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Crear reflejos"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 360, height: 420)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: content)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        isVisible = true
    }

    func hide(model: WorkspaceModel) {
        model.setReflectionEnvironmentEditorEnabled(false)
        panel?.orderOut(nil)
        isVisible = false
    }

    func windowWillClose(_ notification: Notification) {
        activeModel?.setReflectionEnvironmentEditorEnabled(false)
        isVisible = false
    }
}

private struct ReflectionEnvironmentPanel: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dibuja fuentes sobre el Device desde la cámara actual. Se compilan en un OpenEXR 2:1 y se usan como entorno físico.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                ForEach(AuthoredReflectionEmitterKind.allCases) { kind in
                    Button {
                        model.addReflectionEmitter(kind)
                    } label: {
                        Label(kind.label, systemImage: kind.systemImage)
                    }
                }
            }
            .buttonStyle(.bordered)

            List(selection: Binding(
                get: { model.selectedReflectionEmitterID },
                set: { model.selectReflectionEmitter($0) }
            )) {
                ForEach(Array(model.reflectionEmitters.enumerated()), id: \.element.id) { index, emitter in
                    Label("\(emitter.kind.label) \(index + 1)", systemImage: emitter.kind.systemImage)
                        .tag(Optional(emitter.id))
                }
            }
            .frame(minHeight: 90)

            if let emitter = model.selectedReflectionEmitter {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    numericRow("Distancia", value: emitter.distanceMeters, range: 0.1 ... 100, unit: "m") {
                        model.updateSelectedReflectionEmitter(\.distanceMeters, value: $0)
                    }
                    numericRow("Radiancia", value: emitter.radianceCandelasPerSquareMeter, range: 0 ... 100_000, unit: "cd/m²") {
                        model.updateSelectedReflectionEmitter(\.radianceCandelasPerSquareMeter, value: $0)
                    }
                    numericRow("Temperatura", value: emitter.temperatureKelvin, range: 1_000 ... 20_000, unit: "K") {
                        model.updateSelectedReflectionEmitter(\.temperatureKelvin, value: $0)
                    }
                    numericRow("Tinte", value: emitter.tint, range: -1 ... 1, unit: "") {
                        model.updateSelectedReflectionEmitter(\.tint, value: $0)
                    }
                    numericRow("Suavidad", value: emitter.softnessDegrees, range: 0 ... 20, unit: "°") {
                        model.updateSelectedReflectionEmitter(\.softnessDegrees, value: $0)
                    }
                    if emitter.kind == .sun {
                        numericRow("Diámetro", value: emitter.sunAngularDiameterDegrees, range: 0.05 ... 20, unit: "°") {
                            model.updateSelectedReflectionEmitter(\.sunAngularDiameterDegrees, value: $0)
                        }
                    }
                }
                Button("Eliminar fuente", role: .destructive) {
                    model.deleteSelectedReflectionEmitter()
                }
            }

            HStack {
                Picker("Resolución", selection: $model.reflectionEnvironmentWidth) {
                    Text("1K · 1024×512").tag(1024)
                    Text("2K · 2048×1024").tag(2048)
                    Text("4K · 4096×2048").tag(4096)
                }
                Spacer()
                Button("Generar y usar") {
                    Task { await model.generateAndUseReflectionEnvironment() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.reflectionEmitters.isEmpty || model.reflectionEnvironmentIsGenerating)
            }
            if model.reflectionEnvironmentIsGenerating {
                ProgressView().controlSize(.small)
            }
        }
        .padding(16)
        .frame(minWidth: 360, idealWidth: 390)
    }

    private func numericRow(
        _ label: String, value: Double, range: ClosedRange<Double>, unit: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        GridRow {
            Text(label)
            Slider(value: Binding(get: { value }, set: onChange), in: range)
            Text(value.formatted(.number.precision(.fractionLength(0 ... 2))))
                .monospacedDigit().frame(width: 58, alignment: .trailing)
            Text(unit).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
        }
    }
}
