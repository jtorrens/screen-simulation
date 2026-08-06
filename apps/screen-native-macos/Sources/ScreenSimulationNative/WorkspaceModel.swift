@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation
import ImageIO
import StudioColor

@MainActor
final class WorkspaceModel: ObservableObject {
    struct RenderJob: Identifiable {
        enum State: String { case queued, rendering, complete, failed }
        let id = UUID()
        let destination: URL
        let output: StudioColorOutputTransform
        var state: State = .queued
        var detail: String = "En cola"
    }

    @Published var inputTransform = StudioColorInputTransform.catalog[2]
    @Published var outputTransform = StudioColorOutputTransform.catalog[0]
    @Published var alphaAssociation = StudioColorAlphaAssociation.straight
    @Published var selectedPattern = SyntheticPattern.colorAndRange
    @Published var requestedSeconds = 0.0
    @Published var sourceName = "Patrón sintético"
    @Published var sourceDetail = "ACEScg lineal · 960 × 540"
    @Published var status = "Preparado"
    @Published var isIDTConfirmed = true
    @Published var linearFrame: StudioColorLinearFrame?
    @Published var jobs: [RenderJob] = []
    @Published var errorMessage: String?

    let colorPipeline: StudioColorPipeline
    let metalDisplay: StudioColorMetalDisplay
    private let physicalPipeline = PhysicalPipeline()
    private var decoded: DecodedNativeFrame

    init() {
        let pipeline = StudioColorPipeline()
        colorPipeline = pipeline
        metalDisplay = try! StudioColorMetalDisplay()
        decoded = SyntheticPattern.colorAndRange.frame()
        do {
            linearFrame = try physicalPipeline.process(
                pipeline.prepareInput(
                    width: decoded.width,
                    height: decoded.height,
                    encodedRGBA: decoded.rgba,
                    input: inputTransform,
                    alpha: alphaAssociation
                )
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var pipelineSummary: String {
        "Input → IDT → ACEScg → Physical(identity) → \(outputTransform.label)"
    }

    func choosePattern(_ pattern: SyntheticPattern, undoManager: UndoManager?) {
        let prior = selectedPattern
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.choosePattern(prior, undoManager: nil) }
        }
        selectedPattern = pattern
        decoded = pattern.frame()
        sourceName = pattern.label
        sourceDetail = "ACEScg lineal · \(decoded.width) × \(decoded.height)"
        inputTransform = StudioColorInputTransform.catalog[2]
        alphaAssociation = .straight
        isIDTConfirmed = true
        rebuild()
    }

    func openMedia() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        status = "Decodificando el tiempo solicitado…"
        Task {
            do {
                decoded = try await NativeMediaDecoder.decode(
                    url: url,
                    time: CMTime(seconds: requestedSeconds, preferredTimescale: 60_000)
                )
                sourceName = url.lastPathComponent
                sourceDetail = "\(decoded.width) × \(decoded.height) · \(decoded.sourceDescription)"
                alphaAssociation = .premultiplied
                isIDTConfirmed = false
                linearFrame = nil
                status = "Selecciona y confirma un IDT explícito"
            } catch {
                errorMessage = error.localizedDescription
                status = "Error de decodificación"
            }
        }
    }

    func confirmIDT() {
        isIDTConfirmed = true
        rebuild()
    }

    func changeInput(_ value: StudioColorInputTransform, undoManager: UndoManager?) {
        let prior = inputTransform
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.changeInput(prior, undoManager: nil) }
        }
        inputTransform = value
        isIDTConfirmed = false
        linearFrame = nil
        status = "Confirma el IDT seleccionado"
    }

    func changeOutput(_ value: StudioColorOutputTransform, undoManager: UndoManager?) {
        let prior = outputTransform
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.changeOutput(prior, undoManager: nil) }
        }
        outputTransform = value
        status = linearFrame == nil ? "Confirma el IDT seleccionado" : "Preview OCIO actualizado"
        objectWillChange.send()
    }

    func changeAlpha(_ value: StudioColorAlphaAssociation, undoManager: UndoManager?) {
        let prior = alphaAssociation
        undoManager?.registerUndo(withTarget: self) { target in
            Task { @MainActor in target.changeAlpha(prior, undoManager: nil) }
        }
        alphaAssociation = value
        isIDTConfirmed = false
        linearFrame = nil
        status = "Confirma la asociación alpha"
    }

    func enqueueExport() {
        guard linearFrame != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "ScreenSimulation-\(outputTransform.id).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        jobs.append(RenderJob(destination: url, output: outputTransform))
    }

    func runQueue() {
        guard let frame = linearFrame else { return }
        for index in jobs.indices where jobs[index].state == .queued {
            jobs[index].state = .rendering
            jobs[index].detail = "Metal + ODT"
            do {
                let bytes = try metalDisplay.renderRGBA8(frame, output: jobs[index].output)
                try Self.writePNG(
                    bytes: bytes,
                    width: frame.width,
                    height: frame.height,
                    to: jobs[index].destination
                )
                jobs[index].state = .complete
                jobs[index].detail = jobs[index].destination.lastPathComponent
            } catch {
                jobs[index].state = .failed
                jobs[index].detail = error.localizedDescription
            }
        }
    }

    private func rebuild() {
        guard isIDTConfirmed else { return }
        status = "IDT → ACEScg → Physical(identity)…"
        do {
            let aces = try colorPipeline.prepareInput(
                width: decoded.width,
                height: decoded.height,
                encodedRGBA: decoded.rgba,
                input: inputTransform,
                alpha: alphaAssociation
            )
            linearFrame = try physicalPipeline.process(aces)
            status = "ACEScg lineal preparado · Preview OCIO Metal"
        } catch {
            linearFrame = nil
            errorMessage = error.localizedDescription
            status = "Pipeline detenido"
        }
    }

    private static func writePNG(
        bytes: [UInt8],
        width: Int,
        height: Int,
        to url: URL
    ) throws {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        else { throw NativeMediaError.invalidRaster }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NativeMediaError.unreadable(url.lastPathComponent)
        }
    }
}
