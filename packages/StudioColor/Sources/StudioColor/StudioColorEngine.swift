import Foundation

#if canImport(StudioColorABI)
import StudioColorABI
#endif

public enum StudioColorError: Error, Equatable, LocalizedError {
    case unavailableOnPlatform
    case missingBundledConfiguration
    case bridge(String)
    case invalidTexture
    case invalidPixelBuffer

    public var errorDescription: String? {
        switch self {
        case .unavailableOnPlatform:
            "StudioColor no está disponible para esta plataforma."
        case .missingBundledConfiguration:
            "No se encuentra la configuración ACES incluida en la aplicación."
        case let .bridge(message):
            "StudioColor: \(message)"
        case .invalidTexture:
            "StudioColor ha generado una textura LUT no válida."
        case .invalidPixelBuffer:
            "El búfer RGBA de StudioColor no es válido."
        }
    }
}

public enum StudioColorTextureDimension: Equatable, Sendable {
    case one
    case two
    case three
}

public enum StudioColorTextureInterpolation: Equatable, Sendable {
    case nearest
    case linear
}

public struct StudioColorTexture: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var depth: Int
    public var channelCount: Int
    public var dimension: StudioColorTextureDimension
    public var interpolation: StudioColorTextureInterpolation
    public var values: [Float]

    public init(
        width: Int,
        height: Int,
        depth: Int,
        channelCount: Int,
        dimension: StudioColorTextureDimension,
        interpolation: StudioColorTextureInterpolation,
        values: [Float]
    ) {
        self.width = width
        self.height = height
        self.depth = depth
        self.channelCount = channelCount
        self.dimension = dimension
        self.interpolation = interpolation
        self.values = values
    }
}

public struct StudioColorMetalShader: Equatable, Sendable {
    public var functionName: String
    public var source: String
    public var textures: [StudioColorTexture]

    public init(
        functionName: String,
        source: String,
        textures: [StudioColorTexture]
    ) {
        self.functionName = functionName
        self.source = source
        self.textures = textures
    }
}

public final class StudioColorProcessor: @unchecked Sendable {
    #if canImport(StudioColorABI)
    private let reference: SCProcessorRef

    fileprivate init(reference: SCProcessorRef) {
        self.reference = reference
    }

    deinit {
        SCProcessorRelease(reference)
    }
    #else
    fileprivate init() {}
    #endif

    public func applying(to color: SIMD4<Float>) throws -> SIMD4<Float> {
        #if canImport(StudioColorABI)
        var values = [color.x, color.y, color.z, color.w]
        _ = try withBridgeError { error in
            SCProcessorApplyRGBA(reference, &values, 1, error)
        }
        return SIMD4(values[0], values[1], values[2], color.w)
        #else
        throw StudioColorError.unavailableOnPlatform
        #endif
    }

    public func apply(toRGBA values: inout [Float]) throws {
        guard values.count.isMultiple(of: 4) else {
            throw StudioColorError.invalidPixelBuffer
        }
        #if canImport(StudioColorABI)
        let pixelCount = values.count / 4
        _ = try values.withUnsafeMutableBufferPointer { buffer in
            try withBridgeError { error in
                SCProcessorApplyRGBA(
                    reference,
                    buffer.baseAddress,
                    pixelCount,
                    error
                )
            }
        }
        #else
        throw StudioColorError.unavailableOnPlatform
        #endif
    }

