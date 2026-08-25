import Foundation
import ScreenPhysicalBridge
import StudioColor
import StudioMedia
import simd

enum FusionScenePackageError: Error, LocalizedError, Equatable {
    case invalidRaster
    case activeRectOutsideRaster
    case insufficientSpillSupport
    case invalidCamera
    case invalidLens
    case lensNotRepresentableBySynthEyesDE4
    case nonFinitePixel
    case incompletePhysicalDeviceContribution
    case unsupportedMediaEncoding
    case invalidOutputManifest

    var errorDescription: String? {
        switch self {
        case .invalidRaster: "El raster VFX no es válido."
        case .activeRectOutsideRaster: "El rectángulo activo queda fuera del raster VFX."
        case .insufficientSpillSupport: "El raster físico no contiene el soporte de spill declarado."
        case .invalidCamera: "La cámara Fusion no es válida."
        case .invalidLens: "El modelo de lente Fusion no es válido."
        case .lensNotRepresentableBySynthEyesDE4:
            "La lente activa no puede reconstruirse exactamente con el modelo SynthEyes DE4 Radial Standard Degree 4."
        case .nonFinitePixel: "El raster VFX contiene un valor no finito."
        case .incompletePhysicalDeviceContribution:
            "Fusion Scene Package requiere Screen y Panel Emission al 100 % para exportar la contribución física completa sin consultar el RGB ideal."
        case .unsupportedMediaEncoding:
            "El preset de color no tiene una transformación nativa exacta hacia ACEScg en Fusion 21."
        case .invalidOutputManifest:
            "El manifiesto de salida Fusion no corresponde al rango configurado."
        }
    }
}

struct FusionRasterRect: Codable, Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct FusionRawPhysicalFrame: Equatable, Sendable {
    let width: Int
    let height: Int
    let activeRect: FusionRasterRect
    /// Surface contribution with the complete physical Device occlusion matte embedded in alpha.
    let deviceRGBA: [Float]
    /// Additive exterior contribution over black. Alpha is opaque and has no matte meaning.
    let spillRGBA: [Float]

    func validate() throws {
        guard width > 0, height > 0,
              deviceRGBA.count == width * height * 4,
              spillRGBA.count == width * height * 4 else {
            throw FusionScenePackageError.invalidRaster
        }
        guard activeRect.width > 0, activeRect.height > 0,
              activeRect.x >= 0, activeRect.y >= 0,
              activeRect.x + activeRect.width <= width,
              activeRect.y + activeRect.height <= height else {
            throw FusionScenePackageError.activeRectOutsideRaster
        }
        guard deviceRGBA.allSatisfy(\.isFinite), spillRGBA.allSatisfy(\.isFinite) else {
            throw FusionScenePackageError.nonFinitePixel
        }
    }
}

struct FusionPreparedPhysicalFrame: Equatable, Sendable {
    let width: Int
    let height: Int
    let activeRect: FusionRasterRect
    let uniformPaddingPixels: Int
    let thresholdSupportPixels: Int
    let deviceRGBA: [Float]
    let spillRGBA: [Float]
}

enum FusionSpillSupport {
    // AP1/ACEScg RGB to CIE Y coefficients in the ACES D60 basis.
    static let luminance = SIMD3<Float>(0.272_228_72, 0.674_081_74, 0.053_689_52)

    static func measureThresholdSupport(
        _ source: FusionRawPhysicalFrame,
        thresholdSceneLinear: Double
    ) throws -> Int {
        try source.validate()
        guard thresholdSceneLinear.isFinite, thresholdSceneLinear > 0 else {
            throw FusionScenePackageError.invalidRaster
        }
        let active = source.activeRect
        var thresholdSupport = 0
        for y in 0 ..< source.height {
            for x in 0 ..< source.width {
                let offset = (y * source.width + x) * 4
                let rgb = SIMD3<Float>(
                    source.spillRGBA[offset], source.spillRGBA[offset + 1],
                    source.spillRGBA[offset + 2]
                )
                let yScene = max(0, simd_dot(rgb, luminance))
                let matte = source.deviceRGBA[offset + 3]
                guard Double(yScene) >= thresholdSceneLinear || matte > 0 else { continue }
                let dx = x < active.x ? active.x - x
                    : (x >= active.x + active.width ? x - (active.x + active.width - 1) : 0)
                let dy = y < active.y ? active.y - y
                    : (y >= active.y + active.height ? y - (active.y + active.height - 1) : 0)
                thresholdSupport = max(thresholdSupport, dx, dy)
            }
        }
        return thresholdSupport
    }

    static func prepare(
        _ source: FusionRawPhysicalFrame,
        thresholdSceneLinear: Double,
        fadeWidthPixels: Int,
        fixedThresholdSupportPixels: Int
    ) throws -> FusionPreparedPhysicalFrame {
        try source.validate()
        guard thresholdSceneLinear.isFinite, thresholdSceneLinear > 0,
              fadeWidthPixels >= 0 else {
            throw FusionScenePackageError.invalidRaster
        }
        let active = source.activeRect
        let thresholdSupport = fixedThresholdSupportPixels
        // The support is an explicit export choice (currently two authored glow radii), not an
        // unbounded request to preserve a mathematical filter tail. The radiometric edge fade
        // below owns the exterior fade band without growing the package raster.
        let padding = thresholdSupport + fadeWidthPixels
        let outputWidth = active.width + 2 * padding
        let outputHeight = active.height + 2 * padding
        let sourceCenterX2 = active.x * 2 + active.width
        let sourceCenterY2 = active.y * 2 + active.height
        let sourceOriginX = (sourceCenterX2 - outputWidth) / 2
        let sourceOriginY = (sourceCenterY2 - outputHeight) / 2
        guard sourceOriginX >= 0, sourceOriginY >= 0,
              sourceOriginX + outputWidth <= source.width,
              sourceOriginY + outputHeight <= source.height else {
            throw FusionScenePackageError.insufficientSpillSupport
        }
        var device = [Float](repeating: 0, count: outputWidth * outputHeight * 4)
        var spill = [Float](repeating: 0, count: outputWidth * outputHeight * 4)
        for y in 0 ..< outputHeight {
            for x in 0 ..< outputWidth {
                let sourceOffset = ((sourceOriginY + y) * source.width + sourceOriginX + x) * 4
                let targetOffset = (y * outputWidth + x) * 4
                let dx = x < padding ? padding - x
                    : (x >= padding + active.width ? x - (padding + active.width - 1) : 0)
                let dy = y < padding ? padding - y
                    : (y >= padding + active.height ? y - (padding + active.height - 1) : 0)
                let distance = max(dx, dy)
                let fade: Float
                if fadeWidthPixels == 0 || distance <= thresholdSupport {
                    fade = 1
                } else {
                    let t = Float(distance - thresholdSupport) / Float(fadeWidthPixels)
                    let clamped = min(1, max(0, t))
                    fade = 1 - clamped * clamped * (3 - 2 * clamped)
                }
                device[targetOffset] = source.deviceRGBA[sourceOffset]
                device[targetOffset + 1] = source.deviceRGBA[sourceOffset + 1]
                device[targetOffset + 2] = source.deviceRGBA[sourceOffset + 2]
                device[targetOffset + 3] = source.deviceRGBA[sourceOffset + 3]
                spill[targetOffset] = source.spillRGBA[sourceOffset] * fade
                spill[targetOffset + 1] = source.spillRGBA[sourceOffset + 1] * fade
                spill[targetOffset + 2] = source.spillRGBA[sourceOffset + 2] * fade
                spill[targetOffset + 3] = 1
            }
        }
        return FusionPreparedPhysicalFrame(
            width: outputWidth,
            height: outputHeight,
            activeRect: FusionRasterRect(
                x: padding, y: padding, width: active.width, height: active.height
            ),
            uniformPaddingPixels: padding,
            thresholdSupportPixels: thresholdSupport,
            deviceRGBA: device,
            spillRGBA: spill
        )
    }
}

struct FusionCameraKeyframe: Codable, Equatable, Sendable {
    let frame: Int
    let positionMeters: [Double]
    let quaternionXYZW: [Double]
    let focalLengthMillimeters: Double
    let horizontalFOVDegrees: Double
    let sensorWidthMillimeters: Double
    let sensorHeightMillimeters: Double
    let lensShiftXY: [Double]
    let focusDistanceMeters: Double
    let fStop: Double
    let nearClipMeters: Double
    let farClipMeters: Double
}

struct FusionLensKeyframe: Codable, Equatable, Sendable {
    let frame: Int
    let radialK1K2K3: [Double]
    let tangentialP1P2: [Double]
    let opticalCenterXY: [Double]
}

struct FusionMotionBlurContract: Codable, Equatable, Sendable {
    let bakedInEXR: Bool
    let enabledInFusion: Bool
    let shutterAngleDegrees: Double
    let shutterPhaseDegrees: Double

    var fusionCenterBias: Double {
        shutterAngleDegrees == 0 ? 0 : 2 * shutterPhaseDegrees / shutterAngleDegrees
    }
}

struct FusionProjectedRaster: Equatable, Sendable {
    let activeWidth: Int
    let activeHeight: Int
    let pixelsPerMeter: Double
}

enum FusionProjectionResolver {
    static let depthOfFieldBoundarySamples = 1_024

    private static func evenCeiling(_ value: Double) -> Int {
        let ceiling = max(1, Int(ceil(value)))
        return ceiling.isMultiple(of: 2) ? ceiling : ceiling + 1
    }

    /// Resolves one fixed frontal raster from the complete, unclipped Device projection. Camera
    /// samples must include every authored curve evaluation relevant to the job range.
    static func maximumProjectedDensity(
        cameraSamples: [FusionCameraKeyframe],
        deviceWidthMeters: Double,
        deviceHeightMeters: Double,
        deliveryWidth: Int,
        deliveryHeight: Int
    ) throws -> FusionProjectedRaster {
        guard !cameraSamples.isEmpty,
              deviceWidthMeters.isFinite, deviceWidthMeters > 0,
              deviceHeightMeters.isFinite, deviceHeightMeters > 0,
              deliveryWidth > 0, deliveryHeight > 0 else {
            throw FusionScenePackageError.invalidCamera
        }
        let halfWidth = deviceWidthMeters * 0.5
        let halfHeight = deviceHeightMeters * 0.5
        let corners = [
            SIMD3(-halfWidth, -halfHeight, 0),
            SIMD3(halfWidth, -halfHeight, 0),
            SIMD3(halfWidth, halfHeight, 0),
            SIMD3(-halfWidth, halfHeight, 0),
        ]
        var density = 0.0
        for camera in cameraSamples {
            let projected = try corners.map {
                try project(
                    $0, camera: camera,
                    deliveryWidth: deliveryWidth, deliveryHeight: deliveryHeight
                )
            }
            let horizontal = max(
                simd_length(projected[1] - projected[0]),
                simd_length(projected[2] - projected[3])
            ) / deviceWidthMeters
            let vertical = max(
                simd_length(projected[3] - projected[0]),
                simd_length(projected[2] - projected[1])
            ) / deviceHeightMeters
            density = max(density, horizontal, vertical)
        }
        guard density.isFinite, density > 0 else {
            throw FusionScenePackageError.invalidCamera
        }
        return FusionProjectedRaster(
            // The alpha-capable ProRes writer requires even coded dimensions. Fusion support is
            // symmetric, so resolving the active raster to even dimensions here preserves that
            // symmetry and never undersamples the measured maximum projected density.
            activeWidth: evenCeiling(deviceWidthMeters * density),
            activeHeight: evenCeiling(deviceHeightMeters * density),
            pixelsPerMeter: density
        )
    }

