import AppKit
import MetalKit
import ScreenSimulationMacUI
import ScreenSimulationPresentation
import StudioColor
import StudioMedia
import StudioVideoOutput
import SwiftUI
import UniformTypeIdentifiers

enum NativeTheme {
    static let accent = Color(red: 0.88, green: 0.57, blue: 0.16)
    static let nsAccent = NSColor(
        calibratedRed: 0.88, green: 0.57, blue: 0.16, alpha: 1
    )
}

private struct CopyableErrorDialog: View {
    let detail: String
    let dismiss: () -> Void

    @State private var selectableDetail: String
    @FocusState private var detailIsFocused: Bool

    init(detail: String, dismiss: @escaping () -> Void) {
        self.detail = detail
        self.dismiss = dismiss
        _selectableDetail = State(initialValue: detail)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SCREEN-SIMULATION")
                .font(.headline)
            Text("No se ha podido completar la operación. Puedes seleccionar el detalle o copiarlo completo.")
                .foregroundStyle(.secondary)
            TextEditor(text: $selectableDetail)
                .font(.system(.body, design: .monospaced))
                .focused($detailIsFocused)
                .frame(minWidth: 540, minHeight: 190)
                .padding(6)
                .background(
                    Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            HStack {
                Button("Copiar detalle") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail, forType: .string)
                }
                Spacer()
                Button("Aceptar", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { detailIsFocused = true }
    }
}

private struct SceneSettingsSelectionSheet: View {
    let title: String
    let explanation: String
    let available: Set<SceneSettingsBlock>
    let actionTitle: String
    let cancel: () -> Void
    let commit: (Set<SceneSettingsBlock>) -> Void

    @State private var selected: Set<SceneSettingsBlock>

    init(
        title: String,
        explanation: String,
        available: Set<SceneSettingsBlock>,
        actionTitle: String,
        cancel: @escaping () -> Void,
        commit: @escaping (Set<SceneSettingsBlock>) -> Void
    ) {
        self.title = title
        self.explanation = explanation
        self.available = available
        self.actionTitle = actionTitle
        self.cancel = cancel
        self.commit = commit
        _selected = State(initialValue: available)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(explanation).font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SceneSettingsBlock.allCases) { block in
                    Toggle(
                        isOn: Binding(
                            get: { selected.contains(block) },
                            set: { enabled in
                                if enabled { selected.insert(block) }
                                else { selected.remove(block) }
                            }
                        )
                    ) {
                        Label(block.label, systemImage: block.systemImage)
                    }
                    .disabled(!available.contains(block))
                }
            }
            Divider()
            HStack {
                Button("Cancelar", action: cancel)
                Spacer()
                Button(actionTitle) { commit(selected) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}

private struct WindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updateWindowTitle(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateWindowTitle(for: nsView)
    }

    private func updateWindowTitle(for view: NSView) {
        DispatchQueue.main.async { view.window?.title = title }
    }
}

struct ContentView: View {
    enum SceneTreeSelection: Hashable {
        case unclassified
        case production(UUID)
        case episode(UUID)
        case shot(UUID)
        case scene(UUID)
    }
    enum PendingSceneAction {
        case resetDefaults, removeImported3D, delete
    }
    enum LibraryDeletion: String {
        case pattern = "patrón"
        case testImage = "imagen de test"
        case renderPreset = "preset de render"
        case wipReviewPreset = "preset WIP Review"
        case device = "device preset"
        case coverGlass = "preset de Cover Glass"
        case camera = "perfil de cámara"
        case lens = "perfil de lente"
        case environment = "perfil de entorno"
    }
    enum WorkspacePage: String, CaseIterable, Identifiable {
        case scene = "Escena"
        case render = "Render"
        case settings = "Settings"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .scene: "checklist.checked"
            case .render: "list.bullet.rectangle"
            case .settings: "gearshape"
            }
        }
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
        case wipReview = "WIP Review"
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
            case .wipReview: "text.bubble"
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
    @StateObject private var reflectionEnvironmentPanel = ReflectionEnvironmentPanelController()
    @StateObject private var environmentReflectionFramingPanel = EnvironmentReflectionFramingPanelController()
    @StateObject private var trackingScenePanel = TrackingScenePanelController()
    @State private var page = WorkspacePage.scene
    @State private var settingsSection = SettingsSection.application
    @State private var libraryCollection = LibraryCollection.patterns
    @State private var pendingLibraryDeletion: LibraryDeletion?
    @State private var sidebarIsVisible = true
    @State private var pendingSceneAction: PendingSceneAction?
    @State private var pendingScene: SavedScene?
    @State private var renderDraft: RenderDraft?
    @State private var autosaveHistoryTarget: SceneAutosaveHistoryTarget?
    @State private var sceneTreeSelection: SceneTreeSelection? = .unclassified
    @State private var expandedSceneTreeBranches: Set<SceneTreeSelection> = []
    @State private var settingsCopyRequest: SceneSettingsCopyRequest?
    @State private var settingsPasteRequest: SceneSettingsPasteRequest?
    @State private var pendingSettingsPaste: PendingSettingsPaste?

    private struct SceneSettingsCopyRequest: Identifiable {
        let scene: SavedScene
        var id: UUID { scene.id }
    }

    private struct SceneSettingsPasteRequest: Identifiable {
        let scene: SavedScene
        let clipboard: SceneSettingsClipboardDocument
        var id: UUID { scene.id }
    }

    private struct PendingSettingsPaste: Identifiable {
        let scene: SavedScene
        let clipboard: SceneSettingsClipboardDocument
        let blocks: Set<SceneSettingsBlock>
        var id: UUID { scene.id }
    }

