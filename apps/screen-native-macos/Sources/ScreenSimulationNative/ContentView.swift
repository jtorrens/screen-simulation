import AppKit
import MetalKit
import ScreenSimulationMacUI
import ScreenSimulationPresentation
import StudioColor
import StudioMedia
import StudioVideoOutput
import SwiftUI

enum NativeTheme {
    static let accent = Color(red: 0.88, green: 0.57, blue: 0.16)
    static let nsAccent = NSColor(
        calibratedRed: 0.88, green: 0.57, blue: 0.16, alpha: 1
    )
}

struct ContentView: View {
    enum PendingSceneAction {
        case open, update, renderAfterUpdate, delete
    }
    enum LibraryDeletion: String {
        case pattern = "patrón"
        case testImage = "imagen de test"
        case renderPreset = "preset de render"
        case device = "device preset"
        case coverGlass = "preset de Cover Glass"
        case camera = "perfil de cámara"
        case lens = "perfil de lente"
        case environment = "perfil de entorno"
    }
    enum WorkspacePage: String, CaseIterable, Identifiable {
        case main = "Principal"
        case test = "Escena"
        case settings = "Settings"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .main: "rectangle.on.rectangle"
            case .test: "checklist.checked"
            case .settings: "gearshape"
            }
        }
    }

    enum SidebarTab: String, CaseIterable, Identifiable {
        case output = "Output"
        case queue = "Render Queue"
        var id: String { rawValue }
    }

    enum SettingsSection: String, CaseIterable, Identifiable {
        case application = "Aplicación"
        case library = "Biblioteca"
        case monitor = "Monitor"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .application: "info.circle"
            case .library: "books.vertical"
            case .monitor: "rectangle.connected.to.line.below"
            }
        }
    }

    enum LibraryCollection: String, CaseIterable, Identifiable {
        case patterns = "Patrones"
        case testImages = "Imágenes de test"
        case renderPresets = "Presets de render"
        case devices = "Devices"
        case coverGlasses = "Cover Glass"
        case cameras = "Cámaras"
        case lenses = "Lentes"
        case environments = "Entornos"

        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .patterns: "camera.filters"
            case .testImages: "photo.stack"
            case .renderPresets: "slider.horizontal.3"
            case .devices: "display"
            case .coverGlasses: "square.3.layers.3d"
            case .cameras: "camera"
            case .lenses: "camera.aperture"
            case .environments: "globe"
            }
        }
    }

    @Environment(\.undoManager) private var undoManager
    @ObservedObject var model: WorkspaceModel
    @StateObject private var library = GlobalLibraryController()
    @StateObject private var scenes = SceneLibraryController()
    @StateObject private var referenceMatchPanel = ReferenceMatchPanelController()
    @StateObject private var reflectionEnvironmentPanel = ReflectionEnvironmentPanelController()
    @StateObject private var environmentReflectionFramingPanel = EnvironmentReflectionFramingPanelController()
    @StateObject private var trackingScenePanel = TrackingScenePanelController()
    @State private var tab = SidebarTab.output
    @State private var page = WorkspacePage.test
    @State private var settingsSection = SettingsSection.application
    @State private var libraryCollection = LibraryCollection.patterns
    @State private var pendingLibraryDeletion: LibraryDeletion?
    @State private var sidebarIsVisible = true
    @State private var pendingSceneAction: PendingSceneAction?
    @State private var pendingScene: SavedScene?
    @State private var pendingRenderScene: SavedScene?
    @State private var autosaveHistoryTarget: SceneAutosaveHistoryTarget?
    // Card expansion is UI-only state.  Parameter publication may replace the
    // presentation descriptor, but never changes this authored-inspector layout.
    @State private var expandedTestInspectorCards: Set<String> = ["general"]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .main: mainWorkspace
                case .test: testWorkspace
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
                                .foregroundStyle(page == destination
                                    ? NativeTheme.accent : .secondary)
                            Text(destination.rawValue)
                                .font(.caption2)
                                .foregroundStyle(page == destination
                                    ? NativeTheme.accent : .secondary)
                        }
                        .frame(minWidth: 64, minHeight: 38)
                    }
                    .buttonStyle(.borderless)
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
            model.configureSceneEnvironmentPersistence { sceneID, data in
                try scenes.replaceGeneratedEnvironment(sceneID: sceneID, data: data)
            }
            if model.resolvedDevice == nil,
               let first = library.document.devices.first,
               let cover = library.document.coverGlasses.first(
                    where: { $0.id == first.value.defaultCoverGlassPresetID }
               ) {
                model.selectDevice(first.value, coverGlass: cover.value, amount: 0)
            }
        }
        .onChange(of: library.document) { _, _ in
            model.refreshActiveSceneFromGlobalLibrary()
        }
        .onChange(of: page) { _, destination in
            model.setModelPageActive(false)
            model.setTestPageActive(destination == .test)
        }
        .alert(
            "SCREEN-SIMULATION",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) { Button("Aceptar") { model.errorMessage = nil } }
        message: { Text(model.errorMessage ?? "") }
        .sheet(item: $pendingRenderScene) { scene in
            renderOptionsSheet(scene)
        }
        .sheet(item: $autosaveHistoryTarget) { target in
            SceneAutosaveHistoryView(
                target: target,
                controller: scenes,
                onRestore: { revision in
                    do {
                        let restored = try scenes.restoreAutosave(revision)
                        model.markActiveScene(restored.id)
                        autosaveHistoryTarget = nil
                    } catch { model.errorMessage = error.localizedDescription }
                }
            )
        }
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
                case .pattern: library.removeSelectedPattern()
                case .testImage: library.removeSelectedImage()
                case .renderPreset: library.removeSelectedPreset()
                case .device: library.removeSelectedDevice()
                case .coverGlass: library.removeSelectedCoverGlass()
                case .camera: library.removeSelectedCamera()
                case .lens: library.removeSelectedLens()
                case .environment: library.removeSelectedEnvironment()
                case nil: break
                }
                pendingLibraryDeletion = nil
            }
            Button("Cancelar", role: .cancel) { pendingLibraryDeletion = nil }
        }
        .confirmationDialog(
            sceneConfirmationTitle,
            isPresented: Binding(
                get: { pendingSceneAction != nil && pendingScene != nil },
                set: {
                    if !$0 {
                        pendingSceneAction = nil
                        pendingScene = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingSceneAction, let scene = pendingScene {
                Button(sceneConfirmationButton(action), role: action == .delete ? .destructive : nil) {
                    performConfirmedSceneAction(action, scene: scene)
                }
            }
            Button("Cancelar", role: .cancel) {
                pendingSceneAction = nil
                pendingScene = nil
            }
        } message: {
            if pendingSceneAction == .open {
                Text("Se sustituirá la escena cargada actualmente por el snapshot guardado.")
            } else if pendingSceneAction == .update {
                Text("Se reemplazarán los datos y la miniatura guardados por el estado activo.")
            } else if pendingSceneAction == .renderAfterUpdate {
                Text("La escena activa ha cambiado. Se guardará primero y Render Queue conservará una copia inmutable de ese estado.")
            } else {
                Text("Esta operación elimina la escena de la biblioteca.")
            }
        }
    }

    private var mainWorkspace: some View {
        HSplitView {
            if sidebarIsVisible {
                VSplitView {
                    sceneLibraryPanel
                        .frame(minHeight: 170, idealHeight: 230, maxHeight: 360)
                    VStack(spacing: 0) {
                        TabView(selection: $tab) {
                            outputPanel.tabItem { Label("Output", systemImage: "square.and.arrow.up") }.tag(SidebarTab.output)
                            queuePanel.tabItem { Label("Queue", systemImage: "list.bullet.rectangle") }.tag(SidebarTab.queue)
                        }
                        Divider()
                        contextualInspector
                    }
                }
                .frame(minWidth: 360, idealWidth: 400, maxWidth: 560)
            }

            preview()
                .frame(minWidth: 640, minHeight: 480)
        }
        .background(SplitAutosaveProbe(name: "ScreenSimulation.Native.Workspace"))
    }

    private var settingsWorkspace: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(SettingsSection.allCases) { section in
                        Button {
                            settingsSection = section
                        } label: {
                            Label(section.rawValue, systemImage: section.systemImage)
                                .foregroundStyle(
                                    settingsSection == section ? NativeTheme.accent : .primary
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            settingsSection == section ? .isSelected : []
                        )
                    }

                    if settingsSection == .library {
                        Divider()
                        Text("Colecciones")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(LibraryCollection.allCases) { collection in
                            Button {
                                libraryCollection = collection
                            } label: {
                                Label(collection.rawValue, systemImage: collection.systemImage)
                                    .foregroundStyle(
                                        libraryCollection == collection
                                            ? NativeTheme.accent : .primary
                                    )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(
                                libraryCollection == collection ? .isSelected : []
                            )
                        }
                    }
                }
                .padding(14)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
            .background(Color(nsColor: .windowBackgroundColor))
            .layoutPriority(0)

            Group {
                switch settingsSection {
                case .application:
                    applicationSettings
                case .library:
                    globalLibrary
                case .monitor:
                    monitorSettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
    }

    private var applicationSettings: some View {
        Form {
            Section("Aplicación") {
                LabeledContent("Renderer", value: "Metal · RGBA16Float")
                LabeledContent("OCIO", value: StudioColorBuildIdentity.ocioVersion)
                LabeledContent("ACES", value: StudioColorBuildIdentity.acesConfigVersion)
            }
        }
        .formStyle(.grouped)
    }

    private var testWorkspace: some View {
        HSplitView {
            if sidebarIsVisible {
                VSplitView {
                    sceneLibraryPanel
                        .frame(minHeight: 170, idealHeight: 230, maxHeight: 360)
                    testSetupPanel
                }
                .frame(minWidth: 380, idealWidth: 430, maxWidth: 620)
            }

            preview(showTestPhasePicker: true)
            .frame(minWidth: 640, minHeight: 480)
        }
        .background(SplitAutosaveProbe(name: "ScreenSimulation.Native.Test"))
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
                    .disabled(!model.monitorOutput.isAvailable)
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
        Group {
            if let error = library.blockedError {
                ContentUnavailableView(
                    "Biblioteca bloqueada",
                    systemImage: "exclamationmark.lock",
                    description: Text(error)
                )
            } else {
                switch libraryCollection {
                case .patterns: patternLibrary
                case .testImages: testImageLibrary
                case .renderPresets: renderPresetLibrary
                case .devices: deviceLibrary
                case .coverGlasses: coverGlassLibrary
                case .cameras: cameraLibrary
                case .lenses: lensLibrary
                case .environments: environmentLibrary
                }
            }
        }
    }

    private var testImageLibrary: some View {
        VSplitView {
            VStack(spacing: 0) {
                List(selection: $library.selectedImageID) {
                    ForEach(library.document.testImages) { image in
                        HStack {
                            Text(image.name)
                            Spacer()
                            if image.isLocked { Image(systemName: "lock.fill") }
                        }
                        .tag(image.id)
                    }
                }
                HStack {
                    Button(action: library.addTestImage) { Image(systemName: "plus") }
                        .help("Añadir imagen PNG o EXR")
                    Button(action: library.duplicateSelectedImage) {
                        Image(systemName: "plus.square.on.square")
                    }
                    .disabled(library.selectedImageID == nil)
                    .help("Duplicar imagen")
                    Button(action: library.unlockSelectedImage) {
                        Image(systemName: "lock.open")
                    }
                    .disabled(library.selectedImageItem?.isLocked != true)
                    .help("Desbloquear imagen")
                    Button { pendingLibraryDeletion = .testImage } label: { Image(systemName: "trash") }
                        .disabled(library.selectedImageItem?.isLocked != false)
                        .help("Eliminar imagen seleccionada")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: 160, idealHeight: 240)

            if let image = selectedTestImage {
                Form {
                    Section("Interpretación explícita") {
                        TextField("Nombre", text: Binding(
                            get: { image.name },
                            set: { value in library.updateSelectedImage { $0.name = value } }
                        ))
                        Picker("Input Transform", selection: Binding(
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
                .disabled(library.selectedImageItem?.isLocked == true)
            } else {
                ContentUnavailableView("Sin imagen", systemImage: "photo.badge.plus")
            }
        }
    }

    private var patternLibrary: some View {
        VSplitView {
            VStack(spacing: 0) {
                List(selection: $library.selectedPatternID) {
                    ForEach(library.document.patterns) { pattern in
                        HStack {
                            Text(pattern.name)
                            Spacer()
                            if pattern.isLocked { Image(systemName: "lock.fill") }
                        }
                        .tag(pattern.id)
                    }
                }
                HStack {
                    Button(action: library.addPattern) { Image(systemName: "plus") }
                        .help("Crear patrón global")
                    Button(action: library.duplicateSelectedPattern) {
                        Image(systemName: "plus.square.on.square")
                    }
                    .disabled(library.selectedPatternID == nil)
                    .help("Duplicar patrón")
                    Button(action: library.unlockSelectedPattern) {
                        Image(systemName: "lock.open")
                    }
                    .disabled(library.selectedPatternItem?.isLocked != true)
                    .help("Desbloquear patrón")
                    Button { pendingLibraryDeletion = .pattern } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(library.selectedPatternItem?.isLocked != false)
                    .help("Eliminar patrón")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: 160, idealHeight: 240)

            if let item = library.selectedPatternItem {
                Form {
                    Section("Patrón") {
                        TextField("Nombre", text: Binding(
                            get: { item.name },
                            set: { value in
                                library.updateSelectedPattern { $0.name = value }
                            }
                        ))
                        Picker("Fuente canónica", selection: Binding(
                            get: { item.pattern },
                            set: { value in
                                library.updateSelectedPattern { $0.pattern = value }
                            }
                        )) {
                            ForEach(SyntheticPattern.allCases) {
                                Text($0.label).tag($0)
                            }
                        }
                        LabeledContent("ID estable", value: item.id)
                            .textSelection(.enabled)
                    }
                }
                .formStyle(.grouped)
                .disabled(item.isLocked)
            } else {
                ContentUnavailableView("Sin patrón", systemImage: "camera.filters")
            }
        }
    }

    private var renderPresetLibrary: some View {
        VSplitView {
            VStack(spacing: 0) {
                List(selection: $library.selectedPresetID) {
                    ForEach(library.document.renderPresets) { preset in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(preset.name)
                                Spacer()
                                if preset.isLocked { Image(systemName: "lock.fill") }
                            }
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
                    Button(action: library.unlockSelectedPreset) {
                        Image(systemName: "lock.open")
                    }
                    .disabled(library.selectedPresetItem?.isLocked != true)
                    .help("Desbloquear preset")
                    Button { pendingLibraryDeletion = .renderPreset } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(library.selectedPresetItem?.isLocked != false)
                    .help("Eliminar preset")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: 160, idealHeight: 240)

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
                            Text("VFX Log / Gamut").tag(StudioRenderTarget.vfxLog)
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
                .disabled(library.selectedPresetItem?.isLocked == true)
            } else {
                ContentUnavailableView("Sin preset", systemImage: "slider.horizontal.3")
            }
        }
    }

    private var deviceLibrary: some View {
        VSplitView {
            VStack(spacing: 0) {
                List(selection: $library.selectedDeviceID) {
                    ForEach(library.document.devices) { device in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(device.name)
                                Spacer()
                                if device.isLocked { Image(systemName: "lock.fill") }
                            }
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
                    Button(action: library.unlockSelectedDevice) {
                        Image(systemName: "lock.open")
                    }
                    .disabled(library.selectedDeviceItem?.isLocked != true)
                    .help("Desbloquear device")
                    Button { pendingLibraryDeletion = .device } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(library.selectedDeviceItem?.isLocked != false)
                    .help("Eliminar device")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: 160, idealHeight: 240)

            if let device = library.selectedDevice {
                deviceEditor(device)
                    .disabled(library.selectedDeviceItem?.isLocked == true)
            } else {
                ContentUnavailableView("Sin device", systemImage: "display.slash")
            }
        }
    }

    private var cameraLibrary: some View {
        VSplitView {
            VStack(spacing: 0) {
                List(selection: $library.selectedCameraID) {
                    ForEach(library.document.cameras) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name)
                                Text("\(item.gateWidthMillimeters, format: .number) × \(item.gateHeightMillimeters, format: .number) mm")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.isLocked { Image(systemName: "lock.fill") }
                        }.tag(item.id)
                    }
                }
                HStack {
                    Button(action: library.addCamera) { Image(systemName: "plus") }
                        .help("Crear cámara global")
                    Button(action: library.duplicateSelectedCamera) { Image(systemName: "plus.square.on.square") }
                        .disabled(library.selectedCameraID == nil)
                    Button(action: library.unlockSelectedCamera) { Image(systemName: "lock.open") }
                        .disabled(library.selectedCameraItem?.isLocked != true)
                    Button { pendingLibraryDeletion = .camera } label: { Image(systemName: "trash") }
                        .disabled(library.selectedCameraItem?.isLocked != false)
                    Spacer()
                }.buttonStyle(.borderless).padding(8)
            }.frame(maxWidth: .infinity, minHeight: 160, idealHeight: 240)
            if let camera = library.selectedCameraItem?.value {
                Form {
                    Section("Identidad y sensor") {
                        TextField("Nombre", text: Binding(
                            get: { camera.name },
                            set: { value in library.updateSelectedCamera { $0.name = value } }
                        ))
                        TextField("Gate ancho (mm)", value: Binding(
                            get: { camera.gateWidthMillimeters },
                            set: { value in library.updateSelectedCamera { $0.gateWidthMillimeters = value } }
                        ), format: .number)
                        TextField("Gate alto (mm)", value: Binding(
                            get: { camera.gateHeightMillimeters },
                            set: { value in library.updateSelectedCamera { $0.gateHeightMillimeters = value } }
                        ), format: .number)
                        TextField("F-stop predeterminado", value: Binding(
                            get: { camera.defaultFStop },
                            set: { value in library.updateSelectedCamera { $0.defaultFStop = value } }
                        ), format: .number)
                        Picker("Lente predeterminada", selection: Binding(
                            get: { camera.defaultLensID },
                            set: { value in library.updateSelectedCamera { $0.defaultLensID = value } }
                        )) {
                            ForEach(library.document.lenses.filter {
                                camera.compatibleLensIDs.contains($0.id)
                            }) { Text($0.name).tag($0.id) }
                        }
                    }
                }.formStyle(.grouped).disabled(library.selectedCameraItem?.isLocked == true)
            } else {
                ContentUnavailableView("Sin cámara", systemImage: "camera")
            }
        }
    }

    private var lensLibrary: some View {
        VSplitView {
            VStack(spacing: 0) {
                List(selection: $library.selectedLensID) {
                    ForEach(library.document.lenses) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name)
                                Text("\(item.nominalFocalLengthMillimeters, format: .number) mm")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.isLocked { Image(systemName: "lock.fill") }
                        }.tag(item.id)
                    }
                }
                HStack {
                    Button(action: library.addLens) { Image(systemName: "plus") }
                        .help("Crear lente global")
                    Button(action: library.duplicateSelectedLens) { Image(systemName: "plus.square.on.square") }
                        .disabled(library.selectedLensID == nil)
                    Button(action: library.unlockSelectedLens) { Image(systemName: "lock.open") }
                        .disabled(library.selectedLensItem?.isLocked != true)
                    Button { pendingLibraryDeletion = .lens } label: { Image(systemName: "trash") }
                        .disabled(library.selectedLensItem?.isLocked != false)
                    Spacer()
                }.buttonStyle(.borderless).padding(8)
            }.frame(maxWidth: .infinity, minHeight: 160, idealHeight: 240)
            if let lens = library.selectedLensItem?.value {
                Form {
                    Section("Perfil óptico") {
                        TextField("Nombre", text: Binding(
                            get: { lens.name },
                            set: { value in library.updateSelectedLens { $0.name = value } }
                        ))
                        TextField("Focal nominal (mm)", value: Binding(
                            get: { lens.nominalFocalLengthMillimeters },
                            set: { value in library.updateSelectedLens { $0.nominalFocalLengthMillimeters = value } }
                        ), format: .number)
                        TextField("Viñeteo", value: Binding(
                            get: { lens.vignettingStrength },
                            set: { value in library.updateSelectedLens { $0.vignettingStrength = value } }
                        ), format: .number)
                        TextField("Veiling glare", value: Binding(
                            get: { lens.veilingGlareFraction },
                            set: { value in library.updateSelectedLens { $0.veilingGlareFraction = value } }
                        ), format: .number)
                    }
                }.formStyle(.grouped).disabled(library.selectedLensItem?.isLocked == true)
            } else {
                ContentUnavailableView("Sin lente", systemImage: "camera.aperture")
            }
        }
    }

    private var environmentLibrary: some View {
        VSplitView {
            VStack(spacing: 0) {
                List(selection: $library.selectedEnvironmentID) {
                    ForEach(library.document.environments) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            if item.isLocked { Image(systemName: "lock.fill") }
                        }.tag(item.id)
                    }
                }
                HStack {
                    Button(action: library.addEnvironment) { Image(systemName: "plus") }
                        .help("Crear entorno global")
                    Button(action: library.duplicateSelectedEnvironment) { Image(systemName: "plus.square.on.square") }
                        .disabled(library.selectedEnvironmentID == nil)
                    Button(action: library.unlockSelectedEnvironment) { Image(systemName: "lock.open") }
                        .disabled(library.selectedEnvironmentItem?.isLocked != true)
                    Button { pendingLibraryDeletion = .environment } label: { Image(systemName: "trash") }
                        .disabled(library.selectedEnvironmentItem?.isLocked != false)
                    Spacer()
                }.buttonStyle(.borderless).padding(8)
            }.frame(maxWidth: .infinity, minHeight: 160, idealHeight: 240)
            if let profile = library.selectedEnvironmentItem?.value {
                Form {
                    Section("Entorno procedural") {
                        TextField("Nombre", text: Binding(
                            get: { profile.name },
                            set: { value in library.updateSelectedEnvironment { $0.name = value } }
                        ))
                        TextField("Radio angular key (°)", value: Binding(
                            get: { profile.environment.keyAngularRadiusDegrees },
                            set: { value in library.updateSelectedEnvironment { $0.environment.keyAngularRadiusDegrees = value } }
                        ), format: .number)
                        TextField("Rotación X (°)", value: Binding(
                            get: { profile.environment.rotationXDegrees },
                            set: { value in library.updateSelectedEnvironment { $0.environment.rotationXDegrees = value } }
                        ), format: .number)
                        TextField("Rotación Y (°)", value: Binding(
                            get: { profile.environment.rotationYDegrees },
                            set: { value in library.updateSelectedEnvironment { $0.environment.rotationYDegrees = value } }
                        ), format: .number)
                    }
                }.formStyle(.grouped).disabled(library.selectedEnvironmentItem?.isLocked == true)
            } else {
                ContentUnavailableView("Sin entorno", systemImage: "globe")
            }
        }
    }

    private var coverGlassLibrary: some View {
        VSplitView {
            VStack(spacing: 0) {
                List(selection: $library.selectedCoverGlassID) {
                    ForEach(library.document.coverGlasses) { cover in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(cover.name)
                                Spacer()
                                if cover.isLocked { Image(systemName: "lock.fill") }
                            }
                            Text(cover.authority.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(cover.id)
                    }
                }
                HStack {
                    Button(action: library.addCoverGlass) { Image(systemName: "plus") }
                        .help("Crear Cover Glass global")
                    Button(action: library.duplicateSelectedCoverGlass) {
                        Image(systemName: "plus.square.on.square")
                    }
                    .disabled(library.selectedCoverGlassID == nil)
                    .help("Duplicar Cover Glass")
                    Button(action: library.unlockSelectedCoverGlass) {
                        Image(systemName: "lock.open")
                    }
                    .disabled(library.selectedCoverGlassItem?.isLocked != true)
                    .help("Desbloquear Cover Glass")
                    Button { pendingLibraryDeletion = .coverGlass } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(library.selectedCoverGlassItem?.isLocked != false)
                    .help("Eliminar Cover Glass")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(maxWidth: .infinity, minHeight: 160, idealHeight: 240)

            if let cover = library.selectedCoverGlass {
                coverGlassEditor(cover)
                    .disabled(library.selectedCoverGlassItem?.isLocked == true)
            } else {
                ContentUnavailableView(
                    "Sin Cover Glass",
                    systemImage: "square.3.layers.3d"
                )
            }
        }
    }

    private func coverGlassEditor(_ cover: CoverGlassDefinition) -> some View {
        Form {
            Section("Identidad") {
                TextField("Nombre", text: Binding(
                    get: { cover.name },
                    set: { value in
                        library.updateSelectedCoverGlass { $0.name = value }
                    }
                ))
                Picker("Autoridad", selection: Binding(
                    get: { cover.authority },
                    set: { value in
                        library.updateSelectedCoverGlass { $0.authority = value }
                    }
                )) {
                    ForEach(CoverGlassAuthority.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                LabeledContent("ID estable", value: cover.id)
                    .textSelection(.enabled)
            }
            Section("Óptica") {
                coverGlassField("Cantidad", value: cover.characterStrength) {
                    $0.characterStrength = $1
                }
                coverGlassField("Espesor (mm)", value: cover.thicknessMillimeters) {
                    $0.thicknessMillimeters = $1
                }
                coverGlassField("Índice de refracción", value: cover.refractiveIndex) {
                    $0.refractiveIndex = $1
                }
                coverGlassField("Eficiencia antirreflejo", value: cover.antiReflectiveEfficiency) {
                    $0.antiReflectiveEfficiency = $1
                }
                coverGlassField("Rugosidad", value: cover.roughness) {
                    $0.roughness = $1
                }
                coverGlassField("Haze", value: cover.haze) {
                    $0.haze = $1
                }
            }
            Section("Microtextura antirreflejos") {
                coverGlassField(
                    "Cantidad",
                    value: cover.agMicrotextureCharacterStrength
                ) {
                    $0.agMicrotextureCharacterStrength = $1
                }
                coverGlassField("Pendiente RMS", value: cover.agMicrotextureRMSSlope) {
                    $0.agMicrotextureRMSSlope = $1
                }
                coverGlassField(
                    "Longitud de correlación (µm)",
                    value: cover.agMicrotextureCorrelationLengthMicrometers
                ) {
                    $0.agMicrotextureCorrelationLengthMicrometers = $1
                }
                coverGlassField("Anisotropía", value: cover.agMicrotextureAnisotropy) {
                    $0.agMicrotextureAnisotropy = $1
                }
                TextField("Semilla", value: Binding(
                    get: { cover.agMicrotextureSeed },
                    set: { value in
                        library.updateSelectedCoverGlass { $0.agMicrotextureSeed = value }
                    }
                ), format: .number.grouping(.never))
            }
            Section("Resplandor de emisión") {
                coverGlassField("Intensidad", value: cover.glowCharacterStrength) {
                    $0.glowCharacterStrength = $1
                }
                coverGlassField("Ganancia del halo", value: cover.glowIntensity) {
                    $0.glowIntensity = $1
                }
                coverGlassField("Radio y suavidad (mm)", value: cover.glowRadiusMillimeters) {
                    $0.glowRadiusMillimeters = $1
                }
                coverGlassField("Umbral relativo", value: cover.glowThresholdRelativeWhite) {
                    $0.glowThresholdRelativeWhite = $1
                }
            }
            Section("Absorción por milímetro") {
                ForEach(Array(["R", "G", "B"].enumerated()), id: \.offset) { channel in
                    TextField(channel.element, value: Binding(
                        get: { cover.absorptionPerMillimeter[channel.offset] },
                        set: { value in
                            library.updateSelectedCoverGlass {
                                $0.absorptionPerMillimeter[channel.offset] = value
                            }
                        }
                    ), format: .number)
                }
            }
            if let validation = library.coverGlassValidationMessage {
                Section("Validación") {
                    Text(validation).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.visible, axes: .vertical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func coverGlassField(
        _ label: String,
        value: Double,
        update: @escaping (inout CoverGlassDefinition, Double) -> Void
    ) -> some View {
        TextField(label, value: Binding(
            get: { value },
            set: { newValue in
                library.updateSelectedCoverGlass { update(&$0, newValue) }
            }
        ), format: .number)
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
            case .vfxLog:
                preset.peakNits = 0
                preset.display = nil
                preset.view = nil
                preset.format = .proRes4444XQ
                preset.pixelEncoding = .yuv44412
                preset.signalRange = .video
                preset.alpha = .straight
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
                TextField("Resolución nativa — ancho (px)", value: Binding(
                    get: { device.nativeWidth },
                    set: { value in library.updateSelectedDevice { $0.nativeWidth = value } }
                ), format: .number)
                TextField("Resolución nativa — alto (px)", value: Binding(
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
                TextField("Corner Radius (mm)", value: Binding(
                    get: { device.cornerRadiusMeters * 1_000 },
                    set: { value in
                        library.updateSelectedDevice { $0.cornerRadiusMeters = value / 1_000 }
                    }
                ), format: .number.precision(.fractionLength(2)))
                LabeledContent("Diagonal", value: "\(device.diagonalInches.formatted(.number.precision(.fractionLength(1)))) in")
                LabeledContent("PPI", value: device.pixelsPerInch.formatted(.number.precision(.fractionLength(1))))
                LabeledContent("Pixel pitch", value: "\(device.pixelPitchMicrometers.formatted(.number.precision(.fractionLength(1)))) µm")
            }

            Section("Panel y emisión") {
                Picker("Color Mode", selection: Binding(
                    get: { device.colorModeID },
                    set: { value in library.updateSelectedDevice { $0.colorModeID = value } }
                )) {
                    ForEach(library.colorModes(for: device)) {
                        Text($0.label).tag($0.id)
                    }
                }
                ForEach(library.authorableColorModes) { mode in
                    Toggle("Admite \(mode.label)", isOn: Binding(
                        get: { device.colorModeIDs.contains(mode.id) },
                        set: { enabled in
                            library.updateSelectedDevice { candidate in
                                if enabled {
                                    candidate.colorModeIDs.append(mode.id)
                                } else {
                                    candidate.colorModeIDs.removeAll { $0 == mode.id }
                                }
                            }
                        }
                    ))
                    .disabled(device.colorModeID == mode.id)
                }
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
                TextField("White Luminance mínima (cd/m²)", value: Binding(
                    get: { device.minimumWhiteLuminance },
                    set: { value in
                        library.updateSelectedDevice { $0.minimumWhiteLuminance = value }
                    }
                ), format: .number)
                TextField("White Luminance máxima (cd/m²)", value: Binding(
                    get: { device.maximumWhiteLuminance },
                    set: { value in
                        library.updateSelectedDevice { $0.maximumWhiteLuminance = value }
                    }
                ), format: .number)
                TextField("Paso White Luminance (cd/m²)", value: Binding(
                    get: { device.whiteLuminanceStep },
                    set: { value in
                        library.updateSelectedDevice { $0.whiteLuminanceStep = value }
                    }
                ), format: .number)
                TextField("White Luminance (cd/m²)", value: Binding(
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
                Picker("Cover Glass predeterminado", selection: Binding(
                    get: { device.defaultCoverGlassPresetID },
                    set: { value in
                        library.updateSelectedDevice {
                            $0.defaultCoverGlassPresetID = value
                        }
                    }
                )) {
                    ForEach(library.document.coverGlasses) { cover in
                        Text(cover.name).tag(cover.id)
                    }
                }
            }

            if let validation = library.deviceValidationMessage {
                Section("Validación") {
                    Text(validation).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.visible, axes: .vertical)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        library.selectedImageItem?.value
    }

    private var selectedGlobalPreset: StudioRenderPreset? {
        library.allRenderPresets.first { $0.id == library.selectedPresetID }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                sidebarIsVisible.toggle()
            } label: {
                Label(
                    sidebarIsVisible ? "Ocultar barra lateral" : "Mostrar barra lateral",
                    systemImage: "sidebar.left"
                )
            }
            .nativeActionState(.init(active: sidebarIsVisible))
            .help(sidebarIsVisible ? "Ocultar panel izquierdo" : "Mostrar panel izquierdo")
        }
        ToolbarItemGroup {
            Button("Abrir", action: model.openMedia)
                .disabled(page == .settings)
                .help("Abrir un vídeo o una imagen")
            Button {
                trackingScenePanel.toggle(model: model)
            } label: {
                Label("Tracking 3D", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .nativeActionState(.init(
                available: page != .settings,
                active: trackingScenePanel.isVisible
            ))
            .help("Importar cámara, point cloud, geometrías y lente desde Fusion")
            Button("Frame", action: model.renderCurrentFrame)
                .disabled(page != .main || model.metalFrame == nil)
                .help("Renderizar el frame actual horneando la transformación del visor")
            Button("Render", action: model.runQueue)
                .disabled(page != .main || !model.jobs.contains { $0.state == .pending })
                .help("Procesar los trabajos en cola")
        }
    }

    private var sceneLibraryPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Escenas", systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                Button {
                    trackingScenePanel.toggle(model: model)
                } label: {
                    Label("Tracking 3D", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .controlSize(.small)
                .nativeActionState(.init(
                    available: page != .settings,
                    active: trackingScenePanel.isVisible
                ))
                .help("Importar cámara, point cloud, geometrías y lente desde Fusion")
                Button {
                    saveNewScene()
                } label: {
                    Label("Guardar escena", systemImage: "plus.square.on.square")
                        .labelStyle(.iconOnly)
                }
                .disabled(model.metalFrame == nil || scenes.blockedError != nil)
                .help("Guardar la escena completa activa")
                Button {
                    do {
                        guard let target = try scenes.deletedAutosaveHistoryTargets().first else {
                            model.errorMessage = "No hay escenas eliminadas recuperables."
                            return
                        }
                        autosaveHistoryTarget = target
                    } catch { model.errorMessage = error.localizedDescription }
                } label: {
                    Label("Recuperar escena eliminada", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.iconOnly)
                }
                .disabled(scenes.blockedError != nil)
                .help("Recuperar autosaves de una escena eliminada")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            if let blocked = scenes.blockedError {
                ContentUnavailableView(
                    "Biblioteca bloqueada",
                    systemImage: "exclamationmark.lock",
                    description: Text(blocked)
                )
            } else if scenes.document.scenes.isEmpty {
                ContentUnavailableView(
                    "Sin escenas",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Guarda el estado activo con el botón +.")
                )
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(scenes.document.scenes) { scene in
                            SceneLibraryItemView(
                                scene: scene,
                                thumbnailURL: scenes.thumbnailURL(for: scene),
                                onRename: { name in
                                    do { try scenes.rename(scene, to: name) }
                                    catch { model.errorMessage = error.localizedDescription }
                                },
                                onOpen: { requestSceneAction(.open, scene: scene) },
                                onUpdate: { requestSceneAction(.update, scene: scene) },
                                onDuplicate: {
                                    do { _ = try scenes.duplicate(scene) }
                                    catch { model.errorMessage = error.localizedDescription }
                                },
                                onRender: { requestSceneRender(scene) },
                                onHistory: { autosaveHistoryTarget = scenes.autosaveHistoryTarget(for: scene) },
                                onDelete: { requestSceneAction(.delete, scene: scene) }
                            )
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sceneConfirmationTitle: String {
        guard let action = pendingSceneAction, let scene = pendingScene else { return "Escena" }
        return switch action {
        case .open: "¿Abrir ‘\(scene.name)’?"
        case .update: "¿Actualizar ‘\(scene.name)’?"
        case .renderAfterUpdate: "¿Actualizar ‘\(scene.name)’ antes de renderizar?"
        case .delete: "¿Eliminar ‘\(scene.name)’?"
        }
    }

    private func sceneConfirmationButton(_ action: PendingSceneAction) -> String {
        switch action {
        case .open: "Abrir escena"
        case .update: "Actualizar escena"
        case .renderAfterUpdate: "Actualizar y añadir a cola"
        case .delete: "Eliminar escena"
        }
    }

    private func requestSceneAction(_ action: PendingSceneAction, scene: SavedScene) {
        pendingScene = scene
        pendingSceneAction = action
    }

    private func requestSceneRender(_ scene: SavedScene) {
        model.renderJobName = scene.name
        do {
            if try model.savedSceneNeedsUpdate(scene) {
                requestSceneAction(.renderAfterUpdate, scene: scene)
            } else {
                model.ensureRenderOptionsCompatible()
                pendingRenderScene = scene
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func saveNewScene() {
        do {
            let capture = try model.captureSavedScene()
            let scene = try scenes.add(capture: capture)
            model.markActiveScene(scene.id)
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func performConfirmedSceneAction(_ action: PendingSceneAction, scene: SavedScene) {
        pendingSceneAction = nil
        pendingScene = nil
        switch action {
        case .open:
            Task { await model.openSavedScene(scene, undoManager: undoManager) }
        case .update:
            do {
                let capture = try model.captureSavedScene()
                try scenes.update(scene, capture: capture, undoManager: undoManager)
                model.markActiveScene(scene.id)
            } catch { model.errorMessage = error.localizedDescription }
        case .renderAfterUpdate:
            do {
                let capture = try model.captureSavedScene()
                try scenes.update(scene, capture: capture, undoManager: undoManager)
                model.markActiveScene(scene.id)
                guard let updated = scenes.scene(id: scene.id) else {
                    throw SceneLibraryError.inaccessible("La escena actualizada no existe.")
                }
                model.ensureRenderOptionsCompatible()
                pendingRenderScene = updated
            } catch { model.errorMessage = error.localizedDescription }
        case .delete:
            do { try scenes.delete(scene) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func renderOptionsSheet(_ scene: SavedScene) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Opciones de render")
                        .font(.headline)
                    Text(scene.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            Divider()
            Form {
                Section("Salida") {
                    Picker("Tipo de salida", selection: $model.renderOutputType) {
                        ForEach(StudioOutputType.allCases) { type in
                            Text(type.label).tag(type)
                        }
                    }
                    TextField("Nombre del trabajo", text: $model.renderJobName)
                    if model.renderOutputType == .standard {
                    Picker("Preset", selection: Binding(
                        get: { model.renderPreset },
                        set: { model.applyRenderPreset($0) }
                    )) {
                        ForEach(library.allRenderPresets) { preset in
                            Text(preset.name).tag(preset)
                        }
                    }
                    Picker("Formato", selection: Binding(
                        get: { model.outputFormat },
                        set: { model.changeOutputFormat($0) }
                    )) {
                        ForEach(StudioOutputFormat.allCases.filter {
                            $0.supports(target: model.renderPreset.target)
                        }) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    if model.renderPreset.target == .vfxLog {
                        Picker("Log / Gamut VFX", selection: $model.vfxInterchangeEncodingID) {
                            ForEach(StudioVFXInterchangeEncoding.catalog) { encoding in
                                Text(encoding.label).tag(encoding.id)
                            }
                        }
                        if let recommendation = model.recommendedVFXInterchangeEncoding {
                            HStack {
                                Text("Sugerido por cámara: \(recommendation.label)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Usar sugerido") {
                                    model.vfxInterchangeEncodingID = recommendation.id
                                }
                            }
                        }
                    }
                    Picker("Composición", selection: $model.renderComposition) {
                        ForEach(StudioRenderComposition.allCases) { composition in
                            Text(composition.label).tag(composition)
                        }
                    }
                    } else {
                        Picker("DOF", selection: $model.fusionDOFMode) {
                            ForEach(StudioFusionDOFMode.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Resolución", selection: $model.fusionResolutionMode) {
                            ForEach(StudioFusionResolutionMode.allCases) { Text($0.label).tag($0) }
                        }
                        if model.fusionResolutionMode == .custom {
                            LabeledContent("Ancho activo") {
                                TextField("px", value: $model.fusionCustomWidth, format: .number)
                                    .frame(width: 90)
                            }
                            LabeledContent("Alto activo") {
                                TextField("px", value: $model.fusionCustomHeight, format: .number)
                                    .frame(width: 90)
                            }
                        }
                        LabeledContent("Threshold ACEScg lineal") {
                            TextField("threshold", value: $model.fusionSpillThresholdSceneLinear, format: .number)
                                .frame(width: 110)
                        }
                        LabeledContent("Fade de spill") {
                            TextField("px", value: $model.fusionSpillFadeWidthPixels, format: .number)
                                .frame(width: 90)
                        }
                        Text("OpenEXR RGBA half-float ACEScg lineal. Perspectiva, distorsión SynthEyes DE4 y motion blur se reconstruyen en Fusion.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Rango", selection: $model.renderRange) {
                        Text("Todo").tag(StudioRenderRange.all)
                        Text("IN / OUT").tag(StudioRenderRange.inOut)
                    }
                    if model.renderRange == .inOut {
                        LabeledContent("IN") {
                            TextField("IN", value: $model.inFrame, format: .number)
                                .frame(width: 90)
                        }
                        LabeledContent("OUT") {
                            TextField("OUT", value: $model.outFrame, format: .number)
                                .frame(width: 90)
                        }
                    }
                }
                Section("Movimiento") {
                    if model.renderOutputType == .standard {
                    Toggle("Desenfoque de movimiento", isOn: $model.renderMotionBlurEnabled)
                    LabeledContent("Muestras temporales") {
                        Stepper(
                            value: $model.renderMotionSamples,
                            in: 2...64,
                            step: 1
                        ) {
                            Text("\(model.renderMotionSamples)")
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    .disabled(!model.renderMotionBlurEnabled)
                    Text("Integra cámara, Device y emisión durante el intervalo físico de obturación. No aplica un blur 2D posterior.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("El motion blur no se hornea en los EXR; Fusion recibe el shutter y las curvas animadas de cámara.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Codificación") {
                    if model.renderOutputType == .standard {
                    LabeledContent("Píxel", value: model.outputPixelEncoding.label)
                    Picker("Rango de señal", selection: $model.outputSignalRange) {
                        ForEach(StudioSignalRange.allCases) { range in
                            Text(range.label).tag(range)
                                .disabled(!model.outputFormat.supportedSignalRanges(
                                    for: model.outputPixelEncoding
                                ).contains(range))
                        }
                    }
                    Picker("Alpha", selection: $model.outputAlphaMode) {
                        ForEach(StudioAlphaMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .disabled(!model.outputFormat.supportsAlpha)
                    Toggle("Audio", isOn: $model.includeAudio)
                        .disabled(!model.outputFormat.isMovie)
                    } else {
                        LabeledContent("Píxel", value: "RGBA float16")
                        LabeledContent("Espacio", value: "ACEScg scene-linear")
                        LabeledContent("Alpha", value: "Matte de oclusión independiente")
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancelar") { pendingRenderScene = nil }
                Spacer()
                Button("Elegir destino y añadir") {
                    pendingRenderScene = nil
                    DispatchQueue.main.async {
                        model.enqueueSavedScene(scene)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 610)
    }

    private var testSetupPanel: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let presentation = model.testPresentation {
                    TestAuthoringView(
                        state: presentation,
                        excludedControlIDs: ["device", "color-mode", "white-luminance"],
                        showsInspectorGroups: false,
                        expandedCardIDs: $expandedTestInspectorCards,
                        onScalarEditingChanged: { controlID, editing in
                            if editing {
                                model.beginSceneControlEdit(controlID)
                            } else {
                                model.endSceneControlEdit(
                                    controlID, undoManager: undoManager
                                )
                            }
                        },
                        onIntent: { model.handleTestIntent($0, undoManager: undoManager) }
                    )
                    TestPhaseCard(
                        label: "Referencia",
                        identifier: "reference",
                        expandedCardIDs: $expandedTestInspectorCards
                    ) {
                        referenceAuthoringControls
                    }
                    TestAuthoringView(
                        state: presentation,
                        excludedControlIDs: ["device", "color-mode", "white-luminance"],
                        showsGeneral: false,
                        supplementarySectionContent: testInspectorSupplements,
                        expandedCardIDs: $expandedTestInspectorCards,
                        onScalarEditingChanged: { controlID, editing in
                            if editing {
                                model.beginSceneControlEdit(controlID)
                            } else {
                                model.endSceneControlEdit(
                                    controlID, undoManager: undoManager
                                )
                            }
                        },
                        onIntent: { model.handleTestIntent($0, undoManager: undoManager) }
                    )
                } else {
                    ContentUnavailableView(
                        "Esperando descriptor de fase",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text(
                            "Application/Rust debe publicar las fases y controles antes de autorizar su edición."
                        )
                    )
                }
            }
            .padding(12)
        }
    }

    private var testInspectorSupplements: [String: AnyView] {
        var result: [String: AnyView] = [
            "device.source-adjustment": AnyView(originAuthoringControls),
            "device.emission": AnyView(sceneDeviceControls),
        ]
        if !model.environmentSourceEvidence.isEmpty {
            result["environment.main"] = AnyView(
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.environmentSourceEvidence, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            )
        }
        return result
    }

    @ViewBuilder
    private var sceneDeviceControls: some View {
        let selected = model.modelDeviceDefinition
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            originRow("Device") {
                Picker("Device", selection: Binding(
                    get: { selected?.id ?? "" },
                    set: { id in
                        guard let item = library.document.devices.first(where: { $0.id == id }),
                              let cover = library.document.coverGlasses.first(where: {
                                  $0.id == item.value.defaultCoverGlassPresetID
                              })
                        else { return }
                        library.selectedDeviceID = id
                        model.selectModelDevice(
                            item.value,
                            coverGlass: cover.value,
                            undoManager: undoManager
                        )
                    }
                )) {
                    ForEach(library.document.devices) { item in
                        Text(item.name).tag(item.id)
                    }
                }
                .labelsHidden()
            }
            if let selected {
                originRow("Color Mode") {
                    Picker("Color Mode", selection: Binding(
                        get: { selected.colorModeID },
                        set: { id in
                            model.handleTestIntent(.setChoice(
                                controlID: "color-mode", optionID: id
                            ), undoManager: undoManager)
                        }
                    )) {
                        ForEach(selected.colorModeIDs, id: \.self) { id in
                            Text(StudioColorMode.catalog.first(where: { $0.id == id })?.label ?? id)
                                .tag(id)
                        }
                    }
                    .labelsHidden()
                }
                originRow("Luminancia blanca") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { selected.whiteLevelNits },
                                set: { value in
                                    model.handleTestIntent(.setScalar(
                                        controlID: "white-luminance", value: value
                                    ), undoManager: undoManager)
                                }
                            ),
                            in: selected.minimumWhiteLuminance...selected.maximumWhiteLuminance,
                            step: selected.whiteLuminanceStep,
                            onEditingChanged: { editing in
                                if editing {
                                    model.beginSceneControlEdit("white-luminance")
                                } else {
                                    model.endSceneControlEdit(
                                        "white-luminance", undoManager: undoManager
                                    )
                                }
                            }
                        )
                        TextField("cd/m²", value: Binding(
                            get: { selected.whiteLevelNits },
                            set: { value in
                                model.handleTestIntent(.setScalar(
                                    controlID: "white-luminance", value: value
                                ), undoManager: undoManager)
                            }
                        ), format: .number)
                        .frame(width: 72)
                        Text("cd/m²").foregroundStyle(.secondary)
                    }
                }
                originRow("Resolución nativa") {
                    Text("\(selected.nativeWidth)×\(selected.nativeHeight) px")
                }
                originRow("Densidad") {
                    Text("\(selected.pixelsPerInch.formatted(.number.precision(.fractionLength(1)))) ppi")
                }
            }
        }
    }

    @ViewBuilder
    private var originAuthoringControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fuente")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                originRow("Tipo") { Text(model.sourceKindLabel) }
                originRow("Fuente actual") { Text(model.sourceName).lineLimit(1) }
                originRow("Detalle") { Text(model.sourceDetail).lineLimit(2) }
                originRow("Tiempo (s)") {
                    TextField("0", value: Binding(
                        get: { model.requestedSeconds },
                        set: { model.requestedSeconds = $0 }
                    ), format: .number)
                    .accessibilityLabel("Tiempo solicitado en segundos")
                }
                originRow("") {
                    HStack(spacing: 8) {
                        Button("Abrir archivo o secuencia…", action: model.openMedia)
                        if model.hasExternalSourceMedia {
                            Button("Quitar", action: model.removeExternalSourceMedia)
                        }
                    }
                }
                originRow("Patrón sintético") {
                    Picker("Patrón sintético", selection: Binding(
                        get: {
                            if let selected = library.selectedPatternItem,
                               selected.pattern == model.selectedPattern {
                                return selected.id
                            }
                            return library.document.patterns.first {
                                $0.pattern == model.selectedPattern
                            }?.id ?? ""
                        },
                        set: { id in
                            guard let item = library.document.patterns.first(
                                where: { $0.id == id }
                            ) else { return }
                            library.selectedPatternID = id
                            model.choosePattern(item.pattern, undoManager: undoManager)
                        }
                    )) {
                        ForEach(library.document.patterns) {
                            Text($0.name).tag($0.id)
                        }
                    }
                    .labelsHidden()
                }
            }
            Divider()
            Text("Interpretación de entrada")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                inputInterpretationControls
            }
            Divider()
            Text("Working space")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                originRow("Espacio") { Text("ACEScg lineal") }
                originRow("Alpha") { Text("Premultiplicado") }
                originRow("Rango") { Text("Negativos y >1 preservados") }
            }
        }
    }

    private func originRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GridRow {
            Text(label).frame(width: 122, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: 52)
        }
    }

    @ViewBuilder
    private var inputInterpretationControls: some View {
        originRow("Input Transform") {
            Picker("Input Transform", selection: Binding(
                get: { model.inputTransform },
                set: { model.changeInput($0, undoManager: undoManager) }
            )) {
                ForEach(StudioColorInputTransform.catalog) { value in
                    interpretationLabel(value.label, annotation: model.inputAnnotation(value))
                        .tag(value)
                }
            }
            .labelsHidden()
        }
        originRow("Alpha") {
            Picker("Alpha", selection: Binding(
                get: { model.alphaMode },
                set: { model.changeAlpha($0, undoManager: undoManager) }
            )) {
                ForEach(StudioAlphaMode.allCases) { value in
                    interpretationLabel(value.label, annotation: model.alphaAnnotation(value))
                        .tag(value)
                }
            }
            .labelsHidden()
        }
        originRow("Modelo de señal") {
            Picker("Modelo de señal", selection: Binding(
                get: { model.signalColorModel }, set: { model.changeColorModel($0) }
            )) {
                ForEach(StudioSignalColorModel.allCases) { value in
                    interpretationLabel(
                        value.label, annotation: model.colorModelAnnotation(value)
                    ).tag(value)
                }
            }
            .labelsHidden()
        }
        originRow("Matriz YUV") {
            Picker("Matriz YUV", selection: Binding(
                get: { model.signalMatrix }, set: { model.changeMatrix($0) }
            )) {
                ForEach(StudioSignalMatrix.allCases) { value in
                    interpretationLabel(value.label, annotation: model.matrixAnnotation(value))
                        .tag(value)
                }
            }
            .labelsHidden()
        }
        originRow("Rango señal") {
            Picker("Rango señal", selection: Binding(
                get: { model.signalRange }, set: { model.changeRange($0) }
            )) {
                ForEach(StudioSignalRange.allCases) { value in
                    interpretationLabel(value.label, annotation: model.rangeAnnotation(value))
                        .tag(value)
                }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var referenceAuthoringControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                originRow("Plate de composición") {
                    Picker("Plate de composición", selection: Binding(
                        get: { model.referencePlate },
                        set: { model.changeReferencePlate($0) }
                    )) {
                        ForEach(WorkspaceModel.ReferencePlate.allCases) { plate in
                            Text(plate.label).tag(plate)
                                .disabled(plate == .videoReference
                                    && model.referenceFrameName == nil)
                        }
                    }
                    .labelsHidden()
                }
                originRow("Medio") {
                    Text(model.referenceFrameName ?? "Sin referencia").lineLimit(1)
                }
                if let detail = model.referenceFrameDetail {
                    originRow("Detalle") { Text(detail).lineLimit(2) }
                }
                originRow("") {
                    HStack {
                        Button("Seleccionar imagen o vídeo…", action: model.browseReferenceFrame)
                        if model.referenceFrameName != nil {
                            Button("Quitar", role: .destructive) {
                                referenceMatchPanel.hide(model: model)
                                model.removeReferenceFrame()
                            }
                        }
                    }
                }
            }
            if model.referenceFrameName != nil {
                Divider()
                Text("Interpretación de entrada")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    originRow("Input Transform") {
                        Picker("Input Transform", selection: Binding(
                            get: { model.referenceInputTransform },
                            set: { model.changeReferenceInput($0, undoManager: undoManager) }
                        )) {
                            ForEach(StudioColorInputTransform.catalog) { value in
                                Text(value.label).tag(value)
                            }
                        }
                        .labelsHidden()
                    }
                    originRow("Alpha") {
                        Picker("Alpha", selection: Binding(
                            get: { model.referenceAlphaMode },
                            set: { model.changeReferenceAlpha($0) }
                        )) {
                            ForEach(StudioAlphaMode.allCases) { value in
                                Text(value.label).tag(value)
                            }
                        }
                        .labelsHidden()
                    }
                    originRow("Modelo de señal") {
                        Picker("Modelo de señal", selection: Binding(
                            get: { model.referenceSignalColorModel },
                            set: { model.changeReferenceColorModel($0) }
                        )) {
                            ForEach(StudioSignalColorModel.allCases) { value in
                                Text(value.label).tag(value)
                            }
                        }
                        .labelsHidden()
                    }
                    originRow("Matriz YUV") {
                        Picker("Matriz YUV", selection: Binding(
                            get: { model.referenceSignalMatrix },
                            set: { model.changeReferenceMatrix($0) }
                        )) {
                            ForEach(StudioSignalMatrix.allCases) { value in
                                Text(value.label).tag(value)
                            }
                        }
                        .labelsHidden()
                    }
                    originRow("Rango señal") {
                        Picker("Rango señal", selection: Binding(
                            get: { model.referenceSignalRange },
                            set: { model.changeReferenceRange($0) }
                        )) {
                            ForEach(StudioSignalRange.allCases) { value in
                                Text(value.label).tag(value)
                            }
                        }
                        .labelsHidden()
                    }
                }
                Divider()
                Text("Working space")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    originRow("Espacio") { Text("ACEScg lineal") }
                    originRow("Alpha") { Text("Premultiplicado") }
                    originRow("Rango") { Text("Negativos y >1 preservados") }
                }
                Divider()
                Text("Colocación en Raster de entrega")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    originRow("Escalado") {
                        Picker("Escalado", selection: Binding(
                            get: { model.referencePlacement },
                            set: { model.changeReferencePlacement($0) }
                        )) {
                            ForEach(WorkspaceModel.SourcePlacement.allCases) { value in
                                Text(value.rawValue).tag(value)
                            }
                        }
                        .labelsHidden()
                    }
                    originRow("Match") {
                        Button {
                            referenceMatchPanel.toggle(model: model, undoManager: undoManager)
                        } label: {
                            Label(
                                referenceMatchPanel.isVisible ? "Ocultar Match" : "Abrir Match",
                                systemImage: referenceMatchPanel.isVisible
                                    ? "viewfinder.circle.fill" : "viewfinder.circle"
                            )
                        }
                        .nativeActionState(.init(active: referenceMatchPanel.isVisible))
                    }
                }
            }
        }
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
                LabeledContent(
                    "ODT del preset",
                    value: model.renderPreset.target == .vfxLog
                        ? "Sin ODT de display"
                        : (model.renderPreset.view ?? model.renderPreset.target.rawValue)
                )
                LabeledContent(
                    "Transformación efectiva",
                    value: model.renderPreset.target == .vfxLog
                        ? (model.selectedVFXInterchangeEncoding?.label ?? "Selección inválida")
                        : (model.renderPreset.view ?? model.renderPreset.target.rawValue)
                )
                if model.renderPreset.target != .vfxLog {
                    LabeledContent("Peak nits") {
                        TextField("nits", value: $model.peakNits, format: .number).frame(width: 90)
                    }
                }
                Picker("Formato", selection: Binding(
                    get: { model.outputFormat },
                    set: { model.changeOutputFormat($0) }
                )) {
                    ForEach(StudioOutputFormat.allCases.filter {
                        $0.supports(target: model.renderPreset.target)
                    }) { Text($0.displayName).tag($0) }
                }
                if model.renderPreset.target == .vfxLog {
                    Picker("Log / Gamut VFX", selection: $model.vfxInterchangeEncodingID) {
                        ForEach(StudioVFXInterchangeEncoding.catalog) { encoding in
                            Text(encoding.label).tag(encoding.id)
                        }
                    }
                    if let recommendation = model.recommendedVFXInterchangeEncoding {
                        Button("Usar sugerido · \(recommendation.label)") {
                            model.vfxInterchangeEncodingID = recommendation.id
                        }
                    }
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
                Picker("Composición", selection: $model.renderComposition) {
                    ForEach(StudioRenderComposition.allCases) { composition in
                        Text(composition.label).tag(composition)
                    }
                }
                Toggle("Desenfoque de movimiento", isOn: $model.renderMotionBlurEnabled)
                Stepper(
                    "Muestras temporales · \(model.renderMotionSamples)",
                    value: $model.renderMotionSamples,
                    in: 2...64
                )
                .disabled(!model.renderMotionBlurEnabled)
                Picker("Alpha", selection: $model.outputAlphaMode) {
                    ForEach(StudioAlphaMode.allCases) { Text($0.label).tag($0) }
                }
                    .disabled(!model.outputFormat.supportsAlpha)
                Toggle("Audio", isOn: $model.includeAudio)
                    .disabled(!model.outputFormat.isMovie)
            }
            Section("Exportación") {
                Text("Añade el render desde el menú contextual de una escena guardada. La cola conservará exactamente ese snapshot.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text(job.scene.name).font(.caption).foregroundStyle(.secondary)
                    Text("\(job.configuration.firstFrame)–\(job.configuration.lastFrame) · \(job.configuration.pixelEncoding.label) · \(job.configuration.signalRange.label) · \(job.detail)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .contextMenu {
                    if [.pending, .failed, .completed].contains(job.state) {
                        Button("Eliminar de la cola", role: .destructive) {
                            model.removeInactiveRender(job)
                        }
                    }
                    if job.state == .completed {
                        Button("Mostrar directorio en Finder") {
                            model.showRenderDestinationInFinder(job)
                        }
                        if job.configuration.outputType == .fusionScenePackage {
                            Button("Actualizar comp Fusion") {
                                model.refreshFusionComposition(job)
                            }
                        }
                        Button("Volver a renderizar") {
                            model.requeueCompletedRender(job)
                        }
                    }
                }
            }
            HStack {
                if model.jobs.contains(where: { $0.state == .rendering }) {
                    Button("Cancelar", action: model.cancelRender)
                }
                if model.outputQueue.isPaused {
                    Button("Reanudar", action: model.runQueue)
                } else if model.jobs.contains(where: { $0.state == .pending || $0.state == .rendering }) {
                    Button("Pausa", action: model.pauseRenderQueue)
                }
                Button("Limpiar terminados", action: model.clearCompletedAndFailedRenders)
                    .disabled(!model.jobs.contains {
                        $0.state == .completed || $0.state == .failed
                    })
                Spacer()
                Button("Render Queue", action: model.runQueue)
                    .disabled(!model.outputQueue.isPaused && !model.jobs.contains { $0.state == .pending })
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

    private func preview(showTestPhasePicker: Bool = false) -> some View {
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
                if showTestPhasePicker, let presentation = model.testPresentation {
                    TestPreviewControls(
                        state: presentation,
                        onIntent: { model.handleTestIntent($0, undoManager: undoManager) }
                    )
                    .frame(maxWidth: 150)
                    NativeRenderButton(
                        state: model.testNativeRenderButtonState,
                        action: model.performNativeRenderButtonAction
                    )
                    if model.physicalModel.quality == .environmentSetup {
                        Button {
                            referenceMatchPanel.hide(model: model)
                            environmentReflectionFramingPanel.hide(model: model)
                            reflectionEnvironmentPanel.toggle(model: model)
                        } label: {
                            Image(systemName: reflectionEnvironmentPanel.isVisible
                                ? "lightbulb.max.fill" : "lightbulb.max")
                        }
                        .nativeActionState(.init(active: reflectionEnvironmentPanel.isVisible))
                        .help(reflectionEnvironmentPanel.isVisible
                            ? "Ocultar creación de reflejos" : "Crear reflejos")
                        Button {
                            referenceMatchPanel.hide(model: model)
                            reflectionEnvironmentPanel.hide(model: model)
                            environmentReflectionFramingPanel.toggle(model: model)
                        } label: {
                            Image(systemName: "viewfinder")
                        }
                        .nativeActionState(.init(
                            available: model.environmentSourceName != nil,
                            active: model.environmentReflectionFramingEnabled
                        ))
                        .help("Encuadrar HDRI")
                    }
                }
                Spacer()
                Button {
                    model.monitorOutput.toggle(
                        frame: model.metalFrame,
                        display: model.metalDisplay
                    )
                } label: {
                    previewBarLabel(
                        "Monitor", systemImage: model.monitorOutput.isActive
                            ? "rectangle.connected.to.line.below.fill" : "rectangle.connected.to.line.below"
                    )
                }
                .nativeActionState(.init(
                    available: model.monitorOutput.isAvailable,
                    active: model.monitorOutput.isActive
                ))
                .help(model.monitorOutput.isActive
                    ? "Detener monitorización DeckLink"
                    : "Iniciar monitorización DeckLink")
                .accessibilityLabel(model.monitorOutput.isActive
                    ? "Detener monitorización DeckLink"
                    : "Iniciar monitorización DeckLink")
                Button { model.zoomBy(0.8) } label: {
                    previewBarLabel("Alejar", systemImage: "minus.magnifyingglass")
                }
                .help("Reducir zoom")
                .accessibilityLabel("Reducir zoom")
                CommittedZoomField(
                    percentage: model.zoomPercentage,
                    onCommit: model.setZoomPercentage
                )
                    .frame(width: 52)
                    .accessibilityLabel("Escala del visor en porcentaje")
                Text("%").foregroundStyle(.secondary)
                Button(action: model.fitPreview) {
                    previewBarLabel("Fit", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                    .help("Ajustar imagen al visor")
                Button(action: model.showPreviewOneToOne) {
                    previewBarLabel("1:1", systemImage: "1.magnifyingglass")
                }
                    .help("Un píxel calculado por píxel lógico del visor")
                Button { model.zoomBy(1.25) } label: {
                    previewBarLabel("Acercar", systemImage: "plus.magnifyingglass")
                }
                    .help("Aumentar zoom")
                    .accessibilityLabel("Aumentar zoom")
                Button(action: model.togglePreviewTransformationsLock) {
                    previewBarLabel(
                        "Bloquear", systemImage: model.previewTransformationsLocked
                            ? "lock.fill" : "lock.open"
                    )
                }
                .nativeActionState(.init(active: model.previewTransformationsLocked))
                .help(model.previewTransformationsLocked
                    ? "Desbloquear transformaciones de escena y Device"
                    : "Bloquear transformaciones de escena y Device")
                .accessibilityLabel(model.previewTransformationsLocked
                    ? "Desbloquear transformaciones del Viewer"
                    : "Bloquear transformaciones del Viewer")
                Button(action: model.togglePreviewGizmos) {
                    previewBarLabel(
                        "Gizmos", systemImage: model.previewGizmosVisible ? "eye" : "eye.slash"
                    )
                }
                .nativeActionState(.init(active: model.previewGizmosVisible))
                .help(model.previewGizmosVisible
                    ? "Ocultar todos los gizmos del Viewer"
                    : "Mostrar todos los gizmos del Viewer")
                .accessibilityLabel(model.previewGizmosVisible
                    ? "Ocultar gizmos del Viewer"
                    : "Mostrar gizmos del Viewer")
                Button {
                    model.renderCurrentFrame()
                } label: {
                    previewBarLabel("Guardar", systemImage: "square.and.arrow.down")
                }
                .disabled(model.metalFrame == nil)
                .help("Guardar el fotograma actual")
                .accessibilityLabel("Guardar fotograma actual")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 58)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ZStack {
                Color(nsColor: NSColor(calibratedWhite: 0.18, alpha: 1))
                if let frame = model.metalFrame {
                    let image = MetalPreview(
                        display: model.metalDisplay,
                        frame: frame,
                        output: model.previewTransform,
                        zoom: model.zoom,
                        pan: model.pan,
                        fitted: model.previewIsFitted,
                        metadataLines: model.previewMetadataLines,
                        deviceBoundary: model.previewGizmosVisible && (model.physicalModel.quality == .setup
                                || model.physicalModel.quality == .environmentSetup
                                || model.physicalModel.quality == .focusSetup)
                            ? model.setupDeviceBoundary : [],
                        sensorGateBoundary: model.previewGizmosVisible && (model.physicalModel.quality == .setup
                                || model.physicalModel.quality == .environmentSetup
                                || model.physicalModel.quality == .focusSetup
                                || model.referenceMatchEnabled)
                            ? model.setupSensorGateBoundary : [],
                        focusTarget: model.previewGizmosVisible
                            && model.physicalModel.quality == .focusSetup
                            ? model.focusSetupTarget : nil,
                        focusTargetEnabled: model.previewGizmosVisible
                            && model.physicalModel.quality == .focusSetup
                            && model.focusSetupTargetEnabled,
                        referenceProjectedCorners: model.previewGizmosVisible
                            && model.referenceMatchEnabled
                            ? model.referenceMatchProjectedCorners : [],
                        referenceTargetCorners: model.previewGizmosVisible
                            && model.referenceMatchEnabled
                            ? model.referenceMatchCorners : [],
                        reflectionHandles: model.previewGizmosVisible
                            ? model.selectedReflectionEmitterHandles : [],
                        reflectionSoftnessPixels: model.previewGizmosVisible
                            ? model.selectedReflectionEmitterSoftnessPixels : 0,
                        reflectionShapeClosed: model.previewGizmosVisible
                            && model.selectedReflectionEmitter?.kind == .window,
                        reflectionShapeCircular: model.previewGizmosVisible
                            && model.selectedReflectionEmitter?.kind == .practical,
                        trackingPoints: model.previewGizmosVisible
                            ? model.trackingOverlayPoints : [],
                        trackingPointIDs: model.previewGizmosVisible
                            ? model.trackingOverlayPointIDs : [],
                        trackingSegments: model.previewGizmosVisible
                            ? model.trackingOverlaySegments : [],
                        trackingMeshCenters: model.previewGizmosVisible
                            ? model.trackingOverlayMeshCenters : [],
                        trackingMeshCenterIDs: model.previewGizmosVisible
                            ? model.trackingOverlayMeshCenterIDs : [],
                        trackingMeshCenterLabels: model.previewGizmosVisible
                            ? model.trackingOverlayMeshCenterLabels : [],
                        trackingPointSelectionEnabled: model.previewGizmosVisible
                            && model.trackingScaleSelectionSlot != nil,
                        sceneInteractionLocked: model.previewTransformationsLocked,
                        cameraNavigationEnabled: model.physicalPlacementNavigationEnabled,
                        onDisplayChange: model.publishSystemDisplayInfo,
                        onPanChange: { model.pan = $0 },
                        onZoomChange: model.setInteractiveZoom,
                        onFittedZoomChange: model.updateFittedZoom,
                        onCameraGestureBegin: model.beginCameraNavigation,
                        onCameraGestureChange: model.updateCameraNavigation,
                        onCameraGestureEnd: { model.endCameraNavigation(undoManager: undoManager) },
                        onFocusTargetBegin: model.beginFocusTargetDrag,
                        onFocusTargetChange: model.updateFocusTarget,
                        onFocusTargetEnd: { model.endFocusTargetDrag(undoManager: undoManager) },
                        onReferenceCornerBegin: model.beginReferenceCornerDrag,
                        onReferenceCornerChange: model.updateReferenceCorner,
                        onReferenceCornerEnd: { model.endReferenceCornerDrag(undoManager: undoManager) },
                        onReflectionHandleBegin: model.beginReflectionHandleDrag,
                        onReflectionHandleChange: model.updateReflectionHandle,
                        onReflectionHandleEnd: model.endReflectionHandleDrag,
                        onTrackingPointSelected: model.selectTrackingPoint,
                        onPlaceDeviceAtTrackingPoint: {
                            model.placeDeviceAtTrackingPoint($0, undoManager: undoManager)
                        },
                        onPlaceDeviceOnTrackingPlane: {
                            model.placeDeviceOnTrackingPlane($0, undoManager: undoManager)
                        }
                    )
                    .accessibilityLabel("Preview OCIO del resultado")
                    image
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

    private func previewBarLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
            Text(title).font(.caption2)
        }
        .frame(minWidth: 42)
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
                .nativeActionState(.init(active: model.isPlaying))
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
                .nativeActionState(.init(active: model.loopPlayback))
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
    let fitted: Bool
    let metadataLines: [String]
    let deviceBoundary: [CGPoint]
    let sensorGateBoundary: [CGPoint]
    let focusTarget: CGPoint?
    let focusTargetEnabled: Bool
    let referenceProjectedCorners: [CGPoint]
    let referenceTargetCorners: [CGPoint]
    let reflectionHandles: [CGPoint]
    let reflectionSoftnessPixels: CGFloat
    let reflectionShapeClosed: Bool
    let reflectionShapeCircular: Bool
    let trackingPoints: [CGPoint]
    let trackingPointIDs: [String]
    let trackingSegments: [CGPoint]
    let trackingMeshCenters: [CGPoint]
    let trackingMeshCenterIDs: [String]
    let trackingMeshCenterLabels: [String]
    let trackingPointSelectionEnabled: Bool
    let sceneInteractionLocked: Bool
    let cameraNavigationEnabled: Bool
    let onDisplayChange: (StudioColorSystemDisplayInfo) -> Void
    let onPanChange: (CGSize) -> Void
    let onZoomChange: (Double) -> Void
    let onFittedZoomChange: (Double) -> Void
    let onCameraGestureBegin: (CameraNavigationOperation, CGSize) -> Void
    let onCameraGestureChange: (CGSize) -> Void
    let onCameraGestureEnd: () -> Void
    let onFocusTargetBegin: () -> Void
    let onFocusTargetChange: (CGPoint) -> Void
    let onFocusTargetEnd: () -> Void
    let onReferenceCornerBegin: (Int) -> Void
    let onReferenceCornerChange: (Int, CGPoint) -> Void
    let onReferenceCornerEnd: () -> Void
    let onReflectionHandleBegin: (Int) -> Void
    let onReflectionHandleChange: (Int, CGPoint) -> Void
    let onReflectionHandleEnd: () -> Void
    let onTrackingPointSelected: (String) -> Void
    let onPlaceDeviceAtTrackingPoint: (String) -> Void
    let onPlaceDeviceOnTrackingPlane: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDisplayChange: onDisplayChange)
    }

    func makeNSView(context: Context) -> MetalPreviewContainer {
        let container = MetalPreviewContainer()
        let view = StudioColorScreenAwareMetalView()
        view.screenDidChange = context.coordinator.reportDisplayChange
        display.configure(view)
        container.install(view)
        return container
    }

    func updateNSView(_ container: MetalPreviewContainer, context: Context) {
        context.coordinator.onDisplayChange = onDisplayChange
        container.metalView.screenDidChange = context.coordinator.reportDisplayChange
        container.updatePresentation(
            zoom: zoom,
            pan: pan,
            fitted: fitted,
            metadataLines: metadataLines,
            deviceBoundary: deviceBoundary,
            sensorGateBoundary: sensorGateBoundary,
            focusTarget: focusTarget,
            focusTargetEnabled: focusTargetEnabled,
            referenceProjectedCorners: referenceProjectedCorners,
            referenceTargetCorners: referenceTargetCorners,
            reflectionHandles: reflectionHandles,
            reflectionSoftnessPixels: reflectionSoftnessPixels,
            reflectionShapeClosed: reflectionShapeClosed,
            reflectionShapeCircular: reflectionShapeCircular,
            trackingPoints: trackingPoints,
            trackingPointIDs: trackingPointIDs,
            trackingSegments: trackingSegments,
            trackingMeshCenters: trackingMeshCenters,
            trackingMeshCenterIDs: trackingMeshCenterIDs,
            trackingMeshCenterLabels: trackingMeshCenterLabels,
            trackingPointSelectionEnabled: trackingPointSelectionEnabled,
            sceneInteractionLocked: sceneInteractionLocked,
            cameraNavigationEnabled: cameraNavigationEnabled,
            textureWidth: frame.width,
            textureHeight: frame.height
        )
        container.onPanChange = onPanChange
        container.onZoomChange = onZoomChange
        container.onFittedZoomChange = onFittedZoomChange
        container.onCameraGestureBegin = onCameraGestureBegin
        container.onCameraGestureChange = onCameraGestureChange
        container.onCameraGestureEnd = onCameraGestureEnd
        container.onFocusTargetBegin = onFocusTargetBegin
        container.onFocusTargetChange = onFocusTargetChange
        container.onFocusTargetEnd = onFocusTargetEnd
        container.onReferenceCornerBegin = onReferenceCornerBegin
        container.onReferenceCornerChange = onReferenceCornerChange
        container.onReferenceCornerEnd = onReferenceCornerEnd
        container.onReflectionHandleBegin = onReflectionHandleBegin
        container.onReflectionHandleChange = onReflectionHandleChange
        container.onReflectionHandleEnd = onReflectionHandleEnd
        container.onTrackingPointSelected = onTrackingPointSelected
        container.onPlaceDeviceAtTrackingPoint = onPlaceDeviceAtTrackingPoint
        container.onPlaceDeviceOnTrackingPlane = onPlaceDeviceOnTrackingPlane
        display.present(frame, output: output, in: container.metalView)
        container.drawCommittedFrame()
    }

    @MainActor
    final class Coordinator {
        var onDisplayChange: (StudioColorSystemDisplayInfo) -> Void
        private var lastScheduled: StudioColorSystemDisplayInfo?

        init(onDisplayChange: @escaping (StudioColorSystemDisplayInfo) -> Void) {
            self.onDisplayChange = onDisplayChange
        }

        func reportDisplayChange(_ info: StudioColorSystemDisplayInfo) {
            guard lastScheduled != info else { return }
            lastScheduled = info
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.lastScheduled == info else { return }
                self.onDisplayChange(info)
            }
        }
    }
}

private struct CommittedZoomField: View {
    let percentage: Double
    let onCommit: (Double) -> Void

    @State private var draft = "100"
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Zoom", text: $draft)
            .focused($isFocused)
            .multilineTextAlignment(.trailing)
            .onAppear { synchronize(with: percentage) }
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if focused {
                    synchronize(with: percentage)
                } else {
                    commit()
                }
            }
            .onChange(of: percentage) { _, value in
                if !isFocused { synchronize(with: value) }
            }
    }

    private func commit() {
        let normalized = draft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else {
            synchronize(with: percentage)
            return
        }
        let clamped = min(1_600, max(10, value))
        onCommit(clamped)
        synchronize(with: clamped)
    }

    private func synchronize(with value: Double) {
        draft = value.formatted(.number.precision(.fractionLength(0 ... 1)))
    }
}

final class MetalPreviewContainer: NSView {
    private(set) var metalView = StudioColorScreenAwareMetalView()
    private var presentationZoom = 1.0
    private var presentationPan = CGSize.zero
    private var presentationFitted = true
    private var textureWidth = 1
    private var textureHeight = 1
    private var cameraNavigationEnabled = true
    private var sceneInteractionLocked = false
    var onPanChange: ((CGSize) -> Void)?
    var onZoomChange: ((Double) -> Void)?
    var onFittedZoomChange: ((Double) -> Void)?
    var onCameraGestureBegin: ((CameraNavigationOperation, CGSize) -> Void)?
    var onCameraGestureChange: ((CGSize) -> Void)?
    var onCameraGestureEnd: (() -> Void)?
    var onFocusTargetBegin: (() -> Void)?
    var onFocusTargetChange: ((CGPoint) -> Void)?
    var onFocusTargetEnd: (() -> Void)?
    var onReferenceCornerBegin: ((Int) -> Void)?
    var onReferenceCornerChange: ((Int, CGPoint) -> Void)?
    var onReferenceCornerEnd: (() -> Void)?
    var onReflectionHandleBegin: ((Int) -> Void)?
    var onReflectionHandleChange: ((Int, CGPoint) -> Void)?
    var onReflectionHandleEnd: (() -> Void)?
    var onTrackingPointSelected: ((String) -> Void)?
    var onPlaceDeviceAtTrackingPoint: ((String) -> Void)?
    var onPlaceDeviceOnTrackingPlane: ((String) -> Void)?
    private let metadataLabel = NSTextField(labelWithString: "")
    private let frameBorderLayer = CALayer()
    private let deviceBoundaryLayer = CAShapeLayer()
    private let sensorGateBoundaryLayer = CAShapeLayer()
    private let focusTargetLayer = CAShapeLayer()
    private let referenceProjectionLayer = CAShapeLayer()
    private let referenceTargetBoundaryLayer = CAShapeLayer()
    private let referenceTargetLayer = CAShapeLayer()
    private let reflectionBoundaryLayer = CAShapeLayer()
    private let reflectionSoftnessBoundaryLayer = CAShapeLayer()
    private let reflectionHandleLayer = CAShapeLayer()
    private let trackingGeometryLayer = CAShapeLayer()
    private let trackingPointLayer = CAShapeLayer()
    private let trackingMeshCenterLayer = CAShapeLayer()
    private let referenceLabels = ["TL", "TR", "BR", "BL"].map { label -> CATextLayer in
        let layer = CATextLayer()
        layer.string = label
        layer.fontSize = 10
        layer.foregroundColor = NSColor.systemYellow.cgColor
        layer.alignmentMode = .center
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.zPosition = 121
        return layer
    }
    private var deviceBoundary: [CGPoint] = []
    private var sensorGateBoundary: [CGPoint] = []
    private var focusTarget: CGPoint?
    private var focusTargetEnabled = false
    private var referenceProjectedCorners: [CGPoint] = []
    private var referenceTargetCorners: [CGPoint] = []
    private var reflectionHandles: [CGPoint] = []
    private var reflectionSoftnessPixels: CGFloat = 0
    private var reflectionShapeClosed = false
    private var reflectionShapeCircular = false
    private var trackingPoints: [CGPoint] = []
    private var trackingPointIDs: [String] = []
    private var trackingSegments: [CGPoint] = []
    private var trackingMeshCenters: [CGPoint] = []
    private var trackingMeshCenterIDs: [String] = []
    private var trackingMeshCenterLabels: [String] = []
    private var trackingPointSelectionEnabled = false
    private var contextTrackingPointID: String?
    private var contextTrackingMeshID: String?
    private var referenceCornerDragIndex: Int?
    private var reflectionHandleDragIndex: Int?
    private var focusTargetDragging = false
    private var dragStartLocation: CGPoint?
    private var dragStartPan = CGSize.zero
    private var magnifyAnchor: CGPoint?
    private var cameraDragStart: CGPoint?
    private var viewerMiddleDragStart: CGPoint?
    private var viewerMiddleDragStartPan = CGSize.zero
    private var viewerMiddleZoomStart: CGPoint?
    private var viewerMiddleZoomStartScale = 1.0
    private var viewerMiddleZoomStartPan = CGSize.zero
    private var viewerMiddleZoomAnchor = CGPoint.zero
    private var pendingCameraGestureDelta: CGSize?
    private var deliveredCameraGestureDelta: CGSize?
    private var cameraGestureUpdate: DispatchWorkItem?
    private var wheelGestureActive = false
    private var wheelGestureDelta = CGSize.zero
    private var committedDrawGeneration: UInt64 = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1).cgColor
        frameBorderLayer.backgroundColor = NSColor.clear.cgColor
        frameBorderLayer.borderColor = NSColor(
            calibratedWhite: 0.72, alpha: 0.55
        ).cgColor
        frameBorderLayer.borderWidth = 1
        frameBorderLayer.zPosition = 100
        layer?.addSublayer(frameBorderLayer)
        deviceBoundaryLayer.fillColor = NSColor.clear.cgColor
        deviceBoundaryLayer.strokeColor = NSColor.systemRed.cgColor
        deviceBoundaryLayer.lineWidth = 1
        deviceBoundaryLayer.zPosition = 110
        layer?.addSublayer(deviceBoundaryLayer)
        sensorGateBoundaryLayer.fillColor = NSColor.clear.cgColor
        sensorGateBoundaryLayer.strokeColor = NSColor.systemCyan.cgColor
        sensorGateBoundaryLayer.lineWidth = 1
        sensorGateBoundaryLayer.lineDashPattern = [6, 4]
        sensorGateBoundaryLayer.zPosition = 109
        layer?.addSublayer(sensorGateBoundaryLayer)
        focusTargetLayer.fillColor = NSColor.clear.cgColor
        focusTargetLayer.strokeColor = NSColor.systemGreen.cgColor
        focusTargetLayer.lineWidth = 2
        focusTargetLayer.zPosition = 127
        layer?.addSublayer(focusTargetLayer)
        referenceProjectionLayer.fillColor = NSColor.clear.cgColor
        referenceProjectionLayer.strokeColor = NSColor.systemRed.cgColor
        referenceProjectionLayer.lineWidth = 1.5
        referenceProjectionLayer.zPosition = 120
        layer?.addSublayer(referenceProjectionLayer)
        referenceTargetBoundaryLayer.fillColor = NSColor.clear.cgColor
        referenceTargetBoundaryLayer.strokeColor = NSColor.systemYellow.cgColor
        referenceTargetBoundaryLayer.lineWidth = 1.5
        referenceTargetBoundaryLayer.zPosition = 120.5
        layer?.addSublayer(referenceTargetBoundaryLayer)
        referenceTargetLayer.fillColor = NSColor.systemYellow.cgColor
        referenceTargetLayer.strokeColor = NSColor.black.cgColor
        referenceTargetLayer.lineWidth = 1
        referenceTargetLayer.zPosition = 121
        layer?.addSublayer(referenceTargetLayer)
        reflectionBoundaryLayer.fillColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        reflectionBoundaryLayer.strokeColor = NSColor.systemOrange.cgColor
        reflectionBoundaryLayer.lineWidth = 1.5
        reflectionBoundaryLayer.zPosition = 122
        layer?.addSublayer(reflectionBoundaryLayer)
        reflectionSoftnessBoundaryLayer.fillColor = NSColor.clear.cgColor
        reflectionSoftnessBoundaryLayer.strokeColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
        reflectionSoftnessBoundaryLayer.lineWidth = 1.25
        reflectionSoftnessBoundaryLayer.lineDashPattern = [7, 5]
        reflectionSoftnessBoundaryLayer.zPosition = 121.5
        layer?.addSublayer(reflectionSoftnessBoundaryLayer)
        reflectionHandleLayer.fillColor = NSColor.systemOrange.cgColor
        reflectionHandleLayer.strokeColor = NSColor.black.cgColor
        reflectionHandleLayer.lineWidth = 1
        reflectionHandleLayer.zPosition = 123
        layer?.addSublayer(reflectionHandleLayer)
        trackingGeometryLayer.fillColor = NSColor.clear.cgColor
        trackingGeometryLayer.strokeColor = NSColor.systemTeal.withAlphaComponent(0.85).cgColor
        trackingGeometryLayer.lineWidth = 1
        trackingGeometryLayer.zPosition = 124
        layer?.addSublayer(trackingGeometryLayer)
        trackingPointLayer.fillColor = NSColor.systemGreen.cgColor
        trackingPointLayer.strokeColor = NSColor.black.cgColor
        trackingPointLayer.lineWidth = 1
        trackingPointLayer.zPosition = 125
        layer?.addSublayer(trackingPointLayer)
        trackingMeshCenterLayer.fillColor = NSColor.systemOrange.cgColor
        trackingMeshCenterLayer.strokeColor = NSColor.black.cgColor
        trackingMeshCenterLayer.lineWidth = 1
        trackingMeshCenterLayer.zPosition = 126
        layer?.addSublayer(trackingMeshCenterLayer)
        referenceLabels.forEach { layer?.addSublayer($0) }
        metadataLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        metadataLabel.textColor = NSColor(calibratedWhite: 0.78, alpha: 1)
        metadataLabel.alignment = .right
        metadataLabel.maximumNumberOfLines = 2
        metadataLabel.lineBreakMode = .byTruncatingHead
        addSubview(metadataLabel)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: dragStartLocation == nil ? .openHand : .closedHand)
    }

    func install(_ view: StudioColorScreenAwareMetalView) {
        metalView.removeFromSuperview()
        metalView = view
        addSubview(view)
        needsLayout = true
    }

    /// Draw immediately for interactive tracking, then retry only the latest
    /// committed presentation after AppKit has attached/updated the drawable.
    /// A first publication can otherwise be consumed while currentDrawable is
    /// unavailable and remain black until an unrelated state change.
    func drawCommittedFrame() {
        committedDrawGeneration &+= 1
        let generation = committedDrawGeneration
        metalView.draw()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.committedDrawGeneration == generation else { return }
            self.metalView.setNeedsDisplay(self.metalView.bounds)
            self.metalView.draw()
        }
    }

    override func layout() {
        super.layout()
        applyPresentation()
    }

    func updatePresentation(
        zoom: Double,
        pan: CGSize,
        fitted: Bool,
        metadataLines: [String],
        deviceBoundary: [CGPoint],
        sensorGateBoundary: [CGPoint],
        focusTarget: CGPoint?,
        focusTargetEnabled: Bool,
        referenceProjectedCorners: [CGPoint],
        referenceTargetCorners: [CGPoint],
        reflectionHandles: [CGPoint],
        reflectionSoftnessPixels: CGFloat,
        reflectionShapeClosed: Bool,
        reflectionShapeCircular: Bool,
        trackingPoints: [CGPoint],
        trackingPointIDs: [String],
        trackingSegments: [CGPoint],
        trackingMeshCenters: [CGPoint],
        trackingMeshCenterIDs: [String],
        trackingMeshCenterLabels: [String],
        trackingPointSelectionEnabled: Bool,
        sceneInteractionLocked: Bool,
        cameraNavigationEnabled: Bool,
        textureWidth: Int,
        textureHeight: Int
    ) {
        presentationZoom = zoom
        presentationPan = pan
        presentationFitted = fitted
        metadataLabel.stringValue = metadataLines.joined(separator: "\n")
        metadataLabel.isHidden = metadataLines.isEmpty
        self.deviceBoundary = deviceBoundary
        self.sensorGateBoundary = sensorGateBoundary
        self.focusTarget = focusTarget
        self.focusTargetEnabled = focusTargetEnabled
        self.referenceProjectedCorners = referenceProjectedCorners
        self.referenceTargetCorners = referenceTargetCorners
        self.reflectionHandles = reflectionHandles
        self.reflectionSoftnessPixels = max(0, reflectionSoftnessPixels)
        self.reflectionShapeClosed = reflectionShapeClosed
        self.reflectionShapeCircular = reflectionShapeCircular
        self.trackingPoints = trackingPoints
        self.trackingPointIDs = trackingPointIDs
        self.trackingSegments = trackingSegments
        self.trackingMeshCenters = trackingMeshCenters
        self.trackingMeshCenterIDs = trackingMeshCenterIDs
        self.trackingMeshCenterLabels = trackingMeshCenterLabels
        self.trackingPointSelectionEnabled = trackingPointSelectionEnabled
        self.sceneInteractionLocked = sceneInteractionLocked
        self.cameraNavigationEnabled = cameraNavigationEnabled
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        applyPresentation()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        if !sceneInteractionLocked, focusTargetEnabled, focusTargetHitRegion(location) {
            focusTargetDragging = true
            onFocusTargetBegin?()
            onFocusTargetChange?(rasterPoint(fromViewer: location))
            NSCursor.crosshair.push()
            return
        }
        if !sceneInteractionLocked,
           trackingPointSelectionEnabled, let index = nearestTrackingPoint(to: location),
           trackingPointIDs.indices.contains(index) {
            onTrackingPointSelected?(trackingPointIDs[index])
            return
        }
        if !sceneInteractionLocked, let index = nearestReflectionHandle(to: location) {
            reflectionHandleDragIndex = index
            onReflectionHandleBegin?(index)
            NSCursor.crosshair.push()
            return
        }
        if !sceneInteractionLocked, let index = nearestReferenceCorner(to: location) {
            referenceCornerDragIndex = index
            onReferenceCornerBegin?(index)
            NSCursor.crosshair.push()
            return
        }
        dragStartLocation = event.locationInWindow
        dragStartPan = presentationPan
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        if focusTargetDragging {
            onFocusTargetChange?(rasterPoint(fromViewer: convert(event.locationInWindow, from: nil)))
            return
        }
        if let index = reflectionHandleDragIndex {
            onReflectionHandleChange?(index, rasterPoint(fromViewer: convert(event.locationInWindow, from: nil)))
            return
        }
        if let index = referenceCornerDragIndex {
            onReferenceCornerChange?(index, rasterPoint(fromViewer: convert(event.locationInWindow, from: nil)))
            return
        }
        guard let start = dragStartLocation else { return }
        let location = event.locationInWindow
        let proposed = CGSize(
            width: dragStartPan.width + location.x - start.x,
            height: dragStartPan.height + location.y - start.y
        )
        publishPan(clampedPan(proposed))
    }

    override func mouseUp(with _: NSEvent) {
        if focusTargetDragging {
            focusTargetDragging = false
            onFocusTargetEnd?()
            NSCursor.pop()
            return
        }
        if reflectionHandleDragIndex != nil {
            reflectionHandleDragIndex = nil
            onReflectionHandleEnd?()
            NSCursor.pop()
            return
        }
        if referenceCornerDragIndex != nil {
            referenceCornerDragIndex = nil
            onReferenceCornerEnd?()
            NSCursor.pop()
            return
        }
        if dragStartLocation != nil {
            publishPan(clampedPan(presentationPan))
            dragStartLocation = nil
            NSCursor.pop()
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        window?.makeFirstResponder(self)
        if !cameraNavigationEnabled {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.shift) {
                viewerMiddleZoomStart = event.locationInWindow
                viewerMiddleZoomStartScale = Double(effectiveScale())
                viewerMiddleZoomStartPan = presentationPan
                viewerMiddleZoomAnchor = convert(event.locationInWindow, from: nil)
                NSCursor.resizeLeftRight.push()
                return
            }
            viewerMiddleDragStart = event.locationInWindow
            viewerMiddleDragStartPan = presentationPan
            NSCursor.closedHand.push()
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let operation: CameraNavigationOperation
        if flags.contains(.command), !flags.contains(.option), !flags.contains(.shift) {
            operation = .trackingWorldScale
        }
        else if flags.contains(.option), !flags.contains(.shift), !flags.contains(.command) { operation = .orbit }
        else if flags.contains(.shift), !flags.contains(.option) { operation = .dolly }
        else if !flags.contains(.option), !flags.contains(.shift), !flags.contains(.command) { operation = .pan }
        else { return }
        cameraDragStart = convert(event.locationInWindow, from: nil)
        pendingCameraGestureDelta = nil
        deliveredCameraGestureDelta = nil
        cameraGestureUpdate?.cancel()
        cameraGestureUpdate = nil
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.preferredFramesPerSecond = 60
        onCameraGestureBegin?(operation, contentViewportSize())
        NSCursor.closedHand.push()
    }

    override func otherMouseDragged(with event: NSEvent) {
        if let start = viewerMiddleZoomStart {
            let delta = event.locationInWindow.x - start.x
            let newZoom = min(16, max(0.1, viewerMiddleZoomStartScale * exp(delta * 0.01)))
            let ratio = CGFloat(newZoom / max(0.01, viewerMiddleZoomStartScale))
            let anchoredPan = PreviewNavigationMath.anchoredPan(
                previous: viewerMiddleZoomStartPan,
                anchor: viewerMiddleZoomAnchor,
                viewportCenter: CGPoint(x: bounds.midX, y: contentCenterY()),
                scaleRatio: ratio
            )
            presentationZoom = newZoom
            presentationFitted = false
            onZoomChange?(newZoom)
            publishPan(clampedPan(anchoredPan))
            return
        }
        if let start = viewerMiddleDragStart {
            let location = event.locationInWindow
            publishPan(clampedPan(CGSize(
                width: viewerMiddleDragStartPan.width + location.x - start.x,
                height: viewerMiddleDragStartPan.height + location.y - start.y
            )))
            return
        }
        guard event.buttonNumber == 2, let start = cameraDragStart else { return }
        let current = convert(event.locationInWindow, from: nil)
        enqueueCameraGestureChange(CGSize(
            width: current.x - start.x,
            height: current.y - start.y
        ))
    }

    override func otherMouseUp(with event: NSEvent) {
        if viewerMiddleZoomStart != nil {
            viewerMiddleZoomStart = nil
            publishPan(clampedPan(presentationPan))
            NSCursor.pop()
            return
        }
        if viewerMiddleDragStart != nil {
            viewerMiddleDragStart = nil
            publishPan(clampedPan(presentationPan))
            NSCursor.pop()
            return
        }
        guard event.buttonNumber == 2, cameraDragStart != nil else { return }
        cameraDragStart = nil
        flushCameraGestureChange()
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        onCameraGestureEnd?()
        metalView.draw()
        NSCursor.pop()
    }

    override func scrollWheel(with event: NSEvent) {
        if !cameraNavigationEnabled {
            zoomViewer(with: event)
            return
        }
        // AppKit continues publishing inertial momentum after the user has
        // released a trackpad or Magic Mouse. Camera navigation represents
        // authored physical movement, so momentum is never an input.
        guard event.momentumPhase.isEmpty else {
            endWheelGesture()
            return
        }
        let delta = event.scrollingDeltaY * 8
        let phasedGesture = !event.phase.isEmpty
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            beginWheelGesture()
        }
        if abs(delta) > 0 {
            if !wheelGestureActive { beginWheelGesture() }
            wheelGestureDelta.width += delta
            enqueueCameraGestureChange(wheelGestureDelta)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            endWheelGesture()
        } else if !phasedGesture {
            // A traditional detented wheel has no AppKit gesture phases.
            endWheelGesture()
        }
    }

    private func zoomViewer(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        let oldZoom = effectiveScale()
        let newZoom = min(16, max(0.1, oldZoom * exp(event.scrollingDeltaY * 0.01)))
        let ratio = CGFloat(newZoom / max(0.01, oldZoom))
        let center = CGPoint(x: bounds.midX, y: contentCenterY())
        let anchoredPan = PreviewNavigationMath.anchoredPan(
            previous: presentationPan,
            anchor: anchor,
            viewportCenter: center,
            scaleRatio: ratio
        )
        presentationZoom = newZoom
        presentationFitted = false
        onZoomChange?(newZoom)
        publishPan(clampedPan(anchoredPan))
    }

    private func beginWheelGesture() {
        guard !wheelGestureActive else { return }
        wheelGestureActive = true
        wheelGestureDelta = .zero
        deliveredCameraGestureDelta = nil
        onCameraGestureBegin?(.dolly, contentViewportSize())
    }

    private func endWheelGesture() {
        guard wheelGestureActive else { return }
        flushCameraGestureChange()
        wheelGestureActive = false
        wheelGestureDelta = .zero
        onCameraGestureEnd?()
    }

    private func enqueueCameraGestureChange(_ delta: CGSize) {
        pendingCameraGestureDelta = delta
        guard cameraGestureUpdate == nil else { return }
        let update = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.cameraGestureUpdate = nil
            self.deliverPendingCameraGestureChange()
        }
        cameraGestureUpdate = update
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0, execute: update)
    }

    private func flushCameraGestureChange() {
        cameraGestureUpdate?.cancel()
        cameraGestureUpdate = nil
        deliverPendingCameraGestureChange()
    }

    private func deliverPendingCameraGestureChange() {
        guard let delta = pendingCameraGestureDelta else { return }
        pendingCameraGestureDelta = nil
        guard deliveredCameraGestureDelta != delta else { return }
        deliveredCameraGestureDelta = delta
        onCameraGestureChange?(delta)
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        if event.phase == .began || magnifyAnchor == nil {
            magnifyAnchor = anchor
        }
        guard let origin = magnifyAnchor else { return }
        let oldZoom = effectiveScale()
        let oldPan = presentationPan
        let newZoom = min(16, max(0.01, oldZoom * (1 + event.magnification)))
        let ratio = CGFloat(newZoom / max(0.01, oldZoom))
        let center = CGPoint(x: bounds.midX, y: contentCenterY())
        let anchoredPan = PreviewNavigationMath.anchoredPan(
            previous: oldPan,
            anchor: origin,
            viewportCenter: center,
            scaleRatio: ratio
        )
        presentationZoom = newZoom
        presentationFitted = false
        onZoomChange?(newZoom)
        publishPan(clampedPan(anchoredPan))
        if event.phase == .ended || event.phase == .cancelled {
            magnifyAnchor = nil
        }
    }

    override func cursorUpdate(with _: NSEvent) {
        (dragStartLocation == nil ? NSCursor.openHand : NSCursor.closedHand).set()
    }

    private func applyPresentation() {
        let scale = effectiveScale()
        metalView.layer?.setAffineTransform(.identity)
        let texture = textureSize()
        metalView.bounds = NSRect(origin: .zero, size: texture)
        metalView.frame = NSRect(
            x: bounds.midX - texture.width / 2,
            y: contentCenterY() - texture.height / 2,
            width: texture.width,
            height: texture.height
        )
        let effectivePan = PreviewNavigationMath.clampedPan(
            presentationPan,
            viewport: contentViewportSize(),
            fittedContent: texture,
            scale: scale
        )
        if effectivePan != presentationPan {
            presentationPan = effectivePan
            Task { @MainActor [weak self] in
                self?.onPanChange?(effectivePan)
            }
        }
        metalView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        metalView.layer?.position = CGPoint(
            x: bounds.midX + effectivePan.width,
            y: contentCenterY() + effectivePan.height
        )
        metalView.layer?.setAffineTransform(
            CGAffineTransform(scaleX: scale, y: scale)
        )
        let displayed = CGSize(width: texture.width * scale, height: texture.height * scale)
        let displayedOriginX = bounds.midX + effectivePan.width - displayed.width / 2
        let displayedOriginY = contentCenterY() + effectivePan.height - displayed.height / 2
        let displayedTopY = contentCenterY() + effectivePan.height + displayed.height / 2
        frameBorderLayer.frame = NSRect(
            x: displayedOriginX,
            y: displayedOriginY,
            width: displayed.width,
            height: displayed.height
        )
        let boundaryPath = CGMutablePath()
        for (index, point) in deviceBoundary.enumerated() {
            let displayedPoint = CGPoint(
                x: displayedOriginX + point.x * scale,
                y: displayedOriginY + (CGFloat(textureHeight) - point.y) * scale
            )
            if index == 0 { boundaryPath.move(to: displayedPoint) }
            else { boundaryPath.addLine(to: displayedPoint) }
        }
        if !deviceBoundary.isEmpty { boundaryPath.closeSubpath() }
        deviceBoundaryLayer.frame = bounds
        deviceBoundaryLayer.path = boundaryPath
        let sensorGatePath = CGMutablePath()
        for (index, point) in sensorGateBoundary.enumerated() {
            let displayedPoint = CGPoint(
                x: displayedOriginX + point.x * scale,
                y: displayedOriginY + (CGFloat(textureHeight) - point.y) * scale
            )
            if index == 0 { sensorGatePath.move(to: displayedPoint) }
            else { sensorGatePath.addLine(to: displayedPoint) }
        }
        if !sensorGateBoundary.isEmpty { sensorGatePath.closeSubpath() }
        sensorGateBoundaryLayer.frame = bounds
        sensorGateBoundaryLayer.path = sensorGatePath
        let focusPath = CGMutablePath()
        if let focusTarget {
            let point = displayedPoint(forRaster: focusTarget)
            focusPath.addEllipse(in: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14))
            focusPath.move(to: CGPoint(x: point.x - 11, y: point.y))
            focusPath.addLine(to: CGPoint(x: point.x + 11, y: point.y))
            focusPath.move(to: CGPoint(x: point.x, y: point.y - 11))
            focusPath.addLine(to: CGPoint(x: point.x, y: point.y + 11))
        }
        focusTargetLayer.frame = bounds
        focusTargetLayer.path = focusPath
        let projectedHandles = CGMutablePath()
        for point in referenceProjectedCorners {
            let displayedPoint = displayedPoint(forRaster: point)
            projectedHandles.move(to: CGPoint(x: displayedPoint.x - 7, y: displayedPoint.y - 7))
            projectedHandles.addLine(to: CGPoint(x: displayedPoint.x + 7, y: displayedPoint.y + 7))
            projectedHandles.move(to: CGPoint(x: displayedPoint.x + 7, y: displayedPoint.y - 7))
            projectedHandles.addLine(to: CGPoint(x: displayedPoint.x - 7, y: displayedPoint.y + 7))
        }
        let targetHandles = CGMutablePath()
        let targetBoundary = CGMutablePath()
        if referenceTargetCorners.count == 4 {
            for (index, point) in referenceTargetCorners.enumerated() {
                let displayedPoint = displayedPoint(forRaster: point)
                if index == 0 { targetBoundary.move(to: displayedPoint) }
                else { targetBoundary.addLine(to: displayedPoint) }
            }
            targetBoundary.closeSubpath()
        }
        for index in referenceTargetCorners.indices {
            let displayedPoint = displayedPoint(forRaster: referenceTargetCorners[index])
            targetHandles.addEllipse(in: CGRect(
                x: displayedPoint.x - 6, y: displayedPoint.y - 6, width: 12, height: 12
            ))
        }
        referenceProjectionLayer.frame = bounds
        referenceProjectionLayer.path = projectedHandles
        referenceTargetBoundaryLayer.frame = bounds
        referenceTargetBoundaryLayer.path = targetBoundary
        referenceTargetLayer.frame = bounds
        referenceTargetLayer.path = targetHandles
        let reflectionBoundary = CGMutablePath()
        let reflectionSoftnessBoundary = CGMutablePath()
        if reflectionShapeCircular, reflectionHandles.count == 2 {
            let center = displayedPoint(forRaster: reflectionHandles[0])
            let radiusPoint = displayedPoint(forRaster: reflectionHandles[1])
            let radius = hypot(radiusPoint.x - center.x, radiusPoint.y - center.y)
            reflectionBoundary.addEllipse(in: CGRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
            let outerRadius = radius + reflectionSoftnessPixels * scale
            reflectionSoftnessBoundary.addEllipse(in: CGRect(
                x: center.x - outerRadius, y: center.y - outerRadius,
                width: outerRadius * 2, height: outerRadius * 2
            ))
        } else if let first = reflectionHandles.first {
            let displayedHandles = reflectionHandles.map(displayedPoint(forRaster:))
            reflectionBoundary.move(to: displayedPoint(forRaster: first))
            for point in displayedHandles.dropFirst() {
                reflectionBoundary.addLine(to: point)
            }
            if reflectionShapeClosed, reflectionHandles.count > 2 {
                reflectionBoundary.closeSubpath()
                let center = displayedHandles.reduce(CGPoint.zero) {
                    CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
                }.applying(CGAffineTransform(
                    scaleX: 1 / CGFloat(displayedHandles.count),
                    y: 1 / CGFloat(displayedHandles.count)
                ))
                let expanded = displayedHandles.map { point -> CGPoint in
                    let dx = point.x - center.x
                    let dy = point.y - center.y
                    let length = max(0.001, hypot(dx, dy))
                    let amount = reflectionSoftnessPixels * scale
                    return CGPoint(
                        x: center.x + dx * (length + amount) / length,
                        y: center.y + dy * (length + amount) / length
                    )
                }
                if let firstExpanded = expanded.first {
                    reflectionSoftnessBoundary.move(to: firstExpanded)
                    for point in expanded.dropFirst() {
                        reflectionSoftnessBoundary.addLine(to: point)
                    }
                    reflectionSoftnessBoundary.closeSubpath()
                }
            }
        }
        let reflectionHandlePath = CGMutablePath()
        for point in reflectionHandles {
            let displayed = displayedPoint(forRaster: point)
            reflectionHandlePath.addEllipse(in: CGRect(
                x: displayed.x - 7, y: displayed.y - 7, width: 14, height: 14
            ))
        }
        reflectionBoundaryLayer.frame = bounds
        reflectionBoundaryLayer.path = reflectionBoundary
        reflectionSoftnessBoundaryLayer.frame = bounds
        reflectionSoftnessBoundaryLayer.path = reflectionSoftnessBoundary
        reflectionHandleLayer.frame = bounds
        reflectionHandleLayer.path = reflectionHandlePath
        let trackingGeometryPath = CGMutablePath()
        for offset in stride(from: 0, to: trackingSegments.count - trackingSegments.count % 2, by: 2) {
            trackingGeometryPath.move(to: displayedPoint(forRaster: trackingSegments[offset]))
            trackingGeometryPath.addLine(to: displayedPoint(forRaster: trackingSegments[offset + 1]))
        }
        trackingGeometryLayer.frame = bounds
        trackingGeometryLayer.path = trackingGeometryPath
        let trackingPointPath = CGMutablePath()
        for point in trackingPoints {
            let displayed = displayedPoint(forRaster: point)
            trackingPointPath.addEllipse(in: CGRect(x: displayed.x - 4, y: displayed.y - 4, width: 8, height: 8))
        }
        trackingPointLayer.frame = bounds
        trackingPointLayer.path = trackingPointPath
        let trackingMeshCenterPath = CGMutablePath()
        for point in trackingMeshCenters {
            let displayed = displayedPoint(forRaster: point)
            trackingMeshCenterPath.addEllipse(in: CGRect(
                x: displayed.x - 6, y: displayed.y - 6, width: 12, height: 12
            ))
            trackingMeshCenterPath.move(to: CGPoint(x: displayed.x - 9, y: displayed.y))
            trackingMeshCenterPath.addLine(to: CGPoint(x: displayed.x + 9, y: displayed.y))
            trackingMeshCenterPath.move(to: CGPoint(x: displayed.x, y: displayed.y - 9))
            trackingMeshCenterPath.addLine(to: CGPoint(x: displayed.x, y: displayed.y + 9))
        }
        trackingMeshCenterLayer.frame = bounds
        trackingMeshCenterLayer.path = trackingMeshCenterPath
        for (index, label) in referenceLabels.enumerated() {
            guard referenceTargetCorners.indices.contains(index) else {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            label.foregroundColor = NSColor.systemYellow.cgColor
            let point = displayedPoint(forRaster: referenceTargetCorners[index])
            label.frame = CGRect(x: point.x - 14, y: point.y + 8, width: 28, height: 14)
        }
        metadataLabel.frame = NSRect(
            x: min(
                max(12, displayedOriginX),
                max(12, bounds.maxX - min(displayed.width, bounds.width - 24) - 12)
            ),
            y: min(bounds.maxY - 28, max(8, displayedTopY + 4)),
            width: min(displayed.width, bounds.width - 24),
            height: 26
        )
    }

    private func publishPan(_ value: CGSize) {
        presentationPan = value
        onPanChange?(value)
        applyPresentation()
    }

    private func clampedPan(_ proposed: CGSize) -> CGSize {
        let texture = textureSize()
        let scale = effectiveScale()
        return PreviewNavigationMath.clampedPan(
            proposed,
            viewport: contentViewportSize(),
            fittedContent: texture,
            scale: scale
        )
    }

    private func textureSize() -> CGSize {
        CGSize(width: textureWidth, height: textureHeight)
    }

    private func displayedPoint(forRaster point: CGPoint) -> CGPoint {
        let scale = effectiveScale()
        let texture = textureSize()
        let displayed = CGSize(width: texture.width * scale, height: texture.height * scale)
        let x = bounds.midX + presentationPan.width - displayed.width / 2
        let y = contentCenterY() + presentationPan.height - displayed.height / 2
        return CGPoint(x: x + point.x * scale, y: y + (CGFloat(textureHeight) - point.y) * scale)
    }

    private func rasterPoint(fromViewer point: CGPoint) -> CGPoint {
        let scale = effectiveScale()
        let texture = textureSize()
        let displayed = CGSize(width: texture.width * scale, height: texture.height * scale)
        let x = bounds.midX + presentationPan.width - displayed.width / 2
        let y = contentCenterY() + presentationPan.height - displayed.height / 2
        return CGPoint(
            x: (point.x - x) / scale,
            y: CGFloat(textureHeight) - (point.y - y) / scale
        )
    }

    private func nearestReferenceCorner(to point: CGPoint) -> Int? {
        referenceTargetCorners.indices.min(by: {
            hypot(displayedPoint(forRaster: referenceTargetCorners[$0]).x - point.x,
                  displayedPoint(forRaster: referenceTargetCorners[$0]).y - point.y)
                < hypot(displayedPoint(forRaster: referenceTargetCorners[$1]).x - point.x,
                        displayedPoint(forRaster: referenceTargetCorners[$1]).y - point.y)
        }).flatMap { index in
            return hypot(displayedPoint(forRaster: referenceTargetCorners[index]).x - point.x,
                         displayedPoint(forRaster: referenceTargetCorners[index]).y - point.y) <= 12
                ? index : nil
        }
    }

    private func focusTargetHitRegion(_ viewerPoint: CGPoint) -> Bool {
        if let focusTarget {
            let displayed = displayedPoint(forRaster: focusTarget)
            if hypot(displayed.x - viewerPoint.x, displayed.y - viewerPoint.y) <= 14 {
                return true
            }
        }
        guard deviceBoundary.count >= 3 else { return false }
        let path = CGMutablePath()
        for (index, point) in deviceBoundary.enumerated() {
            let displayed = displayedPoint(forRaster: point)
            if index == 0 { path.move(to: displayed) } else { path.addLine(to: displayed) }
        }
        path.closeSubpath()
        return path.contains(viewerPoint)
    }

    private func nearestTrackingPoint(to point: CGPoint) -> Int? {
        trackingPoints.indices.min(by: {
            hypot(displayedPoint(forRaster: trackingPoints[$0]).x - point.x,
                  displayedPoint(forRaster: trackingPoints[$0]).y - point.y)
                < hypot(displayedPoint(forRaster: trackingPoints[$1]).x - point.x,
                        displayedPoint(forRaster: trackingPoints[$1]).y - point.y)
        }).flatMap { index in
            hypot(displayedPoint(forRaster: trackingPoints[index]).x - point.x,
                  displayedPoint(forRaster: trackingPoints[index]).y - point.y) <= 12 ? index : nil
        }
    }

    private func nearestTrackingMeshCenter(to point: CGPoint) -> Int? {
        trackingMeshCenters.indices.min(by: {
            hypot(displayedPoint(forRaster: trackingMeshCenters[$0]).x - point.x,
                  displayedPoint(forRaster: trackingMeshCenters[$0]).y - point.y)
                < hypot(displayedPoint(forRaster: trackingMeshCenters[$1]).x - point.x,
                        displayedPoint(forRaster: trackingMeshCenters[$1]).y - point.y)
        }).flatMap { index in
            hypot(displayedPoint(forRaster: trackingMeshCenters[index]).x - point.x,
                  displayedPoint(forRaster: trackingMeshCenters[index]).y - point.y) <= 14 ? index : nil
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !sceneInteractionLocked else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        contextTrackingPointID = nil
        contextTrackingMeshID = nil
        let menu = NSMenu()
        if let index = nearestTrackingMeshCenter(to: location),
           trackingMeshCenterIDs.indices.contains(index) {
            contextTrackingMeshID = trackingMeshCenterIDs[index]
            let label = trackingMeshCenterLabels.indices.contains(index)
                ? trackingMeshCenterLabels[index] : "plano"
            menu.addItem(NSMenuItem(
                title: "Colocar y orientar Device en \(label)",
                action: #selector(placeDeviceOnContextPlane),
                keyEquivalent: ""
            ))
        } else if let index = nearestTrackingPoint(to: location),
                  trackingPointIDs.indices.contains(index) {
            contextTrackingPointID = trackingPointIDs[index]
            menu.addItem(NSMenuItem(
                title: "Colocar centro del Device en este punto",
                action: #selector(placeDeviceAtContextPoint),
                keyEquivalent: ""
            ))
        }
        guard !menu.items.isEmpty else { return nil }
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func placeDeviceAtContextPoint() {
        guard let id = contextTrackingPointID else { return }
        onPlaceDeviceAtTrackingPoint?(id)
    }

    @objc private func placeDeviceOnContextPlane() {
        guard let id = contextTrackingMeshID else { return }
        onPlaceDeviceOnTrackingPlane?(id)
    }

    private func nearestReflectionHandle(to point: CGPoint) -> Int? {
        reflectionHandles.indices.min(by: {
            hypot(displayedPoint(forRaster: reflectionHandles[$0]).x - point.x,
                  displayedPoint(forRaster: reflectionHandles[$0]).y - point.y)
                < hypot(displayedPoint(forRaster: reflectionHandles[$1]).x - point.x,
                        displayedPoint(forRaster: reflectionHandles[$1]).y - point.y)
        }).flatMap { index in
            hypot(displayedPoint(forRaster: reflectionHandles[index]).x - point.x,
                  displayedPoint(forRaster: reflectionHandles[index]).y - point.y) <= 14
                ? index : nil
        }
    }

    private func effectiveScale() -> CGFloat {
        let fittedScale = PreviewNavigationMath.fittedScale(
            texture: textureSize(), viewport: contentViewportSize()
        )
        if presentationFitted {
            Task { @MainActor [weak self] in
                self?.onFittedZoomChange?(Double(fittedScale))
            }
            return fittedScale
        }
        return CGFloat(presentationZoom)
    }

    private func contentViewportSize() -> CGSize {
        CGSize(width: max(1, bounds.width - 24), height: max(1, bounds.height - 58))
    }

    private func contentCenterY() -> CGFloat {
        bounds.midY - 10
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

private struct SceneAutosaveHistoryView: View {
    let target: SceneAutosaveHistoryTarget
    @ObservedObject var controller: SceneLibraryController
    let onRestore: (SceneAutosaveRevision) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.isDeletedScene ? "Recuperar escena eliminada" : "Historial de escena")
                .font(.headline)
            Text(target.sceneName).foregroundStyle(.secondary)
            let revisions = revisionsResult
            if revisions.isEmpty {
                ContentUnavailableView("Sin copias", systemImage: "clock.badge.xmark")
            } else {
                List(revisions) { revision in
                    HStack(spacing: 10) {
                        if let url = controller.autosaveThumbnailURL(for: revision),
                           let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFit()
                                .frame(width: 96, height: 54).background(.black)
                        }
                        VStack(alignment: .leading) {
                            Text(revision.savedAt.formatted(date: .abbreviated, time: .standard))
                            Text(revision.generatedEnvironmentFileName == nil
                                ? "Recursos externos por ruta" : "Incluye HDRI generado")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restaurar como nueva") { onRestore(revision) }
                    }
                }
                .frame(minHeight: 220)
            }
            HStack { Spacer(); Button("Cerrar") { dismiss() } }
        }
        .padding()
        .frame(width: 560, height: 420)
    }

    private var revisionsResult: [SceneAutosaveRevision] {
        (try? controller.autosaves(for: target)) ?? []
    }
}

private struct SceneLibraryItemView: View {
    let scene: SavedScene
    let thumbnailURL: URL?
    let onRename: (String) -> Void
    let onOpen: () -> Void
    let onUpdate: () -> Void
    let onDuplicate: () -> Void
    let onRender: () -> Void
    let onHistory: () -> Void
    let onDelete: () -> Void
    @State private var draftName: String

    init(
        scene: SavedScene,
        thumbnailURL: URL?,
        onRename: @escaping (String) -> Void,
        onOpen: @escaping () -> Void,
        onUpdate: @escaping () -> Void,
        onDuplicate: @escaping () -> Void,
        onRender: @escaping () -> Void,
        onHistory: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.scene = scene
        self.thumbnailURL = thumbnailURL
        self.onRename = onRename
        self.onOpen = onOpen
        self.onUpdate = onUpdate
        self.onDuplicate = onDuplicate
        self.onRender = onRender
        self.onHistory = onHistory
        self.onDelete = onDelete
        _draftName = State(initialValue: scene.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay { Image(systemName: "photo") }
                }
            }
            .frame(width: 150, height: 84)
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
            TextField("Nombre de escena", text: $draftName)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: 150)
                .onSubmit(commitName)
                .onChange(of: scene.name) { _, name in draftName = name }
        }
        .contextMenu {
            Button("Abrir escena", action: onOpen)
            Button("Actualizar con el estado actual", action: onUpdate)
            Button("Duplicar escena", action: onDuplicate)
            Button("Añadir a Render Queue…", action: onRender)
            Button("Historial…", action: onHistory)
            Divider()
            Button("Eliminar escena", role: .destructive, action: onDelete)
        }
        .onDisappear(perform: commitName)
    }

    private func commitName() {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != scene.name else {
            draftName = scene.name
            return
        }
        onRename(name)
    }
}

private struct NativeRenderButton: View {
    let state: NativeRenderButtonState
    let action: () -> Void

    private var color: Color {
        switch state {
        case .outdated: .red
        case .rendering, .cancelling: .orange
        case .complete: .green
        }
    }

    private var statusLabel: String {
        switch state {
        case .outdated: "desactualizado"
        case let .rendering(progress):
            "renderizando \(Int((progress * 100).rounded())) %, pulsar para cancelar"
        case .cancelling: "cancelando y esperando a Metal"
        case .complete: "completo y actualizado"
        }
    }

    var body: some View {
        switch state {
        case let .rendering(progress):
            HStack(spacing: 7) {
                ProgressView(value: progress, total: 1)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(Int((progress * 100).rounded())) %")
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .frame(width: 36, alignment: .trailing)
                Button(action: action) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("Cancelar render nativo")
            }
            .font(.system(size: 11, weight: .semibold))
            .accessibilityLabel("Render nativo, \(statusLabel)")
        case .cancelling:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Cancelando…")
                    .foregroundStyle(.orange)
            }
            .font(.system(size: 11, weight: .semibold))
            .accessibilityLabel("Render nativo, \(statusLabel)")
        case .outdated, .complete:
            Button(action: action) {
                HStack(spacing: 5) {
                    Image(systemName: state == .complete
                        ? "checkmark.circle.fill" : "arrow.clockwise.circle")
                    Text("Render nativo")
                }
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(color)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color.opacity(0.10))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(color, lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .help("Render nativo: \(statusLabel)")
            .accessibilityLabel("Render nativo, \(statusLabel)")
        }
    }
}