    static func nativeDevice(
        width: Int,
        height: Int,
        deviceWidthMeters: Double,
        deviceHeightMeters: Double
    ) throws -> FusionProjectedRaster {
        guard width > 0, height > 0,
              deviceWidthMeters > 0, deviceHeightMeters > 0 else {
            throw FusionScenePackageError.invalidRaster
        }
        return FusionProjectedRaster(
            activeWidth: width,
            activeHeight: height,
            pixelsPerMeter: max(
                Double(width) / deviceWidthMeters,
                Double(height) / deviceHeightMeters
            )
        )
    }

    static func customFit(
        maximumWidth: Int,
        maximumHeight: Int,
        deviceWidthMeters: Double,
        deviceHeightMeters: Double
    ) throws -> FusionProjectedRaster {
        guard maximumWidth > 0, maximumHeight > 0,
              deviceWidthMeters > 0, deviceHeightMeters > 0 else {
            throw FusionScenePackageError.invalidRaster
        }
        let density = min(
            Double(maximumWidth) / deviceWidthMeters,
            Double(maximumHeight) / deviceHeightMeters
        )
        return FusionProjectedRaster(
            activeWidth: max(1, Int(floor(deviceWidthMeters * density))),
            activeHeight: max(1, Int(floor(deviceHeightMeters * density))),
            pixelsPerMeter: density
        )
    }

    static func project(
        _ world: SIMD3<Double>,
        camera: FusionCameraKeyframe,
        deliveryWidth: Int,
        deliveryHeight: Int
    ) throws -> SIMD2<Double> {
        guard camera.positionMeters.count == 3,
              camera.quaternionXYZW.count == 4,
              camera.lensShiftXY.count == 2 else {
            throw FusionScenePackageError.invalidCamera
        }
        let position = SIMD3(
            camera.positionMeters[0], camera.positionMeters[1], camera.positionMeters[2]
        )
        let q = simd_quatd(
            ix: camera.quaternionXYZW[0],
            iy: camera.quaternionXYZW[1],
            iz: camera.quaternionXYZW[2],
            r: camera.quaternionXYZW[3]
        )
        let qv = q.vector
        guard qv.x.isFinite, qv.y.isFinite, qv.z.isFinite, qv.w.isFinite,
              abs(simd_length(qv) - 1) < 1e-6 else {
            throw FusionScenePackageError.invalidCamera
        }
        let local = q.inverse.act(world - position)
        let depth = -local.z
        guard depth.isFinite, depth > camera.nearClipMeters,
              depth < camera.farClipMeters else {
            throw FusionScenePackageError.invalidCamera
        }
        let f = camera.focalLengthMillimeters
        let ndcX = 2 * f * local.x / (depth * camera.sensorWidthMillimeters)
            - 2 * camera.lensShiftXY[0]
        let ndcY = 2 * f * local.y / (depth * camera.sensorHeightMillimeters)
            - 2 * camera.lensShiftXY[1]
        return SIMD2(
            (ndcX + 1) * 0.5 * Double(deliveryWidth),
            (1 - ndcY) * 0.5 * Double(deliveryHeight)
        )
    }

    static func depthOfFieldSupportPixels(
        cameraSamples: [FusionCameraKeyframe],
        deviceWidthMeters: Double,
        deviceHeightMeters: Double,
        pixelsPerMeter: Double
    ) throws -> Int {
        guard pixelsPerMeter.isFinite, pixelsPerMeter > 0 else {
            throw FusionScenePackageError.invalidCamera
        }
        let corners = [
            SIMD3(-deviceWidthMeters * 0.5, -deviceHeightMeters * 0.5, 0),
            SIMD3(deviceWidthMeters * 0.5, -deviceHeightMeters * 0.5, 0),
            SIMD3(deviceWidthMeters * 0.5, deviceHeightMeters * 0.5, 0),
            SIMD3(-deviceWidthMeters * 0.5, deviceHeightMeters * 0.5, 0),
        ]
        var maximumMeters = 0.0
        for camera in cameraSamples {
            let q = simd_quatd(
                ix: camera.quaternionXYZW[0], iy: camera.quaternionXYZW[1],
                iz: camera.quaternionXYZW[2], r: camera.quaternionXYZW[3]
            )
            let position = SIMD3(
                camera.positionMeters[0], camera.positionMeters[1], camera.positionMeters[2]
            )
            let right = q.act(SIMD3(1, 0, 0))
            let up = q.act(SIMD3(0, 1, 0))
            let forward = q.act(SIMD3(0, 0, -1))
            let apertureRadius = camera.focalLengthMillimeters * 0.001 / (2 * camera.fStop)
            for target in corners {
                let chief = simd_normalize(target - position)
                let chiefDenominator = simd_dot(chief, forward)
                guard chiefDenominator > 1e-9 else {
                    throw FusionScenePackageError.invalidCamera
                }
                let focusPoint = position + chief
                    * (camera.focusDistanceMeters / chiefDenominator)
                for sample in 0 ..< depthOfFieldBoundarySamples {
                    let angle = 2 * Double.pi * Double(sample)
                        / Double(depthOfFieldBoundarySamples)
                    let origin = position + right * (cos(angle) * apertureRadius)
                        + up * (sin(angle) * apertureRadius)
                    let ray = focusPoint - origin
                    guard abs(ray.z) > 1e-12 else {
                        throw FusionScenePackageError.invalidCamera
                    }
                    let distance = -origin.z / ray.z
                    guard distance > 0 else { throw FusionScenePackageError.invalidCamera }
                    let intersection = origin + ray * distance
                    maximumMeters = max(
                        maximumMeters,
                        abs(intersection.x - target.x),
                        abs(intersection.y - target.y)
                    )
                }
            }
        }
        // One declared outward raster sample covers discretization of the continuous boundary.
        return Int(ceil(maximumMeters * pixelsPerMeter)) + 1
    }
}

enum FusionPhysicalSupportResolver {
    /// Product-owned export approximation: two authored glow radii preserve the visible
    /// falloff in a practical package; the declared fade brings the residual to zero.
    static let exportGlowRadiusMultiplier = 2.0

    static func sourceOverscanPixels(
        panelTailRadiusMicrometers: Double,
        panelSpreadAmount: Double,
        glowRadiusMillimeters: Double,
        glowAmount: Double,
        dofSupportPixels: Int,
        fadeWidthPixels: Int,
        pixelsPerMeter: Double
    ) throws -> Int {
        guard panelTailRadiusMicrometers.isFinite, panelTailRadiusMicrometers >= 0,
              panelSpreadAmount.isFinite, panelSpreadAmount >= 0,
              glowRadiusMillimeters.isFinite, glowRadiusMillimeters >= 0,
              glowAmount.isFinite, glowAmount >= 0,
              dofSupportPixels >= 0, fadeWidthPixels >= 0,
              pixelsPerMeter.isFinite, pixelsPerMeter > 0 else {
            throw FusionScenePackageError.invalidRaster
        }
        let spreadMeters = panelTailRadiusMicrometers
            * panelSpreadAmount / sqrt(2) * 1e-6
        // Glow amount scales energy, not radius. Any positive amount therefore reserves the
        // explicit practical export support; no hidden kernel-tail multiplier is applied.
        let glowMeters = glowAmount == 0 ? 0 : glowRadiusMillimeters
            * exportGlowRadiusMultiplier * 1e-3
        return Int(ceil(max(spreadMeters, glowMeters) * pixelsPerMeter))
            + dofSupportPixels + fadeWidthPixels
    }
}

struct FusionSceneMetadata: Codable, Equatable, Sendable {
    struct Raster: Codable, Equatable, Sendable {
        let width: Int
        let height: Int
        let activeDeviceRect: FusionRasterRect
        let uniformPaddingPixels: Int
        let pixelAspect: Double
        let deviceWidthMeters: Double
        let deviceHeightMeters: Double
        let resolutionMode: StudioFusionResolutionMode
    }
    struct Spill: Codable, Equatable, Sendable {
        let thresholdSceneLinear: Double
        let fadeWidthPixels: Int
        let thresholdSupportPixels: Int
        let sourceOverscanPixels: Int
        let physicalKernelSupportContract: String
        let dofSupportContract: String
        let matteSupportContract: String
        let luminanceCoefficientsACEScg: [Double]
    }
    struct LensReconstruction: Codable, Equatable, Sendable {
        let bakedInEXR: Bool
        let contract: String
        let fusionTool: String
        let fusionModel: String
        let parameterMapping: String
    }

    let schema: String
    let schemaVersion: Int
    let jobName: String
    let firstFrame: Int
    let lastFrame: Int
    let frameRate: Double
    let colorSpace: String
    let transfer: String
    let channels: [String]
    let rgbMeaning: String
    let alphaMeaning: String
    let alphaAssociation: String
    let physicalCompositeEquation: String
    let raster: Raster
    let spill: Spill
    let dofMode: StudioFusionDOFMode
    let dofBakedInEXR: Bool
    let cameraCurvesExportedWhenBaked: Bool
    let motionBlur: FusionMotionBlurContract
    let lensReconstruction: LensReconstruction
    let camera: [FusionCameraKeyframe]
    let lens: [FusionLensKeyframe]
    let deviceTransform: String
    let mediaFormat: StudioOutputFormat
    let mediaEncoding: String
    let mediaToACEScgTransform: String
    let deviceMediaPattern: String
    let spillMediaPattern: String
    let fusionComp: String
}

