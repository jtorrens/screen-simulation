import Foundation
import Metal
import StudioColor

enum EnvironmentRadianceFrameError: Error, LocalizedError {
    case invalidEquirectangularRaster
    case unavailableMetalResource
    case mipGenerationFailed

    var errorDescription: String? {
        switch self {
        case .invalidEquirectangularRaster:
            "El entorno HDR debe ser un panorama equirectangular 2:1."
        case .unavailableMetalResource:
            "No se ha podido reservar la textura HDR con mipmaps."
        case .mipGenerationFailed:
            "No se ha podido generar la convolución multiescala del entorno HDR."
        }
    }
}

enum EnvironmentRadianceFrame {
    /// Builds the mipmapped ACEScg environment artifact consumed by Cover/Environment.
    /// Decoding and the explicit IDT have already completed before this boundary.
    static func mipmapped(from source: StudioColorMetalFrame) throws -> StudioColorMetalFrame {
        guard source.width >= 2, source.height >= 2, source.width == source.height * 2 else {
            throw EnvironmentRadianceFrameError.invalidEquirectangularRaster
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.texture.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: true
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead]
        guard let destination = source.texture.device.makeTexture(descriptor: descriptor),
              let queue = source.texture.device.makeCommandQueue(),
              let command = queue.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder()
        else { throw EnvironmentRadianceFrameError.unavailableMetalResource }
        blit.copy(
            from: source.texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.generateMipmaps(for: destination)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw EnvironmentRadianceFrameError.mipGenerationFailed
        }
        return StudioColorMetalFrame(texture: destination)
    }
}
