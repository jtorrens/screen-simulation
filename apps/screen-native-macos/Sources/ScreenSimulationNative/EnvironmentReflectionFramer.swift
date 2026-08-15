import AppKit
import Metal
import simd
import StudioColor
import SwiftUI

struct EnvironmentReflectionFraming: Equatable, Sendable {
    var centerX = 0.5
    var centerY = 0.5
    var zoom = 1.0
    var rollDegrees = 0.0

    var shaderValue: SIMD4<Float> {
        SIMD4(Float(centerX), Float(centerY), Float(zoom), Float(rollDegrees * .pi / 180))
    }
}

enum EnvironmentReflectionFramerError: LocalizedError {
    case invalidContract
    case metalUnavailable
    case commandFailed

    var errorDescription: String? {
        switch self {
        case .invalidContract: "El encuadre del reflejo no es válido."
        case .metalUnavailable: "No se puede crear el reproyector Metal del entorno."
        case .commandFailed: "No se pudo reproyectar el entorno."
        }
    }
}

@MainActor
final class EnvironmentReflectionReprojector {
    private struct Parameters {
        var cameraPosition: SIMD4<Float>
        var screenPositionWidth: SIMD4<Float>
        var screenQuaternion: SIMD4<Float>
        var screenHeight: SIMD4<Float>
        var framing: SIMD4<Float>
        var sourceRotation: SIMD4<Float>
        var raster: SIMD4<UInt32>
    }

    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let sampler: MTLSamplerState

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else {
            throw EnvironmentReflectionFramerError.metalUnavailable
        }
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let function = library.makeFunction(name: "reproject_environment") else {
            throw EnvironmentReflectionFramerError.metalUnavailable
        }
        pipeline = try device.makeComputePipelineState(function: function)
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw EnvironmentReflectionFramerError.metalUnavailable
        }
        self.queue = queue
        self.sampler = sampler
    }

    func render(
        source: StudioColorMetalFrame,
        device definition: DeviceDefinition,
        pipeline authored: PhysicalPipelineAuthoringState,
        framing: EnvironmentReflectionFraming
    ) throws -> StudioColorMetalFrame {
        guard source.width == source.height * 2,
              authored.cameraPose.position.count == 3,
              authored.screenPose.position.count == 3,
              authored.screenPose.quaternion.count == 4,
              framing.zoom.isFinite, framing.zoom > 0
        else { throw EnvironmentReflectionFramerError.invalidContract }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: source.width, height: source.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let output = source.texture.device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
        else { throw EnvironmentReflectionFramerError.metalUnavailable }
        var parameters = Parameters(
            cameraPosition: SIMD4(
                Float(authored.cameraPose.position[0]), Float(authored.cameraPose.position[1]),
                Float(authored.cameraPose.position[2]), 0
            ),
            screenPositionWidth: SIMD4(
                Float(authored.screenPose.position[0]), Float(authored.screenPose.position[1]),
                Float(authored.screenPose.position[2]), Float(definition.activeWidthMeters)
            ),
            screenQuaternion: SIMD4(
                Float(authored.screenPose.quaternion[0]), Float(authored.screenPose.quaternion[1]),
                Float(authored.screenPose.quaternion[2]), Float(authored.screenPose.quaternion[3])
            ),
            screenHeight: SIMD4(Float(definition.activeHeightMeters), 0, 0, 0),
            framing: framing.shaderValue,
            sourceRotation: SIMD4(
                Float(authored.environment.rotationXDegrees * .pi / 180),
                Float(authored.environment.rotationYDegrees * .pi / 180), 0, 0
            ),
            raster: SIMD4(UInt32(source.width), UInt32(source.height), 0, 0)
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source.texture, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setSamplerState(sampler, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(
            MTLSize(width: source.width, height: source.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw EnvironmentReflectionFramerError.commandFailed
        }
        return StudioColorMetalFrame(texture: output)
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Parameters {
        float4 camera_position;
        float4 screen_position_width;
        float4 screen_quaternion;
        float4 screen_height;
        float4 framing;
        float4 source_rotation;
        uint4 raster;
    };

    inline float3 rotate_q(float4 q, float3 v) {
        const float3 t = 2.0f * cross(q.xyz, v);
        return v + q.w * t + cross(q.xyz, t);
    }

    inline float3 rotate_environment(float3 d, float rx, float ry) {
        const float sy = sin(ry), cy = cos(ry);
        d = float3(d.x * cy + d.z * sy, d.y, -d.x * sy + d.z * cy);
        const float sx = sin(rx), cx = cos(rx);
        return float3(d.x, d.y * cx - d.z * sx, d.y * sx + d.z * cx);
    }

    inline float2 direction_uv(float3 d) {
        d = normalize(d);
        return float2(atan2(d.x, d.z) / (2.0f * M_PI_F) + 0.5f,
            0.5f - asin(clamp(d.y, -1.0f, 1.0f)) / M_PI_F);
    }

    inline float3 uv_direction(float2 uv) {
        const float longitude = (uv.x - 0.5f) * (2.0f * M_PI_F);
        const float latitude = (0.5f - uv.y) * M_PI_F;
        const float c = cos(latitude);
        return float3(sin(longitude) * c, sin(latitude), cos(longitude) * c);
    }

    inline float2 framed_uv(float2 panel, constant Parameters& p) {
        const float angle = -p.framing.w;
        const float sn = sin(angle), cs = cos(angle);
        const float2 q = panel - 0.5f;
        const float2 rotated = float2(q.x * cs - q.y * sn, q.x * sn + q.y * cs);
        float2 uv = p.framing.xy + rotated / p.framing.z;
        uv.x = fract(uv.x);
        uv.y = clamp(uv.y, 0.0f, 1.0f);
        return uv;
    }

    kernel void reproject_environment(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        sampler linear_sampler [[sampler(0)]],
        constant Parameters& p [[buffer(0)]],
        uint2 pixel [[thread_position_in_grid]]
    ) {
        if (any(pixel >= p.raster.xy)) return;
        const float2 uv = (float2(pixel) + 0.5f) / float2(p.raster.xy);
        const float3 environment_direction = uv_direction(uv);
        const float3 screen_right = rotate_q(p.screen_quaternion, float3(1, 0, 0));
        const float3 screen_up = rotate_q(p.screen_quaternion, float3(0, 1, 0));
        const float3 normal = rotate_q(p.screen_quaternion, float3(0, 0, 1));
        const float3 camera_ray = reflect(environment_direction, normal);
        const float denominator = dot(camera_ray, normal);
        float4 value = source.sample(
            linear_sampler,
            direction_uv(rotate_environment(
                environment_direction, p.source_rotation.x, p.source_rotation.y
            ))
        );
        if (abs(denominator) > 1.0e-8f) {
            const float distance = dot(
                p.screen_position_width.xyz - p.camera_position.xyz, normal
            ) / denominator;
            if (distance > 0.0f) {
                const float3 point = p.camera_position.xyz + camera_ray * distance;
                const float3 relative = point - p.screen_position_width.xyz;
                const float2 panel = float2(
                    dot(relative, screen_right) / p.screen_position_width.w + 0.5f,
                    0.5f - dot(relative, screen_up) / p.screen_height.x
                );
                if (all(panel >= 0.0f) && all(panel <= 1.0f)) {
                    value = source.sample(linear_sampler, framed_uv(panel, p));
                }
            }
        }
        value.a = 1.0f;
        output.write(value, pixel);
    }
    """#
}

@MainActor
final class EnvironmentReflectionFramingPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    private var panel: NSPanel?
    private weak var model: WorkspaceModel?

    func toggle(model: WorkspaceModel) {
        if panel?.isVisible == true { hide(model: model); return }
        self.model = model
        model.setEnvironmentReflectionFramingEnabled(true)
        let content = EnvironmentReflectionFramingPanel(model: model)
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 370, height: 300),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered, defer: false
            )
            panel.title = "Encuadrar reflejo"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            self.panel = panel
        }
        panel?.contentView = NSHostingView(rootView: content)
        panel?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide(model: WorkspaceModel) {
        model.setEnvironmentReflectionFramingEnabled(false)
        panel?.orderOut(nil)
        isVisible = false
    }

    func windowWillClose(_ notification: Notification) {
        model?.setEnvironmentReflectionFramingEnabled(false)
        isVisible = false
    }
}

private struct EnvironmentReflectionFramingPanel: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Encuadra el panorama en plano sobre el Device. Al generar se reproyecta a un EXR 2:1 para la cámara y pantalla actuales.")
                .font(.caption).foregroundStyle(.secondary)
            if model.environmentReflectionFramingEnabled {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                    row("Centro X", value: model.environmentReflectionFraming.centerX, range: 0 ... 1) {
                        model.updateEnvironmentReflectionFraming(centerX: $0)
                    }
                    row("Centro Y", value: model.environmentReflectionFraming.centerY, range: 0 ... 1) {
                        model.updateEnvironmentReflectionFraming(centerY: $0)
                    }
                    row("Zoom", value: model.environmentReflectionFraming.zoom, range: 0.1 ... 20) {
                        model.updateEnvironmentReflectionFraming(zoom: $0)
                    }
                    row("Rotación Z", value: model.environmentReflectionFraming.rollDegrees, range: -180 ... 180) {
                        model.updateEnvironmentReflectionFraming(rollDegrees: $0)
                    }
                }
                Text("MMB: desplazar · Alt+MMB: rotar · Shift+MMB o rueda: zoom")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Restablecer") { model.resetEnvironmentReflectionFraming() }
                    Spacer()
                    Button("Generar y usar") {
                        Task { await model.generateAndUseFramedEnvironment() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.environmentReflectionFramingIsGenerating)
                }
            } else {
                Text("El EXR reproyectado está activo. Puedes volver a encuadrar conservando la fuente original de esta sesión.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Volver a encuadrar") {
                    model.setEnvironmentReflectionFramingEnabled(true)
                }
            }
            if model.environmentReflectionFramingIsGenerating { ProgressView().controlSize(.small) }
        }
        .padding(16)
        .frame(width: 370)
    }

    private func row(
        _ label: String, value: Double, range: ClosedRange<Double>,
        update: @escaping (Double) -> Void
    ) -> some View {
        let binding = Binding(get: { value }, set: { update(min(range.upperBound, max(range.lowerBound, $0))) })
        return GridRow {
            Text(label)
            Slider(value: binding, in: range)
            TextField(label, value: binding, format: .number.precision(.fractionLength(0 ... 3)))
                .textFieldStyle(.roundedBorder).frame(width: 74).monospacedDigit()
        }
    }
}
