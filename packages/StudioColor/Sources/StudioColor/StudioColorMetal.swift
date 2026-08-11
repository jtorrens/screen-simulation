import CoreGraphics
import CoreVideo
import Metal
import MetalKit
import QuartzCore

private final class StudioColorCompletionTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var milliseconds = 0.0
    private var lastSubmittedAt: CFTimeInterval = 0

    func store(_ value: Double, submittedAt: CFTimeInterval) {
        lock.lock()
        if submittedAt > lastSubmittedAt {
            milliseconds = value
            lastSubmittedAt = submittedAt
        }
        lock.unlock()
    }

    func load() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return milliseconds
    }
}

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

public final class StudioColorMetalFrame: @unchecked Sendable {
    public let texture: MTLTexture
    fileprivate let submittedAt: CFTimeInterval
    public var width: Int { texture.width }
    public var height: Int { texture.height }

    public init(texture: MTLTexture, submittedAt: CFTimeInterval = CACurrentMediaTime()) {
        self.texture = texture
        self.submittedAt = submittedAt
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
    private let yuv420Pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private var resources: [String: Resources] = [:]
    private var sourcePipelines: [String: MTLRenderPipelineState] = [:]
    private var frame: StudioColorLinearFrame?
    private var metalFrame: StudioColorMetalFrame?
    private var output = StudioColorOutputTransform.catalog[0]
    private let completionTiming = StudioColorCompletionTiming()
    public var lastCompletedEndToEndMilliseconds: Double { completionTiming.load() }

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
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache
        else { throw StudioColorMetalError.textureCreation }
        self.device = device
        self.queue = queue
        self.engine = engine
        self.compositionSampler = sampler
        self.textureCache = cache
        let yuvLibrary = try device.makeLibrary(source: Self.yuvShaderSource, options: nil)
        guard let yuvFunction = yuvLibrary.makeFunction(name: "rgbaToYUV420") else {
            throw StudioColorMetalError.missingShaderFunction
        }
        yuv420Pipeline = try device.makeComputePipelineState(function: yuvFunction)
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
            layer.wantsExtendedDynamicRangeContent = output.encoding == .rec2100PQ
                || output.encoding == .rec2100HLG
                || output.encoding == .displayP3EDR
            layer.colorspace = output.colorSpace
        }
    }

    /// Resolves and compiles the one authoritative OCIO/Metal display graph
    /// before application state adopts a new viewer transform.
    public func prepare(_ output: StudioColorOutputTransform) throws {
        _ = try displayResources(output, pixelFormat: .rgba16Float)
    }

    public func present(
        _ frame: StudioColorLinearFrame,
        output: StudioColorOutputTransform,
        in view: MTKView
    ) {
        self.frame = frame
        metalFrame = nil
        self.output = output
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = output.colorSpace
            layer.wantsExtendedDynamicRangeContent = output.encoding == .rec2100PQ
                || output.encoding == .rec2100HLG
                || output.encoding == .displayP3EDR
        }
        view.setNeedsDisplay(view.bounds)
    }

    public func present(
        _ frame: StudioColorMetalFrame,
        output: StudioColorOutputTransform,
        in view: MTKView
    ) {
        self.frame = nil
        metalFrame = frame
        self.output = output
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = output.colorSpace
            layer.wantsExtendedDynamicRangeContent = output.encoding == .rec2100PQ
                || output.encoding == .rec2100HLG
                || output.encoding == .displayP3EDR
        }
        view.setNeedsDisplay(view.bounds)
    }

    public func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer()
        else { return }
        do {
            let input: MTLTexture
            if let metalFrame {
                input = metalFrame.texture
            } else if let frame {
                input = try makeInputTexture(frame)
            } else {
                return
            }
            try encode(
                input: input,
                output: drawable.texture,
                pass: pass,
                transform: output,
                command: command,
                fitInputAspect: true
            )
            command.present(drawable)
            if let metalFrame {
                command.addCompletedHandler(Self.completionHandler(
                    timing: completionTiming, submittedAt: metalFrame.submittedAt
                ))
            }
            command.commit()
        } catch {}
    }

    private nonisolated static func completionHandler(
        timing: StudioColorCompletionTiming,
        submittedAt: CFTimeInterval
    ) -> MTLCommandBufferHandler {
        { _ in
            timing.store(
                (CACurrentMediaTime() - submittedAt) * 1_000,
                submittedAt: submittedAt
            )
        }
    }

    /// Uploads encoded RGBA once, then applies the selected IDT on Metal into the
    /// canonical linear ACEScg texture contract.
    public func makeACEScgFrame(
        width: Int,
        height: Int,
        encodedRGBA: [Float],
        input: StudioColorInputTransform,
        alpha: StudioColorAlphaAssociation
    ) throws -> StudioColorMetalFrame {
        let submittedAt = CACurrentMediaTime()
        guard width > 0, height > 0, encodedRGBA.count == width * height * 4 else {
            throw StudioColorError.invalidPixelBuffer
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let source = device.makeTexture(descriptor: descriptor) else {
            throw StudioColorMetalError.textureCreation
        }
        encodedRGBA.withUnsafeBytes {
            source.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float>.size
            )
        }
        return try applyInputTransform(
            source, input: input, alpha: alpha, submittedAt: submittedAt
        )
    }

    /// Converts an IOSurface-backed Apple decoder buffer to encoded RGB and runs
    /// the same IDT used by stills and synthetic sources without CPU readback.
    public func makeACEScgFrame(
        pixelBuffer: CVPixelBuffer,
        input: StudioColorInputTransform,
        alpha: StudioColorAlphaAssociation,
        matrix: StudioColorSignalMatrix,
        range: StudioColorSignalRange
    ) throws -> StudioColorMetalFrame {
        let submittedAt = CACurrentMediaTime()
        let encoded = try makeEncodedRGB(
            pixelBuffer: pixelBuffer, matrix: matrix, range: range
        )
        return try applyInputTransform(
            encoded, input: input, alpha: alpha, submittedAt: submittedAt
        )
    }

    /// Applies the same authoritative input/IDT graph to an existing GPU
    /// texture. This is used for typed encoded diagnostics without a CPU
    /// readback or a second color implementation.
    public func makeACEScgFrame(
        encodedTexture: MTLTexture,
        input: StudioColorInputTransform,
        alpha: StudioColorAlphaAssociation
    ) throws -> StudioColorMetalFrame {
        try applyInputTransform(
            encodedTexture,
            input: input,
            alpha: alpha,
            submittedAt: CACurrentMediaTime()
        )
    }

    public func renderRGBA8(
        _ frame: StudioColorMetalFrame,
        output: StudioColorOutputTransform
    ) throws -> [UInt8] {
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
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        try encode(
            input: frame.texture, output: target, pass: pass,
            transform: output, command: command, fitInputAspect: false
        )
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw StudioColorMetalError.commandFailure }
        var bytes = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        bytes.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!, bytesPerRow: frame.width * 4,
                from: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0
            )
        }
        return bytes
    }

    /// Applies the selected display transform into a 16-bit integer RGBA
    /// raster so diagnostic gradients are not reduced to 8 bits before PNG
    /// encoding.
    public func renderRGBA16(
        _ frame: StudioColorMetalFrame,
        output: StudioColorOutputTransform
    ) throws -> [UInt16] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm,
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
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        try encode(
            input: frame.texture, output: target, pass: pass,
            transform: output, command: command, fitInputAspect: false
        )
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw StudioColorMetalError.commandFailure }
        var words = [UInt16](repeating: 0, count: frame.width * frame.height * 4)
        words.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!, bytesPerRow: frame.width * 4 * MemoryLayout<UInt16>.size,
                from: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0
            )
        }
        return words
    }

    /// Encodes the selected ODT directly into an IOSurface-backed writer buffer.
    public func render(
        _ frame: StudioColorMetalFrame,
        output: StudioColorOutputTransform,
        into pixelBuffer: CVPixelBuffer,
        alpha: StudioColorAlphaAssociation = .premultiplied
    ) throws {
        guard CVPixelBufferGetWidth(pixelBuffer) == frame.width,
              CVPixelBufferGetHeight(pixelBuffer) == frame.height
        else { throw StudioColorMetalError.textureCreation }
        let pixelFormat: MTLPixelFormat
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32BGRA: pixelFormat = .bgra8Unorm
        case kCVPixelFormatType_64RGBAHalf: pixelFormat = .rgba16Float
        default: throw StudioColorMetalError.textureCreation
        }
        let target = try cvTexture(pixelBuffer, format: pixelFormat, plane: 0)
        guard let command = queue.makeCommandBuffer() else {
            throw StudioColorMetalError.unavailableQueue
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        try encode(
            input: frame.texture, output: target, pass: pass,
            transform: output, command: command, fitInputAspect: false,
            outputAlpha: alpha
        )
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw StudioColorMetalError.commandFailure }
    }

    /// Encodes the authoritative ODT directly into a range-specific bi-planar
    /// YUV IOSurface for VideoToolbox. No monitor ICC participates here.
    public func renderYUV420(
        _ frame: StudioColorMetalFrame,
        output: StudioColorOutputTransform,
        into pixelBuffer: CVPixelBuffer,
        matrix: StudioColorSignalMatrix,
        range: StudioColorSignalRange,
        tenBit: Bool
    ) throws {
        guard CVPixelBufferGetWidth(pixelBuffer) == frame.width,
              CVPixelBufferGetHeight(pixelBuffer) == frame.height,
              CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              frame.width.isMultiple(of: 2), frame.height.isMultiple(of: 2)
        else { throw StudioColorMetalError.textureCreation }
        let rgbaDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        rgbaDescriptor.usage = [.renderTarget, .shaderRead]
        rgbaDescriptor.storageMode = .private
        guard let rgba = device.makeTexture(descriptor: rgbaDescriptor),
              let command = queue.makeCommandBuffer()
        else { throw StudioColorMetalError.textureCreation }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = rgba
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        try encode(
            input: frame.texture,
            output: rgba,
            pass: pass,
            transform: output,
            command: command,
            fitInputAspect: false,
            outputAlpha: .ignore
        )
        let y = try cvTexture(
            pixelBuffer,
            format: tenBit ? .r16Unorm : .r8Unorm,
            plane: 0
        )
        let uv = try cvTexture(
            pixelBuffer,
            format: tenBit ? .rg16Unorm : .rg8Unorm,
            plane: 1
        )
        guard let compute = command.makeComputeCommandEncoder() else {
            throw StudioColorMetalError.commandFailure
        }
        compute.setComputePipelineState(yuv420Pipeline)
        compute.setTexture(rgba, index: 0)
        compute.setTexture(y, index: 1)
        compute.setTexture(uv, index: 2)
        var options = SIMD4<UInt32>(
            matrix == .bt2020 ? 1 : 0,
            range == .video ? 1 : 0,
            tenBit ? 1 : 0,
            0
        )
        compute.setBytes(&options, length: MemoryLayout.size(ofValue: options), index: 0)
        let threadWidth = yuv420Pipeline.threadExecutionWidth
        let threadHeight = max(1, yuv420Pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        compute.dispatchThreads(
            MTLSize(width: frame.width / 2, height: frame.height / 2, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        compute.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw StudioColorMetalError.commandFailure }
    }

    /// CPU oracle/readback boundary used only by sequence encoders that cannot
    /// consume IOSurface textures (OpenEXR, DPX and TIFF).
    public func readLinearRGBA(_ frame: StudioColorMetalFrame) throws -> [Float] {
        let readable: MTLTexture
        if frame.texture.storageMode == .shared {
            readable = frame.texture
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: frame.texture.pixelFormat,
                width: frame.width,
                height: frame.height,
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            guard let target = device.makeTexture(descriptor: descriptor),
                  let command = queue.makeCommandBuffer(),
                  let blit = command.makeBlitCommandEncoder()
            else { throw StudioColorMetalError.textureCreation }
            blit.copy(
                from: frame.texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(),
                sourceSize: MTLSize(width: frame.width, height: frame.height, depth: 1),
                to: target,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin()
            )
            blit.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed else {
                throw StudioColorMetalError.commandFailure
            }
            readable = target
        }
        switch readable.pixelFormat {
        case .rgba16Float:
            var half = [Float16](repeating: 0, count: frame.width * frame.height * 4)
            half.withUnsafeMutableBytes {
                readable.getBytes(
                    $0.baseAddress!, bytesPerRow: frame.width * 4 * MemoryLayout<Float16>.size,
                    from: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0
                )
            }
            return half.map(Float.init)
        case .rgba32Float:
            var values = [Float](repeating: 0, count: frame.width * frame.height * 4)
            values.withUnsafeMutableBytes {
                readable.getBytes(
                    $0.baseAddress!, bytesPerRow: frame.width * 4 * MemoryLayout<Float>.size,
                    from: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0
                )
            }
            return values
        default:
            throw StudioColorMetalError.commandFailure
        }
    }

    /// Materializes one immutable cross-domain RGBA16F checkpoint in shared
    /// storage without changing any channel code.
    public func materializeSharedRGBA16F(
        _ frame: StudioColorMetalFrame
    ) throws -> StudioColorMetalFrame {
        guard frame.texture.pixelFormat == .rgba16Float else {
            throw StudioColorMetalError.textureCreation
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder()
        else { throw StudioColorMetalError.textureCreation }
        blit.copy(
            from: frame.texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: frame.width, height: frame.height, depth: 1),
            to: target,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin()
        )
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw StudioColorMetalError.commandFailure
        }
        return StudioColorMetalFrame(texture: target, submittedAt: frame.submittedAt)
    }

    public func renderRGBAFloat(
        _ frame: StudioColorMetalFrame,
        output: StudioColorOutputTransform
    ) throws -> [Float] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: frame.width, height: frame.height, mipmapped: false
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
            input: frame.texture, output: target, pass: pass,
            transform: output, command: command, fitInputAspect: false
        )
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw StudioColorMetalError.commandFailure }
        var half = [Float16](repeating: 0, count: frame.width * frame.height * 4)
        half.withUnsafeMutableBytes {
            target.getBytes(
                $0.baseAddress!, bytesPerRow: frame.width * 4 * MemoryLayout<Float16>.size,
                from: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0
            )
        }
        return half.map(Float.init)
    }

    /// Keeps an ACEScg-to-output processor on GPU and returns its private
    /// texture for a downstream authoritative Metal stage.
    public func transformToMetalFrame(
        _ frame: StudioColorMetalFrame,
        output: StudioColorOutputTransform
    ) throws -> StudioColorMetalFrame {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer()
        else { throw StudioColorMetalError.textureCreation }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        try encode(
            input: frame.texture,
            output: target,
            pass: pass,
            transform: output,
            command: command,
            fitInputAspect: false
        )
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw StudioColorMetalError.commandFailure
        }
        return StudioColorMetalFrame(
            texture: target,
            submittedAt: frame.submittedAt
        )
    }

    private func applyInputTransform(
        _ source: MTLTexture,
        input: StudioColorInputTransform,
        alpha: StudioColorAlphaAssociation,
        submittedAt: CFTimeInterval
    ) throws -> StudioColorMetalFrame {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: source.width, height: source.height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer()
        else { throw StudioColorMetalError.textureCreation }
        let processor: StudioColorProcessor = switch input.processor {
        case let .colorSpace(source):
            try engine.cachedColorSpaceProcessor(
                source: source, destination: "ACEScg"
            )
        case let .inverseDisplay(display, view):
            try engine.cachedInverseDisplayProcessor(
                destination: "ACEScg", display: display, view: view
            )
        }
        let shader = try processor.makeMetalShader(functionName: "studioColorInput")
        let key = "idt:\(input.id):\(alpha.rawValue)"
        let resource: Resources
        if let cached = resources[key] {
            resource = cached
        } else {
            let library = try device.makeLibrary(
                source: Self.inputShaderSource(shader, alpha: alpha), options: nil
            )
            guard let vertex = library.makeFunction(name: "fullscreenVertex"),
                  let fragment = library.makeFunction(name: "inputFragment")
            else { throw StudioColorMetalError.missingShaderFunction }
            let pipeline = MTLRenderPipelineDescriptor()
            pipeline.vertexFunction = vertex
            pipeline.fragmentFunction = fragment
            pipeline.colorAttachments[0].pixelFormat = .rgba16Float
            resource = Resources(
                pipeline: try device.makeRenderPipelineState(descriptor: pipeline),
                textures: try shader.textures.map { try makeTexture($0) },
                samplers: try shader.textures.map { try makeSampler($0.interpolation) }
            )
            resources[key] = resource
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw StudioColorMetalError.commandFailure
        }
        encoder.setRenderPipelineState(resource.pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(compositionSampler, index: 0)
        for index in resource.textures.indices {
            encoder.setFragmentTexture(resource.textures[index], index: index + 1)
            encoder.setFragmentSamplerState(resource.samplers[index], index: index + 1)
        }
        var presentation = SIMD4<Float>(1, 1, 0, 0)
        encoder.setVertexBytes(&presentation, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        command.commit()
        return StudioColorMetalFrame(texture: target, submittedAt: submittedAt)
    }

    private func makeEncodedRGB(
        pixelBuffer: CVPixelBuffer,
        matrix: StudioColorSignalMatrix,
        range: StudioColorSignalRange
    ) throws -> MTLTexture {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false
        )
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        outputDescriptor.storageMode = .private
        guard let output = device.makeTexture(descriptor: outputDescriptor),
              let command = queue.makeCommandBuffer()
        else { throw StudioColorMetalError.textureCreation }
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        let packedYUVA = CVPixelBufferGetPixelFormatType(pixelBuffer)
            == kCVPixelFormatType_4444AYpCbCr16
        let sourceKind = planar ? "planar-yuv" : (packedYUVA ? "packed-yuva" : "rgb")
        let key = "decode:\(sourceKind):\(matrix.rawValue):\(range.rawValue)"
        let pipeline: MTLRenderPipelineState
        if let cached = sourcePipelines[key] {
            pipeline = cached
        } else {
            let library = try device.makeLibrary(source: Self.sourceShaderSource, options: nil)
            let fragmentName = planar ? "yuvFragment"
                : (packedYUVA ? "packedYuvaFragment" : "rgbFragment")
            guard let vertex = library.makeFunction(name: "sourceVertex"),
                  let fragment = library.makeFunction(name: fragmentName)
            else { throw StudioColorMetalError.missingShaderFunction }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            sourcePipelines[key] = pipeline
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw StudioColorMetalError.commandFailure
        }
        encoder.setRenderPipelineState(pipeline)
        if planar {
            let is10Bit = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                || CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            let luma = try cvTexture(pixelBuffer, format: is10Bit ? .r16Unorm : .r8Unorm, plane: 0)
            let chroma = try cvTexture(pixelBuffer, format: is10Bit ? .rg16Unorm : .rg8Unorm, plane: 1)
            encoder.setFragmentTexture(luma, index: 0)
            encoder.setFragmentTexture(chroma, index: 1)
            encoder.setFragmentSamplerState(compositionSampler, index: 0)
            var coefficients = Self.yuvCoefficients(
                matrix: matrix, range: range, bitDepth: is10Bit ? 10 : 8
            )
            encoder.setFragmentBytes(&coefficients.luma, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentBytes(&coefficients.chroma, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        } else if packedYUVA {
            encoder.setFragmentTexture(
                try cvTexture(pixelBuffer, format: .rgba16Unorm, plane: 0),
                index: 0
            )
            encoder.setFragmentSamplerState(compositionSampler, index: 0)
            var coefficients = Self.yuvCoefficients(
                matrix: matrix, range: range, bitDepth: 12
            )
            encoder.setFragmentBytes(
                &coefficients.luma,
                length: MemoryLayout<SIMD4<Float>>.stride,
                index: 0
            )
            encoder.setFragmentBytes(
                &coefficients.chroma,
                length: MemoryLayout<SIMD2<Float>>.stride,
                index: 1
            )
        } else {
            let format: MTLPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
                == kCVPixelFormatType_64RGBAHalf ? .rgba16Float : .bgra8Unorm
            encoder.setFragmentTexture(try cvTexture(pixelBuffer, format: format, plane: 0), index: 0)
            encoder.setFragmentSamplerState(compositionSampler, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        command.commit()
        return output
    }

    private func cvTexture(
        _ pixelBuffer: CVPixelBuffer, format: MTLPixelFormat, plane: Int
    ) throws -> MTLTexture {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        var reference: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, format, width, height, plane, &reference
        ) == kCVReturnSuccess,
              let reference, let texture = CVMetalTextureGetTexture(reference)
        else { throw StudioColorMetalError.textureCreation }
        return texture
    }

    private static func yuvCoefficients(
        matrix: StudioColorSignalMatrix,
        range: StudioColorSignalRange,
        bitDepth: Int
    ) -> (luma: SIMD4<Float>, chroma: SIMD2<Float>) {
        let kr: Float
        let kb: Float
        switch matrix {
        case .bt601: (kr, kb) = (0.299, 0.114)
        case .bt709: (kr, kb) = (0.2126, 0.0722)
        case .bt2020: (kr, kb) = (0.2627, 0.0593)
        }
        // CoreVideo stores 10/12-bit integer samples left-aligned in 16-bit
        // words. An r16/rgba16 UNORM Metal texture therefore normalizes by
        // 65535, not by the nominal (2^bits)-1 code maximum.
        let maximum: Float = bitDepth > 8
            ? 65_535 / Float(1 << (16 - bitDepth))
            : 255
        let scale: Float = Float(1 << max(0, bitDepth - 8))
        let yOffset: Float = range == .video ? 16 * scale / maximum : 0
        let yScale: Float = range == .video ? maximum / (219 * scale) : 1
        let chromaOffset: Float = range == .video
            ? 128 * scale / maximum
            : 128 * scale / maximum
        let chromaScale: Float = range == .video
            ? maximum / (224 * scale)
            : 1
        return (SIMD4(kr, kb, yOffset, yScale), SIMD2(chromaOffset, chromaScale))
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
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        try encode(
            input: input,
            output: target,
            pass: pass,
            transform: output,
            command: command,
            fitInputAspect: false
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
        command: MTLCommandBuffer,
        fitInputAspect: Bool,
        outputAlpha: StudioColorAlphaAssociation = .premultiplied
    ) throws {
        let resources = try displayResources(
            transform, pixelFormat: output.pixelFormat, alpha: outputAlpha
        )
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
        if fitInputAspect {
            let inputAspect = Float(input.width) / Float(input.height)
            let outputAspect = Float(output.width) / Float(output.height)
            if outputAspect > inputAspect {
                presentation.x = inputAspect / outputAspect
            } else {
                presentation.y = outputAspect / inputAspect
            }
        }
        encoder.setVertexBytes(
            &presentation,
            length: MemoryLayout<SIMD4<Float>>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    private func displayResources(
        _ transform: StudioColorOutputTransform,
        pixelFormat: MTLPixelFormat,
        alpha: StudioColorAlphaAssociation = .premultiplied
    ) throws -> Resources {
        let key = "\(transform.id):\(pixelFormat.rawValue):\(alpha.rawValue)"
        if let cached = resources[key] { return cached }
        let processor: StudioColorProcessor = switch transform.processor {
        case let .displayView(display, view):
            try engine.cachedDisplayProcessor(
                source: "ACEScg", display: display, view: view
            )
        case let .colorSpace(destination):
            try engine.cachedColorSpaceProcessor(
                source: "ACEScg", destination: destination
            )
        }
        let shader = try processor.makeMetalShader()
        let library = try device.makeLibrary(
            source: Self.displayShaderSource(shader, alpha: alpha),
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

    private static func displayShaderSource(
        _ shader: StudioColorMetalShader,
        alpha: StudioColorAlphaAssociation
    ) -> String {
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
        let alphaOutput: String = switch alpha {
        case .premultiplied:
            "color.rgb *= alpha; color.a = alpha;"
        case .straight:
            "color.a = alpha;"
        case .ignore:
            "color.a = 1.0;"
        }
        return """
        #include <metal_stdlib>
        using namespace metal;
        struct FullscreenOutput { float4 position [[position]]; float2 textureCoordinate; };
        vertex FullscreenOutput fullscreenVertex(uint vertexID [[vertex_id]], constant float4 &presentation [[buffer(0)]]) {
            constexpr float2 positions[6] = {
                float2(-1.0,-1.0), float2(1.0,-1.0), float2(-1.0,1.0),
                float2(-1.0,1.0), float2(1.0,-1.0), float2(1.0,1.0)
            };
            constexpr float2 coordinates[6] = {
                float2(0.0,1.0), float2(1.0,1.0), float2(0.0,0.0),
                float2(0.0,0.0), float2(1.0,1.0), float2(1.0,0.0)
            };
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
            \(alphaOutput)
            return color;
        }
        """
    }

    private static func inputShaderSource(
        _ shader: StudioColorMetalShader,
        alpha: StudioColorAlphaAssociation
    ) -> String {
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
        let alphaPreparation: String = switch alpha {
        case .ignore: "color.a = 1.0;"
        case .straight: ""
        case .premultiplied: "if (color.a > 0.0) { color.rgb /= color.a; } else { color.rgb = 0.0; }"
        }
        return """
        #include <metal_stdlib>
        using namespace metal;
        struct FullscreenOutput { float4 position [[position]]; float2 textureCoordinate; };
        vertex FullscreenOutput fullscreenVertex(uint vertexID [[vertex_id]], constant float4 &presentation [[buffer(0)]]) {
            constexpr float2 positions[6] = {
                float2(-1.0,-1.0), float2(1.0,-1.0), float2(-1.0,1.0),
                float2(-1.0,1.0), float2(1.0,-1.0), float2(1.0,1.0)
            };
            constexpr float2 coordinates[6] = {
                float2(0.0,1.0), float2(1.0,1.0), float2(0.0,0.0),
                float2(0.0,0.0), float2(1.0,1.0), float2(1.0,0.0)
            };
            FullscreenOutput output;
            output.position = float4(positions[vertexID], 0.0, 1.0);
            output.textureCoordinate = coordinates[vertexID];
            return output;
        }
        \(shader.source)
        fragment float4 inputFragment(FullscreenOutput input [[stage_in]], texture2d<float> source [[texture(0)]], sampler sourceSampler [[sampler(0)]] \(suffix)) {
            float4 color = source.sample(sourceSampler, input.textureCoordinate);
            \(alphaPreparation)
            float alpha = color.a;
            color = \(shader.functionName)(\(prefix)color);
            color.rgb *= alpha;
            color.a = alpha;
            return color;
        }
        """
    }

    private static let yuvShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void rgbaToYUV420(
        texture2d<half, access::read> rgba [[texture(0)]],
        texture2d<float, access::write> yPlane [[texture(1)]],
        texture2d<float, access::write> uvPlane [[texture(2)]],
        constant uint4 &options [[buffer(0)]],
        uint2 chromaPosition [[thread_position_in_grid]]
    ) {
        if (chromaPosition.x >= uvPlane.get_width()
            || chromaPosition.y >= uvPlane.get_height()) {
            return;
        }
        const float kr = options.x == 1 ? 0.2627 : 0.2126;
        const float kb = options.x == 1 ? 0.0593 : 0.0722;
        const float kg = 1.0 - kr - kb;
        const bool videoRange = options.y == 1;
        const bool tenBit = options.z == 1;
        const float maxCode = tenBit ? 1023.0 : 255.0;
        const float yOffset = videoRange ? (tenBit ? 64.0 : 16.0) : 0.0;
        const float yScale = videoRange ? (tenBit ? 876.0 : 219.0) : maxCode;
        const float cOffset = tenBit ? 512.0 : 128.0;
        const float cScale = videoRange
            ? (tenBit ? 896.0 : 224.0)
            : maxCode;
        float cbSum = 0.0;
        float crSum = 0.0;
        for (uint offsetY = 0; offsetY < 2; ++offsetY) {
            for (uint offsetX = 0; offsetX < 2; ++offsetX) {
                const uint2 position = chromaPosition * 2 + uint2(offsetX, offsetY);
                const float3 rgb = clamp(float3(rgba.read(position).rgb), 0.0, 1.0);
                const float luma = kr * rgb.r + kg * rgb.g + kb * rgb.b;
                const float cb = (rgb.b - luma) / (2.0 * (1.0 - kb));
                const float cr = (rgb.r - luma) / (2.0 * (1.0 - kr));
                const float yCode = clamp(yOffset + yScale * luma, 0.0, maxCode);
                yPlane.write(float4(yCode / maxCode), position);
                cbSum += cb;
                crSum += cr;
            }
        }
        const float cbCode = clamp(cOffset + cScale * cbSum * 0.25, 0.0, maxCode);
        const float crCode = clamp(cOffset + cScale * crSum * 0.25, 0.0, maxCode);
        uvPlane.write(float4(cbCode / maxCode, crCode / maxCode, 0.0, 1.0), chromaPosition);
    }
    """

    private static let sourceShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct SourceOutput { float4 position [[position]]; float2 uv; };
    vertex SourceOutput sourceVertex(uint vertexID [[vertex_id]]) {
        constexpr float2 positions[6] = {
            float2(-1.0,-1.0), float2(1.0,-1.0), float2(-1.0,1.0),
            float2(-1.0,1.0), float2(1.0,-1.0), float2(1.0,1.0)
        };
        constexpr float2 coordinates[6] = {
            float2(0.0,1.0), float2(1.0,1.0), float2(0.0,0.0),
            float2(0.0,0.0), float2(1.0,1.0), float2(1.0,0.0)
        };
        return SourceOutput { float4(positions[vertexID], 0.0, 1.0), coordinates[vertexID] };
    }
    fragment float4 rgbFragment(
        SourceOutput input [[stage_in]],
        texture2d<float> source [[texture(0)]], sampler sourceSampler [[sampler(0)]]) {
        return source.sample(sourceSampler, input.uv);
    }
    fragment float4 yuvFragment(
        SourceOutput input [[stage_in]], texture2d<float> luma [[texture(0)]],
        texture2d<float> chroma [[texture(1)]], sampler sourceSampler [[sampler(0)]],
        constant float4 &lumaParameters [[buffer(0)]],
        constant float2 &chromaParameters [[buffer(1)]]) {
        float y = (luma.sample(sourceSampler, input.uv).r - lumaParameters.z) * lumaParameters.w;
        float2 cbcr = (chroma.sample(sourceSampler, input.uv).rg - chromaParameters.x) * chromaParameters.y;
        float kr = lumaParameters.x;
        float kb = lumaParameters.y;
        float kg = 1.0 - kr - kb;
        float r = y + 2.0 * (1.0 - kr) * cbcr.y;
        float b = y + 2.0 * (1.0 - kb) * cbcr.x;
        float g = (y - kr * r - kb * b) / kg;
        return float4(r, g, b, 1.0);
    }
    fragment float4 packedYuvaFragment(
        SourceOutput input [[stage_in]],
        texture2d<float> source [[texture(0)]], sampler sourceSampler [[sampler(0)]],
        constant float4 &lumaParameters [[buffer(0)]],
        constant float2 &chromaParameters [[buffer(1)]]) {
        const float4 aycbcr = source.sample(sourceSampler, input.uv);
        const float y = (aycbcr.g - lumaParameters.z) * lumaParameters.w;
        const float2 cbcr = (aycbcr.ba - chromaParameters.x) * chromaParameters.y;
        const float kr = lumaParameters.x;
        const float kb = lumaParameters.y;
        const float kg = 1.0 - kr - kb;
        const float r = y + 2.0 * (1.0 - kr) * cbcr.y;
        const float b = y + 2.0 * (1.0 - kb) * cbcr.x;
        const float g = (y - kr * r - kb * b) / kg;
        return float4(r, g, b, aycbcr.r);
    }
    """

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
