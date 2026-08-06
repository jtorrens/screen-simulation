import AppKit
import MetalKit
import StudioColor
import StudioMedia
import StudioVideoOutput
import SwiftUI

struct ContentView: View {
    enum WorkspacePage: String, CaseIterable, Identifiable {
        case main = "Principal"
        case device = "Device"
        case settings = "Settings"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .main: "rectangle.on.rectangle"
            case .device: "display"
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
    @StateObject private var library = GlobalLibraryController()
    @State private var tab = SidebarTab.source
    @State private var page = WorkspacePage.main

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .main: mainWorkspace
                case .device: deviceWorkspace
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
        .onAppear {
            if model.resolvedDevice == nil,
               let first = library.document.devices.first {
                model.selectDevice(first)
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

            globalCollections
            .tabItem { Label("Colecciones", systemImage: "square.stack.3d.up") }

            monitorSettings
            .tabItem { Label("Monitor", systemImage: "rectangle.connected.to.line.below") }
        }
    }

    private var deviceWorkspace: some View {
        HSplitView {
            Form {
                Section("Device preset") {
                    Picker(
                        "Device",
                        selection: Binding(
                            get: { model.resolvedDevice?.id ?? "" },
                            set: { id in
                                guard let device = library.document.devices.first(
                                    where: { $0.id == id }
                                ) else { return }
                                model.selectDevice(device)
                            }
                        )
                    ) {
                        ForEach(library.document.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .accessibilityLabel("Seleccionar device preset")
                }

                if let device = model.resolvedDevice?.definition {
                    Section("Propiedades efectivas resueltas") {
                        LabeledContent("Categoría", value: device.category.rawValue)
                        LabeledContent(
                            "Resolución",
                            value: "\(device.nativeWidth) × \(device.nativeHeight)"
                        )
                        LabeledContent(
                            "Área activa",
                            value: "\((device.activeWidthMeters * 1_000).formatted(.number.precision(.fractionLength(1)))) × "
                                + "\((device.activeHeightMeters * 1_000).formatted(.number.precision(.fractionLength(1)))) mm"
                        )
                        LabeledContent(
                            "Densidad",
                            value: "\(device.pixelsPerInch.formatted(.number.precision(.fractionLength(1)))) PPI"
                        )
                        LabeledContent(
                            "Pixel pitch",
                            value: "\(device.pixelPitchMicrometers.formatted(.number.precision(.fractionLength(1)))) µm"
                        )
                        LabeledContent("Panel", value: device.panelTechnology.rawValue)
                        LabeledContent(
                            "EOTF",
                            value: "γ \(device.eotfGamma.formatted(.number.precision(.fractionLength(2))))"
                        )
                        LabeledContent(
                            "Luminancia",
                            value: "\(device.blackLevelNits.formatted())–\(device.whiteLevelNits.formatted()) nits"
                        )
                        LabeledContent("Subpíxeles", value: device.stripeLayout.rawValue)
                        LabeledContent(
                            "Black matrix",
                            value: device.blackMatrixFraction.formatted(.percent)
                        )
                        LabeledContent(
                            "Cover glass",
                            value: device.defaultCoverGlassPresetID
                        )
                        LabeledContent(
                            "Physical stage",
                            value: model.deviceStageAmount == 1
                                ? "1 · Físico calibrado" : "0 · Identidad exacta"
                        )
                    }
                    Section {
                        Text(
                            "La selección crea un snapshot inmutable. Editar o borrar "
                                + "el preset global no cambia esta evaluación."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView(
                        "Sin device seleccionado",
                        systemImage: "display.slash"
                    )
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 360, idealWidth: 400, maxWidth: 560)

            preview
                .frame(minWidth: 640, minHeight: 480)
        }
        .background(SplitAutosaveProbe(name: "ScreenSimulation.Native.Device"))
    }

    private var monitorSettings: some View {
        Form {
            Section("DeckLink") {
                LabeledContent(
                    "Runtime",
                    value: model.monitorOutput.report.runtime.displayName
                )
                LabeledContent(
                    "Integración",
                    value: model.monitorOutput.report.bridge.displayName
                )
                LabeledContent(
                    "Dispositivos",
                    value: "\(model.monitorOutput.report.devices.count)"
                )
                LabeledContent("Estado", value: model.monitorOutput.status)
                Button("Actualizar dispositivos") {
                    model.monitorOutput.refresh()
                }
            }

            if !model.monitorOutput.report.devices.isEmpty {
                Section("Señal de monitorización") {
                    Picker(
                        "Dispositivo",
                        selection: Binding(
                            get: { model.monitorOutput.selectedDeviceID },
                            set: { model.monitorOutput.selectDevice($0) }
                        )
                    ) {
                        ForEach(model.monitorOutput.report.devices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    if let device = model.monitorOutput.selectedDevice {
                        Picker(
                            "Modo",
                            selection: Binding(
                                get: { model.monitorOutput.selectedModeID },
                                set: { model.monitorOutput.selectMode($0) }
                            )
                        ) {
                            ForEach(device.modes, id: \.identifier) { mode in
                                Text(
                                    "\(mode.name) · \(mode.width) × \(mode.height) · "
                                        + "\(mode.framesPerSecond) fps"
                                )
                                .tag(mode.identifier)
                            }
                        }
                    }
                    if let mode = model.monitorOutput.selectedMode {
                        Picker(
                            "ODT",
                            selection: Binding(
                                get: { model.monitorOutput.selectedTransform },
                                set: { model.monitorOutput.selectTransform($0) }
                            )
                        ) {
                            ForEach(
                                MonitorOutputTransform.allCases.filter {
                                    mode.supportedSignals.contains($0.signal)
                                }
                            ) { transform in
                                Text(transform.label).tag(transform)
                            }
                        }
                        Picker(
                            "Rango",
                            selection: Binding(
                                get: { model.monitorOutput.selectedRange },
                                set: { model.monitorOutput.selectRange($0) }
                            )
                        ) {
                            ForEach(
                                VideoOutputRange.allCases.filter {
                                    mode.supportedRanges.contains($0)
                                }
                            ) { range in
                                Text(range.displayName).tag(range)
                            }
                        }
                        Picker(
                            "Formato de píxel",
                            selection: Binding(
                                get: { model.monitorOutput.selectedPixelFormat },
                                set: { model.monitorOutput.selectPixelFormat($0) }
                            )
                        ) {
                            ForEach(
                                VideoOutputPixelFormat.allCases.filter {
                                    mode.supportedPixelFormats.contains($0)
                                }
                            ) { pixelFormat in
                                Text(pixelFormat.displayName).tag(pixelFormat)
                            }
                        }
                    }
                    Button(
                        model.monitorOutput.isEnabled
                            ? "Detener monitorización" : "Iniciar monitorización"
                    ) {
                        model.monitorOutput.toggle(
                            frame: model.metalFrame,
                            display: model.metalDisplay
                        )
                    }
                    .disabled(model.monitorOutput.selectedMode == nil)
                }
            }

            if let error = model.monitorOutput.errorMessage {
                Section("Error") {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section {
                Text(
                    "La ODT, el dispositivo/modo, la resolución/fps, el rango "
                        + "y el formato de píxel pertenecen a DeckLink. No reutilizan "
                        + "la View del Mac ni la ODT de la cola de render."
                )
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var globalCollections: some View {
        VStack(spacing: 0) {
            if let error = library.blockedError {
                ContentUnavailableView(
                    "Biblioteca bloqueada",
                    systemImage: "exclamationmark.lock",
                    description: Text(error)
                )
            } else {
                TabView {
                    List(SyntheticPattern.allCases) { pattern in
                        Label(pattern.label, systemImage: "camera.filters")
                    }
                    .tabItem { Label("Patrones", systemImage: "camera.filters") }

                    testImageLibrary
                        .tabItem { Label("Imágenes", systemImage: "photo.stack") }

                    renderPresetLibrary
                        .tabItem { Label("Presets", systemImage: "slider.horizontal.3") }

                    deviceLibrary
                        .tabItem { Label("Devices", systemImage: "display") }
                }
            }
        }
    }

    private var testImageLibrary: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $library.selectedImageID) {
                    ForEach(library.document.testImages) { image in
                        Text(image.name).tag(image.id)
                    }
                }
                HStack {
                    Button(action: library.addTestImage) { Image(systemName: "plus") }
                        .help("Añadir imagen PNG o EXR")
                    Button(action: library.removeSelectedImage) { Image(systemName: "minus") }
                        .disabled(library.selectedImageID == nil)
                        .help("Eliminar imagen seleccionada")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 280)

            if let image = selectedTestImage {
                Form {
                    Section("Interpretación explícita") {
                        TextField("Nombre", text: Binding(
                            get: { image.name },
                            set: { value in library.updateSelectedImage { $0.name = value } }
                        ))
                        Picker("IDT", selection: Binding(
                            get: { image.inputTransformID },
                            set: { value in library.updateSelectedImage { $0.inputTransformID = value } }
                        )) {
                            ForEach(StudioColorInputTransform.catalog) { transform in
                                Text(transform.label).tag(transform.id)
                            }
                        }
                        Picker("Alpha", selection: Binding(
                            get: { image.alpha },
                            set: { value in library.updateSelectedImage { $0.alpha = value } }
                        )) {
                            ForEach(StudioAlphaMode.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Matriz", selection: Binding(
                            get: { image.matrix },
                            set: { value in library.updateSelectedImage { $0.matrix = value } }
                        )) {
                            ForEach(StudioSignalMatrix.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Rango", selection: Binding(
                            get: { image.range },
                            set: { value in library.updateSelectedImage { $0.range = value } }
                        )) {
                            ForEach(StudioSignalRange.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("Sin imagen", systemImage: "photo.badge.plus")
            }
        }
    }

    private var renderPresetLibrary: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $library.selectedPresetID) {
                    Section("Incluidos") {
                        ForEach(StudioRenderPreset.builtIns) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                    Section("Usuario") {
                        ForEach(library.document.renderPresets) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                }
                HStack {
                    Button(action: library.addRenderPreset) { Image(systemName: "plus") }
                        .help("Crear preset global")
                    Button(action: library.duplicateSelectedPreset) {
                        Image(systemName: "plus.square.on.square")
                    }
                    .disabled(library.selectedPresetID == nil)
                    .help("Duplicar preset")
                    Button(action: library.removeSelectedPreset) { Image(systemName: "minus") }
                        .disabled(!selectedPresetIsEditable)
                        .help("Eliminar preset de usuario")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 280)

            if let preset = selectedGlobalPreset {
                Form {
                    Section("Configuración efectiva") {
                        TextField("Nombre", text: Binding(
                            get: { preset.name },
                            set: { value in library.updateSelectedPreset { $0.name = value } }
                        ))
                        .disabled(!selectedPresetIsEditable)
                        LabeledContent("Pipeline", value: preset.pipeline.rawValue)
                        LabeledContent("Destino", value: preset.target.rawValue)
                        TextField("Peak nits", value: Binding(
                            get: { preset.peakNits },
                            set: { value in library.updateSelectedPreset { $0.peakNits = value } }
                        ), format: .number)
                        .disabled(!selectedPresetIsEditable)
                        Text("El preset rellena opciones; los trabajos conservan sus valores resueltos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("Sin preset", systemImage: "slider.horizontal.3")
            }
        }
    }

    private var deviceLibrary: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $library.selectedDeviceID) {
                    ForEach(library.document.devices) { device in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(device.category.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(device.id)
                    }
                }
                HStack {
                    Button(action: library.addDevice) { Image(systemName: "plus") }
                        .help("Crear device global")
                    Button(action: library.duplicateSelectedDevice) {
                        Image(systemName: "plus.square.on.square")
                    }
                    .disabled(library.selectedDeviceID == nil)
                    .help("Duplicar device")
                    Button(action: library.removeSelectedDevice) {
                        Image(systemName: "minus")
                    }
                    .disabled(library.selectedDeviceID == nil)
                    .help("Eliminar device")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 220, idealWidth: 280)

            if let device = library.selectedDevice {
                deviceEditor(device)
            } else {
                ContentUnavailableView("Sin device", systemImage: "display.slash")
            }
        }
    }

    private func deviceEditor(_ device: DeviceDefinition) -> some View {
        Form {
            Section("Identidad") {
                TextField("Nombre", text: Binding(
                    get: { device.name },
                    set: { value in library.updateSelectedDevice { $0.name = value } }
                ))
                Picker("Categoría", selection: Binding(
                    get: { device.category },
                    set: { value in library.updateSelectedDevice { $0.category = value } }
                )) {
                    ForEach(DeviceCategory.allCases) { Text($0.rawValue).tag($0) }
                }
                LabeledContent("ID estable", value: device.id)
                    .textSelection(.enabled)
            }

            Section("Geometría física") {
                TextField("Anchura nativa", value: Binding(
                    get: { device.nativeWidth },
                    set: { value in library.updateSelectedDevice { $0.nativeWidth = value } }
                ), format: .number)
                TextField("Altura nativa", value: Binding(
                    get: { device.nativeHeight },
                    set: { value in library.updateSelectedDevice { $0.nativeHeight = value } }
                ), format: .number)
                TextField("Anchura activa (m)", value: Binding(
                    get: { device.activeWidthMeters },
                    set: { value in library.updateSelectedDevice { $0.activeWidthMeters = value } }
                ), format: .number.precision(.fractionLength(6)))
                TextField("Altura activa (m)", value: Binding(
                    get: { device.activeHeightMeters },
                    set: { value in library.updateSelectedDevice { $0.activeHeightMeters = value } }
                ), format: .number.precision(.fractionLength(6)))
                LabeledContent("Diagonal", value: "\(device.diagonalInches.formatted(.number.precision(.fractionLength(1)))) in")
                LabeledContent("PPI", value: device.pixelsPerInch.formatted(.number.precision(.fractionLength(1))))
                LabeledContent("Pixel pitch", value: "\(device.pixelPitchMicrometers.formatted(.number.precision(.fractionLength(1)))) µm")
            }

            Section("Panel y emisión") {
                Picker("Tecnología", selection: Binding(
                    get: { device.panelTechnology },
                    set: { value in library.updateSelectedDevice { $0.panelTechnology = value } }
                )) {
                    ForEach(DevicePanelTechnology.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Modelo", selection: Binding(
                    get: { device.emissionModel },
                    set: { value in library.updateSelectedDevice { $0.emissionModel = value } }
                )) {
                    ForEach(DeviceEmissionModel.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("EOTF gamma", value: Binding(
                    get: { device.eotfGamma },
                    set: { value in library.updateSelectedDevice { $0.eotfGamma = value } }
                ), format: .number)
                TextField("Negro (nits)", value: Binding(
                    get: { device.blackLevelNits },
                    set: { value in library.updateSelectedDevice { $0.blackLevelNits = value } }
                ), format: .number)
                TextField("Blanco (nits)", value: Binding(
                    get: { device.whiteLevelNits },
                    set: { value in library.updateSelectedDevice { $0.whiteLevelNits = value } }
                ), format: .number)
                TextField("Base del blanco", text: Binding(
                    get: { device.whiteBasis },
                    set: { value in library.updateSelectedDevice { $0.whiteBasis = value } }
                ))
            }

            Section("Subpíxeles") {
                Picker("Orden", selection: Binding(
                    get: { device.stripeLayout },
                    set: { value in library.updateSelectedDevice { $0.stripeLayout = value } }
                )) {
                    ForEach(DeviceStripeLayout.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Black matrix", value: Binding(
                    get: { device.blackMatrixFraction },
                    set: { value in library.updateSelectedDevice { $0.blackMatrixFraction = value } }
                ), format: .number)
            }

            DisclosureGroup("Colorimetría nativa") {
                chromaticityRow("Rojo", value: device.red) { newValue in
                    library.updateSelectedDevice { $0.red = newValue }
                }
                chromaticityRow("Verde", value: device.green) { newValue in
                    library.updateSelectedDevice { $0.green = newValue }
                }
                chromaticityRow("Azul", value: device.blue) { newValue in
                    library.updateSelectedDevice { $0.blue = newValue }
                }
                chromaticityRow("Blanco", value: device.white) { newValue in
                    library.updateSelectedDevice { $0.white = newValue }
                }
            }

            DisclosureGroup("Respuesta angular y temporal") {
                ForEach(Array(["R", "G", "B"].enumerated()), id: \.offset) { item in
                    TextField("Potencia angular \(item.element)", value: Binding(
                        get: { device.angularEmissionPower[item.offset] },
                        set: { value in
                            library.updateSelectedDevice {
                                $0.angularEmissionPower[item.offset] = value
                            }
                        }
                    ), format: .number)
                }
                TextField("Flicker residual (Hz)", value: Binding(
                    get: { 1 / device.residualFlickerPeriod.seconds },
                    set: { value in
                        library.updateSelectedDevice {
                            $0.residualFlickerPeriod = .init(
                                numerator: 1,
                                denominator: UInt32(max(1, value.rounded()))
                            )
                        }
                    }
                ), format: .number)
                TextField("Amplitud residual", value: Binding(
                    get: { device.residualFlickerAmplitude },
                    set: { value in
                        library.updateSelectedDevice {
                            $0.residualFlickerAmplitude = value
                        }
                    }
                ), format: .number)
                TextField("Banding (Hz)", value: Binding(
                    get: { 1 / device.bandingPeriod.seconds },
                    set: { value in
                        library.updateSelectedDevice {
                            let denominator = UInt32(max(1, value.rounded()))
                            $0.bandingPeriod = .init(numerator: 1, denominator: denominator)
                            $0.bandingOnDuration = .init(
                                numerator: 1,
                                denominator: denominator * 2
                            )
                        }
                    }
                ), format: .number)
                TextField("Cantidad de banding", value: Binding(
                    get: { device.bandingAmount },
                    set: { value in
                        library.updateSelectedDevice { $0.bandingAmount = value }
                    }
                ), format: .number)
            }

            Section("Asociación") {
                TextField("Cover glass predeterminado", text: Binding(
                    get: { device.defaultCoverGlassPresetID },
                    set: { value in
                        library.updateSelectedDevice {
                            $0.defaultCoverGlassPresetID = value
                        }
                    }
                ))
            }

            if let validation = library.deviceValidationMessage {
                Section("Validación") {
                    Text(validation).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chromaticityRow(
        _ label: String,
        value: DeviceChromaticity,
        update: @escaping (DeviceChromaticity) -> Void
    ) -> some View {
        LabeledContent(label) {
            HStack {
                TextField("x", value: Binding(
                    get: { value.x },
                    set: { update(.init(x: $0, y: value.y)) }
                ), format: .number)
                TextField("y", value: Binding(
                    get: { value.y },
                    set: { update(.init(x: value.x, y: $0)) }
                ), format: .number)
            }
            .frame(maxWidth: 240)
        }
    }

    private var selectedTestImage: GlobalTestImage? {
        library.document.testImages.first { $0.id == library.selectedImageID }
    }

    private var selectedGlobalPreset: StudioRenderPreset? {
        library.allRenderPresets.first { $0.id == library.selectedPresetID }
    }

    private var selectedPresetIsEditable: Bool {
        library.document.renderPresets.contains { $0.id == library.selectedPresetID }
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
                    ForEach(library.allRenderPresets) { Text($0.name).tag($0) }
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
