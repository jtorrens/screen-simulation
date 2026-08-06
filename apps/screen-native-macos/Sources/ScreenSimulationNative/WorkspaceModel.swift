@preconcurrency import AVFoundation
import AppKit
import Combine
import CryptoKit
import Foundation
import StudioColor
import StudioMedia

@MainActor
final class WorkspaceModel: ObservableObject {
    enum SourcePlacement: String, CaseIterable, Identifiable {
        case fit = "Fit"
        case fillCrop = "Fill / Crop"
        case stretch = "Stretch"
        case oneToOne = "One to One"

        var id: String { rawValue }
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
        $0.id == "input-rec709"
    }!
    @Published var previewTransform = StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-srgb-sdr-100"
    }!
    @Published var systemDisplayInfo = StudioColorSystemDisplayInfo.unavailable
    @Published var alphaMode = StudioAlphaMode.ignore
    @Published var signalColorModel = StudioSignalColorModel.rgb
    @Published var signalMatrix = StudioSignalMatrix.bt709
    @Published var signalRange = StudioSignalRange.full
    @Published var detection = StudioMediaDetection()
    @Published var selectedPattern = SyntheticPattern.animatedCheckerboard
    @Published var sourceName = "Checker animado"
    @Published var sourceDetail = "Patrón SCREEN canónico · 960 × 540"
    @Published var status = "Preparado"
    @Published var metalFrame: StudioColorMetalFrame?
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
    @Published var pan = CGSize.zero
    @Published private(set) var defaultInputTransformID = "input-rec709"
    @Published private(set) var defaultAlphaMode = StudioAlphaMode.ignore
    @Published private(set) var defaultSignalColorModel = StudioSignalColorModel.rgb
    @Published private(set) var defaultSignalMatrix = StudioSignalMatrix.bt709
    @Published private(set) var defaultSignalRange = StudioSignalRange.full
    @Published private(set) var resolvedDevice: ResolvedDevice?
    @Published private(set) var requestedPhysicalIntermediate = PhysicalIntermediate.developedACEScg
    @Published private(set) var sourceACEScgFrame: StudioColorMetalFrame?
    @Published var sourcePlacement = SourcePlacement.fit
    @Published var modelViewerOneToOne = false

    let metalDisplay: StudioColorMetalDisplay
    let monitorOutput = MonitorOutputController()
    let physicalModel = PhysicalModelController()
    private let deviceSignalTransform = StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-srgb-sdr-100"
    }!
    private let deviceSignalInverseTransform = StudioColorInputTransform.catalog.first {
        $0.id == "display-srgb-aces2-sdr"
    }!
    private let session = NativeMediaSession()
    private var sourceIsPattern = true
    private var tickSubscription: AnyCancellable?
    private var physicalSubscription: AnyCancellable?
    private var renderTask: Task<Void, Never>?
    private var physicalNativeTask: Task<Void, Never>?
    private var physicalInteractiveTask: Task<Void, Never>?
    private var physicalNativeJob: PhysicalMetalFrameJob?
    private var physicalInteractiveJob: PhysicalMetalFrameJob?
    private let physicalEngine = PhysicalMetalFrameEngine()
    private var physicalIdentityCounter: UInt64 = 0
    private var modelViewport = CGSize(width: 960, height: 540)
    private var isModelPageActive = false
    private var resolvedPhysicalPipeline: PhysicalPipelineResolvedState?

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
        "Input → YUV/rango → IDT → ACEScg → Pantalla → Captura → Display/ODT"
    }

    func selectDevice(
        _ definition: DeviceDefinition,
        coverGlass: CoverGlassDefinition,
        amount _: Double
    ) {
        do {
            resolvedDevice = try definition.resolved()
            resolvedPhysicalPipeline = try .inactiveDownstreamStages(
                coverGlass: coverGlass
            )
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
            resolvedDevice = try definition.resolved()
            resolvedPhysicalPipeline = try .inactiveDownstreamStages(
                coverGlass: coverGlass
            )
            rebuildPhysicalSelectedFrame()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectPhysicalIntermediate(_ intermediate: PhysicalIntermediate) {
        requestedPhysicalIntermediate = intermediate
        rebuildPhysicalSelectedFrame()
    }

    func setModelPageActive(_ active: Bool) {
        isModelPageActive = active
        if active { pause() }
        rebuildPhysicalSelectedFrame()
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

    func changePhysicalDomainAmount(_ amount: Double, domain: PhysicalDomainID) {
        do {
            try physicalModel.setDomainAmount(amount, domain: domain)
        } catch {
            errorMessage = "Amount físico fuera de los límites seguros 0–4."
        }
    }

    func changePhysicalStageAmount(_ amount: Double, stage: PhysicalStageID) {
        do {
            try physicalModel.setContinuousAmount(amount, stage: stage)
        } catch {
            errorMessage = "La contribución no admite ese valor."
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
        guard physicalNativeTask == nil else { return }
        pause()
        do { try physicalModel.beginNative() }
        catch { return }
        physicalNativeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let job = try submitPhysicalJob(quality: .native)
                physicalNativeJob = job
                try await pollPhysicalJob(job, native: true)
            } catch is CancellationError {
                // Explicit cancellation or parameter invalidation owns the state.
            } catch {
                if !Task.isCancelled {
                    physicalModel.failNative()
                    errorMessage = error.localizedDescription
                }
            }
            physicalNativeJob = nil
            physicalNativeTask = nil
        }
    }

    func cancelSelectedPhysicalFrameNative() {
        physicalModel.cancelNative()
        physicalNativeTask?.cancel()
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
        detection = StudioMediaDetection(
            proposedInputTransformID: "input-rec709",
            inputTransformProvenance: .proposed,
            matrix: .bt709,
            matrixProvenance: .proposed,
            range: .full,
            rangeProvenance: .proposed,
            colorModel: .rgb,
            colorModelProvenance: .proposed,
            hasAlpha: false,
            alpha: .ignore,
            alphaProvenance: .proposed
        )
        inputTransform = StudioColorInputTransform.catalog.first { $0.id == "input-rec709" }!
        alphaMode = .ignore
        signalMatrix = .bt709
        signalRange = .full
        signalColorModel = .rgb
        defaultInputTransformID = "input-rec709"
        defaultAlphaMode = .ignore
        defaultSignalMatrix = .bt709
        defaultSignalRange = .full
        defaultSignalColorModel = .rgb
        currentFrame = 0
        frameRate = 24
        frameCount = pattern == .animatedCheckerboard ? 240 : 1
        outFrame = frameCount - 1
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
            ? "display-rec709-aces2-sdr"
            : "display-srgb-aces2-sdr"
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

    func resetView() { zoom = 1; pan = .zero }
    func fitModelPreview() {
        modelViewerOneToOne = false
        resetView()
    }
    func showModelPreviewOneToOne() {
        modelViewerOneToOne = true
        resetView()
    }
    func zoomBy(_ factor: Double) { zoom = min(16, max(0.1, zoom * factor)) }
    var zoomPercentage: Double {
        get { zoom * 100 }
        set { zoom = min(16, max(0.1, newValue / 100)) }
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
        panel.allowedContentTypes = [.tiff]
        panel.nameFieldStringValue = String(format: "ScreenSimulation-%08d.tiff", currentFrame)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try NativeOutputRenderer.renderCurrentFrame(
                frame: metalFrame, displayTransform: previewTransform,
                destination: url, display: metalDisplay
            )
            status = "Frame actual renderizado · \(url.lastPathComponent)"
        } catch { errorMessage = error.localizedDescription }
    }

    private func tickPlayback() {
        if metalDisplay.lastCompletedEndToEndMilliseconds > 0 {
            decodeToPreviewMilliseconds = metalDisplay.lastCompletedEndToEndMilliseconds
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
            metalFrame = base
            if let metalFrame {
                monitorOutput.update(frame: metalFrame, display: metalDisplay)
            }
            sourceDetail = "Patrón SCREEN canónico · \(decoded.width) × \(decoded.height)"
            decodeToPreviewMilliseconds = (CACurrentMediaTime() - started) * 1_000
            status = "Textura ACEScg Metal · \(decodeToPreviewMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
            rebuildPhysicalSelectedFrame()
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
        metalFrame = base
        if let metalFrame {
            monitorOutput.update(frame: metalFrame, display: metalDisplay)
        }
        currentFrame = min(frameCount - 1, max(0, Int((sample.time.seconds * frameRate).rounded())))
        decodeToPreviewMilliseconds = (CACurrentMediaTime() - started) * 1_000
        status = "CVPixelBuffer → ACEScg → Preview · \(decodeToPreviewMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
        rebuildPhysicalSelectedFrame()
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
        guard isModelPageActive else {
            _ = physicalInteractiveJob?.cancel()
            physicalInteractiveTask?.cancel()
            if let sourceACEScgFrame { metalFrame = sourceACEScgFrame }
            return
        }
        guard physicalModel.quality != .native else { return }
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
                try await pollPhysicalJob(job, native: false)
            } catch is CancellationError {
                // A newer parameter revision owns the next authoritative result.
            } catch {
                status = error.localizedDescription
            }
            if physicalInteractiveJob === submittedJob {
                physicalInteractiveJob = nil
            }
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
        let deviceSignal = try metalDisplay.transformToMetalFrame(
            sourceACEScgFrame,
            output: deviceSignalTransform
        )
        let contributions = physicalModel.orderedContributions
        guard let spreadAmount = contributions.first(where: {
            $0.stage == .screen(.panelLightSpread)
        })?.amount else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "Falta la contribución resuelta de Panel Light Spread."
            )
        }
        var effectiveDeviceDefinition = resolvedDevice.definition
        effectiveDeviceDefinition.panelLightSpread.characterStrength = spreadAmount
        let effectiveDevice = try effectiveDeviceDefinition.resolved()
        physicalIdentityCounter &+= 1
        let identity = PhysicalFrameIdentity(
            high: physicalModel.parameterRevision,
            low: physicalIdentityCounter
        )
        return try physicalEngine.submit(
            sourceACEScg: sourceACEScgFrame,
            deviceSignal: deviceSignal,
            frame: try PhysicalFrameSelection(
                frameIndex: Int64(currentFrame),
                timeNumerator: Int64(currentFrame),
                timeDenominator: UInt32(max(1, Int(frameRate.rounded())))
            ),
            resolvedDevice: effectiveDevice,
            resolvedPipeline: resolvedPhysicalPipeline,
            quality: quality,
            screenAmount: physicalModel.screenAmount,
            captureAmount: physicalModel.captureAmount,
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

    private func pollPhysicalJob(
        _ job: PhysicalMetalFrameJob,
        native: Bool
    ) async throws {
        let started = ContinuousClock.now
        while true {
            try Task.checkCancellation()
            let snapshot = try job.snapshot()
            if native {
                physicalModel.publishNative(snapshot)
            }
            switch snapshot.state {
            case .idle, .stale, .rendering:
                try await Task.sleep(for: .milliseconds(8))
            case .cancelled:
                throw CancellationError()
            case .failed:
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
                    presentationFrame = try metalDisplay.makeACEScgFrame(
                        encodedTexture: frame.texture,
                        input: deviceSignalInverseTransform,
                        alpha: .premultiplied
                    )
                } else {
                    presentationFrame = frame
                }
                metalFrame = presentationFrame
                monitorOutput.update(frame: presentationFrame, display: metalDisplay)
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
                let diagnostic = snapshot.diagnostics
                    .filter { !$0.message.isEmpty }
                    .map(\.message)
                    .joined(separator: " · ")
                status = "Modelo · \(snapshot.computedQuality.uiLabel) · \(effective.width)×\(effective.height) · \((elapsed * 1_000).formatted(.number.precision(.fractionLength(1)))) ms"
                if !diagnostic.isEmpty { status += " · \(diagnostic)" }
                return
            }
        }
    }

    private func physicalRequestedDimensions(
        quality: PhysicalQuality,
        device: DeviceDefinition
    ) throws -> PhysicalDimensions {
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
        let fields = [
            quality.rawValue.description,
            physicalModel.screenAmount.description,
            physicalModel.captureAmount.description,
            sourcePlacement.rawValue,
            physicalModel.parameterRevision.description,
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
            "Captura está pendiente del motor físico ABI v2; no se ha simulado."
        case .artisticScreenPending:
            "Pantalla >1 está pendiente del motor físico ABI v2; se conserva el último resultado."
        case let .sectionPending(stage):
            "La contribución 0x\(String(stage.id, radix: 16)) está pendiente del motor ABI v2."
        }
    }
}

private extension PhysicalQuality {
    var uiLabel: String {
        switch self {
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
