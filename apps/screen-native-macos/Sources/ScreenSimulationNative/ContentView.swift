import AppKit
import MetalKit
import StudioColor
import SwiftUI

struct ContentView: View {
    enum SidebarTab: String, CaseIterable, Identifiable {
        case source = "Source"
        case color = "Color"
        case output = "Output"
        case queue = "Render Queue"
        var id: String { rawValue }
    }

    @Environment(\.undoManager) private var undoManager
    @ObservedObject var model: WorkspaceModel
    @State private var tab = SidebarTab.source

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TabView(selection: $tab) {
                    sourcePanel.tabItem { Label("Source", systemImage: "film") }.tag(SidebarTab.source)
                    colorPanel.tabItem { Label("Color", systemImage: "paintpalette") }.tag(SidebarTab.color)
                    outputPanel.tabItem { Label("Output", systemImage: "square.and.arrow.up") }.tag(SidebarTab.output)
                    queuePanel.tabItem { Label("Queue", systemImage: "list.bullet.rectangle") }.tag(SidebarTab.queue)
                }
                Divider()
                contextualInspector
            }
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 560)

            preview
                .frame(minWidth: 640, minHeight: 480)
        }
        .background(SplitAutosaveProbe(name: "ScreenSimulation.Native.Workspace"))
        .toolbar {
            ToolbarItemGroup {
                Button(action: model.openMedia) { Label("Abrir", systemImage: "folder") }
                    .help("Abrir un vídeo o una imagen")
                Button(action: model.enqueueExport) { Label("Añadir render", systemImage: "plus.rectangle.on.rectangle") }
                    .disabled(model.linearFrame == nil)
                    .help("Añadir el frame actual a Render Queue")
                Button(action: model.runQueue) { Label("Render", systemImage: "play.fill") }
                    .disabled(!model.jobs.contains { $0.state == .queued })
                    .help("Procesar los trabajos en cola")
            }
        }
        .alert(
            "SCREEN-SIMULATION",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) { Button("Aceptar") { model.errorMessage = nil } }
        message: { Text(model.errorMessage ?? "") }
    }

    private var sourcePanel: some View {
        Form {
            Section("Fuente") {
                LabeledContent("Archivo") { Text(model.sourceName).lineLimit(1) }
                LabeledContent("Detalle") { Text(model.sourceDetail).lineLimit(2) }
                LabeledContent("Tiempo (s)") {
                    TextField("0", value: $model.requestedSeconds, format: .number)
                        .frame(width: 72)
                        .accessibilityLabel("Tiempo solicitado en segundos")
                }
                Button("Abrir medio…", action: model.openMedia)
            }
            Section("Patrones sintéticos") {
                Picker("Patrón", selection: Binding(
                    get: { model.selectedPattern },
                    set: { model.choosePattern($0, undoManager: undoManager) }
                )) {
                    ForEach(SyntheticPattern.allCases) { Text($0.label).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var colorPanel: some View {
        Form {
            Section("Interpretación de entrada") {
                Picker("IDT", selection: Binding(
                    get: { model.inputTransform },
                    set: { model.changeInput($0, undoManager: undoManager) }
                )) {
                    ForEach(StudioColorInputTransform.catalog) { Text($0.label).tag($0) }
                }
                Picker("Alpha", selection: Binding(
                    get: { model.alphaAssociation },
                    set: { model.changeAlpha($0, undoManager: undoManager) }
                )) {
                    Text("Straight").tag(StudioColorAlphaAssociation.straight)
                    Text("Premultiplied").tag(StudioColorAlphaAssociation.premultiplied)
                    Text("Ignore").tag(StudioColorAlphaAssociation.ignore)
                }
                Button(model.isIDTConfirmed ? "IDT confirmado" : "Confirmar IDT") {
                    model.confirmIDT()
                }
                .disabled(model.isIDTConfirmed)
            }
            Section("Working space") {
                LabeledContent("Espacio") { Text("ACEScg lineal") }
                LabeledContent("Alpha") { Text("Premultiplicado") }
                LabeledContent("Rango") { Text("Negativos y >1 preservados") }
            }
        }
        .formStyle(.grouped)
    }

    private var outputPanel: some View {
        Form {
            Section("Display / View OCIO") {
                Picker("ODT", selection: Binding(
                    get: { model.outputTransform },
                    set: { model.changeOutput($0, undoManager: undoManager) }
                )) {
                    ForEach(StudioColorOutputTransform.catalog) { Text($0.label).tag($0) }
                }
                LabeledContent("Motor") { Text("StudioColor · Metal") }
            }
            Section("Exportación") {
                Button("Añadir PNG a Render Queue", action: model.enqueueExport)
                    .disabled(model.linearFrame == nil)
            }
        }
        .formStyle(.grouped)
    }

    private var queuePanel: some View {
        VStack(spacing: 0) {
            List(model.jobs) { job in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(job.destination.lastPathComponent)
                        Spacer()
                        Text(job.state.rawValue.capitalized).foregroundStyle(.secondary)
                    }
                    Text(job.output.label).font(.caption)
                    Text(job.detail).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Spacer()
                Button("Render Queue", action: model.runQueue)
                    .disabled(!model.jobs.contains { $0.state == .queued })
            }
            .padding(8)
        }
    }

    private var contextualInspector: some View {
        Form {
            Section("Inspector · \(tab.rawValue)") {
                LabeledContent("Estado") { Text(model.status).lineLimit(2) }
                LabeledContent("OCIO") { Text(StudioColorBuildIdentity.ocioVersion) }
                LabeledContent("ACES") { Text(StudioColorBuildIdentity.acesConfigVersion) }
                LabeledContent("Physical") { Text("identity · Rust ABI") }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 180, idealHeight: 220)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .black)
                if let frame = model.linearFrame {
                    MetalPreview(
                        display: model.metalDisplay,
                        frame: frame,
                        output: model.outputTransform
                    )
                    .accessibilityLabel("Preview OCIO del resultado")
                } else {
                    ContentUnavailableView(
                        "IDT pendiente",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Selecciona y confirma la interpretación de entrada.")
                    )
                }
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: model.linearFrame == nil ? "exclamationmark.circle" : "checkmark.circle")
                Text(model.pipelineSummary).lineLimit(1)
                Spacer()
                Text(model.status).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

struct MetalPreview: NSViewRepresentable {
    let display: StudioColorMetalDisplay
    let frame: StudioColorLinearFrame
    let output: StudioColorOutputTransform

    func makeNSView(context _: Context) -> MTKView {
        let view = MTKView()
        display.configure(view)
        return view
    }

    func updateNSView(_ view: MTKView, context _: Context) {
        display.present(frame, output: output, in: view)
    }
}

struct SplitAutosaveProbe: NSViewRepresentable {
    let name: String

    func makeNSView(context _: Context) -> ProbeView { ProbeView(name: name) }
    func updateNSView(_ view: ProbeView, context _: Context) { view.name = name; view.install() }

    final class ProbeView: NSView {
        var name: String
        init(name: String) { self.name = name; super.init(frame: .zero) }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
        func install() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var view = self.superview
                while let candidate = view {
                    if let split = candidate as? NSSplitView, split.isVertical {
                        split.autosaveName = NSSplitView.AutosaveName(name)
                        return
                    }
                    view = candidate.superview
                }
            }
        }
    }
}
