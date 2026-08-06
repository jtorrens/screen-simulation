import AppKit
import MetalKit
import StudioColor
import StudioMedia
import SwiftUI

struct ContentView: View {
    enum WorkspacePage: String, CaseIterable, Identifiable {
        case main = "Principal"
        case settings = "Settings"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .main: "rectangle.on.rectangle"
            case .settings: "gearshape"
            }
        }
    }

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
    @State private var page = WorkspacePage.main

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .main: mainWorkspace
                case .settings: settingsWorkspace
                }
            }
            Divider()
            HStack(spacing: 8) {
                ForEach(WorkspacePage.allCases) { destination in
                    Button {
                        page = destination
                    } label: {
                        Image(systemName: destination.systemImage)
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(page == destination ? Color.accentColor : .secondary)
                    .help(destination.rawValue)
                    .accessibilityLabel(destination.rawValue)
                    .accessibilityAddTraits(page == destination ? .isSelected : [])
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar { workspaceToolbar }
        .alert(
            "SCREEN-SIMULATION",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) { Button("Aceptar") { model.errorMessage = nil } }
        message: { Text(model.errorMessage ?? "") }
    }

    private var mainWorkspace: some View {
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
    }

    private var settingsWorkspace: some View {
        TabView {
            Form {
                Section("Aplicación") {
                    LabeledContent("Renderer", value: "Metal · RGBA16Float")
                    LabeledContent("OCIO", value: StudioColorBuildIdentity.ocioVersion)
                    LabeledContent("ACES", value: StudioColorBuildIdentity.acesConfigVersion)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Aplicación", systemImage: "info.circle") }

            ContentUnavailableView(
                "Colecciones globales",
                systemImage: "square.stack.3d.up",
                description: Text("Patrones, imágenes de prueba y presets de render.")
            )
            .tabItem { Label("Colecciones", systemImage: "square.stack.3d.up") }

            Form {
                Section("Monitor externo") {
                    Text("La salida DeckLink usa una ODT de monitorización independiente.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Monitor", systemImage: "rectangle.connected.to.line.below") }
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button(action: model.openMedia) { Label("Abrir", systemImage: "folder") }
                .disabled(page != .main)
                .help("Abrir un vídeo o una imagen")
            Button(action: model.enqueueExport) { Label("Añadir render", systemImage: "plus.rectangle.on.rectangle") }
                .disabled(page != .main || model.metalFrame == nil)
                .help("Añadir la película o el rango completo a Render Queue")
            Button(action: model.renderCurrentFrame) { Label("Frame actual", systemImage: "photo") }
                .disabled(page != .main || model.metalFrame == nil)
                .help("Renderizar el frame actual horneando la transformación del visor")
            Button(action: model.runQueue) { Label("Render", systemImage: "play.fill") }
                .disabled(page != .main || !model.jobs.contains { $0.state == .pending })
                .help("Procesar los trabajos en cola")
        }
    }

    private var sourcePanel: some View {
        Form {
            Section("Fuente") {
                LabeledContent("Archivo") { Text(model.sourceName).lineLimit(1) }
                LabeledContent("Detalle") { Text(model.sourceDetail).lineLimit(2) }
                LabeledContent("Tiempo (s)") {
                    TextField("0", value: Binding(
                        get: { model.requestedSeconds },
                        set: { model.requestedSeconds = $0 }
                    ), format: .number)
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
                    ForEach(StudioColorInputTransform.catalog) { value in
                        interpretationLabel(value.label, annotation: model.inputAnnotation(value))
                            .tag(value)
                    }
                }
                Picker("Alpha", selection: Binding(
                    get: { model.alphaMode },
                    set: { model.changeAlpha($0, undoManager: undoManager) }
                )) {
                    ForEach(StudioAlphaMode.allCases) { value in
                        interpretationLabel(value.label, annotation: model.alphaAnnotation(value))
                            .tag(value)
                    }
                }
                Picker("Matriz YUV", selection: Binding(
                    get: { model.signalMatrix }, set: { model.changeMatrix($0) }
                )) {
                    ForEach(StudioSignalMatrix.allCases) { value in
                        interpretationLabel(value.label, annotation: model.matrixAnnotation(value))
                            .tag(value)
                    }
                }
                Picker("Rango señal", selection: Binding(
                    get: { model.signalRange }, set: { model.changeRange($0) }
                )) {
                    ForEach(StudioSignalRange.allCases) { value in
                        interpretationLabel(value.label, annotation: model.rangeAnnotation(value))
                            .tag(value)
                    }
                }
            }
            Section("Working space") {
                LabeledContent("Espacio") { Text("ACEScg lineal") }
                LabeledContent("Alpha") { Text("Premultiplicado") }
                LabeledContent("Rango") { Text("Negativos y >1 preservados") }
            }
        }
        .formStyle(.grouped)
    }

    private func interpretationLabel(_ label: String, annotation: String?) -> Text {
        Text(label + (annotation.map { " · \($0)" } ?? ""))
            .fontWeight(annotation == nil ? .regular : .semibold)
    }

    private var outputPanel: some View {
        Form {
            Section("Preset / ODT") {
                Picker("Preset", selection: $model.renderPreset) {
                    ForEach(StudioRenderPreset.builtIns) { Text($0.name).tag($0) }
                }
                LabeledContent("Peak nits") {
                    TextField("nits", value: $model.peakNits, format: .number).frame(width: 90)
                }
                Picker("Formato", selection: $model.outputFormat) {
                    ForEach(StudioOutputFormat.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Rango", selection: $model.renderRange) {
                    Text("Todo").tag(StudioRenderRange.all)
                    Text("IN / OUT").tag(StudioRenderRange.inOut)
                }
                Picker("Alpha", selection: $model.outputAlphaMode) {
                    ForEach(StudioAlphaMode.allCases) { Text($0.label).tag($0) }
                }
                    .disabled(!model.outputFormat.supportsAlpha)
                Toggle("Audio", isOn: $model.includeAudio)
                    .disabled(!model.outputFormat.isMovie)
            }
            Section("Exportación") {
                Button("Añadir a Render Queue", action: model.enqueueExport)
                    .disabled(model.metalFrame == nil)
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
                        Text(job.format.displayName).font(.caption)
                    Text("\(job.range.lowerBound)–\(job.range.upperBound) · \(job.detail)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                if model.jobs.contains(where: { $0.state == .rendering }) {
                    Button("Cancelar", action: model.cancelRender)
                }
                Spacer()
                Button("Render Queue", action: model.runQueue)
                    .disabled(!model.jobs.contains { $0.state == .pending })
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
                LabeledContent("Frame") { Text("\(model.currentFrame + 1) / \(model.frameCount)") }
                LabeledContent("Rendimiento") {
                    Text("\(model.decodeToPreviewMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 180, idealHeight: 220)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Pantalla", selection: Binding(
                    get: { model.previewTransform },
                    set: { model.changePreview($0, undoManager: undoManager) }
                )) {
                    ForEach(StudioColorOutputTransform.catalog) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 330)
                Spacer()
                Button { model.zoomBy(0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                Button("100%", action: model.resetView)
                Button { model.zoomBy(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ZStack {
                Color(nsColor: .black)
                if let frame = model.metalFrame {
                    MetalPreview(
                        display: model.metalDisplay,
                        frame: frame,
                        output: model.previewTransform
                    )
                    .scaleEffect(model.zoom)
                    .offset(model.pan)
                    .gesture(
                        DragGesture().onChanged { value in model.pan = value.translation }
                    )
                    .gesture(
                        MagnifyGesture().onChanged { value in
                            model.zoom = min(16, max(0.1, value.magnification))
                        }
                    )
                    .accessibilityLabel("Preview OCIO del resultado")
                } else {
                    ContentUnavailableView(
                        "Sin frame",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Abre un medio o selecciona un patrón.")
                    )
                }
            }
            .clipped()
            Divider()
            transport
            Divider()
            HStack(spacing: 8) {
                Image(systemName: model.metalFrame == nil ? "exclamationmark.circle" : "checkmark.circle")
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

    private var transport: some View {
        VStack(spacing: 5) {
            NativeTimelineView(
                frameCount: model.frameCount,
                frameRate: model.frameRate,
                currentFrame: model.currentFrame,
                inFrame: model.inFrame,
                outFrame: model.outFrame,
                onSeek: { model.seek(toFrame: $0) },
                onSetIn: { model.setInFrame($0) },
                onSetOut: { model.setOutFrame($0) }
            )
            .frame(height: 58)
            HStack(spacing: 12) {
                Button("[", action: model.markIn)
                    .help("Marcar entrada (I)")
                    .accessibilityLabel("Marcar entrada")
                Button { model.jump(-5) } label: { Image(systemName: "backward.end.fill") }
                Button { model.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                Button(action: model.togglePlayback) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .keyboardShortcut(.space, modifiers: [])
                Button { model.step(1) } label: { Image(systemName: "forward.frame.fill") }
                Button { model.jump(5) } label: { Image(systemName: "forward.end.fill") }
                Button("]", action: model.markOut)
                    .help("Marcar salida (O)")
                    .accessibilityLabel("Marcar salida")
                Spacer()
                Picker("Reproducción", selection: $model.renderRange) {
                    Text("Todo").tag(StudioRenderRange.all)
                    Text("Rango").tag(StudioRenderRange.inOut)
                }
                .labelsHidden()
                .frame(width: 82)
                Toggle("Loop", isOn: $model.loopPlayback)
                    .toggleStyle(.checkbox)
                frameField("Entrada", value: Binding(
                    get: { model.inFrame }, set: { model.setInFrame($0) }
                ))
                frameField("Posición", value: Binding(
                    get: { model.currentFrame }, set: { model.seek(toFrame: $0) }
                ))
                frameField("Salida", value: Binding(
                    get: { model.outFrame }, set: { model.setOutFrame($0) }
                ))
                Text(model.timecode).monospacedDigit()
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func frameField(_ label: String, value: Binding<Int>) -> some View {
        TextField(label, value: value, format: .number)
            .labelsHidden()
            .frame(width: 54)
            .monospacedDigit()
            .accessibilityLabel(label)
    }
}

struct MetalPreview: NSViewRepresentable {
    let display: StudioColorMetalDisplay
    let frame: StudioColorMetalFrame
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