struct FusionScenePackageRequest: Equatable, Sendable {
    let configuration: StudioResolvedRenderConfiguration
    let outputPlan: RenderOutputPlan
    let deviceWidthMeters: Double
    let deviceHeightMeters: Double
    let activeRaster: FusionProjectedRaster
    let sourceOverscanPixels: Int
    let deliveryWidth: Int
    let deliveryHeight: Int
    let camera: [FusionCameraKeyframe]
    let lens: [FusionLensKeyframe]
    let motionBlur: FusionMotionBlurContract
    let referencePlate: FusionReferencePlate?

    func validate() throws {
        try configuration.validate()
        _ = try FusionMediaColorContract.resolve(configuration)
        guard configuration.renderMode == .final,
              configuration.fusionScene != nil,
              outputPlan.kind == .fusionScenePackage,
              configuration.frameRate.framesPerSecond.isFinite,
              configuration.frameRate.framesPerSecond > 0,
              deviceWidthMeters.isFinite, deviceWidthMeters > 0,
              deviceHeightMeters.isFinite, deviceHeightMeters > 0,
              activeRaster.activeWidth > 0, activeRaster.activeHeight > 0,
              activeRaster.pixelsPerMeter.isFinite, activeRaster.pixelsPerMeter > 0,
              sourceOverscanPixels >= 0,
              deliveryWidth > 0, deliveryHeight > 0,
              !camera.isEmpty, !lens.isEmpty,
              motionBlur.bakedInEXR == false,
              motionBlur.enabledInFusion,
              motionBlur.shutterAngleDegrees.isFinite,
              motionBlur.shutterAngleDegrees >= 0,
              motionBlur.shutterPhaseDegrees.isFinite,
              motionBlur.fusionCenterBias >= -1,
              motionBlur.fusionCenterBias <= 1 else {
            throw FusionScenePackageError.invalidCamera
        }
        let requiredFrames = Set(configuration.frameRange)
        guard Set(camera.map(\.frame)) == requiredFrames,
              Set(lens.map(\.frame)) == requiredFrames,
              camera.count == requiredFrames.count,
              lens.count == requiredFrames.count else {
            throw FusionScenePackageError.invalidCamera
        }
        for key in camera {
            guard key.positionMeters.count == 3,
                  key.quaternionXYZW.count == 4,
                  key.lensShiftXY.count == 2,
                  (key.positionMeters + key.quaternionXYZW + key.lensShiftXY)
                    .allSatisfy(\.isFinite),
                  key.focalLengthMillimeters.isFinite,
                  key.focalLengthMillimeters > 0,
                  key.sensorWidthMillimeters > 0,
                  key.sensorHeightMillimeters > 0,
                  key.focusDistanceMeters > 0,
                  key.fStop > 0,
                  key.nearClipMeters.isFinite, key.nearClipMeters > 0,
                  key.farClipMeters.isFinite, key.farClipMeters > key.nearClipMeters,
                  abs(sqrt(key.quaternionXYZW.reduce(0) { $0 + $1 * $1 }) - 1) < 1e-5 else {
                throw FusionScenePackageError.invalidCamera
            }
        }
        for key in lens {
            guard key.radialK1K2K3.count == 3,
                  key.tangentialP1P2.count == 2,
                  key.opticalCenterXY.count == 2,
                  (key.radialK1K2K3 + key.tangentialP1P2 + key.opticalCenterXY)
                    .allSatisfy(\.isFinite) else {
                throw FusionScenePackageError.invalidLens
            }
            guard key.radialK1K2K3[2] == 0,
                  key.tangentialP1P2 == [0, 0],
                  key.opticalCenterXY == [0, 0] else {
                throw FusionScenePackageError.lensNotRepresentableBySynthEyesDE4
            }
        }
    }
}

enum FusionReferenceColorTransform: String, Equatable, Sendable {
    case aces2Rec709D65InverseOutput
    case disabled

    static func resolve(inputTransformID: String) -> Self {
        inputTransformID == "display-rec709-aces2-sdr"
            ? .aces2Rec709D65InverseOutput
            : .disabled
    }
}

struct FusionMediaColorContract: Equatable, Sendable {
    enum NativeNode: Equatable, Sendable {
        case acesTransform(inputID: String)
        case colorSpaceTransform(inputColorSpaceID: String, inputGammaID: String)
    }

    let encodingDescription: String
    let transformDescription: String
    let node: NativeNode

    static func resolve(_ configuration: StudioResolvedRenderConfiguration) throws -> Self {
        switch (configuration.pipeline, configuration.target) {
        case (_, .acescg):
            return .init(
                encodingDescription: "ACEScg scene-linear",
                transformDescription: "AcesTransform ACES_VERSION_2_0_0 IDT_ACESCG to ODT_ACESCG",
                node: .acesTransform(inputID: "IDT_ACESCG")
            )
        case (_, .aces2065):
            return .init(
                encodingDescription: "ACES2065-1 scene-linear",
                transformDescription: "AcesTransform ACES_VERSION_2_0_0 IDT_NONE (ACES2065-1) to ODT_ACESCG",
                node: .acesTransform(inputID: "IDT_NONE")
            )
        case (.aces, .sdr)
            where configuration.peakNits == 100
                && configuration.display == "Rec.1886 Rec.709 - Display"
                && configuration.view == "ACES 2.0 - SDR 100 nits (Rec.709)":
            return .init(
                encodingDescription: "ACES 2.0 Rec.709 D65 100 nit display/output encoded",
                transformDescription: "AcesTransform ACES_VERSION_2_0_0 IDT_REC709_100_INV_ODT to ODT_ACESCG",
                node: .acesTransform(inputID: "IDT_REC709_100_INV_ODT")
            )
        case (.aces, .hdr)
            where configuration.peakNits == 1_000
                && configuration.display == "Rec.2100-PQ - Display"
                && configuration.view == "ACES 2.0 - HDR 1000 nits (Rec.2020)":
            return .init(
                encodingDescription: "ACES 2.0 Rec.2100 ST 2084 1000 nit display/output encoded",
                transformDescription: "AcesTransform ACES_VERSION_2_0_0 IDT_REC2100_ST2084_1000_INV_ODT to ODT_ACESCG",
                node: .acesTransform(inputID: "IDT_REC2100_ST2084_1000_INV_ODT")
            )
        case (.davinciColorManaged, .sdr)
            where configuration.peakNits == 100
                && configuration.display == "Rec.1886 Rec.709 - Display"
                && configuration.view == "Video (colorimetric)":
            return .init(
                encodingDescription: "Rec.709 Gamma 2.4 display encoded (DCM colorimetric)",
                transformDescription: "ColorSpaceTransform REC709_COLORSPACE/TWOPOINTFOUR_GAMMA to ACES_AP1_COLORSPACE/LINEAR_GAMMA; tone and gamut mapping none",
                node: .colorSpaceTransform(
                    inputColorSpaceID: "REC709_COLORSPACE",
                    inputGammaID: "TWOPOINTFOUR_GAMMA"
                )
            )
        case (.davinciColorManaged, .hdr)
            where configuration.peakNits == 1_000
                && configuration.display == "Rec.2100-PQ - Display"
                && configuration.view == "Video (colorimetric)":
            return .init(
                encodingDescription: "Rec.2100 ST 2084 1000 nit display encoded (DCM colorimetric)",
                transformDescription: "ColorSpaceTransform REC2020_COLORSPACE/PQ1000_GAMMA to ACES_AP1_COLORSPACE/LINEAR_GAMMA; tone and gamut mapping none",
                node: .colorSpaceTransform(
                    inputColorSpaceID: "REC2020_COLORSPACE",
                    inputGammaID: "PQ1000_GAMMA"
                )
            )
        case (_, .vfxLog):
            guard let id = configuration.vfxInterchangeEncodingID else {
                throw FusionScenePackageError.unsupportedMediaEncoding
            }
            guard StudioVFXInterchangeEncoding.catalog.contains(where: { $0.id == id }) else {
                throw FusionScenePackageError.unsupportedMediaEncoding
            }
            if id == "acescct-ap1" {
                return .init(
                    encodingDescription: "ACEScct / AP1 scene-referred Log",
                    transformDescription: "AcesTransform ACES_VERSION_2_0_0 IDT_ACESCCT to ODT_ACESCG",
                    node: .acesTransform(inputID: "IDT_ACESCCT")
                )
            }
            if id == "rec709-gamma24" {
                return .init(
                    encodingDescription: "ACES 2.0 Rec.709 D65 100 nit display/output encoded",
                    transformDescription: "AcesTransform ACES_VERSION_2_0_0 IDT_REC709_100_INV_ODT to ODT_ACESCG",
                    node: .acesTransform(inputID: "IDT_REC709_100_INV_ODT")
                )
            }
            let acesIDs: [String: String] = [
                "arri-logc4-awg4": "IDT_ARRI_LOGC4_CSC",
                "arri-logc3-ei800-awg3": "IDT_ARRI_LOGC_EI800_AWG_CSC",
                "sony-slog3-sgamut3-cine": "IDT_SONY_SLOG3_SGAMUT3_CINE_CSC",
                "panasonic-vlog-vgamut": "IDT_PANASONIC_VLOG_VGAMUT_CSC",
                "canon-log3-cinema-gamut-d55": "IDT_CANON_CLOG3_CINEMA_CSC",
                "red-log3g10-redwidegamutrgb": "IDT_RED_LOG3G10_WIDE_GAUMUT_CSC",
                "blackmagic-film-gen5": "IDT_BMD_FILM_V5_CSC",
            ]
            if id == "davinci-intermediate-wide-gamut" {
                return .init(
                    encodingDescription: "DaVinci Intermediate / Wide Gamut scene-referred Log",
                    transformDescription: "ColorSpaceTransform DWG_COLORSPACE/DAV_INTER_OETF_GAMMA to ACES_AP1_COLORSPACE/LINEAR_GAMMA; tone and gamut mapping none",
                    node: .colorSpaceTransform(
                        inputColorSpaceID: "DWG_COLORSPACE",
                        inputGammaID: "DAV_INTER_OETF_GAMMA"
                    )
                )
            }
            guard let inputID = acesIDs[id],
                  let encoding = StudioVFXInterchangeEncoding.catalog.first(where: {
                      $0.id == id
                  }) else {
                throw FusionScenePackageError.unsupportedMediaEncoding
            }
            return .init(
                encodingDescription: "\(encoding.label) scene-referred Log/Gamut",
                transformDescription: "AcesTransform ACES_VERSION_2_0_0 \(inputID) to ODT_ACESCG",
                node: .acesTransform(inputID: inputID)
            )
        default:
            throw FusionScenePackageError.unsupportedMediaEncoding
        }
    }

