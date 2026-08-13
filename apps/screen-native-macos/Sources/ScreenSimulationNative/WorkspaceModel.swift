@preconcurrency import AVFoundation
import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import ScreenSimulationPresentation
import StudioColor
import StudioMedia
import SwiftUI
import UniformTypeIdentifiers

enum NativeRenderButtonState: Equatable {
    case outdated
    case rendering(progress: Double)
    case cancelling
    case complete

    static func resolve(
        frameState: PhysicalFrameState,
        progress: Double,
        hasActiveTask: Bool,
        cancellationRequested: Bool
    ) -> Self {
        if hasActiveTask, cancellationRequested || frameState != .rendering {
            return .cancelling
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

@MainActor
final class WorkspaceModel: ObservableObject {
    private final class UndoManagerBox: @unchecked Sendable {
        weak var value: UndoManager?
        init(_ value: UndoManager?) { self.value = value }
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
    struct RenderJob: Identifiable {
        enum State: String { case pending, rendering, completed, failed, cancelled }
        let id = UUID()
        let destination: URL
        let configuration: StudioResolvedRenderConfiguration
        var state: State = .pending
        var progress = 0.0
        var detail = "Pendiente"
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
    @Published private(set) var setupDeviceBoundary: [CGPoint] = []
    @Published private(set) var environmentSourceName: String?
    @Published var jobs: [RenderJob] = []
    @Published var errorMessage: String?
    @Published var currentFrame = 0
    @Published var frameCount = 1
    @Published var frameRate = 24.0
    @Published var isPlaying = false
    @Published var inFrame = 0
    @Published var outFrame = 0
    @Published var renderRange = StudioRenderRange.all
    @Published var loopPlayback = false
    @Published var outputFormat = StudioOutputFormat.proRes4444
    @Published var outputPixelEncoding = StudioPixelEncoding.yuv44412
    @Published var renderPreset = StudioRenderPreset.builtIns[0]
    @Published var peakNits = 100.0
    @Published var includeAudio = true
    @Published var outputAlphaMode = StudioAlphaMode.premultiplied
    @Published var outputSignalRange = StudioSignalRange.video
    @Published var decodeToPreviewMilliseconds = 0.0
    @Published var zoom = 1.0
    @Published private(set) var previewIsFitted = true
    @Published var pan = CGSize.zero
    @Published private(set) var defaultInputTransformID = "srgb-encoded-rec709"
    @Published private(set) var defaultAlphaMode = StudioAlphaMode.ignore
    @Published private(set) var defaultSignalColorModel = StudioSignalColorModel.rgb
    @Published private(set) var defaultSignalMatrix = StudioSignalMatrix.bt709
    @Published private(set) var defaultSignalRange = StudioSignalRange.full
    @Published private(set) var resolvedDevice: ResolvedDevice?
    @Published private(set) var modelDeviceDefinition: DeviceDefinition?
    @Published private(set) var physicalAuthoringState: PhysicalPipelineAuthoringState?
    @Published private(set) var requestedPhysicalIntermediate = PhysicalIntermediate.developedACEScg
    @Published private(set) var sourceACEScgFrame: StudioColorMetalFrame?
    @Published private(set) var deviceSignalCheckpoint: DeviceSignalCheckpoint?
    @Published var sourcePlacement = SourcePlacement.fit
    @Published var modelViewerOneToOne = false
    @Published private(set) var armedPhysicalParameterIDs: Set<String> = []
    @Published private(set) var selectedCapturePresetID: String?
    @Published private(set) var selectedCaptureRasterModeID: String?
    @Published private(set) var selectedLensPresetID: String?
    let capturePresets = try! CapturePresetDefinition.catalog()
    let lensPresets = try! LensPresetDefinition.catalog()
    let environmentPresets = try! EnvironmentPresetDefinition.catalog()
    @Published private(set) var physicalPublicationSummary = "Sin publicación física"
    @Published private(set) var testPresentation: TestPagePresentation?
    @Published private(set) var recordingEncodedBytes: Int?
    @Published private(set) var recordingEncodedSHA256: String?
    private var testAuthoringSelection: TestAuthoringResolvedSelection?
    private var recordingCameraCheckpoint: StudioColorMetalFrame?
    private var deliveryRasterCheckpoint: StudioColorMetalFrame?
    private var recordingOutputExecution: RecordingOutputExecution?
    private var setupFramingRenderer: SetupFramingRenderer?
    private var environmentRadianceFrame: EnvironmentRadianceFrame?
    private var authoredImageEnvironment: PhysicalPipelineAuthoringState.Environment?
    private var environmentSourceHash: String?
    private var environmentSourceInputTransformID: String?
    private var cameraNavigationGesture: CameraNavigationGesture?
    private var cameraNavigationStartSelection: TestAuthoringResolvedSelection?

    let metalDisplay: StudioColorMetalDisplay
    let monitorOutput = MonitorOutputController()
    let physicalModel = PhysicalModelController()
    private let session = NativeMediaSession()
    private var sourceIsPattern = true
    private var tickSubscription: AnyCancellable?
    private var physicalSubscription: AnyCancellable?
    private var renderTask: Task<Void, Never>?
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
    private var resolvedPhysicalPipeline: PhysicalPipelineResolvedState?
    private var baseModelDeviceDefinition: DeviceDefinition?
    private var basePhysicalAuthoringState: PhysicalPipelineAuthoringState?
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
             .relativeGeometry,
             .coverEnvironment, .coverGlow, .lensProjection:
            guard let device = modelDeviceDefinition ?? resolvedDevice?.definition else { return nil }
            return Double(device.nativeWidth) / Double(device.nativeHeight)
        case .sensorBloom, .sensorNoise, .rawMosaic, .developedACEScg, .cameraRenderedACEScg:
            guard let sensor = physicalAuthoringState?.sensor,
                  sensor.nativeWidth > 0, sensor.nativeHeight > 0
            else { return nil }
            // The selected capture preset is authoritative for the camera-result
            // viewport. Do not retain the aspect of the previously published frame
            // while the replacement physical job is being evaluated.
            return Double(sensor.nativeWidth) / Double(sensor.nativeHeight)
        case .sourceACEScg, .deviceSignal, .shutterMotion, .computationalCapture:
            guard let metalFrame, metalFrame.height > 0 else { return nil }
            return Double(metalFrame.width) / Double(metalFrame.height)
        }
    }

    var physicalNativeOutputDescription: String? {
        switch requestedPhysicalIntermediate {
        case .sensorBloom, .sensorNoise, .rawMosaic, .developedACEScg, .cameraRenderedACEScg:
            guard let sensor = physicalAuthoringState?.sensor else { return nil }
            return "Captura \(sensor.nativeWidth)×\(sensor.nativeHeight)"
        case .panelEmission, .subpixelRadiance, .panelUniformity, .panelLightSpread,
             .relativeGeometry,
             .coverEnvironment, .coverGlow, .lensProjection, .shutterMotion:
            guard let device = modelDeviceDefinition ?? resolvedDevice?.definition else { return nil }
            return "Panel \(device.nativeWidth * 3)×\(device.nativeHeight * 3)"
        case .computationalCapture:
            guard let device = modelDeviceDefinition ?? resolvedDevice?.definition else { return nil }
            return "Panel \(device.nativeWidth * 3)×\(device.nativeHeight * 3)"
        case .sourceACEScg, .deviceSignal:
            guard let metalFrame else { return nil }
            return "Fuente \(metalFrame.width)×\(metalFrame.height)"
        }
    }

    init() {
        metalDisplay = try! StudioColorMetalDisplay()
        physicalModel.interactiveInvalidation = { [weak self] in
            self?.rebuildPhysicalSelectedFrame()
        }
        physicalModel.cancelNativeWork = { [weak self] in
            _ = self?.physicalNativeJob?.cancel()
        }
        physicalSubscription = physicalModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        renderPattern()
        tickSubscription = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect().sink { [weak self] _ in self?.tickPlayback() }
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
            try refreshTestAuthoringDescriptor()
            rebuildCurrent()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectModelDevice(
        _ definition: DeviceDefinition,
        coverGlass: CoverGlassDefinition
    ) {
        do {
            testAuthoringSelection = nil
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
            try refreshTestAuthoringDescriptor()
            rebuildPhysicalSelectedFrame()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectCapturePreset(_ preset: CapturePresetDefinition, undoManager: UndoManager?) {
        guard let prior = physicalAuthoringState else { return }
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
            undoManager?.registerUndo(withTarget: self) { target in
                Task { @MainActor in
                    target.restoreCapturePresetState(
                        prior,
                        selectedID: priorID,
                        selectedRasterModeID: priorRasterModeID,
                        selectedLensID: priorLensID
                    )
                }
            }
            undoManager?.setActionName("Cambiar cámara")
            physicalModel.invalidateExternalParameters()
        } catch { errorMessage = error.localizedDescription }
    }

    private func apply(
        capture: CapturePresetDefinition,
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
        selectedLensID: String?
    ) {
        do {
            resolvedPhysicalPipeline = try state.resolvedPipeline()
            physicalAuthoringState = state
            basePhysicalAuthoringState = state
            selectedCapturePresetID = selectedID
            selectedCaptureRasterModeID = selectedRasterModeID
            selectedLensPresetID = selectedLensID
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
        guard let prior = physicalAuthoringState else { return }
        var next = prior
        mutation(&next)
        do {
            resolvedPhysicalPipeline = try next.resolvedPipeline()
            physicalAuthoringState = next
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
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.restoreModelDevice(prior) }
        }
        undoManager?.setActionName("Editar parámetro físico")
    }

    private func restoreModelDevice(_ value: DeviceDefinition) {
        do {
            resolvedDevice = try value.resolved()
            modelDeviceDefinition = value
            try refreshTestAuthoringDescriptor()
            physicalModel.invalidateExternalParameters()
        } catch { errorMessage = error.localizedDescription }
    }

    private func registerPhysicalAuthoringUndo(
        _ prior: PhysicalPipelineAuthoringState,
        undoManager: UndoManager?
    ) {
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.restorePhysicalAuthoring(prior) }
        }
        undoManager?.setActionName("Editar parámetro físico")
    }

    private func restorePhysicalAuthoring(_ value: PhysicalPipelineAuthoringState) {
        do {
            resolvedPhysicalPipeline = try value.resolvedPipeline()
            physicalAuthoringState = value
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
        if active { pause() }
        rebuildPhysicalSelectedFrame()
    }

    func setTestPageActive(_ active: Bool) {
        isTestPageActive = active
        if active { pause() }
        if active, let intermediate = selectedTestPhysicalIntermediate {
            updateRequestedPhysicalIntermediate(intermediate)
            rebuildPhysicalSelectedFrame()
        } else {
            publishSelectedTestPreview()
        }
    }

    func handleTestIntent(_ intent: TestControlIntent) {
        do {
            switch intent {
            case let .selectPhase(phaseID):
                guard let selection = currentTestAuthoringSelection() else {
                    throw TestAuthoringCoordinatorError.malformedDescriptor(
                        "Test necesita un Device resuelto."
                    )
                }
                let snapshot = try RustTestAuthoringCoordinator.snapshot(
                    selection: selection,
                    selectedPreviewPhaseID: phaseID
                )
                testPresentation = snapshot.presentation
                testPreviewResultByPhaseID = snapshot.previewResultByPhaseID
                let selectedResult = snapshot.previewResultByPhaseID[phaseID]
                if (selectedResult == .recordingOutput || selectedResult == .recordingCodec),
                   recordingCameraCheckpoint != nil {
                    publishRecordingPreview(result: selectedResult!)
                    return
                }
                if let intermediate = physicalIntermediate(
                    for: selectedResult
                ) {
                    updateRequestedPhysicalIntermediate(intermediate)
                    rebuildPhysicalSelectedFrame()
                } else {
                    publishSelectedTestPreview()
                }
            case .setChoice, .setScalar, .setToggle:
                guard let selection = currentTestAuthoringSelection() else {
                    throw TestAuthoringCoordinatorError.malformedDescriptor(
                        "Test necesita un Device resuelto."
                    )
                }
                if case let .setChoice(controlID, _) = intent,
                   controlID == "environment-preset" {
                    environmentRadianceFrame = nil
                    authoredImageEnvironment = nil
                    environmentSourceName = nil
                    environmentSourceHash = nil
                    environmentSourceInputTransformID = nil
                }
                let phaseToReveal = testPhaseToReveal(for: intent)
                let resolved = try RustTestAuthoringCoordinator.apply(intent, to: selection)
                try applyTestAuthoringSelection(resolved)
                if let phaseToReveal,
                   let updatedSelection = currentTestAuthoringSelection() {
                    let snapshot = try RustTestAuthoringCoordinator.snapshot(
                        selection: updatedSelection,
                        selectedPreviewPhaseID: phaseToReveal
                    )
                    testPresentation = snapshot.presentation
                    testPreviewResultByPhaseID = snapshot.previewResultByPhaseID
                    let revealResult = snapshot.previewResultByPhaseID[phaseToReveal]
                    if (revealResult == .recordingOutput || revealResult == .recordingCodec),
                       recordingCameraCheckpoint != nil {
                        publishRecordingPreview(result: revealResult!)
                        return
                    }
                    if let intermediate = physicalIntermediate(
                        for: revealResult
                    ) {
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
        guard let authored = physicalAuthoringState,
              let device = modelDeviceDefinition ?? resolvedDevice?.definition,
              let selection = testAuthoringSelection,
              viewportSize.width > 0, viewportSize.height > 0
        else { return }
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

    func updateCameraNavigation(delta: CGSize) {
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
        }
        applyCameraNavigationPose(pose)
    }

    func endCameraNavigation(undoManager: UndoManager?) {
        guard cameraNavigationGesture != nil else { return }
        cameraNavigationGesture = nil
        if let prior = cameraNavigationStartSelection,
           prior != testAuthoringSelection {
            let manager = UndoManagerBox(undoManager)
            undoManager?.registerUndo(withTarget: self) { target in
                Task { @MainActor in
                    try? target.restoreCameraNavigationSelection(
                        prior, undoManager: manager.value
                    )
                }
            }
            undoManager?.setActionName("Navegar cámara")
        }
        cameraNavigationStartSelection = nil
    }

    private func applyCameraNavigationPose(_ pose: CameraNavigationPose) {
        guard var selection = testAuthoringSelection else { return }
        do {
            selection = try RustTestAuthoringCoordinator.apply(
                .setChoice(controlID: "geometry-mode", optionID: "free"), to: selection
            )
            let degrees = PoseRotationProjection.degrees(from: [
                pose.orientation.imag.x, pose.orientation.imag.y,
                pose.orientation.imag.z, pose.orientation.real,
            ])
            for (id, value) in [
                ("camera-position-x-meters", pose.position.x),
                ("camera-position-y-meters", pose.position.y),
                ("camera-position-z-meters", pose.position.z),
                ("camera-rotation-x-degrees", degrees[0]),
                ("camera-rotation-y-degrees", degrees[1]),
                ("camera-rotation-z-degrees", degrees[2]),
            ] {
                selection = try RustTestAuthoringCoordinator.apply(
                    .setScalar(controlID: id, value: value), to: selection
                )
            }
            selection = try RustTestAuthoringCoordinator.apply(
                .setChoice(controlID: "preview-quality", optionID: "setup"), to: selection
            )
            try applyTestAuthoringSelection(selection)
        } catch { errorMessage = error.localizedDescription }
    }

    private func restoreCameraNavigationSelection(
        _ selection: TestAuthoringResolvedSelection,
        undoManager: UndoManager?
    ) throws {
        let prior = testAuthoringSelection
        try applyTestAuthoringSelection(selection)
        if let prior {
            let manager = UndoManagerBox(undoManager)
            undoManager?.registerUndo(withTarget: self) { target in
                Task { @MainActor in
                    try? target.restoreCameraNavigationSelection(
                        prior, undoManager: manager.value
                    )
                }
            }
            undoManager?.setActionName("Navegar cámara")
        }
    }

    func browseEnvironment() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
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
        inputPicker.selectItem(at: inputTransforms.firstIndex { $0.id == "acescg" } ?? 0)
        let radianceField = NSTextField(string: "1")
        let exposureField = NSTextField(string: "0")
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
        Task {
            await loadEnvironment(
                url, inputTransformID: inputID,
                unitRadiance: unitRadiance, exposureStops: exposureStops
            )
        }
    }

    private func loadEnvironment(
        _ url: URL,
        inputTransformID: String,
        unitRadiance: Double,
        exposureStops: Double
    ) async {
        do {
            status = "Decodificando entorno HDR…"
            let decoded = try await NativeMediaDecoder.decode(url: url, time: .zero)
            guard decoded.width == decoded.height * 2 else {
                throw EnvironmentRadianceFrameError.invalidEquirectangularRaster
            }
            guard let input = StudioColorInputTransform.catalog.first(where: {
                $0.id == inputTransformID && $0.referenceDomain == .sceneReferred
            })
            else {
                throw NativeMediaError.unreadable(
                    "El Input Transform explícito del entorno no existe o no es scene-referred."
                )
            }
            let source = try metalDisplay.makeACEScgFrame(
                width: decoded.width, height: decoded.height,
                encodedRGBA: decoded.rgba, input: input, alpha: .ignore
            )
            let environment = try EnvironmentRadianceFrame.prefiltered(from: source)
            guard var authored = physicalAuthoringState else { return }
            authored.environment.sourceKind = 1
            authored.environment.sourceUnitRadianceCandelasPerSquareMeter = unitRadiance
            authored.environment.exposureStops = exposureStops
            authored.environment.ambientRadianceACEScg = [0, 0, 0]
            authored.environment.keyRadianceACEScg = [0, 0, 0]
            authored.environment.pattern = 0
            resolvedPhysicalPipeline = try authored.resolvedPipeline()
            physicalAuthoringState = authored
            environmentRadianceFrame = environment
            authoredImageEnvironment = authored.environment
            environmentSourceName = url.lastPathComponent
            environmentSourceInputTransformID = inputTransformID
            environmentSourceHash = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }.joined()
            try physicalModel.setContinuousAmount(1, stage: .screen(.environment))
            physicalModel.invalidateExternalParameters()
            status = "Entorno · \(url.lastPathComponent) · \(decoded.width)×\(decoded.height) · \(input.label)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func testPhaseToReveal(for intent: TestControlIntent) -> String? {
        let controlID: String
        switch intent {
        case let .setChoice(id, _), let .setScalar(id, _), let .setToggle(id, _): controlID = id
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

    func changePhysicalQuality(_ quality: PhysicalQuality) {
        physicalModel.setQuality(quality)
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
            undoManager?.registerUndo(withTarget: self) { target in
                Task { @MainActor in
                    target.changePhysicalDomainBypass(
                        prior,
                        domain: domain,
                        undoManager: nil
                    )
                }
            }
            undoManager?.setActionName(bypassed ? "Omitir Pantalla" : "Activar Pantalla")
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
            undoManager?.registerUndo(withTarget: self) { target in
                Task { @MainActor in
                    target.changePhysicalStageBypass(
                        prior,
                        stage: stage,
                        undoManager: nil
                    )
                }
            }
            undoManager?.setActionName(bypassed ? "Omitir etapa" : "Activar etapa")
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
        do { try physicalModel.beginNative() }
        catch { return }
        nativeRenderTaskActive = true
        physicalNativeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let job = try submitPhysicalJob(quality: .native)
                physicalNativeJob = job
                if nativeCancellationRequested {
                    _ = job.cancel()
                }
                try await pollPhysicalJob(
                    job,
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

    var activeFrameRange: ClosedRange<Int> {
        renderRange == .inOut ? min(inFrame, outFrame) ... max(inFrame, outFrame) : 0 ... max(0, frameCount - 1)
    }

    func inputAnnotation(_ value: StudioColorInputTransform) -> String? {
        if value.id == detection.proposedInputTransformID {
            return detection.inputTransformProvenance?.feminineLabel ?? "Propuesta"
        }
        return detection.proposedInputTransformID == nil && value.id == defaultInputTransformID
            ? "Predeterminada" : nil
    }

    func alphaAnnotation(_ value: StudioAlphaMode) -> String? {
        if value == detection.alpha {
            return detection.alphaProvenance?.masculineLabel ?? "Propuesto"
        }
        return detection.alpha == nil && value == defaultAlphaMode ? "Predeterminado" : nil
    }

    func matrixAnnotation(_ value: StudioSignalMatrix) -> String? {
        if value == detection.matrix {
            return detection.matrixProvenance?.feminineLabel ?? "Propuesta"
        }
        return detection.matrix == nil && value == defaultSignalMatrix ? "Predeterminada" : nil
    }

    func rangeAnnotation(_ value: StudioSignalRange) -> String? {
        if value == detection.range {
            return detection.rangeProvenance?.masculineLabel ?? "Propuesto"
        }
        return detection.range == nil && value == defaultSignalRange ? "Predeterminado" : nil
    }

    func colorModelAnnotation(_ value: StudioSignalColorModel) -> String? {
        if value == detection.colorModel {
            return detection.colorModelProvenance?.masculineLabel ?? "Propuesto"
        }
        return detection.colorModel == nil && value == defaultSignalColorModel
            ? "Predeterminado" : nil
    }

    func choosePattern(_ pattern: SyntheticPattern, undoManager: UndoManager?) {
        let prior = selectedPattern
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.choosePattern(prior, undoManager: nil) }
        }
        pause()
        selectedPattern = pattern
        sourceIsPattern = true
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
        defaultInputTransformID = inputID
        defaultAlphaMode = resolvedAlpha
        defaultSignalMatrix = resolvedMatrix
        defaultSignalRange = resolvedRange
        defaultSignalColorModel = resolvedColorModel
        currentFrame = 0
        frameRate = 24
        frameCount = pattern == .animatedCheckerboard ? 240 : 1
        outFrame = frameCount - 1
        do {
            if let selection = currentTestAuthoringSelection() {
                let resolved = try RustTestAuthoringCoordinator.apply(
                    .setChoice(
                        controlID: "placement",
                        optionID: pattern.authoredPlacementID
                    ),
                    to: selection
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

    func openMedia() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .image, .folder]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        Task { await load(panel.urls) }
    }

    func load(_ urls: [URL]) async {
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
        let defaultInputID = isVideo
            ? "display-rec709-gamma24-dcm"
            : "srgb-encoded-rec709"
        defaultInputTransformID = defaultInputID
        defaultAlphaMode = detection.hasAlpha ? .straight : .ignore
        defaultSignalMatrix = .bt709
        defaultSignalRange = isVideo ? .video : .full
        defaultSignalColorModel = .rgb
        let resolvedInputID = detection.proposedInputTransformID ?? defaultInputID
        inputTransform = StudioColorInputTransform.catalog.first {
            $0.id == resolvedInputID
        }!
        alphaMode = detection.alpha ?? defaultAlphaMode
        signalMatrix = detection.matrix ?? defaultSignalMatrix
        signalRange = detection.range ?? defaultSignalRange
        signalColorModel = detection.colorModel ?? defaultSignalColorModel
        do {
            let info = isVideo
                ? try await session.openVideo(
                    first,
                    hasAlpha: detection.hasAlpha,
                    colorModel: signalColorModel,
                    decodedRange: signalRange
                )
                : try session.openImages(expanded.filter(Self.isImage))
            sourceIsPattern = false
            sourceName = info.name
            sourceDetail = info.detail + (detection.note.map { " · Metadata: \($0)" } ?? "")
            frameRate = info.frameRate
            frameCount = info.frameCount
            currentFrame = 0
            inFrame = 0
            outFrame = max(0, info.frameCount - 1)
            includeAudio = info.hasAudio
            session.play()
            try await Task.sleep(for: .milliseconds(20))
            session.pause()
            try present(try await session.exactSample(at: .zero))
        } catch {
            errorMessage = error.localizedDescription
            status = "No se pudo abrir el medio"
        }
    }

    func changeInput(_ value: StudioColorInputTransform, undoManager: UndoManager?) {
        let prior = inputTransform
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.changeInput(prior, undoManager: nil) }
        }
        inputTransform = value
        rebuildCurrent()
    }

    func changeAlpha(_ value: StudioAlphaMode, undoManager: UndoManager?) {
        let prior = alphaMode
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.changeAlpha(prior, undoManager: nil) }
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
        rebuildCurrent()
    }

    func changePreview(_ value: StudioColorOutputTransform, undoManager: UndoManager?) {
        do {
            try metalDisplay.prepare(value)
        } catch {
            errorMessage = "No se puede activar \(value.label): \(error.localizedDescription)"
            return
        }
        let prior = previewTransform
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.changePreview(prior, undoManager: nil) }
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
        isPlaying = true
        if sourceIsPattern { return }
        session.play()
    }

    func pause() {
        isPlaying = false
        session.pause()
    }

    func seek(toFrame frame: Int) {
        pause()
        currentFrame = min(max(0, frame), max(0, frameCount - 1))
        if sourceIsPattern {
            renderPattern()
        } else {
            Task {
                do {
                    let time = session.time(forFrame: currentFrame)
                    try await session.seek(to: time)
                    try present(try await session.exactSample(at: time))
                } catch { errorMessage = error.localizedDescription }
            }
        }
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

    func fitPreview() {
        previewIsFitted = true
        pan = .zero
    }
    func showPreviewOneToOne() {
        previewIsFitted = false
        zoom = 1
        pan = .zero
    }
    func updateFittedZoom(_ value: Double) {
        guard previewIsFitted, value.isFinite, value > 0,
              abs(zoom - value) > 0.000_001
        else { return }
        zoom = value
    }
    func setInteractiveZoom(_ value: Double) {
        previewIsFitted = false
        zoom = min(16, max(0.01, value))
    }
    func resetView() { fitPreview() }
    func fitModelPreview() {
        modelViewerOneToOne = false
        resetView()
    }
    func showModelPreviewOneToOne() {
        modelViewerOneToOne = true
        resetView()
    }
    func zoomBy(_ factor: Double) {
        setInteractiveZoom(zoom * factor)
    }
    var zoomPercentage: Double {
        zoom * 100
    }
    func setZoomPercentage(_ percentage: Double) {
        setInteractiveZoom(percentage / 100)
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

    func applyRenderPreset(_ preset: StudioRenderPreset) {
        renderPreset = preset
        peakNits = preset.peakNits
        changeOutputFormat(preset.format)
        outputPixelEncoding = preset.pixelEncoding
        outputSignalRange = preset.signalRange
        outputAlphaMode = preset.alpha
        includeAudio = preset.includeAudio
    }

    func enqueueExport() {
        guard metalFrame != nil else { return }
        let url: URL?
        if outputFormat.isMovie {
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = sourceName.replacingOccurrences(of: ".", with: "-")
            panel.allowedContentTypes = [.movie]
            url = panel.runModal() == .OK ? panel.url : nil
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            url = panel.runModal() == .OK ? panel.url : nil
        }
        guard let url else { return }
        let range = activeFrameRange
        let configuration = StudioResolvedRenderConfiguration(
            format: outputFormat,
            pipeline: renderPreset.pipeline,
            target: renderPreset.target,
            peakNits: peakNits,
            display: renderPreset.display,
            view: renderPreset.view,
            pixelEncoding: outputPixelEncoding,
            signalRange: outputSignalRange,
            alpha: outputFormat.supportsAlpha ? outputAlphaMode : .ignore,
            includeAudio: outputFormat.isMovie && includeAudio,
            frameRate: frameRate,
            firstFrame: range.lowerBound,
            lastFrame: range.upperBound
        )
        jobs.append(RenderJob(destination: url, configuration: configuration))
    }

    func runQueue() {
        guard renderTask == nil,
              let index = jobs.firstIndex(where: { $0.state == .pending })
        else { return }
        pause()
        jobs[index].state = .rendering
        jobs[index].detail = "Preparando grafo Metal"
        let job = jobs[index]
        renderTask = Task {
            do {
                let url = try await NativeOutputRenderer.render(
                    configuration: job.configuration,
                    destination: job.destination,
                    audioSource: session.sourceURL,
                    display: metalDisplay,
                    frameProvider: { [weak self] frame in
                        guard let self else { throw CancellationError() }
                        return try await self.renderFrame(frame)
                    },
                    progress: { [weak self] completed, total in
                        guard let self,
                              let live = self.jobs.firstIndex(where: { $0.id == job.id })
                        else { return }
                        self.jobs[live].progress = Double(completed) / Double(total)
                        self.jobs[live].detail = "\(completed) / \(total)"
                    }
                )
                if let live = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[live].state = .completed
                    jobs[live].progress = 1
                    jobs[live].detail = url.lastPathComponent
                }
            } catch is CancellationError {
                if let live = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[live].state = .cancelled
                    jobs[live].detail = "Cancelado"
                }
            } catch {
                if let live = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[live].state = .failed
                    jobs[live].detail = error.localizedDescription
                }
                errorMessage = error.localizedDescription
            }
            renderTask = nil
            runQueue()
        }
    }

    func cancelRender() {
        renderTask?.cancel()
    }

    func renderCurrentFrame() {
        guard let metalFrame else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let quality = switch physicalModel.quality {
        case .setup: "Setup"
        case .draft: "Draft"
        case .medium: "Media"
        case .high: "Alta"
        case .native: "Nativa"
        }
        panel.nameFieldStringValue = String(
            format: "ScreenSimulation-%@-%08d.png", quality, currentFrame
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try NativeOutputRenderer.renderCurrentFrame(
                frame: metalFrame, displayTransform: previewTransform,
                metadata: currentFrameCheckMetadata(quality: quality, frame: metalFrame),
                destination: url, display: metalDisplay
            )
            status = "Frame \(quality) renderizado · \(url.lastPathComponent)"
        } catch { errorMessage = error.localizedDescription }
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
        var document: [String: Any] = [
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
        if let device = modelDeviceDefinition ?? resolvedDevice?.definition,
           let state = physicalAuthoringState,
           let context = currentSettingsContext(),
           let settings = PhysicalSettingsExchange.metadata(
               device: device,
               pipeline: state,
               model: physicalModel.authoringState,
               context: context
           ) {
            document["settings"] = settings
        }
        return document
    }

    func importPhysicalSettings(undoManager: UndoManager?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = false
        panel.message = "Recupera todos los ajustes que generaron el frame; zoom y pan se conservan."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let png = try Data(contentsOf: url)
            guard let metadata = FrameCheckPNG.metadataForSelectedImport(in: png),
                  let document = try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
            else {
                throw PhysicalSettingsExchange.ImportError.missingSettings
            }
            let imported = try PhysicalSettingsExchange.decode(from: document)
            guard confirmPhysicalSettingsImport(imported.report) else { return }
            try applyPhysicalSettings(imported, undoManager: undoManager)
            status = "Ajustes físicos importados · \(url.lastPathComponent)"
        } catch {
            errorMessage = error.localizedDescription
        }
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
            environmentResource: .init(
                kind: environmentRadianceFrame == nil ? .procedural : .image,
                fileName: environmentSourceName,
                sha256: environmentSourceHash,
                inputTransformID: environmentSourceInputTransformID
            )
        )
    }

    private func applyPhysicalSettings(
        _ imported: PhysicalSettingsExchange.Imported,
        undoManager: UndoManager?
    ) throws {
        if let resource = imported.context?.environmentResource,
           resource.kind == .image,
           (environmentSourceHash != resource.sha256
               || environmentSourceInputTransformID != resource.inputTransformID) {
            throw PhysicalSettingsExchange.ImportError.unavailableEnvironmentResource(
                resource.fileName ?? "sin nombre"
            )
        }
        guard let priorDevice = modelDeviceDefinition ?? resolvedDevice?.definition,
              let priorPipeline = physicalAuthoringState
        else { throw PhysicalSettingsExchange.ImportError.invalidModel }
        let prior = ImportedPhysicalState(
            device: priorDevice,
            pipeline: priorPipeline,
            model: physicalModel.authoringState,
            context: currentSettingsContext()
        )
        try restoreImportedPhysicalState(.init(
            device: imported.device,
            pipeline: imported.pipeline,
            model: imported.model,
            context: imported.context
        ))
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in try? target.restoreImportedPhysicalState(prior) }
        }
        undoManager?.setActionName("Importar ajustes físicos")
    }

    private func restoreImportedPhysicalState(_ state: ImportedPhysicalState) throws {
        resolvedDevice = try state.device.resolved()
        resolvedPhysicalPipeline = try state.pipeline.resolvedPipeline()
        try physicalModel.restoreAuthoringState(state.model)
        modelDeviceDefinition = state.device
        physicalAuthoringState = state.pipeline
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
                environmentSourceHash = nil
                environmentSourceInputTransformID = nil
            case .image:
                authoredImageEnvironment = state.pipeline.environment
                environmentSourceName = context.environmentResource.fileName
                environmentSourceHash = context.environmentResource.sha256
                environmentSourceInputTransformID = context.environmentResource.inputTransformID
            }
            testAuthoringSelection = context.selection
            selectedCapturePresetID = context.selection.capturePresetID
            selectedCaptureRasterModeID = context.selection.captureRasterModeID
            selectedLensPresetID = context.selection.lensPresetID
            testPresentation = snapshot.presentation
            testPreviewResultByPhaseID = snapshot.previewResultByPhaseID
            physicalModel.setQuality(quality)
        }
        resolvedDevice = try state.device.resolved()
        resolvedPhysicalPipeline = try state.pipeline.resolvedPipeline()
        try physicalModel.restoreAuthoringState(state.model)
        modelDeviceDefinition = state.device
        physicalAuthoringState = state.pipeline
        physicalModel.invalidateExternalParameters()
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
            return
        }
        renderCurrentMediaFrame()
    }

