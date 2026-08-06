import CoreGraphics
import Metal
import MetalKit
import QuartzCore

public enum StudioColorMetalError: Error, LocalizedError {
    case unavailableDevice
    case unavailableQueue
    case textureCreation
    case missingShaderFunction
    case commandFailure

    public var errorDescription: String? {
        switch self {
        case .unavailableDevice: "Metal no está disponible."
        case .unavailableQueue: "No se ha podido crear la cola Metal."
        case .textureCreation: "No se ha podido crear una textura Metal."
        case .missingShaderFunction: "Falta una función del shader StudioColor."
        case .commandFailure: "La transformación StudioColor Metal ha fallado."
        }
    }
}

/// Exact extraction of the CREDITOS-HDR OCIO-generated-MSL display boundary.
/// Resources are cached by the complete output transform and pixel format.
@MainActor
public final class StudioColorMetalDisplay: NSObject, MTKViewDelegate, @unchecked Sendable {
    private struct Resources {
        let pipeline: MTLRenderPipelineState
        let textures: [MTLTexture]
        let samplers: [MTLSamplerState]
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let engine: StudioColorEngine
    private let compositionSampler: MTLSamplerState
    private var resources: [String: Resources] = [:]
    private var frame: StudioColorLinearFrame?
    private var output = StudioColorOutputTransform.catalog[0]

