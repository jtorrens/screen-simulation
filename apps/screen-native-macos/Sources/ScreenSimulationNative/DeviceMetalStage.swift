import Metal
import StudioColor

@MainActor
final class DeviceMetalStage {
    private struct Uniforms {
        var matrixRow0: SIMD4<Float>
        var matrixRow1: SIMD4<Float>
        var matrixRow2: SIMD4<Float>
        var levels: SIMD4<Float>
        var geometry: SIMD4<Float>
    }

    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let sampler: MTLSamplerState
    private let deviceSignalTransform = StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-srgb-sdr-100"
    }!

    init(device: MTLDevice = MTLCreateSystemDefaultDevice()!) throws {
        guard let queue = device.makeCommandQueue() else {
            throw DeviceMetalError.unavailableQueue
        }
        guard let url = Bundle.module.url(
            forResource: "DeviceStage",
            withExtension: "metal"
        ) else {
            throw DeviceMetalError.missingShader
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "evaluateDeviceStage") else {
            throw DeviceMetalError.missingShader
        }
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToZero
        samplerDescriptor.tAddressMode = .clampToZero
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw DeviceMetalError.textureCreation
        }
        self.sampler = sampler
    }

    func process(
        _ frame: StudioColorMetalFrame,
        device resolvedDevice: ResolvedDevice,
        amount: Double,
        placement: WorkspaceModel.SourcePlacement,
        color: StudioColorMetalDisplay
    ) throws -> StudioColorMetalFrame {
        let amount = min(1, max(0, amount))
        guard amount > 0 else {
            return frame
        }
        let parameters = try resolvedDevice.metalEvaluationParameters()
        let deviceCode = try color.transformToMetalFrame(
            frame,
            output: deviceSignalTransform
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: resolvedDevice.definition.nativeWidth,
            height: resolvedDevice.definition.nativeHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let target = frame.texture.device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
        else {
            throw DeviceMetalError.textureCreation
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(frame.texture, index: 0)
        encoder.setTexture(deviceCode.texture, index: 1)
        encoder.setTexture(target, index: 2)
        var uniforms = Uniforms(
            matrixRow0: SIMD4(
                parameters.nativeToACEScg[0],
                parameters.nativeToACEScg[1],
                parameters.nativeToACEScg[2],
                0
            ),
            matrixRow1: SIMD4(
                parameters.nativeToACEScg[3],
                parameters.nativeToACEScg[4],
                parameters.nativeToACEScg[5],
                0
            ),
            matrixRow2: SIMD4(
                parameters.nativeToACEScg[6],
                parameters.nativeToACEScg[7],
                parameters.nativeToACEScg[8],
                0
            ),
            levels: SIMD4(
                parameters.eotfGamma,
                parameters.blackLevelNits,
                parameters.whiteLevelNits,
                Float(amount)
            ),
            geometry: SIMD4(
                Float(frame.width) / Float(frame.height),
                Float(resolvedDevice.definition.nativeWidth)
                    / Float(resolvedDevice.definition.nativeHeight),
                placement.metalIndex,
                Float(resolvedDevice.definition.nativeWidth)
                    / Float(frame.width)
            )
        )
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<Uniforms>.stride,
            index: 0
        )
        encoder.setSamplerState(sampler, index: 0)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: target.width, height: target.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw DeviceMetalError.commandFailure
        }
        return StudioColorMetalFrame(texture: target)
    }
}

enum DeviceMetalError: Error, LocalizedError {
    case unavailableQueue
    case missingShader
    case textureCreation
    case commandFailure

    var errorDescription: String? {
        switch self {
        case .unavailableQueue: "No se ha podido crear la cola Metal de Device."
        case .missingShader: "Falta el shader Metal autoritativo de Device."
        case .textureCreation: "No se ha podido crear la textura física de Device."
        case .commandFailure: "La evaluación Metal de Device ha fallado."
        }
    }
}
