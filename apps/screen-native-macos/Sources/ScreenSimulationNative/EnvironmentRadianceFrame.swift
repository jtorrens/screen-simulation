import Foundation
import Metal
import ScreenPhysicalBridge
import StudioColor

enum EnvironmentRadianceFrameError: Error, LocalizedError {
    case invalidEquirectangularRaster
    case angularPrefilterFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEquirectangularRaster:
            "El entorno HDR debe ser un panorama equirectangular 2:1."
        case .angularPrefilterFailed(let message):
            message
        }
    }
}

/// Immutable Cover/Environment artifact. Rust owns its rough-interface semantics;
/// Swift retains the prepared Metal resource and passes only its opaque physical texture view.
final class EnvironmentRadianceFrame: @unchecked Sendable {
    let physicalTexture: ScreenPhysicalTextureRef
    private let owner: ScreenEnvironmentRadianceTextureRef

    private init(
        owner: ScreenEnvironmentRadianceTextureRef,
        physicalTexture: ScreenPhysicalTextureRef
    ) {
        self.owner = owner
        self.physicalTexture = physicalTexture
    }

    deinit {
        screen_environment_radiance_texture_release(owner)
    }

    /// Copies the exact single-level radiance source consumed by Cover/Environment.
    /// Decoding and the explicit IDT have already completed before this boundary.
    static func prefiltered(from source: StudioColorMetalFrame) throws -> EnvironmentRadianceFrame {
        guard source.width >= 2, source.height >= 2, source.width == source.height * 2 else {
            throw EnvironmentRadianceFrameError.invalidEquirectangularRaster
        }
        var error: UnsafePointer<CChar>?
        let pointer = Unmanaged.passUnretained(source.texture as AnyObject).toOpaque()
        guard let owner = screen_environment_radiance_texture_create_metal(pointer, &error),
              let physicalTexture = screen_environment_radiance_texture_borrow_physical(owner)
        else {
            let message = error.map { String(cString: $0) }
                ?? "No se ha podido prefiltrar angularmente el entorno HDR."
            throw EnvironmentRadianceFrameError.angularPrefilterFailed(message)
        }
        return EnvironmentRadianceFrame(owner: owner, physicalTexture: physicalTexture)
    }
}