    func fusionTool(
        name: String,
        source: String,
        x: Int,
        y: Double,
        preDividePostMultiply: Bool = false
    ) -> String {
        let alphaHandling = preDividePostMultiply ? 1 : 0
        switch node {
        case let .acesTransform(inputID):
            return """
            \(name) = AcesTransform {
              Inputs = {
                AcesVersion = Input { Value = FuID { "ACES_VERSION_2_0_0" } },
                InputTransform200 = Input { Value = FuID { "\(inputID)" } },
                OutputTransform200 = Input { Value = FuID { "ODT_ACESCG" } },
                ["Gamut.PreDividePostMultiply"] = Input { Value = \(alphaHandling) },
                Input = Input { SourceOp = "\(source)", Source = "Output" }
              },
              CustomData = { SourceEncoding = "\(encodingDescription)", WorkingSpace = "ACEScg scene-linear" },
              ViewInfo = OperatorInfo { Pos = { \(x), \(y) } }
            },
            """
        case let .colorSpaceTransform(inputColorSpaceID, inputGammaID):
            return """
            \(name) = ColorSpaceTransform {
              Inputs = {
                InputColorSpace = Input { Value = FuID { "\(inputColorSpaceID)" } },
                InputGamma = Input { Value = FuID { "\(inputGammaID)" } },
                OutputColorSpace = Input { Value = FuID { "ACES_AP1_COLORSPACE" } },
                OutputGamma = Input { Value = FuID { "LINEAR_GAMMA" } },
                ToneMapping = Input { Value = FuID { "TM_NONE" } },
                GamutMapping = Input { Value = FuID { "GM_NONE" } },
                ["Gamut.PreDividePostMultiply"] = Input { Value = \(alphaHandling) },
                Input = Input { SourceOp = "\(source)", Source = "Output" }
              },
              CustomData = { SourceEncoding = "\(encodingDescription)", WorkingSpace = "ACEScg scene-linear" },
              ViewInfo = OperatorInfo { Pos = { \(x), \(y) } }
            },
            """
        }
    }
}

struct FusionReferencePlate: Equatable, Sendable {
    let sourceURL: URL
    let inputTransformID: String
    let colorTransform: FusionReferenceColorTransform
    let placementID: String
    let width: Int
    let height: Int
}

@MainActor
enum FusionScenePackageWriter {
    typealias FrameProvider = (Int) async throws -> FusionRawPhysicalFrame
    typealias Progress = (Int, Int) -> Void