    private func restartPlayback(at frame: Int) {
        currentFrame = frame
        if sourceIsPattern {
            isPlaying = true
            renderPattern()
            return
        }
        Task {
            do {
                let time = session.time(forFrame: frame)
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
        sourceIsPattern ? renderPattern() : renderCurrentMediaFrame(at: session.time(forFrame: currentFrame))
    }

    private func renderPattern() {
        let started = CACurrentMediaTime()
        do {
            let decoded = try selectedPattern.frame(time: requestedSeconds)
            let base = try metalDisplay.makeACEScgFrame(
                width: decoded.width, height: decoded.height, encodedRGBA: decoded.rgba,
                input: inputTransform, alpha: effectiveAlpha
            )
            sourceACEScgFrame = base
            physicalModel.invalidateExternalParameters()
            metalFrame = base
            if let metalFrame {
                monitorOutput.update(frame: metalFrame, display: metalDisplay)
            }
            sourceDetail = "Patrón SCREEN canónico · \(decoded.width) × \(decoded.height)"
            decodeToPreviewMilliseconds = (CACurrentMediaTime() - started) * 1_000
            status = "Textura ACEScg Metal · \(decodeToPreviewMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
            rebuildPhysicalSelectedFrame()
            publishSelectedTestPreview()
        } catch {
            metalFrame = nil
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
        sourceACEScgFrame = base
        physicalModel.invalidateExternalParameters()
        metalFrame = base
        if let metalFrame {
            monitorOutput.update(frame: metalFrame, display: metalDisplay)
        }
        currentFrame = min(frameCount - 1, max(0, Int((sample.time.seconds * frameRate).rounded())))
        decodeToPreviewMilliseconds = (CACurrentMediaTime() - started) * 1_000
        status = "CVPixelBuffer → ACEScg → Preview · \(decodeToPreviewMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
        rebuildPhysicalSelectedFrame()
        publishSelectedTestPreview()
    }

    private func renderFrame(_ index: Int) async throws -> StudioColorMetalFrame {
        if sourceIsPattern {
            let decoded = try selectedPattern.frame(time: Double(index) / frameRate)
            let base = try metalDisplay.makeACEScgFrame(
                width: decoded.width, height: decoded.height,
                encodedRGBA: decoded.rgba, input: inputTransform, alpha: effectiveAlpha
            )
            return base
        }
        let time = session.time(forFrame: index)
        try Task.checkCancellation()
        guard let sample = try await session.exactSample(at: time) else {
            throw NativeMediaError.unreadable("frame \(index)")
        }
        let base = try metalDisplay.makeACEScgFrame(
            pixelBuffer: sample.pixelBuffer, input: inputTransform,
            alpha: effectiveAlpha, matrix: effectiveMatrix, range: effectiveRange
        )
        return base
    }

    private func rebuildPhysicalSelectedFrame() {
        let testNeedsPhysicalResult = isTestPageActive
            && selectedTestPhysicalIntermediate != nil
        guard isModelPageActive || testNeedsPhysicalResult else {
            _ = physicalInteractiveJob?.cancel()
            physicalInteractiveTask?.cancel()
            if !isTestPageActive, let sourceACEScgFrame { metalFrame = sourceACEScgFrame }
            return
        }
        if physicalModel.quality == .setup {
            _ = physicalInteractiveJob?.cancel()
            physicalInteractiveTask?.cancel()
            publishSetupFraming()
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
                let job = try submitPhysicalJob(quality: quality)
                submittedJob = job
                physicalInteractiveJob = job
                try await pollPhysicalJob(
                    job,
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

    private func publishSetupFraming() {
        guard let sourceACEScgFrame,
              let device = modelDeviceDefinition ?? resolvedDevice?.definition,
              let authored = physicalAuthoringState
        else { return }
        do {
            let started = CACurrentMediaTime()
            if setupFramingRenderer == nil {
                setupFramingRenderer = try SetupFramingRenderer(device: sourceACEScgFrame.texture.device)
            }
            let selection = testAuthoringSelection
            let width = Int(selection?.deliveryWidth ?? UInt32(sourceACEScgFrame.width))
            let height = Int(selection?.deliveryHeight ?? UInt32(sourceACEScgFrame.height))
            let result = try setupFramingRenderer!.render(
                source: sourceACEScgFrame,
                sourcePlacement: sourcePlacement,
                device: device,
                pipeline: authored,
                deliveryWidth: width,
                deliveryHeight: height,
                deliveryPlacementID: selection?.deliveryPlacementID ?? "fit",
                deliveryBackgroundID: selection?.deliveryBackgroundID ?? "black"
            )
            metalFrame = result.frame
            setupDeviceBoundary = result.boundary
            monitorOutput.update(frame: result.frame, display: metalDisplay)
            let elapsedMilliseconds = (CACurrentMediaTime() - started) * 1_000
            status = "Setup · encuadre ideal · \(width)×\(height) · \(elapsedMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
            physicalPublicationSummary = "Setup · fuente + Device + cámara + Delivery Raster · publicado"
        } catch {
            setupDeviceBoundary = []
            errorMessage = error.localizedDescription
        }
    }

    private func submitPhysicalJob(
        quality: PhysicalQuality
    ) throws -> PhysicalMetalFrameJob {
        guard let sourceACEScgFrame else {
            throw PhysicalEvaluationAvailabilityError.missingSelectedFrame
        }
        guard let resolvedDevice else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "El modelo físico necesita un snapshot de Device resuelto."
            )
        }
        guard let resolvedPhysicalPipeline else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "El modelo físico necesita un snapshot completo resuelto."
            )
        }
        guard let physicalAuthoringState else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "El modelo físico necesita overrides de proyecto resueltos."
            )
        }
        let outputSignal = try resolvedOutputSignal()
        let checkpoint = try DeviceSignalCheckpoint.prepare(
            sourceACEScg: sourceACEScgFrame,
            inputTransform: inputTransform,
            outputSignal: outputSignal,
            alphaInterpretation: String(describing: effectiveAlpha),
            display: metalDisplay
        )
        deviceSignalCheckpoint = checkpoint
        let deviceSignal = checkpoint.deviceSignal
        let contributions = physicalModel.orderedContributions
        guard let uniformityAmount = contributions.first(where: {
            $0.stage == .screen(.panelUniformity)
        })?.amount else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "Falta la contribución resuelta de Panel Uniformity."
            )
        }
        guard let spreadAmount = contributions.first(where: {
            $0.stage == .screen(.panelLightSpread)
        })?.amount else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "Falta la contribución resuelta de Panel Light Spread."
            )
        }
        var effectiveDeviceDefinition = resolvedDevice.definition
        effectiveDeviceDefinition.panelUniformity.characterStrength = uniformityAmount
        effectiveDeviceDefinition.panelLightSpread.characterStrength = spreadAmount
        let effectiveDevice = try effectiveDeviceDefinition.resolved()
        let effectivePipeline = try resolvedPhysicalPipeline.resolving(
            contributions: contributions
        )
        physicalIdentityCounter &+= 1
        let identity = PhysicalFrameIdentity(
            high: physicalModel.parameterRevision,
            low: physicalIdentityCounter
        )
        physicalPublicationSummary = "Source \(sourceACEScgFrame.width)×\(sourceACEScgFrame.height) · Device \(deviceSignal.width)×\(deviceSignal.height) · \(quality.uiLabel)/\(requestedPhysicalIntermediate.uiLabel) · enviado"
        physicalPublicationLog.notice(
            "submit source=\(sourceACEScgFrame.width)x\(sourceACEScgFrame.height) device=\(deviceSignal.width)x\(deviceSignal.height) quality=\(quality.uiLabel, privacy: .public) intermediate=\(self.requestedPhysicalIntermediate.uiLabel, privacy: .public) cameraZ=\(physicalAuthoringState.cameraPose.position[2])"
        )
        let selection = try PhysicalFrameSelection(
            frameIndex: Int64(currentFrame),
            timeNumerator: Int64(currentFrame),
            timeDenominator: UInt32(max(1, Int(frameRate.rounded())))
        )
        return try physicalEngine.submit(
            sourceACEScg: sourceACEScgFrame,
            deviceSignal: deviceSignal,
            environmentACEScg: environmentRadianceFrame,
            orchestration: try physicalAuthoringState.orchestration(for: selection),
            resolvedDevice: effectiveDevice,
            resolvedPipeline: effectivePipeline,
            quality: quality,
            screenAmount: physicalModel.effectiveScreenAmount,
            contributions: contributions,
            requestedDimensions: try physicalRequestedDimensions(
                quality: quality,
                device: resolvedDevice.definition
            ),
            cancellationIdentity: identity,
            progressIdentity: identity,
            parameterRevision: physicalModel.parameterRevision,
            parameterHash: try physicalParameterHash(
                quality: quality,
                device: resolvedDevice.definition
            ),
            rasterPlacement: sourcePlacement.physicalRasterPlacement,
            requestedIntermediate: requestedPhysicalIntermediate
        )
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

    private func refreshTestAuthoringDescriptor() throws {
        guard let device = modelDeviceDefinition ?? resolvedDevice?.definition else { return }
        if testAuthoringSelection == nil {
            let initial = try RustTestAuthoringCoordinator.defaultSelection(
                inputTransformID: inputTransform.id,
                deviceID: device.id,
                frameRate: frameRate
            )
            testAuthoringSelection = sourceIsPattern
                ? try RustTestAuthoringCoordinator.apply(
                    .setChoice(
                        controlID: "placement",
                        optionID: selectedPattern.authoredPlacementID
                    ),
                    to: initial
                )
                : initial
        }
        guard var selection = testAuthoringSelection else { return }
        selection.frameRate = frameRate
        testAuthoringSelection = selection
        let snapshot = try RustTestAuthoringCoordinator.snapshot(
            selection: selection,
            selectedPreviewPhaseID: testPresentation?.selectedPhaseID
        )
        testPresentation = snapshot.presentation
        testPreviewResultByPhaseID = snapshot.previewResultByPhaseID
        publishSelectedTestPreview()
    }

    private func applyTestAuthoringSelection(
        _ selection: TestAuthoringResolvedSelection
    ) throws {
        let previous = testAuthoringSelection
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
        guard var device = try RustDeviceCatalog.builtIns().first(where: {
            $0.id == selection.deviceID
        }) else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "Rust devolvió un Device que no existe en su catálogo."
            )
        }
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
        guard let cover = try RustCoverGlassCatalog.builtIns().first(where: {
            $0.id == selection.coverGlassPresetID
        }) else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "El Device seleccionado no resuelve su Cover Glass."
            )
        }
        resolvedDevice = try device.resolved()
        modelDeviceDefinition = device
        var selectedCover = cover
        selectedCover.characterStrength = selection.coverGlassAmount
        selectedCover.agMicrotextureCharacterStrength = selection.coverAgMicrotextureAmount
        selectedCover.glowCharacterStrength = selection.coverGlowAmount
        var authored = try PhysicalPipelineAuthoringState.seeded(
            device: device,
            coverGlass: selectedCover
        )
        guard let capture = capturePresets.first(where: {
            $0.id == selection.capturePresetID
        }), let environment = environmentPresets.first(where: {
            $0.id == selection.environmentPresetID
        }) else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "Rust devolvió una cámara o entorno que no existe en sus catálogos."
            )
        }
        try apply(
            capture: capture,
            rasterModeID: selection.captureRasterModeID,
            lensID: selection.lensPresetID,
            to: &authored
        )
        environment.apply(to: &authored)
        if let authoredImageEnvironment {
            authored.environment = authoredImageEnvironment
        }
        authored.sceneLens.focusPolicy = selection.autofocusEnabled
            ? "autofocus-screen" : "manual"
        authored.sceneLens.evaluationModel = selection.lensEvaluationModelID
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
                to: authored.screenPose.position
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
            stage: .capture(.noise)
        )
        selectedCapturePresetID = capture.id
        selectedCaptureRasterModeID = selection.captureRasterModeID
        selectedLensPresetID = selection.lensPresetID
        physicalAuthoringState = authored
        resolvedPhysicalPipeline = try authored.resolvedPipeline()
        baseModelDeviceDefinition = device
        basePhysicalAuthoringState = authored
        try refreshTestAuthoringDescriptor()
        rebuildCurrent()
        // Rebuilding the source invalidates the previous physical frame and
        // deliberately returns the viewer to Setup. Apply an explicitly
        // authored physical quality only after that final invalidation.
        physicalModel.setQuality(quality)
    }

    private var selectedTestPreviewResult: TestPreviewResultKind? {
        guard let phaseID = testPresentation?.selectedPhaseID else { return nil }
        return testPreviewResultByPhaseID[phaseID]
    }

    private var selectedTestPhysicalIntermediate: PhysicalIntermediate? {
        physicalIntermediate(for: selectedTestPreviewResult)
    }

    private func physicalIntermediate(
        for result: TestPreviewResultKind?
    ) -> PhysicalIntermediate? {
        switch result {
        case .feederSignal: .deviceSignal
        case .deviceInterpretation: .panelEmission
        case .panelStructure: .subpixelRadiance
        case .panelUniformity: .panelUniformity
        case .panelLightSpread: .panelLightSpread
        case .relativeGeometry: .relativeGeometry
        case .coverEnvironment: .coverEnvironment
        case .coverGlow: .coverGlow
        case .lensProjection: .lensProjection
        case .shutterExposure: .shutterMotion
        case .computationalCapture: .computationalCapture
        case .sensorBloom: .sensorBloom
        case .sensorCfa: .sensorNoise
        case .sensorNoise: .rawMosaic
        case .developDemosaic: .developedACEScg
        case .cameraRenderingIntent, .deliveryRaster, .recordingOutput, .recordingCodec: .cameraRenderedACEScg
        case .sourceACEScg, nil: nil
        }
    }

    private func publishSelectedTestPreview() {
        guard let sourceACEScgFrame else { return }
        guard isTestPageActive,
              let presentation = testPresentation,
              let result = testPreviewResultByPhaseID[presentation.selectedPhaseID]
        else {
            metalFrame = sourceACEScgFrame
            monitorOutput.update(frame: sourceACEScgFrame, display: metalDisplay)
            return
        }
        let presentationFrame: StudioColorMetalFrame
        switch result {
        case .sourceACEScg:
            updateRequestedPhysicalIntermediate(.sourceACEScg)
            presentationFrame = sourceACEScgFrame
        case .feederSignal:
            updateRequestedPhysicalIntermediate(.deviceSignal)
            rebuildPhysicalSelectedFrame()
            return
        case .deviceInterpretation, .panelStructure, .panelUniformity, .panelLightSpread,
             .relativeGeometry, .coverEnvironment, .coverGlow, .lensProjection,
             .shutterExposure, .computationalCapture, .sensorBloom, .sensorCfa, .sensorNoise,
             .developDemosaic, .cameraRenderingIntent, .deliveryRaster, .recordingOutput, .recordingCodec:
            updateRequestedPhysicalIntermediate(physicalIntermediate(for: result)!)
            rebuildPhysicalSelectedFrame()
            return
        }
        metalFrame = presentationFrame
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
            let delivery: StudioColorMetalFrame
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
                metalFrame = delivery
                monitorOutput.update(frame: delivery, display: metalDisplay)
                return
            }
            let output: RecordingOutputExecution
            if let cached = recordingOutputExecution {
                output = cached
            } else {
                output = try RecordingPhaseExecutor.output(
                    cameraRendered: delivery,
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
            metalFrame = frame
            monitorOutput.update(frame: frame, display: metalDisplay)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pollPhysicalJob(
        _ job: PhysicalMetalFrameJob,
        native: Bool
    ) async throws {
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
                physicalPublicationLog.error(
                    "job state=failed quality=\(snapshot.computedQuality.uiLabel, privacy: .public) intermediate=\(snapshot.returnedIntermediate.uiLabel, privacy: .public)"
                )
                throw PhysicalMetalFrameEngineError.bridge(
                    snapshot.diagnostics.last?.message ?? "La evaluación física ha fallado."
                )
            case .complete:
                guard snapshot.parameterRevision == physicalModel.parameterRevision,
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
                metalFrame = presentationFrame
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
        device: DeviceDefinition
    ) throws -> PhysicalDimensions {
        if quality == .setup {
            throw PhysicalEvaluationAvailabilityError.sectionPending(.capture(.geometry))
        }
        if quality == .native {
            return try PhysicalDimensions(
                width: device.nativeWidth,
                height: device.nativeHeight
            )
        }
        let aspect = Double(device.nativeWidth) / Double(device.nativeHeight)
        var width = max(1, Int(modelViewport.width.rounded(.down)))
        var height = max(1, Int((Double(width) / aspect).rounded(.down)))
        if height > Int(modelViewport.height) {
            height = max(1, Int(modelViewport.height.rounded(.down)))
            width = max(1, Int((Double(height) * aspect).rounded(.down)))
        }
        let scale: Double = switch quality {
        case .setup: 1
        case .draft: 0.5
        case .medium: 1
        case .high: 1.5
        case .native: 1
        }
        return try PhysicalDimensions(
            width: min(device.nativeWidth, max(1, Int(Double(width) * scale))),
            height: min(device.nativeHeight, max(1, Int(Double(height) * scale)))
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
