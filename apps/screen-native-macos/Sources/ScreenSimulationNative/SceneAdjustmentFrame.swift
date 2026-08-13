import Metal
import ScreenPhysicalBridge
import StudioColor

struct SceneAdjustmentParameters: Codable, Equatable, Sendable {
    static let neutral = Self()

    var exposureEV = 0.0
    var contrast = 1.0
    var saturation = 1.0
    var temperatureKelvin = 6500.0
    var tint = 0.0
}

final class SceneAdjustmentFrame: @unchecked Sendable {
    let frame: StudioColorMetalFrame
    let physicalTexture: ScreenPhysicalTextureRef
    private let owner: ScreenAdjustedSceneTextureRef

    init(
        source: StudioColorMetalFrame,
        parameters: SceneAdjustmentParameters,
        incidentRadiance: Bool
    ) throws {
        var error: UnsafePointer<CChar>?
        let pointer = Unmanaged.passUnretained(source.texture as AnyObject).toOpaque()
        guard let owner = screen_scene_adjustment_texture_create_metal(
            pointer,
            Float(parameters.exposureEV),
            Float(parameters.contrast),
            Float(parameters.saturation),
            Float(parameters.temperatureKelvin),
            Float(parameters.tint),
            incidentRadiance,
            &error
        ), let physical = screen_scene_adjustment_texture_borrow_physical(owner),
           let metalPointer = screen_scene_adjustment_texture_borrow_metal(owner)
        else {
            throw NSError(
                domain: "ScreenSimulation.SceneAdjustment",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: error.map(String.init(cString:))
                    ?? "No se ha podido ajustar el raster ACEScg."]
            )
        }
        self.owner = owner
        physicalTexture = physical
        let texture = Unmanaged<MTLTexture>.fromOpaque(metalPointer).takeUnretainedValue()
        frame = StudioColorMetalFrame(texture: texture)
    }

    deinit { screen_scene_adjustment_texture_release(owner) }
}