    public init(engine: StudioColorEngine = try! .bundled()) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw StudioColorMetalError.unavailableDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw StudioColorMetalError.unavailableQueue
        }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw StudioColorMetalError.textureCreation
        }
        self.device = device
        self.queue = queue
        self.engine = engine
        self.compositionSampler = sampler
        super.init()
    }

    public func configure(_ view: MTKView) {
        view.device = device
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.delegate = self
        view.wantsLayer = true
        if let layer = view.layer as? CAMetalLayer {
            layer.pixelFormat = .rgba16Float
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = output.colorSpace
        }
    }

    public func present(
        _ frame: StudioColorLinearFrame,
        output: StudioColorOutputTransform,
        in view: MTKView
    ) {
        self.frame = frame
        self.output = output
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = output.colorSpace
        }
        view.setNeedsDisplay(view.bounds)
    }

    public func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    public func draw(in view: MTKView) {
        guard let frame,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer()
        else { return }
        do {
            let input = try makeInputTexture(frame)
            try encode(
                input: input,
                output: drawable.texture,
                pass: pass,
                transform: output,
                command: command
            )
            command.present(drawable)
            command.commit()
        } catch {
            assertionFailure(error.localizedDescription)
        }
    }

    public func renderRGBA8(
        _ frame: StudioColorLinearFrame,
        output: StudioColorOutputTransform
    ) throws -> [UInt8] {
        let input = try makeInputTexture(frame)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer()
        else { throw StudioColorMetalError.textureCreation }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        try encode(
            input: input,
            output: target,
            pass: pass,
            transform: output,
            command: command
        )
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw StudioColorMetalError.commandFailure
        }
        var bytes = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        bytes.withUnsafeMutableBytes { storage in
            target.getBytes(
                storage.baseAddress!,
                bytesPerRow: frame.width * 4,
                from: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0
            )
        }
        return bytes
    }

    private func makeInputTexture(_ frame: StudioColorLinearFrame) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw StudioColorMetalError.textureCreation
        }
        frame.premultipliedRGBA.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: frame.width * 4 * MemoryLayout<Float>.size
            )
        }
        return texture
    }

    private func encode(
        input: MTLTexture,
        output: MTLTexture,
        pass: MTLRenderPassDescriptor,
        transform: StudioColorOutputTransform,
        command: MTLCommandBuffer
    ) throws {
        let resources = try displayResources(transform, pixelFormat: output.pixelFormat)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw StudioColorMetalError.commandFailure
        }
        encoder.setRenderPipelineState(resources.pipeline)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentSamplerState(compositionSampler, index: 0)
        for index in resources.textures.indices {
            encoder.setFragmentTexture(resources.textures[index], index: index + 1)
            encoder.setFragmentSamplerState(resources.samplers[index], index: index + 1)
        }
        var presentation = SIMD4<Float>(1, 1, 0, 0)
        encoder.setVertexBytes(
            &presentation,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func displayResources(
        _ transform: StudioColorOutputTransform,
        pixelFormat: MTLPixelFormat
    ) throws -> Resources {
        let key = "\(transform.id):\(pixelFormat.rawValue)"
        if let cached = resources[key] { return cached }
        let processor = try engine.cachedDisplayProcessor(
            source: "ACEScg",
            display: transform.display,
            view: transform.view
        )
        let shader = try processor.makeMetalShader()
        let library = try device.makeLibrary(
            source: Self.displayShaderSource(shader),
            options: nil
        )
        guard let vertex = library.makeFunction(name: "fullscreenVertex"),
              let fragment = library.makeFunction(name: "displayFragment")
        else { throw StudioColorMetalError.missingShaderFunction }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = false
        let result = Resources(
            pipeline: try device.makeRenderPipelineState(descriptor: descriptor),
            textures: try shader.textures.map { try makeTexture($0) },
            samplers: try shader.textures.map { try makeSampler($0.interpolation) }
        )
        resources[key] = result
        return result
    }

    private static func displayShaderSource(_ shader: StudioColorMetalShader) -> String {
        let declarations = shader.textures.indices.map { index in
            let type = switch shader.textures[index].dimension {
            case .one: "texture1d<float>"
            case .two: "texture2d<float>"
            case .three: "texture3d<float>"
            }
            return "\(type) ocioTexture\(index) [[texture(\(index + 1))]], sampler ocioSampler\(index) [[sampler(\(index + 1))]]"
        }
        let suffix = declarations.isEmpty ? "" : ",\n" + declarations.joined(separator: ",\n")
        let arguments = shader.textures.indices.flatMap { ["ocioTexture\($0)", "ocioSampler\($0)"] }
        let prefix = arguments.isEmpty ? "" : arguments.joined(separator: ", ") + ", "
        return """
        #include <metal_stdlib>
        using namespace metal;
        struct FullscreenOutput { float4 position [[position]]; float2 textureCoordinate; };
        vertex FullscreenOutput fullscreenVertex(uint vertexID [[vertex_id]], constant float4 &presentation [[buffer(0)]]) {
            constexpr float2 positions[3] = { float2(-1.0,-1.0), float2(3.0,-1.0), float2(-1.0,3.0) };
            constexpr float2 coordinates[3] = { float2(0.0,1.0), float2(2.0,1.0), float2(0.0,-1.0) };
            FullscreenOutput output;
            output.position = float4(positions[vertexID].x * presentation.x + presentation.z, positions[vertexID].y * presentation.y + presentation.w, 0.0, 1.0);
            output.textureCoordinate = coordinates[vertexID];
            return output;
        }
        \(shader.source)
        fragment float4 displayFragment(FullscreenOutput input [[stage_in]], texture2d<float> composition [[texture(0)]], sampler compositionSampler [[sampler(0)]] \(suffix)) {
            float4 color = composition.sample(compositionSampler, input.textureCoordinate);
            float alpha = color.a;
            if (alpha > 0.0) { color.rgb /= alpha; }
            color = \(shader.functionName)(\(prefix)color);
            color.rgb *= alpha;
            color.a = alpha;
            return color;
        }
        """
    }

    private func makeTexture(_ source: StudioColorTexture) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = source.channelCount == 1 ? .r32Float : .rgba32Float
        descriptor.width = source.width
        descriptor.height = source.height
        descriptor.depth = source.depth
        descriptor.mipmapLevelCount = 1
        descriptor.arrayLength = 1
        descriptor.sampleCount = 1
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        switch source.dimension {
        case .one: descriptor.textureType = .type1D; descriptor.height = 1; descriptor.depth = 1
        case .two: descriptor.textureType = .type2D; descriptor.depth = 1
        case .three: descriptor.textureType = .type3D
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw StudioColorMetalError.textureCreation
        }
        let values: [Float]
        let components: Int
        if source.channelCount == 1 {
            values = source.values
            components = 1
        } else {
            var expanded: [Float] = []
            expanded.reserveCapacity(source.values.count / 3 * 4)
            for index in stride(from: 0, to: source.values.count, by: 3) {
                expanded.append(source.values[index])
                expanded.append(source.values[index + 1])
                expanded.append(source.values[index + 2])
                expanded.append(1)
            }
            values = expanded
            components = 4
        }
        values.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, source.width, source.height, source.depth),
                mipmapLevel: 0,
                slice: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: source.width * components * MemoryLayout<Float>.size,
                bytesPerImage: source.width * source.height * components * MemoryLayout<Float>.size
            )
        }
        return texture
    }

    private func makeSampler(_ interpolation: StudioColorTextureInterpolation) throws -> MTLSamplerState {
        let descriptor = MTLSamplerDescriptor()
        let filter: MTLSamplerMinMagFilter = interpolation == .nearest ? .nearest : .linear
        descriptor.minFilter = filter
        descriptor.magFilter = filter
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        descriptor.rAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw StudioColorMetalError.textureCreation
        }
        return sampler
    }
}