    private struct RenderDraft: Identifiable {
        let scene: SavedScene
        let sourceJob: NativeOutputQueueController.RenderJob?
        let historicalSnapshot: Bool
        var id: String {
            "\(scene.id.uuidString)-\(sourceJob?.id.uuidString ?? "new")-\(historicalSnapshot)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .scene: testWorkspace
                case .render: renderWorkspace
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
        .background(WindowTitleUpdater(title: activeSceneTitle))
        .toolbar { workspaceToolbar }
        .onAppear {
            model.configureSceneEnvironmentPersistence { sceneID, data in
                try scenes.replaceGeneratedEnvironment(sceneID: sceneID, data: data)
            }
            model.configureActiveScenePersistence { sceneID, capture in
                guard let scene = scenes.scene(id: sceneID) else {
                    throw SceneLibraryError.inaccessible("La escena activa ya no existe.")
                }
                try scenes.update(scene, capture: capture)
            }
            if model.resolvedDevice == nil,
               let first = library.document.devices.first,
               let cover = library.document.coverGlasses.first(
                    where: { $0.id == first.value.defaultCoverGlassPresetID }
               ) {
                model.selectDevice(first.value, coverGlass: cover.value, amount: 0)
            }
            activateWorkspacePage(page)
        }
        .onChange(of: library.document) { _, _ in
            model.refreshActiveSceneFromGlobalLibrary()
        }
        .onChange(of: page) { _, destination in
            activateWorkspacePage(destination)
        }
        .sheet(
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            CopyableErrorDialog(detail: model.errorMessage ?? "Error sin detalle.") {
                model.errorMessage = nil
            }
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
        .sheet(item: $settingsCopyRequest) { request in
            SceneSettingsSelectionSheet(
                title: "Copiar settings de ‘\(request.scene.name)’",
                explanation: "Selecciona las tarjetas que estarán disponibles al pegar.",
                available: Set(SceneSettingsBlock.allCases),
                actionTitle: "Copiar settings",
                cancel: { settingsCopyRequest = nil },
                commit: { blocks in copySceneSettings(request.scene, blocks: blocks) }
            )
        }
        .sheet(item: $settingsPasteRequest) { request in
            SceneSettingsSelectionSheet(
                title: "Pegar settings en ‘\(request.scene.name)’",
                explanation: "Las tarjetas que no se copiaron permanecen visibles y deshabilitadas.",
                available: Set(request.clipboard.includedBlocks),
                actionTitle: "Revisar cambios",
                cancel: { settingsPasteRequest = nil },
                commit: { blocks in
                    settingsPasteRequest = nil
                    pendingSettingsPaste = PendingSettingsPaste(
                        scene: request.scene, clipboard: request.clipboard, blocks: blocks
                    )
                }
            )
        }
        .confirmationDialog(
            pendingSettingsPaste.map {
                "¿Aplicar settings a ‘\($0.scene.name)’?"
            } ?? "¿Aplicar settings?",
            isPresented: Binding(
                get: { pendingSettingsPaste != nil },
                set: { if !$0 { pendingSettingsPaste = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Aplicar settings", role: .destructive) {
                if let request = pendingSettingsPaste { applySceneSettings(request) }
            }
            Button("Cancelar", role: .cancel) { pendingSettingsPaste = nil }
        } message: {
            if let request = pendingSettingsPaste {
                let labels = SceneSettingsBlock.allCases
                    .filter(request.blocks.contains).map(\.label).joined(separator: ", ")
                Text(
                    "Origen: \(request.clipboard.sourceSceneName). Se reemplazarán: \(labels)."
                    + (request.clipboard.containsAnimation
                        && request.blocks.contains(.cameraTransform)
                        ? " La transformación de Cámara contiene animación y se copiará completa."
                        : "")
                )
            }
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
                case .wipReviewPreset: library.removeSelectedWIPReviewPreset()
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
                Button(
                    sceneConfirmationButton(action),
                    role: action == .delete || action == .resetDefaults
                        || action == .removeImported3D ? .destructive : nil
                ) {
                    performConfirmedSceneAction(action, scene: scene)
                }
            }
            Button("Cancelar", role: .cancel) {
                pendingSceneAction = nil
                pendingScene = nil
            }
        } message: {
            if pendingSceneAction == .resetDefaults {
                Text("Se conservarán únicamente Source y Reference. El resto quedará como en una escena nueva.")
            } else if pendingSceneAction == .removeImported3D {
                Text("Se eliminarán la cámara importada, la nube de puntos, las geometrías, su visibilidad y su escala. Volverá a aplicarse la cámara manual de esta escena.")
            } else {
                Text("Esta operación elimina la escena de la biblioteca.")
            }
        }
    }

    private func activateWorkspacePage(_ destination: WorkspacePage) {
        model.setModelPageActive(false)
        model.setTestPageActive(destination == .scene)
    }

    private var renderWorkspace: some View {
        HSplitView {
            if sidebarIsVisible {
                VSplitView {
                    sceneLibraryPanel
                        .frame(minHeight: 170, idealHeight: 360, maxHeight: 720)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Group {
                        if let renderDraft {
                            renderOptionsPanel(renderDraft)
                        } else {
                            ContentUnavailableView(
                                "Selecciona una escena",
                                systemImage: "film.stack",
                                description: Text("Usa Render en el menú de una escena guardada para preparar sus ajustes.")
                            )
                        }
                    }
                    .frame(minHeight: 300)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 560, idealWidth: 680, maxWidth: 900)
            }
            queuePanel
                .frame(minWidth: 640, minHeight: 480)
        }
        .background(SplitAutosaveProbe(name: "ScreenSimulation.Native.Render"))
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
            outputInspectorSections
        }
        .formStyle(.grouped)
    }

    private var testWorkspace: some View {
        HSplitView {
            if sidebarIsVisible {
                VSplitView {
                    sceneLibraryPanel
                        .frame(minHeight: 170, idealHeight: 360, maxHeight: 720)
                    testSetupPanel
                }
                .frame(minWidth: 560, idealWidth: 680, maxWidth: 900)
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
                case .wipReview: wipReviewLibrary
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
                        CommittedTextField(label: "Nombre", value: image.name) { value in
                            library.updateSelectedImage { $0.name = value }
                        }
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
                        CommittedTextField(label: "Nombre", value: item.name) { value in
                            library.updateSelectedPattern { $0.name = value }
                        }
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
                        CommittedTextField(label: "Nombre", value: preset.name) { value in
                            library.updateSelectedPreset { $0.name = value }
                        }
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
                        CommittedNumberField(label: "Peak nits", value: preset.peakNits) { value in
                            library.updateSelectedPreset { $0.peakNits = value }
                        }
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

    private var wipReviewLibrary: some View {
        VSplitView {
            VStack(spacing: 0) {
                List(selection: $library.selectedWIPReviewPresetID) {
                    ForEach(library.document.wipReviewPresets) { preset in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(preset.name)
                                Text("\(preset.outputColorSpace.label) · \(preset.reviewRaster.rawValue)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if preset.isLocked { Image(systemName: "lock.fill") }
                        }.tag(preset.id)
                    }
                }
                HStack {
                    Button(action: library.addWIPReviewPreset) { Image(systemName: "plus") }
                    Button(action: library.duplicateSelectedWIPReviewPreset) {
                        Image(systemName: "plus.square.on.square")
                    }.disabled(library.selectedWIPReviewPresetID == nil)
                    Button(action: library.unlockSelectedWIPReviewPreset) {
                        Image(systemName: "lock.open")
                    }.disabled(library.selectedWIPReviewPresetItem?.isLocked != true)
                    Button { pendingLibraryDeletion = .wipReviewPreset } label: {
                        Image(systemName: "trash")
                    }.disabled(library.selectedWIPReviewPresetItem?.isLocked != false)
                    Spacer()
                }.buttonStyle(.borderless).padding(8)
            }.frame(maxWidth: .infinity, minHeight: 160, idealHeight: 240)
            if let item = library.selectedWIPReviewPresetItem {
                Form {
                    Section("Identidad y color") {
                        CommittedTextField(label: "Nombre", value: item.name) { value in
                            library.updateSelectedWIPReviewPreset { $0.name = value }
                        }
                        Picker("Output Color Space", selection: Binding(
                            get: { item.outputColorSpace },
                            set: { value in library.updateSelectedWIPReviewPreset { $0.outputColorSpace = value } }
                        )) {
                            ForEach(StudioWIPOutputColorSpace.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Review Raster", selection: Binding(
                            get: { item.reviewRaster },
                            set: { value in
                                library.updateSelectedWIPReviewPreset {
                                    $0.reviewRaster = value
                                    if value == .custom {
                                        $0.customWidth = $0.customWidth ?? 1920
                                        $0.customHeight = $0.customHeight ?? 1080
                                    } else { $0.customWidth = nil; $0.customHeight = nil }
                                }
                            }
                        )) { ForEach(StudioWIPReviewRaster.allCases) { Text($0.rawValue).tag($0) } }
                        if item.reviewRaster == .custom {
                            CommittedNumberField(label: "Ancho", value: item.customWidth ?? 1920) { value in
                                library.updateSelectedWIPReviewPreset { $0.customWidth = value }
                            }
                            CommittedNumberField(label: "Alto", value: item.customHeight ?? 1080) { value in
                                library.updateSelectedWIPReviewPreset { $0.customHeight = value }
                            }
                        }
                        Picker("Placement", selection: Binding(
                            get: { item.placement },
                            set: { value in library.updateSelectedWIPReviewPreset { $0.placement = value } }
                        )) { ForEach(StudioWIPPlacement.allCases) { Text($0.rawValue).tag($0) } }
                        Picker("Filtro", selection: Binding(
                            get: { item.resampleFilter },
                            set: { value in library.updateSelectedWIPReviewPreset { $0.resampleFilter = value } }
                        )) { ForEach(StudioWIPResampleFilter.allCases) { Text($0.rawValue).tag($0) } }
                        wipColorEditor("Canvas RGBA", item.canvasColor, keyPath: \.canvasColor)
                    }
                    Section("Blanking") {
                        Toggle("Activado", isOn: Binding(
                            get: { item.blankingEnabled },
                            set: { value in library.updateSelectedWIPReviewPreset { $0.blankingEnabled = value } }
                        ))
                        Picker("Aspect", selection: Binding(
                            get: { item.blankingAspect },
                            set: { value in
                                library.updateSelectedWIPReviewPreset {
                                    $0.blankingAspect = value
                                    $0.customBlankingAspect = value == .custom ? ($0.customBlankingAspect ?? 2.39) : nil
                                }
                            }
                        )) { ForEach(StudioWIPBlankingAspect.allCases) { Text($0.rawValue).tag($0) } }
                        if item.blankingAspect == .custom {
                            wipDoubleField("Aspect personalizado", item.customBlankingAspect ?? 2.39) {
                                $0.customBlankingAspect = $1
                            }
                        }
                        wipDoubleField("Opacidad", item.blankingOpacity, keyPath: \.blankingOpacity)
                        wipColorEditor("Color RGBA", item.blankingColor, keyPath: \.blankingColor)
                    }
                    Section("Tipografía y gráficos") {
                        CommittedTextField(label: "Familia", value: item.fontFamily) { value in
                            library.updateSelectedWIPReviewPreset { $0.fontFamily = value }
                        }
                        Picker("Estilo", selection: Binding(
                            get: { item.fontStyle },
                            set: { value in library.updateSelectedWIPReviewPreset { $0.fontStyle = value } }
                        )) { ForEach(StudioWIPFontStyle.allCases) { Text($0.rawValue).tag($0) } }
                        wipDoubleField("Tamaño normalizado", item.fontSize, keyPath: \.fontSize)
                        wipDoubleField("Opacidad texto", item.textOpacity, keyPath: \.textOpacity)
                        wipColorEditor("Texto RGBA", item.textColor, keyPath: \.textColor)
                        Picker("Graphics White", selection: Binding(
                            get: { item.graphicsWhiteMode },
                            set: { value in library.updateSelectedWIPReviewPreset { $0.graphicsWhiteMode = value } }
                        )) { ForEach(StudioWIPGraphicsWhiteMode.allCases) { Text($0.rawValue).tag($0) } }
                        wipDoubleField("Graphics White nit", item.graphicsWhiteNits, keyPath: \.graphicsWhiteNits)
                        wipDoubleField("HLG Peak nit", item.hlgPeakNits, keyPath: \.hlgPeakNits)
                        wipDoubleField("Padding izquierdo", item.paddingLeft, keyPath: \.paddingLeft)
                        wipDoubleField("Padding derecho", item.paddingRight, keyPath: \.paddingRight)
                        wipDoubleField("Padding superior", item.paddingTop, keyPath: \.paddingTop)
                        wipDoubleField("Padding inferior", item.paddingBottom, keyPath: \.paddingBottom)
                        Toggle("Outline", isOn: Binding(
                            get: { item.outlineEnabled },
                            set: { value in library.updateSelectedWIPReviewPreset { $0.outlineEnabled = value } }
                        ))
                        wipDoubleField("Outline ancho", item.outlineWidth, keyPath: \.outlineWidth)
                        wipDoubleField("Outline opacidad", item.outlineOpacity, keyPath: \.outlineOpacity)
                        wipColorEditor("Outline RGBA", item.outlineColor, keyPath: \.outlineColor)
                        Toggle("Sombra", isOn: Binding(
                            get: { item.shadowEnabled },
                            set: { value in library.updateSelectedWIPReviewPreset { $0.shadowEnabled = value } }
                        ))
                        wipDoubleField("Sombra offset X", item.shadowOffsetX, keyPath: \.shadowOffsetX)
                        wipDoubleField("Sombra offset Y", item.shadowOffsetY, keyPath: \.shadowOffsetY)
                        wipDoubleField("Sombra suavidad", item.shadowSoftness, keyPath: \.shadowSoftness)
                        wipDoubleField("Sombra opacidad", item.shadowOpacity, keyPath: \.shadowOpacity)
                        wipColorEditor("Sombra RGBA", item.shadowColor, keyPath: \.shadowColor)
                    }
                    Section("Timing") {
                        CommittedNumberField(label: "Frame Relative Base", value: item.frameRelativeBase) { value in
                            library.updateSelectedWIPReviewPreset { $0.frameRelativeBase = value }
                        }
                        CommittedNumberField(label: "Frame Start", value: item.frameStart) { value in
                            library.updateSelectedWIPReviewPreset { $0.frameStart = value }
                        }
                        Picker("FPS", selection: Binding(
                            get: { item.frameRateMode },
                            set: { value in library.updateSelectedWIPReviewPreset { $0.frameRateMode = value } }
                        )) { ForEach(StudioWIPFrameRateMode.allCases) { Text($0.rawValue).tag($0) } }
                        if item.frameRateMode == .override {
                            wipDoubleField("FPS Override", item.frameRateOverride, keyPath: \.frameRateOverride)
                        }
                        CommittedTextField(label: "Timecode Start", value: item.timecodeStart) { value in
                            library.updateSelectedWIPReviewPreset { $0.timecodeStart = value }
                        }
                        CommittedTextField(label: "Review Date", value: item.reviewDate) { value in
                            library.updateSelectedWIPReviewPreset { $0.reviewDate = value }
                        }
                    }
                    Section("Zonas") {
                        ForEach(item.zones) { zone in
                            HStack {
                                Toggle(zone.position.rawValue, isOn: Binding(
                                    get: { zone.enabled },
                                    set: { value in updateWIPZone(zone.position) { $0.enabled = value } }
                                ))
                                CommittedTextField(label: "Texto", value: zone.prefix) { value in
                                    updateWIPZone(zone.position) { $0.prefix = value }
                                }
                                Picker("Campo", selection: Binding(
                                    get: { zone.calculatedField },
                                    set: { value in updateWIPZone(zone.position) { $0.calculatedField = value } }
                                )) { ForEach(StudioWIPCalculatedField.allCases) { Text($0.label).tag($0) } }
                                .labelsHidden()
                            }
                            HStack {
                                wipZoneDoubleField("Offset X", zone, keyPath: \.offsetX)
                                wipZoneDoubleField("Offset Y", zone, keyPath: \.offsetY)
                            }
                            HStack {
                                Toggle("Tamaño propio", isOn: Binding(
                                    get: { zone.fontSize.enabled },
                                    set: { value in updateWIPZone(zone.position) { $0.fontSize.enabled = value } }
                                ))
                                CommittedNumberField(label: "Tamaño", value: zone.fontSize.value) { value in
                                    updateWIPZone(zone.position) { $0.fontSize.value = value }
                                }
                                Toggle("Opacidad propia", isOn: Binding(
                                    get: { zone.opacity.enabled },
                                    set: { value in updateWIPZone(zone.position) { $0.opacity.enabled = value } }
                                ))
                                CommittedNumberField(label: "Opacidad", value: zone.opacity.value) { value in
                                    updateWIPZone(zone.position) { $0.opacity.value = value }
                                }
                            }
                            Toggle("Color propio", isOn: Binding(
                                get: { zone.color.enabled },
                                set: { value in updateWIPZone(zone.position) { $0.color.enabled = value } }
                            ))
                            HStack {
                                ForEach(["R", "G", "B", "A"], id: \.self) { channel in
                                    CommittedNumberField(
                                        label: channel,
                                        value: wipZoneColorComponent(zone.color.value, channel: channel)
                                    ) { value in
                                        updateWIPZone(zone.position) {
                                            setWIPZoneColorComponent(&$0.color.value, channel: channel, value: value)
                                        }
                                    }
                                }
                            }
                        }
                        Text("Los campos calculados de la app —incluido File Name— se convierten en texto literal antes de invocar el OFX; el plugin recibe Calculated Field = None.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped).disabled(item.isLocked)
            } else { ContentUnavailableView("Sin preset WIP Review", systemImage: "text.bubble") }
        }
    }

    private func updateWIPZone(
        _ position: StudioWIPZonePosition,
        mutation: (inout StudioWIPReviewZone) -> Void
    ) {
        library.updateSelectedWIPReviewPreset { preset in
            guard let index = preset.zones.firstIndex(where: { $0.position == position }) else { return }
            mutation(&preset.zones[index])
        }
    }

    private func wipDoubleField(
        _ label: String,
        _ value: Double,
        keyPath: WritableKeyPath<StudioWIPReviewPreset, Double>
    ) -> some View {
        CommittedNumberField(label: label, value: value) { newValue in
            library.updateSelectedWIPReviewPreset { $0[keyPath: keyPath] = newValue }
        }
    }

    private func wipDoubleField(
        _ label: String,
        _ value: Double,
        mutation: @escaping (inout StudioWIPReviewPreset, Double) -> Void
    ) -> some View {
        CommittedNumberField(label: label, value: value) { newValue in
            library.updateSelectedWIPReviewPreset { mutation(&$0, newValue) }
        }
    }

    private func wipColorEditor(
        _ label: String,
        _ color: StudioReviewColor,
        keyPath: WritableKeyPath<StudioWIPReviewPreset, StudioReviewColor>
    ) -> some View {
        HStack {
            Text(label)
            ForEach(["R", "G", "B", "A"], id: \.self) { channel in
                CommittedNumberField(
                    label: channel,
                    value: wipZoneColorComponent(color, channel: channel)
                ) { value in
                    library.updateSelectedWIPReviewPreset {
                        setWIPZoneColorComponent(&$0[keyPath: keyPath], channel: channel, value: value)
                    }
                }
                .frame(minWidth: 42)
            }
        }
    }

    private func wipZoneDoubleField(
        _ label: String,
        _ zone: StudioWIPReviewZone,
        keyPath: WritableKeyPath<StudioWIPReviewZone, Double>
    ) -> some View {
        CommittedNumberField(label: label, value: zone[keyPath: keyPath]) { value in
            updateWIPZone(zone.position) { $0[keyPath: keyPath] = value }
        }
    }

    private func wipZoneColorComponent(
        _ color: StudioReviewColor,
        channel: String
    ) -> Double {
        switch channel {
        case "R": color.red
        case "G": color.green
        case "B": color.blue
        default: color.alpha
        }
    }

    private func setWIPZoneColorComponent(
        _ color: inout StudioReviewColor,
        channel: String,
        value: Double
    ) {
        switch channel {
        case "R": color.red = value
        case "G": color.green = value
        case "B": color.blue = value
        default: color.alpha = value
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
                        CommittedTextField(label: "Nombre", value: camera.name) { value in
                            library.updateSelectedCamera { $0.name = value }
                        }
                        CommittedNumberField(label: "Gate ancho (mm)", value: camera.gateWidthMillimeters) { value in
                            library.updateSelectedCamera { $0.gateWidthMillimeters = value }
                        }
                        CommittedNumberField(label: "Gate alto (mm)", value: camera.gateHeightMillimeters) { value in
                            library.updateSelectedCamera { $0.gateHeightMillimeters = value }
                        }
                        CommittedNumberField(label: "F-stop predeterminado", value: camera.defaultFStop) { value in
                            library.updateSelectedCamera { $0.defaultFStop = value }
                        }
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
                        CommittedTextField(label: "Nombre", value: lens.name) { value in
                            library.updateSelectedLens { $0.name = value }
                        }
                        CommittedNumberField(label: "Focal nominal (mm)", value: lens.nominalFocalLengthMillimeters) { value in
                            library.updateSelectedLens { $0.nominalFocalLengthMillimeters = value }
                        }
                        CommittedNumberField(label: "Viñeteo", value: lens.vignettingStrength) { value in
                            library.updateSelectedLens { $0.vignettingStrength = value }
                        }
                        CommittedNumberField(label: "Veiling glare", value: lens.veilingGlareFraction) { value in
                            library.updateSelectedLens { $0.veilingGlareFraction = value }
                        }
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
                        CommittedTextField(label: "Nombre", value: profile.name) { value in
                            library.updateSelectedEnvironment { $0.name = value }
                        }
                        CommittedNumberField(label: "Radio angular key (°)", value: profile.environment.keyAngularRadiusDegrees) { value in
                            library.updateSelectedEnvironment { $0.environment.keyAngularRadiusDegrees = value }
                        }
                        CommittedNumberField(label: "Rotación X (°)", value: profile.environment.rotationXDegrees) { value in
                            library.updateSelectedEnvironment { $0.environment.rotationXDegrees = value }
                        }
                        CommittedNumberField(label: "Rotación Y (°)", value: profile.environment.rotationYDegrees) { value in
                            library.updateSelectedEnvironment { $0.environment.rotationYDegrees = value }
                        }
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
                CommittedTextField(label: "Nombre", value: cover.name) { value in
                    library.updateSelectedCoverGlass { $0.name = value }
                }
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
                CommittedNumberField(label: "Semilla", value: cover.agMicrotextureSeed) { value in
                    library.updateSelectedCoverGlass { $0.agMicrotextureSeed = value }
                }
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
                    CommittedNumberField(
                        label: channel.element,
                        value: cover.absorptionPerMillimeter[channel.offset]
                    ) { value in
                        library.updateSelectedCoverGlass {
                            $0.absorptionPerMillimeter[channel.offset] = value
                        }
                    }
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
        CommittedNumberField(label: label, value: value) { newValue in
            library.updateSelectedCoverGlass { update(&$0, newValue) }
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
            case .vfxLog:
                preset.peakNits = 0
                preset.display = nil
                preset.view = nil
                preset.format = .proRes4444XQ
                preset.pixelEncoding = .rgb44412
                preset.signalRange = .video
                preset.alpha = .straight
            }
        }
    }

    private func deviceEditor(_ device: DeviceDefinition) -> some View {
        Form {
            Section("Identidad") {
                CommittedTextField(label: "Nombre", value: device.name) { value in
                    library.updateSelectedDevice { $0.name = value }
                }
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
                CommittedNumberField(label: "Resolución nativa — ancho (px)", value: device.nativeWidth) { value in
                    library.updateSelectedDevice { $0.nativeWidth = value }
                }
                CommittedNumberField(label: "Resolución nativa — alto (px)", value: device.nativeHeight) { value in
                    library.updateSelectedDevice { $0.nativeHeight = value }
                }
                CommittedNumberField(label: "Anchura activa (m)", value: device.activeWidthMeters) { value in
                    library.updateSelectedDevice { $0.activeWidthMeters = value }
                }
                CommittedNumberField(label: "Altura activa (m)", value: device.activeHeightMeters) { value in
                    library.updateSelectedDevice { $0.activeHeightMeters = value }
                }
                CommittedNumberField(label: "Corner Radius (mm)", value: device.cornerRadiusMeters * 1_000) { value in
                    library.updateSelectedDevice { $0.cornerRadiusMeters = value / 1_000 }
                }
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
                CommittedNumberField(label: "EOTF gamma", value: device.eotfGamma) { value in
                    library.updateSelectedDevice { $0.eotfGamma = value }
                }
                CommittedNumberField(label: "Negro (nits)", value: device.blackLevelNits) { value in
                    library.updateSelectedDevice { $0.blackLevelNits = value }
                }
                CommittedNumberField(label: "White Luminance mínima (cd/m²)", value: device.minimumWhiteLuminance) { value in
                    library.updateSelectedDevice { $0.minimumWhiteLuminance = value }
                }
                CommittedNumberField(label: "White Luminance máxima (cd/m²)", value: device.maximumWhiteLuminance) { value in
                    library.updateSelectedDevice { $0.maximumWhiteLuminance = value }
                }
                CommittedNumberField(label: "Paso White Luminance (cd/m²)", value: device.whiteLuminanceStep) { value in
                    library.updateSelectedDevice { $0.whiteLuminanceStep = value }
                }
                CommittedNumberField(label: "White Luminance (cd/m²)", value: device.whiteLevelNits) { value in
                    library.updateSelectedDevice { $0.whiteLevelNits = value }
                }
                CommittedTextField(label: "Base del blanco", value: device.whiteBasis) { value in
                    library.updateSelectedDevice { $0.whiteBasis = value }
                }
            }

            Section("Subpíxeles") {
                Picker("Orden", selection: Binding(
                    get: { device.stripeLayout },
                    set: { value in library.updateSelectedDevice { $0.stripeLayout = value } }
                )) {
                    ForEach(DeviceStripeLayout.allCases) { Text($0.rawValue).tag($0) }
                }
                CommittedNumberField(label: "Black matrix", value: device.blackMatrixFraction) { value in
                    library.updateSelectedDevice { $0.blackMatrixFraction = value }
                }
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
                    CommittedNumberField(
                        label: "Potencia angular \(item.element)",
                        value: device.angularEmissionPower[item.offset]
                    ) { value in
                        library.updateSelectedDevice {
                            $0.angularEmissionPower[item.offset] = value
                        }
                    }
                }
                CommittedNumberField(
                    label: "Flicker residual (Hz)",
                    value: 1 / device.residualFlickerPeriod.seconds
                ) { value in
                    library.updateSelectedDevice {
                        $0.residualFlickerPeriod = .init(
                            numerator: 1,
                            denominator: UInt32(max(1, value.rounded()))
                        )
                    }
                }
                CommittedNumberField(label: "Amplitud residual", value: device.residualFlickerAmplitude) { value in
                    library.updateSelectedDevice {
                        $0.residualFlickerAmplitude = value
                    }
                }
                CommittedNumberField(
                    label: "Banding (Hz)",
                    value: 1 / device.bandingPeriod.seconds
                ) { value in
                    library.updateSelectedDevice {
                        let denominator = UInt32(max(1, value.rounded()))
                        $0.bandingPeriod = .init(numerator: 1, denominator: denominator)
                        $0.bandingOnDuration = .init(
                            numerator: 1,
                            denominator: denominator * 2
                        )
                    }
                }
                CommittedNumberField(label: "Cantidad de banding", value: device.bandingAmount) { value in
                    library.updateSelectedDevice { $0.bandingAmount = value }
                }
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
                CommittedNumberField(label: "x", value: value.x) {
                    update(.init(x: $0, y: value.y))
                }
                CommittedNumberField(label: "y", value: value.y) {
                    update(.init(x: value.x, y: $0))
                }
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
                .disabled(page != .scene)
                .help("Abrir un vídeo o una imagen")
            Button {
                trackingScenePanel.toggle(model: model, undoManager: undoManager)
            } label: {
                Label("Tracking 3D", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .nativeActionState(.init(
                available: page == .scene,
                active: trackingScenePanel.isVisible
            ))
            .help("Importar cámara, point cloud, geometrías y lente desde Fusion")
            Button("Frame", action: model.renderCurrentFrame)
                .disabled(page != .scene || model.metalFrame == nil)
                .help("Renderizar el frame actual horneando la transformación del visor")
            Button("Render", action: model.runQueue)
                .disabled(page != .render || !model.jobs.contains { $0.state == .pending })
                .help("Procesar los trabajos en cola")
        }
    }

    private var sceneLibraryPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Escenas", systemImage: "rectangle.stack")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Nueva Producción manual…") { createManualProduction() }
                    Button("Asociar production.json…") { associateNewProduction() }
                } label: {
                    Label("Estructura", systemImage: "folder.badge.plus")
                        .labelStyle(.iconOnly)
                }
                .disabled(scenes.blockedError != nil)
                Button {
                    trackingScenePanel.toggle(model: model, undoManager: undoManager)
                } label: {
                    Label("Tracking 3D", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .controlSize(.small)
                .nativeActionState(.init(
                    available: page == .scene,
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
            } else if scenes.document.scenes.isEmpty && scenes.document.productions.isEmpty {
                ContentUnavailableView(
                    "Sin escenas",
                    systemImage: "rectangle.stack.badge.plus",
                    description: Text("Guarda el estado activo con el botón +.")
                )
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Producciones").font(.headline)
                                Text("Episodios, Planos y Escenas")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button("Nueva Producción manual…") { createManualProduction() }
                                Button("Asociar production.json…") { associateNewProduction() }
                            } label: {
                                Image(systemName: "plus")
                            }
                            .menuStyle(.borderlessButton)
                            .help("Crear Producción")
                        }
                        .padding(10)
                        Divider()
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                            DisclosureGroup(isExpanded: sceneTreeExpansionBinding(.unclassified)) {
                                ForEach(scenes.sortedScenes(scenes.document.unclassifiedSceneIDs)) { scene in
                                    compactSceneTreeRow(scene).padding(.leading, 18)
                                }
                            } label: {
                                sceneTreeRow(
                                    .unclassified,
                                    title: "Sin clasificar",
                                    detail: "\(scenes.document.unclassifiedSceneIDs.count) escenas libres",
                                    icon: "tray",
                                    onOpen: { toggleSceneTreeBranch(.unclassified) }
                                )
                            }
                            .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                acceptSceneDrop(providers, shotID: nil)
                            }
                            ForEach(scenes.document.productions) { production in
                                DisclosureGroup(
                                    isExpanded: sceneTreeExpansionBinding(.production(production.id))
                                ) {
                                    ForEach(production.episodes) { episode in
                                        DisclosureGroup(
                                            isExpanded: sceneTreeExpansionBinding(.episode(episode.id))
                                        ) {
                                            ForEach(episode.shots) { shot in
                                                DisclosureGroup(
                                                    isExpanded: sceneTreeExpansionBinding(.shot(shot.id))
                                                ) {
                                                    ForEach(scenes.sortedScenes(shot.scenes.map(\.sceneID))) { scene in
                                                        compactSceneTreeRow(scene).padding(.leading, 54)
                                                    }
                                                } label: {
                                                    sceneTreeRow(
                                                        .shot(shot.id), title: shot.name,
                                                        detail: shot.associationState == .associated
                                                            ? shot.externalReference?.canonicalName
                                                            : "Libre · Salida manual",
                                                        icon: "camera",
                                                        onAdd: { createScene(in: shot) },
                                                        onOpen: { toggleSceneTreeBranch(.shot(shot.id)) }
                                                    )
                                                }
                                                .padding(.leading, 36)
                                                .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                                                    acceptSceneDrop(providers, shotID: shot.id)
                                                }
                                            }
                                        } label: {
                                            sceneTreeRow(
                                                .episode(episode.id), title: episode.name,
                                                detail: episode.associationState == .associated
                                                    ? episode.externalReference.map {
                                                        "Episodio \(String(format: "%03d", $0.episodeOrder))"
                                                    }
                                                    : "Libre · Salida manual",
                                                icon: "rectangle.stack",
                                                onAdd: { createShot(in: episode) },
                                                onOpen: { toggleSceneTreeBranch(.episode(episode.id)) }
                                            )
                                        }
                                        .padding(.leading, 18)
                                    }
                                } label: {
                                    sceneTreeRow(
                                        .production(production.id), title: production.name,
                                        detail: production.association == nil
                                            ? "Manual\(production.seasonSlug.isEmpty ? "" : " · \(production.seasonSlug)")"
                                            : "Shot Manager · \(production.seasonSlug)",
                                        icon: "building.2",
                                        onAdd: { createEpisode(in: production) },
                                        onOpen: { toggleSceneTreeBranch(.production(production.id)) }
                                    )
                                }
                            }
                            }
                            .padding(8)
                        }
                    }
                    .background(
                        Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .padding(8)
                    .frame(minWidth: 280, idealWidth: 340)
                    sceneTreeInspector
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.vertical, 8).padding(.trailing, 8)
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sceneConfirmationTitle: String {
        guard let action = pendingSceneAction, let scene = pendingScene else { return "Escena" }
        return switch action {
        case .resetDefaults: "¿Restaurar ‘\(scene.name)’ a sus valores por defecto?"
        case .removeImported3D: "¿Eliminar el 3D importado de ‘\(scene.name)’?"
        case .delete: "¿Eliminar ‘\(scene.name)’?"
        }
    }

    private func sceneTreeRow(
        _ selection: SceneTreeSelection, title: String, detail: String?, icon: String,
        onAdd: (() -> Void)? = nil, imported3DScene: SavedScene? = nil,
        onOpen: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .frame(width: 17)
                .foregroundStyle(sceneTreeSelection == selection ? .white : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium).lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(
                        sceneTreeSelection == selection ? .white.opacity(0.82) : .secondary
                    ).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let scene = imported3DScene, sceneOwnsImported3D(scene) {
                Label("3D importado", systemImage: "cube.transparent")
                    .font(.caption2)
                    .foregroundStyle(
                        sceneTreeSelection == selection ? .white.opacity(0.9) : .secondary
                    )
                    .fixedSize()
                Button {
                    requestSceneAction(.removeImported3D, scene: scene)
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(sceneTreeSelection == selection ? .white : .red)
                .help("Eliminar el 3D importado de esta escena")
            }
            if let onAdd {
                Button(action: onAdd) { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(sceneTreeSelection == selection ? .white : .secondary)
                    .help("Añadir nivel hijo")
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            sceneTreeSelection == selection ? Color.accentColor : .clear,
            in: RoundedRectangle(cornerRadius: 5)
        )
        .onTapGesture {
            sceneTreeSelection = selection
            onOpen?()
        }
    }

    private func sceneTreeExpansionBinding(
        _ selection: SceneTreeSelection
    ) -> Binding<Bool> {
        Binding(
            get: { expandedSceneTreeBranches.contains(selection) },
            set: { expanded in
                if expanded { expandedSceneTreeBranches.insert(selection) }
                else { expandedSceneTreeBranches.remove(selection) }
            }
        )
    }

    private func toggleSceneTreeBranch(_ selection: SceneTreeSelection) {
        if expandedSceneTreeBranches.contains(selection) {
            expandedSceneTreeBranches.remove(selection)
        } else {
            expandedSceneTreeBranches.insert(selection)
        }
    }

    private func compactSceneTreeRow(_ scene: SavedScene) -> some View {
        sceneTreeRow(
            .scene(scene.id), title: scene.name,
            detail: model.activeSceneID == scene.id ? "abierta" : nil,
            icon: "doc.text", imported3DScene: scene
        )
        .overlay(alignment: .leading) {
            if model.activeSceneID == scene.id {
                RoundedRectangle(cornerRadius: 4).stroke(NativeTheme.accent, lineWidth: 1)
            }
        }
        .highPriorityGesture(
            TapGesture(count: 2).onEnded { requestOpenScene(scene) }
        )
        .onDrag { NSItemProvider(object: scene.id.uuidString as NSString) }
        .contextMenu {
            Button("Abrir escena") { requestOpenScene(scene) }
            Divider()
            Button("Copiar settings…") {
                settingsCopyRequest = SceneSettingsCopyRequest(scene: scene)
            }
            if let clipboard = SceneSettingsClipboardDocument.read() {
                Button("Pegar settings…") {
                    settingsPasteRequest = SceneSettingsPasteRequest(
                        scene: scene, clipboard: clipboard
                    )
                }
            }
            Button("Restaurar valores por defecto…") {
                requestSceneAction(.resetDefaults, scene: scene)
            }
            if sceneOwnsImported3D(scene) {
                Button("Eliminar 3D importado…", role: .destructive) {
                    requestSceneAction(.removeImported3D, scene: scene)
                }
            }
            Divider()
            Button("Duplicar escena") {
                do { _ = try scenes.duplicate(scene) }
                catch { model.errorMessage = error.localizedDescription }
            }
            Button("Añadir a Render Queue…") { requestSceneRender(scene) }
            Divider()
            Button("Eliminar escena", role: .destructive) { requestSceneAction(.delete, scene: scene) }
        }
    }

    @ViewBuilder
    private var sceneTreeInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch sceneTreeSelection {
                case .unclassified:
                    inspectorTitle("Sin clasificar", icon: "tray")
                    Text("Escenas que todavía no pertenecen a ningún Plano.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Escenas", value: "\(scenes.document.unclassifiedSceneIDs.count)")
                    Divider()
                    Button("Nueva Producción manual…") { createManualProduction() }
                    Button("Asociar production.json…") { associateNewProduction() }
                case let .production(id):
                    if let production = production(id: id) {
                        productionInspector(production)
                    } else { missingTreeSelection() }
                case let .episode(id):
                    if let context = episodeContext(id: id) {
                        episodeInspector(context.episode, production: context.production)
                    } else { missingTreeSelection() }
                case let .shot(id):
                    if let context = shotContext(id: id) {
                        shotInspector(
                            context.shot, episode: context.episode,
                            production: context.production
                        )
                    } else { missingTreeSelection() }
                case let .scene(id):
                    if let scene = scenes.scene(id: id) {
                        sceneInspector(scene)
                    } else { missingTreeSelection() }
                case nil:
                    ContentUnavailableView(
                        "Inspector del árbol", systemImage: "sidebar.right",
                        description: Text("Selecciona un elemento del árbol.")
                    )
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func inspectorTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.headline)
    }

    private func productionInspector(_ production: SceneProduction) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorTitle("Producción", icon: "building.2")
            TreeInspectorTextField(title: "Nombre", value: production.name) { value in
                do { try scenes.renameProduction(production.id, to: value); return true }
                catch { model.errorMessage = error.localizedDescription; return false }
            }
            TreeInspectorTextField(
                title: "Temporada", value: production.seasonSlug,
                allowsEmpty: true, isEnabled: production.association == nil
            ) { value in
                do { try scenes.setProductionSeason(production.id, to: value); return true }
                catch { model.errorMessage = error.localizedDescription; return false }
            }
            Divider()
            productionAssociationPicker(production)
            if let association = production.association {
                LabeledContent("Estado", value: productionIsLive(production) ? "Conectada" : "Desconectada")
                LabeledContent("Production ID", value: association.productionId)
                LabeledContent("Raíz", value: association.productionRootPath)
                ForEach(association.destinations) { destination in
                    LabeledContent(
                        destination.role,
                        value: "\(destination.workstreamName)/\(destination.folderName)\(destination.folderSuffix)"
                    )
                }
                Button("Actualizar desde production.json…") { reconnectProduction(production, replace: false) }
                Button("Seleccionar nueva raíz…") { selectOfflineRoot(production) }
            } else {
                LabeledContent("Estado", value: "Manual")
            }
            Divider()
            Button("Nuevo Episodio libre…") { createEpisode(in: production) }
            Button("Eliminar Producción", role: .destructive) {
                do {
                    try scenes.deleteProduction(production.id)
                    sceneTreeSelection = .unclassified
                } catch { model.errorMessage = error.localizedDescription }
            }
        }
    }

    private func productionAssociationPicker(_ production: SceneProduction) -> some View {
        Picker(
            "Asociación",
            selection: Binding(
                get: { production.association?.productionId ?? "" },
                set: { selection in
                    guard selection != production.association?.productionId else { return }
                    if selection.isEmpty {
                        do { try scenes.makeProductionManual(production.id) }
                        catch { model.errorMessage = error.localizedDescription }
                    } else if selection == "choose-production-json" {
                        if production.association == nil {
                            associateExistingProduction(production)
                        } else {
                            reconnectProduction(production, replace: true)
                        }
                    }
                }
            )
        ) {
            Text("Libre · Salida manual").tag("")
            if let association = production.association {
                Text("Shot Manager · \(association.productionSlug)")
                    .tag(association.productionId)
            }
            Text("Asociar otro production.json…").tag("choose-production-json")
        }
        .pickerStyle(.menu)
    }

    private func episodeAssociationPicker(
        _ episode: SceneEpisode, production: SceneProduction
    ) -> some View {
        let live = try? liveProjection(for: production)
        let currentID = episode.associationState == .associated
            ? episode.externalReference?.episodeId ?? "" : ""
        var options = (live?.episodes ?? []).sorted {
            $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order
        }.map { ($0.id, "\(String(format: "%03d", $0.order)) · \($0.slug)") }
        if let reference = episode.externalReference,
           episode.associationState == .associated,
           !options.contains(where: { $0.0 == reference.episodeId }) {
            options.append((reference.episodeId, "No disponible · \(reference.episodeSlug)"))
        }
        return Picker(
            "Asociación",
            selection: Binding(
                get: { currentID },
                set: { selection in
                    guard selection != currentID else { return }
                    if selection.isEmpty {
                        do { try scenes.makeEpisodeFree(episode.id) }
                        catch { model.errorMessage = error.localizedDescription }
                    } else if let external = live?.episodes.first(where: { $0.id == selection }) {
                        do { try scenes.associateEpisode(episode.id, with: external) }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                }
            )
        ) {
            Text("Libre · Salida manual").tag("")
            ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
        }
        .pickerStyle(.menu)
    }

    private func shotAssociationPicker(
        _ shot: SceneShot, episode: SceneEpisode, production: SceneProduction
    ) -> some View {
        let live = try? liveProjection(for: production)
        let episodeID = episode.associationState == .associated
            ? episode.externalReference?.episodeId : nil
        let currentID = shot.associationState == .associated
            ? shot.externalReference?.shotId ?? "" : ""
        var options = (live?.shots ?? []).filter { $0.episodeId == episodeID }.sorted {
            let order = $0.canonicalName.localizedStandardCompare($1.canonicalName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }.map { ($0.id, $0.canonicalName) }
        if let reference = shot.externalReference,
           shot.associationState == .associated,
           !options.contains(where: { $0.0 == reference.shotId }) {
            options.append((reference.shotId, "No disponible · \(reference.canonicalName)"))
        }
        return Picker(
            "Asociación",
            selection: Binding(
                get: { currentID },
                set: { selection in
                    guard selection != currentID else { return }
                    if selection.isEmpty {
                        do { try scenes.makeShotFree(shot.id) }
                        catch { model.errorMessage = error.localizedDescription }
                    } else if let external = live?.shots.first(where: { $0.id == selection }) {
                        do { try scenes.associateShot(shot.id, with: external) }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                }
            )
        ) {
            Text("Libre · Salida manual").tag("")
            ForEach(options, id: \.0) { option in Text(option.1).tag(option.0) }
        }
        .pickerStyle(.menu)
    }

    private func episodeInspector(
        _ episode: SceneEpisode, production: SceneProduction
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorTitle("Episodio", icon: "rectangle.stack")
            TreeInspectorTextField(
                title: "Nombre", value: episode.name,
                isEnabled: episode.associationState == .free
            ) { value in
                do { try scenes.renameEpisode(episode.id, to: value); return true }
                catch { model.errorMessage = error.localizedDescription; return false }
            }
            LabeledContent(
                "Estado", value: episode.associationState == .associated ? "Asociado" : "Libre"
            )
            episodeAssociationPicker(episode, production: production)
            if let reference = episode.externalReference {
                LabeledContent("Orden", value: String(format: "%03d", reference.episodeOrder))
                LabeledContent("Slug", value: reference.episodeSlug)
                LabeledContent("Episode ID", value: reference.episodeId)
            }
            Divider()
            Button("Nuevo Plano libre…") { createShot(in: episode) }
            Button("Eliminar Episodio", role: .destructive) {
                do {
                    try scenes.deleteEpisode(episode.id)
                    sceneTreeSelection = .production(production.id)
                } catch { model.errorMessage = error.localizedDescription }
            }
        }
    }

    private func shotInspector(
        _ shot: SceneShot, episode: SceneEpisode, production: SceneProduction
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorTitle("Plano", icon: "camera")
            TreeInspectorTextField(
                title: "Nombre", value: shot.name,
                isEnabled: shot.associationState == .free
            ) { value in
                do { try scenes.renameShot(shot.id, to: value); return true }
                catch { model.errorMessage = error.localizedDescription; return false }
            }
            LabeledContent("Estado", value: shot.associationState == .associated ? "Asociado" : "Libre")
            shotAssociationPicker(shot, episode: episode, production: production)
            LabeledContent("Escenas", value: "\(shot.scenes.count)")
            LabeledContent("Próximo ordinal", value: String(format: "%03d", shot.nextSceneOrdinal))
            if let reference = shot.externalReference {
                LabeledContent("Nombre canónico", value: reference.canonicalName)
                LabeledContent("Shot ID", value: reference.shotId)
            }
            Divider()
            Text("Arrastra escenas sobre este Plano para asociarlas.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Nueva escena") { createScene(in: shot) }
            Button("Eliminar Plano", role: .destructive) {
                do {
                    try scenes.deleteShot(shot.id)
                    sceneTreeSelection = .episode(episode.id)
                } catch { model.errorMessage = error.localizedDescription }
            }
        }
    }

    private func sceneInspector(_ scene: SavedScene) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            inspectorTitle("Escena", icon: "doc.text")
            let placement = scenePlacement(scene.id)
            TreeInspectorTextField(
                title: "Nombre", value: scene.name, isEnabled: placement == nil
            ) { value in
                do { try scenes.rename(scene, to: value); return true }
                catch { model.errorMessage = error.localizedDescription; return false }
            }
            if let placement {
                LabeledContent("Plano", value: placement.shot.name)
                LabeledContent("Ordinal", value: String(format: "%03d", placement.ordinal))
                Text("El nombre procede del Plano asociado. Muévela a Sin clasificar para editarlo.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Mover a Sin clasificar") {
                    do { try scenes.moveScene(scene.id, to: nil) }
                    catch { model.errorMessage = error.localizedDescription }
                }
            } else {
                LabeledContent("Ubicación", value: "Sin clasificar")
            }
            Divider()
            Button("Abrir escena") { requestOpenScene(scene) }
            Button("Copiar settings…") {
                settingsCopyRequest = SceneSettingsCopyRequest(scene: scene)
            }
            if let clipboard = SceneSettingsClipboardDocument.read() {
                Button("Pegar settings…") {
                    settingsPasteRequest = SceneSettingsPasteRequest(
                        scene: scene, clipboard: clipboard
                    )
                }
            }
            Button("Restaurar valores por defecto…") {
                requestSceneAction(.resetDefaults, scene: scene)
            }
            if sceneOwnsImported3D(scene) {
                Button("Eliminar 3D importado…", role: .destructive) {
                    requestSceneAction(.removeImported3D, scene: scene)
                }
            }
            Button("Duplicar escena") {
                do { _ = try scenes.duplicate(scene) }
                catch { model.errorMessage = error.localizedDescription }
            }
            Button("Añadir a Render Queue…") { requestSceneRender(scene) }
            Button("Historial…") { autosaveHistoryTarget = scenes.autosaveHistoryTarget(for: scene) }
            Button("Eliminar escena", role: .destructive) { requestSceneAction(.delete, scene: scene) }
        }
    }

    private func missingTreeSelection() -> some View {
        ContentUnavailableView("Elemento inexistente", systemImage: "questionmark.folder")
    }

    private func production(id: UUID) -> SceneProduction? {
        scenes.document.productions.first { $0.id == id }
    }

    private func episodeContext(id: UUID) -> (production: SceneProduction, episode: SceneEpisode)? {
        for production in scenes.document.productions {
            if let episode = production.episodes.first(where: { $0.id == id }) {
                return (production, episode)
            }
        }
        return nil
    }

    private func shotContext(
        id: UUID
    ) -> (production: SceneProduction, episode: SceneEpisode, shot: SceneShot)? {
        for production in scenes.document.productions {
            for episode in production.episodes {
                if let shot = episode.shots.first(where: { $0.id == id }) {
                    return (production, episode, shot)
                }
            }
        }
        return nil
    }

    private func scenePlacement(_ sceneID: UUID) -> (shot: SceneShot, ordinal: Int)? {
        for production in scenes.document.productions {
            for episode in production.episodes {
                for shot in episode.shots {
                    if let placement = shot.scenes.first(where: { $0.sceneID == sceneID }) {
                        return (shot, placement.ordinal)
                    }
                }
            }
        }
        return nil
    }

    private func sceneOwnsImported3D(_ scene: SavedScene) -> Bool {
        if model.activeSceneID == scene.id {
            return model.trackingScene != nil
        }
        return scene.snapshot.tracking != nil
    }

    private func acceptSceneDrop(_ providers: [NSItemProvider], shotID: UUID?) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let text = value as? String, let sceneID = UUID(uuidString: text) else { return }
            Task { @MainActor in
                do { try scenes.moveScene(sceneID, to: shotID) }
                catch { model.errorMessage = error.localizedDescription }
            }
        }
        return true
    }