    public func makeMetalShader(
        functionName: String = "studioColorDisplay"
    ) throws -> StudioColorMetalShader {
        #if canImport(StudioColorABI)
        var error: UnsafeMutablePointer<CChar>?
        guard let sourcePointer = functionName.withCString({ name in
            SCProcessorCopyMSLShader(reference, name, &error)
        }) else {
            throw consumeBridgeError(error)
        }
        defer { SCFreeString(sourcePointer) }
        let source = String(cString: sourcePointer)
        let textureCount: Int = try withBridgeError { bridgeError in
            let count = SCProcessorTextureCount(reference, bridgeError)
            return Int(count)
        }
        var textures: [StudioColorTexture] = []
        textures.reserveCapacity(textureCount)
        for index in 0 ..< textureCount {
            var info = SCTextureInfo()
            _ = try withBridgeError { bridgeError in
                SCProcessorTextureInfoAtIndex(
                    reference,
                    index,
                    &info,
                    bridgeError
                )
            }
            guard
                info.width > 0,
                info.height > 0,
                info.depth > 0,
                info.channelCount == 1 || info.channelCount == 3,
                let valuesPointer = info.values
            else {
                throw StudioColorError.invalidTexture
            }
            let values = Array(
                UnsafeBufferPointer(
                    start: valuesPointer,
                    count: info.valueCount
                )
            )
            let dimension: StudioColorTextureDimension
            switch info.dimension {
            case SCTextureDimension1D:
                dimension = .one
            case SCTextureDimension2D:
                dimension = .two
            case SCTextureDimension3D:
                dimension = .three
            default:
                throw StudioColorError.invalidTexture
            }
            textures.append(
                StudioColorTexture(
                    width: Int(info.width),
                    height: Int(info.height),
                    depth: Int(info.depth),
                    channelCount: Int(info.channelCount),
                    dimension: dimension,
                    interpolation: info.interpolation
                        == SCTextureInterpolationNearest ? .nearest : .linear,
                    values: values
                )
            )
        }
        return StudioColorMetalShader(
            functionName: functionName,
            source: source,
            textures: textures
        )
        #else
        throw StudioColorError.unavailableOnPlatform
        #endif
    }
}

public final class StudioColorEngine: @unchecked Sendable {
    public static let libraryVersion = "2.5.2"
    public static let configurationVersion = "4.0.0"
    public static let configurationFileName =
        "studio-config-v4.0.0_aces-v2.0_ocio-v2.5"
    /// The exact OCIO configuration used by the application. Interchange writers copy this
    /// self-contained config when a downstream host must reproduce an authored IDT.
    public static func bundledConfigurationURL() throws -> URL {
        try bundledConfigurationURL(named: configurationFileName)
    }

    private static func bundledConfigurationURL(named fileName: String) throws -> URL {
        #if DEBUG
        let resourceBundle = Bundle.module
        #else
        guard let resourceURL = Bundle.main.resourceURL,
              let resourceBundle = Bundle(
                url: resourceURL.appendingPathComponent("StudioColor_StudioColor.bundle")
              )
        else { throw StudioColorError.missingBundledConfiguration }
        #endif
        guard let configurationURL = resourceBundle.url(
            forResource: fileName,
            withExtension: "ocio"
        ) else { throw StudioColorError.missingBundledConfiguration }
        return configurationURL
    }

    public static var runtimeVersion: String {
        #if canImport(StudioColorABI)
        String(cString: SCVersion())
        #else
        "unavailable"
        #endif
    }

    #if canImport(StudioColorABI)
    private let reference: SCConfigRef
    private let cacheLock = NSLock()
    private var colorSpaceProcessors: [String: StudioColorProcessor] = [:]
    private var inverseDisplayProcessors: [String: StudioColorProcessor] = [:]
    private var displayProcessors: [String: StudioColorProcessor] = [:]

    private init(reference: SCConfigRef) {
        self.reference = reference
    }

    deinit {
        SCConfigRelease(reference)
    }
    #else
    private init() {}
    #endif

    public static func bundled() throws -> StudioColorEngine {
        try engine(configurationURL: bundledConfigurationURL())
    }

    private static func engine(configurationURL: URL) throws -> StudioColorEngine {
        #if canImport(StudioColorABI)
        var error: UnsafeMutablePointer<CChar>?
        let reference = configurationURL.path.withCString { path in
            SCConfigCreate(path, &error)
        }
        guard let reference else {
            throw consumeBridgeError(error)
        }
        return StudioColorEngine(reference: reference)
        #else
        throw StudioColorError.unavailableOnPlatform
        #endif
    }

