import SwiftUI

struct ModelInspectorView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case screen = "Pantalla"
        case capture = "Captura"

        var id: String { rawValue }
    }

    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var library: GlobalLibraryController
    @ObservedObject private var physical: PhysicalModelController
    @State private var tab = Tab.general
    @State private var expandedScreen: Set<ScreenPhysicalSection> = [.emission]
    @State private var expandedCapture: Set<CapturePhysicalSection> = []

    init(workspace: WorkspaceModel, library: GlobalLibraryController) {
        self.workspace = workspace
        self.library = library
        physical = workspace.physicalModel
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Área del modelo", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(10)
            .accessibilityLabel("Área del modelo físico")
            Divider()
            Group {
                switch tab {
                case .general: general
                case .screen: screen
                case .capture: capture
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var general: some View {
        Form {
            Section("Preset efectivo") {
                Picker(
                    "Device",
                    selection: Binding(
                        get: { workspace.resolvedDevice?.id ?? "" },
                        set: { id in
                            guard let device = library.document.devices.first(
                                where: { $0.id == id }
                            ) else { return }
                            workspace.selectModelDevice(device.value)
                        }
                    )
                ) {
                    ForEach(library.document.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .accessibilityLabel("Seleccionar preset de Device")
                Picker("Placement", selection: Binding(
                    get: { workspace.sourcePlacement },
                    set: { workspace.changeSourcePlacement($0) }
                )) {
                    ForEach(WorkspaceModel.SourcePlacement.allCases) {
                        Text($0.rawValue).tag($0)
                    }
                }
                Text("El preset se resuelve como snapshot. Placement pertenece al modelo actual.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Pipeline del fotograma seleccionado") {
                pipelineSummary
                Text("El resultado permanece ACEScg. La ODT del visor y ColorSync se aplican después.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Contribución maestra") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    domainAmount(
                        title: "Pantalla",
                        domain: .screen,
                        amount: physical.screenAmount,
                        enabled: true
                    )
                    Divider().gridCellColumns(3)
                    domainAmount(
                        title: "Captura",
                        domain: .capture,
                        amount: physical.captureAmount,
                        enabled: false
                    )
                }
                .frame(maxWidth: .infinity)
                Text("0 bypass/ideal · 1 físico calibrado · >1 artístico")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let device = workspace.resolvedDevice?.definition {
                Section("Resultado") {
                    LabeledContent("Pantalla", value: device.name)
                    LabeledContent(
                        "Superficie nativa",
                        value: "\(device.nativeWidth) × \(device.nativeHeight)"
                    )
                    LabeledContent(
                        "Etapas activas",
                        value: "Pantalla \(physical.activeScreenStageCount) · Captura \(physical.activeCaptureStageCount)"
                    )
                    LabeledContent("Estado", value: physical.frameState.modelLabel)
                    if let dimensions = physical.effectiveDimensions {
                        LabeledContent(
                            "Resultado efectivo",
                            value: "\(dimensions.width) × \(dimensions.height) · \(physical.computedQuality.modelLabel)"
                        )
                    }
                    if let seconds = physical.lastInteractiveSeconds {
                        LabeledContent(
                            "Último preview",
                            value: "\((seconds * 1_000).formatted(.number.precision(.fractionLength(1)))) ms"
                        )
                    }
                    if let completed = physical.completedFrame {
                        LabeledContent(
                            "Último Native",
                            value: "\(completed.effectiveDimensions.width) × \(completed.effectiveDimensions.height)"
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var pipelineSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                pipelineNode("Fuente ACEScg")
                Image(systemName: "arrow.right")
                pipelineNode("Pantalla")
                Image(systemName: "arrow.right")
                pipelineNode("Captura")
                Image(systemName: "arrow.right")
                pipelineNode("Resultado ACEScg")
            }
            VStack(alignment: .leading, spacing: 5) {
                pipelineNode("Fuente ACEScg → Pantalla")
                pipelineNode("→ Captura → Resultado ACEScg")
            }
        }
        .font(.caption)
    }

    private func pipelineNode(_ label: String) -> some View {
        Text(label)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func domainAmount(
        title: String,
        domain: PhysicalDomainID,
        amount: Double,
        enabled: Bool
    ) -> some View {
        GridRow(alignment: .center) {
            Text(title)
                .frame(width: 82, alignment: .leading)
            CleanSteppedSlider(value: detentedSliderBinding(
                value: amount,
                update: { workspace.changePhysicalDomainAmount($0, domain: domain) }
            ), range: 0 ... 2, step: 0.05, identityDetent: 1,
            accessibilityLabel: "Contribución maestra de \(title)")
            .frame(minWidth: 150, maxWidth: .infinity)
            .help("Incrementos de 0,05 · detente en 1 físico")
            .disabled(!enabled)
            TextField("", value: Binding(
                get: { amount },
                set: { workspace.changePhysicalDomainAmount($0, domain: domain) }
            ), format: .number.precision(.fractionLength(2)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 68)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel("Valor de contribución maestra de \(title)")
            .disabled(!enabled)
        }
        GridRow {
            contributionState(amount)
                .gridCellColumns(3)
        }
    }

    private var screen: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(ScreenPhysicalSection.allCases) { section in
                    physicalCard(
                        stage: .screen(section),
                        title: section.title,
                        affects: section.affects,
                        explanation: section.explanation,
                        isExpanded: Binding(
                            get: { expandedScreen.contains(section) },
                            set: { expanded in
                                if expanded { expandedScreen.insert(section) }
                                else { expandedScreen.remove(section) }
                            }
                        )
                    ) {
                        screenDetails(section)
                    }
                }
            }
            .padding(10)
        }
    }

    private var capture: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(CapturePhysicalSection.allCases) { section in
                    physicalCard(
                        stage: .capture(section),
                        title: section.title,
                        affects: section.affects,
                        explanation: section.explanation,
                        isExpanded: Binding(
                            get: { expandedCapture.contains(section) },
                            set: { expanded in
                                if expanded { expandedCapture.insert(section) }
                                else { expandedCapture.remove(section) }
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Pendiente del motor físico ABI v1.")
                                .foregroundStyle(.secondary)
                            Text("No se aplica ninguna aproximación ni simulación provisional.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func physicalCard<Details: View>(
        stage: PhysicalStageID,
        title: String,
        affects: String,
        explanation: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder details: @escaping () -> Details
    ) -> some View {
        let value = physical.stageValue(stage)
        return GroupBox {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(explanation)
                    details()
                    if !stage.isImplementedByPhysicalPanelV1 {
                        Label(
                            "Pendiente del motor físico; permanece en bypass y no se simula.",
                            systemImage: "wrench.and.screwdriver"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title).fontWeight(.medium)
                        Spacer(minLength: 6)
                        stageControl(stage, value: value)
                            .disabled(!stage.isImplementedByPhysicalPanelV1)
                    }
                    Text(affects)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    stageState(value)
                }
            }
        }
        .opacity(value.isDisabled ? 0.58 : 1)
        .contextMenu {
            Button(
                physical.isolatedStage == stage ? "Salir de aislar" : "Aislar etapa"
            ) {
                workspace.togglePhysicalIsolation(stage)
            }
            .disabled(!stage.isImplementedByPhysicalPanelV1)
            Button("Restablecer a físico") {
                workspace.resetPhysicalStage(stage)
            }
            .disabled(!stage.isImplementedByPhysicalPanelV1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Etapa \(title). \(affects)")
    }

    @ViewBuilder
    private func stageControl(
        _ stage: PhysicalStageID,
        value: PhysicalModelController.StageValue
    ) -> some View {
        switch value.control {
        case let .continuous(amount, limits):
            CleanSteppedSlider(value: detentedSliderBinding(
                value: amount,
                update: { workspace.changePhysicalStageAmount($0, stage: stage) }
            ), range: limits.visualRange, step: 0.05, identityDetent: 1,
            accessibilityLabel: "Contribución de la etapa")
            .frame(width: 116)
            .help("Incrementos de 0,05 · detente en 1 físico")
            TextField("Amount", value: Binding(
                get: { amount },
                set: { workspace.changePhysicalStageAmount($0, stage: stage) }
            ), format: .number.precision(.fractionLength(2)))
            .frame(width: 52)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel("Valor de contribución de la etapa")
        case let .discrete(enabled):
            Toggle("Activa", isOn: Binding(
                get: { enabled },
                set: { workspace.changePhysicalStageEnabled($0, stage: stage) }
            ))
            .toggleStyle(.checkbox)
            .accessibilityLabel("Activar etapa discreta")
        }
    }

    @ViewBuilder
    private func stageState(_ value: PhysicalModelController.StageValue) -> some View {
        switch value.control {
        case let .continuous(amount, _): contributionState(amount)
        case let .discrete(enabled):
            Text(enabled ? "Discreta · Activa" : "Discreta · Desactivada")
                .font(.caption2)
                .foregroundStyle(enabled ? NativeTheme.accent : .secondary)
        }
    }

    private func contributionState(_ amount: Double) -> some View {
        let label: String
        let color: Color
        if amount == 0 {
            label = "0 · Desactivado"
            color = .secondary
        } else if amount == 1 {
            label = "1 · Físico"
            color = NativeTheme.accent
        } else if amount > 1 {
            label = "\(amount.formatted(.number.precision(.fractionLength(2)))) · Artístico"
            color = .primary
        } else {
            label = "\(amount.formatted(.number.precision(.fractionLength(2)))) · Transición"
            color = .primary
        }
        return Text(label).font(.caption2).foregroundStyle(color)
    }

    private func detentedSliderBinding(
        value: Double,
        update: @escaping (Double) -> Void
    ) -> Binding<Double> {
        Binding(
            get: { value },
            set: { proposed in
                let stepped = (proposed / 0.05).rounded() * 0.05
                let detented = abs(proposed - 1) <= 0.027_5 ? 1 : stepped
                update(detented)
            }
        )
    }

    @ViewBuilder
    private func screenDetails(_ section: ScreenPhysicalSection) -> some View {
        if let device = workspace.resolvedDevice?.definition {
            switch section {
            case .emission:
                LabeledContent("Tecnología", value: device.panelTechnology.rawValue)
                LabeledContent(
                    "EOTF",
                    value: "γ \(device.eotfGamma.formatted(.number.precision(.fractionLength(2))))"
                )
                LabeledContent(
                    "Negro / blanco",
                    value: "\(device.blackLevelNits.formatted()) / \(device.whiteLevelNits.formatted()) nits"
                )
            case .subpixelGeometry:
                LabeledContent(
                    "Resolución",
                    value: "\(device.nativeWidth) × \(device.nativeHeight)"
                )
                LabeledContent("Orden", value: device.stripeLayout.rawValue)
                LabeledContent(
                    "Pitch",
                    value: "\(device.pixelPitchMicrometers.formatted(.number.precision(.fractionLength(1)))) µm"
                )
                LabeledContent("Matriz negra", value: device.blackMatrixFraction.formatted(.percent))
                Text("Aporta frecuencias espaciales; moiré y fringe aparecen al combinarla con Captura.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .temporal:
                LabeledContent(
                    "Flicker residual",
                    value: device.residualFlickerAmplitude.formatted(.percent)
                )
                LabeledContent("Banding creativo", value: device.bandingAmount.formatted())
            case .coverGlass:
                LabeledContent("Preset asociado", value: device.defaultCoverGlassPresetID)
            case .environment:
                Text("No hay un perfil de entorno conectado en el shell nativo actual.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Selecciona un Device en General.").foregroundStyle(.secondary)
        }
    }
}

private extension PhysicalModelController.StageValue {
    var isDisabled: Bool {
        switch control {
        case let .continuous(amount, _): amount == 0
        case let .discrete(enabled): !enabled
        }
    }
}

private extension PhysicalFrameState {
    var modelLabel: String {
        switch self {
        case .idle: "Sin cálculo Native"
        case .stale: "Desactualizado"
        case .rendering: "Renderizando"
        case .cancelled: "Cancelado"
        case .failed: "Fallido"
        case .complete: "Completo"
        }
    }
}

private extension PhysicalQuality {
    var modelLabel: String {
        switch self {
        case .draft: "Draft"
        case .medium: "Media"
        case .high: "Alta"
        case .native: "Nativa"
        }
    }
}

private extension ScreenPhysicalSection {
    var title: String {
        switch self {
        case .emission: "Emisión"
        case .subpixelGeometry: "Geometría subpíxel"
        case .temporal: "Temporal"
        case .coverGlass: "Cristal"
        case .environment: "Entorno"
        }
    }

    var affects: String {
        switch self {
        case .emission: "Afecta a: luminancia · contraste · color · nivel de negro"
        case .subpixelGeometry: "Afecta a: trama RGB · detalle · moiré · fringe"
        case .temporal: "Afecta a: flicker · uniformidad temporal · persistencia"
        case .coverGlass: "Afecta a: contraste · reflejos · difusión · negros"
        case .environment: "Afecta a: reflejos · contaminación de color · contraste aparente"
        }
    }

    var explanation: String {
        switch self {
        case .emission:
            "Convierte la señal del contenido en emisión luminosa según la tecnología."
        case .subpixelGeometry:
            "Define pitch, fill factor, matriz negra y distribución RGB/BGR."
        case .temporal:
            "Modela la variación de emisión durante la exposición. El banding creativo permanece separado."
        case .coverGlass:
            "Modela transmisión, Fresnel, roughness y tratamiento antirreflejo."
        case .environment:
            "Define la radiancia ambiente reflejada en el cristal."
        }
    }
}

private extension CapturePhysicalSection {
    var title: String {
        switch self {
        case .geometry: "Geometría cámara–pantalla"
        case .lens: "Lente"
        case .exposureShutter: "Exposición / obturación"
        case .sensorCFA: "Sensor / CFA"
        case .noise: "Ruido"
        case .developDemosaic: "Revelado / demosaic"
        }
    }

    var affects: String {
        switch self {
        case .geometry: "Afecta a: encuadre · perspectiva · escala física"
        case .lens: "Afecta a: enfoque · distorsión · aberración · transmisión"
        case .exposureShutter: "Afecta a: exposición · integración temporal · movimiento"
        case .sensorCFA: "Afecta a: muestreo · CFA · resolución nativa"
        case .noise: "Afecta a: señal · ruido de lectura · cuantización"
        case .developDemosaic: "Afecta a: reconstrucción · color · detalle"
        }
    }

    var explanation: String {
        switch self {
        case .geometry: "Define la relación física y la proyección entre cámara y pantalla."
        case .lens: "Integra el modelo óptico autoritativo de la lente seleccionada."
        case .exposureShutter: "Integra exposición, obturación global o rolling y movimiento."
        case .sensorCFA: "Define el raster físico de fotositos y su patrón CFA discreto."
        case .noise: "Aplica el modelo físico de exposición, ganancia, ruido y ADC."
        case .developDemosaic: "Reconstruye el mosaico mediante el revelado autoritativo."
        }
    }
}