    private func prompt(_ title: String, label: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Aceptar")
        alert.addButton(withTitle: "Cancelar")
        let field = NSTextField(string: initial)
        field.placeholderString = label
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func chooseProductionJSON() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Selecciona production.json"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseDestinations(
        _ options: [ShotManagerDestinationOption]
    ) -> (render: ShotManagerDestinationOption, comps: ShotManagerDestinationOption)? {
        guard !options.isEmpty else { model.errorMessage = "La Producción no publica destinos."; return nil }
        let labels = options.map { "\($0.workstream.name) / \($0.folder.name)" }
        let renderPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        renderPopup.addItems(withTitles: labels)
        let compsPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        compsPopup.addItems(withTitles: labels)
        if let renderIndex = options.firstIndex(where: {
            $0.folder.name.localizedCaseInsensitiveContains("render")
        }) { renderPopup.selectItem(at: renderIndex) }
        if let compsIndex = options.firstIndex(where: {
            $0.folder.name.localizedCaseInsensitiveContains("comp")
        }) { compsPopup.selectItem(at: compsIndex) }
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Carpeta de renders"), renderPopup,
            NSTextField(labelWithString: "Carpeta de comps"), compsPopup,
        ])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 92)
        let alert = NSAlert()
        alert.messageText = "Destinos de Producción"
        alert.informativeText = "Elige por separado las carpetas de renders y composiciones."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Asociar")
        alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (
            options[renderPopup.indexOfSelectedItem],
            options[compsPopup.indexOfSelectedItem]
        )
    }

    private func createManualProduction() {
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Nombre de Producción"
        let seasonField = NSTextField(string: "")
        seasonField.placeholderString = "Temporada (atributo, puede quedar vacío)"
        let fields = NSStackView(views: [nameField, seasonField])
        fields.orientation = .vertical; fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 340, height: 56)
        let alert = NSAlert(); alert.messageText = "Nueva Producción manual"
        alert.accessoryView = fields
        alert.addButton(withTitle: "Crear"); alert.addButton(withTitle: "Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try scenes.createProduction(
                name: nameField.stringValue, seasonSlug: seasonField.stringValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func associateNewProduction() {
        guard let url = chooseProductionJSON() else { return }
        do {
            let read = try ShotManagerAssociationService.readProductionJSON(at: url)
            let matches = scenes.productionsAssociated(
                with: read.projection.productionId
            )
            if !matches.isEmpty {
                let production: SceneProduction
                if matches.count == 1 {
                    production = matches[0]
                } else {
                    guard let selected = chooseItem(
                        "Reconectar Producción local",
                        items: matches,
                        label: productionReconnectLabel
                    ) else { return }
                    production = selected
                }
                guard let existing = production.association else {
                    throw SceneLibraryError.invalidDocument(
                        "La Producción local seleccionada no conserva su asociación."
                    )
                }
                let association = try ShotManagerAssociationService.refreshedAssociation(
                    existing, from: read
                )
                try scenes.associateProduction(
                    production.id, association: association,
                    projection: read.projection, replacingProduction: false
                )
                sceneTreeSelection = .production(production.id)
                return
            }
            let options = ShotManagerAssociationService.destinationOptions(in: read.projection)
            guard let destinations = chooseDestinations(options) else { return }
            let association = try ShotManagerAssociationService.makeAssociation(
                from: read,
                selections: [("render", destinations.render), ("comps", destinations.comps)]
            )
            _ = try scenes.createAssociatedProduction(
                name: read.projection.productionSlug, association: association,
                projection: read.projection
            )
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func productionReconnectLabel(_ production: SceneProduction) -> String {
        let root = production.association?.productionRootPath ?? "Sin raíz"
        let episodeLabel = production.episodes.count == 1
            ? "1 episodio" : "\(production.episodes.count) episodios"
        return "\(production.name) · \(episodeLabel) · \(root)"
    }

    private func associateExistingProduction(_ production: SceneProduction) {
        guard let url = chooseProductionJSON() else { return }
        do {
            let read = try ShotManagerAssociationService.readProductionJSON(at: url)
            let options = ShotManagerAssociationService.destinationOptions(in: read.projection)
            guard let destinations = chooseDestinations(options) else { return }
            let association = try ShotManagerAssociationService.makeAssociation(
                from: read,
                selections: [("render", destinations.render), ("comps", destinations.comps)]
            )
            try scenes.associateProduction(
                production.id, association: association, projection: read.projection,
                replacingProduction: false
            )
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func createEpisode(in production: SceneProduction) {
        guard let name = prompt("Nuevo Episodio libre", label: "Nombre") else { return }
        do { _ = try scenes.createEpisode(in: production.id, name: name) }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func createShot(in episode: SceneEpisode) {
        guard let name = prompt("Nuevo Plano libre", label: "Nombre") else { return }
        do { _ = try scenes.createShot(in: episode.id, name: name) }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func liveProjection(for production: SceneProduction) throws -> ShotManagerProductionProjection {
        guard let association = production.association else {
            throw SceneLibraryError.inaccessible("La Producción es manual.")
        }
        let url = URL(fileURLWithPath: association.productionRootPath).appendingPathComponent("production.json")
        let read = try ShotManagerAssociationService.readProductionJSON(at: url)
        guard read.projection.productionId == association.productionId else {
            throw ShotManagerAssociationError.differentProduction
        }
        return read.projection
    }

    private func productionIsLive(_ production: SceneProduction) -> Bool {
        (try? liveProjection(for: production)) != nil
    }

    private func chooseItem<T>(_ title: String, items: [T], label: (T) -> String) -> T? {
        guard !items.isEmpty else { model.errorMessage = "No hay opciones disponibles."; return nil }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        popup.addItems(withTitles: items.map(label))
        let alert = NSAlert(); alert.messageText = title; alert.accessoryView = popup
        alert.addButton(withTitle: "Asociar"); alert.addButton(withTitle: "Cancelar")
        return alert.runModal() == .alertFirstButtonReturn ? items[popup.indexOfSelectedItem] : nil
    }

    private func associateEpisode(_ episode: SceneEpisode, production: SceneProduction) {
        do {
            let projection = try liveProjection(for: production)
            guard let external = chooseItem("Asociar Episodio", items: projection.episodes, label: {
                "\(String(format: "%03d", $0.order)) · \($0.slug)"
            }) else { return }
            try scenes.associateEpisode(episode.id, with: external)
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func associateShot(_ shot: SceneShot, episode: SceneEpisode, production: SceneProduction) {
        do {
            guard let episodeID = episode.externalReference?.episodeId,
                  episode.associationState == .associated else {
                throw SceneLibraryError.invalidDocument("Asocia primero el Episodio.")
            }
            let projection = try liveProjection(for: production)
            let options = projection.shots.filter { $0.episodeId == episodeID }
            guard let external = chooseItem("Asociar Plano", items: options, label: { $0.canonicalName }) else { return }
            try scenes.associateShot(shot.id, with: external)
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func reconnectProduction(_ production: SceneProduction, replace: Bool) {
        guard let url = chooseProductionJSON() else { return }
        do {
            let read = try ShotManagerAssociationService.readProductionJSON(at: url)
            let association: ShotManagerProductionAssociation
            if replace {
                let options = ShotManagerAssociationService.destinationOptions(in: read.projection)
                guard let destinations = chooseDestinations(options) else { return }
                association = try ShotManagerAssociationService.makeAssociation(
                    from: read,
                    selections: [("render", destinations.render), ("comps", destinations.comps)]
                )
            } else if let existing = production.association {
                association = try ShotManagerAssociationService.refreshedAssociation(existing, from: read)
            } else { return }
            try scenes.associateProduction(
                production.id, association: association, projection: read.projection,
                replacingProduction: replace
            )
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func selectOfflineRoot(_ production: SceneProduction) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try scenes.selectOfflineRoot(production.id, root: url) }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func sceneConfirmationButton(_ action: PendingSceneAction) -> String {
        switch action {
        case .resetDefaults: "Restaurar valores"
        case .removeImported3D: "Eliminar 3D importado"
        case .delete: "Eliminar escena"
        }
    }

    private func requestSceneAction(_ action: PendingSceneAction, scene: SavedScene) {
        pendingScene = scene
        pendingSceneAction = action
    }

    private var activeSceneTitle: String {
        guard let activeSceneID = model.activeSceneID,
              let scene = scenes.scene(id: activeSceneID)
        else { return "SCREEN-SIMULATION" }
        return scene.name
    }

    private func requestOpenScene(_ scene: SavedScene) {
        guard scene.id != model.activeSceneID else { return }
        openScene(scene)
    }

    private func openScene(_ scene: SavedScene) {
        Task { await model.openSavedScene(scene, undoManager: undoManager) }
    }

    private func requestSceneRender(_ scene: SavedScene) {
        do {
            try model.configureRenderRaster(for: scene)
            try applyRenderIdentityDefaults(for: scene)
            model.renderVersionSuffix = ""
            if model.renderOutputDirectoryPath.isEmpty {
                model.renderOutputDirectoryPath = FileDialogDirectory.renderOutput.url?.path ?? ""
            }
            model.ensureRenderOptionsCompatible()
            renderDraft = RenderDraft(
                scene: scene, sourceJob: nil, historicalSnapshot: false
            )
            page = .render
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func applyRenderIdentityDefaults(for scene: SavedScene) throws {
        if let associated = try scenes.associatedRenderTarget(for: scene.id) {
            model.renderJobName = associated.outputBaseName
            model.renderOutputDirectoryPath = associated.directoryPath
        } else {
            model.renderJobName = scene.name
        }
    }

    private func saveNewScene() {
        do {
            let capture = try model.captureSavedScene()
            let scene = try scenes.add(capture: capture)
            model.markActiveScene(scene.id)
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func createScene(in shot: SceneShot) {
        do {
            let capture = try model.captureSavedScene()
            let scene = try scenes.add(capture: capture, toShotID: shot.id)
            sceneTreeSelection = .scene(scene.id)
            model.markActiveScene(scene.id)
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func copySceneSettings(
        _ scene: SavedScene,
        blocks: Set<SceneSettingsBlock>
    ) {
        do {
            let clipboard = try scenes.settingsClipboard(for: scene, blocks: blocks)
            try clipboard.write()
            settingsCopyRequest = nil
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func applySceneSettings(_ request: PendingSettingsPaste) {
        pendingSettingsPaste = nil
        do {
            let destination: SceneSettingsPasteDestination
            let destinationSnapshot: SavedSceneSnapshot
            if model.activeSceneID == request.scene.id {
                let capture = try model.captureSavedScene()
                destination = .activeScene(capture)
                destinationSnapshot = capture.snapshot
            } else {
                destination = .storedScene
                destinationSnapshot = request.scene.snapshot
            }
            let ownership = try model.sceneSettingsOwnership(
                source: request.clipboard.snapshot,
                destination: destinationSnapshot
            )
            let updated = try scenes.applySettingsClipboard(
                request.clipboard,
                blocks: request.blocks,
                to: request.scene,
                destination: destination,
                ownership: ownership,
                undoManager: undoManager
            )
            if model.activeSceneID == updated.id {
                Task { await model.openSavedScene(updated, undoManager: undoManager) }
            }
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func performConfirmedSceneAction(_ action: PendingSceneAction, scene: SavedScene) {
        pendingSceneAction = nil
        pendingScene = nil
        switch action {
        case .resetDefaults:
            do {
                let isActive = model.activeSceneID == scene.id
                let destination: SceneDefaultResetDestination
                let base: SavedSceneSnapshot
                if isActive {
                    let capture = try model.captureSavedScene()
                    destination = .activeScene(capture)
                    base = capture.snapshot
                } else {
                    destination = .storedScene
                    base = scene.snapshot
                }
                let reset = try model.defaultSceneSnapshot(preserving: base)
                let updated = try scenes.resetToDefaults(
                    scene,
                    snapshot: reset,
                    destination: destination,
                    undoManager: undoManager
                )
                if isActive {
                    Task { await model.openSavedScene(updated, undoManager: undoManager) }
                }
            } catch { model.errorMessage = error.localizedDescription }
        case .removeImported3D:
            do {
                let isActive = model.activeSceneID == scene.id
                let destination: SceneImported3DRemovalDestination
                if isActive {
                    destination = .activeScene(try model.captureSavedScene())
                } else {
                    destination = .storedScene
                }
                let updated = try scenes.removeImported3D(
                    scene, destination: destination, undoManager: undoManager
                )
                if isActive {
                    Task { await model.openSavedScene(updated, undoManager: undoManager) }
                }
            } catch { model.errorMessage = error.localizedDescription }
        case .delete:
            do { try scenes.delete(scene) }
            catch { model.errorMessage = error.localizedDescription }
        }
    }

    private func renderOptionsPanel(_ draft: RenderDraft) -> some View {
        let scene = draft.scene
        return VStack(spacing: 0) {
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
                Section("Destino") {
                    LabeledContent("Ruta") {
                        HStack {
                            TextField("Directorio", text: $model.renderOutputDirectoryPath)
                            Button("Browse…", action: browseRenderOutputDirectory)
                        }
                    }
                    TextField("Nombre", text: $model.renderJobName)
                    TextField("Versión", text: $model.renderVersionSuffix)
                    LabeledContent("Resultado", value: renderOutputNamePreview)
                }
                Section("Salida") {
                    Picker("Modo", selection: Binding(
                        get: { model.renderMode },
                        set: { model.changeRenderMode($0) }
                    )) {
                        ForEach(StudioRenderMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
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
                        ForEach(StudioOutputFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    if model.renderMode == .final && !model.outputFormat.supportsAlpha {
                        Text("Final requiere un formato que conserve alpha.")
                            .font(.caption)
                            .foregroundStyle(.red)
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
                    GroupBox("Raster de la escena") {
                        VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Ancho") {
                            TextField("px", value: $model.renderRasterWidth, format: .number)
                                .frame(width: 90)
                        }
                        LabeledContent("Alto") {
                            TextField("px", value: $model.renderRasterHeight, format: .number)
                                .frame(width: 90)
                        }
                        Picker("Placement", selection: $model.renderRasterPlacementID) {
                            Text("Fit").tag("fit")
                            Text("Fill / Crop").tag("fill-crop")
                            Text("1:1").tag("one-to-one")
                        }
                        Text("Parte de los valores guardados en la escena; los cambios sólo se congelan en este render.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if model.renderMode == .final {
                    Toggle("Incluir composición Fusion · Device único", isOn: Binding(
                            get: { model.includeFusionComposition },
                            set: {
                                model.includeFusionComposition = $0
                                model.ensureRenderOptionsCompatible()
                            }
                        ))
                    if model.includeFusionComposition {
                        LabeledContent("Entrega", value: "Fusion · Device único")
                    } else {
                        Picker("Entrega", selection: Binding(
                            get: { model.renderComposition },
                            set: { model.changeRenderComposition($0) }
                        )) {
                            ForEach([
                                StudioRenderComposition.deviceAndSpillTogether,
                                .deviceAndSpillSeparate
                            ]) { composition in
                                Text(composition.label).tag(composition)
                            }
                        }
                        if model.renderComposition == .deviceAndSpillSeparate {
                            Picker("Spill", selection: $model.renderSpillDeliveryMode) {
                                ForEach(StudioSpillDeliveryMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                        }
                    }
                    } else {
                        Picker("WIP Review", selection: Binding(
                            get: { model.renderWIPReviewPreset },
                            set: { model.changeWIPReviewPreset($0) }
                        )) {
                            Text("Ninguno").tag(StudioWIPReviewPreset?.none)
                            ForEach(library.allWIPReviewPresets) { preset in
                                Text(preset.name).tag(Optional(preset))
                            }
                        }
                    }
                    if model.includeFusionComposition {
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
                        Text("Fusion recibe un único Device con RGB físico completo y alpha de oclusión independiente. La comp aplica el nodo nativo exacto hacia ACEScg antes de reconstruir cámara, distorsión y motion blur.")
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
                    if !model.includeFusionComposition {
                    Picker("Motion Blur", selection: $model.renderMotionBlurMode) {
                        ForEach(StudioRenderMotionBlurMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
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
                    .disabled(model.renderMotionBlurMode == .disabled)
                    Text(model.renderMotionBlurMode == .approximate2D
                        ? "Aproximación 2D posterior a una sola evaluación física. No resuelve disoclusiones, parallax, reflejos temporales ni integración física de shutter."
                        : "El modo físico integra cámara, Device y emisión durante el intervalo físico de obturación.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text("El motion blur no se hornea en los media; Fusion recibe el shutter y las curvas animadas de cámara.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Codificación") {
                    LabeledContent("Píxel", value: model.outputPixelEncoding.label)
                    Picker("Rango de señal", selection: $model.outputSignalRange) {
                        ForEach(StudioSignalRange.allCases) { range in
                            Text(range.label).tag(range)
                                .disabled(!model.outputFormat.supportedSignalRanges(
                                    for: model.outputPixelEncoding
                                ).contains(range))
                        }
                    }
                    LabeledContent(
                        "Alpha",
                        value: model.renderMode == .preview
                            ? "Ignore / opaco" : "Straight · matte físico"
                    )
                    Toggle("Audio", isOn: $model.includeAudio)
                        .disabled(!model.outputFormat.isMovie
                            || model.renderComposition == .deviceAndSpillSeparate)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Añadir a Render Queue") {
                    addRenderDraft(draft)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    private var renderOutputNamePreview: String {
        let stem = model.renderJobName + model.renderVersionSuffix
        let ext = model.outputFormat.fileExtension
        if model.includeFusionComposition {
            return "\(stem)_FusionScene/"
        }
        if model.renderComposition == .deviceAndSpillSeparate {
            return model.outputFormat.isMovie
                ? "\(stem)_Device.\(ext) · \(stem)_Spill.\(ext)"
                : "\(stem)_Device########.\(ext) · \(stem)_Spill########.\(ext)"
        }
        return model.outputFormat.isMovie
            ? "\(stem).\(ext)" : "\(stem)########.\(ext)"
    }

    private func browseRenderOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if model.renderOutputDirectoryPath.hasPrefix("/") {
            panel.directoryURL = URL(
                fileURLWithPath: model.renderOutputDirectoryPath, isDirectory: true
            )
        } else {
            FileDialogDirectory.renderOutput.apply(to: panel)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.renderOutputDirectoryPath = url.path
        FileDialogDirectory.renderOutput.remember(url)
    }

    private func addRenderDraft(_ draft: RenderDraft) {
        if draft.historicalSnapshot {
            enqueueRenderDraft(draft)
            return
        }
        guard let current = scenes.scene(id: draft.scene.id) else {
            model.errorMessage = "La escena guardada ya no existe."
            return
        }
        let currentDraft = RenderDraft(
            scene: current,
            sourceJob: draft.sourceJob,
            historicalSnapshot: false
        )
        renderDraft = currentDraft
        enqueueRenderDraft(currentDraft)
    }

    private func enqueueRenderDraft(_ draft: RenderDraft) {
        model.enqueueSavedScene(
            draft.historicalSnapshot ? draft.sourceJob!.scene : draft.scene,
            derivedFrom: draft.sourceJob,
            historicalSnapshot: draft.historicalSnapshot
        )
    }

    private var testSetupPanel: some View {
        ScrollView {
            VStack(spacing: 12) {
                if let presentation = model.testPresentation {
                    TestAuthoringView(
                        state: presentation,
                        excludedControlIDs: ["device", "color-mode", "white-luminance"],
                        showsInspectorGroups: false,
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
                    TestPhaseCard(label: "Referencia") {
                        referenceAuthoringControls
                    }
                    TestAuthoringView(
                        state: presentation,
                        excludedControlIDs: ["device", "color-mode", "white-luminance"],
                        showsGeneral: false,
                        supplementarySectionContent: testInspectorSupplements,
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
                        CommittedNumberField(
                            label: "cd/m²",
                            value: selected.whiteLevelNits
                        ) { value in
                            model.handleTestIntent(.setScalar(
                                controlID: "white-luminance", value: value
                            ), undoManager: undoManager)
                        }
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
                    CommittedNumberField(
                        label: "0",
                        value: model.requestedSeconds,
                        onCommit: { model.requestedSeconds = $0 }
                    )
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
                                model.setReferenceMatchEnabled(false)
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
                            trackingScenePanel.toggle(
                                model: model,
                                undoManager: undoManager,
                                method: .deviceCorners
                            )
                        } label: {
                            Label(
                                trackingScenePanel.isVisible && model.trackingSceneMethod == .deviceCorners
                                    ? "Ocultar Match" : "Abrir Match",
                                systemImage: trackingScenePanel.isVisible && model.trackingSceneMethod == .deviceCorners
                                    ? "viewfinder.circle.fill" : "viewfinder.circle"
                            )
                        }
                        .nativeActionState(.init(
                            active: trackingScenePanel.isVisible
                                && model.trackingSceneMethod == .deviceCorners
                        ))
                    }
                }
            }
        }
    }

    private func interpretationLabel(_ label: String, annotation: String?) -> Text {
        Text(label + (annotation.map { " · \($0)" } ?? ""))
            .fontWeight(annotation == nil ? .regular : .semibold)
    }

    @ViewBuilder

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
                    if let timing = model.outputQueue.timing(for: job.id) {
                        Text(renderTimingLabel(timing))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else if let timing = job.terminalTiming {
                        Text(terminalRenderTimingLabel(timing))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .contextMenu {
                    if job.state != .rendering {
                        Button("Eliminar de la cola", role: .destructive) {
                            model.removeInactiveRender(job)
                        }
                    }
                    if job.state == .completed {
                        Button("Mostrar directorio en Finder") {
                            model.showRenderDestinationInFinder(job)
                        }
                        if job.configuration.fusionScene != nil {
                            Button("Actualizar comp Fusion") {
                                model.refreshFusionComposition(job)
                            }
                            Button("Copiar composición Fusion") {
                                model.copyFusionComposition(job)
                            }
                        }
                    }
                    if job.state.isTerminal {
                        Button("Volver a renderizar esta versión") {
                            model.configureRerender(
                                from: job.configuration, outputPlan: job.outputPlan
                            )
                            renderDraft = RenderDraft(
                                scene: job.scene,
                                sourceJob: job,
                                historicalSnapshot: true
                            )
                            page = .render
                        }
                        Button("Renderizar la escena actual…") {
                            renderCurrentSavedScene(derivedFrom: job)
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
                Button("Limpiar terminados", action: model.clearTerminalRenders)
                    .disabled(!model.jobs.contains {
                        $0.state == .completed || $0.state == .failed || $0.state == .cancelled
                    })
                Spacer()
                Button("Render Queue", action: model.runQueue)
                    .disabled(!model.outputQueue.isPaused && !model.jobs.contains { $0.state == .pending })
            }
            .padding(8)
        }
    }

    private func renderTimingLabel(
        _ timing: NativeOutputQueueController.RenderTiming
    ) -> String {
        let elapsed = queueDuration(timing.elapsedSeconds)
        let frame = timing.lastCompletedFrameSeconds.map {
            "Frame \(queueDuration($0))"
        } ?? "Frame calculando…"
        let average = timing.averageCompletedFrameSeconds.map {
            "Media/frame \(queueDuration($0))"
        } ?? "Media/frame calculando…"
        let remaining = timing.approximateRemainingSeconds.map {
            "Restante aprox. \(queueDuration($0))"
        } ?? "Restante aprox. calculando…"
        return "Transcurrido \(elapsed) · \(frame) · \(average) · \(remaining)"
    }

    private func terminalRenderTimingLabel(
        _ timing: NativeOutputQueueController.TerminalTiming
    ) -> String {
        let total = queueDuration(timing.totalSeconds)
        guard let average = timing.averageCompletedFrameSeconds else {
            return "Total \(total) · Media/frame no disponible"
        }
        return "Total \(total) · Media/frame \(queueDuration(average))"
    }

    private func queueDuration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        let hours = whole / 3_600
        let minutes = (whole % 3_600) / 60
        let remainder = whole % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
    }

    private func renderCurrentSavedScene(
        derivedFrom job: NativeOutputQueueController.RenderJob
    ) {
        guard let current = scenes.scene(id: job.scene.id) else {
            model.errorMessage = "La escena guardada actual ya no existe. La versión histórica sigue disponible."
            return
        }
        do {
            if let wipID = job.configuration.wipReview?.id {
                guard let currentWIP = library.allWIPReviewPresets.first(where: { $0.id == wipID }) else {
                    model.errorMessage = "El preset WIP Review del render histórico ya no existe en la Biblioteca Global."
                    return
                }
                model.configureRerender(from: job.configuration, outputPlan: job.outputPlan)
                model.renderWIPReviewPreset = currentWIP
            } else {
                model.configureRerender(from: job.configuration, outputPlan: job.outputPlan)
            }
            try applyRenderIdentityDefaults(for: current)
        } catch {
            model.errorMessage = error.localizedDescription
            return
        }
        renderDraft = RenderDraft(
            scene: current,
            sourceJob: job,
            historicalSnapshot: false
        )
        page = .render
    }

    @ViewBuilder
    private var outputInspectorSections: some View {
            Section("Inspector · Output") {
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
                            model.setReferenceMatchEnabled(false)
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
                            model.setReferenceMatchEnabled(false)
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
                .help("""
                    \(model.previewGizmosVisible ? "Ocultar" : "Mostrar") todos los gizmos del Viewer

                    Atajos de cámara y Device (con transformaciones desbloqueadas):
                    • MMB: desplazar
                    • Alt/Option + MMB: orbitar alrededor del Device
                    • Shift + MMB o rueda: acercar/alejar
                    • Cmd + MMB: escalar el mundo de tracking y recolocar el Device

                    Sin cámara Fusion/SynthEyes activa, los tres primeros atajos mueven la cámara.
                    Con cámara Fusion/SynthEyes activa, mueven el Device manteniendo fija esa cámara.
                    """)
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
        let propertyColumnWidth: CGFloat = 276
        let descriptor = SimulationOpacityResolver.presentation
        return VStack(spacing: 5) {
            HStack(spacing: 0) {
                Color.clear.frame(width: propertyColumnWidth, height: 58)
                NativeTimelineView(
                    frameCount: model.frameCount,
                    frameRate: model.frameRate,
                    currentFrame: model.currentFrame,
                    inFrame: model.inFrame,
                    outFrame: model.outFrame,
                    snapFrames: model.simulationOpacityKeyframeFrames,
                    onSeek: { model.seek(toFrame: $0) },
                    onSetIn: { model.setInFrame($0) },
                    onSetOut: { model.setOutFrame($0) }
                )
                .frame(height: 58)
            }
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
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(descriptor.displayName)
                            .frame(width: 64, alignment: .leading)
                        CommittedNumberField(
                            label: "Opacidad de simulación",
                            value: model.currentSimulationOpacity
                        ) {
                            model.setSimulationOpacityKeyframe(
                                value: $0, undoManager: undoManager
                            )
                        }
                        .frame(width: 68)
                        Button {
                            model.toggleSimulationOpacityKeyframe(undoManager: undoManager)
                        } label: {
                            Image(systemName: model.currentSimulationOpacityKeyframe == nil
                                ? "diamond" : "diamond.fill")
                        }
                        .buttonStyle(.plain)
                        .help(model.currentSimulationOpacityKeyframe == nil
                            ? "Crear keyframe" : "Eliminar keyframe")
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: propertyColumnWidth, height: 28)
                    SimulationOpacityTrackView(
                        frameCount: model.frameCount,
                        currentFrame: model.currentFrame,
                        keyframes: model.simulationOpacityKeyframes,
                        interpolationOptions: descriptor.supportedInterpolations.map {
                            ($0, descriptor.interpolationLabels[$0]!)
                        },
                        onSeek: { model.seek(toFrame: $0) },
                        onMove: { id, frame in
                            model.moveSimulationOpacityKeyframe(
                                id: id, toFrame: frame, undoManager: undoManager
                            )
                        },
                        onSetInterpolation: { id, interpolation in
                            model.setSimulationOpacityInterpolation(
                                keyframeID: id,
                                interpolation: interpolation,
                                undoManager: undoManager
                            )
                        }
                    )
                    .frame(height: 28)
                }
            }
            .padding(.vertical, 4)
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func frameField(_ label: String, value: Binding<Int>) -> some View {
        CommittedNumberField(
            label: label,
            value: value.wrappedValue,
            onCommit: { value.wrappedValue = $0 }
        )
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

private protocol CommittedNumericValue: Equatable {
    static func parseCommittedDraft(_ text: String) -> Self?
    var committedDraftText: String { get }
}

extension Double: CommittedNumericValue {
    fileprivate static func parseCommittedDraft(_ text: String) -> Double? {
        let value = Double(text.replacingOccurrences(of: ",", with: "."))
        return value?.isFinite == true ? value : nil
    }

    fileprivate var committedDraftText: String { String(format: "%.12g", self) }
}

extension Int: CommittedNumericValue {
    fileprivate static func parseCommittedDraft(_ text: String) -> Int? { Int(text) }
    fileprivate var committedDraftText: String { String(self) }
}

extension UInt32: CommittedNumericValue {
    fileprivate static func parseCommittedDraft(_ text: String) -> UInt32? { UInt32(text) }
    fileprivate var committedDraftText: String { String(self) }
}

private struct CommittedNumberField<Value: CommittedNumericValue>: View {
    let label: String
    let value: Value
    let onCommit: (Value) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(label, text: $draft)
            .focused($isFocused)
            .onAppear { synchronize(with: value) }
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if focused { synchronize(with: value) }
                else { commit() }
            }
            .onChange(of: value) { _, newValue in
                synchronize(with: newValue)
            }
    }

    private func commit() {
        let normalized = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Value.parseCommittedDraft(normalized) else {
            synchronize(with: value)
            return
        }
        guard parsed != value else {
            synchronize(with: value)
            return
        }
        onCommit(parsed)
    }

    private func synchronize(with value: Value) {
        draft = value.committedDraftText
    }
}

private struct CommittedTextField: View {
    let label: String
    let value: String
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(label, text: $draft)
            .focused($isFocused)
            .onAppear { draft = value }
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in
                if focused { draft = value }
                else { commit() }
            }
            .onChange(of: value) { _, newValue in
                draft = newValue
            }
    }

    private func commit() {
        guard draft != value else { return }
        onCommit(draft)
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

private struct TreeInspectorTextField: View {
    let title: String
    let value: String
    var allowsEmpty = false
    var isEnabled = true
    let onCommit: (String) -> Bool
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(
        title: String, value: String, allowsEmpty: Bool = false,
        isEnabled: Bool = true, onCommit: @escaping (String) -> Bool
    ) {
        self.title = title
        self.value = value
        self.allowsEmpty = allowsEmpty
        self.isEnabled = isEnabled
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: $draft)
                .textFieldStyle(.roundedBorder)
                .disabled(!isEnabled)
                .focused($isFocused)
                .onSubmit { commit() }
                .onChange(of: isFocused) { wasFocused, focused in
                    if wasFocused, !focused { commit() }
                }
                .onChange(of: value) { _, newValue in
                    if !isFocused { draft = newValue }
                }
        }
        .onDisappear { if isFocused { commit() } }
    }

    private func commit() {
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate != value else { return }
        guard allowsEmpty || !candidate.isEmpty, onCommit(candidate) else {
            draft = value
            return
        }
        draft = candidate
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
        case let .cancelling(progress):
            "esperando el final de Metal al \(Int((progress * 100).rounded())) %"
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
        case let .cancelling(progress):
            HStack(spacing: 7) {
                ProgressView(value: progress, total: 1)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(Int((progress * 100).rounded())) %")
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .frame(width: 36, alignment: .trailing)
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