    public func makeColorSpaceProcessor(
        source: String,
        destination: String
    ) throws -> StudioColorProcessor {
        #if canImport(StudioColorABI)
        var error: UnsafeMutablePointer<CChar>?
        let processor = source.withCString { sourceName in
            destination.withCString { destinationName in
                SCProcessorCreateColorSpace(
                    reference,
                    sourceName,
                    destinationName,
                    &error
                )
            }
        }
        guard let processor else {
            throw consumeBridgeError(error)
        }
        return StudioColorProcessor(reference: processor)
        #else
        throw StudioColorError.unavailableOnPlatform
        #endif
    }

    public func cachedColorSpaceProcessor(
        source: String,
        destination: String
    ) throws -> StudioColorProcessor {
        let key = "\(source)→\(destination)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = colorSpaceProcessors[key] { return cached }
        let processor = try makeColorSpaceProcessor(
            source: source,
            destination: destination
        )
        colorSpaceProcessors[key] = processor
        return processor
    }

    public func makeDisplayProcessor(
        source: String,
        display: String,
        view: String
    ) throws -> StudioColorProcessor {
        #if canImport(StudioColorABI)
        var error: UnsafeMutablePointer<CChar>?
        let processor = source.withCString { sourceName in
            display.withCString { displayName in
                view.withCString { viewName in
                    SCProcessorCreateDisplayView(
                        reference,
                        sourceName,
                        displayName,
                        viewName,
                        &error
                    )
                }
            }
        }
        guard let processor else {
            throw consumeBridgeError(error)
        }
        return StudioColorProcessor(reference: processor)
        #else
        throw StudioColorError.unavailableOnPlatform
        #endif
    }

    public func cachedDisplayProcessor(
        source: String,
        display: String,
        view: String
    ) throws -> StudioColorProcessor {
        let key = "\(source)→\(display)→\(view)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = displayProcessors[key] { return cached }
        let processor = try makeDisplayProcessor(
            source: source,
            display: display,
            view: view
        )
        displayProcessors[key] = processor
        return processor
    }

    public func makeInverseDisplayProcessor(
        destination: String,
        display: String,
        view: String
    ) throws -> StudioColorProcessor {
        #if canImport(StudioColorABI)
        var error: UnsafeMutablePointer<CChar>?
        let processor = destination.withCString { destinationName in
            display.withCString { displayName in
                view.withCString { viewName in
                    SCProcessorCreateDisplayViewInverse(
                        reference,
                        destinationName,
                        displayName,
                        viewName,
                        &error
                    )
                }
            }
        }
        guard let processor else {
            throw consumeBridgeError(error)
        }
        return StudioColorProcessor(reference: processor)
        #else
        throw StudioColorError.unavailableOnPlatform
        #endif
    }

    public func cachedInverseDisplayProcessor(
        destination: String,
        display: String,
        view: String
    ) throws -> StudioColorProcessor {
        let key = "\(display)→\(view)→\(destination)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = inverseDisplayProcessors[key] { return cached }
        let processor = try makeInverseDisplayProcessor(
            destination: destination,
            display: display,
            view: view
        )
        inverseDisplayProcessors[key] = processor
        return processor
    }
}

#if canImport(StudioColorABI)
private func consumeBridgeError(
    _ pointer: UnsafeMutablePointer<CChar>?
) -> StudioColorError {
    guard let pointer else {
        return .bridge("Error no especificado.")
    }
    defer { SCFreeString(pointer) }
    return .bridge(String(cString: pointer))
}

private func withBridgeError<Result>(
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
) throws -> Result {
    var error: UnsafeMutablePointer<CChar>?
    let result = body(&error)
    if let error {
        throw consumeBridgeError(error)
    }
    if let success = result as? Bool, !success {
        throw StudioColorError.bridge("La operación no se completó.")
    }
    return result
}
#endif