    static func render(
        request: FusionScenePackageRequest,
        display: StudioColorMetalDisplay? = nil,
        frameProvider: FrameProvider,
        progress: Progress
    ) async throws -> URL {
        try request.validate()
        let configuration = request.configuration
        let options = configuration.fusionScene!
        try request.outputPlan.prepareDirectories()
        var firstPrepared: FusionPreparedPhysicalFrame?
        var deviceMovie: MovieWriter?
        var spillMovie: MovieWriter?
        var editorialEncodedBlack: SIMD3<Float>?
        let frames = Array(configuration.frameRange)
        let fixedThresholdSupport = request.sourceOverscanPixels
            - options.spillFadeWidthPixels
        guard fixedThresholdSupport >= 0 else {
            throw FusionScenePackageError.insufficientSpillSupport
        }
        for (position, frame) in frames.enumerated() {
            try Task.checkCancellation()
            let prepared = try FusionSpillSupport.prepare(
                try await frameProvider(frame),
                thresholdSceneLinear: options.spillThresholdSceneLinear,
                fadeWidthPixels: options.spillFadeWidthPixels,
                fixedThresholdSupportPixels: fixedThresholdSupport
            )
            guard prepared.activeRect.width == request.activeRaster.activeWidth,
                  prepared.activeRect.height == request.activeRaster.activeHeight else {
                throw FusionScenePackageError.invalidRaster
            }
            if let firstPrepared {
                guard firstPrepared.width == prepared.width,
                      firstPrepared.height == prepared.height,
                      firstPrepared.activeRect == prepared.activeRect,
                      firstPrepared.uniformPaddingPixels == prepared.uniformPaddingPixels else {
                    throw FusionScenePackageError.invalidRaster
                }
            } else {
                firstPrepared = prepared
            }
            let manifestOffset = configuration.format.isMovie ? 0 : position * 2
            guard request.outputPlan.generatedRelativePaths.indices.contains(manifestOffset + 1) else {
                throw FusionScenePackageError.invalidOutputManifest
            }
            let deviceRelative = request.outputPlan.generatedRelativePaths[manifestOffset]
            let spillRelative = request.outputPlan.generatedRelativePaths[manifestOffset + 1]
            let deviceURL = request.outputPlan.destination.appendingPathComponent(deviceRelative)
            let spillURL = request.outputPlan.destination.appendingPathComponent(spillRelative)
            if !configuration.format.isMovie {
                try request.outputPlan.authorizeWrite(
                    to: deviceURL, policy: configuration.overwritePolicy
                )
                try request.outputPlan.authorizeWrite(
                    to: spillURL, policy: configuration.overwritePolicy
                )
            }
            if configuration.format.isMovie {
                guard let display else {
                    throw NativeOutputError.unsupported("Fusion movie requiere el writer Metal")
                }
                let output = try requiredOutputTransform(configuration)
                let editorialAdd = configuration.spillDeliveryMode == .editorialEncodedAdd
                let deviceFrame = editorialAdd
                    ? try display.makeIndependentLinearACEScgFrame(
                        width: prepared.width, height: prepared.height,
                        rgba: prepared.deviceRGBA
                    )
                    : try makeACEScgFrame(
                        prepared.deviceRGBA, width: prepared.width, height: prepared.height,
                        display: display
                    )
                let spillFrame = editorialAdd ? nil : try makeACEScgFrame(
                    prepared.spillRGBA, width: prepared.width, height: prepared.height,
                    display: display
                )
                if deviceMovie == nil {
                    try request.outputPlan.authorizeWrite(
                        to: deviceURL, policy: configuration.overwritePolicy
                    )
                    try request.outputPlan.authorizeWrite(
                        to: spillURL, policy: configuration.overwritePolicy
                    )
                    for url in [deviceURL, spillURL] where FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    deviceMovie = try MovieWriter(
                        url: deviceURL, width: prepared.width, height: prepared.height,
                        frameRate: configuration.frameRate, format: configuration.format,
                        pixelEncoding: configuration.pixelEncoding,
                        peakNits: configuration.peakNits, signalRange: configuration.signalRange,
                        alpha: .straight, output: output,
                        preservesIndependentRGB: editorialAdd
                    )
                    spillMovie = try MovieWriter(
                        url: spillURL, width: prepared.width, height: prepared.height,
                        frameRate: configuration.frameRate, format: configuration.format,
                        pixelEncoding: configuration.pixelEncoding,
                        peakNits: configuration.peakNits, signalRange: configuration.signalRange,
                        alpha: editorialAdd ? .straight : .ignore, output: output
                    )
                }
                try await deviceMovie!.append(
                    frame: deviceFrame, presentationFrame: position,
                    display: display, output: output
                )
                if editorialAdd {
                    if editorialEncodedBlack == nil {
                        let blackFrame = try display.makeIndependentLinearACEScgFrame(
                            width: 1, height: 1, rgba: [0, 0, 0, 1]
                        )
                        let encodedBlack = try display.renderIndependentRGBAFloat(
                            blackFrame, output: output, alpha: .ignore
                        )
                        editorialEncodedBlack = SIMD3(
                            encodedBlack[0], encodedBlack[1], encodedBlack[2]
                        )
                    }
                    let encodedCarrier = try display.renderIndependentRGBAFloat(
                        deviceFrame, output: output, alpha: .straight
                    )
                    let encodedSpill = try NativeOutputRenderer.editorialEncodedAddSpill(
                        encodedCarrier: encodedCarrier,
                        encodedBlack: editorialEncodedBlack!
                    )
                    try await spillMovie!.appendEncodedRGBA(
                        encodedSpill, presentationFrame: position
                    )
                } else {
                    try await spillMovie!.append(
                        frame: spillFrame!, presentationFrame: position,
                        display: display, output: output
                    )
                }
            } else {
                if configuration.spillDeliveryMode == .editorialEncodedAdd {
                    guard let display else {
                        throw NativeOutputError.unsupported(
                            "Fusion Editorial still requiere el writer Metal"
                        )
                    }
                    let output = try requiredOutputTransform(configuration)
                    let deviceFrame = try display.makeIndependentLinearACEScgFrame(
                        width: prepared.width, height: prepared.height,
                        rgba: prepared.deviceRGBA
                    )
                    let encodedDevice = try display.renderIndependentRGBAFloat(
                        deviceFrame, output: output, alpha: .straight
                    )
                    if editorialEncodedBlack == nil {
                        let blackFrame = try display.makeIndependentLinearACEScgFrame(
                            width: 1, height: 1, rgba: [0, 0, 0, 1]
                        )
                        let encodedBlack = try display.renderIndependentRGBAFloat(
                            blackFrame, output: output, alpha: .ignore
                        )
                        editorialEncodedBlack = SIMD3(
                            encodedBlack[0], encodedBlack[1], encodedBlack[2]
                        )
                    }
                    let encodedSpill = try NativeOutputRenderer.editorialEncodedAddSpill(
                        encodedCarrier: encodedDevice,
                        encodedBlack: editorialEncodedBlack!
                    )
                    try writeEncodedStillPass(
                        encodedDevice, width: prepared.width, height: prepared.height,
                        to: deviceURL, configuration: configuration, output: output,
                        alpha: .straight
                    )
                    try writeEncodedStillPass(
                        encodedSpill, width: prepared.width, height: prepared.height,
                        to: spillURL, configuration: configuration, output: output,
                        alpha: .straight
                    )
                } else {
                    try writeStillPass(
                        prepared.deviceRGBA, width: prepared.width, height: prepared.height,
                        to: deviceURL, configuration: configuration, display: display,
                        alpha: .straight
                    )
                    try writeStillPass(
                        prepared.spillRGBA, width: prepared.width, height: prepared.height,
                        to: spillURL, configuration: configuration, display: display,
                        alpha: .ignore
                    )
                }
            }

            progress(position + 1, frames.count)
        }
        try await deviceMovie?.finish()
        try await spillMovie?.finish()
        guard let prepared = firstPrepared else { throw FusionScenePackageError.invalidRaster }
        guard request.outputPlan.generatedRelativePaths.count >= 2 else {
            throw FusionScenePackageError.invalidOutputManifest
        }
        let compRelative = request.outputPlan.generatedRelativePaths[
            request.outputPlan.generatedRelativePaths.count - 2
        ]
        let compURL = request.outputPlan.destination.appendingPathComponent(compRelative)
        try request.outputPlan.authorizeWrite(
            to: compURL, policy: configuration.overwritePolicy
        )
        try fusionComp(request: request, prepared: prepared)
            .write(to: compURL, atomically: true, encoding: .utf8)

        let metadata = try metadata(request: request, prepared: prepared)
        let metadataRelative = request.outputPlan.generatedRelativePaths[
            request.outputPlan.generatedRelativePaths.count - 1
        ]
        let metadataURL = request.outputPlan.destination.appendingPathComponent(metadataRelative)
        try request.outputPlan.authorizeWrite(
            to: metadataURL, policy: configuration.overwritePolicy
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
        return request.outputPlan.destination
    }

    private static func requiredOutputTransform(
        _ configuration: StudioResolvedRenderConfiguration
    ) throws -> StudioColorOutputTransform {
        guard let output = try NativeOutputRenderer.outputTransform(for: configuration) else {
            throw NativeOutputError.unsupported("el preset Fusion no define encoding de entrega")
        }
        return output
    }

    private static func makeACEScgFrame(
        _ rgba: [Float], width: Int, height: Int,
        display: StudioColorMetalDisplay
    ) throws -> StudioColorMetalFrame {
        guard let identity = StudioColorInputTransform.catalog.first(where: { $0.id == "acescg" }) else {
            throw NativeOutputError.unsupported("falta el Input Transform ACEScg")
        }
        return try display.makeACEScgFrame(
            width: width, height: height, encodedRGBA: rgba,
            input: identity, alpha: .ignore
        )
    }

    private static func writeStillPass(
        _ rgba: [Float], width: Int, height: Int, to url: URL,
        configuration: StudioResolvedRenderConfiguration,
        display: StudioColorMetalDisplay?,
        alpha: StudioColorAlphaAssociation
    ) throws {
        switch configuration.format {
        case .openEXR:
            var values = rgba
            if configuration.target == .aces2065 {
                let processor = try StudioColorEngine.bundled().cachedColorSpaceProcessor(
                    source: "ACEScg", destination: "ACES2065-1"
                )
                try processor.apply(toRGBA: &values)
            } else if configuration.target != .acescg {
                guard let display else {
                    throw NativeOutputError.unsupported(
                        "Fusion OpenEXR encoded requiere el writer Metal"
                    )
                }
                let frame = try makeACEScgFrame(
                    rgba, width: width, height: height, display: display
                )
                values = try display.renderRGBAFloat(
                    frame, output: requiredOutputTransform(configuration), alpha: alpha
                )
            }
            try NativeOutputRenderer.encodeEXR(values, width: width, height: height)
                .write(to: url, options: .atomic)
        case .dpx10RGB, .tiff16:
            guard let display else {
                throw NativeOutputError.unsupported("Fusion still encoded requiere el writer Metal")
            }
            let frame = try makeACEScgFrame(rgba, width: width, height: height, display: display)
            let output = try requiredOutputTransform(configuration)
            let rendered = try display.renderRGBAFloat(
                frame, output: output, alpha: alpha
            )
            if configuration.format == .dpx10RGB {
                try NativeOutputRenderer.encodeDPX(rendered, width: width, height: height)
                    .write(to: url, options: .atomic)
            } else {
                try NativeOutputRenderer.encodeTIFF16(
                    rendered, width: width, height: height,
                    colorSpace: output.colorSpace, alpha: alpha
                ).write(to: url, options: .atomic)
            }
        default:
            throw NativeOutputError.unsupported(configuration.format.displayName)
        }
    }

    private static func writeEncodedStillPass(
        _ rgba: [Float], width: Int, height: Int, to url: URL,
        configuration: StudioResolvedRenderConfiguration,
        output: StudioColorOutputTransform,
        alpha: StudioColorAlphaAssociation
    ) throws {
        guard rgba.count == width * height * 4, rgba.allSatisfy(\.isFinite) else {
            throw NativeOutputError.invalidFrame
        }
        switch configuration.format {
        case .openEXR:
            try NativeOutputRenderer.encodeEXR(rgba, width: width, height: height)
                .write(to: url, options: .atomic)
        case .tiff16:
            try NativeOutputRenderer.encodeTIFF16(
                rgba, width: width, height: height,
                colorSpace: output.colorSpace, alpha: alpha
            ).write(to: url, options: .atomic)
        default:
            throw NativeOutputError.unsupported(configuration.format.displayName)
        }
    }

    /// Rewrites only the generated Fusion composition from the immutable queued snapshot and
    /// the package's existing raster metadata. Media frames are intentionally never opened,
    /// rewritten or re-rendered here.
    static func refreshComposition(request: FusionScenePackageRequest) throws {
        let outputStem = request.configuration.jobName + request.configuration.versionSuffix
        let metadataURL = request.outputPlan.destination.appendingPathComponent(
            "metadata/\(outputStem)_FusionScene.json"
        )
        let metadata = try JSONDecoder().decode(
            FusionSceneMetadata.self, from: Data(contentsOf: metadataURL)
        )
        guard metadata.schema == "ScreenSimulation.FusionScenePackage",
              metadata.schemaVersion == 2,
              metadata.jobName == request.configuration.jobName,
              metadata.firstFrame == request.configuration.firstFrame,
              metadata.lastFrame == request.configuration.lastFrame,
              metadata.dofMode == request.configuration.fusionScene?.dofMode,
              metadata.raster.width > 0,
              metadata.raster.height > 0,
              metadata.raster.deviceWidthMeters > 0,
              metadata.raster.deviceHeightMeters > 0,
              metadata.raster.activeDeviceRect.width > 0,
              metadata.raster.activeDeviceRect.height > 0
        else { throw FusionScenePackageError.invalidRaster }
        // The existing EXRs and their sidecar are the authority for a composition-only refresh.
        // Library presets may have changed since this completed queue item was rendered; using a
        // newly resolved raster or camera here would make the regenerated comp disagree with the
        // media it loads. Only scene-owned plate/delivery data comes from the immutable queue job.
        let pixelsPerMeter = max(
            Double(metadata.raster.activeDeviceRect.width)
                / metadata.raster.deviceWidthMeters,
            Double(metadata.raster.activeDeviceRect.height)
                / metadata.raster.deviceHeightMeters
        )
        let refreshRequest = FusionScenePackageRequest(
            configuration: request.configuration,
            outputPlan: request.outputPlan,
            deviceWidthMeters: metadata.raster.deviceWidthMeters,
            deviceHeightMeters: metadata.raster.deviceHeightMeters,
            activeRaster: FusionProjectedRaster(
                activeWidth: metadata.raster.activeDeviceRect.width,
                activeHeight: metadata.raster.activeDeviceRect.height,
                pixelsPerMeter: pixelsPerMeter
            ),
            sourceOverscanPixels: metadata.spill.sourceOverscanPixels,
            deliveryWidth: request.deliveryWidth,
            deliveryHeight: request.deliveryHeight,
            camera: metadata.camera,
            lens: metadata.lens,
            motionBlur: metadata.motionBlur,
            referencePlate: request.referencePlate
        )
        try refreshRequest.validate()
        let prepared = FusionPreparedPhysicalFrame(
            width: metadata.raster.width,
            height: metadata.raster.height,
            activeRect: metadata.raster.activeDeviceRect,
            uniformPaddingPixels: metadata.raster.uniformPaddingPixels,
            thresholdSupportPixels: metadata.spill.thresholdSupportPixels,
            deviceRGBA: [],
            spillRGBA: []
        )
        let compURL = request.outputPlan.destination.appendingPathComponent(
            "fusion/\(outputStem).comp"
        )
        try FileManager.default.createDirectory(
            at: compURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fusionComp(request: refreshRequest, prepared: prepared)
            .write(to: compURL, atomically: true, encoding: .utf8)
    }

    static func metadata(
        request: FusionScenePackageRequest,
        prepared: FusionPreparedPhysicalFrame
    ) throws -> FusionSceneMetadata {
        let configuration = request.configuration
        let outputStem = configuration.jobName + configuration.versionSuffix
        let options = configuration.fusionScene!
        let color = try FusionMediaColorContract.resolve(configuration)
        let editorialAdd = configuration.spillDeliveryMode == .editorialEncodedAdd
        return FusionSceneMetadata(
            schema: "ScreenSimulation.FusionScenePackage",
            schemaVersion: 2,
            jobName: configuration.jobName,
            firstFrame: configuration.firstFrame,
            lastFrame: configuration.lastFrame,
            frameRate: configuration.frameRate.framesPerSecond,
            colorSpace: "ACEScg",
            transfer: "scene-linear",
            channels: ["R", "G", "B", "A"],
            rgbMeaning: "two typed media: Device surface RGB and additive Spill RGB",
            alphaMeaning: editorialAdd
                ? "Device embeds physical occlusion alpha; Spill carries straight editorial alpha 0.125 and Fusion normalizes it to opaque before additive projection"
                : "Device media embeds the non-chromatic physical occlusion alpha; Spill is opaque RGB over black",
            alphaAssociation: editorialAdd
                ? "device-embedded-physical-alpha-spill-straight-editorial-0.125"
                : "device-embedded-physical-alpha-spill-opaque-black",
            physicalCompositeEquation: "resultRGB = deviceRGB + spillRGB + plateRGB * (1 - deviceA)",
            raster: .init(
                width: prepared.width,
                height: prepared.height,
                activeDeviceRect: prepared.activeRect,
                uniformPaddingPixels: prepared.uniformPaddingPixels,
                pixelAspect: 1,
                deviceWidthMeters: request.deviceWidthMeters,
                deviceHeightMeters: request.deviceHeightMeters,
                resolutionMode: options.resolutionMode
            ),
            spill: .init(
                thresholdSceneLinear: options.spillThresholdSceneLinear,
                fadeWidthPixels: options.spillFadeWidthPixels,
                thresholdSupportPixels: prepared.thresholdSupportPixels,
                sourceOverscanPixels: request.sourceOverscanPixels,
                physicalKernelSupportContract: "max(panel tail radius * amount / sqrt(2), cover glow radius when amount > 0 * 2), rounded outward in frontal pixels",
                dofSupportContract: "1024-point aperture-boundary scan plus one outward pixel",
                matteSupportContract: "all nonzero achromatic occlusion samples",
                luminanceCoefficientsACEScg: [0.272_228_72, 0.674_081_74, 0.053_689_52]
            ),
            dofMode: options.dofMode,
            dofBakedInEXR: options.dofMode == .baked,
            cameraCurvesExportedWhenBaked: true,
            motionBlur: request.motionBlur,
            lensReconstruction: .init(
                bakedInEXR: false,
                contract: "syntheyes-de4-radial-standard-degree4-v1",
                fusionTool: "LensDistort",
                fusionModel: "DE4RadialStandardDegree4",
                parameterMapping: "DistortionDegree2 = Brown k1 * 2; QuarticDistortionDegree4 = Brown k2 * 4; k3 and tangential must be exactly zero"
            ),
            camera: request.camera,
            lens: request.lens,
            deviceTransform: "identity-at-origin",
            mediaFormat: configuration.format,
            mediaEncoding: color.encodingDescription,
            mediaToACEScgTransform: color.transformDescription,
            deviceMediaPattern: configuration.format.isMovie
                ? "../media/\(outputStem)_Device.\(configuration.format.fileExtension)"
                : "../media/\(outputStem)_Device%08d.\(configuration.format.fileExtension)",
            spillMediaPattern: configuration.format.isMovie
                ? "../media/\(outputStem)_Spill.\(configuration.format.fileExtension)"
                : "../media/\(outputStem)_Spill%08d.\(configuration.format.fileExtension)",
            fusionComp: "../fusion/\(outputStem).comp"
        )
    }

    static func fusionComp(
        request: FusionScenePackageRequest,
        prepared: FusionPreparedPhysicalFrame
    ) throws -> String {
        let configuration = request.configuration
        let outputStem = configuration.jobName + configuration.versionSuffix
        let color = try FusionMediaColorContract.resolve(configuration)
        let firstCamera = request.camera[0]
        let dofEnabled = configuration.fusionScene!.dofMode == .fusion ? 1 : 0
        let deviceMedia = configuration.format.isMovie
            ? "Comp:/../media/\(outputStem)_Device.\(configuration.format.fileExtension)"
            : String(
                format: "Comp:/../media/%@_Device%08d.%@",
                outputStem, configuration.firstFrame,
                configuration.format.fileExtension
            )
        let spillMedia = configuration.format.isMovie
            ? "Comp:/../media/\(outputStem)_Spill.\(configuration.format.fileExtension)"
            : String(
                format: "Comp:/../media/%@_Spill%08d.%@",
                outputStem, configuration.firstFrame,
                configuration.format.fileExtension
            )
        let loaderFormatID = switch configuration.format {
        case .openEXR: "OpenEXRFormat"
        case .tiff16: "TIFFFormat"
        default: "QuickTimeMovies"
        }
        let mediaEncodingDescription = color.encodingDescription
        let mediaTransformDescription = color.transformDescription
        let deviceColorTool = color.fusionTool(
            name: "DeviceToACEScg", source: "DeviceRGBForColor", x: 330, y: 82.5
        )
        let spillColorTool = color.fusionTool(
            name: "SpillToACEScg", source: "SpillRGBForColor", x: 330, y: 346.5
        )
        let editorialAdd = configuration.spillDeliveryMode == .editorialEncodedAdd
        let spillAlphaDescription = editorialAdd
            ? "straight editorial alpha 0.125; applied after the RGB color transform"
            : "no alpha; opaque RGB already composed over black for Add"
        let spillLoaderAlphaSemantics = editorialAdd
            ? "straight-editorial-alpha-0.125"
            : "no-alpha-additive-over-black"
        let cameraX = fusionSpline(request.camera.map { ($0.frame, $0.positionMeters[0]) })
        let cameraY = fusionSpline(request.camera.map { ($0.frame, $0.positionMeters[1]) })
        let cameraZ = fusionSpline(request.camera.map { ($0.frame, $0.positionMeters[2]) })
        let euler = request.camera.map { camera in
            (camera.frame, fusionEulerDegrees(camera.quaternionXYZW))
        }
        let cameraRX = fusionSpline(euler.map { ($0.0, $0.1.x) })
        let cameraRY = fusionSpline(euler.map { ($0.0, $0.1.y) })
        let cameraRZ = fusionSpline(euler.map { ($0.0, $0.1.z) })
        let focal = fusionSpline(request.camera.map { ($0.frame, $0.focalLengthMillimeters) })
        let horizontalFOV = fusionSpline(request.camera.map {
            ($0.frame, $0.horizontalFOVDegrees)
        })
        let focus = fusionSpline(request.camera.map { ($0.frame, $0.focusDistanceMeters) })
        let fStop = fusionSpline(request.camera.map { ($0.frame, $0.fStop) })
        let apertureRadius = fusionSpline(request.camera.map {
            ($0.frame, $0.focalLengthMillimeters * 0.001 / (2 * $0.fStop))
        })
        let lensShiftX = fusionSpline(request.camera.map { ($0.frame, $0.lensShiftXY[0]) })
        let lensShiftY = fusionSpline(request.camera.map { ($0.frame, $0.lensShiftXY[1]) })
        let lensDegree2 = fusionSpline(request.lens.map {
            ($0.frame, $0.radialK1K2K3[0] * 2)
        })
        let lensDegree4 = fusionSpline(request.lens.map {
            ($0.frame, $0.radialK1K2K3[1] * 4)
        })
        let apertureWidthInches = firstCamera.sensorWidthMillimeters / 25.4
        let apertureHeightInches = firstCamera.sensorHeightMillimeters / 25.4
        let planeWidth = request.deviceWidthMeters
            * Double(prepared.width) / Double(prepared.activeRect.width)
        let planeHeight = request.deviceHeightMeters
            * Double(prepared.height) / Double(prepared.activeRect.height)
        // ImagePlane3D already derives its unscaled Y extent from the texture aspect ratio.
        // Its base width is one Fusion scene unit, so the physical dimensions must not be
        // halved or have the texture aspect applied a second time.
        let planeScaleX = planeWidth
        let planeScaleY = planeHeight * Double(prepared.width) / Double(prepared.height)
        // Each Loader alpha bypasses color conversion. RGB is transformed while temporarily
        // opaque, then explicitly associated with the original alpha exactly once for Fusion.
        // Their projected RGB
        // is added while Device alpha remains unchanged. The final Custom node implements the
        // physical equation directly; a Merge/Over node is intentionally absent.
        return """
        Composition {
          CurrentTime = \(configuration.firstFrame),
          RenderRange = { \(configuration.firstFrame), \(configuration.lastFrame) },
          GlobalRange = { \(configuration.firstFrame), \(configuration.lastFrame) },
          Tools = ordered() {
            ColorPipelineGuide = Note {
              Inputs = {
                Comments = Input { Value = "SCREEN SIMULATION - COLOR PIPELINE\\n\\nDEVICE MEDIA\\n- Path/pattern: ../media/\(outputStem)_Device\(configuration.format.isMovie ? ".\(configuration.format.fileExtension)" : "%08d.\(configuration.format.fileExtension)")\\n- Encoding: \(mediaEncodingDescription).\\n- Alpha: embedded physical occlusion alpha; bypasses color conversion and is associated after RGB reaches ACEScg.\\n- RGB transform to working space: \(mediaTransformDescription).\\n\\nSPILL MEDIA\\n- Path/pattern: ../media/\(outputStem)_Spill\(configuration.format.isMovie ? ".\(configuration.format.fileExtension)" : "%08d.\(configuration.format.fileExtension)")\\n- Encoding: \(mediaEncodingDescription).\\n- Alpha: \(spillAlphaDescription); bypasses color conversion.\\n- RGB transform to working space: \(mediaTransformDescription).\\n\\nPLATE / REFERENCE\\n- External authored absolute path is retained when present.\\n- ReferenceDepthFloat16 converts the Loader output to float16 before color processing.\\n- ReferenceToACEScg uses IDT_REC709_100_INV_ODT to ODT_ACESCG only for the exact saved ACES 2.0 Rec.709 D65 100 nit contract; otherwise it is explicitly disabled.\\n\\nWORKING SPACE\\n- ACEScg scene-linear.\\n- resultRGB = deviceRGB + spillRGB + plateRGB * (1 - deviceA).\\n\\nVIEWER (select manually)\\n- AcesTransform, ACES_VERSION_2_0_0, IDT_ACESCG to ODT_REC709_100.\\n- Gamut compression: None. Pre-Divide/Post-Multiply: enabled.\\n- Fusion Viewer UI state is not stored by this composition.\\n\\nSIDECAR\\n- ../metadata/\(outputStem)_FusionScene.json records raster, camera, lens, media and pass semantics." }
              },
              ViewInfo = StickyNoteInfo {
                Pos = { 28, -181.5 },
                Flags = { Expanded = true },
                Size = { 520, 330 }
              }
            },
            DeviceRGBA = Loader {
              Clips = { Clip {
                ID = "Clip1",
                Filename = "\(deviceMedia)",
                FormatID = "\(loaderFormatID)",
                StartFrame = \(configuration.firstFrame),
                Length = \(configuration.frameRange.count),
                LengthSetManually = true,
                TrimIn = 0,
                TrimOut = \(configuration.frameRange.count - 1),
                ExtendFirst = 0,
                ExtendLast = 0,
                Loop = 0,
                AspectMode = 0,
                Depth = 0,
                TimeCode = 0,
                GlobalStart = \(configuration.firstFrame),
                GlobalEnd = \(configuration.lastFrame)
              } },
              GlobalIn = \(configuration.firstFrame), GlobalOut = \(configuration.lastFrame),
              Inputs = {
                PostMultiplyByAlpha = Input { Value = 0 },
                ["Gamut.PreDividePostMultiply"] = Input { Value = 0 },
                ["Clip1.OpenEXRFormat.RedName"] = Input { Value = FuID { "R" } },
                ["Clip1.OpenEXRFormat.GreenName"] = Input { Value = FuID { "G" } },
                ["Clip1.OpenEXRFormat.BlueName"] = Input { Value = FuID { "B" } },
                ["Clip1.OpenEXRFormat.AlphaName"] = Input { Value = FuID { "A" } }
              },
              CustomData = { SourceEncoding = "\(mediaEncodingDescription)", AlphaSemantics = "embedded-physical-occlusion-alpha" },
              ViewInfo = OperatorInfo { Pos = { 110, 214.5 } }
            },
            DeviceRGBForColor = Custom {
              Inputs = {
                Image1 = Input { SourceOp = "DeviceRGBA", Source = "Output" },
                RedExpression = Input { Value = "r1" },
                GreenExpression = Input { Value = "g1" },
                BlueExpression = Input { Value = "b1" },
                AlphaExpression = Input { Value = "1" }
              },
              CustomData = { Role = "rgb-only-color-transform-input", OriginalAlpha = "DeviceRGBA.A" },
              ViewInfo = OperatorInfo { Pos = { 220, 214.5 } }
            },
            \(deviceColorTool)
            DeviceAssociateAlpha = Custom {
              Inputs = {
                Image1 = Input { SourceOp = "DeviceToACEScg", Source = "Output" },
                Image2 = Input { SourceOp = "DeviceRGBA", Source = "Output" },
                RedExpression = Input { Value = "r1*a2" },
                GreenExpression = Input { Value = "g1*a2" },
                BlueExpression = Input { Value = "b1*a2" },
                AlphaExpression = Input { Value = "a2" }
              },
              CustomData = { Role = "associate-original-alpha-after-color", AlphaSource = "DeviceRGBA.A" },
              ViewInfo = OperatorInfo { Pos = { 440, 82.5 } }
            },
            SpillRGBA = Loader {
              Clips = { Clip {
                ID = "Clip1",
                Filename = "\(spillMedia)",
                FormatID = "\(loaderFormatID)",
                StartFrame = \(configuration.firstFrame), Length = \(configuration.frameRange.count), LengthSetManually = true,
                TrimIn = 0, TrimOut = \(configuration.frameRange.count - 1), ExtendFirst = 0, ExtendLast = 0,
                Loop = 0, AspectMode = 0, Depth = 0, TimeCode = 0,
                GlobalStart = \(configuration.firstFrame), GlobalEnd = \(configuration.lastFrame)
              } },
              GlobalIn = \(configuration.firstFrame), GlobalOut = \(configuration.lastFrame),
              Inputs = {
                PostMultiplyByAlpha = Input { Value = 0 },
                ["Gamut.PreDividePostMultiply"] = Input { Value = 0 },
                ["Clip1.OpenEXRFormat.RedName"] = Input { Value = FuID { "R" } },
                ["Clip1.OpenEXRFormat.GreenName"] = Input { Value = FuID { "G" } },
                ["Clip1.OpenEXRFormat.BlueName"] = Input { Value = FuID { "B" } },
                ["Clip1.OpenEXRFormat.AlphaName"] = Input { Value = FuID { "A" } }
              },
              CustomData = { AlphaSemantics = "\(spillLoaderAlphaSemantics)" },
              ViewInfo = OperatorInfo { Pos = { 110, 346.5 } }
            },
            SpillRGBForColor = Custom {
              Inputs = {
                Image1 = Input { SourceOp = "SpillRGBA", Source = "Output" },
                RedExpression = Input { Value = "r1" },
                GreenExpression = Input { Value = "g1" },
                BlueExpression = Input { Value = "b1" },
                AlphaExpression = Input { Value = "1" }
              },
              CustomData = { Role = "rgb-only-color-transform-input", OriginalAlpha = "SpillRGBA.A" },
              ViewInfo = OperatorInfo { Pos = { 220, 346.5 } }
            },
            \(spillColorTool)
            SpillAssociateAlpha = Custom {
              Inputs = {
                Image1 = Input { SourceOp = "SpillToACEScg", Source = "Output" },
                Image2 = Input { SourceOp = "SpillRGBA", Source = "Output" },
                RedExpression = Input { Value = "r1*a2" },
                GreenExpression = Input { Value = "g1*a2" },
                BlueExpression = Input { Value = "b1*a2" },
                AlphaExpression = Input { Value = "1" }
              },
              CustomData = { Role = "attenuate-additive-rgb-once-after-color", AlphaSource = "SpillRGBA.A", PlaneAlpha = "opaque" },
              ViewInfo = OperatorInfo { Pos = { 440, 346.5 } }
            },
            DeviceRGBAPlane = ImagePlane3D {
              Inputs = {
                MaterialInput = Input { SourceOp = "DeviceAssociateAlpha", Source = "Output" },
                ["Transform3DOp.ScaleLock"] = Input { Value = 0 },
                ["Transform3DOp.Scale.X"] = Input { Value = \(planeScaleX) },
                ["Transform3DOp.Scale.Y"] = Input { Value = \(planeScaleY) },
                ["Transform3DOp.Scale.Z"] = Input { Value = 1 }
              },
              CustomData = { TransformContract = "identity-at-origin", WidthMeters = \(planeWidth), HeightMeters = \(planeHeight), TextureAspectAppliedByImagePlane3D = true, ActiveRect = "\(prepared.activeRect.x),\(prepared.activeRect.y),\(prepared.activeRect.width),\(prepared.activeRect.height)" },
              ViewInfo = OperatorInfo { Pos = { 440, 148.5 } }
            },
            SpillRGBPlane = ImagePlane3D {
              Inputs = {
                MaterialInput = Input { SourceOp = "SpillAssociateAlpha", Source = "Output" },
                ["Transform3DOp.ScaleLock"] = Input { Value = 0 },
                ["Transform3DOp.Scale.X"] = Input { Value = \(planeScaleX) },
                ["Transform3DOp.Scale.Y"] = Input { Value = \(planeScaleY) },
                ["Transform3DOp.Scale.Z"] = Input { Value = 1 }
              },
              CustomData = { TransformContract = "identity-at-origin", Role = "additive-spill" },
              ViewInfo = OperatorInfo { Pos = { 605, 346.5 } }
            },
            Camera3D_Device = Camera3D {
              Inputs = {
                ["Transform3DOp.Translate.X"] = Input { SourceOp = "CameraX", Source = "Value" },
                ["Transform3DOp.Translate.Y"] = Input { SourceOp = "CameraY", Source = "Value" },
                ["Transform3DOp.Translate.Z"] = Input { SourceOp = "CameraZ", Source = "Value" },
                ["Transform3DOp.Rotate.X"] = Input { SourceOp = "CameraRX", Source = "Value" },
                ["Transform3DOp.Rotate.Y"] = Input { SourceOp = "CameraRY", Source = "Value" },
                ["Transform3DOp.Rotate.Z"] = Input { SourceOp = "CameraRZ", Source = "Value" },
                FLength = Input { SourceOp = "CameraFocal", Source = "Value" },
                PlaneOfFocus = Input { SourceOp = "CameraFocus", Source = "Value" },
                LensShiftX = Input { SourceOp = "CameraLensShiftX", Source = "Value" },
                LensShiftY = Input { SourceOp = "CameraLensShiftY", Source = "Value" },
                FilmGate = Input { Value = FuID { "User" } },
                AovType = Input { Value = 1 },
                AoV = Input { SourceOp = "CameraHorizontalFOV", Source = "Value" },
                ApertureW = Input { Value = \(apertureWidthInches) },
                ApertureH = Input { Value = \(apertureHeightInches) },
                PerspAdaptiveClip = Input { Value = 0 },
                PerspNearClip = Input { Value = \(firstCamera.nearClipMeters) },
                PerspFarClip = Input { Value = \(firstCamera.farClipMeters) },
                IDepth = Input { Value = \(firstCamera.focusDistanceMeters) }
              },
              CustomData = { FStopCurve = "CameraFStop", ApertureRadiusCurve = "CameraApertureRadius", ExactQuaternionCurves = "Comp:/../metadata/\(outputStem)_FusionScene.json" },
              ViewInfo = OperatorInfo { Pos = { 440, 412.5 } }
            },
            CameraX = BezierSpline { KeyFrames = { \(cameraX) } },
            CameraY = BezierSpline { KeyFrames = { \(cameraY) } },
            CameraZ = BezierSpline { KeyFrames = { \(cameraZ) } },
            CameraRX = BezierSpline { KeyFrames = { \(cameraRX) } },
            CameraRY = BezierSpline { KeyFrames = { \(cameraRY) } },
            CameraRZ = BezierSpline { KeyFrames = { \(cameraRZ) } },
            CameraFocal = BezierSpline { KeyFrames = { \(focal) } },
            CameraHorizontalFOV = BezierSpline { KeyFrames = { \(horizontalFOV) } },
            CameraFocus = BezierSpline { KeyFrames = { \(focus) } },
            CameraFStop = BezierSpline { KeyFrames = { \(fStop) } },
            CameraApertureRadius = BezierSpline { KeyFrames = { \(apertureRadius) } },
            CameraLensShiftX = BezierSpline { KeyFrames = { \(lensShiftX) } },
            CameraLensShiftY = BezierSpline { KeyFrames = { \(lensShiftY) } },
            LensDE4Degree2 = BezierSpline { KeyFrames = { \(lensDegree2) } },
            LensDE4Degree4 = BezierSpline { KeyFrames = { \(lensDegree4) } },
            DeviceRGBAScene3D = Merge3D {
              Inputs = {
                SceneInput1 = Input { SourceOp = "DeviceRGBAPlane", Source = "Output" },
                SceneInput2 = Input { SourceOp = "Camera3D_Device", Source = "Output" }
              },
              ViewInfo = OperatorInfo { Pos = { 605, 148.5 } }
            },
            SpillRGBScene3D = Merge3D {
              Inputs = {
                SceneInput1 = Input { SourceOp = "SpillRGBPlane", Source = "Output" },
                SceneInput2 = Input { SourceOp = "Camera3D_Device", Source = "Output" }
              },
              ViewInfo = OperatorInfo { Pos = { 770, 346.5 } }
            },
            RenderDeviceRGBA = Renderer3D {
              Inputs = {
                SceneInput = Input { SourceOp = "DeviceRGBAScene3D", Source = "Output" },
                Width = Input { Value = \(request.deliveryWidth) },
                Height = Input { Value = \(request.deliveryHeight) },
                PixelAspect = Input { Value = { 1, 1 } },
                CameraSelector = Input { Value = FuID { "Camera3D_Device" } },
                RendererType = Input { Value = FuID { "RendererOpenGL" } },
                MotionBlur = Input { Value = 1 },
                Quality = Input { Value = \(configuration.motionSamples) },
                ShutterAngle = Input { Value = \(request.motionBlur.shutterAngleDegrees) },
                CenterBias = Input { Value = \(request.motionBlur.fusionCenterBias) },
                ["RendererOpenGL.EnableAccumEffects"] = Input { Value = \(dofEnabled) },
                ["RendererOpenGL.EnableAccumDepthOfField"] = Input { Value = \(dofEnabled) },
                ["RendererOpenGL.AccumQuality"] = Input { Value = 32 },
                ["RendererOpenGL.DoFBlur"] = Input { SourceOp = "CameraApertureRadius", Source = "Value" },
                ["RendererOpenGL.MaximumTextureDepth"] = Input { Value = 4 }
              },
              ViewInfo = OperatorInfo { Pos = { 770, 148.5 } }
            },
            RenderSpillRGB = Renderer3D {
              Inputs = {
                SceneInput = Input { SourceOp = "SpillRGBScene3D", Source = "Output" },
                Width = Input { Value = \(request.deliveryWidth) },
                Height = Input { Value = \(request.deliveryHeight) },
                PixelAspect = Input { Value = { 1, 1 } },
                CameraSelector = Input { Value = FuID { "Camera3D_Device" } },
                RendererType = Input { Value = FuID { "RendererOpenGL" } },
                MotionBlur = Input { Value = 1 },
                Quality = Input { Value = \(configuration.motionSamples) },
                ShutterAngle = Input { Value = \(request.motionBlur.shutterAngleDegrees) },
                CenterBias = Input { Value = \(request.motionBlur.fusionCenterBias) },
                ["RendererOpenGL.EnableAccumEffects"] = Input { Value = \(dofEnabled) },
                ["RendererOpenGL.EnableAccumDepthOfField"] = Input { Value = \(dofEnabled) },
                ["RendererOpenGL.AccumQuality"] = Input { Value = 32 },
                ["RendererOpenGL.DoFBlur"] = Input { SourceOp = "CameraApertureRadius", Source = "Value" },
                ["RendererOpenGL.MaximumTextureDepth"] = Input { Value = 4 }
              },
              ViewInfo = OperatorInfo { Pos = { 935, 346.5 } }
            },
            AddProjectedDeviceSpill = Custom {
              Inputs = {
                Image1 = Input { SourceOp = "RenderDeviceRGBA", Source = "Output" },
                Image2 = Input { SourceOp = "RenderSpillRGB", Source = "Output" },
                RedExpression = Input { Value = "r1+r2" },
                GreenExpression = Input { Value = "g1+g2" },
                BlueExpression = Input { Value = "b1+b2" },
                AlphaExpression = Input { Value = "a1" }
              },
              CustomData = { Equation = "projectedDeviceRGB + projectedSpillRGB", AlphaSemantics = "preserve-projected-device-alpha" },
              ViewInfo = OperatorInfo { Pos = { 935, 148.5 } }
            },
            DeviceLensDistortion = LensDistort {
              Inputs = {
                Mode = Input { Value = 1 },
                ClippingMode = Input { Value = FuID { "Domain" } },
                LensDistortionModel = Input { Value = 1 },
                Model = Input { Value = FuID { "DE4RadialStandardDegree4" } },
                ["DE4RadialStandardDegree4.DistortionDegree2"] = Input { SourceOp = "LensDE4Degree2", Source = "Value" },
                ["DE4RadialStandardDegree4.QuarticDistortionDegree4"] = Input { SourceOp = "LensDE4Degree4", Source = "Value" },
                UseSourcePixelAspect = Input { Value = 0 },
                PixelAspect = Input { Value = { 1, 1 } },
                FLength = Input { SourceOp = "CameraFocal", Source = "Value" },
                FilmGate = Input { Value = FuID { "User" } },
                ApertureW = Input { Value = \(apertureWidthInches) },
                ApertureH = Input { Value = \(apertureHeightInches) },
                LensShiftX = Input { SourceOp = "CameraLensShiftX", Source = "Value" },
                LensShiftY = Input { SourceOp = "CameraLensShiftY", Source = "Value" },
                Input = Input { SourceOp = "AddProjectedDeviceSpill", Source = "Output" }
              },
              CustomData = { Contract = "syntheyes-de4-radial-standard-degree4-v1", LensBakedInEXR = false },
              ViewInfo = OperatorInfo { Pos = { 1100, 214.5 } }
            },
            \(fusionPlateComp(
                request.referencePlate,
                firstFrame: configuration.firstFrame,
                lastFrame: configuration.lastFrame,
                deliveryWidth: request.deliveryWidth,
                deliveryHeight: request.deliveryHeight
            ))
            PhysicalComposite = Custom {
              Inputs = {
                Image1 = Input { SourceOp = "DeviceLensDistortion", Source = "Output" },
                Image2 = Input { SourceOp = "PlateInput", Source = "Output" },
                RedExpression = Input { Value = "r1+r2*(1-a1)" },
                GreenExpression = Input { Value = "g1+g2*(1-a1)" },
                BlueExpression = Input { Value = "b1+b2*(1-a1)" },
                AlphaExpression = Input { Value = "max(a1,a2)" }
              },
              CustomData = {
                Operation = "DEVICE_PLUS_OCCLUDED_PLATE",
                Equation = "resultRGB = deviceRGB + spillRGB + plateRGB * (1 - deviceA)",
                ConventionalOverForbidden = true
              },
              ViewInfo = OperatorInfo { Pos = { 1265, 214.5 } }
            }
          },
          Prefs = {
            Comp = {
              Info = { Comments = "SCREEN-SIMULATION Fusion Scene Package · ACEScg scene-linear" },
              FrameFormat = {
                Name = "Custom",
                Width = \(request.deliveryWidth),
                Height = \(request.deliveryHeight),
                Rate = \(configuration.frameRate.framesPerSecond),
                AspectX = 1,
                AspectY = 1,
                GuideRatio = \(Double(request.deliveryWidth) / Double(request.deliveryHeight)),
                DepthFull = 2,
                DepthPreview = 2,
                DepthInteractive = 2
              },
              Unsorted = {
                GlobalStart = \(configuration.firstFrame),
                GlobalEnd = \(configuration.lastFrame)
              }
            }
          }
        }
        """
    }

    private static func fusionPlateComp(
        _ reference: FusionReferencePlate?,
        firstFrame: Int,
        lastFrame: Int,
        deliveryWidth: Int,
        deliveryHeight: Int
    ) -> String {
        guard let reference else {
            return """
            PlateInput = Background {
              CustomData = { Role = "NO_SAVED_REFERENCE" },
              ViewInfo = OperatorInfo { Pos = { 1100, 346.5 } }
            },
            """
        }
        let destinationWidth = deliveryWidth
        let destinationHeight = deliveryHeight
        let sourceAspect = Double(reference.width) / Double(reference.height)
        let fit = reference.placementID == "fit"
        let stretch = reference.placementID == "stretch"
        let scale = stretch ? 1.0 : (fit
            ? min(Double(deliveryWidth) / Double(reference.width), Double(deliveryHeight) / Double(reference.height))
            : max(Double(deliveryWidth) / Double(reference.width), Double(deliveryHeight) / Double(reference.height)))
        let resizedWidth = stretch ? deliveryWidth : Int((Double(reference.width) * scale).rounded())
        let resizedHeight = stretch ? deliveryHeight : Int((Double(reference.height) * scale).rounded())
        let colorTransformPassThrough = reference.colorTransform == .disabled
            ? "  PassThrough = true,\n" : ""
        let colorTransformEnabled = reference.colorTransform == .disabled ? "false" : "true"
        _ = sourceAspect
        return """
        ReferenceLoader = Loader {
          Clips = { Clip {
            ID = "Clip1",
            Filename = "\(fusionEscapedPath(reference.sourceURL))",
            FormatID = "QuickTimeMovies",
            StartFrame = \(firstFrame),
            Length = \(lastFrame - firstFrame + 1),
            Multiframe = true,
            TrimIn = 0,
            TrimOut = \(lastFrame - firstFrame),
            ExtendFirst = 0,
            ExtendLast = 0,
            Loop = 1,
            AspectMode = 0,
            Depth = 0,
            TimeCode = 0,
            GlobalStart = \(firstFrame),
            GlobalEnd = \(lastFrame)
          } },
          GlobalIn = \(firstFrame), GlobalOut = \(lastFrame),
          ViewInfo = OperatorInfo { Pos = { 1100, 346.5 } }
        },
        ReferenceDepthFloat16 = ChangeDepth {
          CtrlWZoom = false,
          Inputs = {
            Depth = Input { Value = 3 },
            Input = Input { SourceOp = "ReferenceLoader", Source = "Output" }
          },
          CustomData = { Role = "reference-minimum-float16-boundary" },
          ViewInfo = OperatorInfo { Pos = { 1183.33, 345.894 } }
        },
        ReferenceToACEScg = AcesTransform {
        \(colorTransformPassThrough)  CustomData = { Role = "saved-reference-color-transform", InputTransformID = "\(reference.inputTransformID)", ColorTransformContract = "ACES 2.0 Rec.709 D65 100 nit inverse Output Transform to ACEScg", Enabled = \(colorTransformEnabled) },
          CtrlWZoom = false,
          Inputs = {
            AcesVersion = Input { Value = FuID { "ACES_VERSION_2_0_0" } },
            InputTransform200 = Input { Value = FuID { "IDT_REC709_100_INV_ODT" } },
            OutputTransform200 = Input { Value = FuID { "ODT_ACESCG" } },
            Input = Input { SourceOp = "ReferenceDepthFloat16", Source = "Output" }
          },
          ViewInfo = OperatorInfo { Pos = { 1265, 346.5 } }
        },
        ReferenceResize = BetterResize {
          Inputs = {
            Width = Input { Value = \(resizedWidth) },
            Height = Input { Value = \(resizedHeight) },
            KeepAspect = Input { Value = \(stretch ? 0 : 1) },
            Input = Input { SourceOp = "ReferenceToACEScg", Source = "Output" }
          },
          CustomData = { Role = "delivery-raster-placement", Placement = "\(reference.placementID)", DeliveryWidth = \(destinationWidth), DeliveryHeight = \(destinationHeight), Centered = true },
          ViewInfo = OperatorInfo { Pos = { 1430, 346.5 } }
        },
        PlateCanvas = Background {
          Inputs = { Width = Input { Value = \(destinationWidth) }, Height = Input { Value = \(destinationHeight) }, Alpha = Input { Value = 0 } },
          ViewInfo = OperatorInfo { Pos = { 1430, 412.5 } }
        },
        PlateInput = Merge {
          Inputs = {
            Background = Input { SourceOp = "PlateCanvas", Source = "Output" },
            Foreground = Input { SourceOp = "ReferenceResize", Source = "Output" },
            Center = Input { Value = { 0.5, 0.5 } },
            PerformDepthMerge = Input { Value = 0 }
          },
          CustomData = { Role = "centered-reference-delivery-raster", Placement = "\(reference.placementID)" },
          ViewInfo = OperatorInfo { Pos = { 1595, 346.5 } }
        },
        """
    }

    private static func fusionEscapedPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func fusionSpline(_ values: [(Int, Double)]) -> String {
        values.map { frame, value in
            "[\(frame)] = { \(value), RH = { \(frame), \(value) }, Flags = { Linear = true } }"
        }.joined(separator: ", ")
    }

    static func fusionEulerDegrees(_ quaternion: [Double]) -> SIMD3<Double> {
        let x = quaternion[0]
        let y = quaternion[1]
        let z = quaternion[2]
        let w = quaternion[3]
        let roll = atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
        let sinPitch = min(1, max(-1, 2 * (w * y - z * x)))
        let pitch = asin(sinPitch)
        let yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
        let degrees = 180 / Double.pi
        return SIMD3(roll * degrees, pitch * degrees, yaw * degrees)
    }

}
