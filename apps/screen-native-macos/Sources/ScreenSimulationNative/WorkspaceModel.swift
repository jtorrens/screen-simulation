@preconcurrency import AVFoundation
import AppKit
import Combine
import CryptoKit
import Foundation
import Metal
import OSLog
import ScreenPhysicalBridge
import ScreenSimulationPresentation
import simd
import StudioColor
import StudioMedia
import SwiftUI
import UniformTypeIdentifiers

enum NativeRenderButtonState: Equatable {
    case outdated
    case rendering(progress: Double)
    case cancelling(progress: Double)
    case complete

    static func resolve(
        frameState: PhysicalFrameState,
        progress: Double,
        hasActiveTask: Bool,
        cancellationRequested: Bool
    ) -> Self {
        if hasActiveTask, cancellationRequested || frameState != .rendering {
            return .cancelling(progress: min(0.99, max(0, progress)))
        }
        if hasActiveTask {
            // A worker may finish its kernels before its result texture and
            // terminal snapshot are available. Reserve 100% for .complete.
            return .rendering(progress: min(0.99, max(0, progress)))
        }
        if frameState == .complete {
            return .complete
        }
        return .outdated
    }
}

enum ReferenceMatchError: LocalizedError {
    case unknownDeliveryPlacement(String)
    case unsolved(String)

    var errorDescription: String? {
        switch self {
        case let .unknownDeliveryPlacement(value):
            "El Raster de entrega usa una colocación desconocida: \(value)."
        case let .unsolved(message):
            "No se puede resolver una cámara rígida con estos cuatro puntos: \(message)."
        }
    }
}

enum ReferenceMatchRasterMapping {
    private static func scaleAndOffset(
        referenceWidth: Int,
        referenceHeight: Int,
        cameraWidth: UInt32,
        cameraHeight: UInt32,
        deliveryPlacementID: String
    ) throws -> (scale: Double, offsetX: Double, offsetY: Double) {
        let gateWidth = Double(cameraWidth)
        let gateHeight = Double(cameraHeight)
        let outputWidth = Double(referenceWidth)
        let outputHeight = Double(referenceHeight)
        let scale: Double
        switch deliveryPlacementID {
        case "fit": scale = min(outputWidth / gateWidth, outputHeight / gateHeight)
        case "fill-crop": scale = max(outputWidth / gateWidth, outputHeight / gateHeight)
        case "one-to-one": scale = 1
        default: throw ReferenceMatchError.unknownDeliveryPlacement(deliveryPlacementID)
        }
        return (
            scale,
            (outputWidth - gateWidth * scale) * 0.5,
            (outputHeight - gateHeight * scale) * 0.5
        )
    }

    static func cameraGateCorners(
        _ referenceCorners: [CGPoint],
        referenceWidth: Int,
        referenceHeight: Int,
        cameraWidth: UInt32,
        cameraHeight: UInt32,
        deliveryPlacementID: String
    ) throws -> [CGPoint] {
        let mapping = try scaleAndOffset(
            referenceWidth: referenceWidth, referenceHeight: referenceHeight,
            cameraWidth: cameraWidth, cameraHeight: cameraHeight,
            deliveryPlacementID: deliveryPlacementID
        )
        return referenceCorners.map { point in
            CGPoint(
                x: (Double(point.x) + 0.5 - mapping.offsetX) / mapping.scale - 0.5,
                y: (Double(point.y) + 0.5 - mapping.offsetY) / mapping.scale - 0.5
            )
        }
    }

    static func referenceCorners(
        _ cameraGateCorners: [CGPoint],
        referenceWidth: Int,
        referenceHeight: Int,
        cameraWidth: UInt32,
        cameraHeight: UInt32,
        deliveryPlacementID: String
    ) throws -> [CGPoint] {
        let mapping = try scaleAndOffset(
            referenceWidth: referenceWidth, referenceHeight: referenceHeight,
            cameraWidth: cameraWidth, cameraHeight: cameraHeight,
            deliveryPlacementID: deliveryPlacementID
        )
        return cameraGateCorners.map { point in
            CGPoint(
                x: (Double(point.x) + 0.5) * mapping.scale + mapping.offsetX - 0.5,
                y: (Double(point.y) + 0.5) * mapping.scale + mapping.offsetY - 0.5
            )
        }
    }

    static func previewPoints(
        _ cameraGatePoints: [CGPoint],
        deliveryWidth: Int,
        deliveryHeight: Int,
        previewWidth: Int,
        previewHeight: Int,
        cameraWidth: UInt32,
        cameraHeight: UInt32,
        deliveryPlacementID: String
    ) throws -> [CGPoint] {
        guard deliveryWidth > 0, deliveryHeight > 0,
              previewWidth > 0, previewHeight > 0
        else { throw ReferenceMatchError.unsolved("el raster de entrega o preview no es válido") }
        let deliveryPoints = try referenceCorners(
            cameraGatePoints,
            referenceWidth: deliveryWidth,
            referenceHeight: deliveryHeight,
            cameraWidth: cameraWidth,
            cameraHeight: cameraHeight,
            deliveryPlacementID: deliveryPlacementID
        )
        let scaleX = Double(previewWidth) / Double(deliveryWidth)
        let scaleY = Double(previewHeight) / Double(deliveryHeight)
        return deliveryPoints.map { point in
            CGPoint(
                x: (Double(point.x) + 0.5) * scaleX - 0.5,
                y: (Double(point.y) + 0.5) * scaleY - 0.5
            )
        }
    }
}

enum ReferenceTimelineAuthority {
    static func resolve(
        source: NativeVideoTimelineInfo,
        reference: NativeVideoTimelineInfo?,
        referenceVisible: Bool,
        tracking: NativeVideoTimelineInfo? = nil
    ) -> NativeVideoTimelineInfo {
        if referenceVisible, let reference { return reference }
        if source.frameCount > 1 { return source }
        return tracking ?? source
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    enum ReferencePlate: String, CaseIterable, Identifiable, Codable, Sendable {
        case videoReference = "video-reference"
        case vfxChecker = "vfx-checker"
        case black
        case white
        case middleGray = "middle-gray"

        var id: String { rawValue }
        var label: String {
            switch self {
            case .videoReference: "Vídeo de referencia"
            case .vfxChecker: "Damero VFX"
            case .black: "Negro"
            case .white: "Blanco"
            case .middleGray: "Gris medio"
            }
        }
    }
    private struct SceneAuthoringEditSnapshot {
        let selection: TestAuthoringResolvedSelection
        let explicitOverrideControlIDs: Set<String>
    }

    private final class UndoManagerBox: @unchecked Sendable {
        weak var value: UndoManager?
        init(_ value: UndoManager?) { self.value = value }
    }

    private func registerUndo(
        with undoManager: UndoManager?,
        actionName: String,
        _ operation: @escaping @MainActor (WorkspaceModel, UndoManager?) -> Void
    ) {
        guard let undoManager else { return }
        let manager = UndoManagerBox(undoManager)
        let register = {
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    operation(target, manager.value)
                }
            }
        }
        if undoManager.isUndoing || undoManager.isRedoing {
            register()
            undoManager.setActionName(actionName)
        } else {
            let groupedByEvent = undoManager.groupsByEvent
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
            register()
            undoManager.setActionName(actionName)
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupedByEvent
        }
    }

    private var sceneAuthoringEditSnapshot: SceneAuthoringEditSnapshot? {
        testAuthoringSelection.map {
            SceneAuthoringEditSnapshot(
                selection: $0,
                explicitOverrideControlIDs: explicitSceneOverrideControlIDs
            )
        }
    }

    /// The sole commit boundary shared by descriptor cards and interactive modes.
    /// Callers identify only the stable controls they changed; they never mutate
    /// persisted override ownership themselves.
    private func commitSceneAuthoringEdit(
        selection: TestAuthoringResolvedSelection,
        setting controlIDs: Set<String>,
        resetting resetControlIDs: Set<String> = [],
        prior: SceneAuthoringEditSnapshot? = nil,
        profileDevice: DeviceDefinition? = nil,
        profileCoverGlass: CoverGlassDefinition? = nil,
        undoManager: UndoManager?,
        actionName: String
    ) throws {
        let prior = prior ?? sceneAuthoringEditSnapshot
        try applyTestAuthoringSelection(
            selection,
            profileDevice: profileDevice,
            profileCoverGlass: profileCoverGlass
        )
        explicitSceneOverrideControlIDs.formUnion(controlIDs)
        explicitSceneOverrideControlIDs.subtract(resetControlIDs)
        guard let prior else { return }
        registerUndo(with: undoManager, actionName: actionName) { target, manager in
            try? target.restoreSceneAuthoringEdit(
                prior,
                undoManager: manager,
                actionName: actionName
            )
        }
    }

    private func restoreSceneAuthoringEdit(
        _ snapshot: SceneAuthoringEditSnapshot,
        undoManager: UndoManager?,
        actionName: String
    ) throws {
        let inverse = sceneAuthoringEditSnapshot
        try applyTestAuthoringSelection(snapshot.selection)
        explicitSceneOverrideControlIDs = snapshot.explicitOverrideControlIDs
        guard let inverse else { return }
        registerUndo(with: undoManager, actionName: actionName) { target, manager in
            try? target.restoreSceneAuthoringEdit(
                inverse,
                undoManager: manager,
                actionName: actionName
            )
        }
    }

    func beginSceneControlEdit(_ controlID: String) {
        guard activeSceneControlEditID == nil,
              let snapshot = sceneAuthoringEditSnapshot
        else { return }
        activeSceneControlEditID = controlID
        activeSceneControlEditStart = snapshot
    }

    func endSceneControlEdit(_ controlID: String, undoManager: UndoManager?) {
        guard activeSceneControlEditID == controlID,
              let prior = activeSceneControlEditStart
        else { return }
        activeSceneControlEditID = nil
        activeSceneControlEditStart = nil
        guard let current = sceneAuthoringEditSnapshot,
              current.selection != prior.selection
                || current.explicitOverrideControlIDs != prior.explicitOverrideControlIDs
        else { return }
        registerUndo(with: undoManager, actionName: "Editar parámetro") { target, manager in
            try? target.restoreSceneAuthoringEdit(
                prior,
                undoManager: manager,
                actionName: "Editar parámetro"
            )
        }
    }

    enum SourcePlacement: String, CaseIterable, Identifiable {
        case fit = "Fit"
        case fillCrop = "Fill / Crop"
        case stretch = "Stretch"
        case oneToOne = "One to One"

        var id: String { rawValue }
        var stableID: String {
            switch self {
            case .fit: "fit"
            case .fillCrop: "fill-crop"
            case .stretch: "stretch"
            case .oneToOne: "one-to-one"
            }
        }
        init?(stableID: String) {
            switch stableID {
            case "fit": self = .fit
            case "fill-crop": self = .fillCrop
            case "stretch": self = .stretch
            case "one-to-one": self = .oneToOne
            default: return nil
            }
        }
        var physicalRasterPlacement: PhysicalRasterPlacement {
            switch self {
            case .fit: .fit
            case .fillCrop: .fillCrop
            case .stretch: .stretch
            case .oneToOne: .oneToOne
            }
        }
    }
    @Published var inputTransform = StudioColorInputTransform.catalog.first {
        $0.id == "srgb-encoded-rec709"
    }!
    @Published var previewTransform = StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-srgb-sdr-100"
    }!
    @Published var systemDisplayInfo = StudioColorSystemDisplayInfo.unavailable
    @Published var alphaMode = StudioAlphaMode.ignore
    @Published var signalColorModel = StudioSignalColorModel.rgb
    @Published var signalMatrix = StudioSignalMatrix.bt709
    @Published var signalRange = StudioSignalRange.full
    @Published var detection = SyntheticPattern.animatedCheckerboard.sourceDetection
    @Published var selectedPattern = SyntheticPattern.animatedCheckerboard
    @Published var sourceName = "Checker animado"
    @Published var sourceDetail = "Patrón SCREEN canónico · 960 × 540"
    @Published var status = "Preparado"
    @Published var metalFrame: StudioColorMetalFrame?
    private var publishedSceneIdentity: PublishedSceneIdentity?
    private var publishedResolvedSceneFrame: ResolvedSceneFrame?
    @Published private(set) var setupDeviceBoundary: [CGPoint] = []
    @Published private(set) var setupSensorGateBoundary: [CGPoint] = []
    @Published private(set) var focusSetupTarget: CGPoint?
    @Published private(set) var focusSetupTargetEnabled = false
    @Published private(set) var previewGizmosVisible = true
    @Published private(set) var referenceFrameName: String?
    @Published private(set) var referenceFrameDetail: String?
    @Published private(set) var referenceInputTransform = StudioColorInputTransform.catalog.first {
        $0.id == "srgb-encoded-rec709"
    }!
    @Published private(set) var referenceAlphaMode = StudioAlphaMode.ignore
    @Published private(set) var referenceSignalColorModel = StudioSignalColorModel.rgb
    @Published private(set) var referenceSignalMatrix = StudioSignalMatrix.bt709
    @Published private(set) var referenceSignalRange = StudioSignalRange.full
    @Published private(set) var referencePlacement = SourcePlacement.fit
    @Published private(set) var referencePlate = ReferencePlate.vfxChecker
    /// Authored 2D targets in Delivery-Raster pixels. They are independent of
    /// the current rigid projection and therefore never move during a solve.
    @Published private(set) var referenceMatchCorners: [CGPoint] = []
    @Published private(set) var referenceMatchProjectedCorners: [CGPoint] = []
    @Published private(set) var referenceMatchErrorPixels: Double?
    var referenceMatchFocalLengthMillimeters: Double? {
        testAuthoringSelection?.focalLengthMillimeters
    }
    @Published var referenceMatchEnabled = false
    // Scene manipulation is opt-in. A newly opened workspace therefore starts with the
    // Preview lock engaged and presents the closed-lock affordance until the user unlocks it.
    @Published private(set) var previewTransformationsLocked = true
    @Published private(set) var reflectionEnvironmentEditorEnabled = false
    @Published private(set) var environmentReflectionFramingEnabled = false
    @Published private(set) var environmentReflectionFraming = EnvironmentReflectionFraming()
    @Published private(set) var reflectionEmitters: [AuthoredReflectionEmitter] = []
    @Published private(set) var selectedReflectionEmitterID: UUID?
    @Published var reflectionEnvironmentWidth = 2048
    @Published private(set) var reflectionEnvironmentIsGenerating = false
    @Published private(set) var environmentSourceName: String?
    @Published private(set) var environmentSourceResolution: CGSize?
    @Published var errorMessage: String?
    @Published var currentFrame = 0 {
        didSet {
            guard currentFrame != oldValue else { return }
            applyTrackingCameraAtCurrentFrame()
        }
    }
    @Published var frameCount = 1
    @Published var frameRate = 24.0
    @Published private(set) var sceneAnimation = SceneAnimationDocument()
    @Published var isPlaying = false
    @Published var inFrame = 0
    @Published var outFrame = 0
    @Published var renderRange = StudioRenderRange.all
    @Published var renderMode = StudioRenderMode.preview
    @Published var renderJobName = "ScreenSimulation"
    @Published var renderVersionSuffix = ""
    @Published var renderOutputDirectoryPath = ""
    @Published var renderComposition = StudioRenderComposition.deviceAndSpillTogether
    @Published var renderSpillDeliveryMode = StudioSpillDeliveryMode.physicalLinear
    @Published var renderMotionBlurMode = StudioRenderMotionBlurMode.physical
    @Published var renderMotionSamples: UInt16 = 8
    @Published var renderRasterWidth: UInt32 = 1920
    @Published var renderRasterHeight: UInt32 = 1080
    @Published var renderRasterPlacementID = "fit"
    @Published var fusionDOFMode = StudioFusionDOFMode.fusion
    @Published var fusionResolutionMode = StudioFusionResolutionMode.maximumProjectedDensity
    @Published var fusionCustomWidth = 3840
    @Published var fusionCustomHeight = 2160
    @Published var fusionSpillThresholdSceneLinear = 0.0001
    @Published var fusionSpillFadeWidthPixels = 32
    @Published var includeFusionComposition = false
    @Published var loopPlayback = false
    @Published var outputFormat = StudioOutputFormat.proRes4444
    @Published var outputPixelEncoding = StudioPixelEncoding.yuv44412
    @Published var renderPreset: StudioRenderPreset
    @Published var renderWIPReviewPreset: StudioWIPReviewPreset?
    @Published var vfxInterchangeEncodingID = StudioVFXEditorialDeliveryContract.colorEncodingID
    @Published var peakNits = 100.0
    @Published var includeAudio = true
    @Published var outputAlphaMode = StudioAlphaMode.premultiplied
    @Published var outputSignalRange = StudioSignalRange.video
    @Published var decodeToPreviewMilliseconds = 0.0
    @Published private(set) var resolvedDevice: ResolvedDevice?
    @Published private(set) var modelDeviceDefinition: DeviceDefinition?
    @Published private(set) var physicalAuthoringState: PhysicalPipelineAuthoringState?
    @Published private(set) var requestedPhysicalIntermediate = PhysicalIntermediate.developedACEScg
    @Published private(set) var sourceACEScgFrame: StudioColorMetalFrame?
    @Published private(set) var originACEScgFrame: StudioColorMetalFrame?
    @Published private(set) var deviceSignalCheckpoint: DeviceSignalCheckpoint?
    @Published var sourcePlacement = SourcePlacement.fit
    @Published private(set) var armedPhysicalParameterIDs: Set<String> = []
    @Published private(set) var selectedCapturePresetID: String?
    @Published private(set) var selectedCaptureRasterModeID: String?
    @Published private(set) var selectedLensPresetID: String?
    private(set) var capturePresets: [CameraProfileDefinition]
    private(set) var lensPresets: [LensProfileDefinition]
    private(set) var environmentPresets: [EnvironmentProfileDefinition]
    @Published private(set) var physicalPublicationSummary = "Sin publicación física"
    @Published private(set) var trackingScene: TrackingScene?
    @Published private(set) var trackingSceneMethod = TrackingSceneMethod.fusionComposition
    @Published private(set) var fusionTrackerClipboard: FusionTrackerClipboard?
    @Published private(set) var fusionTrackerAnchorFrame: Int?
    @Published private(set) var fusionTrackerMotion: FusionTrackerPoseTrack?
    @Published var fusionTrackerTarget = FusionTrackerTarget.camera
    @Published var fusionTrackerMovesX = true
    @Published var fusionTrackerMovesY = true
    @Published var fusionTrackerScales = false
    @Published var fusionTrackerRotates = false
    @Published var fusionTrackerUsesCornerPin = false
    @Published var fusionTrackerSmoothingEnabled = false
    @Published var fusionTrackerSmoothingWindow = 9
    @Published var fusionTrackerSmoothingDegree = 2
    @Published var fusionTrackerCornerAssignments: [String: FusionTrackerCorner] = [:]
    @Published var selectedTrackingCameraID: String?
    @Published var selectedTrackingPointGroupID: String?
    @Published var trackingCameraEnabled = true
    @Published var trackingPointsVisible = true
    @Published var trackingGeometryVisible = true
    @Published var visibleTrackingMeshIDs: Set<String> = []
    @Published var trackingSynthEyesUnitValue = 1.0
    @Published var trackingSynthEyesUnit = "m"
    private var trackingScalePointAID: String?
    private var trackingScalePointBID: String?
    private var trackingMeasuredDistanceMeters = 1.0
    @Published private(set) var trackingMetersPerSourceUnit: Double?
    @Published private(set) var trackingScaleSelectionSlot: Int?
    @Published private(set) var testPresentation: TestPagePresentation?
    @Published private(set) var recordingEncodedBytes: Int?
    @Published private(set) var recordingEncodedSHA256: String?
    private var testAuthoringSelection: TestAuthoringResolvedSelection?
    private var explicitSceneOverrideControlIDs: Set<String> = []
    private var activeSceneControlEditID: String?
    private var activeSceneControlEditStart: SceneAuthoringEditSnapshot?
    private var sceneProfileBaselineByControlID: [String: SceneControlOverride] = [:]
    private let globalLibraryStore: GlobalLibraryStore
    private var globalLibraryDocument: GlobalLibraryDocument
    private var testAuthoringProfileContext: RustTestAuthoringProfileContext
    private var recordingCameraCheckpoint: StudioColorMetalFrame?
    private var deliveryRasterCheckpoint: DeliveryRasterExecution?
    private var recordingOutputExecution: RecordingOutputExecution?
    private var setupFramingRenderer: SetupFramingRenderer?
    private var environmentRadianceFrame: EnvironmentRadianceFrame?
    private var environmentSourceACEScgFrame: StudioColorMetalFrame?
    private var sourceAdjustmentOwner: SceneAdjustmentFrame?
    private var environmentAdjustmentOwner: SceneAdjustmentFrame?
    private struct CachedSceneResolver {
        let revision: UInt64
        let frameRate: ExactFrameRate
        let temporalSamplesOverride: UInt16?
        let resolver: RustSceneFrameResolver
    }
    private var cachedSceneResolver: CachedSceneResolver?
    private var authoredImageEnvironment: PhysicalPipelineAuthoringState.Environment?
    private var environmentSourceHash: String?
    private var environmentSourceInputTransformID: String?
    private var environmentSourceURL: URL?
    private var environmentSourceCalibration: EnvironmentAssetCalibration?
    private var generatedReflectionEnvironmentData: Data?
    @Published private(set) var activeSceneID: UUID?
    private var persistGeneratedEnvironment: ((UUID, Data) throws -> ManagedEnvironmentAsset)?
    private var referenceACEScgFrame: StudioColorMetalFrame?
    private var syntheticReferencePlateCache: (plate: ReferencePlate, width: Int, height: Int, frame: StudioColorMetalFrame)?
    private var referenceForegroundFrame: StudioColorMetalFrame?
    private var transparentSimulationFrames: [String: StudioColorMetalFrame] = [:]
    private var referenceForegroundIsDeliveryAligned = false
    private var referenceSourceURL: URL?
    private var referenceInputTransformID: String?
    private var referenceSourceHash: String?
    private var referenceDetection = SyntheticPattern.animatedCheckerboard.sourceDetection
    private var sourceTimelineInfo = NativeVideoTimelineInfo(
        exactFrameRate: .fps24,
        frameCount: 1
    )
    private var referenceTimelineInfo: NativeVideoTimelineInfo?
    private var referencePlaybackStartedAt: CFTimeInterval?
    private var referencePlaybackStartFrame = 0
    private var referenceMatchStartSelection: TestAuthoringResolvedSelection?
    private var referenceRefreshTask: Task<Void, Never>?
    private var referenceSession = NativeMediaSession()
    private var cameraNavigationGesture: CameraNavigationGesture?
    private var cameraNavigationStartSelection: TestAuthoringResolvedSelection?
    private var cameraNavigationStartOverrideControlIDs: Set<String>?
    private var focusTargetDragStartSelection: TestAuthoringResolvedSelection?
    private var focusTargetDragStartOverrideControlIDs: Set<String>?
    private var cameraNavigationLatestPose: CameraNavigationPose?
    private var cameraNavigationStartDevicePose: CameraNavigationPose?
    private var cameraNavigationLatestDevicePose: CameraNavigationPose?
    private var cameraNavigationStartTrackingScale: Double?
    private var cameraNavigationLatestTrackingScale: Double?
    private var cameraNavigationMovesDevice = false
    private var cameraNavigationPreviewQuality = PhysicalQuality.setup
    private var environmentNavigationStartSelection: TestAuthoringResolvedSelection?
    private var environmentNavigationPriorSelection: TestAuthoringResolvedSelection?
    private var environmentNavigationStartOverrideControlIDs: Set<String>?
    private var environmentNavigationOperation: CameraNavigationOperation?
    private var environmentNavigationViewportSize = CGSize(width: 1, height: 1)
    private var environmentNavigationCameraRight = SIMD3<Double>(1, 0, 0)
    private var environmentNavigationCameraUp = SIMD3<Double>(0, 1, 0)
    private var environmentNavigationVerticalFovRadians = Double.pi / 3
    private var environmentNavigationLockedAxis: CameraNavigationLockedAxis?
    private var environmentReflectionFramingStart: EnvironmentReflectionFraming?
    private var environmentReflectionFramingOperation: CameraNavigationOperation?
    private var environmentReflectionFramingViewport = CGSize(width: 1, height: 1)
    private var environmentReflectionFramingSourceFrame: StudioColorMetalFrame?
    private var reflectionHandleDragIndex: Int?

    let metalDisplay: StudioColorMetalDisplay
    let monitorOutput = MonitorOutputController()
    let physicalModel = PhysicalModelController()
    let viewerNavigation = ViewerNavigationController()
    let outputQueue: NativeOutputQueueController
    private var viewerNavigationSubscription: AnyCancellable?
    private var outputQueueSubscription: AnyCancellable?
    private var monitorOutputSubscription: AnyCancellable?

    var zoom: Double { viewerNavigation.zoom }
    var previewIsFitted: Bool { viewerNavigation.isFitted }
    var pan: CGSize {
        get { viewerNavigation.pan }
        set { viewerNavigation.setPan(newValue) }
    }
    var modelViewerOneToOne: Bool { viewerNavigation.modelOneToOne }
    var jobs: [NativeOutputQueueController.RenderJob] { outputQueue.jobs }

    var environmentSourceEvidence: [String] {
        guard let name = environmentSourceName,
              let resolution = environmentSourceResolution,
              let inputID = environmentSourceInputTransformID,
              let input = StudioColorInputTransform.catalog.first(where: { $0.id == inputID }),
              let authored = physicalAuthoringState
        else { return [] }
        return [
            "Archivo: \(name)",
            "Raster: \(Int(resolution.width))×\(Int(resolution.height)) · equirectangular 2:1",
            "Input Transform: \(input.label)",
            "Calibración: \(authored.environment.sourceUnitRadianceCandelasPerSquareMeter.formatted(.number.precision(.fractionLength(0 ... 3)))) cd/m² por unidad",
            "Evaluación: reflejos visibles desde Draft; Setup muestra solo encuadre",
        ]
    }
    private var session = NativeMediaSession()
    private var sourceIsPattern = true
    private var tickSubscription: AnyCancellable?
    private var physicalSubscription: AnyCancellable?
    private var physicalNativeTask: Task<Void, Never>?
    private var physicalInteractiveTask: Task<Void, Never>?
    private var physicalNativeJob: PhysicalMetalFrameJob?
    private var physicalInteractiveJob: PhysicalMetalFrameJob?
    @Published private var nativeRenderTaskActive = false
    @Published private var nativeCancellationRequested = false
    private let physicalEngine = PhysicalMetalFrameEngine()
    private var physicalIdentityCounter: UInt64 = 0
    private var modelViewport = CGSize(width: 960, height: 540)
    private var isModelPageActive = false
    private var isTestPageActive = false
    private var testPreviewResultByPhaseID: [String: TestPreviewResultKind] = [:]
    private var testPhysicalIntermediateByPhaseID: [String: PhysicalIntermediate] = [:]
    private var resolvedPhysicalPipeline: PhysicalPipelineResolvedState?
    private var baseModelDeviceDefinition: DeviceDefinition?
    private var basePhysicalAuthoringState: PhysicalPipelineAuthoringState?
    private var savedSceneOpenWarnings: [String] = []
    /// Scene Open is a transaction: external resources may decode into their canonical
    /// inputs, but no preview/setup/physical evaluation is published until every strict
    /// setting and the embedded scene authoring have been restored successfully.
    private var isMaterializingSavedScene = false
    private let physicalPublicationLog = Logger(
        subsystem: "com.jtorrens.ScreenSimulationNative",
        category: "PhysicalPublication"
    )

    var physicalPipelineState: PhysicalPipelineResolvedState? {
        resolvedPhysicalPipeline
    }

    var physicalPresetDeviceDefinition: DeviceDefinition? {
        baseModelDeviceDefinition
    }

    var physicalPresetAuthoringState: PhysicalPipelineAuthoringState? {
        basePhysicalAuthoringState
    }

    var physicalPreviewSurfaceAspect: Double? {
        switch requestedPhysicalIntermediate {
        case .panelEmission, .subpixelRadiance, .panelUniformity, .panelLightSpread,
             .panelTemporal,
             .relativeGeometry,
             .coverEnvironment, .coverGlow, .lensProjection:
            guard let device = modelDeviceDefinition ?? resolvedDevice?.definition else { return nil }
            return Double(device.nativeWidth) / Double(device.nativeHeight)
        case .sensorCollection, .sensorBloom, .sensorReadoutRaw,
             .developedACEScg, .cameraRenderedACEScg:
            guard let sensor = physicalAuthoringState?.sensor,
                  sensor.nativeWidth > 0, sensor.nativeHeight > 0
            else { return nil }
            // The selected capture preset is authoritative for the camera-result
            // viewport. Do not retain the aspect of the previously published frame
            // while the replacement physical job is being evaluated.
            return Double(sensor.nativeWidth) / Double(sensor.nativeHeight)
        case .sourceACEScg, .deviceSignal, .shutterMotion, .computationalCapture,
             .deviceVfxTransparency:
            guard let metalFrame, metalFrame.height > 0 else { return nil }
            return Double(metalFrame.width) / Double(metalFrame.height)
        }
    }

    var physicalNativeOutputDescription: String? {
        switch requestedPhysicalIntermediate {
        case .sensorCollection, .sensorBloom, .sensorReadoutRaw,
             .developedACEScg, .cameraRenderedACEScg:
            guard let sensor = physicalAuthoringState?.sensor else { return nil }
            return "Captura \(sensor.nativeWidth)×\(sensor.nativeHeight)"
        case .panelEmission, .subpixelRadiance, .panelUniformity, .panelLightSpread,
             .panelTemporal,
             .relativeGeometry,
             .coverEnvironment, .coverGlow, .lensProjection, .shutterMotion:
            guard let device = modelDeviceDefinition ?? resolvedDevice?.definition else { return nil }
            return "Panel \(device.nativeWidth * 3)×\(device.nativeHeight * 3)"
        case .computationalCapture:
            guard let device = modelDeviceDefinition ?? resolvedDevice?.definition else { return nil }
            return "Panel \(device.nativeWidth * 3)×\(device.nativeHeight * 3)"
        case .sourceACEScg, .deviceSignal, .deviceVfxTransparency:
            guard let metalFrame else { return nil }
            return "Fuente \(metalFrame.width)×\(metalFrame.height)"
        }
    }

    init(globalLibraryStore: GlobalLibraryStore? = nil) {
        let resolvedLibraryStore = globalLibraryStore ?? (try! GlobalLibraryStore())
        let library = try! resolvedLibraryStore.load()
        self.globalLibraryStore = resolvedLibraryStore
        globalLibraryDocument = library
        renderPreset = library.renderPresets[0].value
        renderWIPReviewPreset = nil
        capturePresets = library.cameras.map(\.value)
        lensPresets = library.lenses.map(\.value)
        environmentPresets = library.environments.map(\.value)
        testAuthoringProfileContext = try! RustTestAuthoringProfileContext(
            library: library
        )
        metalDisplay = try! StudioColorMetalDisplay()
        do {
            outputQueue = try NativeOutputQueueController(store: RenderQueueStore())
        } catch {
            outputQueue = NativeOutputQueueController(
                rejectedStoreError: "Render Queue rechazada: \(error.localizedDescription)"
            )
        }
        physicalModel.interactiveInvalidation = { [weak self] in
            self?.rebuildPhysicalSelectedFrame()
        }
        physicalModel.cancelNativeWork = { [weak self] in
            _ = self?.physicalNativeJob?.cancel()
        }
        physicalSubscription = physicalModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        viewerNavigationSubscription = viewerNavigation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        outputQueueSubscription = outputQueue.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        monitorOutputSubscription = monitorOutput.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        renderPattern()
        tickSubscription = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect().sink { [weak self] _ in self?.tickPlayback() }
    }

    private func reloadTestAuthoringProfileContext() throws {
        let library = try globalLibraryStore.load()
        globalLibraryDocument = library
        capturePresets = library.cameras.map(\.value)
        lensPresets = library.lenses.map(\.value)
        environmentPresets = library.environments.map(\.value)
        testAuthoringProfileContext = try RustTestAuthoringProfileContext(
            library: library
        )
    }

    /// A committed Global Library edit invalidates the complete inherited
    /// profile layer. Rematerialize every family together and then reapply the
    /// active scene's explicit overrides; never patch one cached profile.
    func refreshActiveSceneFromGlobalLibrary() {
        guard !isMaterializingSavedScene,
              let settingsContext = currentSettingsContext(),
              let currentSelection = currentTestAuthoringSelection()
        else { return }
        do {
            let authoring = try currentSceneAuthoringDocument(
                settingsContext: settingsContext,
                selection: currentSelection
            )
            let library = try globalLibraryStore.load()
            guard let device = library.devices.first(where: {
                $0.id == authoring.profiles.deviceID
            })?.value else {
                throw SceneLibraryError.invalidDocument(
                    "La escena activa requiere el Device \(authoring.profiles.deviceID), que ya no existe."
                )
            }
            guard let coverGlass = library.coverGlasses.first(where: {
                $0.id == authoring.profiles.coverGlassID
            })?.value else {
                throw SceneLibraryError.invalidDocument(
                    "La escena activa requiere el Cover Glass \(authoring.profiles.coverGlassID), que ya no existe."
                )
            }
            let stagedProfileContext = try RustTestAuthoringProfileContext(library: library)
            let stagedSelection = try materializeSceneSelection(
                authoring,
                profileContext: stagedProfileContext
            )
            _ = try RustTestAuthoringCoordinator.snapshot(
                profileContext: stagedProfileContext,
                selection: stagedSelection,
                selectedPreviewPhaseID: testPresentation?.selectedPhaseID
            )

            let priorLibrary = globalLibraryDocument
            let priorCapturePresets = capturePresets
            let priorLensPresets = lensPresets
            let priorEnvironmentPresets = environmentPresets
            let priorProfileContext = testAuthoringProfileContext
            let priorSelection = testAuthoringSelection
            let priorDevice = modelDeviceDefinition
            let priorResolvedDevice = resolvedDevice
            let priorPhysicalAuthoring = physicalAuthoringState
            let priorResolvedPipeline = resolvedPhysicalPipeline
            let priorBaseDevice = baseModelDeviceDefinition
            let priorBaseAuthoring = basePhysicalAuthoringState
            let priorBaselines = sceneProfileBaselineByControlID
            let priorCaptureID = selectedCapturePresetID
            let priorRasterID = selectedCaptureRasterModeID
            let priorLensID = selectedLensPresetID
            let priorPresentation = testPresentation
            let priorPreviewResults = testPreviewResultByPhaseID
            let priorIntermediates = testPhysicalIntermediateByPhaseID
            let priorModelState = physicalModel.authoringState
            let priorQuality = physicalModel.quality

            isMaterializingSavedScene = true
            do {
                globalLibraryDocument = library
                capturePresets = library.cameras.map(\.value)
                lensPresets = library.lenses.map(\.value)
                environmentPresets = library.environments.map(\.value)
                testAuthoringProfileContext = stagedProfileContext
                try applyTestAuthoringSelection(
                    stagedSelection,
                    profileDevice: device,
                    profileCoverGlass: coverGlass
                )
                try physicalModel.restoreSceneOverrides(authoring.modelOverrides)
                explicitSceneOverrideControlIDs = Set(authoring.overrides.map(\.controlID))
                physicalModel.invalidateExternalParameters()
            } catch {
                globalLibraryDocument = priorLibrary
                capturePresets = priorCapturePresets
                lensPresets = priorLensPresets
                environmentPresets = priorEnvironmentPresets
                testAuthoringProfileContext = priorProfileContext
                testAuthoringSelection = priorSelection
                modelDeviceDefinition = priorDevice
                resolvedDevice = priorResolvedDevice
                physicalAuthoringState = priorPhysicalAuthoring
                resolvedPhysicalPipeline = priorResolvedPipeline
                baseModelDeviceDefinition = priorBaseDevice
                basePhysicalAuthoringState = priorBaseAuthoring
                sceneProfileBaselineByControlID = priorBaselines
                selectedCapturePresetID = priorCaptureID
                selectedCaptureRasterModeID = priorRasterID
                selectedLensPresetID = priorLensID
                testPresentation = priorPresentation
                testPreviewResultByPhaseID = priorPreviewResults
                testPhysicalIntermediateByPhaseID = priorIntermediates
                try? physicalModel.restoreAuthoringState(priorModelState)
                physicalModel.setQuality(priorQuality)
                isMaterializingSavedScene = false
                throw error
            }
            isMaterializingSavedScene = false
            status = "Escena activa actualizada desde la Biblioteca"
            rebuildPhysicalSelectedFrame()
        } catch {
            isMaterializingSavedScene = false
            errorMessage = error.localizedDescription
        }
    }

    var pipelineSummary: String {
        if isTestPageActive, let testPresentation,
           let phase = testPresentation.phases.first(where: {
               $0.id == testPresentation.selectedPhaseID
           }) {
            return "Ver hasta · \(phase.label) → Display/ODT"
        }
        return "Input Transform → ACEScg → Color Mode → Pantalla → Captura → Display/ODT"
    }

    var previewMetadataLines: [String] {
        guard isTestPageActive, let frame = metalFrame,
              let presentation = testPresentation,
              let phase = presentation.phases.first(where: {
                  $0.id == presentation.selectedPhaseID
              })
        else { return [] }
        let format = switch frame.texture.pixelFormat {
        case .rgba16Float: "RGBA16F"
        case .rgba32Float: "RGBA32F"
        default: "Metal \(frame.texture.pixelFormat.rawValue)"
        }
        if testPreviewResultByPhaseID[presentation.selectedPhaseID] == .sourceACEScg {
            return ["[\(phase.label)] \(frame.width)×\(frame.height) · \(format) · ACEScg"]
        }
        let device = modelDeviceDefinition ?? resolvedDevice?.definition
        let native = device.map { "\($0.nativeWidth)×\($0.nativeHeight)" } ?? "—"
        let first = "[\(phase.label) · \(physicalModel.computedQuality.uiLabel)] \(frame.width)×\(frame.height) / \(native) · \(format)"
        guard let device else { return [first] }
        let second = "\(device.name) · \(device.colorModeID) · \(Int(device.whiteLevelNits.rounded())) cd/m² · \(sourcePlacement.rawValue) · Zoom \(zoomPercentage.formatted(.number.precision(.fractionLength(0 ... 1)))) %"
        return [first, second]
    }

    var testRequiresExplicitRender: Bool {
        isTestPageActive
            && selectedTestPhysicalIntermediate != nil
            && physicalModel.quality == .native
    }

    var testNativeRenderButtonState: NativeRenderButtonState {
        if nativeRenderTaskActive {
            return .resolve(
                frameState: physicalModel.frameState,
                progress: physicalModel.progress,
                hasActiveTask: true,
                cancellationRequested: nativeCancellationRequested
                    || physicalModel.frameState != .rendering
            )
        }
        return .resolve(
            frameState: physicalModel.frameState,
            progress: physicalModel.progress,
            hasActiveTask: false,
            cancellationRequested: false
        )
    }

    var sourceKindLabel: String {
        sourceIsPattern ? "Patrón sintético" : "Archivo o secuencia"
    }

    var hasExternalSourceMedia: Bool {
        !sourceIsPattern
    }

    func selectDevice(
        _ definition: DeviceDefinition,
        coverGlass: CoverGlassDefinition,
        amount _: Double
    ) {
        do {
            testAuthoringSelection = nil
            resolvedDevice = try definition.resolved()
            modelDeviceDefinition = definition
            let authored = try PhysicalPipelineAuthoringState.seeded(
                device: definition,
                coverGlass: coverGlass
            )
            physicalAuthoringState = authored
            resolvedPhysicalPipeline = try authored.resolvedPipeline()
            baseModelDeviceDefinition = definition
            basePhysicalAuthoringState = authored
            sceneProfileBaselineByControlID = sceneProfileBaselines(
                device: definition, coverGlass: coverGlass
            )
            try refreshTestAuthoringDescriptor()
            rebuildCurrent()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectModelDevice(
        _ definition: DeviceDefinition,
        coverGlass: CoverGlassDefinition,
        undoManager: UndoManager? = nil
    ) {
        do {
            try reloadTestAuthoringProfileContext()
            if let selection = testAuthoringSelection,
               selection.deviceID != definition.id {
                let resolved = try RustTestAuthoringCoordinator.apply(
                    .setChoice(controlID: "device", optionID: definition.id),
                    to: selection,
                    profileContext: testAuthoringProfileContext
                )
                try commitSceneAuthoringEdit(
                    selection: resolved,
                    setting: [],
                    profileDevice: definition,
                    profileCoverGlass: coverGlass,
                    undoManager: undoManager,
                    actionName: "Cambiar Device"
                )
                rebuildPhysicalSelectedFrame()
                return
            }
            resolvedDevice = try definition.resolved()
            modelDeviceDefinition = definition
            var authored = try PhysicalPipelineAuthoringState.seeded(
                device: definition,
                coverGlass: coverGlass
            )
            let capture = capturePresets.first { $0.id == selectedCapturePresetID }
                ?? capturePresets.first
            if let capture {
                try apply(
                    capture: capture,
                    rasterModeID: capture.defaultRasterModeID,
                    lensID: capture.defaultLensID,
                    to: &authored
                )
            }
            selectedCapturePresetID = capture?.id
            selectedCaptureRasterModeID = capture?.defaultRasterModeID
            physicalAuthoringState = authored
            resolvedPhysicalPipeline = try authored.resolvedPipeline()
            baseModelDeviceDefinition = definition
            basePhysicalAuthoringState = authored
            sceneProfileBaselineByControlID = sceneProfileBaselines(
                device: definition, coverGlass: coverGlass
            )
            try refreshTestAuthoringDescriptor()
            rebuildPhysicalSelectedFrame()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectCapturePreset(_ preset: CameraProfileDefinition, undoManager: UndoManager?) {
        guard let prior = basePhysicalAuthoringState else { return }
        let priorID = selectedCapturePresetID
        let priorRasterModeID = selectedCaptureRasterModeID
        let priorLensID = selectedLensPresetID
        var next = prior
        do {
            try apply(
                capture: preset,
                rasterModeID: preset.defaultRasterModeID,
                lensID: preset.defaultLensID,
                to: &next
            )
            resolvedPhysicalPipeline = try next.resolvedPipeline()
            physicalAuthoringState = next
            basePhysicalAuthoringState = next
            selectedCapturePresetID = preset.id
            selectedCaptureRasterModeID = preset.defaultRasterModeID
            registerUndo(with: undoManager, actionName: "Cambiar cámara") { target, manager in
                target.restoreCapturePresetState(
                        prior,
                        selectedID: priorID,
                        selectedRasterModeID: priorRasterModeID,
                        selectedLensID: priorLensID,
                        undoManager: manager
                    )
            }
            physicalModel.invalidateExternalParameters()
        } catch { errorMessage = error.localizedDescription }
    }

    private func apply(
        capture: CameraProfileDefinition,
        rasterModeID: String,
        lensID: String,
        to state: inout PhysicalPipelineAuthoringState
    ) throws {
        guard capture.compatibleLensIDs.contains(lensID),
              let lens = lensPresets.first(where: { $0.id == lensID })
        else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "La cámara no admite el objetivo seleccionado."
            )
        }
        try capture.applyCamera(rasterModeID: rasterModeID, to: &state, frameRate: frameRate)
        lens.apply(to: &state)
        selectedLensPresetID = lens.id
    }

    private func restoreCapturePresetState(
        _ state: PhysicalPipelineAuthoringState,
        selectedID: String?,
        selectedRasterModeID: String?,
        selectedLensID: String?,
        undoManager: UndoManager?
    ) {
        guard let prior = basePhysicalAuthoringState else { return }
        let priorID = selectedCapturePresetID
        let priorRasterModeID = selectedCaptureRasterModeID
        let priorLensID = self.selectedLensPresetID
        do {
            resolvedPhysicalPipeline = try state.resolvedPipeline()
            physicalAuthoringState = state
            basePhysicalAuthoringState = state
            selectedCapturePresetID = selectedID
            selectedCaptureRasterModeID = selectedRasterModeID
            selectedLensPresetID = selectedLensID
            registerUndo(with: undoManager, actionName: "Cambiar cámara") { target, manager in
                target.restoreCapturePresetState(
                    prior,
                    selectedID: priorID,
                    selectedRasterModeID: priorRasterModeID,
                    selectedLensID: priorLensID,
                    undoManager: manager
                )
            }
            physicalModel.invalidateExternalParameters()
        } catch { errorMessage = error.localizedDescription }
    }

    func updateModelDevice(
        undoManager: UndoManager?,
        _ mutation: (inout DeviceDefinition) -> Void
    ) {
        guard let prior = modelDeviceDefinition else { return }
        var next = prior
        mutation(&next)
        do {
            resolvedDevice = try next.resolved()
            modelDeviceDefinition = next
            try refreshTestAuthoringDescriptor()
            registerModelDeviceUndo(prior, undoManager: undoManager)
            physicalModel.invalidateExternalParameters()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updatePhysicalAuthoring(
        undoManager: UndoManager?,
        _ mutation: (inout PhysicalPipelineAuthoringState) -> Void
    ) {
        guard let prior = basePhysicalAuthoringState else { return }
        var next = prior
        mutation(&next)
        do {
            resolvedPhysicalPipeline = try next.resolvedPipeline()
            physicalAuthoringState = next
            basePhysicalAuthoringState = next
            registerPhysicalAuthoringUndo(prior, undoManager: undoManager)
            physicalModel.invalidateExternalParameters()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetPhysicalParameters(
        _ stage: PhysicalStageID,
        undoManager: UndoManager?
    ) {
        switch stage {
        case let .screen(section):
            guard let base = baseModelDeviceDefinition else { return }
            if section == .coverGlass || section == .environment || section == .coverGlow {
                guard let authored = basePhysicalAuthoringState else { return }
                updatePhysicalAuthoring(undoManager: undoManager) { current in
                    if section == .coverGlass || section == .coverGlow {
                        current.coverGlass = authored.coverGlass
                    } else {
                        current.environment = authored.environment
                    }
                }
            } else {
                updateModelDevice(undoManager: undoManager) { current in
                    current.restore(section: section, from: base)
                }
            }
        case let .capture(section):
            guard let base = basePhysicalAuthoringState else { return }
            updatePhysicalAuthoring(undoManager: undoManager) { current in
                current.restore(section: section, from: base)
            }
        }
    }

    private func registerModelDeviceUndo(
        _ prior: DeviceDefinition,
        undoManager: UndoManager?
    ) {
        registerUndo(with: undoManager, actionName: "Editar parámetro físico") { target, manager in
            target.restoreModelDevice(prior, undoManager: manager)
        }
    }

    private func restoreModelDevice(_ value: DeviceDefinition, undoManager: UndoManager?) {
        guard let prior = modelDeviceDefinition else { return }
        do {
            resolvedDevice = try value.resolved()
            modelDeviceDefinition = value
            try refreshTestAuthoringDescriptor()
            registerModelDeviceUndo(prior, undoManager: undoManager)
            physicalModel.invalidateExternalParameters()
        } catch { errorMessage = error.localizedDescription }
    }

    private func registerPhysicalAuthoringUndo(
        _ prior: PhysicalPipelineAuthoringState,
        undoManager: UndoManager?
    ) {
        registerUndo(with: undoManager, actionName: "Editar parámetro físico") { target, manager in
            target.restorePhysicalAuthoring(prior, undoManager: manager)
        }
    }

    private func restorePhysicalAuthoring(
        _ value: PhysicalPipelineAuthoringState,
        undoManager: UndoManager?
    ) {
        guard let prior = basePhysicalAuthoringState else { return }
        do {
            resolvedPhysicalPipeline = try value.resolvedPipeline()
            physicalAuthoringState = value
            basePhysicalAuthoringState = value
            registerPhysicalAuthoringUndo(prior, undoManager: undoManager)
            physicalModel.invalidateExternalParameters()
        } catch { errorMessage = error.localizedDescription }
    }

    func selectPhysicalIntermediate(_ intermediate: PhysicalIntermediate) {
        updateRequestedPhysicalIntermediate(intermediate)
        rebuildPhysicalSelectedFrame()
    }

    private func updateRequestedPhysicalIntermediate(
        _ intermediate: PhysicalIntermediate
    ) {
        guard requestedPhysicalIntermediate != intermediate else { return }
        requestedPhysicalIntermediate = intermediate
        physicalModel.invalidateExternalParameters()
    }

    func setModelPageActive(_ active: Bool) {
        isModelPageActive = active
        if active {
            pause()
            rebuildPhysicalSelectedFrame()
        }
    }

    func setTestPageActive(_ active: Bool) {
        isTestPageActive = active
        guard active else { return }
        pause()
        do {
            try reloadTestAuthoringProfileContext()
            try refreshTestAuthoringDescriptor(publishPreview: false)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        restoreSceneViewerPublication()
    }

    func handleTestIntent(
        _ intent: TestControlIntent,
        undoManager: UndoManager? = nil
    ) {
        do {
            switch intent {
            case let .selectPhase(phaseID):
                guard let selection = currentTestAuthoringSelection() else {
                    throw TestAuthoringCoordinatorError.malformedDescriptor(
                        "Test necesita un Device resuelto."
                    )
                }
                let snapshot = try RustTestAuthoringCoordinator.snapshot(
                    profileContext: testAuthoringProfileContext,
                    selection: selection,
                    selectedPreviewPhaseID: phaseID
                )
                testPresentation = snapshot.presentation
                testPreviewResultByPhaseID = snapshot.previewResultByPhaseID
                testPhysicalIntermediateByPhaseID = snapshot.physicalIntermediateByPhaseID
                let selectedResult = snapshot.previewResultByPhaseID[phaseID]
                if (selectedResult == .recordingOutput || selectedResult == .recordingCodec),
                   recordingCameraCheckpoint != nil {
                    publishRecordingPreview(result: selectedResult!)
                    return
                }
                if let intermediate = snapshot.physicalIntermediateByPhaseID[phaseID] {
                    updateRequestedPhysicalIntermediate(intermediate)
                    rebuildPhysicalSelectedFrame()
                } else {
                    publishSelectedTestPreview()
                }
            case .setChoice, .setScalar, .setToggle, .reset:
                guard let selection = currentTestAuthoringSelection() else {
                    throw TestAuthoringCoordinatorError.malformedDescriptor(
                        "Test necesita un Device resuelto."
                    )
                }
                let effectiveIntent: TestControlIntent
                let editedControlID: String
                let removesOverride: Bool
                switch intent {
                case let .setChoice(controlID, _),
                     let .setScalar(controlID, _),
                     let .setToggle(controlID, _):
                    effectiveIntent = intent
                    editedControlID = controlID
                    removesOverride = false
                case let .reset(controlID):
                    effectiveIntent = try resetIntent(for: controlID)
                    editedControlID = controlID
                    removesOverride = true
                case .selectPhase, .performAction:
                    throw TestAuthoringCoordinatorError.unsupportedIntent
                }
                if case let .setChoice(controlID, optionID) = effectiveIntent,
                   controlID == "environment-source", optionID != "environment-image" {
                    environmentRadianceFrame = nil
                    authoredImageEnvironment = nil
                    environmentSourceName = nil
                    environmentSourceResolution = nil
                    environmentSourceHash = nil
                    environmentSourceInputTransformID = nil
                    environmentSourceURL = nil
                    environmentSourceCalibration = nil
                    generatedReflectionEnvironmentData = nil
                    environmentReflectionFramingSourceFrame = nil
                }
                let phaseToReveal = testPhaseToReveal(for: effectiveIntent)
                let resolved = try RustTestAuthoringCoordinator.apply(
                    effectiveIntent, to: selection,
                    profileContext: testAuthoringProfileContext
                )
                try commitSceneAuthoringEdit(
                    selection: resolved,
                    setting: removesOverride ? [] : [editedControlID],
                    resetting: removesOverride ? [editedControlID] : [],
                    undoManager: activeSceneControlEditID == editedControlID
                        ? nil : undoManager,
                    actionName: removesOverride ? "Restablecer parámetro" : "Editar parámetro"
                )
                if let phaseToReveal,
                   let updatedSelection = currentTestAuthoringSelection() {
                    let snapshot = try RustTestAuthoringCoordinator.snapshot(
                        profileContext: testAuthoringProfileContext,
                        selection: updatedSelection,
                        selectedPreviewPhaseID: phaseToReveal
                    )
                    testPresentation = snapshot.presentation
                    testPreviewResultByPhaseID = snapshot.previewResultByPhaseID
                    testPhysicalIntermediateByPhaseID = snapshot.physicalIntermediateByPhaseID
                    let revealResult = snapshot.previewResultByPhaseID[phaseToReveal]
                    if (revealResult == .recordingOutput || revealResult == .recordingCodec),
                       recordingCameraCheckpoint != nil {
                        publishRecordingPreview(result: revealResult!)
                        return
                    }
                    if let intermediate = snapshot.physicalIntermediateByPhaseID[phaseToReveal] {
                        updateRequestedPhysicalIntermediate(intermediate)
                        rebuildPhysicalSelectedFrame()
                    } else {
                        publishSelectedTestPreview()
                    }
                }
            case let .performAction(controlID):
                guard controlID == "environment-browse" else {
                    throw TestAuthoringCoordinatorError.unsupportedIntent
                }
                browseEnvironment()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func beginCameraNavigation(
        _ operation: CameraNavigationOperation,
        viewportSize: CGSize
    ) {
        guard physicalPlacementNavigationEnabled else { return }
        if environmentReflectionFramingEnabled || physicalModel.quality == .environmentSetup {
            beginEnvironmentNavigation(operation, viewportSize: viewportSize)
            return
        }
        guard let authored = try? resolveSceneFrame(currentFrame).authored,
              let device = modelDeviceDefinition ?? resolvedDevice?.definition,
              let selection = testAuthoringSelection,
              viewportSize.width > 0, viewportSize.height > 0
        else { return }
        if operation == .trackingWorldScale,
           !(trackingSceneMethod == .fusionComposition
                && trackingCameraEnabled
                && trackingMetersPerSourceUnit != nil
                && selectedTrackingCamera != nil) {
            errorMessage = "Cmd+MMB necesita una cámara tracking activa y una escala 3D resuelta."
            return
        }
        let cameraQuaternion = simd_quatd(
            ix: authored.cameraPose.quaternion[0], iy: authored.cameraPose.quaternion[1],
            iz: authored.cameraPose.quaternion[2], r: authored.cameraPose.quaternion[3]
        ).normalized
        let screenQuaternion = simd_quatd(
            ix: authored.screenPose.quaternion[0], iy: authored.screenPose.quaternion[1],
            iz: authored.screenPose.quaternion[2], r: authored.screenPose.quaternion[3]
        ).normalized
        let geometry = CameraNavigationGeometry(
            center: SIMD3(
                authored.screenPose.position[0], authored.screenPose.position[1],
                authored.screenPose.position[2]
            ),
            right: screenQuaternion.act(SIMD3(1, 0, 0)),
            up: screenQuaternion.act(SIMD3(0, 1, 0)),
            halfWidth: device.activeWidthMeters * 0.5,
            halfHeight: device.activeHeightMeters * 0.5
        )
        let verticalFov = 2 * atan(
            authored.sceneLens.sensorHeightMillimeters
                / (2 * authored.sceneLens.focalLengthMillimeters)
        )
        cameraNavigationStartSelection = selection
        cameraNavigationStartOverrideControlIDs = explicitSceneOverrideControlIDs
        cameraNavigationLatestPose = nil
        cameraNavigationLatestDevicePose = nil
        cameraNavigationStartTrackingScale = operation == .trackingWorldScale
            ? trackingMetersPerSourceUnit : nil
        cameraNavigationLatestTrackingScale = nil
        cameraNavigationMovesDevice = operation == .trackingWorldScale || (
            trackingSceneMethod == .fusionComposition
                && trackingCameraEnabled
                && trackingMetersPerSourceUnit != nil
                && selectedTrackingCamera != nil
        )
        cameraNavigationStartDevicePose = cameraNavigationMovesDevice
            ? CameraNavigationPose(
                position: geometry.center,
                orientation: screenQuaternion
            )
            : nil
        cameraNavigationPreviewQuality = physicalModel.quality == .focusSetup ? .focusSetup : .setup
        physicalModel.setQuality(cameraNavigationPreviewQuality)
        cameraNavigationGesture = .init(
            operation: operation,
            startPose: .init(
                position: SIMD3(
                    authored.cameraPose.position[0], authored.cameraPose.position[1],
                    authored.cameraPose.position[2]
                ),
                orientation: cameraQuaternion
            ),
            geometry: geometry,
            viewportSize: viewportSize,
            verticalFovRadians: verticalFov,
            nearClipMeters: authored.sceneLens.nearClipMeters,
            lockedAxis: nil
        )
    }

    func togglePreviewTransformationsLock() {
        previewTransformationsLocked.toggle()
    }

    var physicalPlacementNavigationEnabled: Bool {
        if EnvironmentReflectionFraming.capturesViewerNavigation(
            enabled: environmentReflectionFramingEnabled,
            transformationsLocked: previewTransformationsLocked,
            referenceMatchEnabled: referenceMatchEnabled,
            reflectionEditorEnabled: reflectionEnvironmentEditorEnabled
        ) {
            return true
        }
        return !previewTransformationsLocked
            && physicalModel.quality != .native
            && physicalModel.frameState != .rendering
            && physicalModel.frameState != .complete
            && !referenceMatchEnabled
            && !reflectionEnvironmentEditorEnabled
    }

    func togglePreviewGizmos() {
        previewGizmosVisible.toggle()
    }

    func updateCameraNavigation(delta: CGSize) {
        if environmentNavigationStartSelection != nil || environmentReflectionFramingStart != nil {
            updateEnvironmentNavigation(delta: delta)
            return
        }
        guard var gesture = cameraNavigationGesture else { return }
        let pose: CameraNavigationPose
        switch gesture.operation {
        case .pan:
            pose = CameraNavigationMath.pan(gesture: gesture, delta: delta)
        case .orbit:
            pose = CameraNavigationMath.orbit(gesture: &gesture, delta: delta)
            cameraNavigationGesture = gesture
        case .dolly:
            pose = CameraNavigationMath.dolly(
                gesture: gesture, deltaPixels: Double(delta.width)
            )
        case .trackingWorldScale:
            guard let startDevice = cameraNavigationStartDevicePose,
                  let startScale = cameraNavigationStartTrackingScale
            else { return }
            let scaled = CameraNavigationMath.scaledTrackingWorld(
                gesture: gesture,
                startDevice: startDevice,
                startMetersPerSourceUnit: startScale,
                deltaPixels: Double(delta.width)
            )
            cameraNavigationLatestDevicePose = scaled.device
            cameraNavigationLatestPose = scaled.camera
            cameraNavigationLatestTrackingScale = scaled.metersPerSourceUnit
            applyInteractiveTrackingWorldScale(
                metersPerSourceUnit: scaled.metersPerSourceUnit,
                devicePose: scaled.device
            )
            return
        }
        if cameraNavigationMovesDevice,
           let startDevice = cameraNavigationStartDevicePose {
            let devicePose = CameraNavigationMath.equivalentDevicePose(
                startCamera: gesture.startPose,
                movedCamera: pose,
                startDevice: startDevice
            )
            cameraNavigationLatestDevicePose = devicePose
            applyTransientDeviceNavigationPose(devicePose, viewportSize: gesture.viewportSize)
        } else {
            cameraNavigationLatestPose = pose
            applyTransientCameraNavigationPose(pose, viewportSize: gesture.viewportSize)
        }
    }

    func endCameraNavigation(undoManager: UndoManager?) {
        if environmentNavigationStartSelection != nil || environmentReflectionFramingStart != nil {
            endEnvironmentNavigation(undoManager: undoManager)
            return
        }
        guard cameraNavigationGesture != nil else { return }
        let scaledTrackingWorld = cameraNavigationLatestTrackingScale != nil
        let priorTrackingScale = cameraNavigationStartTrackingScale
        cameraNavigationGesture = nil
        if let scale = cameraNavigationLatestTrackingScale,
           let pose = cameraNavigationLatestDevicePose {
            trackingMetersPerSourceUnit = scale
            commitDeviceNavigationPose(pose)
        } else if let pose = cameraNavigationLatestDevicePose {
            commitDeviceNavigationPose(pose)
        } else if let pose = cameraNavigationLatestPose {
            commitCameraNavigationPose(pose)
        }
        cameraNavigationLatestPose = nil
        cameraNavigationLatestDevicePose = nil
        cameraNavigationStartTrackingScale = nil
        cameraNavigationLatestTrackingScale = nil
        cameraNavigationStartDevicePose = nil
        let priorOverrides = cameraNavigationStartOverrideControlIDs
            ?? explicitSceneOverrideControlIDs
        if let prior = cameraNavigationStartSelection,
           prior != testAuthoringSelection {
            if scaledTrackingWorld, let priorTrackingScale {
                registerUndo(with: undoManager, actionName: "Escalar mundo tracking") { target, manager in
                    try? target.restoreTrackingWorldScale(
                        priorTrackingScale,
                        snapshot: .init(
                            selection: prior,
                            explicitOverrideControlIDs: priorOverrides
                        ),
                        undoManager: manager
                    )
                }
            } else {
                let name = cameraNavigationMovesDevice ? "Mover Device" : "Navegar cámara"
                registerUndo(with: undoManager, actionName: name) { target, manager in
                    try? target.restoreSceneAuthoringEdit(
                        .init(
                            selection: prior,
                            explicitOverrideControlIDs: priorOverrides
                        ),
                        undoManager: manager,
                        actionName: name
                    )
                }
            }
        }
        cameraNavigationStartSelection = nil
        cameraNavigationStartOverrideControlIDs = nil
        cameraNavigationMovesDevice = false
        cameraNavigationPreviewQuality = .setup
    }

    private func beginEnvironmentNavigation(
        _ operation: CameraNavigationOperation,
        viewportSize: CGSize
    ) {
        if environmentReflectionFramingEnabled {
            environmentReflectionFramingStart = environmentReflectionFraming
            environmentReflectionFramingOperation = operation
            environmentReflectionFramingViewport = viewportSize
            return
        }
        guard var selection = testAuthoringSelection,
              selection.environmentSourceID == "environment-image",
              let resolved = try? resolveSceneFrame(currentFrame),
              viewportSize.width > 0,
              viewportSize.height > 0
        else { return }
        environmentNavigationPriorSelection = selection
        environmentNavigationStartOverrideControlIDs = explicitSceneOverrideControlIDs
        if selection.environmentProjectionID == "distant" {
            selection.environmentProjectionID = "finite-sphere"
        }
        let authored = resolved.authored
        let cameraOrientation = simd_quatd(
            ix: authored.cameraPose.quaternion[0], iy: authored.cameraPose.quaternion[1],
            iz: authored.cameraPose.quaternion[2], r: authored.cameraPose.quaternion[3]
        ).normalized
        environmentNavigationStartSelection = selection
        environmentNavigationOperation = operation
        environmentNavigationViewportSize = viewportSize
        environmentNavigationCameraRight = cameraOrientation.act(SIMD3(1, 0, 0))
        environmentNavigationCameraUp = cameraOrientation.act(SIMD3(0, 1, 0))
        environmentNavigationVerticalFovRadians = 2 * atan(
            authored.sceneLens.sensorHeightMillimeters
                / (2 * authored.sceneLens.focalLengthMillimeters)
        )
        environmentNavigationLockedAxis = nil
    }

    private func updateEnvironmentNavigation(delta: CGSize) {
        if let start = environmentReflectionFramingStart {
            var value = start
            switch environmentReflectionFramingOperation {
            case .pan:
                value.centerX = start.centerX - Double(delta.width / max(1, environmentReflectionFramingViewport.width)) / start.zoom
                value.centerY = start.centerY - Double(delta.height / max(1, environmentReflectionFramingViewport.height)) / start.zoom
                value.centerX.formTruncatingRemainder(dividingBy: 1)
                if value.centerX < 0 { value.centerX += 1 }
                value.centerY = min(1, max(0, value.centerY))
            case .dolly:
                value.zoom = min(
                    65_536, max(1.0 / 65_536.0,
                        start.zoom * exp(Double(delta.width) * 0.01))
                )
            case .orbit:
                value.rollDegrees = start.rollDegrees + Double(delta.width) * 0.2
            case .trackingWorldScale, nil:
                return
            }
            environmentReflectionFraming = value
            publishEnvironmentSetup()
            return
        }
        guard var selection = environmentNavigationStartSelection else { return }
        switch environmentNavigationOperation {
        case .dolly:
            selection.environmentSphereRadiusMeters = min(1_000,
                EnvironmentNavigationMath.scaledRadius(
                    start: selection.environmentSphereRadiusMeters,
                    deltaPixels: Double(delta.width)
                )
            )
        case .pan:
            let center = EnvironmentNavigationMath.translatedCenter(
                start: SIMD3(
                    selection.environmentSphereCenterXMeters,
                    selection.environmentSphereCenterYMeters,
                    selection.environmentSphereCenterZMeters
                ),
                radius: selection.environmentSphereRadiusMeters,
                cameraRight: environmentNavigationCameraRight,
                cameraUp: environmentNavigationCameraUp,
                viewportSize: environmentNavigationViewportSize,
                verticalFovRadians: environmentNavigationVerticalFovRadians,
                delta: delta
            )
            selection.environmentSphereCenterXMeters = center.x
            selection.environmentSphereCenterYMeters = center.y
            selection.environmentSphereCenterZMeters = center.z
        case .orbit:
            let rotations = EnvironmentNavigationMath.rotations(
                startX: selection.environmentRotationXDegrees,
                startY: selection.environmentRotationYDegrees,
                lockedAxis: &environmentNavigationLockedAxis,
                delta: delta
            )
            selection.environmentRotationXDegrees = rotations.x
            selection.environmentRotationYDegrees = rotations.y
        case .trackingWorldScale, nil:
            return
        }
        let minimumRadius = minimumEnvironmentSphereRadius(selection: selection)
        guard minimumRadius <= 1_000 else { return }
        selection.environmentSphereRadiusMeters = min(1_000, max(
            minimumRadius, selection.environmentSphereRadiusMeters
        ))
        applyTransientEnvironmentSelection(selection)
    }

    private func minimumEnvironmentSphereRadius(
        selection: TestAuthoringResolvedSelection
    ) -> Double {
        guard let resolved = try? resolveSceneFrame(currentFrame),
              let radius = try? resolved.resolver.minimumEnvironmentRadius(
                  frame: resolved.selection,
                  center: SIMD3(
                      selection.environmentSphereCenterXMeters,
                      selection.environmentSphereCenterYMeters,
                      selection.environmentSphereCenterZMeters
                  ),
                  expectedRevision: resolved.revision
              ) else { return 0.1 }
        return radius
    }

    private func ensureFiniteEnvironmentEnclosesTimeline() throws {
        guard var selection = testAuthoringSelection,
              selection.environmentSourceID == "environment-image",
              selection.environmentProjectionID == "finite-sphere"
        else { return }
        let resolved = try resolveSceneFrame(currentFrame)
        let center = SIMD3(
            selection.environmentSphereCenterXMeters,
            selection.environmentSphereCenterYMeters,
            selection.environmentSphereCenterZMeters
        )
        var required = 0.1
        for frame in 0 ..< max(1, frameCount) {
            let (numerator, overflow) = Int64(frame).multipliedReportingOverflow(
                by: Int64(resolved.selection.frameRateDenominator)
            )
            guard !overflow else { throw PhysicalContractError.invalidFrameTime }
            let frameSelection = try PhysicalFrameSelection(
                frameIndex: Int64(frame),
                timeNumerator: numerator,
                timeDenominator: resolved.selection.frameRateNumerator,
                frameRateNumerator: resolved.selection.frameRateNumerator,
                frameRateDenominator: resolved.selection.frameRateDenominator
            )
            required = max(required, try resolved.resolver.minimumEnvironmentRadius(
                frame: frameSelection, center: center, expectedRevision: resolved.revision
            ))
        }
        guard selection.environmentSphereRadiusMeters < required else { return }
        selection = try RustTestAuthoringCoordinator.apply(
            .setScalar(controlID: "environment-sphere-radius-meters", value: required),
            to: selection,
            profileContext: testAuthoringProfileContext
        )
        selection.previewQualityID = "environment-setup"
        try commitSceneAuthoringEdit(
            selection: selection,
            setting: ["environment-sphere-radius-meters"],
            undoManager: nil,
            actionName: "Ajustar radio del entorno"
        )
        status = "Radio del entorno ampliado a \(required.formatted(.number.precision(.fractionLength(3)))) m para contener toda la animación."
    }

    private func endEnvironmentNavigation(undoManager: UndoManager?) {
        if environmentReflectionFramingStart != nil {
            environmentReflectionFramingStart = nil
            environmentReflectionFramingOperation = nil
            publishEnvironmentSetup()
            return
        }
        let finalSelection = testAuthoringSelection
        let priorSelection = environmentNavigationPriorSelection
        let priorOverrides = environmentNavigationStartOverrideControlIDs
            ?? explicitSceneOverrideControlIDs
        let operation = environmentNavigationOperation
        environmentNavigationStartSelection = nil
        environmentNavigationPriorSelection = nil
        environmentNavigationStartOverrideControlIDs = nil
        environmentNavigationOperation = nil
        environmentNavigationLockedAxis = nil
        if var selection = finalSelection, let priorSelection {
            selection.previewQualityID = "environment-setup"
            var controls: Set<String> = ["environment-projection"]
            switch operation {
            case .pan:
                controls.formUnion([
                    "environment-sphere-center-x-meters",
                    "environment-sphere-center-y-meters",
                    "environment-sphere-center-z-meters",
                    "environment-sphere-radius-meters",
                ])
            case .orbit:
                controls.formUnion([
                    "environment-rotation-x-degrees",
                    "environment-rotation-y-degrees",
                    "environment-sphere-radius-meters",
                ])
            case .dolly:
                controls.insert("environment-sphere-radius-meters")
            case .trackingWorldScale, nil:
                break
            }
            do {
                try commitSceneAuthoringEdit(
                    selection: selection,
                    setting: controls,
                    prior: .init(
                        selection: priorSelection,
                        explicitOverrideControlIDs: priorOverrides
                    ),
                    undoManager: undoManager,
                    actionName: "Editar entorno"
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setEnvironmentReflectionFramingEnabled(_ enabled: Bool) {
        guard !enabled || environmentSourceACEScgFrame != nil else {
            errorMessage = "Encuadrar reflejo necesita un HDRI / EXR seleccionado."
            return
        }
        environmentReflectionFramingEnabled = enabled
        environmentReflectionFramingStart = nil
        environmentReflectionFramingOperation = nil
        if enabled {
            if environmentReflectionFramingSourceFrame == nil {
                environmentReflectionFramingSourceFrame =
                    environmentAdjustmentOwner?.frame ?? environmentSourceACEScgFrame
            }
            referenceMatchEnabled = false
            reflectionEnvironmentEditorEnabled = false
            physicalModel.setQuality(.environmentSetup)
        }
        rebuildPhysicalSelectedFrame()
    }

    func updateEnvironmentReflectionFraming(
        centerX: Double? = nil, centerY: Double? = nil,
        zoom: Double? = nil, rollDegrees: Double? = nil
    ) {
        if let centerX, centerX.isFinite { environmentReflectionFraming.centerX = centerX }
        if let centerY, centerY.isFinite { environmentReflectionFraming.centerY = centerY }
        if let zoom, zoom.isFinite, zoom > 0 { environmentReflectionFraming.zoom = zoom }
        if let rollDegrees, rollDegrees.isFinite {
            environmentReflectionFraming.rollDegrees = rollDegrees
        }
        publishEnvironmentSetup()
    }

    func resetEnvironmentReflectionFraming() {
        environmentReflectionFraming = EnvironmentReflectionFraming()
        publishEnvironmentSetup()
    }

    func applyEnvironmentReflectionFraming() {
        guard var selection = testAuthoringSelection,
              let source = environmentReflectionFramingSourceFrame ?? environmentSourceACEScgFrame
        else {
            errorMessage = "No hay un HDRI resuelto que colocar."
            return
        }
        do {
            let resolved = try resolveSceneFrame(currentFrame)
            let placement = try resolved.resolver.resolveEnvironmentFraming(
                frame: resolved.selection,
                sourceWidth: source.width,
                sourceHeight: source.height,
                framing: environmentReflectionFraming,
                expectedRevision: resolved.revision
            )
            let anchor = SIMD3<Double>(
                Double(placement.anchor_direction_world.0),
                Double(placement.anchor_direction_world.1),
                Double(placement.anchor_direction_world.2)
            )
            let sourceDirection = SIMD3<Double>(
                Double(placement.source_direction.0),
                Double(placement.source_direction.1),
                Double(placement.source_direction.2)
            )
            selection.environmentAnchorLongitudeDegrees = atan2(anchor.x, anchor.z) * 180 / .pi
            selection.environmentAnchorLatitudeDegrees = asin(min(1, max(-1, anchor.y))) * 180 / .pi
            selection.environmentRotationYDegrees = atan2(sourceDirection.x, sourceDirection.z) * 180 / .pi
            selection.environmentRotationXDegrees = -asin(min(1, max(-1, sourceDirection.y))) * 180 / .pi
            selection.environmentTangentTransform = [
                Double(placement.tangent_transform.0),
                Double(placement.tangent_transform.1),
                Double(placement.tangent_transform.2),
                Double(placement.tangent_transform.3),
            ]
            selection.previewQualityID = "environment-setup"
            try commitSceneAuthoringEdit(
                selection: selection,
                setting: [
                    "environment-anchor-longitude-degrees",
                    "environment-anchor-latitude-degrees",
                    "environment-rotation-x-degrees",
                    "environment-rotation-y-degrees",
                    "environment-mobius-a-real",
                    "environment-mobius-a-imag",
                    "environment-mobius-c-real",
                    "environment-mobius-c-imag",
                ],
                undoManager: nil,
                actionName: "Colocar entorno"
            )
            environmentReflectionFramingEnabled = false
            environmentReflectionFramingSourceFrame = nil
            // Applying ends the planar authoring aid. Publish the spherical Setup
            // explicitly from the newly committed scene instead of relying on a
            // later mode transition to redispatch the current quality.
            publishEnvironmentSetup()
            status = "Entorno colocado en el frame \(currentFrame) · HDRI original"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyTransientEnvironmentSelection(_ selection: TestAuthoringResolvedSelection) {
        guard var authored = basePhysicalAuthoringState else { return }
        authored.environment.rotationXDegrees = selection.environmentRotationXDegrees
        authored.environment.rotationYDegrees = selection.environmentRotationYDegrees
        authored.environment.placementAnchorDirectionWorld = Self.environmentDirection(
            longitudeDegrees: selection.environmentAnchorLongitudeDegrees,
            latitudeDegrees: selection.environmentAnchorLatitudeDegrees
        )
        authored.environment.placementSourceDirection = Self.environmentDirection(
            longitudeDegrees: selection.environmentRotationYDegrees,
            latitudeDegrees: -selection.environmentRotationXDegrees
        )
        authored.environment.placementTangentTransform = selection.environmentTangentTransform
        authored.environment.projectionMode = selection.environmentProjectionID == "finite-sphere" ? 1 : 0
        authored.environment.sphereCenterMeters = [
            selection.environmentSphereCenterXMeters,
            selection.environmentSphereCenterYMeters,
            selection.environmentSphereCenterZMeters,
        ]
        authored.environment.sphereRadiusMeters = selection.environmentSphereRadiusMeters
        testAuthoringSelection = selection
        do {
            physicalAuthoringState = authored
            basePhysicalAuthoringState = authored
            resolvedPhysicalPipeline = try authored.resolvedPipeline()
            physicalModel.invalidateExternalParameters(preservingQuality: true)
            publishEnvironmentSetup()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func environmentDirection(
        longitudeDegrees: Double,
        latitudeDegrees: Double
    ) -> [Double] {
        let longitude = longitudeDegrees * .pi / 180
        let latitude = latitudeDegrees * .pi / 180
        let latitudeCosine = cos(latitude)
        return [
            sin(longitude) * latitudeCosine,
            sin(latitude),
            cos(longitude) * latitudeCosine,
        ]
    }

    private func applyTransientCameraNavigationPose(
        _ pose: CameraNavigationPose,
        viewportSize: CGSize
    ) {
        _ = viewportSize
        // Interactive navigation is still scene authoring. Materialize each candidate through
        // the same transaction boundary as the cards so the image and the persistent tracking
        // overlay always share one resolved scene identity. Gesture end owns the single Undo.
        commitCameraNavigationPose(pose)
    }

    private func applyTransientDeviceNavigationPose(
        _ pose: CameraNavigationPose,
        viewportSize: CGSize
    ) {
        _ = viewportSize
        commitDeviceNavigationPose(pose)
    }

    private func applyInteractiveTrackingWorldScale(
        metersPerSourceUnit: Double,
        devicePose: CameraNavigationPose
    ) {
        guard metersPerSourceUnit.isFinite, metersPerSourceUnit > 0 else { return }
        // Cmd+MMB edits the canonical scene continuously. The imported camera is therefore
        // re-sampled by Rust at this scale and the Device anchor is committed from the same
        // gesture-start solution. Image and overlay can remain on one resolved identity.
        publishedSceneIdentity = nil
        publishedResolvedSceneFrame = nil
        trackingMetersPerSourceUnit = metersPerSourceUnit
        commitDeviceNavigationPose(devicePose)
    }

    private func commitCameraNavigationPose(_ pose: CameraNavigationPose) {
        guard var selection = testAuthoringSelection else { return }
        let degrees = PoseRotationProjection.degrees(from: [
            pose.orientation.imag.x, pose.orientation.imag.y,
            pose.orientation.imag.z, pose.orientation.real,
        ])
        selection.geometryModeID = "free"
        selection.previewQualityID = cameraNavigationPreviewQuality == .focusSetup
            ? "focus-setup" : "setup"
        selection.cameraPositionXMeters = pose.position.x
        selection.cameraPositionYMeters = pose.position.y
        selection.cameraPositionZMeters = pose.position.z
        selection.cameraRotationXDegrees = degrees[0]
        selection.cameraRotationYDegrees = degrees[1]
        selection.cameraRotationZDegrees = degrees[2]
        do {
            try commitSceneAuthoringEdit(
                selection: selection,
                setting: [
                    "geometry-mode",
                    "camera-position-x-meters", "camera-position-y-meters",
                    "camera-position-z-meters", "camera-rotation-x-degrees",
                    "camera-rotation-y-degrees", "camera-rotation-z-degrees",
                ],
                undoManager: nil,
                actionName: "Navegar cámara"
            )
        } catch {
            if let prior = cameraNavigationStartSelection {
                try? applyTestAuthoringSelection(prior)
            }
            errorMessage = error.localizedDescription
        }
    }

    private func commitDeviceNavigationPose(_ pose: CameraNavigationPose) {
        guard var selection = testAuthoringSelection else { return }
        let degrees = PoseRotationProjection.degrees(from: [
            pose.orientation.imag.x, pose.orientation.imag.y,
            pose.orientation.imag.z, pose.orientation.real,
        ])
        selection.previewQualityID = cameraNavigationPreviewQuality == .focusSetup
            ? "focus-setup" : "setup"
        selection.screenPositionXMeters = pose.position.x
        selection.screenPositionYMeters = pose.position.y
        selection.screenPositionZMeters = pose.position.z
        selection.screenRotationXDegrees = degrees[0]
        selection.screenYawDegrees = degrees[1]
        selection.screenRotationZDegrees = degrees[2]
        do {
            try commitSceneAuthoringEdit(
                selection: selection,
                setting: [
                    "screen-position-x-meters", "screen-position-y-meters",
                    "screen-position-z-meters", "screen-rotation-x-degrees",
                    "screen-yaw-degrees", "screen-rotation-z-degrees",
                ],
                undoManager: nil,
                actionName: "Mover Device"
            )
            applyTrackingCameraAtCurrentFrame()
        } catch {
            if let prior = cameraNavigationStartSelection {
                try? applyTestAuthoringSelection(prior)
                applyTrackingCameraAtCurrentFrame()
            }
            errorMessage = error.localizedDescription
        }
    }

    private func restoreTrackingWorldScale(
        _ scale: Double,
        snapshot: SceneAuthoringEditSnapshot,
        undoManager: UndoManager?
    ) throws {
        guard scale.isFinite, scale > 0 else { return }
        let currentScale = trackingMetersPerSourceUnit
        let currentSnapshot = sceneAuthoringEditSnapshot
        trackingMetersPerSourceUnit = scale
        try applyTestAuthoringSelection(snapshot.selection)
        explicitSceneOverrideControlIDs = snapshot.explicitOverrideControlIDs
        applyTrackingCameraAtCurrentFrame()
        if let currentScale, let currentSnapshot {
            registerUndo(with: undoManager, actionName: "Escalar mundo tracking") { target, manager in
                try? target.restoreTrackingWorldScale(
                    currentScale,
                    snapshot: currentSnapshot,
                    undoManager: manager
                )
            }
        }
    }

    func browseEnvironment() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        FileDialogDirectory.environment.apply(to: panel)
        panel.allowedContentTypes = [.image] + ["exr", "hdr"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.message = "Selecciona un panorama HDRI/OpenEXR equirectangular 2:1."
        let inputTransforms = StudioColorInputTransform.catalog.filter {
            $0.referenceDomain == .sceneReferred
        }
        let inputPicker = NSPopUpButton()
        for input in inputTransforms {
            inputPicker.addItem(withTitle: input.label)
            inputPicker.lastItem?.representedObject = input.id
        }
        inputPicker.selectItem(at: inputTransforms.firstIndex { $0.id == "linear-rec709" } ?? 0)
        let radianceField = NSTextField(string: "100")
        let exposureField = NSTextField(string: "-1")
        let accessory = NSGridView(views: [
            [NSTextField(labelWithString: "Input Transform"), inputPicker],
            [NSTextField(labelWithString: "cd/m² por unidad"), radianceField],
            [NSTextField(labelWithString: "Exposición EV"), exposureField],
        ])
        accessory.column(at: 0).xPlacement = .trailing
        accessory.column(at: 1).width = 260
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url,
              let inputID = inputPicker.selectedItem?.representedObject as? String,
              let unitRadiance = Double(radianceField.stringValue), unitRadiance.isFinite,
              unitRadiance > 0,
              let exposureStops = Double(exposureField.stringValue), exposureStops.isFinite,
              (-16 ... 16).contains(exposureStops)
        else { return }
        FileDialogDirectory.environment.remember(url)
        generatedReflectionEnvironmentData = nil
        environmentReflectionFramingSourceFrame = nil
        Task {
            await loadEnvironment(
                url, inputTransformID: inputID,
                unitRadiance: unitRadiance, exposureStops: exposureStops
            )
        }
    }

    var selectedReflectionEmitter: AuthoredReflectionEmitter? {
        guard let selectedReflectionEmitterID else { return nil }
        return reflectionEmitters.first { $0.id == selectedReflectionEmitterID }
    }

    var selectedReflectionEmitterHandles: [CGPoint] {
        guard reflectionEnvironmentEditorEnabled,
              let emitter = selectedReflectionEmitter,
              let frame = metalFrame,
              let selection = testAuthoringSelection
        else { return [] }
        return ReflectionEditorRasterMapping.presentationPoints(
            emitter.handles,
            deliverySize: CGSize(
                width: Int(selection.deliveryWidth), height: Int(selection.deliveryHeight)
            ),
            previewSize: CGSize(width: frame.width, height: frame.height)
        )
    }

    var selectedReflectionEmitterSoftnessPixels: CGFloat {
        guard reflectionEnvironmentEditorEnabled,
              let emitter = selectedReflectionEmitter,
              let authored = physicalAuthoringState,
              let selection = testAuthoringSelection,
              let frame = metalFrame
        else { return 0 }
        let cameraWidth = Double(authored.sensor.nativeWidth)
        let cameraHeight = Double(authored.sensor.nativeHeight)
        let deliveryWidth = Double(selection.deliveryWidth)
        let deliveryHeight = Double(selection.deliveryHeight)
        let placementScale: Double = switch selection.deliveryPlacementID {
        case "fit": min(deliveryWidth / cameraWidth, deliveryHeight / cameraHeight)
        case "fill-crop": max(deliveryWidth / cameraWidth, deliveryHeight / cameraHeight)
        case "one-to-one": 1
        default: 1
        }
        let xPixelsPerRadian = authored.sceneLens.focalLengthMillimeters
            / authored.sceneLens.sensorWidthMillimeters * cameraWidth
        let yPixelsPerRadian = authored.sceneLens.focalLengthMillimeters
            / authored.sceneLens.sensorHeightMillimeters * cameraHeight
        let deliveryPixelsPerRadian = sqrt(xPixelsPerRadian * yPixelsPerRadian) * placementScale
        let previewScale = sqrt(
            Double(frame.width) / deliveryWidth * Double(frame.height) / deliveryHeight
        )
        return CGFloat(
            emitter.softnessDegrees * .pi / 180 * deliveryPixelsPerRadian * previewScale
        )
    }

    func setReflectionEnvironmentEditorEnabled(_ enabled: Bool) {
        reflectionEnvironmentEditorEnabled = enabled
        reflectionHandleDragIndex = nil
        guard enabled else { return }
        referenceMatchEnabled = false
        // Reflection authoring is drawn over the camera/reference framing. It
        // must not enter Environment Setup: that diagnostic replaces the
        // reference with a selected HDRI and cannot exist before generation.
        physicalModel.setQuality(.setup)
        if reflectionEmitters.isEmpty { addReflectionEmitter(.practical) }
        rebuildPhysicalSelectedFrame()
    }

    func addReflectionEmitter(_ kind: AuthoredReflectionEmitterKind) {
        let frameWidth = max(1, Int(testAuthoringSelection?.deliveryWidth ?? 1920))
        let frameHeight = max(1, Int(testAuthoringSelection?.deliveryHeight ?? 1080))
        let usable = reflectionEditorBounds(width: frameWidth, height: frameHeight)
        let center = CGPoint(x: usable.midX, y: usable.midY)
        let handles: [CGPoint]
        switch kind {
        case .practical:
            handles = [
                center,
                CGPoint(x: center.x + usable.width * 0.06, y: center.y),
            ]
        case .window:
            handles = rectangleHandles(center: center, width: usable.width * 0.28, height: usable.height * 0.34)
        case .sun:
            handles = [center]
        }
        let emitter = AuthoredReflectionEmitter(
            id: UUID(), kind: kind, handles: handles,
            distanceMeters: kind == .sun ? 1_000 : 3,
            radianceCandelasPerSquareMeter: kind == .sun ? 15_000 : 2_500,
            temperatureKelvin: kind == .window ? 6_500 : 3_200,
            tint: 0, softnessDegrees: kind == .sun ? 0.1 : 0.5,
            sunAngularDiameterDegrees: 0.53
        )
        reflectionEmitters.append(emitter)
        selectedReflectionEmitterID = emitter.id
    }

    func selectReflectionEmitter(_ id: UUID?) {
        selectedReflectionEmitterID = id
    }

    func updateSelectedReflectionEmitter(
        _ keyPath: WritableKeyPath<AuthoredReflectionEmitter, Double>, value: Double
    ) {
        guard value.isFinite, let id = selectedReflectionEmitterID,
              let index = reflectionEmitters.firstIndex(where: { $0.id == id })
        else { return }
        reflectionEmitters[index][keyPath: keyPath] = value
    }

    func deleteSelectedReflectionEmitter() {
        guard let id = selectedReflectionEmitterID,
              let index = reflectionEmitters.firstIndex(where: { $0.id == id })
        else { return }
        reflectionEmitters.remove(at: index)
        selectedReflectionEmitterID = reflectionEmitters.first?.id
    }

    func beginReflectionHandleDrag(_ index: Int) {
        guard !previewTransformationsLocked,
              reflectionEnvironmentEditorEnabled,
              selectedReflectionEmitterHandles.indices.contains(index)
        else { return }
        reflectionHandleDragIndex = index
    }

    func updateReflectionHandle(_ index: Int, point: CGPoint) {
        guard !previewTransformationsLocked,
              reflectionHandleDragIndex == index,
              let id = selectedReflectionEmitterID,
              let emitterIndex = reflectionEmitters.firstIndex(where: { $0.id == id }),
              reflectionEmitters[emitterIndex].handles.indices.contains(index),
              let frame = metalFrame,
              let selection = testAuthoringSelection
        else { return }
        let deliverySize = CGSize(
            width: Int(selection.deliveryWidth), height: Int(selection.deliveryHeight)
        )
        let deliveryPoint = ReflectionEditorRasterMapping.deliveryPoint(
            point,
            deliverySize: deliverySize,
            previewSize: CGSize(width: frame.width, height: frame.height)
        )
        let constrained = CGPoint(
            x: min(deliverySize.width - 1, max(0, deliveryPoint.x)),
            y: min(deliverySize.height - 1, max(0, deliveryPoint.y))
        )
        if reflectionEmitters[emitterIndex].kind == .practical,
           index == 0,
           reflectionEmitters[emitterIndex].handles.count == 2 {
            let prior = reflectionEmitters[emitterIndex].handles[0]
            let delta = CGPoint(x: constrained.x - prior.x, y: constrained.y - prior.y)
            let priorRadius = reflectionEmitters[emitterIndex].handles[1]
            reflectionEmitters[emitterIndex].handles[1] = CGPoint(
                x: min(deliverySize.width - 1, max(0, priorRadius.x + delta.x)),
                y: min(deliverySize.height - 1, max(0, priorRadius.y + delta.y))
            )
        }
        reflectionEmitters[emitterIndex].handles[index] = constrained
    }

    func endReflectionHandleDrag() {
        reflectionHandleDragIndex = nil
    }

    func generateAndUseReflectionEnvironment() async {
        guard !reflectionEnvironmentIsGenerating else { return }
        reflectionEnvironmentIsGenerating = true
        defer { reflectionEnvironmentIsGenerating = false }
        do {
            let emitters = try reflectionEmitters.map(reflectionBridgeEmitter)
            let width = reflectionEnvironmentWidth
            let height = width / 2
            status = "Creando entorno de reflejos…"
            let pixels = try ReflectionEnvironmentCompiler.compile(
                emitters: emitters, width: width, height: height
            )
            let data = try ReflectionEnvironmentCompiler.encodeEXR(
                pixels, width: width, height: height
            )
            let asset: ManagedEnvironmentAsset
            if let activeSceneID, let persistGeneratedEnvironment {
                asset = try persistGeneratedEnvironment(activeSceneID, data)
            } else {
                asset = try EnvironmentAssetLibrary.storeGeneratedEXR(
                    data, suggestedName: "Reflejos creados"
                )
            }
            let calibration = try EnvironmentAssetCalibration(
                inputTransformID: "acescg",
                sourceUnitRadianceCandelasPerSquareMeter: 1,
                exposureEV: 0
            )
            try EnvironmentAssetLibrary.saveCalibration(calibration, for: asset)
            generatedReflectionEnvironmentData = data
            try resetGeneratedEnvironmentPlacement()
            guard await loadEnvironment(
                asset.url, inputTransformID: calibration.inputTransformID,
                unitRadiance: calibration.sourceUnitRadianceCandelasPerSquareMeter,
                exposureStops: calibration.exposureEV, originalFileName: asset.originalFileName,
                knownHash: asset.sha256
            ) else { return }
            status = "Entorno de reflejos generado · \(width)×\(height) · \(asset.originalFileName)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func configureSceneEnvironmentPersistence(
        _ persistence: @escaping (UUID, Data) throws -> ManagedEnvironmentAsset
    ) {
        persistGeneratedEnvironment = persistence
    }

    func markActiveScene(_ id: UUID?) {
        if activeSceneID != id {
            previewTransformationsLocked = true
        }
        activeSceneID = id
    }

    private func reflectionEditorBounds(width: Int, height: Int) -> CGRect {
        if setupDeviceBoundary.count == 4 {
            let xs = setupDeviceBoundary.map(\.x)
            let ys = setupDeviceBoundary.map(\.y)
            let bounds = CGRect(
                x: xs.min() ?? 0, y: ys.min() ?? 0,
                width: max(1, (xs.max() ?? CGFloat(width)) - (xs.min() ?? 0)),
                height: max(1, (ys.max() ?? CGFloat(height)) - (ys.min() ?? 0))
            )
            return bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.08)
        }
        return CGRect(x: 0, y: 0, width: width, height: height)
            .insetBy(dx: CGFloat(width) * 0.2, dy: CGFloat(height) * 0.2)
    }

    private func rectangleHandles(center: CGPoint, width: CGFloat, height: CGFloat) -> [CGPoint] {
        [
            CGPoint(x: center.x - width * 0.5, y: center.y - height * 0.5),
            CGPoint(x: center.x + width * 0.5, y: center.y - height * 0.5),
            CGPoint(x: center.x + width * 0.5, y: center.y + height * 0.5),
            CGPoint(x: center.x - width * 0.5, y: center.y + height * 0.5),
        ]
    }

    private func reflectionBridgeEmitter(
        _ emitter: AuthoredReflectionEmitter
    ) throws -> ScreenReflectionEmitterV2 {
        let directions = try reflectionDirections(for: emitter.handles)
        guard !directions.isEmpty else { throw ReflectionEnvironmentEditorError.invalidGeometry }
        var value = ScreenReflectionEmitterV2()
        value.abi_version = SCREEN_REFLECTION_ENVIRONMENT_ABI_VERSION
        value.kind = switch emitter.kind { case .practical: 0; case .window: 1; case .sun: 2 }
        withUnsafeMutableBytes(of: &value.directions_xyz) { bytes in
            let output = bytes.bindMemory(to: Float.self)
            for index in 0 ..< min(4, directions.count) {
                output[index * 3] = Float(directions[index].x)
                output[index * 3 + 1] = Float(directions[index].y)
                output[index * 3 + 2] = Float(directions[index].z)
            }
        }
        if emitter.kind == .practical, directions.count == 2 {
            value.angular_diameter_degrees = Float(
                2 * angleDegrees(directions[0], directions[1])
            )
        } else if emitter.kind == .sun {
            value.angular_diameter_degrees = Float(emitter.sunAngularDiameterDegrees)
        }
        value.distance_meters = Float(emitter.distanceMeters)
        value.radiance_candelas_per_square_meter = Float(emitter.radianceCandelasPerSquareMeter)
        value.temperature_kelvin = Float(emitter.temperatureKelvin)
        value.tint = Float(emitter.tint)
        value.edge_softness_degrees = Float(emitter.softnessDegrees)
        return value
    }

    private func reflectionDirections(for points: [CGPoint]) throws -> [SIMD3<Double>] {
        guard let authored = physicalAuthoringState, let selection = testAuthoringSelection else {
            throw ReflectionEnvironmentEditorError.invalidGeometry
        }
        let gatePoints = try ReferenceMatchRasterMapping.cameraGateCorners(
            points,
            referenceWidth: Int(selection.deliveryWidth),
            referenceHeight: Int(selection.deliveryHeight),
            cameraWidth: authored.sensor.nativeWidth,
            cameraHeight: authored.sensor.nativeHeight,
            deliveryPlacementID: selection.deliveryPlacementID
        )
        let camera = simd_quatd(
            ix: authored.cameraPose.quaternion[0], iy: authored.cameraPose.quaternion[1],
            iz: authored.cameraPose.quaternion[2], r: authored.cameraPose.quaternion[3]
        ).normalized
        let forward = camera.act(SIMD3<Double>(0, 0, -1))
        let right = camera.act(SIMD3<Double>(1, 0, 0))
        let up = camera.act(SIMD3<Double>(0, 1, 0))
        let screen = simd_quatd(
            ix: authored.screenPose.quaternion[0], iy: authored.screenPose.quaternion[1],
            iz: authored.screenPose.quaternion[2], r: authored.screenPose.quaternion[3]
        ).normalized
        let normal = screen.act(SIMD3<Double>(0, 0, 1))
        let gateWidth = Double(authored.sensor.nativeWidth)
        let gateHeight = Double(authored.sensor.nativeHeight)
        var result: [SIMD3<Double>] = []
        result.reserveCapacity(gatePoints.count)
        for point in gatePoints {
            let observedX = (Double(point.x) + 0.5) / gateWidth * 2 - 1
            let observedY = (Double(point.y) + 0.5) / gateHeight * 2 - 1
            let idealX = observedX + 2 * authored.sceneLens.lensShift[0]
            let idealY = -observedY - 2 * authored.sceneLens.lensShift[1]
            let horizontalScale = idealX * authored.sceneLens.sensorWidthMillimeters
                / (2 * authored.sceneLens.focalLengthMillimeters)
            let verticalScale = idealY * authored.sceneLens.sensorHeightMillimeters
                / (2 * authored.sceneLens.focalLengthMillimeters)
            let unnormalizedRay = forward + right * horizontalScale + up * verticalScale
            let ray = simd_normalize(unnormalizedRay)
            let reflected = ray - normal * (2 * simd_dot(ray, normal))
            result.append(simd_normalize(reflected))
        }
        return result
    }

    private func angleDegrees(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(min(1, max(-1, simd_dot(a, b)))) * 180 / .pi
    }

    private func resetGeneratedEnvironmentPlacement() throws {
        guard var selection = currentTestAuthoringSelection() else {
            throw TestAuthoringCoordinatorError.malformedDescriptor("No existe autoría de entorno.")
        }
        selection = try RustTestAuthoringCoordinator.apply(
            .setScalar(controlID: "environment-rotation-x-degrees", value: 0),
            to: selection, profileContext: testAuthoringProfileContext
        )
        selection = try RustTestAuthoringCoordinator.apply(
            .setScalar(controlID: "environment-rotation-y-degrees", value: 0),
            to: selection, profileContext: testAuthoringProfileContext
        )
        for controlID in [
            "environment-anchor-longitude-degrees",
            "environment-anchor-latitude-degrees",
            "environment-mobius-a-imag",
            "environment-mobius-c-real",
            "environment-mobius-c-imag",
        ] {
            selection = try RustTestAuthoringCoordinator.apply(
                .setScalar(controlID: controlID, value: 0),
                to: selection, profileContext: testAuthoringProfileContext
            )
        }
        selection = try RustTestAuthoringCoordinator.apply(
            .setScalar(controlID: "environment-mobius-a-real", value: 1),
            to: selection, profileContext: testAuthoringProfileContext
        )
        selection = try RustTestAuthoringCoordinator.apply(
            .setChoice(controlID: "environment-projection", optionID: "distant"),
            to: selection, profileContext: testAuthoringProfileContext
        )
        try commitSceneAuthoringEdit(
            selection: selection,
            setting: [
                "environment-rotation-x-degrees",
                "environment-rotation-y-degrees",
                "environment-anchor-longitude-degrees",
                "environment-anchor-latitude-degrees",
                "environment-mobius-a-real",
                "environment-mobius-a-imag",
                "environment-mobius-c-real",
                "environment-mobius-c-imag",
                "environment-projection",
            ],
            undoManager: nil,
            actionName: "Fijar entorno generado"
        )
    }

    private struct PreparedEnvironmentResource {
        let managed: ManagedEnvironmentAsset
        let calibration: EnvironmentAssetCalibration
        let input: StudioColorInputTransform
        let source: StudioColorMetalFrame
        let adjustment: SceneAdjustmentFrame
        let radiance: EnvironmentRadianceFrame
        let resolution: CGSize
    }

    private func prepareEnvironmentResource(
        _ url: URL,
        inputTransformID: String,
        unitRadiance: Double,
        exposureStops: Double,
        originalFileName: String?,
        knownHash: String?,
        adjustmentSelection: TestAuthoringResolvedSelection?
    ) async throws -> PreparedEnvironmentResource {
        let managed: ManagedEnvironmentAsset
        if let originalFileName, let knownHash {
            managed = .init(url: url, originalFileName: originalFileName, sha256: knownHash)
        } else {
            managed = try EnvironmentAssetLibrary.importAsset(from: url)
        }
        let calibration = try EnvironmentAssetCalibration(
            inputTransformID: inputTransformID,
            sourceUnitRadianceCandelasPerSquareMeter: unitRadiance,
            exposureEV: exposureStops
        )
        if knownHash != nil {
            try EnvironmentAssetLibrary.saveCalibration(calibration, for: managed)
        }
        let decoded = try await NativeMediaDecoder.decode(url: managed.url, time: .zero)
        guard decoded.width == decoded.height * 2 else {
            throw EnvironmentRadianceFrameError.invalidEquirectangularRaster
        }
        guard let input = StudioColorInputTransform.catalog.first(where: {
            $0.id == inputTransformID && $0.referenceDomain == .sceneReferred
        }) else {
            throw NativeMediaError.unreadable(
                "El Input Transform explícito del entorno no existe o no es scene-referred."
            )
        }
        let source = try metalDisplay.makeACEScgFrame(
            width: decoded.width, height: decoded.height,
            encodedRGBA: decoded.rgba, input: input, alpha: .ignore
        )
        let adjustment = try SceneAdjustmentFrame(
            source: source,
            parameters: .init(
                exposureEV: 0,
                contrast: adjustmentSelection?.environmentContrast ?? 1,
                saturation: adjustmentSelection?.environmentSaturation ?? 1,
                temperatureKelvin: adjustmentSelection?.environmentTemperatureKelvin ?? 6500,
                tint: adjustmentSelection?.environmentTint ?? 0
            ),
            incidentRadiance: true
        )
        return try .init(
            managed: managed,
            calibration: calibration,
            input: input,
            source: source,
            adjustment: adjustment,
            radiance: EnvironmentRadianceFrame.prefiltered(from: adjustment.frame),
            resolution: .init(width: decoded.width, height: decoded.height)
        )
    }

    @discardableResult
    private func loadEnvironment(
        _ url: URL,
        inputTransformID: String,
        unitRadiance: Double,
        exposureStops: Double,
        originalFileName: String? = nil,
        knownHash: String? = nil
    ) async -> Bool {
        do {
            status = "Decodificando entorno HDR…"
            let prepared = try await prepareEnvironmentResource(
                url,
                inputTransformID: inputTransformID,
                unitRadiance: unitRadiance,
                exposureStops: exposureStops,
                originalFileName: originalFileName,
                knownHash: knownHash,
                adjustmentSelection: currentTestAuthoringSelection()
            )
            environmentSourceACEScgFrame = prepared.source
            environmentAdjustmentOwner = prepared.adjustment
            guard var authored = physicalAuthoringState else { return false }
            authored.environment.sourceKind = 1
            authored.environment.sourceUnitRadianceCandelasPerSquareMeter = unitRadiance
            authored.environment.exposureStops = exposureStops
            authored.environment.ambientRadianceACEScg = [0, 0, 0]
            authored.environment.keyRadianceACEScg = [0, 0, 0]
            authored.environment.pattern = 0
            resolvedPhysicalPipeline = try authored.resolvedPipeline()
            physicalAuthoringState = authored
            basePhysicalAuthoringState = authored
            environmentRadianceFrame = prepared.radiance
            authoredImageEnvironment = authored.environment
            environmentSourceName = prepared.managed.originalFileName
            environmentSourceResolution = prepared.resolution
            environmentSourceInputTransformID = inputTransformID
            environmentSourceHash = knownHash
            environmentSourceURL = prepared.managed.url
            environmentSourceCalibration = prepared.calibration
            guard let current = currentTestAuthoringSelection() else {
                throw TestAuthoringCoordinatorError.malformedDescriptor(
                    "Test no tiene una selección resuelta para el entorno externo."
                )
            }
            var selected = try RustTestAuthoringCoordinator.apply(
                .setChoice(controlID: "environment-source", optionID: "environment-image"),
                to: current, profileContext: testAuthoringProfileContext
            )
            selected = try RustTestAuthoringCoordinator.apply(
                .setScalar(controlID: "environment-exposure-ev", value: exposureStops),
                to: selected, profileContext: testAuthoringProfileContext
            )
            physicalModel.invalidateExternalParameters()
            try commitSceneAuthoringEdit(
                selection: selected,
                setting: ["environment-source", "environment-exposure-ev"],
                undoManager: nil,
                actionName: "Seleccionar entorno"
            )
            status = "Entorno cargado · visible desde Draft · \(prepared.managed.originalFileName) · \(Int(prepared.resolution.width))×\(Int(prepared.resolution.height)) · \(prepared.input.label)"
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func testPhaseToReveal(for intent: TestControlIntent) -> String? {
        let controlID: String
        switch intent {
        case let .setChoice(id, _), let .setScalar(id, _), let .setToggle(id, _): controlID = id
        case let .reset(id): controlID = id
        case .selectPhase, .performAction: return nil
        }
        guard let presentation = testPresentation,
              let selectedIndex = presentation.phases.firstIndex(where: {
                  $0.id == presentation.selectedPhaseID
              }),
              let ownerIndex = presentation.phases.firstIndex(where: { phase in
                  phase.sections.flatMap(\.controls).contains(where: { $0.id == controlID })
              }),
              ownerIndex > selectedIndex
        else { return nil }
        return presentation.phases[ownerIndex].id
    }

    private func resetIntent(for controlID: String) throws -> TestControlIntent {
        if let baseline = sceneProfileBaselineByControlID[controlID] {
            return baseline.intent
        }
        guard let presentation = testPresentation else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "Test no ha publicado el control que se quiere restablecer."
            )
        }
        let controls = presentation.previewControls + presentation.phases.flatMap {
            $0.sections.flatMap(\.controls)
        }
        guard let descriptor = controls.first(where: { $0.id == controlID }) else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "Test no reconoce el control \(controlID)."
            )
        }
        switch descriptor {
        case let .choice(control):
            return .setChoice(controlID: controlID, optionID: control.resetID)
        case let .scalar(control):
            return .setScalar(controlID: controlID, value: control.resetValue)
        case let .toggle(control):
            return .setToggle(controlID: controlID, value: control.resetValue)
        case .action, .readOnly:
            throw TestAuthoringCoordinatorError.unsupportedIntent
        }
    }

    func changePhysicalQuality(_ quality: PhysicalQuality) {
        if quality == .environmentSetup {
            do {
                try ensureFiniteEnvironmentEnclosesTimeline()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        let qualityChanged = physicalModel.quality != quality
        physicalModel.setQuality(quality)
        if !qualityChanged {
            rebuildPhysicalSelectedFrame()
        }
    }

    func setModelViewportSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 1, size.height > 1,
              modelViewport != size
        else { return }
        modelViewport = size
        if isModelPageActive, physicalModel.quality != .native {
            rebuildPhysicalSelectedFrame()
        }
    }

    func scheduleModelViewportSize(_ size: CGSize) {
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.setModelViewportSize(size)
        }
    }

    func publishSystemDisplayInfo(_ info: StudioColorSystemDisplayInfo) {
        guard systemDisplayInfo != info else { return }
        systemDisplayInfo = info
    }

    func changePhysicalDomainAmount(_ amount: Double, domain: PhysicalDomainID) {
        do {
            try physicalModel.setDomainAmount(amount, domain: domain)
        } catch {
            errorMessage = "Amount físico fuera de los límites seguros 0–4."
        }
    }

    func changePhysicalDomainBypass(
        _ bypassed: Bool,
        domain: PhysicalDomainID,
        undoManager: UndoManager?
    ) {
        let prior = physicalModel.screenIsBypassed
        guard prior != bypassed else { return }
        do {
            try physicalModel.setDomainBypassed(bypassed, domain: domain)
            let action = bypassed ? "Omitir Pantalla" : "Activar Pantalla"
            registerUndo(with: undoManager, actionName: action) { [prior, domain] target, manager in
                target.changePhysicalDomainBypass(prior, domain: domain, undoManager: manager)
            }
        } catch {
            errorMessage = "El dominio no admite bypass continuo."
        }
    }

    func changePhysicalStageAmount(_ amount: Double, stage: PhysicalStageID) {
        do {
            try physicalModel.setContinuousAmount(amount, stage: stage)
        } catch {
            errorMessage = "La contribución no admite ese valor."
        }
    }

    func changePhysicalStageBypass(
        _ bypassed: Bool,
        stage: PhysicalStageID,
        undoManager: UndoManager?
    ) {
        let prior = physicalModel.stageValue(stage).isBypassed
        guard prior != bypassed else { return }
        do {
            try physicalModel.setContinuousBypassed(bypassed, stage: stage)
            let action = bypassed ? "Omitir etapa" : "Activar etapa"
            registerUndo(with: undoManager, actionName: action) { [prior, stage] target, manager in
                target.changePhysicalStageBypass(prior, stage: stage, undoManager: manager)
            }
        } catch {
            errorMessage = "La etapa no admite bypass continuo."
        }
    }

    func changePhysicalStageEnabled(_ enabled: Bool, stage: PhysicalStageID) {
        do {
            try physicalModel.setDiscreteEnabled(enabled, stage: stage)
        } catch {
            errorMessage = "La etapa no es discreta."
        }
    }

    func togglePhysicalIsolation(_ stage: PhysicalStageID) {
        do { try physicalModel.toggleIsolation(stage) }
        catch { errorMessage = "No se ha podido aislar la etapa." }
    }

    func resetPhysicalStage(_ stage: PhysicalStageID) {
        do { try physicalModel.resetToPhysical(stage) }
        catch { errorMessage = "No se ha podido restablecer la etapa." }
    }

    func renderSelectedPhysicalFrameNative() {
        guard !nativeRenderTaskActive else { return }
        pause()
        nativeCancellationRequested = false
        do {
            try ensureFiniteEnvironmentEnclosesTimeline()
            try physicalModel.beginNative()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        nativeRenderTaskActive = true
        physicalNativeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let submission = try await submitPhysicalJob(quality: .native)
                physicalNativeJob = submission.job
                if nativeCancellationRequested {
                    _ = submission.job.cancel()
                }
                try await pollPhysicalJob(
                    submission,
                    native: true
                )
            } catch is CancellationError {
                if physicalModel.frameState == .rendering {
                    physicalModel.confirmNativeCancellation()
                }
            } catch {
                if !Task.isCancelled {
                    physicalModel.failNative()
                    errorMessage = error.localizedDescription
                    physicalPublicationSummary = "Native falló · \(error.localizedDescription)"
                    physicalPublicationLog.error("native job failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            physicalNativeJob = nil
            physicalNativeTask = nil
            nativeCancellationRequested = false
            nativeRenderTaskActive = false
        }
    }

    func cancelSelectedPhysicalFrameNative() {
        guard nativeRenderTaskActive else { return }
        nativeCancellationRequested = true
        physicalModel.requestNativeCancellation()
    }

    func performNativeRenderButtonAction() {
        if !nativeRenderTaskActive {
            renderSelectedPhysicalFrameNative()
        } else if !nativeCancellationRequested {
            cancelSelectedPhysicalFrameNative()
        }
    }

    func changeSourcePlacement(_ placement: SourcePlacement) {
        sourcePlacement = placement
        rebuildCurrent()
    }

    var requestedSeconds: Double {
        get { Double(currentFrame) / frameRate }
        set { seek(toFrame: Int((newValue * frameRate).rounded())) }
    }

    var timecode: String {
        let rate = max(1, Int(frameRate.rounded()))
        let frames = max(0, currentFrame)
        let hours = frames / (rate * 3_600)
        let minutes = (frames / (rate * 60)) % 60
        let seconds = (frames / rate) % 60
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames % rate)
    }

    var effectiveAlpha: StudioColorAlphaAssociation {
        switch alphaMode {
        case .straight: return StudioColorAlphaAssociation.straight
        case .premultiplied: return StudioColorAlphaAssociation.premultiplied
        case .ignore: return StudioColorAlphaAssociation.ignore
        }
    }

    var effectiveMatrix: StudioColorSignalMatrix {
        switch signalMatrix {
        case .bt601: return StudioColorSignalMatrix.bt601
        case .bt2020: return StudioColorSignalMatrix.bt2020
        case .bt709: return StudioColorSignalMatrix.bt709
        }
    }

    var effectiveRange: StudioColorSignalRange {
        switch signalRange {
        case .full: return StudioColorSignalRange.full
        case .video: return StudioColorSignalRange.video
        }
    }

    private var referenceEffectiveAlpha: StudioColorAlphaAssociation {
        switch referenceAlphaMode {
        case .straight: .straight
        case .premultiplied: .premultiplied
        case .ignore: .ignore
        }
    }

    private var referenceEffectiveMatrix: StudioColorSignalMatrix {
        switch referenceSignalMatrix {
        case .bt601: .bt601
        case .bt2020: .bt2020
        case .bt709: .bt709
        }
    }

    private var referenceEffectiveRange: StudioColorSignalRange {
        switch referenceSignalRange {
        case .full: .full
        case .video: .video
        }
    }

    var activeFrameRange: ClosedRange<Int> {
        renderRange == .inOut ? min(inFrame, outFrame) ... max(inFrame, outFrame) : 0 ... max(0, frameCount - 1)
    }

    func inputAnnotation(_ value: StudioColorInputTransform) -> String? {
        if value.id == detection.proposedInputTransformID {
            return detection.inputTransformProvenance?.feminineLabel ?? "Propuesta"
        }
        return nil
    }

    func alphaAnnotation(_ value: StudioAlphaMode) -> String? {
        if value == detection.alpha {
            return detection.alphaProvenance?.masculineLabel ?? "Propuesto"
        }
        return nil
    }

    func matrixAnnotation(_ value: StudioSignalMatrix) -> String? {
        if value == detection.matrix {
            return detection.matrixProvenance?.feminineLabel ?? "Propuesta"
        }
        return nil
    }

    func rangeAnnotation(_ value: StudioSignalRange) -> String? {
        if value == detection.range {
            return detection.rangeProvenance?.masculineLabel ?? "Propuesto"
        }
        return nil
    }

    func colorModelAnnotation(_ value: StudioSignalColorModel) -> String? {
        if value == detection.colorModel {
            return detection.colorModelProvenance?.masculineLabel ?? "Propuesto"
        }
        return nil
    }

    /// Initial import materializes one complete editable interpretation before
    /// either media adapter opens the source. Detected values are preserved;
    /// absent values use declared product defaults and are disclosed to the user.
    private func adoptSourceImportInterpretation(_ proposal: StudioMediaDetection) throws {
        guard let inputID = proposal.proposedInputTransformID,
              let input = StudioColorInputTransform.catalog.first(where: { $0.id == inputID }),
              let alpha = proposal.alpha,
              let matrix = proposal.matrix,
              let range = proposal.range,
              let colorModel = proposal.colorModel
        else {
            throw NativeMediaError.unreadable(
                "La metadata no proporciona una interpretación completa para importar el vídeo."
            )
        }
        inputTransform = input
        alphaMode = alpha
        signalMatrix = matrix
        signalRange = range
        signalColorModel = colorModel
    }

    private func adoptReferenceImportInterpretation(_ proposal: StudioMediaDetection) throws {
        guard let inputID = proposal.proposedInputTransformID,
              let input = StudioColorInputTransform.catalog.first(where: { $0.id == inputID }),
              let alpha = proposal.alpha,
              let matrix = proposal.matrix,
              let range = proposal.range,
              let colorModel = proposal.colorModel
        else {
            throw NativeMediaError.unreadable(
                "La metadata no proporciona una interpretación completa para importar el vídeo de referencia."
            )
        }
        referenceInputTransform = input
        referenceAlphaMode = alpha
        referenceSignalMatrix = matrix
        referenceSignalRange = range
        referenceSignalColorModel = colorModel
    }

    private func acknowledgeImportDefaults(
        _ resolution: StudioMediaImportResolution,
        role: String
    ) {
        guard !resolution.nonMetadataFields.isEmpty else { return }
        guard let inputTransform = resolution.detection.proposedInputTransformID,
              let colorModel = resolution.detection.colorModel,
              let matrix = resolution.detection.matrix,
              let range = resolution.detection.range,
              let alpha = resolution.detection.alpha
        else {
            preconditionFailure("La resolución de importación debe ser completa.")
        }
        let values: [StudioImportInterpretationField: String] = [
            .inputTransform: inputTransform,
            .colorModel: colorModel.label,
            .matrix: matrix.label,
            .range: range.label,
            .alpha: alpha.label,
        ]
        let assumptions = resolution.nonMetadataFields.map { field in
            "• \(field.label): \(values[field] ?? "")"
        }.joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Metadata incompleta en \(role)"
        alert.informativeText = """
        El archivo se importará con estos valores por defecto, no detectados en su metadata:

        \(assumptions)

        Puedes cambiarlos después en Interpretación de entrada.
        """
        alert.addButton(withTitle: "Usar valores por defecto")
        _ = alert.runModal()
    }

    func choosePattern(_ pattern: SyntheticPattern, undoManager: UndoManager?) {
        let prior = selectedPattern
        registerUndo(with: undoManager, actionName: "Cambiar patrón") { target, manager in
            target.choosePattern(prior, undoManager: manager)
        }
        pause()
        session.reset()
        selectedPattern = pattern
        sourceIsPattern = true
        includeAudio = false
        sourceName = pattern.label
        sourceDetail = "Patrón SCREEN canónico"
        detection = pattern.sourceDetection
        guard let inputID = detection.proposedInputTransformID,
              let resolvedInput = StudioColorInputTransform.catalog.first(
                where: { $0.id == inputID }
              ),
              let resolvedAlpha = detection.alpha,
              let resolvedMatrix = detection.matrix,
              let resolvedRange = detection.range,
              let resolvedColorModel = detection.colorModel
        else {
            preconditionFailure("El contrato del patrón sintético debe ser completo.")
        }
        inputTransform = resolvedInput
        alphaMode = resolvedAlpha
        signalMatrix = resolvedMatrix
        signalRange = resolvedRange
        signalColorModel = resolvedColorModel
        sourceTimelineInfo = NativeVideoTimelineInfo(
            exactFrameRate: .fps24,
            frameCount: pattern == .animatedCheckerboard ? 240 : 1
        )
        applyTimelineAuthority(resetRange: true)
        do {
            if let selection = currentTestAuthoringSelection() {
                let resolved = try RustTestAuthoringCoordinator.apply(
                    .setChoice(
                        controlID: "placement",
                        optionID: pattern.authoredPlacementID
                    ),
                    to: selection, profileContext: testAuthoringProfileContext
                )
                guard let placement = SourcePlacement(stableID: resolved.placementID) else {
                    throw TestAuthoringCoordinatorError.malformedDescriptor(
                        "Application/Rust devolvió una colocación desconocida para el patrón."
                    )
                }
                testAuthoringSelection = resolved
                sourcePlacement = placement
                try refreshTestAuthoringDescriptor()
            } else {
                guard let placement = SourcePlacement(stableID: pattern.authoredPlacementID) else {
                    throw TestAuthoringCoordinatorError.malformedDescriptor(
                        "El patrón declara una colocación desconocida."
                    )
                }
                sourcePlacement = placement
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        renderPattern()
    }

    func removeExternalSourceMedia() {
        guard hasExternalSourceMedia else { return }
        choosePattern(selectedPattern, undoManager: nil)
    }

    func openMedia() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .image, .folder]
        FileDialogDirectory.sourceMedia.apply(to: panel)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        FileDialogDirectory.sourceMedia.remember(panel.urls[0])
        Task { await load(panel.urls) }
    }

    func browseReferenceFrame() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .image]
        panel.message = "Selecciona la imagen o película usada como referencia de encuadre."
        FileDialogDirectory.referenceMedia.apply(to: panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileDialogDirectory.referenceMedia.remember(url)
        Task { await loadReferenceFrame(url) }
    }

    func removeReferenceFrame() {
        referenceRefreshTask?.cancel()
        referenceRefreshTask = nil
        referenceACEScgFrame = nil
        referenceForegroundFrame = nil
        referenceForegroundIsDeliveryAligned = false
        referenceSourceURL = nil
        referenceInputTransformID = nil
        referenceSourceHash = nil
        referenceTimelineInfo = nil
        referenceFrameName = nil
        referenceFrameDetail = nil
        referencePlacement = .fit
        referenceMatchCorners = []
        referenceMatchProjectedCorners = []
        referenceMatchErrorPixels = nil
        referenceMatchEnabled = false
        // Removing the only external video is an explicit authoring action.
        // Keep the Reference phase valid by selecting its built-in VFX plate.
        referencePlate = .vfxChecker
        applyTimelineAuthority(resetRange: true)
        invalidateNativeResultForSceneContextChange()
        rebuildPhysicalSelectedFrame()
    }

    func setReferenceMatchEnabled(_ enabled: Bool) {
        guard referenceACEScgFrame != nil else { return }
        referenceMatchEnabled = enabled
        applyTimelineAuthority(resetRange: true)
        if enabled {
            physicalModel.setQuality(.setup)
            publishReferenceMatchSetup(
                resetTargetsToVisibleFrame: referenceMatchCorners.count != 4
            )
        } else {
            publishReferenceMatchSetup(resetTargetsToVisibleFrame: false)
        }
    }

    func setTrackingSceneMethod(_ method: TrackingSceneMethod) {
        guard method != trackingSceneMethod else { return }
        trackingSceneMethod = method
        referenceMatchEnabled = method == .deviceCorners && referenceACEScgFrame != nil
        cachedSceneResolver = nil
        applyTimelineAuthority(resetRange: true)
        physicalModel.invalidateExternalParameters(preservingQuality: true)
        publishSetupFraming()
    }

    private func loadReferenceFrame(_ url: URL) async {
        do {
            let managed = try ReferenceAssetLibrary.importAsset(from: url)
            let isVideo = Self.isVideo(managed.url)
            referenceDetection = await StudioMediaMetadataDetector.detect(
                url: managed.url, isVideo: isVideo
            )
            let resolution = StudioMediaImportResolution(
                detection: referenceDetection, isVideo: isVideo
            )
            referenceDetection = resolution.detection
            try adoptReferenceImportInterpretation(referenceDetection)
            acknowledgeImportDefaults(resolution, role: "la referencia")
            referencePlacement = .fit
            referencePlate = .videoReference
            invalidateNativeResultForSceneContextChange()
            let info = isVideo
                ? try await referenceSession.openVideo(
                    managed.url,
                    hasAlpha: referenceDetection.hasAlpha,
                    colorModel: referenceSignalColorModel,
                    matrix: referenceSignalMatrix,
                    decodedRange: referenceSignalRange
                )
                : try referenceSession.openImages([managed.url], frameRate: .fps24)
            referenceForegroundFrame = nil
            referenceForegroundIsDeliveryAligned = false
            referenceSourceURL = managed.url
            referenceInputTransformID = referenceInputTransform.id
            referenceSourceHash = nil
            referenceTimelineInfo = isVideo
                ? NativeVideoTimelineInfo(
                    exactFrameRate: info.exactFrameRate,
                    frameCount: info.frameCount
                )
                : nil
            referenceFrameName = managed.originalFileName
            referenceFrameDetail = info.detail
            referenceMatchCorners = []
            referenceMatchProjectedCorners = []
            referenceMatchErrorPixels = nil
            applyTimelineAuthority(resetRange: true)
            try await rebuildReferenceFrame()
            publishReferenceMatchSetup(resetTargetsToVisibleFrame: true)
            status = "Referencia · \(managed.originalFileName) · \(info.detail) · interpretación explícita conservada"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func changeReferenceInput(
        _ value: StudioColorInputTransform, undoManager: UndoManager?
    ) {
        guard referenceInputTransform != value else { return }
        let prior = referenceInputTransform
        registerUndo(with: undoManager, actionName: "Cambiar interpretación de referencia") { target, manager in
            target.changeReferenceInput(prior, undoManager: manager)
        }
        referenceInputTransform = value
        referenceInputTransformID = value.id
        invalidateNativeResultForSceneContextChange()
        refreshReferenceInterpretation()
    }

    func changeReferenceAlpha(_ value: StudioAlphaMode) {
        guard referenceAlphaMode != value else { return }
        referenceAlphaMode = value
        invalidateNativeResultForSceneContextChange()
        refreshReferenceInterpretation()
    }

    func changeReferenceMatrix(_ value: StudioSignalMatrix) {
        guard referenceSignalMatrix != value else { return }
        referenceSignalMatrix = value
        invalidateNativeResultForSceneContextChange()
        refreshReferenceInterpretation()
    }

    func changeReferenceRange(_ value: StudioSignalRange) {
        guard referenceSignalRange != value else { return }
        referenceSignalRange = value
        invalidateNativeResultForSceneContextChange()
        reconfigureReferenceDecode()
    }

    func changeReferenceColorModel(_ value: StudioSignalColorModel) {
        guard referenceSignalColorModel != value else { return }
        referenceSignalColorModel = value
        invalidateNativeResultForSceneContextChange()
        reconfigureReferenceDecode()
    }

    func changeReferencePlacement(_ value: SourcePlacement) {
        guard referencePlacement != value else { return }
        referencePlacement = value
        invalidateNativeResultForSceneContextChange()
        rebuildPhysicalSelectedFrame()
    }

    func changeReferencePlate(_ value: ReferencePlate) {
        guard value != .videoReference || referenceACEScgFrame != nil else { return }
        guard referencePlate != value else { return }
        referencePlate = value
        syntheticReferencePlateCache = nil
        if value != .videoReference { referenceMatchEnabled = false }
        applyTimelineAuthority(resetRange: true)
        // Reference plate selection changes the final post-physical composition. It is
        // authored scene state, so a completed Native frame can never remain current.
        invalidateNativeResultForSceneContextChange()
        rebuildPhysicalSelectedFrame()
    }

    /// Reference context is authored scene state outside the physical-model control
    /// transaction. A complete Native image contains its post-physical plate, so it
    /// must be invalidated by every change to that context before any async decode.
    private func invalidateNativeResultForSceneContextChange() {
        physicalModel.invalidateExternalParameters()
    }

    private func refreshReferenceInterpretation() {
        Task {
            do { try await rebuildReferenceFrameAndPublish() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func reconfigureReferenceDecode() {
        guard let url = referenceSourceURL else { return }
        Task {
            do {
                if Self.isVideo(url) {
                    _ = try await referenceSession.openVideo(
                        url,
                        hasAlpha: referenceDetection.hasAlpha,
                        colorModel: referenceSignalColorModel,
                        matrix: referenceSignalMatrix,
                        decodedRange: referenceSignalRange
                    )
                }
                try await rebuildReferenceFrameAndPublish()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func clearReferenceMatchTargets() {
        guard referenceACEScgFrame != nil else { return }
        let size = referenceDeliveryRasterSize
        referenceMatchCorners = Self.initialReferenceMatchTargets(
            width: size.width, height: size.height
        )
        referenceMatchErrorPixels = nil
        status = "Match referencia · objetivos reiniciados"
    }

    func beginReferenceCornerDrag(_ index: Int) {
        guard !previewTransformationsLocked,
              referenceMatchEnabled, referenceMatchCorners.indices.contains(index)
        else { return }
        referenceMatchStartSelection = testAuthoringSelection
    }

    func updateReferenceCorner(_ index: Int, to point: CGPoint) {
        guard !previewTransformationsLocked,
              referenceMatchEnabled,
              referenceMatchCorners.indices.contains(index),
              referenceACEScgFrame != nil
        else { return }
        let size = referenceDeliveryRasterSize
        referenceMatchCorners[index] = CGPoint(
            x: min(CGFloat(size.width) - 0.5, max(-0.5, point.x)),
            y: min(CGFloat(size.height) - 0.5, max(-0.5, point.y))
        )
        referenceMatchErrorPixels = nil
        status = "Match referencia · objetivo \(["TL", "TR", "BR", "BL"][index])"
    }

    func endReferenceCornerDrag(undoManager: UndoManager?) {
        guard let prior = referenceMatchStartSelection else { return }
        if referenceMatchCorners.count == 4 {
            solveReferenceMatchTargets(undoManager: undoManager, priorSelection: prior)
        }
        referenceMatchStartSelection = nil
    }

    func beginFocusTargetDrag() {
        guard !previewTransformationsLocked,
              physicalModel.quality == .focusSetup,
              testAuthoringSelection?.autofocusEnabled == true
        else { return }
        focusTargetDragStartSelection = testAuthoringSelection
        focusTargetDragStartOverrideControlIDs = explicitSceneOverrideControlIDs
    }

    func updateFocusTarget(to rasterPoint: CGPoint) {
        guard !previewTransformationsLocked,
              physicalModel.quality == .focusSetup,
              let selection = testAuthoringSelection,
              selection.autofocusEnabled,
              let frame = metalFrame,
              let placement = Self.deliveryPlacementCode(selection.deliveryPlacementID)
        else { return }
        do {
            let scene = try resolveSceneFrame(currentFrame)
            guard let uv = try scene.resolver.unprojectFocusTarget(
                frame: scene.selection,
                pixel: rasterPoint,
                deliveryWidth: Int(selection.deliveryWidth),
                deliveryHeight: Int(selection.deliveryHeight),
                previewWidth: frame.width,
                previewHeight: frame.height,
                deliveryPlacement: placement,
                expectedRevision: scene.revision
            ) else { return }
            let withU = try RustTestAuthoringCoordinator.apply(
                .setScalar(controlID: "autofocus-target-u", value: uv.x),
                to: selection, profileContext: testAuthoringProfileContext
            )
            let resolved = try RustTestAuthoringCoordinator.apply(
                .setScalar(controlID: "autofocus-target-v", value: uv.y),
                to: withU, profileContext: testAuthoringProfileContext
            )
            let focusSetup = try RustTestAuthoringCoordinator.apply(
                .setChoice(controlID: "preview-quality", optionID: "focus-setup"),
                to: resolved, profileContext: testAuthoringProfileContext
            )
            testAuthoringSelection = focusSetup
            physicalModel.invalidateExternalParameters(preservingQuality: true)
            publishFocusSetup()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func endFocusTargetDrag(undoManager: UndoManager?) {
        guard let prior = focusTargetDragStartSelection else { return }
        focusTargetDragStartSelection = nil
        let priorOverrides = focusTargetDragStartOverrideControlIDs
            ?? explicitSceneOverrideControlIDs
        focusTargetDragStartOverrideControlIDs = nil
        guard prior != testAuthoringSelection else { return }
        if let current = testAuthoringSelection {
            do {
                try commitSceneAuthoringEdit(
                    selection: current,
                    setting: ["autofocus-target-u", "autofocus-target-v"],
                    prior: .init(
                        selection: prior,
                        explicitOverrideControlIDs: priorOverrides
                    ),
                    undoManager: undoManager,
                    actionName: "Cambiar punto de autofocus"
                )
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    func solveReferenceMatchTargets(undoManager: UndoManager?) {
        guard let prior = testAuthoringSelection else { return }
        solveReferenceMatchTargets(undoManager: undoManager, priorSelection: prior)
    }

    func searchReferenceMatchFocalLength(undoManager: UndoManager?) {
        guard referenceMatchCorners.count == 4,
              let prior = testAuthoringSelection
        else {
            status = "Match referencia · se necesitan cuatro objetivos para buscar focal"
            return
        }
        do {
            // Search uniformly in log focal length so wide and telephoto ranges receive
            // comparable resolution. Then refine only the best neighboring interval.
            guard let focalControl = testPresentation?.phases
                .flatMap(\.sections)
                .flatMap(\.controls)
                .compactMap({ descriptor -> TestScalarControl? in
                    guard case let .scalar(control) = descriptor,
                          control.id == "focal-length-millimeters"
                    else { return nil }
                    return control
                })
                .first
            else {
                throw ReferenceMatchError.unsolved("no existe un intervalo focal resuelto")
            }
            let lower = log(focalControl.minimum)
            let upper = log(focalControl.maximum)
            let coarseCount = 72
            var candidates: [(logFocal: Double, solved: (pose: CameraNavigationPose, maximumErrorPixels: Double, rmsErrorPixels: Double))] = []
            for index in 0..<coarseCount {
                let amount = Double(index) / Double(coarseCount - 1)
                let logFocal = lower + (upper - lower) * amount
                if let solved = try? resolvedFourPointReferencePose(
                    focalLengthMillimeters: exp(logFocal)
                ) {
                    candidates.append((logFocal, solved))
                }
            }
            guard let coarseBestIndex = candidates.indices.min(by: {
                candidates[$0].solved.rmsErrorPixels < candidates[$1].solved.rmsErrorPixels
            }) else {
                throw ReferenceMatchError.unsolved("ninguna focal produce una pose válida")
            }
            var left = coarseBestIndex > candidates.startIndex
                ? candidates[coarseBestIndex - 1].logFocal : lower
            var right = coarseBestIndex + 1 < candidates.endIndex
                ? candidates[coarseBestIndex + 1].logFocal : upper
            let golden = (sqrt(5.0) - 1.0) * 0.5
            var x1 = right - golden * (right - left)
            var x2 = left + golden * (right - left)
            var s1 = try resolvedFourPointReferencePose(focalLengthMillimeters: exp(x1))
            var s2 = try resolvedFourPointReferencePose(focalLengthMillimeters: exp(x2))
            for _ in 0..<28 {
                if s1.rmsErrorPixels <= s2.rmsErrorPixels {
                    right = x2
                    x2 = x1
                    s2 = s1
                    x1 = right - golden * (right - left)
                    s1 = try resolvedFourPointReferencePose(focalLengthMillimeters: exp(x1))
                } else {
                    left = x1
                    x1 = x2
                    s1 = s2
                    x2 = left + golden * (right - left)
                    s2 = try resolvedFourPointReferencePose(focalLengthMillimeters: exp(x2))
                }
            }
            let refined = s1.rmsErrorPixels <= s2.rmsErrorPixels ? (x1, s1) : (x2, s2)
            let coarse = candidates[coarseBestIndex]
            let best = refined.1.rmsErrorPixels <= coarse.solved.rmsErrorPixels
                ? (exp(refined.0), refined.1) : (exp(coarse.logFocal), coarse.solved)
            try commitReferenceMatch(
                focalLengthMillimeters: best.0,
                solved: best.1,
                priorSelection: prior,
                undoManager: undoManager,
                actionName: "Buscar focal con referencia"
            )
            status = "Match referencia · focal \(best.0.formatted(.number.precision(.fractionLength(2)))) mm · RMS \(best.1.rmsErrorPixels.formatted(.number.precision(.fractionLength(2)))) px · máximo \(best.1.maximumErrorPixels.formatted(.number.precision(.fractionLength(2)))) px"
        } catch {
            referenceMatchErrorPixels = nil
            status = error.localizedDescription
        }
    }

    func load(
        _ urls: [URL],
        materializeImportInterpretation: Bool = true
    ) async {
        pause()
        status = "Leyendo medio y metadata…"
        let expanded: [URL]
        if urls.count == 1, urls[0].hasDirectoryPath {
            expanded = (try? FileManager.default.contentsOfDirectory(
                at: urls[0], includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ).filter(Self.isImage)) ?? []
        } else {
            expanded = urls
        }
        guard let first = expanded.first else {
            errorMessage = "La selección no contiene imágenes o películas compatibles."
            return
        }
        let isVideo = Self.isVideo(first) && expanded.count == 1
        detection = await StudioMediaMetadataDetector.detect(url: first, isVideo: isVideo)
        do {
            if materializeImportInterpretation {
                let resolution = StudioMediaImportResolution(
                    detection: detection, isVideo: isVideo
                )
                detection = resolution.detection
                try adoptSourceImportInterpretation(detection)
                acknowledgeImportDefaults(resolution, role: "la fuente")
            }
            let info = isVideo
                ? try await session.openVideo(
                    first,
                    hasAlpha: detection.hasAlpha,
                    colorModel: signalColorModel,
                    matrix: signalMatrix,
                    decodedRange: signalRange
                )
                : try session.openImages(
                    expanded.filter(Self.isImage),
                    frameRate: sourceTimelineInfo.exactFrameRate
                )
            sourceIsPattern = false
            sourceName = info.name
            sourceDetail = info.detail + (detection.note.map { " · Metadata: \($0)" } ?? "")
            sourceTimelineInfo = NativeVideoTimelineInfo(
                exactFrameRate: info.exactFrameRate,
                frameCount: info.frameCount
            )
            applyTimelineAuthority(resetRange: true)
            includeAudio = info.hasAudio
            session.play()
            try await Task.sleep(for: .milliseconds(20))
            session.pause()
            try present(try await session.exactSample(at: .zero))
            status = "Medio abierto con la interpretación explícita activa; las etiquetas de metadata son solo propuestas."
        } catch {
            errorMessage = error.localizedDescription
            status = "No se pudo abrir el medio"
        }
    }

    func changeInput(_ value: StudioColorInputTransform, undoManager: UndoManager?) {
        let prior = inputTransform
        registerUndo(with: undoManager, actionName: "Cambiar interpretación de fuente") { target, manager in
            target.changeInput(prior, undoManager: manager)
        }
        inputTransform = value
        rebuildCurrent()
    }

    func changeAlpha(_ value: StudioAlphaMode, undoManager: UndoManager?) {
        let prior = alphaMode
        registerUndo(with: undoManager, actionName: "Cambiar alpha") { target, manager in
            target.changeAlpha(prior, undoManager: manager)
        }
        alphaMode = value
        rebuildCurrent()
    }

    func changeMatrix(_ value: StudioSignalMatrix) {
        signalMatrix = value
        rebuildCurrent()
    }

    func changeRange(_ value: StudioSignalRange) {
        signalRange = value
        reconfigureSourceDecode()
    }

    func changeColorModel(_ value: StudioSignalColorModel) {
        signalColorModel = value
        reconfigureSourceDecode()
    }

    private func reconfigureSourceDecode() {
        guard !sourceIsPattern else {
            rebuildCurrent()
            return
        }
        let urls = session.sourceURLs
        guard let first = urls.first else { return }
        let requestedRate = sourceTimelineInfo.exactFrameRate
        let requestedTime = CMTime(
            value: CMTimeValue(currentFrame) * CMTimeValue(requestedRate.denominator),
            timescale: CMTimeScale(requestedRate.numerator)
        )
        Task {
            do {
                let info = if Self.isVideo(first), urls.count == 1 {
                    try await session.openVideo(
                        first,
                        hasAlpha: detection.hasAlpha,
                        colorModel: signalColorModel,
                        matrix: signalMatrix,
                        decodedRange: signalRange
                    )
                } else {
                    try session.openImages(urls, frameRate: requestedRate)
                }
                sourceTimelineInfo = .init(
                    exactFrameRate: info.exactFrameRate,
                    frameCount: info.frameCount
                )
                try present(try await session.exactSample(at: requestedTime))
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func changePreview(_ value: StudioColorOutputTransform, undoManager: UndoManager?) {
        do {
            try metalDisplay.prepare(value)
        } catch {
            errorMessage = "No se puede activar \(value.label): \(error.localizedDescription)"
            return
        }
        let prior = previewTransform
        registerUndo(with: undoManager, actionName: "Cambiar vista") { target, manager in
            target.changePreview(prior, undoManager: manager)
        }
        previewTransform = value
        objectWillChange.send()
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard frameCount > 1 else { return }
        if !activeFrameRange.contains(currentFrame) || currentFrame >= activeFrameRange.upperBound {
            restartPlayback(at: activeFrameRange.lowerBound)
            return
        }
        if referenceControlsTimeline {
            referencePlaybackStartFrame = currentFrame
            referencePlaybackStartedAt = CACurrentMediaTime()
            session.pause()
            isPlaying = true
            return
        }
        isPlaying = true
        if sourceIsPattern { return }
        session.play()
    }

    func pause() {
        isPlaying = false
        referencePlaybackStartedAt = nil
        session.pause()
    }

    func seek(toFrame frame: Int) {
        pause()
        currentFrame = min(max(0, frame), max(0, frameCount - 1))
        if sourceIsPattern {
            renderPattern()
            refreshReferenceFrameForCurrentTime()
        } else {
            Task {
                do {
                    let time = CMTime(
                        seconds: requestedSeconds, preferredTimescale: 60_000
                    )
                    try await session.seek(to: time)
                    try present(try await session.exactSample(at: time))
                    refreshReferenceFrameForCurrentTime()
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    var trackingOverlayPoints: [CGPoint] {
        guard trackingSceneMethod == .fusionComposition,
              trackingPointsVisible, let group = selectedTrackingPointGroup else { return [] }
        return resolveTrackingOverlay(group.points.map(\.sourcePosition)).compactMap(\.self)
    }

    var trackingOverlayPointIDs: [String] {
        guard trackingSceneMethod == .fusionComposition,
              trackingPointsVisible, let group = selectedTrackingPointGroup else { return [] }
        let projected = resolveTrackingOverlay(group.points.map(\.sourcePosition))
        return zip(group.points, projected).compactMap { point, projection in
            projection == nil ? nil : point.id
        }
    }

    var trackingOverlaySegments: [CGPoint] {
        guard trackingSceneMethod == .fusionComposition,
              trackingGeometryVisible, let scene = trackingScene else { return [] }
        let sources = scene.meshes.filter { visibleTrackingMeshIDs.contains($0.id) }.flatMap { mesh in
            var cursor = 0
            return mesh.faceVertexCounts.flatMap { count -> [SIMD3<Double>] in
                defer { cursor += count }
                guard count >= 2, cursor + count <= mesh.faceVertexIndices.count else { return [] }
                let ids = Array(mesh.faceVertexIndices[cursor..<(cursor + count)])
                guard ids.allSatisfy({ mesh.sourceVertices.indices.contains($0) }) else { return [] }
                return ids.indices.flatMap {
                    [mesh.sourceVertices[ids[$0]], mesh.sourceVertices[ids[($0 + 1) % ids.count]]]
                }
            }
        }
        let projected = resolveTrackingOverlay(sources)
        return stride(from: 0, to: projected.count, by: 2).flatMap { index -> [CGPoint] in
            guard index + 1 < projected.count,
                  let first = projected[index], let second = projected[index + 1]
            else { return [] }
            return [first, second]
        }
    }

    var trackingOverlayMeshCenters: [CGPoint] {
        resolveTrackingOverlay(visibleTrackingPlanePlacements.map(\.placement.center)).compactMap(\.self)
    }

    var trackingOverlayMeshCenterIDs: [String] {
        let placements = visibleTrackingPlanePlacements
        let projected = resolveTrackingOverlay(placements.map(\.placement.center))
        return zip(placements, projected).compactMap { item, projection in
            projection == nil ? nil : item.mesh.id
        }
    }

    var trackingOverlayMeshCenterLabels: [String] {
        let placements = visibleTrackingPlanePlacements
        let projected = resolveTrackingOverlay(placements.map(\.placement.center))
        return zip(placements, projected).compactMap { item, projection in
            projection == nil ? nil : item.mesh.label
        }
    }

    private var visibleTrackingPlanePlacements: [(mesh: TrackingMesh, placement: TrackingPlanePlacement)] {
        guard trackingSceneMethod == .fusionComposition,
              trackingGeometryVisible, let scene = trackingScene else { return [] }
        let viewer = trackingSourceCameraPosition
        return scene.meshes.compactMap { mesh in
            guard visibleTrackingMeshIDs.contains(mesh.id),
                  let placement = mesh.planePlacement(toward: viewer)
            else { return nil }
            return (mesh, placement)
        }
    }

    private var trackingSourceCameraPosition: SIMD3<Double> {
        guard let scale = trackingMetersPerSourceUnit, scale > 0,
              let resolved = publishedResolvedSceneFrame,
              publishedSceneIdentity == PublishedSceneIdentity(resolved)
        else { return .zero }
        return SIMD3(
            resolved.authored.cameraPose.position[0] / scale,
            resolved.authored.cameraPose.position[1] / scale,
            resolved.authored.cameraPose.position[2] / scale
        )
    }

    func placeDeviceAtTrackingPoint(_ id: String, undoManager: UndoManager?) {
        guard !previewTransformationsLocked else { return }
        guard let scale = trackingMetersPerSourceUnit,
              let point = selectedTrackingPointGroup?.points.first(where: { $0.id == id })
        else {
            errorMessage = "Selecciona una nube de puntos y resuelve su escala antes de colocar el Device."
            return
        }
        placeDevice(
            at: point.sourcePosition * scale,
            orientation: nil,
            undoManager: undoManager,
            actionName: "Colocar Device en punto"
        )
    }

    func placeDeviceOnTrackingPlane(_ id: String, undoManager: UndoManager?) {
        guard !previewTransformationsLocked else { return }
        guard let scale = trackingMetersPerSourceUnit,
              let mesh = trackingScene?.meshes.first(where: { $0.id == id }),
              let placement = mesh.planePlacement(toward: trackingSourceCameraPosition)
        else {
            errorMessage = "La geometría seleccionada no define un plano válido o falta resolver la escala."
            return
        }
        placeDevice(
            at: placement.center * scale,
            orientation: placement.orientation,
            undoManager: undoManager,
            actionName: "Alinear Device con plano"
        )
    }

    private func placeDevice(
        at position: SIMD3<Double>,
        orientation: simd_quatd?,
        undoManager: UndoManager?,
        actionName: String
    ) {
        guard var selection = testAuthoringSelection else { return }
        let prior = SceneAuthoringEditSnapshot(
            selection: selection,
            explicitOverrideControlIDs: explicitSceneOverrideControlIDs
        )
        selection.geometryModeID = "free"
        selection.previewQualityID = "setup"
        selection.screenPositionXMeters = position.x
        selection.screenPositionYMeters = position.y
        selection.screenPositionZMeters = position.z
        if let orientation {
            let degrees = PoseRotationProjection.degrees(from: [
                orientation.imag.x, orientation.imag.y,
                orientation.imag.z, orientation.real,
            ])
            selection.screenRotationXDegrees = degrees[0]
            selection.screenYawDegrees = degrees[1]
            selection.screenRotationZDegrees = degrees[2]
        }
        do {
            var controls: Set<String> = [
                "geometry-mode",
                "screen-position-x-meters", "screen-position-y-meters",
                "screen-position-z-meters",
            ]
            if orientation != nil {
                controls.formUnion([
                    "screen-rotation-x-degrees", "screen-yaw-degrees",
                    "screen-rotation-z-degrees",
                ])
            }
            try commitSceneAuthoringEdit(
                selection: selection,
                setting: controls,
                prior: prior,
                undoManager: undoManager,
                actionName: actionName
            )
            applyTrackingCameraAtCurrentFrame()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importFusionTrackingScene() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "comp")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        FileDialogDirectory.trackingComposition.apply(to: panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileDialogDirectory.trackingComposition.remember(url)
        do {
            let imported = try FusionTrackingImporter().load(url)
            setTrackingSceneMethod(.fusionComposition)
            trackingScene = imported
            selectedTrackingCameraID = nil
            selectedTrackingPointGroupID = nil
            visibleTrackingMeshIDs = Set(imported.meshes.map(\.id))
            trackingScalePointAID = nil
            trackingScalePointBID = nil
            trackingMeasuredDistanceMeters = 1
            trackingMetersPerSourceUnit = nil
            trackingScaleSelectionSlot = nil
            trackingSynthEyesUnitValue = 1
            trackingSynthEyesUnit = "m"
            trackingMetersPerSourceUnit = 1
            cachedSceneResolver = nil
            applyTimelineAuthority(resetRange: true)
            physicalModel.invalidateExternalParameters(preservingQuality: true)
            publishSetupFraming()
            status = "Tracking importado · 1 unidad SynthEyes = 1 m"
        } catch { errorMessage = error.localizedDescription }
    }

    func importFusionTrackerFromClipboard() {
        guard referenceACEScgFrame != nil, referenceTimelineInfo != nil else {
            errorMessage = "Carga una referencia de vídeo antes de pegar el Tracker de Fusion."
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            errorMessage = "El portapapeles no contiene texto de un nodo Tracker de Fusion."
            return
        }
        do {
            let tracker = try FusionTrackerClipboardImporter().parse(text)
            fusionTrackerClipboard = tracker
            fusionTrackerAnchorFrame = currentFrame
            fusionTrackerCornerAssignments = Dictionary(
                uniqueKeysWithValues: tracker.points.map { ($0.id, .unassigned) }
            )
            status = "Tracker Fusion · \(tracker.points.count) puntos · frames \(tracker.frameRange.lowerBound)–\(tracker.frameRange.upperBound) · origen \(currentFrame)"
        } catch {
            fusionTrackerClipboard = nil
            fusionTrackerAnchorFrame = nil
            fusionTrackerCornerAssignments = [:]
            errorMessage = error.localizedDescription
        }
    }

    func setFusionTrackerCorner(_ corner: FusionTrackerCorner, for pointID: String) {
        guard fusionTrackerClipboard?.points.contains(where: { $0.id == pointID }) == true else { return }
        if corner != .unassigned,
           let prior = fusionTrackerCornerAssignments.first(where: {
               $0.key != pointID && $0.value == corner
           })?.key {
            fusionTrackerCornerAssignments[prior] = .unassigned
        }
        fusionTrackerCornerAssignments[pointID] = corner
    }

    func applyFusionTrackerMotion(undoManager: UndoManager?) {
        guard let tracker = fusionTrackerClipboard else { return }
        do {
            let prepared = fusionTrackerSmoothingEnabled
                ? try tracker.smoothed(
                    window: fusionTrackerSmoothingWindow,
                    degree: fusionTrackerSmoothingDegree
                )
                : tracker
            guard fusionTrackerMovesX || fusionTrackerMovesY || fusionTrackerScales
                    || fusionTrackerRotates || fusionTrackerUsesCornerPin
            else {
                throw FusionTrackerClipboardError.invalid("selecciona al menos un componente de movimiento")
            }
            if fusionTrackerUsesCornerPin {
                let assigned = Set(fusionTrackerCornerAssignments.values.filter { $0 != .unassigned })
                guard prepared.points.count >= 4,
                      assigned == Set([
                          FusionTrackerCorner.topLeft, .topRight, .bottomRight, .bottomLeft,
                      ])
                else {
                    throw FusionTrackerClipboardError.invalid(
                        "Corner Pin requiere una asignación única TL, TR, BR y BL"
                    )
                }
            }
            guard let reference = referenceACEScgFrame,
                  let referenceTimelineInfo,
                  let anchorFrame = fusionTrackerAnchorFrame,
                  tracker.frameRange.contains(anchorFrame),
                  testAuthoringSelection != nil
            else {
                throw FusionTrackerClipboardError.invalid(
                    "el frame de origen debe existir en el Tracker y la referencia debe tener cadencia explícita"
                )
            }
            let motionPoints: [FusionTrackerPointCurve]
            if fusionTrackerUsesCornerPin {
                let order: [FusionTrackerCorner] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
                motionPoints = try order.map { corner in
                    guard let id = fusionTrackerCornerAssignments.first(where: { $0.value == corner })?.key,
                          let point = prepared.points.first(where: { $0.id == id })
                    else { throw FusionTrackerClipboardError.invalid("falta la esquina \(corner.label)") }
                    return point
                }
            } else {
                motionPoints = prepared.points
            }
            if fusionTrackerScales || fusionTrackerRotates {
                guard motionPoints.count >= 2 else {
                    throw FusionTrackerClipboardError.invalid(
                        "escala y rotación requieren al menos dos puntos"
                    )
                }
            }
            let delivery = referenceDeliveryRasterSize
            let anchorTrackerPoints = try motionPoints.map {
                try fusionTrackerDeliveryPoint(
                    curve: $0, frame: anchorFrame,
                    sourceWidth: reference.width, sourceHeight: reference.height,
                    deliveryWidth: delivery.width, deliveryHeight: delivery.height
                )
            }
            let priorMotion = fusionTrackerMotion
            fusionTrackerMotion = nil
            cachedSceneResolver = nil
            var materialized: [FusionTrackerPoseSample] = []
            do {
                for frame in prepared.frameRange {
                    let base = try fusionTrackerBaseProjection(frame: frame)
                    let currentTrackerPoints = try motionPoints.map {
                        try fusionTrackerDeliveryPoint(
                            curve: $0, frame: frame,
                            sourceWidth: reference.width, sourceHeight: reference.height,
                            deliveryWidth: delivery.width, deliveryHeight: delivery.height
                        )
                    }
                    let targets = try FusionTrackerMotionMath.transformedCorners(
                        base: base.deliveryCorners,
                        anchorPoints: anchorTrackerPoints,
                        currentPoints: currentTrackerPoints,
                        components: .init(
                            x: fusionTrackerMovesX, y: fusionTrackerMovesY,
                            scale: fusionTrackerScales, rotation: fusionTrackerRotates,
                            cornerPin: fusionTrackerUsesCornerPin
                        )
                    )
                    let solved = try resolvedRigidCameraPose(
                        deliveryTargets: targets,
                        focalLengthMillimeters: base.focalLengthMillimeters,
                        frame: frame
                    ).pose
                    let pose = fusionTrackerTarget == .camera
                        ? solved
                        : CameraNavigationMath.equivalentDevicePose(
                            startCamera: base.cameraPose,
                            movedCamera: solved,
                            startDevice: base.devicePose
                        )
                    materialized.append(FusionTrackerPoseSample(
                        frame: frame,
                        position: pose.position,
                        orientation: SIMD4(
                            pose.orientation.imag.x, pose.orientation.imag.y,
                            pose.orientation.imag.z, pose.orientation.real
                        )
                    ))
                }
                let rate = referenceTimelineInfo.exactFrameRate
                fusionTrackerMotion = try FusionTrackerPoseTrack(
                    target: fusionTrackerTarget,
                    anchorFrame: anchorFrame,
                    frameRateNumerator: rate.numerator,
                    frameRateDenominator: rate.denominator,
                    samples: materialized
                )
            } catch {
                fusionTrackerMotion = priorMotion
                cachedSceneResolver = nil
                throw error
            }
            cachedSceneResolver = nil
            physicalModel.invalidateExternalParameters(preservingQuality: true)
            publishSetupFraming()
            if priorMotion != fusionTrackerMotion {
                registerUndo(with: undoManager, actionName: "Aplicar Tracker Fusion") { target, manager in
                    target.restoreFusionTrackerMotion(priorMotion, undoManager: manager)
                }
            }
            status = "Tracker Fusion aplicado a \(fusionTrackerTarget.label) · \(materialized.count) frames"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreFusionTrackerMotion(
        _ motion: FusionTrackerPoseTrack?, undoManager: UndoManager?
    ) {
        let current = fusionTrackerMotion
        fusionTrackerMotion = motion
        cachedSceneResolver = nil
        physicalModel.invalidateExternalParameters(preservingQuality: true)
        publishSetupFraming()
        registerUndo(with: undoManager, actionName: "Aplicar Tracker Fusion") { target, manager in
            target.restoreFusionTrackerMotion(current, undoManager: manager)
        }
    }

    private func fusionTrackerDeliveryPoint(
        curve: FusionTrackerPointCurve,
        frame: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        deliveryWidth: Int,
        deliveryHeight: Int
    ) throws -> CGPoint {
        guard let sample = curve.samples.first(where: { $0.frame == frame }),
              sourceWidth > 0, sourceHeight > 0, deliveryWidth > 0, deliveryHeight > 0
        else { throw FusionTrackerClipboardError.invalid("falta el frame \(frame) en \(curve.label)") }
        let scaleX: Double
        let scaleY: Double
        switch referencePlacement {
        case .fit:
            let scale = min(Double(deliveryWidth) / Double(sourceWidth), Double(deliveryHeight) / Double(sourceHeight))
            scaleX = scale; scaleY = scale
        case .fillCrop:
            let scale = max(Double(deliveryWidth) / Double(sourceWidth), Double(deliveryHeight) / Double(sourceHeight))
            scaleX = scale; scaleY = scale
        case .stretch:
            scaleX = Double(deliveryWidth) / Double(sourceWidth)
            scaleY = Double(deliveryHeight) / Double(sourceHeight)
        case .oneToOne:
            scaleX = 1; scaleY = 1
        }
        let offsetX = (Double(deliveryWidth) - Double(sourceWidth) * scaleX) * 0.5
        let offsetY = (Double(deliveryHeight) - Double(sourceHeight) * scaleY) * 0.5
        // Fusion uses a normalized, bottom-up composition coordinate system.
        return CGPoint(
            x: sample.position.x * Double(sourceWidth) * scaleX + offsetX - 0.5,
            y: (1 - sample.position.y) * Double(sourceHeight) * scaleY + offsetY - 0.5
        )
    }

    private func fusionTrackerBaseProjection(frame: Int) throws -> (
        deliveryCorners: [CGPoint], cameraPose: CameraNavigationPose,
        devicePose: CameraNavigationPose, focalLengthMillimeters: Double
    ) {
        let scene = try resolveSceneFrame(frame)
        let delivery = referenceDeliveryRasterSize
        let placementID = testAuthoringSelection?.deliveryPlacementID ?? "fit"
        let plan = try setupDiagnosticPlan(
            scene: scene,
            deliveryWidth: delivery.width, deliveryHeight: delivery.height,
            previewWidth: delivery.width, previewHeight: delivery.height,
            deliveryPlacementID: placementID, deliveryBackgroundID: "black"
        )
        let cameraPose = CameraNavigationPose(
            position: SIMD3(
                Double(plan.camera_position.0), Double(plan.camera_position.1),
                Double(plan.camera_position.2)
            ),
            orientation: simd_quatd(
                ix: Double(plan.camera_rotation_xyzw.0), iy: Double(plan.camera_rotation_xyzw.1),
                iz: Double(plan.camera_rotation_xyzw.2), r: Double(plan.camera_rotation_xyzw.3)
            ).normalized
        )
        let devicePose = CameraNavigationPose(
            position: SIMD3(
                Double(plan.screen_position.0), Double(plan.screen_position.1),
                Double(plan.screen_position.2)
            ),
            orientation: simd_quatd(
                ix: Double(plan.screen_rotation_xyzw.0), iy: Double(plan.screen_rotation_xyzw.1),
                iz: Double(plan.screen_rotation_xyzw.2), r: Double(plan.screen_rotation_xyzw.3)
            ).normalized
        )
        let geometry = CameraNavigationGeometry(
            center: devicePose.position,
            right: devicePose.orientation.act(SIMD3(1, 0, 0)),
            up: devicePose.orientation.act(SIMD3(0, 1, 0)),
            halfWidth: Double(plan.device_active_width_meters) * 0.5,
            halfHeight: Double(plan.device_active_height_meters) * 0.5
        )
        let gateSize = CGSize(width: Int(plan.active_sensor_width), height: Int(plan.active_sensor_height))
        let gateCorners = try geometry.corners.map { corner in
            guard let point = ReferenceAnchorCameraMath.project(
                pose: cameraPose, point: corner, imageSize: gateSize,
                focalLengthMillimeters: Double(plan.focal_length_millimeters),
                sensorSizeMillimeters: CGSize(
                    width: Double(plan.sensor_width_millimeters),
                    height: Double(plan.sensor_height_millimeters)
                ),
                lensShift: SIMD2(Double(plan.lens_shift.0), Double(plan.lens_shift.1)),
                radialDistortion: SIMD3(
                    Double(plan.lens_radial_distortion.0), Double(plan.lens_radial_distortion.1),
                    Double(plan.lens_radial_distortion.2)
                ),
                tangentialDistortion: SIMD2(
                    Double(plan.lens_tangential_distortion.0),
                    Double(plan.lens_tangential_distortion.1)
                )
            ) else { throw FusionTrackerClipboardError.invalid("el Device sale del dominio de cámara") }
            return point
        }
        let deliveryCorners = try ReferenceMatchRasterMapping.referenceCorners(
            gateCorners,
            referenceWidth: delivery.width, referenceHeight: delivery.height,
            cameraWidth: plan.active_sensor_width, cameraHeight: plan.active_sensor_height,
            deliveryPlacementID: placementID
        )
        return (
            deliveryCorners, cameraPose, devicePose,
            Double(plan.focal_length_millimeters)
        )
    }

    func setTrackingMesh(_ id: String, visible: Bool) {
        if visible { visibleTrackingMeshIDs.insert(id) }
        else { visibleTrackingMeshIDs.remove(id) }
    }

    func refreshTrackingCamera() {
        applyTimelineAuthority(resetRange: true)
        applyTrackingCameraAtCurrentFrame()
    }

    func beginTrackingScalePointSelection(slot: Int) {
        guard slot == 0 || slot == 1 else { return }
        trackingScaleSelectionSlot = slot
        status = "Selecciona el punto \(slot == 0 ? "A" : "B") en el Viewer"
    }

    func selectTrackingPoint(id: String) {
        guard let slot = trackingScaleSelectionSlot else { return }
        if slot == 0 { trackingScalePointAID = id }
        else { trackingScalePointBID = id }
        trackingScaleSelectionSlot = nil
    }

    func clearTrackingScaleCalibration() {
        trackingScalePointAID = nil
        trackingScalePointBID = nil
        trackingMeasuredDistanceMeters = 1
        trackingMetersPerSourceUnit = nil
        trackingScaleSelectionSlot = nil
    }

    func applyTrackingUnitScale() {
        guard trackingSynthEyesUnitValue.isFinite, trackingSynthEyesUnitValue > 0 else {
            errorMessage = "La escala de SynthEyes debe ser positiva."
            return
        }
        let scale = trackingSynthEyesUnit == "cm"
            ? trackingSynthEyesUnitValue / 100 : trackingSynthEyesUnitValue
        do {
            try applyTrackingMetersPerSourceUnit(scale)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Changes the unit conversion for the complete imported world. Camera, point cloud,
    /// geometry and an already placed Device keep the same source-space coordinates; the
    /// physical Device dimensions remain metres and therefore change only in apparent size.
    private func applyTrackingMetersPerSourceUnit(_ scale: Double) throws {
        guard scale.isFinite, scale > 0 else { throw PhysicalContractError.invalidFrameTime }
        let priorScale = trackingMetersPerSourceUnit
        let priorSelection = testAuthoringSelection
        var scaledSelection = priorSelection
        if let priorScale, priorScale > 0, var selection = scaledSelection {
            let factor = scale / priorScale
            selection.screenPositionXMeters *= factor
            selection.screenPositionYMeters *= factor
            selection.screenPositionZMeters *= factor
            scaledSelection = selection
        }
        trackingMetersPerSourceUnit = scale
        do {
            if let scaledSelection {
                try commitSceneAuthoringEdit(
                    selection: scaledSelection,
                    setting: [
                        "screen-position-x-meters", "screen-position-y-meters",
                        "screen-position-z-meters",
                    ],
                    undoManager: nil,
                    actionName: "Escalar mundo tracking"
                )
            } else {
                applyTrackingCameraAtCurrentFrame()
            }
        } catch {
            trackingMetersPerSourceUnit = priorScale
            throw error
        }
    }

    func trackingMeshDimensions(_ mesh: TrackingMesh) -> SIMD3<Double>? {
        guard let scale = trackingMetersPerSourceUnit, !mesh.sourceVertices.isEmpty else { return nil }
        let minimum = mesh.sourceVertices.reduce(SIMD3(repeating: Double.infinity), simd_min)
        let maximum = mesh.sourceVertices.reduce(SIMD3(repeating: -Double.infinity), simd_max)
        return (maximum - minimum) * scale
    }

    func resolveTrackingScale() {
        guard let group = selectedTrackingPointGroup,
              let firstID = trackingScalePointAID, let secondID = trackingScalePointBID,
              let first = group.points.first(where: { $0.id == firstID }),
              let second = group.points.first(where: { $0.id == secondID }) else {
            errorMessage = "Selecciona dos puntos diferentes de la nube activa."
            return
        }
        var request = ScreenTrackingScaleCalibrationV1(
            abi_version: SCREEN_TRACKING_SCALE_ABI_VERSION,
            first_point_xyz: (Float(first.sourcePosition.x), Float(first.sourcePosition.y), Float(first.sourcePosition.z)),
            second_point_xyz: (Float(second.sourcePosition.x), Float(second.sourcePosition.y), Float(second.sourcePosition.z)),
            measured_distance_meters: Float(trackingMeasuredDistanceMeters)
        )
        var resolved: Float = 0
        var errorPointer: UnsafePointer<CChar>?
        guard screen_geometry_resolve_tracking_scale_v1(&request, &resolved, &errorPointer), resolved.isFinite, resolved > 0 else {
            errorMessage = errorPointer.map { String(cString: $0) }
                ?? "La escala no es válida: los puntos deben ser distintos y la distancia real positiva."
            return
        }
        do {
            try applyTrackingMetersPerSourceUnit(Double(resolved))
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        status = "Escala resuelta · 1 unidad Fusion = \(Double(resolved).formatted(.number.precision(.fractionLength(6)))) m"
    }

    private var selectedTrackingPointGroup: TrackingPointGroup? {
        guard let id = selectedTrackingPointGroupID else { return nil }
        return trackingScene?.pointGroups.first { $0.id == id }
    }

    private var selectedTrackingCamera: TrackingCamera? {
        guard let id = selectedTrackingCameraID else { return nil }
        return trackingScene?.cameras.first { $0.id == id }
    }

    var canFreezeTrackingCameraAnimation: Bool {
        trackingCameraEnabled
            && trackingMetersPerSourceUnit != nil
            && (selectedTrackingCamera?.samples.count ?? 0) > 1
    }

    private struct TrackingAuthoringState {
        let scene: TrackingScene?
        let cameraID: String?
        let pointGroupID: String?
        let cameraEnabled: Bool
        let pointsVisible: Bool
        let geometryVisible: Bool
        let visibleMeshIDs: Set<String>
        let scalePointAID: String?
        let scalePointBID: String?
        let measuredDistanceMeters: Double
        let metersPerSourceUnit: Double?
        let scaleSelectionSlot: Int?
        let unitValue: Double
        let unit: String
        let currentFrame: Int
        let inFrame: Int
        let outFrame: Int
    }

    private var trackingAuthoringState: TrackingAuthoringState {
        TrackingAuthoringState(
            scene: trackingScene,
            cameraID: selectedTrackingCameraID,
            pointGroupID: selectedTrackingPointGroupID,
            cameraEnabled: trackingCameraEnabled,
            pointsVisible: trackingPointsVisible,
            geometryVisible: trackingGeometryVisible,
            visibleMeshIDs: visibleTrackingMeshIDs,
            scalePointAID: trackingScalePointAID,
            scalePointBID: trackingScalePointBID,
            measuredDistanceMeters: trackingMeasuredDistanceMeters,
            metersPerSourceUnit: trackingMetersPerSourceUnit,
            scaleSelectionSlot: trackingScaleSelectionSlot,
            unitValue: trackingSynthEyesUnitValue,
            unit: trackingSynthEyesUnit,
            currentFrame: currentFrame,
            inFrame: inFrame,
            outFrame: outFrame
        )
    }

    func freezeTrackingCameraAnimation(undoManager: UndoManager?) {
        guard canFreezeTrackingCameraAnimation,
              let scene = trackingScene,
              let cameraID = selectedTrackingCameraID,
              let scale = trackingMetersPerSourceUnit,
              scale.isFinite, scale > 0
        else {
            errorMessage = "Activa una cámara tracking animada y resuelve su escala antes de congelarla."
            return
        }
        do {
            let prior = trackingAuthoringState
            let resolved = try resolveSceneFrame(currentFrame).authored
            let sourcePosition = SIMD3(
                resolved.cameraPose.position[0] / scale,
                resolved.cameraPose.position[1] / scale,
                resolved.cameraPose.position[2] / scale
            )
            let orientation = simd_normalize(SIMD4(
                resolved.cameraPose.quaternion[0], resolved.cameraPose.quaternion[1],
                resolved.cameraPose.quaternion[2], resolved.cameraPose.quaternion[3]
            ))
            trackingScene = try scene.freezingCamera(
                id: cameraID,
                sourcePosition: sourcePosition,
                orientation: orientation
            )
            applyTimelineAuthority(resetRange: true)
            physicalModel.invalidateExternalParameters()
            registerTrackingAuthoringUndo(
                prior,
                undoManager: undoManager,
                actionName: "Eliminar animación de cámara"
            )
            status = "Cámara congelada en el frame actual · animación eliminada"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeImportedTrackingScene(undoManager: UndoManager?) {
        guard trackingScene != nil else { return }
        let prior = trackingAuthoringState
        trackingScene = nil
        selectedTrackingCameraID = nil
        selectedTrackingPointGroupID = nil
        trackingCameraEnabled = true
        trackingPointsVisible = true
        trackingGeometryVisible = true
        visibleTrackingMeshIDs = []
        trackingScalePointAID = nil
        trackingScalePointBID = nil
        trackingMeasuredDistanceMeters = 1
        trackingMetersPerSourceUnit = nil
        trackingScaleSelectionSlot = nil
        trackingSynthEyesUnitValue = 1
        trackingSynthEyesUnit = "m"
        applyTimelineAuthority(resetRange: true)
        physicalModel.invalidateExternalParameters()
        registerTrackingAuthoringUndo(
            prior,
            undoManager: undoManager,
            actionName: "Eliminar importación 3D"
        )
        status = "Importación 3D eliminada"
    }

    private func registerTrackingAuthoringUndo(
        _ state: TrackingAuthoringState,
        undoManager: UndoManager?,
        actionName: String
    ) {
        registerUndo(with: undoManager, actionName: actionName) { target, manager in
            target.restoreTrackingAuthoring(
                state,
                undoManager: manager,
                actionName: actionName
            )
        }
    }

    private func restoreTrackingAuthoring(
        _ state: TrackingAuthoringState,
        undoManager: UndoManager?,
        actionName: String
    ) {
        let inverse = trackingAuthoringState
        trackingScene = state.scene
        selectedTrackingCameraID = state.cameraID
        selectedTrackingPointGroupID = state.pointGroupID
        trackingCameraEnabled = state.cameraEnabled
        trackingPointsVisible = state.pointsVisible
        trackingGeometryVisible = state.geometryVisible
        visibleTrackingMeshIDs = state.visibleMeshIDs
        trackingScalePointAID = state.scalePointAID
        trackingScalePointBID = state.scalePointBID
        trackingMeasuredDistanceMeters = state.measuredDistanceMeters
        trackingMetersPerSourceUnit = state.metersPerSourceUnit
        trackingScaleSelectionSlot = state.scaleSelectionSlot
        trackingSynthEyesUnitValue = state.unitValue
        trackingSynthEyesUnit = state.unit
        applyTimelineAuthority(resetRange: true)
        currentFrame = min(max(0, state.currentFrame), frameCount - 1)
        inFrame = min(max(0, state.inFrame), frameCount - 1)
        outFrame = min(max(inFrame, state.outFrame), frameCount - 1)
        physicalModel.invalidateExternalParameters()
        registerTrackingAuthoringUndo(
            inverse,
            undoManager: undoManager,
            actionName: actionName
        )
    }

    private var trackingTimelineInfo: NativeVideoTimelineInfo? {
        if trackingSceneMethod == .fusionTrackerClipboard, let motion = fusionTrackerMotion {
            let rate: ExactFrameRate
            do {
                rate = try ExactFrameRate(
                    numerator: motion.frameRateNumerator,
                    denominator: motion.frameRateDenominator
                )
            } catch {
                preconditionFailure("El Tracker Fusion materializado contiene una cadencia inválida.")
            }
            return NativeVideoTimelineInfo(
                exactFrameRate: rate,
                frameCount: (motion.samples.map(\.frame).max() ?? 0) + 1
            )
        }
        guard trackingSceneMethod == .fusionComposition,
              trackingCameraEnabled, let camera = selectedTrackingCamera else { return nil }
        let rate: ExactFrameRate
        do {
            rate = try ExactFrameRate(
                numerator: camera.frameRateNumerator,
                denominator: camera.frameRateDenominator
            )
        } catch {
            preconditionFailure("La cámara Fusion importada contiene una cadencia inválida.")
        }
        return NativeVideoTimelineInfo(exactFrameRate: rate, frameCount: camera.samples.count)
    }

    static func savedRenderTimeline(
        source: SavedSceneSource,
        tracking: SavedTrackingScene?,
        fusionTrackerMotion: FusionTrackerPoseTrack?,
        trackingSceneMethod: TrackingSceneMethod
    ) throws -> NativeVideoTimelineInfo {
        let sourceTimeline: NativeVideoTimelineInfo
        switch source.kind {
        case .syntheticPattern:
            sourceTimeline = .init(exactFrameRate: .fps24, frameCount: 1)
        case .externalMedia:
            guard let media = source.missingMedia else {
                throw SceneLibraryError.invalidDocument(
                    "La escena no contiene la cadencia persistida de su Source."
                )
            }
            sourceTimeline = .init(
                exactFrameRate: try media.exactFrameRate,
                frameCount: media.frameCount
            )
        }
        let trackingTimeline: NativeVideoTimelineInfo?
        if trackingSceneMethod == .fusionTrackerClipboard, let fusionTrackerMotion {
            try fusionTrackerMotion.validate()
            trackingTimeline = .init(
                exactFrameRate: try .init(
                    numerator: fusionTrackerMotion.frameRateNumerator,
                    denominator: fusionTrackerMotion.frameRateDenominator
                ),
                frameCount: (fusionTrackerMotion.samples.map(\.frame).max() ?? 0) + 1
            )
        } else if trackingSceneMethod == .fusionComposition,
                  let tracking, tracking.cameraEnabled {
            guard let camera = tracking.scene.cameras.first(where: {
                $0.id == tracking.cameraID
            }) else {
                throw SceneLibraryError.invalidDocument(
                    "La cámara de tracking seleccionada no existe."
                )
            }
            trackingTimeline = .init(
                exactFrameRate: try .init(
                    numerator: camera.frameRateNumerator,
                    denominator: camera.frameRateDenominator
                ),
                frameCount: camera.samples.count
            )
        } else {
            trackingTimeline = nil
        }
        return ReferenceTimelineAuthority.resolve(
            source: sourceTimeline,
            reference: nil,
            referenceVisible: false,
            tracking: trackingTimeline
        )
    }

    private func applyTrackingCameraAtCurrentFrame() {
        guard trackingCameraEnabled, selectedTrackingCamera != nil else { return }
        // Tracking is an Application-owned track. Timeline changes invalidate presentation but
        // never write a sampled pose, focal length or gate into base scene authoring.
        physicalModel.invalidateExternalParameters()
    }

    private struct ResolvedSceneFrame {
        let revision: UInt64
        let selection: PhysicalFrameSelection
        let authored: PhysicalPipelineAuthoringState
        let activeSensorWindow: PhysicalActiveSensorWindow
        let orchestration: PhysicalFrameOrchestration
        let device: ResolvedDevice
        let pipeline: PhysicalPipelineResolvedState
        let resolver: RustSceneFrameResolver
    }

    private struct PublishedSceneIdentity: Equatable {
        let revision: UInt64
        let selection: PhysicalFrameSelection

        init(_ scene: ResolvedSceneFrame) {
            revision = scene.revision
            selection = scene.selection
        }
    }

    private func publishSceneFrame(
        _ frame: StudioColorMetalFrame,
        scene: ResolvedSceneFrame
    ) {
        // Identity is committed before the texture. `metalFrame` is the Viewer commit marker,
        // so SwiftUI can never observe a new image with the prior scene overlay.
        publishedSceneIdentity = PublishedSceneIdentity(scene)
        publishedResolvedSceneFrame = scene
        metalFrame = frame
    }

    private func publishUnresolvedFrame(_ frame: StudioColorMetalFrame?) {
        publishedSceneIdentity = nil
        publishedResolvedSceneFrame = nil
        metalFrame = frame
    }

    private func publishCurrentSceneFrame(_ frame: StudioColorMetalFrame) {
        guard let scene = try? resolveSceneFrame(currentFrame) else {
            publishUnresolvedFrame(frame)
            return
        }
        publishSceneFrame(frame, scene: scene)
    }

    private struct SubmittedPhysicalJob {
        let job: PhysicalMetalFrameJob
        let scene: ResolvedSceneFrame
    }

    /// The sole per-frame materialization point for the physical request. The scene authoring
    /// remains the base; an active external track replaces only the parameters it owns.
    /// Every renderer must consume this result rather than applying tracking independently.
    private func resolveSceneFrame(
        _ frame: Int,
        temporalSamplesOverride: UInt16? = nil,
        authoredOverride: PhysicalPipelineAuthoringState? = nil
    ) throws -> ResolvedSceneFrame {
        guard let selectedDevice = resolvedDevice,
              let authoringSelection = testAuthoringSelection,
              let baseAuthoring = basePhysicalAuthoringState else {
            throw DeviceDomainError.invalidPhysicalProfile("La escena no tiene un Device resuelto.")
        }
        var authored = authoredOverride ?? baseAuthoring
        if let temporalSamplesOverride {
            guard (1...64).contains(temporalSamplesOverride) else {
                throw DeviceDomainError.invalidPhysicalProfile(
                    "Las muestras temporales deben estar entre 1 y 64."
                )
            }
            authored.shutterMotion.temporalSamples = temporalSamplesOverride
        }
        let exactFrameRate = ReferenceTimelineAuthority.resolve(
            source: sourceTimelineInfo,
            reference: referenceTimelineInfo,
            referenceVisible: referenceControlsTimeline,
            tracking: trackingTimelineInfo
        ).exactFrameRate
        let (timeNumerator, overflow) = Int64(frame).multipliedReportingOverflow(
            by: Int64(exactFrameRate.denominator)
        )
        guard !overflow else { throw PhysicalContractError.invalidFrameTime }
        let selection = try PhysicalFrameSelection(
            frameIndex: Int64(frame), timeNumerator: timeNumerator,
            timeDenominator: exactFrameRate.numerator,
            frameRateNumerator: exactFrameRate.numerator,
            frameRateDenominator: exactFrameRate.denominator
        )
        let contributions = physicalModel.orderedContributions
        guard let uniformityAmount = contributions.first(where: {
            $0.stage == .screen(.panelUniformity)
        })?.amount,
        let spreadAmount = contributions.first(where: {
            $0.stage == .screen(.panelLightSpread)
        })?.amount else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "La escena no contiene las contribuciones físicas resueltas."
            )
        }
        var deviceDefinition = selectedDevice.definition
        deviceDefinition.panelUniformity.characterStrength = uniformityAmount
        deviceDefinition.panelLightSpread.characterStrength = spreadAmount
        let device = try deviceDefinition.resolved()
        let pipeline = try authored.resolvedPipeline().resolving(contributions: contributions)
        let revision = physicalModel.parameterRevision
        let resolver: RustSceneFrameResolver
        if authoredOverride == nil,
           let cachedSceneResolver,
           cachedSceneResolver.revision == revision,
           cachedSceneResolver.frameRate == exactFrameRate,
           cachedSceneResolver.temporalSamplesOverride == temporalSamplesOverride {
            resolver = cachedSceneResolver.resolver
        } else {
            resolver = try RustSceneFrameResolver(
                revision: revision,
                frameRate: exactFrameRate,
                base: authored,
                resolvedDevice: device,
                resolvedPipeline: pipeline,
                trackingSceneMethod: trackingSceneMethod,
                trackingCamera: trackingCameraEnabled ? selectedTrackingCamera : nil,
                trackingMetersPerSourceUnit: trackingCameraEnabled
                    ? trackingMetersPerSourceUnit : nil,
                fusionTrackerMotion: fusionTrackerMotion,
                autofocusEnabled: authoringSelection.autofocusEnabled,
                autofocusTargetU: authoringSelection.autofocusTargetU,
                autofocusTargetV: authoringSelection.autofocusTargetV
            )
            if authoredOverride == nil {
                cachedSceneResolver = .init(
                    revision: revision,
                    frameRate: exactFrameRate,
                    temporalSamplesOverride: temporalSamplesOverride,
                    resolver: resolver
                )
            }
        }
        let raw = try resolver.resolve(selection)
        Self.applyResolvedScene(raw, to: &authored)
        let activeSensorWindow = try PhysicalActiveSensorWindow(
            fullWidth: Int(raw.full_sensor_width),
            fullHeight: Int(raw.full_sensor_height),
            originX: Int(raw.active_sensor_origin_x),
            originY: Int(raw.active_sensor_origin_y),
            width: Int(raw.active_sensor_width),
            height: Int(raw.active_sensor_height)
        )
        return .init(
            revision: raw.revision,
            selection: selection,
            authored: authored,
            activeSensorWindow: activeSensorWindow,
            orchestration: try authored.orchestration(for: selection),
            device: device,
            pipeline: pipeline,
            resolver: resolver
        )
    }

    private static func applyResolvedScene(
        _ raw: ScreenResolvedSceneFrameV1,
        to authored: inout PhysicalPipelineAuthoringState
    ) {
        authored.cameraPose.position = [
            Double(raw.camera_position.0), Double(raw.camera_position.1),
            Double(raw.camera_position.2),
        ]
        authored.cameraPose.quaternion = [
            Double(raw.camera_rotation_xyzw.0), Double(raw.camera_rotation_xyzw.1),
            Double(raw.camera_rotation_xyzw.2), Double(raw.camera_rotation_xyzw.3),
        ]
        authored.cameraLookAt = nil
        authored.screenPose.position = [
            Double(raw.screen_position.0), Double(raw.screen_position.1),
            Double(raw.screen_position.2),
        ]
        authored.screenPose.quaternion = [
            Double(raw.screen_rotation_xyzw.0), Double(raw.screen_rotation_xyzw.1),
            Double(raw.screen_rotation_xyzw.2), Double(raw.screen_rotation_xyzw.3),
        ]
        authored.sceneLens.focalLengthMillimeters = Double(raw.focal_length_millimeters)
        authored.sceneLens.sensorWidthMillimeters = Double(raw.sensor_width_millimeters)
        authored.sceneLens.sensorHeightMillimeters = Double(raw.sensor_height_millimeters)
        authored.sceneLens.lensShift = [Double(raw.lens_shift.0), Double(raw.lens_shift.1)]
        authored.sceneLens.focusDistanceMeters = Double(raw.focus_distance_meters)
        authored.sceneLens.fStop = Double(raw.f_stop)
        authored.sceneLens.nearClipMeters = Double(raw.near_clip_meters)
        authored.sceneLens.farClipMeters = Double(raw.far_clip_meters)
        authored.sceneLens.radialDistortion = [
            Double(raw.lens_radial_distortion.0), Double(raw.lens_radial_distortion.1),
            Double(raw.lens_radial_distortion.2),
        ]
        authored.sceneLens.tangentialDistortion = [
            Double(raw.lens_tangential_distortion.0),
            Double(raw.lens_tangential_distortion.1),
        ]
        authored.sceneLens.longitudinalChromaticMeters = [
            Double(raw.lens_longitudinal_chromatic_meters.0),
            Double(raw.lens_longitudinal_chromatic_meters.1),
            Double(raw.lens_longitudinal_chromatic_meters.2),
        ]
        authored.sceneLens.lateralChromaticScale = [
            Double(raw.lens_lateral_chromatic_scale.0),
            Double(raw.lens_lateral_chromatic_scale.1),
            Double(raw.lens_lateral_chromatic_scale.2),
        ]
        authored.sceneLens.vignettingStrength = Double(raw.lens_vignetting_strength)
        authored.sceneLens.transmissionRGB = [
            Double(raw.lens_transmission_rgb.0), Double(raw.lens_transmission_rgb.1),
            Double(raw.lens_transmission_rgb.2),
        ]
        authored.sceneLens.centerSoftnessMicrometers = Double(
            raw.lens_center_softness_micrometers
        )
        authored.sceneLens.edgeSoftnessMicrometers = Double(
            raw.lens_edge_softness_micrometers
        )
        authored.sceneLens.veilingGlareFraction = Double(raw.lens_veiling_glare_fraction)
        // This value is a frame-local presentation adapter. The immutable Rust scene retains
        // the complete sensor plus the active origin; Setup receives only the exposed raster.
        authored.sensor.nativeWidth = raw.active_sensor_width
        authored.sensor.nativeHeight = raw.active_sensor_height
    }

    private func resolveTrackingOverlay(_ sources: [SIMD3<Double>]) -> [CGPoint?] {
        guard !sources.isEmpty,
              let frame = metalFrame,
              let scale = trackingMetersPerSourceUnit,
              let resolved = publishedResolvedSceneFrame,
              publishedSceneIdentity == PublishedSceneIdentity(resolved)
        else { return [] }
        let deliveryWidth = Int(testAuthoringSelection?.deliveryWidth ?? UInt32(frame.width))
        let deliveryHeight = Int(testAuthoringSelection?.deliveryHeight ?? UInt32(frame.height))
        guard let placement = Self.deliveryPlacementCode(
            testAuthoringSelection?.deliveryPlacementID ?? "fit"
        ) else { return [] }
        return (try? resolved.resolver.resolveTrackingOverlay(
            frame: resolved.selection,
            sourcePoints: sources,
            metersPerSourceUnit: scale,
            deliveryWidth: deliveryWidth,
            deliveryHeight: deliveryHeight,
            previewWidth: frame.width,
            previewHeight: frame.height,
            deliveryPlacement: placement,
            expectedRevision: resolved.revision
        )) ?? []
    }

    func step(_ delta: Int) { seek(toFrame: currentFrame + delta) }
    func jump(_ seconds: Double) { seek(toFrame: currentFrame + Int(seconds * frameRate)) }
    func markIn() { setInFrame(currentFrame) }
    func markOut() { setOutFrame(currentFrame) }
    func setInFrame(_ frame: Int) {
        inFrame = min(max(0, frame), outFrame)
    }
    func setOutFrame(_ frame: Int) {
        outFrame = max(inFrame, min(max(0, frame), max(0, frameCount - 1)))
    }

    var currentSimulationOpacity: Double {
        (try? resolvedSimulationOpacity(frame: currentFrame, frameRate: currentTimelineFrameRate))
            ?? .nan
    }

    var currentSimulationOpacityKeyframe: SceneScalarKeyframe? {
        guard let time = try? exactAnimationTime(
            frame: currentFrame, frameRate: currentTimelineFrameRate
        ) else { return nil }
        let track = sceneAnimation.simulationOpacityTrack
        return track.keyframeIndex(
            timeNumerator: time.numerator, timeDenominator: time.denominator
        ).map { track.keyframes[$0] }
    }

    var simulationOpacityKeyframeFrames: [Int] {
        let rate = currentTimelineFrameRate
        return sceneAnimation.simulationOpacityTrack.keyframes.compactMap { keyframe in
            guard keyframe.timeDenominator != 0 else { return nil }
            let frame = Double(keyframe.timeNumerator) / Double(keyframe.timeDenominator)
                * rate.framesPerSecond
            guard frame.isFinite else { return nil }
            return Int(frame.rounded())
        }
    }

    func setSimulationOpacityKeyframe(
        value: Double,
        interpolation: SceneAnimationInterpolation? = nil,
        undoManager: UndoManager? = nil
    ) {
        do {
            guard value.isFinite, (0 ... 1).contains(value) else {
                throw SceneAnimationError.invalidContract("La opacidad debe estar entre 0 y 1.")
            }
            let time = try exactAnimationTime(
                frame: currentFrame, frameRate: currentTimelineFrameRate
            )
            var animation = sceneAnimation
            var track = animation.simulationOpacityTrack
            if let index = track.keyframeIndex(
                timeNumerator: time.numerator, timeDenominator: time.denominator
            ) {
                track.keyframes[index].value = value
                if let interpolation {
                    track.keyframes[index].interpolation = interpolation
                }
            } else {
                track.keyframes.append(.init(
                    timeNumerator: time.numerator,
                    timeDenominator: time.denominator,
                    value: value,
                    interpolation: interpolation
                        ?? SimulationOpacityResolver.presentation.defaultInterpolation
                ))
                track.keyframes.sort {
                    Decimal($0.timeNumerator) * Decimal($1.timeDenominator)
                        < Decimal($1.timeNumerator) * Decimal($0.timeDenominator)
                }
            }
            animation.simulationOpacityTrack = track
            try animation.validate()
            replaceSceneAnimation(animation, undoManager: undoManager)
            status = "Keyframe de opacidad · frame \(currentFrame)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeCurrentSimulationOpacityKeyframe(undoManager: UndoManager? = nil) {
        do {
            let time = try exactAnimationTime(
                frame: currentFrame, frameRate: currentTimelineFrameRate
            )
            var animation = sceneAnimation
            var track = animation.simulationOpacityTrack
            guard track.keyframes.count > 1,
                  let index = track.keyframeIndex(
                    timeNumerator: time.numerator, timeDenominator: time.denominator
                  ) else { return }
            track.keyframes.remove(at: index)
            animation.simulationOpacityTrack = track
            try animation.validate()
            replaceSceneAnimation(animation, undoManager: undoManager)
            status = "Keyframe de opacidad eliminado · frame \(currentFrame)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setCurrentSimulationOpacityInterpolation(
        _ interpolation: SceneAnimationInterpolation,
        undoManager: UndoManager? = nil
    ) {
        setSimulationOpacityKeyframe(
            value: currentSimulationOpacity,
            interpolation: interpolation,
            undoManager: undoManager
        )
    }

    private func replaceSceneAnimation(
        _ animation: SceneAnimationDocument,
        undoManager: UndoManager?
    ) {
        guard animation != sceneAnimation else { return }
        let prior = sceneAnimation
        registerUndo(with: undoManager, actionName: "Editar animación") { target, manager in
            target.replaceSceneAnimation(prior, undoManager: manager)
        }
        sceneAnimation = animation
    }

    private var currentTimelineFrameRate: ExactFrameRate {
        ReferenceTimelineAuthority.resolve(
            source: sourceTimelineInfo,
            reference: referenceTimelineInfo,
            referenceVisible: referenceControlsTimeline,
            tracking: trackingTimelineInfo
        ).exactFrameRate
    }

    private func exactAnimationTime(
        frame: Int, frameRate: ExactFrameRate
    ) throws -> (numerator: Int64, denominator: UInt64) {
        let (numerator, overflow) = Int64(frame).multipliedReportingOverflow(
            by: Int64(frameRate.denominator)
        )
        guard !overflow, frameRate.numerator > 0 else {
            throw SceneAnimationError.invalidContract("El tiempo exacto del keyframe no es válido.")
        }
        return (numerator, UInt64(frameRate.numerator))
    }

    private func resolvedSimulationOpacity(
        frame: Int, frameRate: ExactFrameRate
    ) throws -> Double {
        let time = try exactAnimationTime(frame: frame, frameRate: frameRate)
        return try SimulationOpacityResolver.resolve(
            track: sceneAnimation.simulationOpacityTrack,
            timeNumerator: time.numerator,
            timeDenominator: time.denominator
        )
    }

    func fitPreview() {
        viewerNavigation.fit()
    }
    func showPreviewOneToOne() {
        viewerNavigation.showOneToOne()
    }
    func updateFittedZoom(_ value: Double) {
        viewerNavigation.updateFittedZoom(value)
    }
    func setInteractiveZoom(_ value: Double) {
        viewerNavigation.setInteractiveZoom(value)
    }
    func resetView() { fitPreview() }
    func fitModelPreview() {
        viewerNavigation.fitModelPreview()
    }
    func showModelPreviewOneToOne() {
        viewerNavigation.showModelPreviewOneToOne()
    }
    func zoomBy(_ factor: Double) {
        viewerNavigation.zoom(by: factor)
    }
    var zoomPercentage: Double {
        zoom * 100
    }
    func setZoomPercentage(_ percentage: Double) {
        viewerNavigation.setZoomPercentage(percentage)
    }

    func physicalAnimationArmBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { self.armedPhysicalParameterIDs.contains(id) },
            set: { armed in
                if armed {
                    self.armedPhysicalParameterIDs.insert(id)
                } else {
                    self.armedPhysicalParameterIDs.remove(id)
                }
            }
        )
    }

    func changeOutputFormat(_ format: StudioOutputFormat) {
        outputFormat = format
        if format == .openEXR { renderWIPReviewPreset = nil }
        if !format.supportedPixelEncodings.contains(outputPixelEncoding) {
            outputPixelEncoding = format.defaultPixelEncoding
        }
        if !format.supportedSignalRanges(for: outputPixelEncoding).contains(outputSignalRange),
           let required = format.supportedSignalRanges(for: outputPixelEncoding).first {
            outputSignalRange = required
        }
        if !format.supportsAlpha { outputAlphaMode = .ignore }
        if !format.isMovie { includeAudio = false }
    }

    func changeRenderComposition(_ composition: StudioRenderComposition) {
        renderComposition = composition
        ensureRenderOptionsCompatible()
    }

    var effectiveRenderTarget: StudioRenderTarget {
        if vfxInterchangeEncodingID
            == StudioVFXEditorialDeliveryContract.rec709ColorEncodingID {
            return .sdr
        }
        guard renderMode == .preview,
              let preset = renderWIPReviewPreset else { return renderPreset.target }
        return preset.outputColorSpace == .rec709Gamma24 ? .sdr : .hdr
    }

    func changeWIPReviewPreset(_ preset: StudioWIPReviewPreset?) {
        renderWIPReviewPreset = preset
        if preset != nil { outputAlphaMode = .ignore }
    }

    func changeRenderMode(_ mode: StudioRenderMode) {
        renderMode = mode
        if mode == .preview {
            renderComposition = .fullComposite
            renderWIPReviewPreset = nil
            includeFusionComposition = false
        } else {
            if renderComposition == .fullComposite {
                renderComposition = .deviceAndSpillTogether
            }
            renderWIPReviewPreset = nil
        }
        ensureRenderOptionsCompatible()
    }

    func configureRenderRaster(for scene: SavedScene) throws {
        let selection = try materializeSceneSelection(
            scene.snapshot.authoring, profileContext: testAuthoringProfileContext
        )
        renderRasterWidth = selection.deliveryWidth
        renderRasterHeight = selection.deliveryHeight
        renderRasterPlacementID = selection.deliveryPlacementID
    }

    func applyRenderPreset(_ preset: StudioRenderPreset) {
        renderPreset = preset
        if preset.target != .sdr && preset.target != .hdr {
            renderWIPReviewPreset = nil
        }
        peakNits = preset.peakNits
        changeOutputFormat(preset.format)
        outputPixelEncoding = preset.pixelEncoding
        outputSignalRange = preset.signalRange
        outputAlphaMode = preset.alpha
        includeAudio = preset.includeAudio
        if preset.id == StudioVFXEditorialDeliveryContract.presetID {
            renderMode = .final
            renderComposition = .deviceAndSpillSeparate
            renderSpillDeliveryMode = .editorialEncodedAdd
            renderMotionBlurMode = .approximate2D
            renderWIPReviewPreset = nil
            includeFusionComposition = false
        }
        if let fixed = preset.fixedVFXInterchangeEncodingID {
            vfxInterchangeEncodingID = fixed
        } else if preset.target == .vfxLog,
                  let recommendation = selectedCapturePreset?.nativeVFXEncodingID {
            vfxInterchangeEncodingID = recommendation
        }
        ensureRenderOptionsCompatible()
    }

    var selectedCapturePreset: CameraProfileDefinition? {
        capturePresets.first { $0.id == selectedCapturePresetID }
    }

    var selectedVFXInterchangeEncoding: StudioVFXInterchangeEncoding? {
        StudioVFXInterchangeEncoding.catalog.first { $0.id == vfxInterchangeEncodingID }
    }

    var recommendedVFXInterchangeEncoding: StudioVFXInterchangeEncoding? {
        guard let id = selectedCapturePreset?.nativeVFXEncodingID else { return nil }
        return StudioVFXInterchangeEncoding.catalog.first { $0.id == id }
    }

    func ensureRenderOptionsCompatible() {
        if renderMode == .preview {
            renderComposition = .fullComposite
            includeFusionComposition = false
            renderSpillDeliveryMode = .physicalLinear
            outputAlphaMode = .ignore
        } else {
            if renderComposition == .fullComposite {
                renderComposition = .deviceAndSpillTogether
            }
            renderWIPReviewPreset = nil
            outputAlphaMode = .straight
            if renderComposition == .deviceAndSpillSeparate { includeAudio = false }
            if includeFusionComposition {
                renderComposition = .deviceAndSpillTogether
                renderSpillDeliveryMode = .physicalLinear
                includeAudio = false
                renderMotionBlurMode = .disabled
            }
        }
        if renderSpillDeliveryMode == .editorialEncodedAdd,
           renderComposition != .deviceAndSpillSeparate {
            renderSpillDeliveryMode = .physicalLinear
        }
        if renderMode == .final, !outputFormat.supportsAlpha { return }
    }

    func savedSceneNeedsUpdate(_ scene: SavedScene) throws -> Bool {
        guard activeSceneID == scene.id else { return false }
        let capture = try captureSavedScene()
        let generatedMatches: Bool
        switch (capture.generatedEnvironmentEXR, scene.snapshot.generatedEnvironment) {
        case (nil, nil):
            generatedMatches = true
        case let (.some(data), .some(asset)):
            generatedMatches = FrameCheckPNG.sha256(data) == asset.sha256
        default:
            generatedMatches = false
        }
        let normalized = try capture.snapshot.replacingGeneratedEnvironment(
            scene.snapshot.generatedEnvironment
        )
        return normalized != scene.snapshot || !generatedMatches
    }

    func enqueueSavedScene(
        _ scene: SavedScene,
        derivedFrom sourceJob: NativeOutputQueueController.RenderJob? = nil,
        historicalSnapshot: Bool = false
    ) {
        ensureRenderOptionsCompatible()
        let generatedEnvironmentEXR: Data?
        do {
            generatedEnvironmentEXR = historicalSnapshot
                ? sourceJob?.generatedEnvironmentEXR
                : try scene.snapshot.generatedEnvironment.flatMap { identity in
                guard let asset = try EnvironmentAssetLibrary.asset(
                    sha256: identity.sha256,
                    originalFileName: identity.fileName
                ) else {
                    throw SceneLibraryError.invalidDocument(
                        "Falta el entorno generado de la escena guardada."
                    )
                }
                return try Data(contentsOf: asset.url, options: .mappedIfSafe)
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let url = URL(fileURLWithPath: renderOutputDirectoryPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = "La ruta de render debe ser un directorio existente."
            return
        }
        let savedTimeline: NativeVideoTimelineInfo
        do {
            savedTimeline = try Self.savedRenderTimeline(
                source: scene.snapshot.source,
                tracking: scene.snapshot.tracking,
                fusionTrackerMotion: scene.snapshot.fusionTrackerMotion,
                trackingSceneMethod: scene.snapshot.trackingSceneMethod
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let timeline = if activeSceneID == scene.id,
                          referenceControlsTimeline,
                          let referenceTimelineInfo {
            referenceTimelineInfo
        } else {
            savedTimeline
        }
        let range = renderRange == .inOut
            ? min(inFrame, outFrame) ... max(inFrame, outFrame)
            : 0 ... max(0, timeline.frameCount - 1)
        let exactFrameRate = sourceJob?.configuration.frameRate
            ?? timeline.exactFrameRate
        let fusion = includeFusionComposition
            ? StudioFusionSceneConfiguration(
                dofMode: fusionDOFMode,
                resolutionMode: fusionResolutionMode,
                customActiveWidth: fusionResolutionMode == .custom ? fusionCustomWidth : nil,
                customActiveHeight: fusionResolutionMode == .custom ? fusionCustomHeight : nil,
                spillThresholdSceneLinear: fusionSpillThresholdSceneLinear,
                spillFadeWidthPixels: fusionSpillFadeWidthPixels
            ) : nil
        let wipOutput = renderWIPReviewPreset.map { preset in
            switch preset.outputColorSpace {
            case .rec709Gamma24:
                return (StudioRenderTarget.sdr, 100.0,
                        "Rec.1886 Rec.709 - Display",
                        "ACES 2.0 - SDR 100 nits (Rec.709)")
            case .rec2100PQ:
                return (StudioRenderTarget.hdr, 1_000.0,
                        "Rec.2100-PQ - Display",
                        "ACES 2.0 - HDR 1000 nits (Rec.2020)")
            case .rec2100HLG:
                return (StudioRenderTarget.hdr, preset.hlgPeakNits,
                        "Rec.2100-HLG - Display",
                        "ACES 2.0 - HDR 1000 nits (P3 D65)")
            }
        }
        let editorialOutput: (
            StudioRenderTarget, Double, String, String
        )? = vfxInterchangeEncodingID
                == StudioVFXEditorialDeliveryContract.rec709ColorEncodingID
            ? (
                .sdr,
                StudioVFXEditorialDeliveryContract.rec709PeakNits,
                StudioVFXEditorialDeliveryContract.rec709Display,
                StudioVFXEditorialDeliveryContract.rec709View
            ) : nil
        let resolvedOutput = wipOutput ?? editorialOutput
        var configuration = StudioResolvedRenderConfiguration(
            renderMode: renderMode,
            jobName: renderJobName,
            versionSuffix: renderVersionSuffix,
            overwritePolicy: .failIfExists,
            fusionScene: fusion,
            composition: renderComposition,
            spillDeliveryMode: renderSpillDeliveryMode,
            motionBlurMode: renderMotionBlurMode,
            motionSamples: renderMotionSamples,
            raster: .init(
                width: renderRasterWidth, height: renderRasterHeight,
                placementID: renderRasterPlacementID
            ),
            format: outputFormat,
            pipeline: renderWIPReviewPreset == nil ? renderPreset.pipeline : .aces,
            target: resolvedOutput?.0 ?? renderPreset.target,
            peakNits: resolvedOutput?.1 ?? peakNits,
            display: resolvedOutput?.2 ?? renderPreset.display,
            view: resolvedOutput?.3 ?? renderPreset.view,
            vfxInterchangeEncodingID: renderPreset.target == .vfxLog
                ? vfxInterchangeEncodingID : nil,
            pixelEncoding: outputPixelEncoding,
            signalRange: outputSignalRange,
            alpha: renderWIPReviewPreset != nil
                ? .ignore
                : ([.deviceAndSpillTogether, .deviceAndSpillSeparate]
                    .contains(renderComposition) && outputFormat.supportsAlpha
                    ? .straight : .ignore),
            includeAudio: outputFormat.isMovie
                && renderComposition != .deviceAndSpillSeparate && includeAudio,
            frameRate: exactFrameRate,
            firstFrame: range.lowerBound,
            lastFrame: range.upperBound,
            wipReview: renderMode == .preview
                ? renderWIPReviewPreset : nil
        )
        var outputPlan: RenderOutputPlan
        do {
            try configuration.validate()
            outputPlan = try RenderOutputPlan.prepare(
                configuration: configuration, selectedDestination: url
            )
            let collision = try outputPlan.inspectCollision()
            if collision.requiresConfirmation {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = outputPlan.kind == .singleFile
                    ? "El archivo ya existe" : "La carpeta de salida contiene archivos"
                alert.informativeText = switch collision {
                case .none:
                    ""
                case .singleFile:
                    "El trabajo no se creará salvo que autorices reemplazar este archivo."
                case let .populatedDirectory(_, matching, total):
                    "La carpeta contiene \(total) archivo(s); \(matching) coincide(n) con el manifiesto de este trabajo. Solo se reemplazarán esos archivos generados y la carpeta nunca se vaciará."
                }
                alert.addButton(withTitle: "Cancelar")
                alert.addButton(withTitle: "Sobrescribir archivos existentes")
                switch alert.runModal() {
                case .alertSecondButtonReturn:
                    configuration = configuration.replacingOverwritePolicy(.replaceGeneratedFiles)
                default:
                    return
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        outputQueue.enqueue(
            scene: scene,
            generatedEnvironmentEXR: generatedEnvironmentEXR,
            outputPlan: outputPlan,
            configuration: configuration,
            derivedFromJobID: sourceJob?.id
        )
    }

    func configureRerender(
        from configuration: StudioResolvedRenderConfiguration,
        outputPlan: RenderOutputPlan
    ) {
        renderMode = configuration.renderMode
        renderJobName = configuration.jobName
        renderVersionSuffix = configuration.versionSuffix
        renderOutputDirectoryPath = switch outputPlan.kind {
        case .singleFile, .fusionScenePackage:
            outputPlan.destination.deletingLastPathComponent().path
        case .imageSequence, .deviceSpillDelivery:
            outputPlan.destination.path
        }
        renderComposition = configuration.composition
        renderSpillDeliveryMode = configuration.spillDeliveryMode
        renderMotionBlurMode = configuration.motionBlurMode
        renderMotionSamples = configuration.motionSamples
        renderRasterWidth = configuration.raster.width
        renderRasterHeight = configuration.raster.height
        renderRasterPlacementID = configuration.raster.placementID
        outputFormat = configuration.format
        outputPixelEncoding = configuration.pixelEncoding
        outputSignalRange = configuration.signalRange
        outputAlphaMode = configuration.alpha
        includeAudio = configuration.includeAudio
        peakNits = configuration.peakNits
        vfxInterchangeEncodingID = configuration.vfxInterchangeEncodingID ?? vfxInterchangeEncodingID
        inFrame = configuration.firstFrame
        outFrame = configuration.lastFrame
        renderRange = .inOut
        let inspectorTarget: StudioRenderTarget = configuration.target
        renderPreset = StudioRenderPreset(
            id: UUID(), name: "Ajustes del render anterior",
            pipeline: configuration.pipeline, target: inspectorTarget,
            peakNits: configuration.peakNits,
            display: configuration.display,
            view: configuration.view,
            format: configuration.format,
            pixelEncoding: configuration.pixelEncoding,
            signalRange: configuration.signalRange, alpha: configuration.alpha,
            includeAudio: configuration.includeAudio
        )
        renderWIPReviewPreset = configuration.wipReview
        includeFusionComposition = configuration.fusionScene != nil
        if let fusion = configuration.fusionScene {
            fusionDOFMode = fusion.dofMode
            fusionResolutionMode = fusion.resolutionMode
            fusionCustomWidth = fusion.customActiveWidth ?? fusionCustomWidth
            fusionCustomHeight = fusion.customActiveHeight ?? fusionCustomHeight
            fusionSpillThresholdSceneLinear = fusion.spillThresholdSceneLinear
            fusionSpillFadeWidthPixels = fusion.spillFadeWidthPixels
        }
        ensureRenderOptionsCompatible()
    }

    func enqueueExport() {
        guard let activeSceneID else {
            errorMessage = "Guarda primero la escena antes de añadirla a Render Queue."
            return
        }
        errorMessage = "Usa ‘Añadir a Render Queue’ desde el menú contextual de la escena guardada."
        status = "Escena activa · \(activeSceneID.uuidString.lowercased())"
    }

    func runQueue() {
        pause()
        outputQueue.resume()
        outputQueue.run(
            preflight: { job in
                let collision = try job.outputPlan.inspectCollision()
                guard collision.requiresConfirmation,
                      job.configuration.overwritePolicy == .failIfExists
                else { return job.configuration.overwritePolicy }

                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = job.outputPlan.kind == .singleFile
                    ? "El archivo de salida ya existe"
                    : "Hay archivos de salida que ya existen"
                alert.informativeText = switch collision {
                case .none:
                    ""
                case let .singleFile(url):
                    "Antes de iniciar el render se ha encontrado:\n\(url.path)\n\nSi continúas, se reemplazará este archivo."
                case let .populatedDirectory(url, matching, total):
                    "Antes de iniciar el render se han encontrado \(matching) archivo(s) del manifiesto dentro de una carpeta con \(total) archivo(s):\n\(url.path)\n\nSi continúas, sólo se reemplazarán los archivos declarados por este trabajo; los demás se conservarán."
                }
                alert.addButton(withTitle: "Cancelar")
                alert.addButton(withTitle: "Sobrescribir archivos existentes")
                return alert.runModal() == .alertSecondButtonReturn
                    ? .replaceGeneratedFiles : nil
            },
            operation: { job, progress in
                let log = try LastRenderLogRecorder(job: job)
                let loggedProgress: NativeOutputQueueController.Progress = { completed, total in
                    log.recordProgress(completed: completed, total: total)
                    progress(completed, total)
                }
                do {
                    let executor = WorkspaceModel()
                    let materialized = try executor.materializeQueuedScene(
                        job.scene,
                        generatedEnvironmentEXR: job.generatedEnvironmentEXR
                    )
                    defer { materialized.cleanup() }
                    try await executor.prepareQueuedScene(materialized.scene)
                    let url: URL
                    if job.configuration.fusionScene == nil {
                        url = try await NativeOutputRenderer.render(
                            configuration: job.configuration,
                            outputPlan: job.outputPlan,
                            audioSource: executor.session.sourceURL,
                            display: executor.metalDisplay,
                            frameProvider: { frame in
                                try await executor.renderQueuedSceneFrame(
                                    frame, configuration: job.configuration
                                )
                            },
                            progress: loggedProgress
                        )
                    } else {
                        let package = try executor.makeFusionPackageRequest(job: job)
                        url = try await FusionScenePackageWriter.render(
                            request: package.request,
                            display: executor.metalDisplay,
                            frameProvider: { frame in
                                try await executor.renderFusionPhysicalFrame(
                                    frame, request: package.request,
                                    sourceOverscan: package.sourceOverscan
                                )
                            },
                            progress: loggedProgress,
                            diagnostics: { log.record($0) }
                        )
                    }
                    try await log.finish(.completed)
                    return url
                } catch let cancellation as CancellationError {
                    try await log.finish(.cancelled)
                    throw cancellation
                } catch {
                    let renderError = error
                    try await log.finish(.failed, failure: renderError.localizedDescription)
                    throw renderError
                }
            },
            onFailure: { [weak self] message in self?.errorMessage = message }
        )
    }

    private struct QueuedSceneMaterialization {
        let scene: SavedScene
        let ownedEnvironmentSceneID: UUID?

        func cleanup() {
            guard let ownedEnvironmentSceneID else { return }
            try? EnvironmentAssetLibrary.removeSceneGeneratedEXR(
                sceneID: ownedEnvironmentSceneID
            )
        }
    }

    private func materializeQueuedScene(
        _ scene: SavedScene,
        generatedEnvironmentEXR: Data?
    ) throws -> QueuedSceneMaterialization {
        guard let generatedEnvironmentEXR else {
            return .init(scene: scene, ownedEnvironmentSceneID: nil)
        }
        let queueSceneID = UUID()
        let managed = try EnvironmentAssetLibrary.storeSceneGeneratedEXR(
            generatedEnvironmentEXR,
            sceneID: queueSceneID
        )
        let asset = SavedSceneAsset(
            fileName: managed.originalFileName,
            sha256: managed.sha256
        )
        let snapshot = try scene.snapshot.replacingGeneratedEnvironment(
            asset, absolutePath: managed.url.path
        )
        let clone = SavedScene(
            id: queueSceneID,
            name: scene.name,
            thumbnailFileName: "\(queueSceneID.uuidString.lowercased()).png",
            snapshot: snapshot
        )
        try clone.validate()
        return .init(scene: clone, ownedEnvironmentSceneID: queueSceneID)
    }

    private func prepareQueuedScene(_ scene: SavedScene) async throws {
        errorMessage = nil
        await openSavedScene(scene, undoManager: nil)
        if let errorMessage {
            throw SceneLibraryError.invalidDocument(errorMessage)
        }
        guard activeSceneID == scene.id else {
            throw SceneLibraryError.invalidDocument(
                "La escena guardada no se pudo materializar para Render Queue."
            )
        }
        // Queue evaluation is headless. Activating the Model page here used to
        // schedule an interactive physical preview before the explicit Queue
        // submission, so every attempt paid for an unobservable extra render.
        isModelPageActive = false
        _ = physicalInteractiveJob?.cancel()
        physicalInteractiveTask?.cancel()
        // A video plate is decoded at the exact render time; synthetic plates are
        // generated by the same Reference boundary and need no media session.
        if referencePlate == .videoReference {
            try await prepareQueuedReferenceRaster()
        }
        requestedPhysicalIntermediate = .cameraRenderedACEScg
        physicalModel.setQuality(.native)
    }

    private func renderQueuedSceneFrame(
        _ index: Int,
        configuration: StudioResolvedRenderConfiguration
    ) async throws -> StudioColorMetalFrame {
        try Task.checkCancellation()
        currentFrame = index
        let temporalSamples = configuration.physicalTemporalSamples
        let resolvedSceneFrame = try resolveSceneFrame(
            index, temporalSamplesOverride: temporalSamples
        )
        let simulationOpacity = try resolvedSimulationOpacity(
            frame: index, frameRate: configuration.frameRate
        )
        if !SimulationOpacityResolver.requiresPhysicalEvaluation(simulationOpacity) {
            return try await renderZeroOpacityQueuedFrame(
                configuration: configuration,
                resolvedSceneFrame: resolvedSceneFrame
            )
        }
        let source = try await renderFrame(index)
        sourceACEScgFrame = source
        physicalModel.invalidateExternalParameters()
        let submission = try await submitPhysicalJob(
            quality: .native,
            temporalSamplesOverride: temporalSamples,
            resolvedSceneFrameOverride: resolvedSceneFrame
        )
        while true {
            do {
                try Task.checkCancellation()
            } catch {
                await cancelAndDrainPhysicalJob(submission.job)
                throw error
            }
            let snapshot = try submission.job.snapshot()
            switch snapshot.state {
            case .idle, .stale, .rendering:
                try await Task.sleep(for: .milliseconds(8))
            case .cancelled:
                throw CancellationError()
            case .failed:
                throw PhysicalMetalFrameEngineError.bridge(
                    snapshot.diagnostics.last?.message
                        ?? "La evaluación física de la escena ha fallado."
                )
            case .complete:
                guard snapshot.returnedIntermediate == .cameraRenderedACEScg,
                      let camera = snapshot.frame,
                      let selection = testAuthoringSelection
                else {
                    throw PhysicalMetalFrameEngineError.bridge(
                        "Render Queue no recibió el checkpoint de cámara solicitado."
                    )
                }
                // Approximate 2D Motion Blur alone materializes the transparent carrier
                // before Reference. Disabled and physical modes retain the prior route.
                let deliveryCarrier: StudioColorMetalFrame?
                if configuration.composition != .fullComposite
                    || configuration.motionBlurMode == .approximate2D
                    || simulationOpacity != 1 {
                    let delivery = try RecordingPhaseExecutor.delivery(
                        cameraRendered: camera,
                        width: Int(configuration.raster.width),
                        height: Int(configuration.raster.height),
                        placementID: configuration.raster.placementID,
                        backgroundID: "transparent",
                        display: metalDisplay
                    ).compositionFrame
                    let motionCarrier = configuration.motionBlurMode == .approximate2D
                        ? try approximate2DMotionBlur(
                            delivery, scene: resolvedSceneFrame,
                            configuration: configuration,
                            deliveryPlacementID: configuration.raster.placementID
                        )
                        : delivery
                    deliveryCarrier = try applySimulationOpacity(
                        simulationOpacity, to: motionCarrier
                    )
                } else {
                    deliveryCarrier = nil
                }
                if configuration.composition != .fullComposite {
                    return deliveryCarrier!
                }
                let reference: StudioColorMetalFrame?
                if configuration.composition == .fullComposite {
                    if referencePlate == .videoReference { try await rebuildReferenceFrame() }
                    reference = try referencePlateFrame(
                        width: Int(configuration.raster.width),
                        height: Int(configuration.raster.height)
                    )
                    guard reference != nil else {
                        throw SceneLibraryError.invalidDocument(
                            "La placa de referencia seleccionada no se pudo resolver."
                        )
                    }
                } else {
                    reference = nil
                }
                if setupFramingRenderer == nil {
                    setupFramingRenderer = try SetupFramingRenderer(
                        device: camera.texture.device
                    )
                }
                let plan = try setupDiagnosticPlan(
                    scene: resolvedSceneFrame,
                    deliveryWidth: Int(configuration.raster.width),
                    deliveryHeight: Int(configuration.raster.height),
                    previewWidth: Int(configuration.raster.width),
                    previewHeight: Int(configuration.raster.height),
                    deliveryPlacementID: configuration.raster.placementID,
                    deliveryBackgroundID: selection.deliveryBackgroundID
                )
                return try setupFramingRenderer!.renderCameraComposite(
                    cameraResult: deliveryCarrier ?? camera,
                    reference: reference,
                    referencePlacement: referencePlacement,
                    plan: plan,
                    deliveryAligned: deliveryCarrier != nil
                ).frame
            }
        }
    }

    private func renderZeroOpacityQueuedFrame(
        configuration: StudioResolvedRenderConfiguration,
        resolvedSceneFrame: ResolvedSceneFrame
    ) async throws -> StudioColorMetalFrame {
        let transparent = try transparentSimulationFrame(
            width: Int(configuration.raster.width),
            height: Int(configuration.raster.height)
        )
        guard configuration.composition == .fullComposite else { return transparent }
        if referencePlate == .videoReference { try await rebuildReferenceFrame() }
        guard let reference = try referencePlateFrame(
            width: transparent.width, height: transparent.height
        ), let selection = testAuthoringSelection else {
            throw SceneLibraryError.invalidDocument(
                "La placa de referencia seleccionada no se pudo resolver."
            )
        }
        if setupFramingRenderer == nil {
            setupFramingRenderer = try SetupFramingRenderer(device: transparent.texture.device)
        }
        let plan = try setupDiagnosticPlan(
            scene: resolvedSceneFrame,
            deliveryWidth: transparent.width,
            deliveryHeight: transparent.height,
            previewWidth: transparent.width,
            previewHeight: transparent.height,
            deliveryPlacementID: configuration.raster.placementID,
            deliveryBackgroundID: selection.deliveryBackgroundID
        )
        return try setupFramingRenderer!.renderCameraComposite(
            cameraResult: transparent,
            reference: reference,
            referencePlacement: referencePlacement,
            plan: plan,
            deliveryAligned: true
        ).frame
    }

    private func transparentSimulationFrame(
        width: Int, height: Int
    ) throws -> StudioColorMetalFrame {
        let key = "\(width)x\(height)"
        if let frame = transparentSimulationFrames[key] { return frame }
        guard width > 0, height > 0 else { throw NativeOutputError.invalidFrame }
        let frame = try metalDisplay.makeIndependentLinearACEScgFrame(
            width: width, height: height,
            rgba: [Float](repeating: 0, count: width * height * 4)
        )
        transparentSimulationFrames[key] = frame
        return frame
    }

    private func applySimulationOpacity(
        _ opacity: Double, to frame: StudioColorMetalFrame
    ) throws -> StudioColorMetalFrame {
        guard opacity.isFinite, (0 ... 1).contains(opacity) else {
            throw SceneAnimationError.invalidContract("La opacidad resuelta no es válida.")
        }
        if opacity == 1 { return frame }
        if opacity == 0 {
            return try transparentSimulationFrame(width: frame.width, height: frame.height)
        }
        var rgba = try metalDisplay.readLinearRGBA(frame)
        try SimulationOpacityResolver.apply(opacity, to: &rgba)
        return try metalDisplay.makeIndependentLinearACEScgFrame(
            width: frame.width, height: frame.height, rgba: rgba
        )
    }

    private func approximate2DMotionBlur(
        _ carrier: StudioColorMetalFrame,
        scene: ResolvedSceneFrame,
        configuration: StudioResolvedRenderConfiguration,
        deliveryPlacementID: String
    ) throws -> StudioColorMetalFrame {
        let width = carrier.width
        let height = carrier.height
        let frame = Int(scene.selection.frameIndex)
        let rate = configuration.frameRate
        func frameSelection(timeFrame: Int, identityFrame: Int) throws -> PhysicalFrameSelection {
            let (timeNumerator, overflow) = Int64(timeFrame).multipliedReportingOverflow(
                by: Int64(rate.denominator)
            )
            guard !overflow else { throw PhysicalContractError.invalidFrameTime }
            return try PhysicalFrameSelection(
                frameIndex: Int64(identityFrame), timeNumerator: timeNumerator,
                timeDenominator: rate.numerator,
                frameRateNumerator: rate.numerator,
                frameRateDenominator: rate.denominator
            )
        }
        guard let placement = Self.deliveryPlacementCode(deliveryPlacementID) else {
            throw SetupFramingError.invalidContract
        }
        func projectedCenter(_ selection: PhysicalFrameSelection) throws -> CGPoint {
            let plan = try scene.resolver.prepareSetupDiagnostic(
                frame: selection,
                deliveryWidth: width, deliveryHeight: height,
                previewWidth: width, previewHeight: height,
                deliveryPlacement: placement, deliveryBackground: 0,
                expectedRevision: scene.revision
            )
            guard let point = SetupFramingRenderer.projectedDevicePoint(
                u: 0.5, v: 0.5, plan: plan, applyLensDistortion: true
            ) else { throw SetupFramingError.invalidContract }
            return point
        }
        let velocitySampling = try Approximate2DMotionVelocitySampling.resolve(frame: frame)
        let previous = try projectedCenter(frameSelection(
            timeFrame: velocitySampling.earlierTimeFrame,
            identityFrame: velocitySampling.earlierIdentityFrame
        ))
        let next = try projectedCenter(frameSelection(
            timeFrame: velocitySampling.laterTimeFrame,
            identityFrame: velocitySampling.laterIdentityFrame
        ))
        let shutter = scene.authored.shutterMotion
        let open = Double(shutter.openOffsetNumerator)
            / Double(shutter.openOffsetDenominator)
        let close = Double(shutter.closeOffsetNumerator)
            / Double(shutter.closeOffsetDenominator)
        let openFrames = open * rate.framesPerSecond
        let closeFrames = close * rate.framesPerSecond
        guard openFrames.isFinite, closeFrames.isFinite, closeFrames >= openFrames else {
            throw SetupFramingError.invalidContract
        }
        let velocityX = (next.x - previous.x) * 0.5
        let velocityY = (next.y - previous.y) * 0.5
        let values = try metalDisplay.readLinearRGBA(carrier)
        let blurred = try Approximate2DMotionBlur.apply(
            to: values, width: width, height: height,
            shutterStart: CGPoint(x: velocityX * openFrames, y: velocityY * openFrames),
            shutterEnd: CGPoint(x: velocityX * closeFrames, y: velocityY * closeFrames),
            samples: configuration.motionSamples
        )
        return try metalDisplay.makeIndependentLinearACEScgFrame(
            width: width, height: height, rgba: blurred
        )
    }

    private func cancelAndDrainPhysicalJob(_ job: PhysicalMetalFrameJob) async {
        _ = job.cancel()
        while true {
            guard let snapshot = try? job.snapshot() else { return }
            switch snapshot.state {
            case .idle, .stale, .rendering:
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(
                        deadline: .now() + .milliseconds(8)
                    ) {
                        continuation.resume()
                    }
                }
            case .complete, .cancelled, .failed:
                return
            }
        }
    }

    func makeFusionPackageRequest(
        job: NativeOutputQueueController.RenderJob
    ) throws -> (request: FusionScenePackageRequest, sourceOverscan: Int) {
        guard let options = job.configuration.fusionScene,
              let device = resolvedDevice?.definition,
              testAuthoringSelection != nil else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "Fusion Scene Package requiere Device, cámara y Test resueltos."
            )
        }
        let contributions = physicalModel.orderedContributions
        guard physicalModel.effectiveScreenAmount == 1,
              contributions.first(where: { $0.stage == .screen(.emission) })?.amount == 1 else {
            throw FusionScenePackageError.incompletePhysicalDeviceContribution
        }
        var cameras: [FusionCameraKeyframe] = []
        var devicePoses: [FusionDevicePoseKeyframe] = []
        var lenses: [FusionLensKeyframe] = []
        var shutter: PhysicalPipelineAuthoringState.ShutterMotion?
        let lensReconstruction: FusionLensReconstructionKind =
            trackingCameraEnabled && selectedTrackingCamera != nil
                ? .importedSynthEyesDE4
                : .applicationBrownConrady
        for frame in job.configuration.frameRange {
            currentFrame = frame
            let resolved = try resolveSceneFrame(frame)
            let authored = resolved.authored
            shutter = authored.shutterMotion
            let orchestration = resolved.orchestration
            let cameraPosition = SIMD3<Double>(
                Double(orchestration.cameraPose.position.x),
                Double(orchestration.cameraPose.position.y),
                Double(orchestration.cameraPose.position.z)
            )
            let screenPosition = SIMD3<Double>(
                Double(orchestration.screenPose.position.x),
                Double(orchestration.screenPose.position.y),
                Double(orchestration.screenPose.position.z)
            )
            let cameraQ = simd_quatd(
                ix: Double(orchestration.cameraPose.rotation.x),
                iy: Double(orchestration.cameraPose.rotation.y),
                iz: Double(orchestration.cameraPose.rotation.z),
                r: Double(orchestration.cameraPose.rotation.w)
            )
            let screenQ = simd_quatd(
                ix: Double(orchestration.screenPose.rotation.x),
                iy: Double(orchestration.screenPose.rotation.y),
                iz: Double(orchestration.screenPose.rotation.z),
                r: Double(orchestration.screenPose.rotation.w)
            )
            let lens = authored.sceneLens
            cameras.append(FusionCameraKeyframe(
                frame: frame,
                positionMeters: [
                    cameraPosition.x, cameraPosition.y, cameraPosition.z,
                ],
                quaternionXYZW: [
                    cameraQ.imag.x, cameraQ.imag.y,
                    cameraQ.imag.z, cameraQ.real,
                ],
                focalLengthMillimeters: lens.focalLengthMillimeters,
                horizontalFOVDegrees: 2 * atan(
                    lens.sensorWidthMillimeters / (2 * lens.focalLengthMillimeters)
                ) * 180 / .pi,
                sensorWidthMillimeters: lens.sensorWidthMillimeters,
                sensorHeightMillimeters: lens.sensorHeightMillimeters,
                lensShiftXY: lens.lensShift,
                focusDistanceMeters: lens.focusDistanceMeters,
                fStop: lens.fStop,
                nearClipMeters: lens.nearClipMeters,
                farClipMeters: lens.farClipMeters
            ))
            devicePoses.append(FusionDevicePoseKeyframe(
                frame: frame,
                positionMeters: [screenPosition.x, screenPosition.y, screenPosition.z],
                quaternionXYZW: [
                    screenQ.imag.x, screenQ.imag.y, screenQ.imag.z, screenQ.real,
                ]
            ))
            lenses.append(FusionLensKeyframe(
                frame: frame,
                radialK1K2K3: lens.radialDistortion,
                tangentialP1P2: lens.tangentialDistortion,
                opticalCenterXY: [0, 0]
            ))
        }
        let activeRaster: FusionProjectedRaster
        switch options.resolutionMode {
        case .maximumProjectedDensity:
            activeRaster = try FusionProjectionResolver.maximumProjectedDensity(
                cameraSamples: cameras,
                devicePoseSamples: devicePoses,
                deviceWidthMeters: device.activeWidthMeters,
                deviceHeightMeters: device.activeHeightMeters,
                deliveryWidth: Int(job.configuration.raster.width),
                deliveryHeight: Int(job.configuration.raster.height)
            )
        case .nativeDevice:
            activeRaster = try FusionProjectionResolver.nativeDevice(
                width: device.nativeWidth, height: device.nativeHeight,
                deviceWidthMeters: device.activeWidthMeters,
                deviceHeightMeters: device.activeHeightMeters
            )
        case .custom:
            guard let width = options.customActiveWidth,
                  let height = options.customActiveHeight else {
                throw FusionScenePackageError.invalidRaster
            }
            activeRaster = try FusionProjectionResolver.customFit(
                maximumWidth: width, maximumHeight: height,
                deviceWidthMeters: device.activeWidthMeters,
                deviceHeightMeters: device.activeHeightMeters
            )
        }
        let spreadAmount = contributions.first(where: {
            $0.stage == .screen(.panelLightSpread)
        })?.amount ?? 0
        let glowAmount = contributions.first(where: {
            $0.stage == .screen(.coverGlow)
        })?.amount ?? 0
        let dofSupport = options.dofMode == .baked
            ? try FusionProjectionResolver.depthOfFieldSupportPixels(
                cameraSamples: cameras,
                devicePoseSamples: devicePoses,
                deviceWidthMeters: device.activeWidthMeters,
                deviceHeightMeters: device.activeHeightMeters,
                pixelsPerMeter: activeRaster.pixelsPerMeter
            ) : 0
        let sourceOverscan = try FusionPhysicalSupportResolver.sourceOverscanPixels(
            panelTailRadiusMicrometers: device.panelLightSpread.tailRadiusMicrometers.max() ?? 0,
            panelSpreadAmount: spreadAmount,
            glowRadiusMillimeters: physicalAuthoringState?.coverGlass.glowRadiusMillimeters ?? 0,
            glowAmount: glowAmount,
            dofSupportPixels: dofSupport,
            fadeWidthPixels: options.spillFadeWidthPixels,
            pixelsPerMeter: activeRaster.pixelsPerMeter
        )
        guard let shutter else { throw FusionScenePackageError.invalidCamera }
        let frameDuration = 1 / job.configuration.frameRate.framesPerSecond
        let open = Double(shutter.openOffsetNumerator)
            / Double(shutter.openOffsetDenominator)
        let close = Double(shutter.closeOffsetNumerator)
            / Double(shutter.closeOffsetDenominator)
        let referencePlate: FusionReferencePlate?
        let outputPlan: RenderOutputPlan
        if let referenceURL = referenceSourceURL {
            guard let inputTransformID = referenceInputTransformID else {
                throw FusionScenePackageError.invalidRaster
            }
            let colorTransform = FusionReferenceColorTransform.resolve(
                inputTransformID: inputTransformID
            )
            guard !referenceURL.path.isEmpty else { throw FusionScenePackageError.invalidRaster }
            guard let referenceRaster = referenceACEScgFrame else {
                throw FusionScenePackageError.invalidRaster
            }
            outputPlan = job.outputPlan
            referencePlate = .init(
                sourceURL: referenceURL,
                inputTransformID: inputTransformID,
                colorTransform: colorTransform,
                placementID: referencePlacement.stableID,
                width: referenceRaster.width,
                height: referenceRaster.height
            )
        } else {
            outputPlan = job.outputPlan
            referencePlate = nil
        }
        return (
            FusionScenePackageRequest(
                configuration: job.configuration,
                outputPlan: outputPlan,
                deviceWidthMeters: device.activeWidthMeters,
                deviceHeightMeters: device.activeHeightMeters,
                activeRaster: activeRaster,
                sourceOverscanPixels: sourceOverscan,
                deliveryWidth: Int(job.configuration.raster.width),
                deliveryHeight: Int(job.configuration.raster.height),
                camera: cameras,
                devicePose: devicePoses,
                lens: lenses,
                lensReconstruction: lensReconstruction,
                motionBlur: .init(
                    bakedInEXR: false,
                    enabledInFusion: true,
                    shutterAngleDegrees: (close - open) / frameDuration * 360,
                    shutterPhaseDegrees: (open + close) * 0.5 / frameDuration * 360
                ),
                referencePlate: referencePlate
            ),
            sourceOverscan
        )
    }

    func renderFusionPhysicalFrame(
        _ frameIndex: Int,
        request: FusionScenePackageRequest,
        sourceOverscan: Int
    ) async throws -> FusionRawPhysicalFrame {
        currentFrame = frameIndex
        let simulationOpacity = try resolvedSimulationOpacity(
            frame: frameIndex, frameRate: request.configuration.frameRate
        )
        let active = request.activeRaster
        let width = active.activeWidth + sourceOverscan * 2
        let height = active.activeHeight + sourceOverscan * 2
        let activeRect = FusionRasterRect(
            x: sourceOverscan, y: sourceOverscan,
            width: active.activeWidth, height: active.activeHeight
        )
        if !SimulationOpacityResolver.requiresPhysicalEvaluation(simulationOpacity) {
            return FusionRawPhysicalFrame(
                width: width, height: height, activeRect: activeRect,
                deviceRGBA: [], simulationOpacity: 0
            )
        }
        let sourceStarted = ContinuousClock.now
        let source = try await renderFrame(frameIndex)
        let sourceFinished = ContinuousClock.now
        sourceACEScgFrame = source
        physicalModel.invalidateExternalParameters()
        let dimensions = try PhysicalDimensions(width: width, height: height)
        let physicalStarted = ContinuousClock.now
        let submission = try await submitPhysicalJob(
            quality: .high,
            temporalSamplesOverride: 1,
            sourceFrameOverride: source,
            frameIndexOverride: frameIndex,
            requestedDimensionsOverride: dimensions,
            requestedIntermediateOverride: .deviceVfxTransparency,
            vfxTransparency: .init(
                activeWidth: active.activeWidth,
                activeHeight: active.activeHeight,
                bakeDepthOfField: request.configuration.fusionScene!.dofMode == .baked
            ),
            publishesPreviewState: false
        )
        while true {
            do { try Task.checkCancellation() }
            catch {
                await cancelAndDrainPhysicalJob(submission.job)
                throw error
            }
            let snapshot = try submission.job.snapshot()
            switch snapshot.state {
            case .idle, .stale, .rendering:
                try await Task.sleep(for: .milliseconds(8))
            case .cancelled:
                throw CancellationError()
            case .failed:
                throw PhysicalMetalFrameEngineError.bridge(
                    snapshot.diagnostics.last?.message ?? "Falló Device VFX Transparency."
                )
            case .complete:
                let physicalFinished = ContinuousClock.now
                guard snapshot.returnedIntermediate == .deviceVfxTransparency,
                      let output = snapshot.frame,
                      output.width == width, output.height == height else {
                    throw PhysicalMetalFrameEngineError.invalidSnapshot
                }
                let readbackStarted = ContinuousClock.now
                let physicalRGBA = try metalDisplay.readLinearRGBA(output)
                let readbackFinished = ContinuousClock.now
                guard physicalRGBA.count == width * height * 4,
                      physicalRGBA.allSatisfy(\.isFinite) else {
                    throw PhysicalMetalFrameEngineError.invalidSnapshot
                }
                return FusionRawPhysicalFrame(
                    width: width, height: height,
                    activeRect: activeRect,
                    deviceRGBA: physicalRGBA,
                    simulationOpacity: simulationOpacity,
                    physicalTiming: .resolve(
                        sourcePreparationSeconds: sourceStarted.duration(to: sourceFinished).seconds,
                        physicalEvaluationSeconds: physicalStarted.duration(to: physicalFinished).seconds,
                        gpuReadbackSeconds: readbackStarted.duration(to: readbackFinished).seconds,
                        diagnostics: snapshot.diagnostics
                    )
                )
            }
        }
    }

    func cancelRender() {
        outputQueue.cancel()
    }

    func pauseRenderQueue() {
        outputQueue.pause()
        status = "Render Queue en pausa"
    }

    func clearTerminalRenders() {
        outputQueue.clearTerminalJobs()
        status = "Renders terminados eliminados de la cola"
    }

    func removeInactiveRender(_ job: NativeOutputQueueController.RenderJob) {
        guard outputQueue.removeInactiveJob(id: job.id) else { return }
        status = "Trabajo eliminado de la cola · \(job.scene.name)"
    }

    func showRenderDestinationInFinder(_ job: NativeOutputQueueController.RenderJob) {
        guard job.state.isTerminal else { return }
        let directory: URL
        switch job.outputPlan.kind {
        case .singleFile:
            directory = job.destination.deletingLastPathComponent()
        case .imageSequence, .deviceSpillDelivery, .fusionScenePackage:
            directory = job.destination
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            errorMessage = "No existe el directorio de salida de este render."
            return
        }
        NSWorkspace.shared.open(directory)
    }

    static func isHistoricalRerenderEligible(
        _ state: NativeOutputQueueController.RenderJob.State
    ) -> Bool {
        state.isTerminal
    }

    /// Regenerates only the Fusion composition for a completed package. The queued scene and
    /// output configuration remain immutable; EXR media are neither evaluated nor rewritten.
    func refreshFusionComposition(_ job: NativeOutputQueueController.RenderJob) {
        guard job.state == .completed,
              job.configuration.fusionScene != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let executor = WorkspaceModel()
                let materialized = try executor.materializeQueuedScene(
                    job.scene, generatedEnvironmentEXR: job.generatedEnvironmentEXR
                )
                defer { materialized.cleanup() }
                try await executor.prepareQueuedScene(materialized.scene)
                let package = try executor.makeFusionPackageRequest(job: job)
                try FusionScenePackageWriter.refreshComposition(request: package.request)
                status = "Comp Fusion actualizada · \(job.scene.name)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func copyFusionComposition(
        _ job: NativeOutputQueueController.RenderJob,
        to pasteboard: NSPasteboard = .general
    ) {
        guard job.state == .completed,
              job.configuration.fusionScene != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let executor = WorkspaceModel()
                let materialized = try executor.materializeQueuedScene(
                    job.scene, generatedEnvironmentEXR: job.generatedEnvironmentEXR
                )
                defer { materialized.cleanup() }
                try await executor.prepareQueuedScene(materialized.scene)
                let package = try executor.makeFusionPackageRequest(job: job)
                let text = try FusionScenePackageWriter.clipboardCompositionText(
                    request: package.request
                )
                pasteboard.clearContents()
                guard pasteboard.setString(text, forType: .string) else {
                    throw FusionScenePackageError.invalidOutputManifest
                }
                status = "Comp Fusion copiada · \(job.scene.name)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func renderCurrentFrame() {
        guard let metalFrame else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let quality = switch physicalModel.quality {
        case .setup: "Setup"
        case .environmentSetup: "Setup entorno"
        case .focusSetup: "Setup foco"
        case .draft: "Draft"
        case .medium: "Media"
        case .high: "Alta"
        case .native: "Nativa"
        }
        panel.nameFieldStringValue = String(
            format: "ScreenSimulation-%@-%08d.png", quality, currentFrame
        )
        FileDialogDirectory.frameExport.apply(to: panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileDialogDirectory.frameExport.remember(url)
        do {
            try NativeOutputRenderer.renderCurrentFrame(
                frame: metalFrame, displayTransform: previewTransform,
                metadata: currentFrameCheckMetadata(quality: quality, frame: metalFrame),
                destination: url, display: metalDisplay
            )
            status = "Frame \(quality) renderizado · \(url.lastPathComponent)"
        } catch { errorMessage = error.localizedDescription }
    }

    func captureSavedScene() throws -> SavedSceneCapture {
        guard let frame = metalFrame,
              let settingsContext = currentSettingsContext(),
              let selection = currentTestAuthoringSelection()
        else { throw SceneLibraryError.invalidDocument("La escena todavía no tiene un estado completo.") }
        let source: SavedSceneSource
        if sourceIsPattern {
            source = .init(
                kind: .syntheticPattern,
                patternRawValue: selectedPattern.rawValue,
                assets: [],
                missingMedia: nil
            )
        } else {
            let urls = session.sourceURLs
            guard !urls.isEmpty else {
                throw SceneLibraryError.invalidDocument("La fuente externa no está disponible.")
            }
            let assets = urls.map { SavedExternalAsset(absolutePath: $0.path) }
            let raster = originACEScgFrame ?? frame
            source = .init(
                kind: .externalMedia,
                patternRawValue: nil,
                assets: assets,
                missingMedia: .init(
                    originalName: sourceName,
                    width: raster.width,
                    height: raster.height,
                    frameRateNumerator: sourceTimelineInfo.exactFrameRate.numerator,
                    frameRateDenominator: sourceTimelineInfo.exactFrameRate.denominator,
                    frameCount: sourceTimelineInfo.frameCount,
                    durationNumerator: UInt64(sourceTimelineInfo.frameCount)
                        * UInt64(sourceTimelineInfo.exactFrameRate.denominator),
                    durationDenominator: sourceTimelineInfo.exactFrameRate.numerator
                )
            )
        }
        let savedTracking: SavedTrackingScene?
        if let authoredTrackingScene = trackingScene {
            guard let cameraID = selectedTrackingCameraID,
                  let pointGroupID = selectedTrackingPointGroupID,
                  let scale = trackingMetersPerSourceUnit else {
                throw SceneLibraryError.invalidDocument(
                    "Resuelve la cámara, la nube y la escala del tracking antes de guardar la escena."
                )
            }
            savedTracking = .init(
                scene: authoredTrackingScene,
                cameraID: cameraID, pointGroupID: pointGroupID,
                visibleMeshIDs: visibleTrackingMeshIDs.sorted(),
                pointsVisible: trackingPointsVisible,
                geometryVisible: trackingGeometryVisible,
                cameraEnabled: trackingCameraEnabled,
                calibration: .init(
                    unitValue: trackingSynthEyesUnitValue, unit: trackingSynthEyesUnit,
                    metersPerSourceUnit: scale
                )
            )
        } else { savedTracking = nil }
        let snapshot = SavedSceneSnapshot(
            source: source,
            currentFrame: currentFrame,
            viewerZoom: zoom,
            viewerPanX: pan.width,
            viewerPanY: pan.height,
            viewerIsFitted: previewIsFitted,
            authoring: try currentSceneAuthoringDocument(
                settingsContext: settingsContext,
                selection: selection
            ),
            tracking: savedTracking,
            fusionTrackerMotion: fusionTrackerMotion,
            trackingSceneMethod: trackingSceneMethod,
            animation: sceneAnimation
        )
        try snapshot.validate()
        let thumbnail = try SceneThumbnailRenderer.render(
            frame: frame,
            output: previewTransform,
            display: metalDisplay
        )
        return .init(
            snapshot: snapshot,
            thumbnailPNG: thumbnail,
            generatedEnvironmentEXR: generatedReflectionEnvironmentData
        )
    }

    func defaultSceneSnapshot(
        preserving sourceAndReference: SavedSceneSnapshot
    ) throws -> SavedSceneSnapshot {
        try Self.defaultSceneSnapshot(
            preserving: sourceAndReference,
            library: globalLibraryStore.load()
        )
    }

    static func defaultSceneSnapshot(
        preserving sourceAndReference: SavedSceneSnapshot,
        library: GlobalLibraryDocument
    ) throws -> SavedSceneSnapshot {
        try library.validate()
        guard let defaultDevice = library.devices.first?.value else {
            throw SceneLibraryError.invalidDocument(
                "La biblioteca global no contiene el Device inicial de una escena nueva."
            )
        }
        let sourceContext = sourceAndReference.authoring.context
        let frameRate = try sourceAndReference.source.missingMedia?.exactFrameRate ?? .fps24
        let profileContext = try RustTestAuthoringProfileContext(library: library)
        let defaults = try RustTestAuthoringCoordinator.defaultSelection(
            profileContext: profileContext,
            inputTransformID: sourceContext.sourceInputTransformID,
            deviceID: defaultDevice.id,
            frameRate: frameRate
        )
        let authoring = SceneAuthoringDocument(
            profiles: .init(
                deviceID: defaults.deviceID,
                coverGlassID: defaults.coverGlassPresetID,
                captureID: defaults.capturePresetID,
                lensID: defaults.lensPresetID,
                environmentID: defaults.environmentSourceID,
                deliveryID: defaults.deliveryPresetID,
                recordingID: defaults.recordingProfileID
            ),
            overrides: [],
            modelOverrides: .init(screen: nil, stages: []),
            context: .init(
                sourceInputTransformID: sourceContext.sourceInputTransformID,
                sourceAlphaMode: sourceContext.sourceAlphaMode,
                sourceColorModel: sourceContext.sourceColorModel,
                sourceYUVMatrix: sourceContext.sourceYUVMatrix,
                sourceSignalRange: sourceContext.sourceSignalRange,
                sourcePlacementID: sourceContext.sourcePlacementID,
                previewOutputTransformID: "aces2-srgb-sdr-100",
                previewPhaseID: "recording-codec",
                referencePlateID: sourceContext.referencePlateID,
                environmentResource: .init(
                    kind: .procedural,
                    fileName: nil,
                    absolutePath: nil,
                    inputTransformID: nil
                ),
                referenceResource: sourceContext.referenceResource
            ),
            environmentCalibration: nil
        )
        let reset = SavedSceneSnapshot(
            source: sourceAndReference.source,
            currentFrame: 0,
            viewerZoom: 1,
            viewerPanX: 0,
            viewerPanY: 0,
            viewerIsFitted: true,
            authoring: authoring,
            generatedEnvironment: nil,
            tracking: nil,
            fusionTrackerMotion: nil,
            trackingSceneMethod: .fusionComposition
        )
        try reset.validate()
        return reset
    }

    private static let sceneProfileControlIDs: Set<String> = [
        "device", "cover-glass-preset", "capture-preset", "lens-preset",
        "environment-source", "delivery-preset", "recording-profile", "placement",
    ]

    private func currentSceneAuthoringDocument(
        settingsContext: PhysicalSettingsExchange.FrameContext,
        selection: TestAuthoringResolvedSelection
    ) throws -> SceneAuthoringDocument {
        let document = SceneAuthoringDocument(
            profiles: .init(
                deviceID: try requiredSceneDeviceProfileID(),
                coverGlassID: try requiredSceneCoverGlassProfileID(),
                captureID: selectedCapturePresetID ?? selection.capturePresetID,
                lensID: selectedLensPresetID ?? selection.lensPresetID,
                environmentID: selection.environmentSourceID,
                deliveryID: selection.deliveryPresetID,
                recordingID: selection.recordingProfileID
            ),
            overrides: try currentSceneControlOverrides(),
            modelOverrides: currentSceneModelOverrides(),
            context: .init(
                sourceInputTransformID: settingsContext.sourceInputTransformID,
                sourceAlphaMode: settingsContext.sourceAlphaMode,
                sourceColorModel: settingsContext.sourceColorModel,
                sourceYUVMatrix: settingsContext.sourceYUVMatrix,
                sourceSignalRange: settingsContext.sourceSignalRange,
                sourcePlacementID: settingsContext.sourcePlacementID,
                previewOutputTransformID: settingsContext.previewOutputTransformID,
                previewPhaseID: settingsContext.previewPhaseID,
                referencePlateID: settingsContext.referencePlateID,
                environmentResource: settingsContext.environmentResource,
                referenceResource: settingsContext.referenceResource
            ),
            environmentCalibration: environmentSourceCalibration
        )
        try document.validate()
        return document
    }

    private func currentSceneControlOverrides() throws -> [SceneControlOverride] {
        guard let presentation = testPresentation else {
            throw SceneLibraryError.invalidDocument(
                "Application no ha publicado los controles necesarios para guardar overrides."
            )
        }
        let controls = presentation.previewControls + presentation.phases.flatMap {
            $0.sections.flatMap(\.controls)
        }
        let duplicateIDs = Dictionary(grouping: controls, by: \.id).filter { $0.value.count != 1 }
        guard duplicateIDs.isEmpty else {
            throw SceneLibraryError.invalidDocument(
                "Application publicó identidades de control duplicadas."
            )
        }
        return controls.compactMap { descriptor in
            guard !Self.sceneProfileControlIDs.contains(descriptor.id) else { return nil }
            guard explicitSceneOverrideControlIDs.contains(descriptor.id) else { return nil }
            switch descriptor {
            case let .choice(control):
                return .choice(control.id, control.selectedID)
            case let .scalar(control):
                return .scalar(control.id, control.value)
            case let .toggle(control):
                return .toggle(control.id, control.value)
            case .action, .readOnly:
                return nil
            }
        }.sorted { $0.controlID < $1.controlID }
    }

    private func currentSceneModelOverrides() -> SceneModelOverrides {
        let state = physicalModel.authoringState
        let screen = state.screen.storedAmount != 1 || state.screen.isBypassed
            ? state.screen : nil
        let stages = state.stages.filter { stage in
            switch stage.control {
            case let .continuous(value):
                value.storedAmount != 1 || value.isBypassed
            case let .discrete(enabled):
                !enabled
            }
        }
        return .init(screen: screen, stages: stages)
    }

    func openSavedScene(
        _ scene: SavedScene,
        undoManager: UndoManager?
    ) async {
        do {
            // Materialize every strict contract and external resource in an isolated
            // Workspace. The live Workspace remains byte-for-byte untouched until the
            // complete scene is known to be usable.
            let staged = WorkspaceModel(globalLibraryStore: globalLibraryStore)
            try await staged.materializeSavedScene(scene)
            try adoptMaterializedSavedScene(from: staged)
            // `materializeSavedScene` deliberately suppresses Viewer publication while
            // the isolated workspace is loading its source and external resources.
            // Re-publish only after that complete state has become the live scene: the
            // Viewer commit must describe the same resolved frame as the scene-open
            // success notification, never the staged source checkpoint or an empty
            // placeholder that happens to precede it.
            publishMaterializedSceneInitialFrame()
            _ = undoManager // Scene Open deliberately starts a new authoring baseline.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func materializeSavedScene(_ scene: SavedScene) async throws {
        isMaterializingSavedScene = true
        defer { isMaterializingSavedScene = false }
        savedSceneOpenWarnings = []
        try scene.validate()
        let authoring = scene.snapshot.authoring
        try authoring.validate()
        try validateSceneAuthoringResources(authoring)
        try prepareSceneSourceInterpretation(authoring.context)
        let source = scene.snapshot.source
        switch source.kind {
        case .syntheticPattern:
            guard let rawValue = source.patternRawValue,
                  let pattern = SyntheticPattern(rawValue: rawValue)
            else { throw SceneLibraryError.invalidDocument("El patrón de la escena no existe.") }
            choosePattern(pattern, undoManager: nil)
        case .externalMedia:
            let urls = source.assets.map(\.url)
            if urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                errorMessage = nil
                await load(urls, materializeImportInterpretation: false)
            }
            if errorMessage != nil || sourceIsPattern || session.sourceURLs.count != urls.count {
                savedSceneOpenWarnings.append(
                    "Fuente descartada: \(urls.map(\.path).joined(separator: ", "))"
                )
                errorMessage = nil
                choosePattern(.animatedCheckerboard, undoManager: nil)
            }
        }
        try await applySceneAuthoring(authoring, undoManager: nil)
        try restoreTrackingScene(scene.snapshot.tracking)
        try scene.snapshot.fusionTrackerMotion?.validate()
        fusionTrackerMotion = scene.snapshot.fusionTrackerMotion
        trackingSceneMethod = scene.snapshot.trackingSceneMethod
        sceneAnimation = scene.snapshot.animation
        cachedSceneResolver = nil
        // Tracking is part of the timeline authority. Establish it before restoring
        // the authored frame so a static Source plus a Tracker pose track cannot
        // incorrectly clamp the saved frame to zero.
        applyTimelineAuthority(resetRange: true)
        currentFrame = min(scene.snapshot.currentFrame, max(0, frameCount - 1))
        // `load` intentionally opens media at zero so metadata and raster facts
        // can be established first.  A Saved Scene, however, owns an exact current
        // frame: before the staged scene may be adopted, replace that opening sample
        // and its optional reference sample with the saved rational time.
        try await materializeCurrentFrameForSceneOpen()
        applyTrackingCameraAtCurrentFrame()
        try ensureFiniteEnvironmentEnclosesTimeline()
        viewerNavigation.restore(
            zoom: scene.snapshot.viewerZoom,
            pan: .init(width: scene.snapshot.viewerPanX, height: scene.snapshot.viewerPanY),
            isFitted: scene.snapshot.viewerIsFitted
        )
        // The isolated Workspace suppresses Viewer publication, but the committed
        // scene still needs one canonical source checkpoint immediately available.
        if metalFrame == nil { metalFrame = originACEScgFrame }
        activeSceneID = scene.id
        if let generated = scene.snapshot.generatedEnvironment,
           let asset = try EnvironmentAssetLibrary.asset(
               sha256: generated.sha256, originalFileName: generated.fileName
           ) {
            generatedReflectionEnvironmentData = try Data(
                contentsOf: asset.url, options: .mappedIfSafe
            )
        } else {
            generatedReflectionEnvironmentData = nil
        }
        errorMessage = savedSceneOpenWarnings.isEmpty
            ? nil
            : "La escena se abrió, pero se descartaron recursos externos no disponibles:\n\n"
                + savedSceneOpenWarnings.map { "• \($0)" }.joined(separator: "\n")
        status = "Escena abierta · \(scene.name)"
    }

    private func materializeCurrentFrameForSceneOpen() async throws {
        if sourceIsPattern {
            renderPattern()
        } else {
            let time = CMTime(seconds: requestedSeconds, preferredTimescale: 60_000)
            try present(try await session.exactSample(at: time))
        }
        if referenceSourceURL != nil {
            try await rebuildReferenceFrame()
        }
    }

    /// Publishes a fully materialized scene in one synchronous MainActor commit.
    /// No operation in this method decodes media, reads the filesystem or resolves
    /// authored contracts; every fallible operation completed in the staged Workspace.
    private func adoptMaterializedSavedScene(from staged: WorkspaceModel) throws {
        isMaterializingSavedScene = true
        defer { isMaterializingSavedScene = false }

        // Restore the validated model first. All remaining assignments are in-memory
        // transfers and cannot leave a partially decoded external resource behind.
        try physicalModel.restoreAuthoringState(staged.physicalModel.authoringState)
        physicalModel.setQuality(staged.physicalModel.quality)
        previewTransformationsLocked = true

        pause()
        referenceRefreshTask?.cancel()
        referenceRefreshTask = nil
        session = staged.session
        referenceSession = staged.referenceSession

        inputTransform = staged.inputTransform
        previewTransform = staged.previewTransform
        alphaMode = staged.alphaMode
        signalColorModel = staged.signalColorModel
        signalMatrix = staged.signalMatrix
        signalRange = staged.signalRange
        detection = staged.detection
        selectedPattern = staged.selectedPattern
        sourceName = staged.sourceName
        sourceDetail = staged.sourceDetail
        sourceIsPattern = staged.sourceIsPattern
        sourceTimelineInfo = staged.sourceTimelineInfo
        includeAudio = staged.includeAudio
        frameCount = staged.frameCount
        frameRate = staged.frameRate
        inFrame = staged.inFrame
        outFrame = staged.outFrame

        globalLibraryDocument = staged.globalLibraryDocument
        capturePresets = staged.capturePresets
        lensPresets = staged.lensPresets
        environmentPresets = staged.environmentPresets
        testAuthoringProfileContext = staged.testAuthoringProfileContext
        testAuthoringSelection = staged.testAuthoringSelection
        explicitSceneOverrideControlIDs = staged.explicitSceneOverrideControlIDs
        sceneProfileBaselineByControlID = staged.sceneProfileBaselineByControlID
        testPresentation = staged.testPresentation
        testPreviewResultByPhaseID = staged.testPreviewResultByPhaseID
        testPhysicalIntermediateByPhaseID = staged.testPhysicalIntermediateByPhaseID
        selectedCapturePresetID = staged.selectedCapturePresetID
        selectedCaptureRasterModeID = staged.selectedCaptureRasterModeID
        selectedLensPresetID = staged.selectedLensPresetID
        requestedPhysicalIntermediate = staged.requestedPhysicalIntermediate
        resolvedDevice = staged.resolvedDevice
        modelDeviceDefinition = staged.modelDeviceDefinition
        physicalAuthoringState = staged.physicalAuthoringState
        resolvedPhysicalPipeline = staged.resolvedPhysicalPipeline
        baseModelDeviceDefinition = staged.baseModelDeviceDefinition
        basePhysicalAuthoringState = staged.basePhysicalAuthoringState

        originACEScgFrame = staged.originACEScgFrame
        sourceACEScgFrame = staged.sourceACEScgFrame
        metalFrame = staged.metalFrame
        sourceAdjustmentOwner = staged.sourceAdjustmentOwner
        sourcePlacement = staged.sourcePlacement
        deviceSignalCheckpoint = staged.deviceSignalCheckpoint
        recordingCameraCheckpoint = nil
        deliveryRasterCheckpoint = nil
        recordingOutputExecution = nil
        setupFramingRenderer = nil
        publishedSceneIdentity = nil
        publishedResolvedSceneFrame = nil

        environmentRadianceFrame = staged.environmentRadianceFrame
        environmentSourceACEScgFrame = staged.environmentSourceACEScgFrame
        environmentAdjustmentOwner = staged.environmentAdjustmentOwner
        authoredImageEnvironment = staged.authoredImageEnvironment
        environmentSourceName = staged.environmentSourceName
        environmentSourceResolution = staged.environmentSourceResolution
        environmentSourceHash = staged.environmentSourceHash
        environmentSourceInputTransformID = staged.environmentSourceInputTransformID
        environmentSourceURL = staged.environmentSourceURL
        environmentSourceCalibration = staged.environmentSourceCalibration
        generatedReflectionEnvironmentData = staged.generatedReflectionEnvironmentData
        savedSceneOpenWarnings = staged.savedSceneOpenWarnings

        referenceACEScgFrame = staged.referenceACEScgFrame
        referenceForegroundFrame = staged.referenceForegroundFrame
        referenceForegroundIsDeliveryAligned = staged.referenceForegroundIsDeliveryAligned
        referenceSourceURL = staged.referenceSourceURL
        referenceInputTransformID = staged.referenceInputTransformID
        referenceSourceHash = staged.referenceSourceHash
        referenceDetection = staged.referenceDetection
        referenceTimelineInfo = staged.referenceTimelineInfo
        referenceFrameName = staged.referenceFrameName
        referenceFrameDetail = staged.referenceFrameDetail
        referenceInputTransform = staged.referenceInputTransform
        referenceAlphaMode = staged.referenceAlphaMode
        referenceSignalColorModel = staged.referenceSignalColorModel
        referenceSignalMatrix = staged.referenceSignalMatrix
        referenceSignalRange = staged.referenceSignalRange
        referencePlacement = staged.referencePlacement
        referencePlate = staged.referencePlate
        referenceMatchCorners = staged.referenceMatchCorners
        referenceMatchProjectedCorners = staged.referenceMatchProjectedCorners
        referenceMatchErrorPixels = staged.referenceMatchErrorPixels
        referenceMatchEnabled = staged.referenceMatchEnabled

        trackingScene = staged.trackingScene
        selectedTrackingCameraID = staged.selectedTrackingCameraID
        selectedTrackingPointGroupID = staged.selectedTrackingPointGroupID
        trackingCameraEnabled = staged.trackingCameraEnabled
        trackingPointsVisible = staged.trackingPointsVisible
        trackingGeometryVisible = staged.trackingGeometryVisible
        visibleTrackingMeshIDs = staged.visibleTrackingMeshIDs
        trackingSynthEyesUnitValue = staged.trackingSynthEyesUnitValue
        trackingSynthEyesUnit = staged.trackingSynthEyesUnit
        trackingMetersPerSourceUnit = staged.trackingMetersPerSourceUnit
        trackingScaleSelectionSlot = staged.trackingScaleSelectionSlot
        trackingScalePointAID = staged.trackingScalePointAID
        trackingScalePointBID = staged.trackingScalePointBID
        trackingMeasuredDistanceMeters = staged.trackingMeasuredDistanceMeters
        fusionTrackerMotion = staged.fusionTrackerMotion
        trackingSceneMethod = staged.trackingSceneMethod

        currentFrame = staged.currentFrame
        viewerNavigation.restore(
            zoom: staged.zoom,
            pan: staged.pan,
            isFitted: staged.previewIsFitted
        )
        activeSceneID = staged.activeSceneID
        physicalModel.invalidateExternalParameters()
        errorMessage = staged.errorMessage
        status = staged.status
    }

    /// Completes the sole Viewer publication deferred during a transactional scene
    /// Open.  This intentionally follows the same source/checkpoint route as a
    /// normal decoded frame, so Setup, focus, environment, Reference and interactive
    /// physical Preview retain their existing owners.
    private func publishMaterializedSceneInitialFrame() {
        guard let sourceACEScgFrame else {
            publishUnresolvedFrame(nil)
            return
        }
        if !physicalPreviewOwnsViewerPublication {
            publishCurrentSceneFrame(originACEScgFrame ?? sourceACEScgFrame)
            monitorOutput.update(
                frame: originACEScgFrame ?? sourceACEScgFrame,
                display: metalDisplay
            )
        }
        rebuildPhysicalSelectedFrame()
        publishSelectedTestPreview()
    }

    /// Test-visible proof that the Viewer has received a frame carrying the current
    /// resolved-scene identity, rather than merely a staged source texture.
    var hasPublishedResolvedSceneFrame: Bool {
        metalFrame != nil && publishedSceneIdentity != nil
    }

    private func restoreTrackingScene(_ saved: SavedTrackingScene?) throws {
        guard let saved else {
            trackingScene = nil
            selectedTrackingCameraID = nil
            selectedTrackingPointGroupID = nil
            visibleTrackingMeshIDs = []
            clearTrackingScaleCalibration()
            return
        }
        try saved.validate()
        guard saved.scene.cameras.contains(where: { $0.id == saved.cameraID }),
              saved.scene.pointGroups.contains(where: { $0.id == saved.pointGroupID }),
              Set(saved.visibleMeshIDs).isSubset(of: Set(saved.scene.meshes.map(\.id))) else {
            throw SceneLibraryError.invalidDocument("La selección guardada no existe en la composición Fusion.")
        }
        trackingScene = saved.scene
        selectedTrackingCameraID = saved.cameraID
        selectedTrackingPointGroupID = saved.pointGroupID
        visibleTrackingMeshIDs = Set(saved.visibleMeshIDs)
        trackingPointsVisible = saved.pointsVisible
        trackingGeometryVisible = saved.geometryVisible
        trackingCameraEnabled = saved.cameraEnabled
        trackingSynthEyesUnitValue = saved.calibration.unitValue
        trackingSynthEyesUnit = saved.calibration.unit
        trackingMetersPerSourceUnit = saved.calibration.metersPerSourceUnit
        applyTrackingCameraAtCurrentFrame()
    }

    private func currentFrameCheckMetadata(
        quality: String, frame: StudioColorMetalFrame
    ) -> [String: Any] {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "development"
        let capture = capturePresets.first { $0.id == selectedCapturePresetID }
        let contributions: [[String: Any]] = physicalModel.orderedContributions.map { item in
            var value: [String: Any] = [
                "stageID": item.stage.id,
                "domain": item.stage.domain == .screen ? "screen" : "capture",
                "exactIdentityAtZero": item.exactIdentityAtZero,
            ]
            switch item.control {
            case let .continuous(amount, _): value["amount"] = amount
            case let .discrete(enabled): value["enabled"] = enabled
            }
            return value
        }
        let diagnostics: [[String: Any]] = physicalModel.diagnostics.map { item in
            [
                "stageID": item.stage.id,
                "state": String(describing: item.state),
                "progress": item.progress,
                "elapsedNanoseconds": item.elapsedNanoseconds,
                "message": item.message,
            ]
        }
        var physical: [String: Any] = [
            "abiVersion": PhysicalFrameRequest.abiVersion,
            "quality": quality,
            "requestedIntermediate": String(describing: requestedPhysicalIntermediate),
            "screenAmount": physicalModel.screenAmount,
            "screenBypassed": physicalModel.screenIsBypassed,
            "contributions": contributions,
        ]
        if let selectedCapturePresetID { physical["capturePresetID"] = selectedCapturePresetID }
        if let capture { physical["capturePresetName"] = capture.name }
        if let device = modelDeviceDefinition ?? resolvedDevice?.definition,
           let object = FrameCheckPNG.jsonObject(device) {
            physical["device"] = object
        }
        if let state = physicalAuthoringState,
           let object = FrameCheckPNG.jsonObject(state) {
            physical["pipelineParameters"] = object
        }
        var output: [String: Any] = [
            "transformID": previewTransform.id,
            "transformLabel": previewTransform.label,
            "display": previewTransform.display,
            "view": previewTransform.view,
            "declaredSignal": previewTransform.declaredSignalDescription,
            "observedDisplayName": systemDisplayInfo.displayName,
            "observedDisplayProfile": systemDisplayInfo.profileName,
            "observedSystemColorSpace": systemDisplayInfo.systemColorSpaceName,
        ]
        if let colorSpaceName = previewTransform.colorSpace?.name {
            output["embeddedICCColorSpace"] = colorSpaceName as String
        }
        let document: [String: Any] = [
            "schema": FrameCheckPNG.metadataKeyword,
            "schemaVersion": 1,
            "producer": [
                "application": "SCREEN Simulation",
                "implementation": "native-macos-swift-rust-metal",
                "version": appVersion,
                "physicalABI": PhysicalFrameRequest.abiVersion,
            ],
            "frame": [
                "index": currentFrame,
                "fps": frameRate,
                "timeSeconds": Double(currentFrame) / max(frameRate, 1),
                "width": frame.width,
                "height": frame.height,
                "quality": quality,
            ],
            "source": [
                "name": sourceName,
                "detail": sourceDetail,
                "kind": sourceIsPattern ? "synthetic" : "media",
            ],
            "interpretation": [
                "inputTransformID": inputTransform.id,
                "inputTransformLabel": inputTransform.label,
                "alpha": alphaMode.rawValue,
                "colorModel": signalColorModel.rawValue,
                "yuvMatrix": signalMatrix.rawValue,
                "signalRange": signalRange.rawValue,
                "placement": sourcePlacement.rawValue,
                "workingSpace": "ACEScg",
            ],
            "physical": physical,
            "output": output,
            "diagnostics": [
                "status": physicalPublicationSummary,
                "stages": diagnostics,
                "warnings": errorMessage.map { [$0] } ?? [],
            ],
        ]
        return document
    }

    private struct ImportedPhysicalState {
        let device: DeviceDefinition
        let pipeline: PhysicalPipelineAuthoringState
        let model: PhysicalModelAuthoringState
        let context: PhysicalSettingsExchange.FrameContext?
    }

    private func currentSettingsContext() -> PhysicalSettingsExchange.FrameContext? {
        guard let selection = testAuthoringSelection else { return nil }
        return .init(
            selection: selection,
            sourceInputTransformID: inputTransform.id,
            sourceAlphaMode: alphaMode.rawValue,
            sourceColorModel: signalColorModel.rawValue,
            sourceYUVMatrix: signalMatrix.rawValue,
            sourceSignalRange: signalRange.rawValue,
            sourcePlacementID: sourcePlacement.stableID,
            previewOutputTransformID: previewTransform.id,
            previewPhaseID: testPresentation?.selectedPhaseID ?? "recording-codec",
            referencePlateID: referencePlate.rawValue,
            environmentResource: .init(
                kind: environmentRadianceFrame == nil ? .procedural : .image,
                fileName: environmentSourceName,
                absolutePath: environmentSourceURL?.path,
                inputTransformID: environmentSourceInputTransformID
            ),
            referenceResource: .init(
                kind: referenceACEScgFrame == nil ? .none : .imageOrVideo,
                fileName: referenceFrameName,
                absolutePath: referenceSourceURL?.path,
                inputTransformID: referenceInputTransformID,
                alphaMode: referenceACEScgFrame == nil ? nil : referenceAlphaMode.rawValue,
                signalColorModel: referenceACEScgFrame == nil
                    ? nil : referenceSignalColorModel.rawValue,
                signalMatrix: referenceACEScgFrame == nil ? nil : referenceSignalMatrix.rawValue,
                signalRange: referenceACEScgFrame == nil ? nil : referenceSignalRange.rawValue,
                placementID: referenceACEScgFrame == nil ? nil : referencePlacement.stableID,
                corners: referenceMatchCorners.map {
                    .init(x: Double($0.x), y: Double($0.y))
                }
            )
        )
    }

    private func applyPhysicalSettings(
        _ imported: PhysicalSettingsExchange.Imported,
        undoManager: UndoManager?
    ) throws {
        try validatePhysicalSettingsResources(imported)
        let prior: ImportedPhysicalState?
        if undoManager != nil {
            guard let priorDevice = modelDeviceDefinition ?? resolvedDevice?.definition,
                  let priorPipeline = physicalAuthoringState
            else { throw PhysicalSettingsExchange.ImportError.invalidModel }
            prior = ImportedPhysicalState(
                device: priorDevice,
                pipeline: priorPipeline,
                model: physicalModel.authoringState,
                context: currentSettingsContext()
            )
        } else {
            prior = nil
        }
        try restoreImportedPhysicalState(.init(
            device: imported.device,
            pipeline: imported.pipeline,
            model: imported.model,
            context: imported.context
        ))
        if let prior {
            registerUndo(with: undoManager, actionName: "Importar ajustes físicos") { target, manager in
                try? target.exchangeImportedPhysicalState(prior, undoManager: manager)
            }
        }
    }

    private func exchangeImportedPhysicalState(
        _ state: ImportedPhysicalState,
        undoManager: UndoManager?
    ) throws {
        guard let device = modelDeviceDefinition ?? resolvedDevice?.definition,
              let pipeline = basePhysicalAuthoringState
        else { throw PhysicalSettingsExchange.ImportError.invalidModel }
        let inverse = ImportedPhysicalState(
            device: device,
            pipeline: pipeline,
            model: physicalModel.authoringState,
            context: currentSettingsContext()
        )
        try restoreImportedPhysicalState(state)
        registerUndo(with: undoManager, actionName: "Importar ajustes físicos") { target, manager in
            try? target.exchangeImportedPhysicalState(inverse, undoManager: manager)
        }
    }

    private func requiredSceneDeviceProfileID() throws -> String {
        guard let id = modelDeviceDefinition?.id, !id.isEmpty else {
            throw SceneLibraryError.invalidDocument("La escena no tiene un Device seleccionado.")
        }
        return id
    }

    private func requiredSceneCoverGlassProfileID() throws -> String {
        guard let id = physicalAuthoringState?.coverGlass.id, !id.isEmpty else {
            throw SceneLibraryError.invalidDocument(
                "La escena no tiene un Cover Glass seleccionado."
            )
        }
        return id
    }

    private func validatePhysicalSettingsResources(
        _ imported: PhysicalSettingsExchange.Imported
    ) throws {
        if let resource = imported.context?.environmentResource,
           resource.kind == .image {
            guard let path = resource.absolutePath,
                  FileManager.default.fileExists(atPath: path)
            else {
                throw PhysicalSettingsExchange.ImportError.unavailableEnvironmentResource(
                    resource.fileName ?? "sin nombre"
                )
            }
        }
        if let resource = imported.context?.referenceResource,
           resource.kind == .imageOrVideo {
            guard let path = resource.absolutePath,
                  FileManager.default.fileExists(atPath: path)
            else {
                throw PhysicalSettingsExchange.ImportError.unavailableReferenceResource(
                    resource.fileName ?? "sin nombre"
                )
            }
        }
    }

    private func validateSceneAuthoringResources(_ authoring: SceneAuthoringDocument) throws {
        let library = try globalLibraryStore.load()
        guard library.devices.contains(where: { $0.id == authoring.profiles.deviceID }) else {
            throw SceneLibraryError.invalidDocument(
                "La escena requiere el Device \(authoring.profiles.deviceID), que no existe en la biblioteca global."
            )
        }
        guard library.coverGlasses.contains(where: {
            $0.id == authoring.profiles.coverGlassID
        }) else {
            throw SceneLibraryError.invalidDocument(
                "La escena requiere el Cover Glass \(authoring.profiles.coverGlassID), que no existe en la biblioteca global."
            )
        }
        guard library.cameras.contains(where: { $0.id == authoring.profiles.captureID }),
              library.lenses.contains(where: { $0.id == authoring.profiles.lensID })
        else {
            throw SceneLibraryError.invalidDocument(
                "La escena requiere una cámara o lente que ya no existe en la biblioteca global."
            )
        }
        if authoring.context.environmentResource.kind == .procedural {
            guard library.environments.contains(where: {
                $0.id == authoring.profiles.environmentID
            }) else {
                throw SceneLibraryError.invalidDocument(
                    "La escena requiere un entorno que ya no existe en la biblioteca global."
                )
            }
        }
        try authoring.context.environmentResource.validate()
        try authoring.context.referenceResource.validate()
    }

    private func prepareSceneSourceInterpretation(
        _ context: SceneAuthoringContext
    ) throws {
        guard let input = StudioColorInputTransform.catalog.first(where: {
            $0.id == context.sourceInputTransformID
        }), let alpha = StudioAlphaMode(rawValue: context.sourceAlphaMode),
              let colorModel = StudioSignalColorModel(rawValue: context.sourceColorModel),
              let matrix = StudioSignalMatrix(rawValue: context.sourceYUVMatrix),
              let range = StudioSignalRange(rawValue: context.sourceSignalRange)
        else {
            throw SceneLibraryError.invalidDocument(
                "La escena requiere una interpretación de fuente que ya no existe."
            )
        }
        inputTransform = input
        alphaMode = alpha
        signalColorModel = colorModel
        signalMatrix = matrix
        signalRange = range
    }

    private func applySceneAuthoring(
        _ authoring: SceneAuthoringDocument,
        undoManager: UndoManager?
    ) async throws {
        let context = authoring.context
        let library = try globalLibraryStore.load()
        guard let sceneDevice = library.devices.first(where: {
            $0.id == authoring.profiles.deviceID
        })?.value,
        let sceneCoverGlass = library.coverGlasses.first(where: {
            $0.id == authoring.profiles.coverGlassID
        })?.value else {
            throw SceneLibraryError.invalidDocument(
                "La escena requiere un Device o Cover Glass que ya no existe en la biblioteca global."
            )
        }
        guard let output = StudioColorOutputTransform.catalog.first(where: {
            $0.id == context.previewOutputTransformID
        }), let placement = SourcePlacement(stableID: context.sourcePlacementID),
              capturePresets.contains(where: { $0.id == authoring.profiles.captureID }),
              lensPresets.contains(where: { $0.id == authoring.profiles.lensID })
        else {
            throw SceneLibraryError.invalidDocument(
                "La escena requiere un perfil o una opción de catálogo que ya no existe."
            )
        }
        try prepareSceneSourceInterpretation(context)
        previewTransform = output
        sourcePlacement = placement
        try reloadTestAuthoringProfileContext()
        var selection = try materializeSceneSelection(
            authoring,
            profileContext: testAuthoringProfileContext
        )
        var discardedOverrideControlIDs: Set<String> = []
        switch context.environmentResource.kind {
        case .procedural:
            environmentRadianceFrame = nil
            environmentSourceACEScgFrame = nil
            environmentAdjustmentOwner = nil
            authoredImageEnvironment = nil
            environmentSourceName = nil
            environmentSourceResolution = nil
            environmentSourceHash = nil
            environmentSourceInputTransformID = nil
            environmentSourceURL = nil
            environmentSourceCalibration = nil
        case .image:
            guard let path = context.environmentResource.absolutePath,
                  let transform = context.environmentResource.inputTransformID,
                  let calibration = authoring.environmentCalibration else {
                throw SceneLibraryError.invalidDocument(
                    "El HDRI externo no tiene su calibración de radiancia explícita."
                )
            }
            do {
                guard FileManager.default.fileExists(atPath: path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let prepared = try await prepareEnvironmentResource(
                    URL(fileURLWithPath: path),
                    inputTransformID: transform,
                    unitRadiance: calibration.sourceUnitRadianceCandelasPerSquareMeter,
                    exposureStops: calibration.exposureEV,
                    originalFileName: context.environmentResource.fileName,
                    knownHash: nil,
                    adjustmentSelection: selection
                )
                environmentSourceACEScgFrame = prepared.source
                environmentAdjustmentOwner = prepared.adjustment
                environmentRadianceFrame = prepared.radiance
                environmentSourceName = prepared.managed.originalFileName
                environmentSourceResolution = prepared.resolution
                environmentSourceHash = nil
                environmentSourceInputTransformID = transform
                environmentSourceURL = prepared.managed.url
                environmentSourceCalibration = prepared.calibration
                var environment = PhysicalPipelineAuthoringState.Environment()
                environment.sourceKind = 1
                environment.sourceUnitRadianceCandelasPerSquareMeter =
                    calibration.sourceUnitRadianceCandelasPerSquareMeter
                environment.exposureStops = selection.environmentExposureEV
                environment.rotationXDegrees = selection.environmentRotationXDegrees
                environment.rotationYDegrees = selection.environmentRotationYDegrees
                environment.placementAnchorDirectionWorld = Self.environmentDirection(
                    longitudeDegrees: selection.environmentAnchorLongitudeDegrees,
                    latitudeDegrees: selection.environmentAnchorLatitudeDegrees
                )
                environment.placementSourceDirection = Self.environmentDirection(
                    longitudeDegrees: selection.environmentRotationYDegrees,
                    latitudeDegrees: -selection.environmentRotationXDegrees
                )
                environment.placementTangentTransform = selection.environmentTangentTransform
                environment.projectionMode = selection.environmentProjectionID == "finite-sphere"
                    ? 1 : 0
                environment.sphereCenterMeters = [
                    selection.environmentSphereCenterXMeters,
                    selection.environmentSphereCenterYMeters,
                    selection.environmentSphereCenterZMeters,
                ]
                environment.sphereRadiusMeters = selection.environmentSphereRadiusMeters
                authoredImageEnvironment = environment
            } catch {
                savedSceneOpenWarnings.append("HDRI descartado: \(path)")
                environmentRadianceFrame = nil
                environmentSourceACEScgFrame = nil
                environmentAdjustmentOwner = nil
                authoredImageEnvironment = nil
                environmentSourceName = nil
                environmentSourceResolution = nil
                environmentSourceHash = nil
                environmentSourceInputTransformID = nil
                environmentSourceURL = nil
                environmentSourceCalibration = nil
                selection = try RustTestAuthoringCoordinator.apply(
                    .setChoice(
                        controlID: "environment-source",
                        optionID: authoring.profiles.environmentID
                    ),
                    to: selection,
                    profileContext: testAuthoringProfileContext
                )
                discardedOverrideControlIDs.insert("environment-source")
            }
        }
        try applyTestAuthoringSelection(
            selection,
            profileDevice: sceneDevice,
            profileCoverGlass: sceneCoverGlass
        )
        try physicalModel.restoreSceneOverrides(authoring.modelOverrides)
        if let quality = PhysicalQuality(stableID: selection.previewQualityID) {
            physicalModel.setQuality(quality)
        }
        explicitSceneOverrideControlIDs = Set(authoring.overrides.map(\.controlID))
            .subtracting(discardedOverrideControlIDs)
        physicalModel.invalidateExternalParameters()
        // Resource pixels are intentionally external and are restored only through their exact
        // authored path and interpretation, never through a library copy or hash lookup.
        guard let savedReferencePlate = ReferencePlate(rawValue: context.referencePlateID) else {
            throw SceneLibraryError.invalidDocument("La placa de referencia guardada no es compatible.")
        }
        referencePlate = savedReferencePlate
        switch context.referenceResource.kind {
        case .none:
            referenceACEScgFrame = nil
            referenceForegroundFrame = nil
            referenceSourceURL = nil
            referenceFrameName = nil
        case .imageOrVideo:
            guard let path = context.referenceResource.absolutePath,
                  let name = context.referenceResource.fileName,
                  let transform = context.referenceResource.inputTransformID,
                  let input = StudioColorInputTransform.catalog.first(where: { $0.id == transform }),
                  let alphaRaw = context.referenceResource.alphaMode,
                  let alpha = StudioAlphaMode(rawValue: alphaRaw),
                  let colorRaw = context.referenceResource.signalColorModel,
                  let color = StudioSignalColorModel(rawValue: colorRaw),
                  let matrixRaw = context.referenceResource.signalMatrix,
                  let matrix = StudioSignalMatrix(rawValue: matrixRaw),
                  let rangeRaw = context.referenceResource.signalRange,
                  let range = StudioSignalRange(rawValue: rangeRaw),
                  let placementRaw = context.referenceResource.placementID,
                  let referencePlacement = SourcePlacement(stableID: placementRaw)
            else { throw SceneLibraryError.invalidDocument("La referencia guardada no es compatible.") }
            do {
                guard FileManager.default.fileExists(atPath: path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let asset = ManagedReferenceAsset(
                    url: URL(fileURLWithPath: path), originalFileName: name
                )
                referenceSourceURL = asset.url
                referenceInputTransformID = transform
                referenceInputTransform = input
                referenceAlphaMode = alpha
                referenceSignalColorModel = color
                referenceSignalMatrix = matrix
                referenceSignalRange = range
                self.referencePlacement = referencePlacement
                referenceFrameName = name
                referenceMatchCorners = context.referenceResource.corners.map {
                    CGPoint(x: $0.x, y: $0.y)
                }
                try await loadManagedReferenceFrame(asset, keepAuthoredCorners: true)
            } catch {
                savedSceneOpenWarnings.append("Referencia descartada: \(path)")
                referenceSession.reset()
                referenceACEScgFrame = nil
                referenceForegroundFrame = nil
                referenceForegroundIsDeliveryAligned = false
                referenceSourceURL = nil
                referenceInputTransformID = nil
                referenceSourceHash = nil
                referenceTimelineInfo = nil
                referenceFrameName = nil
                referenceFrameDetail = nil
                self.referencePlacement = .fit
                referenceMatchCorners = []
                referenceMatchProjectedCorners = []
                referenceMatchErrorPixels = nil
                referenceMatchEnabled = false
                if referencePlate == .videoReference { referencePlate = .vfxChecker }
            }
        }
        _ = undoManager // Opening a scene deliberately starts a new authoring baseline.
    }

    private func materializeSceneSelection(
        _ authoring: SceneAuthoringDocument,
        profileContext: RustTestAuthoringProfileContext
    ) throws -> TestAuthoringResolvedSelection {
        try Self.materializeSceneSelection(
            authoring,
            profileContext: profileContext,
            inputTransformID: inputTransform.id,
            frameRate: ReferenceTimelineAuthority.resolve(
                source: sourceTimelineInfo,
                reference: referenceTimelineInfo,
                referenceVisible: referenceControlsTimeline,
                tracking: trackingTimelineInfo
            ).exactFrameRate
        )
    }

    private static func materializeSceneSelection(
        _ authoring: SceneAuthoringDocument,
        profileContext: RustTestAuthoringProfileContext,
        inputTransformID: String,
        frameRate: ExactFrameRate
    ) throws -> TestAuthoringResolvedSelection {
        var selection = try RustTestAuthoringCoordinator.defaultSelection(
            profileContext: profileContext,
            inputTransformID: inputTransformID,
            deviceID: authoring.profiles.deviceID,
            frameRate: frameRate
        )
        let profileIntents: [TestControlIntent] = [
            .setChoice(controlID: "capture-preset", optionID: authoring.profiles.captureID),
            .setChoice(controlID: "lens-preset", optionID: authoring.profiles.lensID),
            .setChoice(controlID: "cover-glass-preset", optionID: authoring.profiles.coverGlassID),
            .setChoice(controlID: "environment-source", optionID: authoring.profiles.environmentID),
            .setChoice(controlID: "delivery-preset", optionID: authoring.profiles.deliveryID),
            .setChoice(controlID: "recording-profile", optionID: authoring.profiles.recordingID),
            .setChoice(controlID: "placement", optionID: authoring.context.sourcePlacementID),
        ]
        for intent in profileIntents {
            selection = try RustTestAuthoringCoordinator.apply(
                intent, to: selection, profileContext: profileContext
            )
        }

        // Geometry mode owns the representation of the camera pose. Entering Free derives
        // an initial pose from Look At, so it must be materialized before the persisted Free
        // position and rotation values; persisted lexical order has no semantic authority.
        let orderedOverrides = authoring.overrides.sorted { lhs, rhs in
            let lhsPriority = lhs.controlID == "geometry-mode" ? 0 : 1
            let rhsPriority = rhs.controlID == "geometry-mode" ? 0 : 1
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return lhs.controlID < rhs.controlID
        }
        for override in orderedOverrides {
            selection = try RustTestAuthoringCoordinator.apply(
                override.intent, to: selection,
                profileContext: profileContext
            )
        }
        return selection
    }

    func sceneSettingsOwnership(
        source: SavedSceneSnapshot,
        destination: SavedSceneSnapshot
    ) throws -> SceneSettingsOwnership {
        let library = try globalLibraryStore.load()
        let profileContext = try RustTestAuthoringProfileContext(library: library)
        let presentations = try [source, destination].map { snapshot in
            let frameRate = try snapshot.source.missingMedia?.exactFrameRate ?? .fps24
            let selection = try Self.materializeSceneSelection(
                snapshot.authoring,
                profileContext: profileContext,
                inputTransformID: snapshot.authoring.context.sourceInputTransformID,
                frameRate: frameRate
            )
            return try RustTestAuthoringCoordinator.snapshot(
                profileContext: profileContext,
                selection: selection,
                selectedPreviewPhaseID: snapshot.authoring.context.previewPhaseID
            ).presentation
        }
        return try SceneSettingsOwnership(presentations: presentations)
    }

    private func sceneProfileBaselines(
        device: DeviceDefinition,
        coverGlass: CoverGlassDefinition
    ) -> [String: SceneControlOverride] {
        let values: [SceneControlOverride] = [
            .choice("color-mode", device.colorModeID),
            .scalar("white-luminance", device.whiteLevelNits),
            .scalar("panel-uniformity-amount", device.panelUniformity.characterStrength),
            .scalar("panel-light-spread-amount", device.panelLightSpread.characterStrength),
            .scalar("cover-glass-amount", coverGlass.characterStrength),
            .scalar("cover-ag-microtexture-amount", coverGlass.agMicrotextureCharacterStrength),
            .scalar("cover-thickness-millimeters", coverGlass.thicknessMillimeters),
            .scalar("cover-refractive-index", coverGlass.refractiveIndex),
            .scalar("cover-ar-efficiency", coverGlass.antiReflectiveEfficiency),
            .scalar("cover-absorption-r", coverGlass.absorptionPerMillimeter[0]),
            .scalar("cover-absorption-g", coverGlass.absorptionPerMillimeter[1]),
            .scalar("cover-absorption-b", coverGlass.absorptionPerMillimeter[2]),
            .scalar("cover-roughness", coverGlass.roughness),
            .scalar("cover-haze", coverGlass.haze),
            .scalar("cover-ag-rms-slope", coverGlass.agMicrotextureRMSSlope),
            .scalar("cover-ag-correlation-micrometers", coverGlass.agMicrotextureCorrelationLengthMicrometers),
            .scalar("cover-ag-anisotropy", coverGlass.agMicrotextureAnisotropy),
            .scalar("cover-glow-amount", coverGlass.glowCharacterStrength),
            .scalar("cover-glow-intensity", coverGlass.glowIntensity),
            .scalar("cover-glow-radius-millimeters", coverGlass.glowRadiusMillimeters),
            .scalar("cover-glow-threshold-relative-white", coverGlass.glowThresholdRelativeWhite),
        ]
        return Dictionary(uniqueKeysWithValues: values.map { ($0.controlID, $0) })
    }

    private func restoreImportedPhysicalState(_ state: ImportedPhysicalState) throws {
        resolvedDevice = try state.device.resolved()
        resolvedPhysicalPipeline = try state.pipeline.resolvedPipeline()
        try physicalModel.restoreAuthoringState(state.model)
        modelDeviceDefinition = state.device
        physicalAuthoringState = state.pipeline
        baseModelDeviceDefinition = state.device
        basePhysicalAuthoringState = state.pipeline
        if let context = state.context {
            guard let input = StudioColorInputTransform.catalog.first(where: {
                $0.id == context.sourceInputTransformID
            }), let output = StudioColorOutputTransform.catalog.first(where: {
                $0.id == context.previewOutputTransformID
            }), let placement = SourcePlacement(stableID: context.sourcePlacementID),
                let alpha = StudioAlphaMode(rawValue: context.sourceAlphaMode),
                let colorModel = StudioSignalColorModel(rawValue: context.sourceColorModel),
                let matrix = StudioSignalMatrix(rawValue: context.sourceYUVMatrix),
                let range = StudioSignalRange(rawValue: context.sourceSignalRange),
                let quality = PhysicalQuality(stableID: context.selection.previewQualityID),
                capturePresets.contains(where: { $0.id == context.selection.capturePresetID }),
                lensPresets.contains(where: { $0.id == context.selection.lensPresetID })
            else { throw PhysicalSettingsExchange.ImportError.invalidModel }
            let snapshot = try RustTestAuthoringCoordinator.snapshot(
                profileContext: testAuthoringProfileContext,
                selection: context.selection,
                selectedPreviewPhaseID: context.previewPhaseID
            )
            inputTransform = input
            previewTransform = output
            sourcePlacement = placement
            alphaMode = alpha
            signalColorModel = colorModel
            signalMatrix = matrix
            signalRange = range
            switch context.environmentResource.kind {
            case .procedural:
                environmentRadianceFrame = nil
                authoredImageEnvironment = nil
                environmentSourceName = nil
                environmentSourceResolution = nil
                environmentSourceHash = nil
                environmentSourceInputTransformID = nil
                environmentSourceURL = nil
                environmentSourceCalibration = nil
                generatedReflectionEnvironmentData = nil
            case .image:
                authoredImageEnvironment = state.pipeline.environment
                environmentSourceName = context.environmentResource.fileName
                environmentSourceHash = nil
                environmentSourceInputTransformID = context.environmentResource.inputTransformID
                if let path = context.environmentResource.absolutePath,
                   let name = context.environmentResource.fileName,
                   let transform = context.environmentResource.inputTransformID,
                   FileManager.default.fileExists(atPath: path) {
                    let url = URL(fileURLWithPath: path)
                    environmentSourceURL = url
                    Task { [weak self] in
                        await self?.loadEnvironment(
                            url,
                            inputTransformID: transform,
                            unitRadiance: state.pipeline.environment
                                .sourceUnitRadianceCandelasPerSquareMeter,
                            exposureStops: state.pipeline.environment.exposureStops,
                            originalFileName: name
                        )
                    }
                }
            }
            switch context.referenceResource.kind {
            case .none:
                referenceACEScgFrame = nil
                referenceForegroundFrame = nil
                referenceForegroundIsDeliveryAligned = false
                referenceSourceURL = nil
                referenceInputTransformID = nil
                referenceSourceHash = nil
                referenceTimelineInfo = nil
                referenceFrameName = nil
                referenceFrameDetail = nil
                referencePlacement = .fit
                referenceMatchCorners = []
                referenceMatchProjectedCorners = []
                referenceMatchEnabled = false
            case .imageOrVideo:
                guard let path = context.referenceResource.absolutePath,
                      let name = context.referenceResource.fileName,
                      let transform = context.referenceResource.inputTransformID,
                      let input = StudioColorInputTransform.catalog.first(where: {
                          $0.id == transform
                      }),
                      let alphaRaw = context.referenceResource.alphaMode,
                      let alpha = StudioAlphaMode(rawValue: alphaRaw),
                      let colorRaw = context.referenceResource.signalColorModel,
                      let colorModel = StudioSignalColorModel(rawValue: colorRaw),
                      let matrixRaw = context.referenceResource.signalMatrix,
                      let matrix = StudioSignalMatrix(rawValue: matrixRaw),
                      let rangeRaw = context.referenceResource.signalRange,
                      let range = StudioSignalRange(rawValue: rangeRaw),
                      let placementRaw = context.referenceResource.placementID,
                      let referencePlacement = SourcePlacement(stableID: placementRaw),
                      FileManager.default.fileExists(atPath: path)
                else {
                    throw PhysicalSettingsExchange.ImportError.unavailableReferenceResource(
                        context.referenceResource.fileName ?? "sin nombre"
                    )
                }
                let asset = ManagedReferenceAsset(
                    url: URL(fileURLWithPath: path), originalFileName: name
                )
                referenceSourceURL = asset.url
                referenceInputTransformID = transform
                referenceInputTransform = input
                referenceAlphaMode = alpha
                referenceSignalColorModel = colorModel
                referenceSignalMatrix = matrix
                referenceSignalRange = range
                self.referencePlacement = referencePlacement
                referenceSourceHash = nil
                referenceFrameName = name
                referenceMatchCorners = context.referenceResource.corners.map {
                    CGPoint(x: $0.x, y: $0.y)
                }
                referenceMatchEnabled = false
                referenceMatchProjectedCorners = []
                Task { [weak self] in
                    do {
                        try await self?.loadManagedReferenceFrame(
                            asset, keepAuthoredCorners: true
                        )
                    } catch {
                        self?.errorMessage = error.localizedDescription
                    }
                }
            }
            testAuthoringSelection = context.selection
            selectedCapturePresetID = context.selection.capturePresetID
            selectedCaptureRasterModeID = context.selection.captureRasterModeID
            selectedLensPresetID = context.selection.lensPresetID
            testPresentation = snapshot.presentation
            testPreviewResultByPhaseID = snapshot.previewResultByPhaseID
            testPhysicalIntermediateByPhaseID = snapshot.physicalIntermediateByPhaseID
            physicalModel.setQuality(quality)
            if !sourceIsPattern, !session.sourceURLs.isEmpty {
                reconfigureSourceDecode()
            }
        }
        resolvedDevice = try state.device.resolved()
        resolvedPhysicalPipeline = try state.pipeline.resolvedPipeline()
        try physicalModel.restoreAuthoringState(state.model)
        modelDeviceDefinition = state.device
        physicalAuthoringState = state.pipeline
        baseModelDeviceDefinition = state.device
        basePhysicalAuthoringState = state.pipeline
        physicalModel.invalidateExternalParameters()
    }

    private func loadManagedReferenceFrame(
        _ managed: ManagedReferenceAsset,
        keepAuthoredCorners: Bool
    ) async throws {
        let isVideo = Self.isVideo(managed.url)
        referenceDetection = await StudioMediaMetadataDetector.detect(
            url: managed.url, isVideo: isVideo
        )
        let info = isVideo
            ? try await referenceSession.openVideo(
                managed.url,
                hasAlpha: referenceDetection.hasAlpha,
                colorModel: referenceSignalColorModel,
                matrix: referenceSignalMatrix,
                decodedRange: referenceSignalRange
            )
            : try referenceSession.openImages([managed.url], frameRate: .fps24)
        try await rebuildReferenceFrame()
        guard referenceACEScgFrame != nil else {
            throw SceneLibraryError.invalidDocument(
                "La referencia externa no produjo un frame ACEScg válido."
            )
        }
        referenceForegroundFrame = nil
        referenceForegroundIsDeliveryAligned = false
        referenceFrameDetail = info.detail
        referenceTimelineInfo = isVideo
            ? NativeVideoTimelineInfo(
                exactFrameRate: info.exactFrameRate,
                frameCount: info.frameCount
            )
            : nil
        applyTimelineAuthority(resetRange: true)
        if !isMaterializingSavedScene {
            publishReferenceMatchSetup(
                resetTargetsToVisibleFrame: !keepAuthoredCorners || referenceMatchCorners.count != 4
            )
        }
    }

    private func confirmPhysicalSettingsImport(_ report: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Importar ajustes físicos"
        alert.informativeText = "Se aplicará el snapshot completo. Solo zoom, pan y transporte no cambiarán."
        alert.addButton(withTitle: "Importar")
        alert.addButton(withTitle: "Cancelar")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.string = report
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = text
        alert.accessoryView = scroll
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func tickPlayback() {
        let completedMilliseconds = metalDisplay.lastCompletedEndToEndMilliseconds
        if completedMilliseconds > 0,
           decodeToPreviewMilliseconds != completedMilliseconds {
            decodeToPreviewMilliseconds = completedMilliseconds
        }
        guard isPlaying else { return }
        if referenceControlsTimeline, let started = referencePlaybackStartedAt {
            let elapsed = max(0, CACurrentMediaTime() - started)
            let target = referencePlaybackStartFrame + Int((elapsed * frameRate).rounded(.down))
            if target > activeFrameRange.upperBound {
                if loopPlayback {
                    restartPlayback(at: activeFrameRange.lowerBound)
                } else {
                    currentFrame = activeFrameRange.upperBound
                    pause()
                }
                return
            }
            guard target != currentFrame else { return }
            currentFrame = target
            if sourceIsPattern {
                renderPattern()
            } else {
                renderCurrentMediaFrame(at: CMTime(
                    seconds: requestedSeconds, preferredTimescale: 60_000
                ))
            }
            refreshReferenceFrameForCurrentTime()
            return
        }
        if currentFrame >= activeFrameRange.upperBound {
            if loopPlayback {
                restartPlayback(at: activeFrameRange.lowerBound)
            } else {
                pause()
            }
            return
        }
        if sourceIsPattern {
            let next = currentFrame + 1
            currentFrame = next
            renderPattern()
            refreshReferenceFrameForCurrentTime()
            return
        }
        renderCurrentMediaFrame()
        refreshReferenceFrameForCurrentTime()
    }

    private func refreshReferenceFrameForCurrentTime() {
        guard let url = referenceSourceURL, Self.isVideo(url)
        else { return }
        referenceRefreshTask?.cancel()
        referenceRefreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.rebuildReferenceFrame()
                try Task.checkCancellation()
                guard self.referenceSourceURL == url else { return }
                if self.referenceMatchEnabled || self.physicalModel.quality == .setup {
                    self.publishReferenceMatchSetup(resetTargetsToVisibleFrame: false)
                } else if let foreground = self.referenceForegroundFrame {
                    self.publishReferenceComposite(foreground)
                } else {
                    self.publishReferenceMatchSetup(resetTargetsToVisibleFrame: false)
                }
            } catch is CancellationError {
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Queue setup cannot rely on the interactive reference-loading task: the Fusion package
    /// needs this exact raster before it can resolve a portable Delivery Raster.
    private func prepareQueuedReferenceRaster() async throws {
        guard let url = referenceSourceURL else { return }
        let isVideo = Self.isVideo(url)
        referenceDetection = await StudioMediaMetadataDetector.detect(url: url, isVideo: isVideo)
        if isVideo {
            _ = try await referenceSession.openVideo(
                url,
                hasAlpha: referenceDetection.hasAlpha,
                colorModel: referenceSignalColorModel,
                matrix: referenceSignalMatrix,
                decodedRange: referenceSignalRange
            )
        } else {
            _ = try referenceSession.openImages([url], frameRate: .fps24)
        }
        try await rebuildReferenceFrame()
    }

    private func rebuildReferenceFrame() async throws {
        guard let sample = try await referenceSession.exactSample(
            at: CMTime(seconds: requestedSeconds, preferredTimescale: 60_000)
        ) else { throw NativeMediaError.invalidRaster }
        referenceACEScgFrame = try metalDisplay.makeACEScgFrame(
            pixelBuffer: sample.pixelBuffer,
            input: referenceInputTransform,
            alpha: referenceEffectiveAlpha,
            matrix: referenceEffectiveMatrix,
            range: referenceEffectiveRange
        )
    }

    private func rebuildReferenceFrameAndPublish() async throws {
        try await rebuildReferenceFrame()
        if referenceMatchEnabled || physicalModel.quality == .setup {
            publishReferenceMatchSetup(resetTargetsToVisibleFrame: false)
        } else if let foreground = referenceForegroundFrame {
            publishReferenceComposite(foreground)
        } else {
            publishReferenceMatchSetup(resetTargetsToVisibleFrame: false)
        }
    }

    private func restartPlayback(at frame: Int) {
        currentFrame = frame
        if referenceControlsTimeline {
            referencePlaybackStartFrame = frame
            referencePlaybackStartedAt = CACurrentMediaTime()
            isPlaying = true
            if sourceIsPattern {
                renderPattern()
            } else {
                renderCurrentMediaFrame(at: CMTime(
                    seconds: requestedSeconds, preferredTimescale: 60_000
                ))
            }
            refreshReferenceFrameForCurrentTime()
            return
        }
        if sourceIsPattern {
            isPlaying = true
            renderPattern()
            return
        }
        Task {
            do {
                let time = CMTime(seconds: requestedSeconds, preferredTimescale: 60_000)
                try await session.seek(to: time)
                try present(try await session.exactSample(at: time))
                session.play()
                isPlaying = true
            } catch {
                pause()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func rebuildCurrent() {
        if sourceIsPattern {
            renderPattern()
        } else {
            renderCurrentMediaFrame(at: CMTime(
                seconds: requestedSeconds,
                preferredTimescale: 60_000
            ))
        }
    }

    private func renderPattern() {
        let started = CACurrentMediaTime()
        do {
            let decoded = try selectedPattern.frame(time: requestedSeconds)
            let base = try metalDisplay.makeACEScgFrame(
                width: decoded.width, height: decoded.height, encodedRGBA: decoded.rgba,
                input: inputTransform, alpha: effectiveAlpha
            )
            originACEScgFrame = base
            sourceACEScgFrame = try adjustedSourceFrame(base)
            physicalModel.invalidateExternalParameters()
            sourceDetail = "Patrón SCREEN canónico · \(decoded.width) × \(decoded.height)"
            guard !isMaterializingSavedScene else { return }
            if !physicalPreviewOwnsViewerPublication {
                publishCurrentSceneFrame(base)
                monitorOutput.update(frame: base, display: metalDisplay)
            }
            decodeToPreviewMilliseconds = (CACurrentMediaTime() - started) * 1_000
            status = "Textura ACEScg Metal · \(decodeToPreviewMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
            rebuildPhysicalSelectedFrame()
            publishSelectedTestPreview()
        } catch {
            publishUnresolvedFrame(nil)
            errorMessage = error.localizedDescription
        }
    }

    private func renderCurrentMediaFrame(at time: CMTime? = nil) {
        let started = CACurrentMediaTime()
        do {
            guard let sample = try session.currentSample(at: time) else { return }
            try present(sample, started: started)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func present(_ sample: NativeMediaSample?, started: CFTimeInterval = CACurrentMediaTime()) throws {
        guard let sample else { return }
        let base = try metalDisplay.makeACEScgFrame(
            pixelBuffer: sample.pixelBuffer, input: inputTransform,
            alpha: effectiveAlpha, matrix: effectiveMatrix, range: effectiveRange
        )
        originACEScgFrame = base
        sourceACEScgFrame = try adjustedSourceFrame(base)
        physicalModel.invalidateExternalParameters()
        currentFrame = min(frameCount - 1, max(0, Int((sample.time.seconds * frameRate).rounded())))
        guard !isMaterializingSavedScene else { return }
        if !physicalPreviewOwnsViewerPublication {
            publishCurrentSceneFrame(base)
            monitorOutput.update(frame: base, display: metalDisplay)
        }
        decodeToPreviewMilliseconds = (CACurrentMediaTime() - started) * 1_000
        status = "CVPixelBuffer → ACEScg → Preview · \(decodeToPreviewMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
        rebuildPhysicalSelectedFrame()
        publishSelectedTestPreview()
    }

    private func adjustedSourceFrame(_ origin: StudioColorMetalFrame) throws -> StudioColorMetalFrame {
        let selection = testAuthoringSelection
        let parameters = SceneAdjustmentParameters(
            exposureEV: selection?.sourceExposureEV ?? 0,
            contrast: selection?.sourceContrast ?? 1,
            saturation: selection?.sourceSaturation ?? 1,
            temperatureKelvin: selection?.sourceTemperatureKelvin ?? 6500,
            tint: selection?.sourceTint ?? 0
        )
        let owner = try SceneAdjustmentFrame(
            source: origin, parameters: parameters, incidentRadiance: false
        )
        sourceAdjustmentOwner = owner
        return owner.frame
    }

    private func renderFrame(_ index: Int) async throws -> StudioColorMetalFrame {
        let rate = ReferenceTimelineAuthority.resolve(
            source: sourceTimelineInfo,
            reference: referenceTimelineInfo,
            referenceVisible: referenceControlsTimeline,
            tracking: trackingTimelineInfo
        ).exactFrameRate
        let numerator = Int64(index) * Int64(rate.denominator)
        return try await renderFrame(
            at: PhysicalRationalTime(
                numerator: numerator,
                denominator: rate.numerator
            )
        )
    }

    private func renderFrame(
        at time: PhysicalRationalTime
    ) async throws -> StudioColorMetalFrame {
        let seconds = Double(time.numerator) / Double(time.denominator)
        if sourceIsPattern {
            let decoded = try selectedPattern.frame(time: seconds)
            let base = try metalDisplay.makeACEScgFrame(
                width: decoded.width, height: decoded.height,
                encodedRGBA: decoded.rgba, input: inputTransform, alpha: effectiveAlpha
            )
            return try adjustedSourceFrame(base)
        }
        let time = CMTime(
            value: CMTimeValue(time.numerator),
            timescale: CMTimeScale(time.denominator)
        )
        try Task.checkCancellation()
        guard let sample = try await session.exactSample(at: time) else {
            throw NativeMediaError.unreadable("time \(seconds)")
        }
        let base = try metalDisplay.makeACEScgFrame(
            pixelBuffer: sample.pixelBuffer, input: inputTransform,
            alpha: effectiveAlpha, matrix: effectiveMatrix, range: effectiveRange
        )
        return try adjustedSourceFrame(base)
    }

    private func rebuildPhysicalSelectedFrame() {
        guard !isMaterializingSavedScene else { return }
        // An empty workspace has no physical scene to evaluate. This is an explicit editor
        // state, not a malformed scene request; the request boundary is reached only after
        // Device and base authoring have both been selected.
        guard resolvedDevice != nil, basePhysicalAuthoringState != nil else {
            _ = physicalInteractiveJob?.cancel()
            physicalInteractiveTask?.cancel()
            return
        }
        let testNeedsPhysicalResult = isTestPageActive
            && selectedTestPhysicalIntermediate != nil
        guard isModelPageActive || testNeedsPhysicalResult || setupOwnsViewerPublication else {
            _ = physicalInteractiveJob?.cancel()
            physicalInteractiveTask?.cancel()
            return
        }
        if referenceMatchEnabled, referencePlateUsesVideo {
            _ = physicalInteractiveJob?.cancel()
            physicalInteractiveTask?.cancel()
            publishReferenceMatchSetup(resetTargetsToVisibleFrame: referenceMatchCorners.count != 4)
            return
        }
        if reflectionEnvironmentEditorEnabled {
            _ = physicalInteractiveJob?.cancel()
            physicalInteractiveTask?.cancel()
            if referencePlateUsesVideo {
                publishReferenceMatchSetup(resetTargetsToVisibleFrame: false)
            } else {
                publishSetupFraming()
            }
            return
        }
        if physicalModel.quality == .setup {
            _ = physicalInteractiveJob?.cancel()
            physicalInteractiveTask?.cancel()
            if referencePlateUsesVideo {
                publishReferenceMatchSetup(resetTargetsToVisibleFrame: referenceMatchCorners.count != 4)
            } else {
                publishSetupFraming()
            }
            return
        }
        if physicalModel.quality == .environmentSetup {
            _ = physicalInteractiveJob?.cancel()
            physicalInteractiveTask?.cancel()
            publishEnvironmentSetup()
            return
        }
        if physicalModel.quality == .focusSetup {
            _ = physicalInteractiveJob?.cancel()
            physicalInteractiveTask?.cancel()
            publishFocusSetup()
            return
        }
        guard physicalModel.quality != .native else { return }
        recordingCameraCheckpoint = nil
        deliveryRasterCheckpoint = nil
        recordingOutputExecution = nil
        recordingEncodedBytes = nil
        recordingEncodedSHA256 = nil
        _ = physicalInteractiveJob?.cancel()
        physicalInteractiveTask?.cancel()
        let quality = physicalModel.quality
        physicalInteractiveTask = Task { [weak self] in
            guard let self else { return }
            var submittedJob: PhysicalMetalFrameJob?
            do {
                let submission = try await submitPhysicalJob(quality: quality)
                submittedJob = submission.job
                physicalInteractiveJob = submission.job
                try await pollPhysicalJob(
                    submission,
                    native: false
                )
            } catch is CancellationError {
                // A newer parameter revision owns the next authoritative result.
            } catch {
                status = error.localizedDescription
                physicalPublicationSummary = "Falló · \(error.localizedDescription)"
                physicalPublicationLog.error("physical job failed: \(error.localizedDescription, privacy: .public)")
            }
            if physicalInteractiveJob === submittedJob {
                physicalInteractiveJob = nil
            }
        }
    }

    /// Workspace navigation has no authority to select or evaluate a physical
    /// checkpoint. Returning to Scene restores the publication already owned by
    /// the active mode and routes any cached physical foreground through the
    /// canonical Reference provider.
    private func restoreSceneViewerPublication() {
        if referenceMatchEnabled, referencePlateUsesVideo {
            publishReferenceMatchSetup(
                resetTargetsToVisibleFrame: referenceMatchCorners.count != 4
            )
            return
        }
        if reflectionEnvironmentEditorEnabled {
            if referencePlateUsesVideo {
                publishReferenceMatchSetup(resetTargetsToVisibleFrame: false)
            } else {
                publishSetupFraming()
            }
            return
        }
        switch physicalModel.quality {
        case .setup:
            if referencePlateUsesVideo {
                publishReferenceMatchSetup(
                    resetTargetsToVisibleFrame: referenceMatchCorners.count != 4
                )
            } else {
                publishSetupFraming()
            }
        case .environmentSetup:
            publishEnvironmentSetup()
        case .focusSetup:
            publishFocusSetup()
        case .draft, .medium, .high, .native:
            guard let foreground = referenceForegroundFrame else { return }
            if referencePlateIsAvailable {
                publishReferenceComposite(foreground)
            }
        }
    }

    private func publishSetupFraming(
        interactiveViewportSize: CGSize? = nil,
        authoredOverride: PhysicalPipelineAuthoringState? = nil
    ) {
        guard let sourceACEScgFrame else { return }
        do {
            let resolved = try resolveSceneFrame(
                currentFrame, authoredOverride: authoredOverride
            )
            let started = CACurrentMediaTime()
            if setupFramingRenderer == nil {
                setupFramingRenderer = try SetupFramingRenderer(device: sourceACEScgFrame.texture.device)
            }
            let selection = testAuthoringSelection
            let width = Int(selection?.deliveryWidth ?? UInt32(sourceACEScgFrame.width))
            let height = Int(selection?.deliveryHeight ?? UInt32(sourceACEScgFrame.height))
            let previewSize: (width: Int?, height: Int?) = if let viewport = interactiveViewportSize {
                {
                    let scale = min(
                        1,
                        max(1, Double(viewport.width)) / Double(width),
                        max(1, Double(viewport.height)) / Double(height)
                    )
                    return (
                        max(1, Int((Double(width) * scale).rounded())),
                        max(1, Int((Double(height) * scale).rounded()))
                    )
                }()
            } else {
                (nil, nil)
            }
            let plan = try setupDiagnosticPlan(
                scene: resolved,
                deliveryWidth: width,
                deliveryHeight: height,
                previewWidth: previewSize.width ?? width,
                previewHeight: previewSize.height ?? height,
                deliveryPlacementID: selection?.deliveryPlacementID ?? "fit",
                deliveryBackgroundID: selection?.deliveryBackgroundID ?? "black"
            )
            let plate = try referencePlateFrame(width: width, height: height)
            let result: SetupFramingRenderer.Result
            if let plate {
                result = try setupFramingRenderer!.renderSetupComposite(
                    source: sourceACEScgFrame,
                    plate: plate,
                    sourcePlacement: sourcePlacement,
                    platePlacement: referencePlate == .videoReference ? referencePlacement : .stretch,
                    plan: plan
                )
            } else {
                result = try setupFramingRenderer!.render(
                    source: sourceACEScgFrame,
                    sourcePlacement: sourcePlacement,
                    referencePlacement: .stretch,
                    plan: plan
                )
            }
            publishSceneFrame(result.frame, scene: resolved)
            setupDeviceBoundary = result.boundary
            setupSensorGateBoundary = result.sensorGateBoundary
            if let selection,
               selection.autofocusEnabled,
               let placement = Self.deliveryPlacementCode(selection.deliveryPlacementID) {
                focusSetupTarget = try resolved.resolver.projectFocusTarget(
                    frame: resolved.selection,
                    uv: CGPoint(
                        x: selection.autofocusTargetU,
                        y: selection.autofocusTargetV
                    ),
                    deliveryWidth: width, deliveryHeight: height,
                    previewWidth: result.frame.width,
                    previewHeight: result.frame.height,
                    deliveryPlacement: placement,
                    expectedRevision: resolved.revision
                )
                focusSetupTargetEnabled = focusSetupTarget != nil
            } else {
                focusSetupTarget = nil
                focusSetupTargetEnabled = false
            }
            if interactiveViewportSize == nil {
                monitorOutput.update(frame: result.frame, display: metalDisplay)
                let elapsedMilliseconds = (CACurrentMediaTime() - started) * 1_000
                status = "Setup · encuadre ideal · \(width)×\(height) · \(elapsedMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
                physicalPublicationSummary = "Setup · fuente + Device + cámara + Delivery Raster · publicado"
            }
        } catch {
            setupDeviceBoundary = []
            setupSensorGateBoundary = []
            focusSetupTarget = nil
            focusSetupTargetEnabled = false
            errorMessage = error.localizedDescription
        }
    }

    private static func deliveryPlacementCode(_ id: String) -> UInt32? {
        switch id {
        case "fit": 0
        case "one-to-one": 1
        case "fill-crop": 2
        default: nil
        }
    }

    private func setupDiagnosticPlan(
        scene: ResolvedSceneFrame,
        deliveryWidth: Int,
        deliveryHeight: Int,
        previewWidth: Int,
        previewHeight: Int,
        deliveryPlacementID: String,
        deliveryBackgroundID: String
    ) throws -> ScreenSetupDiagnosticPlanV1 {
        guard let placement = Self.deliveryPlacementCode(deliveryPlacementID) else {
            throw SetupFramingError.invalidContract
        }
        let background: UInt32 = switch deliveryBackgroundID {
        case "transparent": 0
        case "black": 1
        default: throw SetupFramingError.invalidContract
        }
        return try scene.resolver.prepareSetupDiagnostic(
            frame: scene.selection,
            deliveryWidth: deliveryWidth,
            deliveryHeight: deliveryHeight,
            previewWidth: previewWidth,
            previewHeight: previewHeight,
            deliveryPlacement: placement,
            deliveryBackground: background,
            expectedRevision: scene.revision
        )
    }

    private func publishReferenceMatchSetup(
        resetTargetsToVisibleFrame: Bool,
        authoredOverride: PhysicalPipelineAuthoringState? = nil
    ) {
        guard let reference = referenceACEScgFrame,
              let source = sourceACEScgFrame
        else { return }
        do {
            let resolved = try resolveSceneFrame(
                currentFrame, authoredOverride: authoredOverride
            )
            if setupFramingRenderer == nil {
                setupFramingRenderer = try SetupFramingRenderer(device: source.texture.device)
            }
            let delivery = referenceDeliveryRasterSize
            let projectionPlacementID = testAuthoringSelection?.deliveryPlacementID ?? "fit"
            let plan = try setupDiagnosticPlan(
                scene: resolved,
                deliveryWidth: delivery.width,
                deliveryHeight: delivery.height,
                previewWidth: delivery.width,
                previewHeight: delivery.height,
                deliveryPlacementID: projectionPlacementID,
                deliveryBackgroundID: "black"
            )
            let result = try setupFramingRenderer!.renderReferenceMatch(
                source: source,
                reference: reference,
                sourcePlacement: sourcePlacement,
                referencePlacement: referencePlacement,
                plan: plan
            )
            referenceMatchProjectedCorners = result.corners
            if resetTargetsToVisibleFrame {
                referenceMatchCorners = Self.initialReferenceMatchTargets(
                    width: delivery.width, height: delivery.height
                )
            }
            setupDeviceBoundary = result.boundary
            setupSensorGateBoundary = result.sensorGateBoundary
            // Publish the texture last. SwiftUI may render immediately on any
            // @Published mutation; by making the frame the commit marker the
            // Viewer can never observe a new texture with prior/empty handles.
            publishSceneFrame(result.frame, scene: resolved)
            physicalPublicationSummary = referenceMatchEnabled
                ? "Match referencia · referencia + Device rígido + cámara"
                : "Referencia visible · cámara libre"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func publishReferenceComposite(
        _ foreground: StudioColorMetalFrame,
        resolvedScene: ResolvedSceneFrame? = nil
    ) {
        do {
            let resolved: ResolvedSceneFrame
            if let resolvedScene { resolved = resolvedScene }
            else { resolved = try resolveSceneFrame(currentFrame) }
            if setupFramingRenderer == nil {
                setupFramingRenderer = try SetupFramingRenderer(device: foreground.texture.device)
            }
            let delivery = referenceDeliveryRasterSize
            guard let reference = try referencePlateFrame(
                width: delivery.width, height: delivery.height
            ) else {
                publishSceneFrame(foreground, scene: resolved)
                return
            }
            let plan = try setupDiagnosticPlan(
                scene: resolved,
                deliveryWidth: delivery.width,
                deliveryHeight: delivery.height,
                previewWidth: delivery.width,
                previewHeight: delivery.height,
                deliveryPlacementID: testAuthoringSelection?.deliveryPlacementID ?? "fit",
                deliveryBackgroundID: "black"
            )
            let result = try setupFramingRenderer!.renderReferenceComposite(
                cameraResult: foreground,
                reference: reference,
                referencePlacement: referencePlate == .videoReference ? referencePlacement : .stretch,
                plan: plan,
                deliveryAligned: referenceForegroundIsDeliveryAligned
            )
            publishSceneFrame(result.frame, scene: resolved)
            setupDeviceBoundary = result.boundary
            setupSensorGateBoundary = result.sensorGateBoundary
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var referenceControlsTimeline: Bool {
        referencePlateUsesVideo && referenceTimelineInfo != nil
    }

    private var referenceDeliveryRasterSize: (width: Int, height: Int) {
        if let selection = testAuthoringSelection {
            return (Int(selection.deliveryWidth), Int(selection.deliveryHeight))
        }
        if let reference = referenceACEScgFrame {
            return (reference.width, reference.height)
        }
        return (1, 1)
    }

    /// The Reference boundary is the only owner of the image composited behind a
    /// Device result.  It returns either the exact decoded video frame or one
    /// generated linear-ACEScg plate at the requested delivery raster.
    private func referencePlateFrame(
        width: Int,
        height: Int
    ) throws -> StudioColorMetalFrame? {
        guard width > 0, height > 0 else { throw SetupFramingError.invalidContract }
        switch referencePlate {
        case .videoReference:
            return referenceACEScgFrame
        case .vfxChecker, .black, .white, .middleGray:
            if let cached = syntheticReferencePlateCache,
               cached.plate == referencePlate, cached.width == width, cached.height == height {
                return cached.frame
            }
            guard let device = sourceACEScgFrame?.texture.device
                    ?? referenceACEScgFrame?.texture.device
                    ?? metalFrame?.texture.device
            else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw SetupFramingError.unavailableMetal
            }
            var rgba = [Float](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    let value: Float
                    switch referencePlate {
                    case .vfxChecker:
                        value = ((x / 64) + (y / 64)).isMultiple(of: 2) ? 0.18 : 0.5
                    case .black: value = 0
                    case .white: value = 1
                    case .middleGray: value = 0.18
                    case .videoReference: fatalError("handled above")
                    }
                    let index = (y * width + x) * 4
                    rgba[index] = value
                    rgba[index + 1] = value
                    rgba[index + 2] = value
                    rgba[index + 3] = 1
                }
            }
            rgba.withUnsafeBytes {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                    withBytes: $0.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float>.size
                )
            }
            let frame = StudioColorMetalFrame(texture: texture)
            syntheticReferencePlateCache = (referencePlate, width, height, frame)
            return frame
        }
    }

    private var referencePlateUsesVideo: Bool {
        referencePlate == .videoReference && referenceACEScgFrame != nil
    }

    private var referencePlateIsAvailable: Bool {
        referencePlate != .videoReference || referenceACEScgFrame != nil
    }

    private func applyTimelineAuthority(resetRange: Bool) {
        let previousSeconds = Double(currentFrame) / max(frameRate, 1)
        let timeline = ReferenceTimelineAuthority.resolve(
            source: sourceTimelineInfo,
            reference: referenceTimelineInfo,
            referenceVisible: referenceControlsTimeline,
            tracking: trackingTimelineInfo
        )
        frameRate = timeline.frameRate
        frameCount = max(1, timeline.frameCount)
        currentFrame = min(
            frameCount - 1,
            max(0, Int((previousSeconds * frameRate).rounded()))
        )
        if resetRange {
            inFrame = 0
            outFrame = frameCount - 1
        } else {
            inFrame = min(inFrame, frameCount - 1)
            outFrame = min(max(inFrame, outFrame), frameCount - 1)
        }
    }

    private func solveReferenceMatchTargets(
        undoManager: UndoManager?,
        priorSelection: TestAuthoringResolvedSelection
    ) {
        guard referenceMatchCorners.count == 4 else {
            status = "Match referencia · se necesitan cuatro objetivos para resolver la cámara"
            return
        }
        do {
            let solved = try resolvedFourPointReferencePose(
                focalLengthMillimeters: priorSelection.focalLengthMillimeters
            )
            try commitReferenceMatch(
                focalLengthMillimeters: priorSelection.focalLengthMillimeters,
                solved: solved,
                priorSelection: priorSelection,
                undoManager: undoManager,
                actionName: "Resolver cámara con referencia"
            )
            status = "Match referencia · cámara resuelta · error máximo \(solved.maximumErrorPixels.formatted(.number.precision(.fractionLength(1)))) px"
        } catch {
            referenceMatchErrorPixels = nil
            status = error.localizedDescription
        }
    }

    static func initialReferenceMatchTargets(width: Int, height: Int) -> [CGPoint] {
        let insetX = max(16.0, Double(width) * 0.08)
        let insetY = max(16.0, Double(height) * 0.08)
        let left = min(Double(width) * 0.5 - 1, insetX)
        let right = max(Double(width) * 0.5, Double(width) - insetX - 1)
        let top = min(Double(height) * 0.5 - 1, insetY)
        let bottom = max(Double(height) * 0.5, Double(height) - insetY - 1)
        return [
            CGPoint(x: left, y: top), CGPoint(x: right, y: top),
            CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom),
        ]
    }

    private func commitReferenceMatch(
        focalLengthMillimeters: Double,
        solved: (pose: CameraNavigationPose, maximumErrorPixels: Double, rmsErrorPixels: Double),
        priorSelection: TestAuthoringResolvedSelection,
        undoManager: UndoManager?,
        actionName: String
    ) throws {
        var selection = priorSelection
        let degrees = PoseRotationProjection.degrees(from: [
            solved.pose.orientation.imag.x, solved.pose.orientation.imag.y,
            solved.pose.orientation.imag.z, solved.pose.orientation.real,
        ])
        selection.geometryModeID = "free"
        selection.focalLengthMillimeters = focalLengthMillimeters
        selection.cameraPositionXMeters = solved.pose.position.x
        selection.cameraPositionYMeters = solved.pose.position.y
        selection.cameraPositionZMeters = solved.pose.position.z
        selection.cameraRotationXDegrees = degrees[0]
        selection.cameraRotationYDegrees = degrees[1]
        selection.cameraRotationZDegrees = degrees[2]
        try commitSceneAuthoringEdit(
            selection: selection,
            setting: [
                "geometry-mode", "focal-length-millimeters",
                "camera-position-x-meters", "camera-position-y-meters",
                "camera-position-z-meters", "camera-rotation-x-degrees",
                "camera-rotation-y-degrees", "camera-rotation-z-degrees",
            ],
            prior: .init(
                selection: priorSelection,
                explicitOverrideControlIDs: explicitSceneOverrideControlIDs
            ),
            undoManager: undoManager,
            actionName: actionName
        )
        referenceMatchErrorPixels = solved.maximumErrorPixels
        publishReferenceMatchSetup(resetTargetsToVisibleFrame: false)
    }

    private func resolvedFourPointReferencePose(
        focalLengthMillimeters: Double
    ) throws -> (
        pose: CameraNavigationPose, maximumErrorPixels: Double, rmsErrorPixels: Double
    ) {
        guard referenceACEScgFrame != nil,
              referenceMatchCorners.count == 4
        else { throw NativeMediaError.invalidRaster }
        return try resolvedRigidCameraPose(
            deliveryTargets: referenceMatchCorners,
            focalLengthMillimeters: focalLengthMillimeters,
            frame: currentFrame
        )
    }

    private func resolvedRigidCameraPose(
        deliveryTargets: [CGPoint],
        focalLengthMillimeters: Double,
        frame: Int
    ) throws -> (
        pose: CameraNavigationPose, maximumErrorPixels: Double, rmsErrorPixels: Double
    ) {
        guard referenceACEScgFrame != nil, deliveryTargets.count == 4 else {
            throw NativeMediaError.invalidRaster
        }
        let scene = try resolveSceneFrame(frame)
        let delivery = referenceDeliveryRasterSize
        let placementID = testAuthoringSelection?.deliveryPlacementID ?? "fit"
        let plan = try setupDiagnosticPlan(
            scene: scene,
            deliveryWidth: delivery.width,
            deliveryHeight: delivery.height,
            previewWidth: delivery.width,
            previewHeight: delivery.height,
            deliveryPlacementID: placementID,
            deliveryBackgroundID: "black"
        )
        let gateTargets = try ReferenceMatchRasterMapping.cameraGateCorners(
            deliveryTargets,
            referenceWidth: delivery.width, referenceHeight: delivery.height,
            cameraWidth: plan.active_sensor_width, cameraHeight: plan.active_sensor_height,
            deliveryPlacementID: placementID
        )
        let gateSize = CGSize(
            width: Int(plan.active_sensor_width), height: Int(plan.active_sensor_height)
        )
        let shift = SIMD2(Double(plan.lens_shift.0), Double(plan.lens_shift.1))
        let radial = SIMD3(
            Double(plan.lens_radial_distortion.0), Double(plan.lens_radial_distortion.1),
            Double(plan.lens_radial_distortion.2)
        )
        let tangential = SIMD2(
            Double(plan.lens_tangential_distortion.0),
            Double(plan.lens_tangential_distortion.1)
        )
        let pinholeTargets = try gateTargets.map { target in
            guard let point = ReferenceAnchorCameraMath.undistortedPinholePixel(
                target, imageSize: gateSize, lensShift: shift,
                radialDistortion: radial, tangentialDistortion: tangential
            ) else {
                throw ReferenceMatchError.unsolved("un objetivo queda fuera del dominio de la lente")
            }
            return point
        }
        let screenQuaternion = simd_quatd(
            ix: Double(plan.screen_rotation_xyzw.0), iy: Double(plan.screen_rotation_xyzw.1),
            iz: Double(plan.screen_rotation_xyzw.2), r: Double(plan.screen_rotation_xyzw.3)
        ).normalized
        let geometry = CameraNavigationGeometry(
            center: SIMD3(
                Double(plan.screen_position.0), Double(plan.screen_position.1),
                Double(plan.screen_position.2)
            ),
            right: screenQuaternion.act(SIMD3(1, 0, 0)),
            up: screenQuaternion.act(SIMD3(0, 1, 0)),
            halfWidth: Double(plan.device_active_width_meters) * 0.5,
            halfHeight: Double(plan.device_active_height_meters) * 0.5
        )
        var request = ScreenPlanarReferenceMatchV1()
        request.abi_version = SCREEN_PLANAR_REFERENCE_MATCH_ABI_VERSION
        withUnsafeMutableBytes(of: &request.device_corners_xyz) { bytes in
            let values = bytes.bindMemory(to: Float.self)
            for (index, corner) in geometry.corners.enumerated() {
                values[index * 3] = Float(corner.x)
                values[index * 3 + 1] = Float(corner.y)
                values[index * 3 + 2] = Float(corner.z)
            }
        }
        withUnsafeMutableBytes(of: &request.image_corners_xy) { bytes in
            let values = bytes.bindMemory(to: Float.self)
            for (index, target) in pinholeTargets.enumerated() {
                values[index * 2] = Float(target.x)
                values[index * 2 + 1] = Float(target.y)
            }
        }
        request.image_width = plan.active_sensor_width
        request.image_height = plan.active_sensor_height
        request.focal_length_millimeters = Float(focalLengthMillimeters)
        request.sensor_width_millimeters = plan.sensor_width_millimeters
        request.sensor_height_millimeters = plan.sensor_height_millimeters
        withUnsafeMutableBytes(of: &request.lens_shift_xy) { bytes in
            let values = bytes.bindMemory(to: Float.self)
            values[0] = Float(shift.x)
            values[1] = Float(shift.y)
        }
        var result = ScreenMatchedCameraPoseV1()
        var error: UnsafePointer<CChar>?
        guard screen_geometry_solve_planar_reference_v1(&request, &result, &error) else {
            throw ReferenceMatchError.unsolved(error.map(String.init(cString:)) ?? "solución degenerada")
        }
        let pose = CameraNavigationPose(
            position: SIMD3(
                Double(result.camera_position.0), Double(result.camera_position.1),
                Double(result.camera_position.2)
            ),
            orientation: simd_quatd(
                ix: Double(result.camera_rotation_xyzw.0),
                iy: Double(result.camera_rotation_xyzw.1),
                iz: Double(result.camera_rotation_xyzw.2),
                r: Double(result.camera_rotation_xyzw.3)
            ).normalized
        )
        let projectedGate = try geometry.corners.map { corner in
            guard let projected = ReferenceAnchorCameraMath.project(
                pose: pose, point: corner, imageSize: gateSize,
                focalLengthMillimeters: focalLengthMillimeters,
                sensorSizeMillimeters: CGSize(
                    width: Double(plan.sensor_width_millimeters),
                    height: Double(plan.sensor_height_millimeters)
                ),
                lensShift: shift, radialDistortion: radial, tangentialDistortion: tangential
            ) else { throw ReferenceMatchError.unsolved("la pose resuelta no proyecta el Device") }
            return projected
        }
        let projectedReference = try ReferenceMatchRasterMapping.referenceCorners(
            projectedGate,
            referenceWidth: delivery.width, referenceHeight: delivery.height,
            cameraWidth: plan.active_sensor_width, cameraHeight: plan.active_sensor_height,
            deliveryPlacementID: placementID
        )
        let errors = zip(projectedReference, referenceMatchCorners).map {
            hypot(Double($0.x - $1.x), Double($0.y - $1.y))
        }
        let maximumError = errors.max() ?? 0
        let rmsError = sqrt(errors.reduce(0) { $0 + $1 * $1 } / Double(max(1, errors.count)))
        return (pose, maximumError, rmsError)
    }

    private func publishEnvironmentSetup(
        authoredOverride: PhysicalPipelineAuthoringState? = nil
    ) {
        guard let environmentSourceACEScgFrame else {
            errorMessage = "Setup entorno necesita un HDRI / EXR seleccionado."
            return
        }
        do {
            let resolved = try resolveSceneFrame(
                currentFrame, authoredOverride: authoredOverride
            )
            let setupSource = environmentReflectionFramingEnabled
                ? environmentReflectionFramingSourceFrame ?? environmentSourceACEScgFrame
                : environmentSourceACEScgFrame
            if setupFramingRenderer == nil {
                setupFramingRenderer = try SetupFramingRenderer(device: setupSource.texture.device)
            }
            let selection = testAuthoringSelection
            let width = Int(selection?.deliveryWidth ?? UInt32(environmentSourceACEScgFrame.width))
            let height = Int(selection?.deliveryHeight ?? UInt32(environmentSourceACEScgFrame.height))
            let plan = try setupDiagnosticPlan(
                scene: resolved,
                deliveryWidth: width,
                deliveryHeight: height,
                previewWidth: width,
                previewHeight: height,
                deliveryPlacementID: selection?.deliveryPlacementID ?? "fit",
                deliveryBackgroundID: selection?.deliveryBackgroundID ?? "black"
            )
            let result = try setupFramingRenderer!.renderEnvironment(
                environment: setupSource,
                plan: plan,
                planarFraming: environmentReflectionFramingEnabled
                    ? environmentReflectionFraming.shaderValue : nil
            )
            publishSceneFrame(result.frame, scene: resolved)
            setupDeviceBoundary = result.boundary
            setupSensorGateBoundary = result.sensorGateBoundary
            status = environmentReflectionFramingEnabled
                ? "Encuadre plano de reflejo · \(width)×\(height)"
                : "Setup entorno · reflexión ideal 100% · \(width)×\(height)"
            physicalPublicationSummary = environmentReflectionFramingEnabled
                ? "Autoría inversa plana · el HDRI original no se modifica"
                : "Setup entorno · espejo ideal sin cristal, panel ni cámara"
        } catch {
            setupDeviceBoundary = []
            setupSensorGateBoundary = []
            errorMessage = error.localizedDescription
        }
    }

    private func publishFocusSetup(
        interactiveViewportSize: CGSize? = nil,
        authoredOverride: PhysicalPipelineAuthoringState? = nil
    ) {
        guard let sourceACEScgFrame else { return }
        do {
            let resolved = try resolveSceneFrame(
                currentFrame, authoredOverride: authoredOverride
            )
            if setupFramingRenderer == nil {
                setupFramingRenderer = try SetupFramingRenderer(device: sourceACEScgFrame.texture.device)
            }
            let selection = testAuthoringSelection
            let width = Int(selection?.deliveryWidth ?? UInt32(sourceACEScgFrame.width))
            let height = Int(selection?.deliveryHeight ?? UInt32(sourceACEScgFrame.height))
            let previewSize: (width: Int?, height: Int?) = if let viewport = interactiveViewportSize {
                {
                    let scale = min(1, max(1, Double(viewport.width)) / Double(width),
                        max(1, Double(viewport.height)) / Double(height))
                    return (max(1, Int((Double(width) * scale).rounded())),
                        max(1, Int((Double(height) * scale).rounded())))
                }()
            } else { (nil, nil) }
            let plan = try setupDiagnosticPlan(
                scene: resolved,
                deliveryWidth: width,
                deliveryHeight: height,
                previewWidth: previewSize.width ?? width,
                previewHeight: previewSize.height ?? height,
                deliveryPlacementID: selection?.deliveryPlacementID ?? "fit",
                deliveryBackgroundID: "black"
            )
            let result = try setupFramingRenderer!.renderFocus(
                source: sourceACEScgFrame, plan: plan
            )
            publishSceneFrame(result.frame, scene: resolved)
            setupDeviceBoundary = result.boundary
            setupSensorGateBoundary = result.sensorGateBoundary
            if let selection,
               selection.autofocusEnabled,
               let placement = Self.deliveryPlacementCode(selection.deliveryPlacementID) {
                focusSetupTarget = try resolved.resolver.projectFocusTarget(
                    frame: resolved.selection,
                    uv: CGPoint(
                        x: selection.autofocusTargetU,
                        y: selection.autofocusTargetV
                    ),
                    deliveryWidth: width, deliveryHeight: height,
                    previewWidth: result.frame.width,
                    previewHeight: result.frame.height,
                    deliveryPlacement: placement,
                    expectedRevision: resolved.revision
                )
                focusSetupTargetEnabled = focusSetupTarget != nil
            } else {
                focusSetupTarget = nil
                focusSetupTargetEnabled = false
            }
            if interactiveViewportSize == nil {
                status = "Setup foco · blanco máximo foco · retícula y borde ópticos"
                physicalPublicationSummary = "Setup foco · círculo de confusión + distorsión de lente"
            }
        } catch {
            setupDeviceBoundary = []
            setupSensorGateBoundary = []
            errorMessage = error.localizedDescription
        }
    }

    private func submitPhysicalJob(
        quality: PhysicalQuality,
        temporalSamplesOverride: UInt16? = nil,
        sourceFrameOverride: StudioColorMetalFrame? = nil,
        frameIndexOverride: Int? = nil,
        requestedDimensionsOverride: PhysicalDimensions? = nil,
        requestedIntermediateOverride: PhysicalIntermediate? = nil,
        vfxTransparency: PhysicalVfxTransparencyRequest? = nil,
        publishesPreviewState: Bool = true,
        resolvedSceneFrameOverride: ResolvedSceneFrame? = nil
    ) async throws -> SubmittedPhysicalJob {
        guard let nominalSourceFrame = sourceFrameOverride ?? sourceACEScgFrame else {
            throw PhysicalEvaluationAvailabilityError.missingSelectedFrame
        }
        let resolvedFrame = try resolvedSceneFrameOverride ?? resolveSceneFrame(
            frameIndexOverride ?? currentFrame,
            temporalSamplesOverride: temporalSamplesOverride
        )
        let effectiveAuthoringState = resolvedFrame.authored
        let outputSignal = try resolvedOutputSignal()
        let authoringSelection = currentTestAuthoringSelection()
        let contributions = physicalModel.orderedContributions
        let orchestration = try effectiveAuthoringState.orchestration(
            for: resolvedFrame.selection
        )
        let shutterMotionAmount = contributions.first(where: {
            $0.stage == .capture(.exposureShutter)
        })?.amount ?? 0
        let temporalCount = Self.effectiveTemporalSampleCount(
            shutterMotionAmount: shutterMotionAmount,
            authoredSampleCount: effectiveAuthoringState.shutterMotion.temporalSamples,
            requestedSampleCount: temporalSamplesOverride
        )
        let effectiveIntermediate = requestedIntermediateOverride ?? requestedPhysicalIntermediate
        let requestedDimensions = try requestedDimensionsOverride
            ?? physicalRequestedDimensions(
                quality: quality,
                intermediate: effectiveIntermediate,
                device: resolvedFrame.device.definition,
                captureWidth: resolvedFrame.activeSensorWindow.width,
                captureHeight: resolvedFrame.activeSensorWindow.height
            )
        let preparedRender = try physicalEngine.prepare(
            sceneResolver: resolvedFrame.resolver,
            orchestration: orchestration,
            sampleCount: temporalCount,
            renderContext: .fullFrame(requestedDimensions)
        )
        let requirements = preparedRender.temporalRequirements
        let nominalTime = CMTime(
            value: CMTimeValue(resolvedFrame.selection.timeNumerator),
            timescale: CMTimeScale(resolvedFrame.selection.timeDenominator)
        )
        var temporalInputs: [PhysicalTemporalInput] = []
        temporalInputs.reserveCapacity(requirements.count)
        var preparedMediaSamples: [NativeMediaSampleIdentity: DeviceSignalCheckpoint] = [:]
        let nominalMediaIdentity = sourceIsPattern ? nil : session.sampleIdentity(at: nominalTime)
        var publishedExactCheckpoint = false
        for requirement in requirements {
            try Task.checkCancellation()
            let requestedTime = CMTime(
                value: CMTimeValue(requirement.time.numerator),
                timescale: CMTimeScale(requirement.time.denominator)
            )
            let mediaIdentity = sourceIsPattern ? nil : session.sampleIdentity(at: requestedTime)
            let checkpoint: DeviceSignalCheckpoint
            if let mediaIdentity, let prepared = preparedMediaSamples[mediaIdentity] {
                checkpoint = prepared
            } else {
                let source = mediaIdentity != nil && mediaIdentity == nominalMediaIdentity
                    ? nominalSourceFrame
                    : try await renderFrame(at: requirement.time)
                checkpoint = try DeviceSignalCheckpoint.prepare(
                    sourceACEScg: source,
                    inputTransform: inputTransform,
                    outputSignal: outputSignal,
                    alphaInterpretation: String(describing: effectiveAlpha),
                    sourceAdjustment: .init(
                        exposureEV: authoringSelection?.sourceExposureEV ?? 0,
                        contrast: authoringSelection?.sourceContrast ?? 1,
                        saturation: authoringSelection?.sourceSaturation ?? 1,
                        temperatureKelvin: authoringSelection?.sourceTemperatureKelvin ?? 6500,
                        tint: authoringSelection?.sourceTint ?? 0
                    ),
                    display: metalDisplay
                )
                if let mediaIdentity { preparedMediaSamples[mediaIdentity] = checkpoint }
            }
            temporalInputs.append(.init(
                time: requirement.time,
                sourceACEScg: checkpoint.sourceACEScg,
                deviceSignal: checkpoint.deviceSignal
            ))
            if publishesPreviewState,
               CMTimeCompare(requestedTime, nominalTime) == 0 {
                deviceSignalCheckpoint = checkpoint
                publishedExactCheckpoint = true
            }
        }
        guard let publicationInput = temporalInputs.min(by: {
            abs(Double($0.time.numerator) / Double($0.time.denominator)
                - nominalTime.seconds)
                < abs(Double($1.time.numerator) / Double($1.time.denominator)
                    - nominalTime.seconds)
        }) else {
            throw PhysicalEvaluationAvailabilityError.missingSelectedFrame
        }
        if publishesPreviewState, !publishedExactCheckpoint {
            deviceSignalCheckpoint = try DeviceSignalCheckpoint.prepare(
                sourceACEScg: publicationInput.sourceACEScg,
                inputTransform: inputTransform,
                outputSignal: outputSignal,
                alphaInterpretation: String(describing: effectiveAlpha),
                sourceAdjustment: .init(
                    exposureEV: authoringSelection?.sourceExposureEV ?? 0,
                    contrast: authoringSelection?.sourceContrast ?? 1,
                    saturation: authoringSelection?.sourceSaturation ?? 1,
                    temperatureKelvin: authoringSelection?.sourceTemperatureKelvin ?? 6500,
                    tint: authoringSelection?.sourceTint ?? 0
                ),
                display: metalDisplay
            )
        }
        physicalIdentityCounter &+= 1
        let identity = PhysicalFrameIdentity(
            high: physicalModel.parameterRevision,
            low: physicalIdentityCounter
        )
        if publishesPreviewState {
            physicalPublicationSummary = "Source \(publicationInput.sourceACEScg.width)×\(publicationInput.sourceACEScg.height) · Device \(publicationInput.deviceSignal.width)×\(publicationInput.deviceSignal.height) · \(quality.uiLabel)/\(effectiveIntermediate.uiLabel) · \(temporalInputs.count) muestras exactas · enviado"
            physicalPublicationLog.notice(
                "submit source=\(publicationInput.sourceACEScg.width)x\(publicationInput.sourceACEScg.height) device=\(publicationInput.deviceSignal.width)x\(publicationInput.deviceSignal.height) samples=\(temporalInputs.count) quality=\(quality.uiLabel, privacy: .public) intermediate=\(effectiveIntermediate.uiLabel, privacy: .public) cameraZ=\(effectiveAuthoringState.cameraPose.position[2])"
            )
        }
        let job = try physicalEngine.submit(
            temporalInputs: temporalInputs,
            environmentACEScg: environmentRadianceFrame,
            preparedRender: preparedRender,
            quality: quality,
            deviceVfxAlphaMode: effectiveAuthoringState.deviceVfxAlphaMode,
            screenAmount: physicalModel.effectiveScreenAmount,
            contributions: contributions,
            requestedDimensions: requestedDimensions,
            cancellationIdentity: identity,
            progressIdentity: identity,
            parameterRevision: physicalModel.parameterRevision,
            parameterHash: try physicalParameterHash(
                quality: quality,
                device: resolvedFrame.device.definition
            ),
            rasterPlacement: sourcePlacement.physicalRasterPlacement,
            requestedIntermediate: effectiveIntermediate,
            vfxTransparency: vfxTransparency
        )
        return SubmittedPhysicalJob(job: job, scene: resolvedFrame)
    }

    static func effectiveTemporalSampleCount(
        shutterMotionAmount: Double,
        authoredSampleCount: UInt16,
        requestedSampleCount: UInt16?
    ) -> UInt16 {
        shutterMotionAmount == 0 ? 1 : (requestedSampleCount ?? authoredSampleCount)
    }

    private func resolvedOutputSignal() throws -> StudioColorMode {
        guard let outputSignalID = testAuthoringSelection?.outputSignalID,
              let mode = StudioColorMode.catalog.first(where: {
                  $0.id == outputSignalID
        }) else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "La Output Signal seleccionada no existe en StudioColor."
            )
        }
        return mode
    }

    private func currentTestAuthoringSelection() -> TestAuthoringResolvedSelection? {
        testAuthoringSelection
    }

    private func refreshTestAuthoringDescriptor(
        publishPreview: Bool = true
    ) throws {
        guard let device = modelDeviceDefinition ?? resolvedDevice?.definition else { return }
        let exactFrameRate = ReferenceTimelineAuthority.resolve(
            source: sourceTimelineInfo,
            reference: referenceTimelineInfo,
            referenceVisible: referenceControlsTimeline,
            tracking: trackingTimelineInfo
        ).exactFrameRate
        if testAuthoringSelection == nil {
            let initial = try RustTestAuthoringCoordinator.defaultSelection(
                profileContext: testAuthoringProfileContext,
                inputTransformID: inputTransform.id,
                deviceID: device.id,
                frameRate: exactFrameRate
            )
            testAuthoringSelection = sourceIsPattern
                ? try RustTestAuthoringCoordinator.apply(
                    .setChoice(
                        controlID: "placement",
                        optionID: selectedPattern.authoredPlacementID
                    ),
                    to: initial, profileContext: testAuthoringProfileContext
                )
                : initial
        }
        guard var selection = testAuthoringSelection else { return }
        selection.frameRate = exactFrameRate
        testAuthoringSelection = selection
        let snapshot = try RustTestAuthoringCoordinator.snapshot(
            profileContext: testAuthoringProfileContext,
            selection: selection,
            selectedPreviewPhaseID: testPresentation?.selectedPhaseID
        )
        testPresentation = snapshot.presentation
        testPreviewResultByPhaseID = snapshot.previewResultByPhaseID
        testPhysicalIntermediateByPhaseID = snapshot.physicalIntermediateByPhaseID
        if publishPreview {
            publishSelectedTestPreview()
        }
    }

    private func applyTestAuthoringSelection(
        _ selection: TestAuthoringResolvedSelection,
        profileDevice: DeviceDefinition? = nil,
        profileCoverGlass: CoverGlassDefinition? = nil
    ) throws {
        let previous = testAuthoringSelection
        let sourceAdjustmentChanged = previous.map {
            $0.sourceExposureEV != selection.sourceExposureEV
                || $0.sourceContrast != selection.sourceContrast
                || $0.sourceSaturation != selection.sourceSaturation
                || $0.sourceTemperatureKelvin != selection.sourceTemperatureKelvin
                || $0.sourceTint != selection.sourceTint
        } ?? false
        let environmentAdjustmentChanged = previous.map {
            $0.environmentContrast != selection.environmentContrast
                || $0.environmentSaturation != selection.environmentSaturation
                || $0.environmentTemperatureKelvin != selection.environmentTemperatureKelvin
                || $0.environmentTint != selection.environmentTint
        } ?? false
        if let previous,
           referenceMatchCorners.count == 4,
           (previous.deliveryWidth != selection.deliveryWidth
                || previous.deliveryHeight != selection.deliveryHeight) {
            let scaleX = CGFloat(selection.deliveryWidth) / CGFloat(previous.deliveryWidth)
            let scaleY = CGFloat(selection.deliveryHeight) / CGFloat(previous.deliveryHeight)
            referenceMatchCorners = referenceMatchCorners.map {
                CGPoint(
                    x: ($0.x + 0.5) * scaleX - 0.5,
                    y: ($0.y + 0.5) * scaleY - 0.5
                )
            }
        }
        if previous?.deliveryWidth != selection.deliveryWidth
            || previous?.deliveryHeight != selection.deliveryHeight
            || previous?.deliveryPlacementID != selection.deliveryPlacementID
            || previous?.deliveryBackgroundID != selection.deliveryBackgroundID {
            deliveryRasterCheckpoint = nil
            recordingOutputExecution = nil
            recordingEncodedBytes = nil
            recordingEncodedSHA256 = nil
        } else if previous?.recordingOutputTransformID != selection.recordingOutputTransformID {
            recordingOutputExecution = nil
            recordingEncodedBytes = nil
            recordingEncodedSHA256 = nil
        } else if previous?.recordingProfileID != selection.recordingProfileID
                    || previous?.recordingCharacter != selection.recordingCharacter {
            recordingEncodedBytes = nil
            recordingEncodedSHA256 = nil
        }
        let devicePresetChanged = previous?.deviceID != selection.deviceID
        var device: DeviceDefinition
        if let profileDevice {
            device = profileDevice
        } else if !devicePresetChanged, let current = modelDeviceDefinition {
            device = current
        } else if let libraryDevice = globalLibraryDocument.devices.first(where: {
            $0.id == selection.deviceID
        })?.value {
            device = libraryDevice
        } else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "Rust devolvió un Device que no existe en su catálogo."
            )
        }
        let currentProfileDevice = device
        device.colorModeID = selection.colorModeID
        device.eotfGamma = selection.deviceEOTFGamma
        device.whiteLevelNits = selection.whiteLuminanceNits
        device.panelUniformity.characterStrength = selection.panelUniformityAmount
        device.panelLightSpread.characterStrength = selection.panelLightSpreadAmount
        guard let placement = SourcePlacement(stableID: selection.placementID),
              let quality = PhysicalQuality(stableID: selection.previewQualityID)
        else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "Rust devolvió una colocación o calidad desconocida."
            )
        }
        testAuthoringSelection = selection
        if sourceAdjustmentChanged, let originACEScgFrame {
            sourceACEScgFrame = try adjustedSourceFrame(originACEScgFrame)
        }
        if environmentAdjustmentChanged,
           let environmentSourceACEScgFrame,
           selection.environmentSourceID == "environment-image" {
            let adjusted = try SceneAdjustmentFrame(
                source: environmentSourceACEScgFrame,
                parameters: .init(
                    exposureEV: 0,
                    contrast: selection.environmentContrast,
                    saturation: selection.environmentSaturation,
                    temperatureKelvin: selection.environmentTemperatureKelvin,
                    tint: selection.environmentTint
                ),
                incidentRadiance: true
            )
            environmentAdjustmentOwner = adjusted
            environmentRadianceFrame = try EnvironmentRadianceFrame.prefiltered(from: adjusted.frame)
        }
        sourcePlacement = placement
        try physicalModel.setContinuousAmount(
            selection.subpixelGeometryAmount,
            stage: .screen(.subpixelGeometry)
        )
        try physicalModel.setContinuousAmount(
            selection.panelUniformityAmount,
            stage: .screen(.panelUniformity)
        )
        try physicalModel.setContinuousAmount(
            selection.panelLightSpreadAmount,
            stage: .screen(.panelLightSpread)
        )
        let catalogCover = globalLibraryDocument.coverGlasses.first(where: {
            $0.id == selection.coverGlassPresetID
        })?.value
        guard let cover = profileCoverGlass ?? catalogCover else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "El Device seleccionado no resuelve su Cover Glass."
            )
        }
        if profileDevice != nil || profileCoverGlass != nil || devicePresetChanged
            || previous?.coverGlassPresetID != selection.coverGlassPresetID {
            sceneProfileBaselineByControlID = sceneProfileBaselines(
                device: currentProfileDevice, coverGlass: cover
            )
        }
        resolvedDevice = try device.resolved()
        modelDeviceDefinition = device
        var selectedCover = cover
        selectedCover.characterStrength = selection.coverGlassAmount
        selectedCover.agMicrotextureCharacterStrength = selection.coverAgMicrotextureAmount
        selectedCover.thicknessMillimeters = selection.coverThicknessMillimeters
        selectedCover.refractiveIndex = selection.coverRefractiveIndex
        selectedCover.antiReflectiveEfficiency = selection.coverAREfficiency
        selectedCover.absorptionPerMillimeter = selection.coverAbsorptionRGB
        selectedCover.roughness = selection.coverRoughness
        selectedCover.haze = selection.coverHaze
        selectedCover.agMicrotextureRMSSlope = selection.coverAgRMSSlope
        selectedCover.agMicrotextureCorrelationLengthMicrometers = selection.coverAgCorrelationMicrometers
        selectedCover.agMicrotextureAnisotropy = selection.coverAgAnisotropy
        selectedCover.glowCharacterStrength = selection.coverGlowAmount
        selectedCover.glowIntensity = selection.coverGlowIntensity
        selectedCover.glowRadiusMillimeters = selection.coverGlowRadiusMillimeters
        selectedCover.glowThresholdRelativeWhite = selection.coverGlowThresholdRelativeWhite
        var authored = try PhysicalPipelineAuthoringState.seeded(
            device: device,
            coverGlass: selectedCover
        )
        guard let capture = capturePresets.first(where: {
            $0.id == selection.capturePresetID
        }) else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "Rust devolvió una cámara que no existe en sus catálogos."
            )
        }
        try apply(
            capture: capture,
            rasterModeID: selection.captureRasterModeID,
            lensID: selection.lensPresetID,
            to: &authored
        )
        if selection.environmentSourceID == "environment-image" {
            guard environmentRadianceFrame != nil, let authoredImageEnvironment else {
                throw TestAuthoringCoordinatorError.malformedDescriptor(
                    "El entorno externo seleccionado no tiene un HDRI cargado."
                )
            }
            authored.environment = authoredImageEnvironment
        } else {
            guard let environment = environmentPresets.first(where: {
                $0.id == selection.environmentSourceID
            }) else {
                throw TestAuthoringCoordinatorError.malformedDescriptor(
                    "Rust devolvió un entorno que no existe en sus catálogos."
                )
            }
            environment.apply(to: &authored)
        }
        authored.environment.rotationXDegrees = selection.environmentRotationXDegrees
        authored.environment.rotationYDegrees = selection.environmentRotationYDegrees
        authored.environment.placementAnchorDirectionWorld = Self.environmentDirection(
            longitudeDegrees: selection.environmentAnchorLongitudeDegrees,
            latitudeDegrees: selection.environmentAnchorLatitudeDegrees
        )
        authored.environment.placementSourceDirection = Self.environmentDirection(
            longitudeDegrees: selection.environmentRotationYDegrees,
            latitudeDegrees: -selection.environmentRotationXDegrees
        )
        authored.environment.placementTangentTransform = selection.environmentTangentTransform
        authored.environment.exposureStops = selection.environmentExposureEV
        authored.environment.projectionMode = selection.environmentProjectionID == "finite-sphere" ? 1 : 0
        authored.environment.sphereCenterMeters = [
            selection.environmentSphereCenterXMeters,
            selection.environmentSphereCenterYMeters,
            selection.environmentSphereCenterZMeters,
        ]
        authored.environment.sphereRadiusMeters = selection.environmentSphereRadiusMeters
        authored.moireIntensity = selection.moireIntensity
        authored.moireSaturation = selection.moireSaturation
        authored.moireFilterStrength = selection.moireFilterStrength
        authored.coverGlowExteriorIntensity = selection.coverGlowExteriorIntensity
        authored.deviceVfxAlphaMode = selection.deviceVfxAlphaModeID
        authored.sceneLens.focusPolicy = selection.autofocusEnabled
            ? "autofocus-screen" : "manual"
        authored.sceneLens.evaluationModel = selection.lensEvaluationModelID
        authored.sceneLens.focalLengthMillimeters = selection.focalLengthMillimeters
        authored.sceneLens.focusDistanceMeters = selection.focusDistanceMeters
        authored.sceneLens.fStop = selection.fStop
        authored.sensor.bloomCrosstalkFraction = selection.sensorBloomCrosstalkFraction
        authored.sensor.bloomOverflowTransferFraction =
            selection.sensorBloomOverflowTransferFraction
        let halfExposureNanoseconds = Int64(
            (selection.exposureTimeSeconds * 0.5 * 1_000_000_000).rounded()
        )
        authored.shutterMotion.openOffsetNumerator = -halfExposureNanoseconds
        authored.shutterMotion.openOffsetDenominator = 1_000_000_000
        authored.shutterMotion.closeOffsetNumerator = halfExposureNanoseconds
        authored.shutterMotion.closeOffsetDenominator = 1_000_000_000
        authored.screenPose.position = [
            selection.screenPositionXMeters,
            selection.screenPositionYMeters,
            selection.screenPositionZMeters,
        ]
        authored.screenPose.quaternion = PoseRotationProjection.quaternion(fromDegrees: [
            selection.screenRotationXDegrees,
            selection.screenYawDegrees,
            selection.screenRotationZDegrees,
        ])
        switch selection.geometryModeID {
        case "look-at":
            authored.cameraPose.position = PoseRotationProjection.orbitPosition(
                around: authored.screenPose.position,
                distance: selection.cameraDistanceMeters,
                rotationDegrees: [
                    selection.cameraOrbitXDegrees,
                    selection.cameraOrbitYDegrees,
                    0,
                ]
            )
            authored.cameraLookAt = .init(target: authored.screenPose.position)
            authored.cameraPose.quaternion = PoseRotationProjection.quaternionLooking(
                from: authored.cameraPose.position,
                to: authored.screenPose.position,
                rollDegrees: selection.cameraRotationZDegrees
            )
        case "free":
            authored.cameraPose.position = [
                selection.cameraPositionXMeters,
                selection.cameraPositionYMeters,
                selection.cameraPositionZMeters,
            ]
            authored.cameraPose.quaternion = PoseRotationProjection.quaternion(fromDegrees: [
                selection.cameraRotationXDegrees,
                selection.cameraRotationYDegrees,
                selection.cameraRotationZDegrees,
            ])
            authored.cameraLookAt = nil
        default:
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "Rust devolvió un modo de geometría desconocido."
            )
        }
        try physicalModel.setContinuousAmount(
            selection.coverGlassAmount,
            stage: .screen(.coverGlass)
        )
        try physicalModel.setContinuousAmount(
            selection.environmentAmount,
            stage: .screen(.environment)
        )
        try physicalModel.setContinuousAmount(
            selection.coverGlowAmount,
            stage: .screen(.coverGlow)
        )
        try physicalModel.setContinuousAmount(1, stage: .capture(.geometry))
        try physicalModel.setContinuousAmount(
            selection.lensAmount,
            stage: .capture(.lens)
        )
        try physicalModel.setContinuousAmount(
            selection.shutterMotionAmount,
            stage: .capture(.exposureShutter)
        )
        authored.computationalCapture.exposureCount = UInt32(selection.computationalExposureCount)
        authored.computationalCapture.bracketSpacingStops = selection.computationalBracketSpacingStops
        try physicalModel.setContinuousAmount(
            selection.computationalCharacterStrength,
            stage: .capture(.computationalCapture)
        )
        try physicalModel.setContinuousAmount(
            selection.sensorBloomAmount,
            stage: .capture(.sensorBloom)
        )
        try physicalModel.setContinuousAmount(
            selection.sensorNoiseAmount,
            stage: .capture(.sensorCollection)
        )
        selectedCapturePresetID = capture.id
        selectedCaptureRasterModeID = selection.captureRasterModeID
        selectedLensPresetID = selection.lensPresetID
        physicalAuthoringState = authored
        resolvedPhysicalPipeline = try authored.resolvedPipeline()
        baseModelDeviceDefinition = device
        basePhysicalAuthoringState = authored
        // The resolved-scene cache is keyed by the physical parameter revision.
        // Some scene edits (poses, environment placement, camera values) do not
        // change a contribution amount, so they must still advance that revision
        // before any Setup or physical consumer can resolve the edited scene.
        physicalModel.invalidateExternalParameters(preservingQuality: true)
        try refreshTestAuthoringDescriptor()
        // The source artifact is replaced above only when its own adjustment
        // changes. Keep the last complete composition visible while a new
        // physical result is evaluated; publishing the decoded source here
        // would temporarily discard camera, Device and reference placement.
        let qualityChanged = physicalModel.quality != quality
        physicalModel.setQuality(quality)
        if !qualityChanged {
            rebuildPhysicalSelectedFrame()
        }
    }

    private var selectedTestPreviewResult: TestPreviewResultKind? {
        guard let phaseID = testPresentation?.selectedPhaseID else { return nil }
        return testPreviewResultByPhaseID[phaseID]
    }

    private var selectedTestPhysicalIntermediate: PhysicalIntermediate? {
        guard let phaseID = testPresentation?.selectedPhaseID else { return nil }
        return testPhysicalIntermediateByPhaseID[phaseID]
    }

    private var setupOwnsViewerPublication: Bool {
        (referenceMatchEnabled && referencePlateUsesVideo)
            || reflectionEnvironmentEditorEnabled
            || physicalModel.quality == .setup
            || physicalModel.quality == .environmentSetup
            || physicalModel.quality == .focusSetup
    }

    /// A physical Scene checkpoint owns the Viewer until its replacement is
    /// complete. Source decoding may refresh its canonical input meanwhile,
    /// but must never publish that input over the last valid composition.
    private var physicalPreviewOwnsViewerPublication: Bool {
        setupOwnsViewerPublication
            || (isTestPageActive && selectedTestPhysicalIntermediate != nil)
    }

    private func publishSelectedTestPreview() {
        guard !isMaterializingSavedScene else { return }
        guard let sourceACEScgFrame else { return }
        guard isTestPageActive,
              let presentation = testPresentation,
              let result = testPreviewResultByPhaseID[presentation.selectedPhaseID]
        else {
            // A page transition has no authority to replace the current
            // Viewer publication. The destination page will explicitly
            // request the checkpoint it owns.
            return
        }
        let presentationFrame: StudioColorMetalFrame
        switch result {
        case .sourceACEScg:
            updateRequestedPhysicalIntermediate(.sourceACEScg)
            presentationFrame = originACEScgFrame ?? sourceACEScgFrame
        case .sourceAdjustment:
            updateRequestedPhysicalIntermediate(.sourceACEScg)
            presentationFrame = sourceACEScgFrame
        case .feederSignal:
            updateRequestedPhysicalIntermediate(.deviceSignal)
            rebuildPhysicalSelectedFrame()
            return
        case .deviceInterpretation, .panelStructure, .panelUniformity, .panelLightSpread,
             .panelTemporal,
             .relativeGeometry, .coverEnvironment, .coverGlow, .lensProjection,
             .shutterExposure, .computationalCapture, .sensorCollection, .sensorBloom,
             .sensorReadoutRaw,
             .developDemosaic, .cameraRenderingIntent, .deviceVfxTransparency,
             .deliveryRaster, .recordingOutput, .recordingCodec:
            guard let intermediate = selectedTestPhysicalIntermediate else {
                errorMessage = "Application no publicó el checkpoint físico de esta fase."
                return
            }
            updateRequestedPhysicalIntermediate(intermediate)
            rebuildPhysicalSelectedFrame()
            return
        }
        // Preserve the selected checkpoint intent above, but never let its
        // presentation replace an active Setup composition.
        guard !setupOwnsViewerPublication else { return }
        if referencePlateUsesVideo {
            publishReferenceMatchSetup(resetTargetsToVisibleFrame: false)
            return
        }
        publishCurrentSceneFrame(presentationFrame)
        monitorOutput.update(frame: presentationFrame, display: metalDisplay)
        let phase = presentation.phases.first(where: {
            $0.id == presentation.selectedPhaseID
        })
        status = "Test · Ver hasta \(phase?.label ?? presentation.selectedPhaseID) · \(presentationFrame.width)×\(presentationFrame.height)"
    }

    private func publishRecordingPreview(result: TestPreviewResultKind) {
        guard let camera = recordingCameraCheckpoint,
              let selection = testAuthoringSelection
        else { return }
        do {
            let delivery: DeliveryRasterExecution
            if let cached = deliveryRasterCheckpoint {
                delivery = cached
            } else {
                delivery = try RecordingPhaseExecutor.delivery(
                    cameraRendered: camera,
                    width: Int(selection.deliveryWidth),
                    height: Int(selection.deliveryHeight),
                    placementID: selection.deliveryPlacementID,
                    backgroundID: selection.deliveryBackgroundID,
                    display: metalDisplay
                )
                deliveryRasterCheckpoint = delivery
            }
            if result == .deliveryRaster {
                let frame = delivery.compositionFrame
                referenceForegroundFrame = frame
                referenceForegroundIsDeliveryAligned = true
                if referencePlateIsAvailable { publishReferenceComposite(frame) }
                else { publishCurrentSceneFrame(frame) }
                monitorOutput.update(frame: frame, display: metalDisplay)
                return
            }
            let output: RecordingOutputExecution
            if let cached = recordingOutputExecution {
                output = cached
            } else {
                output = try RecordingPhaseExecutor.output(
                    delivery: delivery,
                    transformID: selection.recordingOutputTransformID,
                    display: metalDisplay
                )
                recordingOutputExecution = output
            }
            let frame: StudioColorMetalFrame
            if result == .recordingCodec {
                let codec = try RecordingPhaseExecutor.codec(
                    output: output,
                    profileID: selection.recordingProfileID,
                    character: selection.recordingCharacter,
                    outputTransformID: selection.recordingOutputTransformID,
                    frameRateNumerator: selection.frameRate.numerator,
                    frameRateDenominator: selection.frameRate.denominator,
                    display: metalDisplay
                )
                frame = codec.frame
                recordingEncodedBytes = codec.encodedBytes
                recordingEncodedSHA256 = codec.encodedSHA256Hex
            } else {
                frame = output.frame
                recordingEncodedBytes = nil
                recordingEncodedSHA256 = nil
            }
            referenceForegroundFrame = frame
            referenceForegroundIsDeliveryAligned = true
            if referencePlateIsAvailable { publishReferenceComposite(frame) }
            else { publishCurrentSceneFrame(frame) }
            monitorOutput.update(frame: frame, display: metalDisplay)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pollPhysicalJob(
        _ submission: SubmittedPhysicalJob,
        native: Bool
    ) async throws {
        let job = submission.job
        let started = ContinuousClock.now
        var lastNativePublication: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            let snapshot = try job.snapshot()
            if native {
                let now = ContinuousClock.now
                if snapshot.state != .rendering
                    || lastNativePublication == nil
                    || lastNativePublication!.duration(to: now) >= .milliseconds(50) {
                    physicalModel.publishNative(snapshot)
                    lastNativePublication = now
                }
            }
            switch snapshot.state {
            case .idle, .stale, .rendering:
                try await Task.sleep(for: .milliseconds(8))
            case .cancelled:
                if native {
                    physicalModel.confirmNativeCancellation()
                }
                throw CancellationError()
            case .failed:
                let failure = snapshot.diagnostics
                    .first(where: { !$0.message.isEmpty })?.message
                    ?? "La evaluación física ha fallado."
                physicalPublicationLog.error(
                    "job state=failed quality=\(snapshot.computedQuality.uiLabel, privacy: .public) intermediate=\(snapshot.returnedIntermediate.uiLabel, privacy: .public) cause=\(failure, privacy: .public)"
                )
                throw PhysicalMetalFrameEngineError.bridge(failure)
            case .complete:
                guard !setupOwnsViewerPublication,
                      snapshot.parameterRevision == physicalModel.parameterRevision,
                      snapshot.returnedIntermediate == requestedPhysicalIntermediate,
                      let frame = snapshot.frame,
                      let effective = snapshot.effectiveDimensions
                else { throw CancellationError() }
                let presentationFrame: StudioColorMetalFrame
                if snapshot.returnedIntermediate == .deviceSignal {
                    let outputSignal = try resolvedOutputSignal()
                    presentationFrame = try metalDisplay.makeACEScgFrame(
                        encodedTexture: frame.texture,
                        input: outputSignal.resolvedPreviewInput(for: inputTransform),
                        alpha: .premultiplied
                    )
                } else {
                    presentationFrame = frame
                }
                referenceForegroundFrame = presentationFrame
                referenceForegroundIsDeliveryAligned = false
                let duration = started.duration(to: .now)
                let elapsed = Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1e18
                if native {
                    physicalModel.publishNative(snapshot)
                    physicalModel.completeNative(
                        nativeDimensions: snapshot.nativeDimensions,
                        effectiveDimensions: effective
                    )
                } else {
                    physicalModel.publishInteractive(snapshot, elapsedSeconds: elapsed)
                }
                if snapshot.returnedIntermediate == .cameraRenderedACEScg {
                    recordingCameraCheckpoint = presentationFrame
                    deliveryRasterCheckpoint = nil
                    recordingOutputExecution = nil
                    if selectedTestPreviewResult == .deliveryRaster
                        || selectedTestPreviewResult == .recordingOutput
                        || selectedTestPreviewResult == .recordingCodec {
                        publishRecordingPreview(result: selectedTestPreviewResult!)
                        return
                    }
                }
                if referencePlateIsAvailable {
                    publishReferenceComposite(
                        presentationFrame,
                        resolvedScene: submission.scene
                    )
                } else {
                    publishSceneFrame(presentationFrame, scene: submission.scene)
                }
                monitorOutput.update(frame: presentationFrame, display: metalDisplay)
                let diagnostic = snapshot.diagnostics
                    .filter { !$0.message.isEmpty }
                    .map(\.message)
                    .joined(separator: " · ")
                status = "Modelo · \(snapshot.computedQuality.uiLabel) · \(effective.width)×\(effective.height) · \((elapsed * 1_000).formatted(.number.precision(.fractionLength(1)))) ms"
                if !diagnostic.isEmpty { status += " · \(diagnostic)" }
                physicalPublicationSummary = "Source sí · Device sí · Result sí \(presentationFrame.width)×\(presentationFrame.height) · \(snapshot.computedQuality.uiLabel)/\(snapshot.returnedIntermediate.uiLabel) · publicado"
                physicalPublicationLog.notice(
                    "published result=\(presentationFrame.width)x\(presentationFrame.height) state=complete quality=\(snapshot.computedQuality.uiLabel, privacy: .public) intermediate=\(snapshot.returnedIntermediate.uiLabel, privacy: .public) revision=\(snapshot.parameterRevision)"
                )
                return
            }
        }
    }

    private func physicalRequestedDimensions(
        quality: PhysicalQuality,
        intermediate: PhysicalIntermediate,
        device: DeviceDefinition,
        captureWidth: Int,
        captureHeight: Int
    ) throws -> PhysicalDimensions {
        if quality == .setup || quality == .environmentSetup || quality == .focusSetup {
            throw PhysicalEvaluationAvailabilityError.sectionPending(.capture(.geometry))
        }
        let nativeRaster = intermediate.nativeRasterSize(
            deviceWidth: device.nativeWidth,
            deviceHeight: device.nativeHeight,
            captureWidth: captureWidth,
            captureHeight: captureHeight
        )
        let nativeWidth = nativeRaster.width
        let nativeHeight = nativeRaster.height
        if quality == .native {
            return try PhysicalDimensions(
                width: nativeWidth,
                height: nativeHeight
            )
        }
        let aspect = Double(nativeWidth) / Double(nativeHeight)
        var width = max(1, Int(modelViewport.width.rounded(.down)))
        var height = max(1, Int((Double(width) / aspect).rounded(.down)))
        if height > Int(modelViewport.height) {
            height = max(1, Int(modelViewport.height.rounded(.down)))
            width = max(1, Int((Double(height) * aspect).rounded(.down)))
        }
        let scale: Double = switch quality {
        case .setup: 1
        case .environmentSetup: 1
        case .focusSetup: 1
        case .draft: 0.5
        case .medium: 1
        case .high: 1.5
        case .native: 1
        }
        return try PhysicalDimensions(
            width: min(nativeWidth, max(1, Int(Double(width) * scale))),
            height: min(nativeHeight, max(1, Int(Double(height) * scale)))
        )
    }

    private func physicalParameterHash(
        quality: PhysicalQuality,
        device: DeviceDefinition
    ) throws -> PhysicalParameterHash {
        var data = try JSONEncoder().encode(device)
        if let physicalAuthoringState {
            data.append(try JSONEncoder().encode(physicalAuthoringState))
        }
        let fields = [
            quality.rawValue.description,
            physicalModel.effectiveScreenAmount.description,
            sourcePlacement.rawValue,
            physicalModel.parameterRevision.description,
            environmentSourceHash ?? "procedural-environment",
            physicalModel.orderedContributions.map {
                switch $0.control {
                case let .continuous(amount, _): "\($0.id):c:\(amount)"
                case let .discrete(enabled): "\($0.id):d:\(enabled)"
                }
            }.joined(separator: ","),
        ].joined(separator: "|")
        data.append(contentsOf: fields.utf8)
        return try PhysicalParameterHash(bytes: Array(SHA256.hash(data: data)))
    }

    private static func isVideo(_ url: URL) -> Bool {
        ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
    }

    private static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "tif", "tiff", "heic", "exr", "dpx"].contains(url.pathExtension.lowercased())
    }
}

enum PhysicalEvaluationAvailabilityError: Error, LocalizedError {
    case missingSelectedFrame
    case capturePending
    case artisticScreenPending
    case sectionPending(PhysicalStageID)

    var errorDescription: String? {
        switch self {
        case .missingSelectedFrame:
            "No hay un fotograma ACEScg seleccionado."
        case .capturePending:
            "Captura está pendiente del motor físico ABI v3; no se ha simulado."
        case .artisticScreenPending:
            "Pantalla >1 está pendiente del motor físico ABI v3; se conserva el último resultado."
        case let .sectionPending(stage):
            "La contribución 0x\(String(stage.id, radix: 16)) está pendiente del motor ABI v3."
        }
    }
}

private extension PhysicalQuality {
    init?(stableID: String) {
        switch stableID {
        case "setup": self = .setup
        case "environment-setup": self = .environmentSetup
        case "focus-setup": self = .focusSetup
        case "draft": self = .draft
        case "medium": self = .medium
        case "high": self = .high
        case "native": self = .native
        default: return nil
        }
    }

    var uiLabel: String {
        switch self {
        case .setup: "Setup"
        case .environmentSetup: "Setup entorno"
        case .focusSetup: "Setup foco"
        case .draft: "Draft"
        case .medium: "Media"
        case .high: "Alta"
        case .native: "Nativa"
        }
    }
}

extension StudioAlphaMode {
    var colorAssociation: StudioColorAlphaAssociation {
        switch self {
        case .straight: .straight
        case .premultiplied: .premultiplied
        case .ignore: .ignore
        }
    }
}
