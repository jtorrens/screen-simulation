import AppKit
import MetalKit
import StudioColor
import StudioMedia
import StudioVideoOutput
import SwiftUI

struct ContentView: View {
    enum LibraryDeletion: String {
        case testImage = "imagen de test"
        case renderPreset = "preset de render"
        case device = "device preset"
    }
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
    @State private var pendingLibraryDeletion: LibraryDeletion?

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
            HStack(spacing: 16) {
                Spacer()
                ForEach(WorkspacePage.allCases) { destination in
                    Button {
                        page = destination
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: destination.systemImage)
                            Text(destination.rawValue).font(.caption2)
                        }
                        .frame(minWidth: 64, minHeight: 38)
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
            .frame(height: 46)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar { workspaceToolbar }
        .onAppear {
            if model.resolvedDevice == nil,
               let first = library.document.devices.first {
                model.selectDevice(first, amount: page == .device ? 1 : 0)
            }
        }
        .onChange(of: page) { _, destination in
            model.setDeviceStageAmount(destination == .device ? 1 : 0)
        }
        .alert(
            "SCREEN-SIMULATION",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) { Button("Aceptar") { model.errorMessage = nil } }
        message: { Text(model.errorMessage ?? "") }
        .confirmationDialog(
            "¿Eliminar \(pendingLibraryDeletion?.rawValue ?? "elemento")?",
            isPresented: Binding(
                get: { pendingLibraryDeletion != nil },
                set: { if !$0 { pendingLibraryDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Eliminar", role: .destructive) {
                switch pendingLibraryDeletion {
                case .testImage: library.removeSelectedImage()
                case .renderPreset: library.removeSelectedPreset()
                case .device: library.removeSelectedDevice()
                case nil: break
                }
                pendingLibraryDeletion = nil
            }
            Button("Cancelar", role: .cancel) { pendingLibraryDeletion = nil }
        }
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

            preview()
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

            globalLibrary
            .tabItem { Label("Biblioteca", systemImage: "books.vertical") }

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
                                model.selectDevice(device, amount: 1)
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
                    Section("Placement de fuente") {
                        Picker("Placement", selection: Binding(
                            get: { model.sourcePlacement },
                            set: { model.changeSourcePlacement($0) }
                        )) {
                            ForEach(WorkspaceModel.SourcePlacement.allCases) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        Text("Pertenece al estado de escena/render; no modifica el preset global.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

            preview(deviceAspect: model.resolvedDevice.map {
                Double($0.definition.nativeWidth) / Double($0.definition.nativeHeight)
            })
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

    private var globalLibrary: some View {
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
                    Button { pendingLibraryDeletion = .testImage } label: { Image(systemName: "trash") }
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
                    ForEach(library.document.renderPresets) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            Text("\(preset.pipeline.rawValue) · \(preset.target.rawValue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(preset.id)
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
                    Button { pendingLibraryDeletion = .renderPreset } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(library.selectedPresetID == nil)
                    .help("Eliminar preset")
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
                        Picker("Pipeline", selection: Binding(
                            get: { preset.pipeline },
                            set: { value in updatePresetPipeline(value) }
                        )) {
                            Text("ACES").tag(StudioRenderPipeline.aces)
                            Text("DaVinci Color Managed").tag(StudioRenderPipeline.davinciColorManaged)
                        }
                        Picker("Destino", selection: Binding(
                            get: { preset.target },
                            set: { value in updatePresetTarget(value) }
                        )) {
                            Text("SDR").tag(StudioRenderTarget.sdr)
                            Text("HDR").tag(StudioRenderTarget.hdr)
                            Text("ACES2065-1").tag(StudioRenderTarget.aces2065)
                            Text("ACEScg").tag(StudioRenderTarget.acescg)
                        }
                        TextField("Peak nits", value: Binding(
                            get: { preset.peakNits },
                            set: { value in library.updateSelectedPreset { $0.peakNits = value } }
                        ), format: .number)
                        Picker("Formato / codec", selection: Binding(
                            get: { preset.format },
                            set: { value in
                                library.updateSelectedPreset {
                                    $0.format = value
                                    $0.pixelEncoding = value.defaultPixelEncoding
                                    $0.signalRange = value.supportedSignalRanges(
                                        for: value.defaultPixelEncoding
                                    )[0]
                                    if !value.supportsAlpha { $0.alpha = .ignore }
                                    if !value.isMovie { $0.includeAudio = false }
                                }
                            }
                        )) {
                            ForEach(StudioOutputFormat.allCases) { Text($0.displayName).tag($0) }
                        }
                        LabeledContent("Codificación", value: preset.pixelEncoding.label)
                        Picker("Rango", selection: Binding(
                            get: { preset.signalRange },
                            set: { value in library.updateSelectedPreset { $0.signalRange = value } }
                        )) {
                            ForEach(StudioSignalRange.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Alpha", selection: Binding(
                            get: { preset.alpha },
                            set: { value in library.updateSelectedPreset { $0.alpha = value } }
                        )) {
                            ForEach(StudioAlphaMode.allCases) { Text($0.label).tag($0) }
                        }
                        Toggle("Audio", isOn: Binding(
                            get: { preset.includeAudio },
                            set: { value in library.updateSelectedPreset { $0.includeAudio = value } }
                        ))
                        LabeledContent("ODT", value: preset.view ?? "Scene-linear · sin ODT")
                        LabeledContent("Contenedor", value: preset.format.fileExtension.uppercased())
                        Text(preset.authoritativeRoundtripNotes)
                            .font(.caption)
                            .textSelection(.enabled)
                        TextEditor(text: Binding(
                            get: { preset.notes },
                            set: { value in library.updateSelectedPreset { $0.notes = value } }
                        ))
                        .frame(minHeight: 70)
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
                    Button { pendingLibraryDeletion = .device } label: {
                        Image(systemName: "trash")
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

    private func updatePresetPipeline(_ pipeline: StudioRenderPipeline) {
        library.updateSelectedPreset { preset in
            preset.pipeline = pipeline
            guard preset.target == .sdr || preset.target == .hdr else { return }
            if preset.target == .sdr {
                preset.display = "Rec.1886 Rec.709 - Display"
                preset.view = pipeline == .aces
                    ? "ACES 2.0 - SDR 100 nits (Rec.709)" : "Video (colorimetric)"
            } else {
                preset.display = "Rec.2100-PQ - Display"
                preset.view = pipeline == .aces
                    ? "ACES 2.0 - HDR 1000 nits (Rec.2020)" : "Video (colorimetric)"
            }
        }
    }

    private func updatePresetTarget(_ target: StudioRenderTarget) {
        library.updateSelectedPreset { preset in
            preset.target = target
            switch target {
            case .sdr:
                preset.peakNits = 100
                preset.display = "Rec.1886 Rec.709 - Display"
                preset.view = preset.pipeline == .aces
                    ? "ACES 2.0 - SDR 100 nits (Rec.709)" : "Video (colorimetric)"
                preset.format = .proRes4444
                preset.signalRange = .full
            case .hdr:
                preset.peakNits = 1_000
                preset.display = "Rec.2100-PQ - Display"
                preset.view = preset.pipeline == .aces
                    ? "ACES 2.0 - HDR 1000 nits (Rec.2020)" : "Video (colorimetric)"
                preset.format = .proRes4444
                preset.signalRange = .full
            case .aces2065, .acescg:
                preset.peakNits = 0
                preset.display = nil
                preset.view = nil
                preset.format = .openEXR
                preset.signalRange = .full
                preset.alpha = .straight
                preset.includeAudio = false
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
                LabeledContent("Modelo de señal") {
                    interpretationLabel(
                        model.signalColorModel.label,
                        annotation: model.colorModelAnnotation(model.signalColorModel)
                    )
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
                Picker("Preset", selection: Binding(
                    get: { model.renderPreset },
                    set: { model.applyRenderPreset($0) }
                )) {
                    ForEach(library.allRenderPresets) { Text($0.name).tag($0) }
                }
                LabeledContent("ODT del preset", value: model.renderPreset.view ?? model.renderPreset.target.rawValue)
                LabeledContent("ODT efectiva", value: model.renderPreset.view ?? model.renderPreset.target.rawValue)
                LabeledContent("Peak nits") {
                    TextField("nits", value: $model.peakNits, format: .number).frame(width: 90)
                }
                Picker("Formato", selection: Binding(
                    get: { model.outputFormat },
                    set: { model.changeOutputFormat($0) }
                )) {
                    ForEach(StudioOutputFormat.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Codificación", value: model.outputPixelEncoding.label)
                Picker("Rango de señal", selection: $model.outputSignalRange) {
                    ForEach(StudioSignalRange.allCases) { range in
                        Text(range.label).tag(range)
                            .disabled(!model.outputFormat.supportedSignalRanges(
                                for: model.outputPixelEncoding
                            ).contains(range))
                    }
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
                    Text(job.configuration.format.displayName).font(.caption)
                    Text("\(job.configuration.firstFrame)–\(job.configuration.lastFrame) · \(job.configuration.pixelEncoding.label) · \(job.configuration.signalRange.label) · \(job.detail)")
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
            Section("Presentación del visor") {
                LabeledContent("Interpretación", value: model.inputTransform.label)
                LabeledContent("ODT preview", value: model.previewTransform.label)
                LabeledContent("Señal CAMetalLayer", value: model.previewTransform.declaredSignalDescription)
                LabeledContent("Pantalla", value: model.systemDisplayInfo.displayName)
                LabeledContent("Perfil ColorSync", value: model.systemDisplayInfo.profileName)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 180, idealHeight: 220)
    }

    private func preview(deviceAspect: Double? = nil) -> some View {
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
                Button {
                    model.monitorOutput.toggle(
                        frame: model.metalFrame,
                        display: model.metalDisplay
                    )
                } label: {
                    Image(systemName: model.monitorOutput.isActive
                        ? "rectangle.connected.to.line.below.fill"
                        : "rectangle.connected.to.line.below")
                }
                .foregroundStyle(model.monitorOutput.isActive ? .blue : .secondary)
                .help(model.monitorOutput.isActive
                    ? "Detener monitorización DeckLink"
                    : "Iniciar monitorización DeckLink")
                .accessibilityLabel(model.monitorOutput.isActive
                    ? "Detener monitorización DeckLink"
                    : "Iniciar monitorización DeckLink")
                Button { model.zoomBy(0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Reducir zoom")
                    .accessibilityLabel("Reducir zoom")
                TextField("Zoom", value: Binding(
                    get: { model.zoomPercentage },
                    set: { model.zoomPercentage = $0 }
                ), format: .number.precision(.fractionLength(0)))
                    .frame(width: 52)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel("Escala del visor en porcentaje")
                Text("%").foregroundStyle(.secondary)
                Button("Fit", action: model.resetView)
                    .help("Ajustar imagen al visor")
                Button { model.zoomBy(1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Aumentar zoom")
                    .accessibilityLabel("Aumentar zoom")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ZStack {
                if deviceAspect == nil {
                    Color(nsColor: .black)
                } else {
                    Color(nsColor: NSColor(deviceWhite: 0.18, alpha: 1))
                }
                if let frame = model.metalFrame {
                    let image = MetalPreview(
                        display: model.metalDisplay,
                        frame: frame,
                        output: model.previewTransform,
                        zoom: model.zoom,
                        pan: model.pan,
                        onDisplayChange: { model.systemDisplayInfo = $0 }
                    )
                    .gesture(
                        DragGesture().onChanged { value in model.pan = value.translation }
                    )
                    .gesture(
                        MagnifyGesture().onChanged { value in
                            model.zoom = min(16, max(0.1, value.magnification))
                        }
                    )
                    .accessibilityLabel("Preview OCIO del resultado")
                    if let deviceAspect {
                        image
                            .aspectRatio(deviceAspect, contentMode: .fit)
                            .background(.black)
                            .overlay {
                                Rectangle()
                                    .stroke(.white.opacity(0.22), lineWidth: 1)
                            }
                            .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
                            .padding(28)
                    } else {
                        image
                    }
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
                .foregroundStyle(model.isPlaying ? .blue : .primary)
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
                Button {
                    model.loopPlayback.toggle()
                } label: {
                    Image(systemName: model.loopPlayback ? "repeat.circle.fill" : "repeat")
                }
                .foregroundStyle(model.loopPlayback ? .blue : .secondary)
                .help(model.loopPlayback ? "Desactivar repetición" : "Activar repetición")
                .accessibilityLabel(model.loopPlayback ? "Desactivar repetición" : "Activar repetición")
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
    let zoom: Double
    let pan: CGSize
    let onDisplayChange: (StudioColorSystemDisplayInfo) -> Void

    func makeNSView(context _: Context) -> MetalPreviewContainer {
        let container = MetalPreviewContainer()
        let view = StudioColorScreenAwareMetalView()
        view.screenDidChange = onDisplayChange
        display.configure(view)
        container.install(view)
        return container
    }

    func updateNSView(_ container: MetalPreviewContainer, context _: Context) {
        container.metalView.screenDidChange = onDisplayChange
        container.updatePresentation(zoom: zoom, pan: pan)
        display.present(frame, output: output, in: container.metalView)
    }
}

final class MetalPreviewContainer: NSView {
    private(set) var metalView = StudioColorScreenAwareMetalView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func install(_ view: StudioColorScreenAwareMetalView) {
        metalView.removeFromSuperview()
        metalView = view
        addSubview(view)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        metalView.frame = bounds
    }

    func updatePresentation(zoom: Double, pan: CGSize) {
        metalView.layer?.setAffineTransform(
            CGAffineTransform(translationX: pan.width, y: -pan.height)
                .scaledBy(x: zoom, y: zoom)
        )
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
