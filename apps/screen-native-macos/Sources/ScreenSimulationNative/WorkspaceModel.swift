@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation
import StudioColor
import StudioMedia

@MainActor
final class WorkspaceModel: ObservableObject {
    struct RenderJob: Identifiable {
        enum State: String { case pending, rendering, completed, failed, cancelled }
        let id = UUID()
        let destination: URL
        let format: StudioOutputFormat
        let preset: StudioRenderPreset
        let range: ClosedRange<Int>
        var state: State = .pending
        var progress = 0.0
        var detail = "Pendiente"
    }

    @Published var inputTransform = StudioColorInputTransform.catalog.first {
        $0.id == "input-rec709"
    }!
    @Published var previewTransform = StudioColorOutputTransform.catalog[0]
    @Published var alphaMode = StudioAlphaMode.ignore
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
    @Published var outputFormat = StudioOutputFormat.proRes4444
    @Published var renderPreset = StudioRenderPreset.builtIns[0]
    @Published var peakNits = 100.0
    @Published var includeAudio = true
    @Published var outputAlpha = true
    @Published var decodeToPreviewMilliseconds = 0.0
    @Published var zoom = 1.0
    @Published var pan = CGSize.zero
    @Published private(set) var defaultInputTransformID = "input-rec709"
    @Published private(set) var defaultAlphaMode = StudioAlphaMode.ignore
    @Published private(set) var defaultSignalMatrix = StudioSignalMatrix.bt709
    @Published private(set) var defaultSignalRange = StudioSignalRange.full

    let metalDisplay: StudioColorMetalDisplay
    private let session = NativeMediaSession()
    private var sourceIsPattern = true
    private var tickSubscription: AnyCancellable?
    private var renderTask: Task<Void, Never>?

    init() {
        metalDisplay = try! StudioColorMetalDisplay()
        renderPattern()
        tickSubscription = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect().sink { [weak self] _ in self?.tickPlayback() }
    }

    var pipelineSummary: String {
        "Input → YUV/rango → IDT → ACEScg → Display/ODT"
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
            return sourceIsPattern ? "Propuesta" : "Detectada"
        }
        return detection.proposedInputTransformID == nil && value.id == defaultInputTransformID
            ? "Predeterminada" : nil
    }

    func alphaAnnotation(_ value: StudioAlphaMode) -> String? {
        if value == detection.alpha {
            return sourceIsPattern ? "Propuesto" : "Detectado"
        }
        return detection.alpha == nil && value == defaultAlphaMode ? "Predeterminado" : nil
    }

    func matrixAnnotation(_ value: StudioSignalMatrix) -> String? {
        if value == detection.matrix {
            return sourceIsPattern ? "Propuesta" : "Detectada"
        }
        return detection.matrix == nil && value == defaultSignalMatrix ? "Predeterminada" : nil
    }

    func rangeAnnotation(_ value: StudioSignalRange) -> String? {
        if value == detection.range {
            return sourceIsPattern ? "Propuesto" : "Detectado"
        }
        return detection.range == nil && value == defaultSignalRange ? "Predeterminado" : nil
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
            proposedInputTransformID: "input-rec709", range: .full,
            hasAlpha: false, alpha: .ignore
        )
        inputTransform = StudioColorInputTransform.catalog.first { $0.id == "input-rec709" }!
        alphaMode = .ignore
        signalMatrix = .bt709
        signalRange = .full
        defaultInputTransformID = "input-rec709"
        defaultAlphaMode = .ignore
        defaultSignalMatrix = .bt709
        defaultSignalRange = .full
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
        let resolvedInputID = detection.proposedInputTransformID ?? defaultInputID
        inputTransform = StudioColorInputTransform.catalog.first {
            $0.id == resolvedInputID
        }!
        alphaMode = detection.alpha ?? defaultAlphaMode
        signalMatrix = detection.matrix ?? defaultSignalMatrix
        signalRange = detection.range ?? defaultSignalRange
        do {
            let info = isVideo
                ? try await session.openVideo(first, hasAlpha: detection.hasAlpha)
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
    func markIn() { inFrame = currentFrame; if outFrame < inFrame { outFrame = inFrame } }
    func markOut() { outFrame = currentFrame; if inFrame > outFrame { inFrame = outFrame } }

    func resetView() { zoom = 1; pan = .zero }
    func zoomBy(_ factor: Double) { zoom = min(16, max(0.1, zoom * factor)) }

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
        jobs.append(RenderJob(
            destination: url, format: outputFormat, preset: renderPreset, range: activeFrameRange
        ))
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
                    format: job.format, preset: job.preset, peakNits: peakNits,
                    frameRate: frameRate, frameRange: job.range,
                    destination: job.destination,
                    includeAlpha: outputAlpha,
                    includeAudio: includeAudio,
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
        if sourceIsPattern {
            let next = currentFrame + 1
            if next >= frameCount { pause(); return }
            currentFrame = next
            renderPattern()
            return
        }
        renderCurrentMediaFrame()
    }

    private func rebuildCurrent() {
        sourceIsPattern ? renderPattern() : renderCurrentMediaFrame(at: session.time(forFrame: currentFrame))
    }

    private func renderPattern() {
        let started = CACurrentMediaTime()
        do {
            let decoded = try selectedPattern.frame(time: requestedSeconds)
            metalFrame = try metalDisplay.makeACEScgFrame(
                width: decoded.width, height: decoded.height, encodedRGBA: decoded.rgba,
                input: inputTransform, alpha: effectiveAlpha
            )
            sourceDetail = "Patrón SCREEN canónico · \(decoded.width) × \(decoded.height)"
            decodeToPreviewMilliseconds = (CACurrentMediaTime() - started) * 1_000
            status = "Textura ACEScg Metal · \(decodeToPreviewMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
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
        metalFrame = try metalDisplay.makeACEScgFrame(
            pixelBuffer: sample.pixelBuffer, input: inputTransform,
            alpha: effectiveAlpha, matrix: effectiveMatrix, range: effectiveRange
        )
        currentFrame = min(frameCount - 1, max(0, Int((sample.time.seconds * frameRate).rounded())))
        decodeToPreviewMilliseconds = (CACurrentMediaTime() - started) * 1_000
        status = "CVPixelBuffer → ACEScg → Preview · \(decodeToPreviewMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
    }

    private func renderFrame(_ index: Int) async throws -> StudioColorMetalFrame {
        if sourceIsPattern {
            let decoded = try selectedPattern.frame(time: Double(index) / frameRate)
            return try metalDisplay.makeACEScgFrame(
                width: decoded.width, height: decoded.height,
                encodedRGBA: decoded.rgba, input: inputTransform, alpha: effectiveAlpha
            )
        }
        let time = session.time(forFrame: index)
        try Task.checkCancellation()
        guard let sample = try await session.exactSample(at: time) else {
            throw NativeMediaError.unreadable("frame \(index)")
        }
        return try metalDisplay.makeACEScgFrame(
            pixelBuffer: sample.pixelBuffer, input: inputTransform,
            alpha: effectiveAlpha, matrix: effectiveMatrix, range: effectiveRange
        )
    }

    private static func isVideo(_ url: URL) -> Bool {
        ["mov", "mp4", "m4v"].contains(url.pathExtension.lowercased())
    }

    private static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "tif", "tiff", "heic", "exr", "dpx"].contains(url.pathExtension.lowercased())
    }
}
