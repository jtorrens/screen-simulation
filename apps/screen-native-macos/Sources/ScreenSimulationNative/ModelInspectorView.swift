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
    @Environment(\.undoManager) private var undoManager
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
                            ), let cover = library.document.coverGlasses.first(
                                where: {
                                    $0.id == device.value.defaultCoverGlassPresetID
                                }
                            ) else { return }
                            workspace.selectModelDevice(
                                device.value,
                                coverGlass: cover.value
                            )
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
                Picker("Diagnóstico", selection: Binding(
                    get: { workspace.requestedPhysicalIntermediate },
                    set: { workspace.selectPhysicalIntermediate($0) }
                )) {
                    ForEach(PhysicalIntermediate.supportedDiagnostics) { intermediate in
                        Text(intermediate.uiLabel).tag(intermediate)
                    }
                }
                .help("Seleccionar el intermedio del pipeline físico")
                .accessibilityLabel("Intermedio del pipeline físico")
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
                        isBypassed: physical.screenIsBypassed
                    )
                    ForEach(PhysicalStageID.generalOverviewContinuous) { stage in
                        overviewStageAmount(stage)
                    }
                }
                .frame(maxWidth: .infinity)
                HStack(spacing: 14) {
                    Label("CFA · discreta", systemImage: "camera.filters")
                    Label("Revelado · discreto", systemImage: "camera.aperture")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("Captura no tiene master continuo. Los valores mostrados son los amounts autoritativos de cada etapa; CFA y Revelado permanecen disponibles como enables en Captura.")
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
                    LabeledContent("Publicación", value: workspace.physicalPublicationSummary)
                }
            }

            Section("Diagnóstico físico") {
                PhysicalDiagnosticsView(diagnostics: physical.diagnostics)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func overviewStageAmount(_ stage: PhysicalStageID) -> some View {
        let value = physical.stageValue(stage)
        if case let .continuous(amount, limits) = value.control {
            GridRow(alignment: .center) {
                Toggle(isOn: Binding(
                    get: { !value.isBypassed },
                    set: {
                        workspace.changePhysicalStageBypass(
                            !$0,
                            stage: stage,
                            undoManager: undoManager
                        )
                    }
                )) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(NativeTheme.accent)
                .frame(width: 38, alignment: .leading)
                .accessibilityLabel("Activar contribución de \(overviewTitle(stage))")
                .accessibilityHint("Desactivado conserva el valor y publica effective amount cero")
                PhysicalAnimationArmButton(
                    label: "Contribución de \(overviewTitle(stage))",
                    armed: workspace.physicalAnimationArmBinding("stage.amount.\(stage.id)")
                )
                Text(overviewTitle(stage))
                    .frame(width: 92, alignment: .leading)
                CleanSteppedSlider(value: detentedSliderBinding(
                    value: amount,
                    update: { workspace.changePhysicalStageAmount($0, stage: stage) }
                ), range: limits.visualRange, step: 0.05, identityDetent: 1,
                accessibilityLabel: "Contribución de \(overviewTitle(stage))")
                .frame(minWidth: 150, maxWidth: .infinity)
                .help("Incrementos de 0,05 · detente en 1 físico")
                .opacity(value.isBypassed ? 0.45 : 1)
                DeferredDoubleTextField("", value: Binding(
                    get: { amount },
                    set: { workspace.changePhysicalStageAmount($0, stage: stage) }
                ), in: limits.safeRange, fractionDigits: 0 ... 2)
                .textFieldStyle(.roundedBorder)
                .frame(width: 68)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel("Valor de contribución de \(overviewTitle(stage))")
                .accessibilityHint("Editable aunque la etapa esté omitida")
                .opacity(value.isBypassed ? 0.45 : 1)
            }
            GridRow {
                contributionState(amount, isBypassed: value.isBypassed)
                    .gridCellColumns(5)
            }
        }
    }

    private func overviewTitle(_ stage: PhysicalStageID) -> String {
        switch stage {
        case .screen(.temporal): "Temporal"
        case .screen(.coverGlass): "Cristal"
        case .screen(.environment): "Entorno"
        case .capture(.lens): "Lente"
        case .capture(.exposureShutter): "Obturación"
        case .capture(.noise): "Ruido"
        default: preconditionFailure("Etapa no autorizada en General")
        }
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
        isBypassed: Bool
    ) -> some View {
        GridRow(alignment: .center) {
            Toggle(isOn: Binding(
                get: { !isBypassed },
                set: {
                    workspace.changePhysicalDomainBypass(
                        !$0,
                        domain: domain,
                        undoManager: undoManager
                    )
                }
            )) { EmptyView() }
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(NativeTheme.accent)
            .frame(width: 38, alignment: .leading)
            .accessibilityLabel("Activar contribución maestra de \(title)")
            .accessibilityHint("Desactivado conserva el valor y publica effective amount cero")
            PhysicalAnimationArmButton(
                label: "Contribución maestra de \(title)",
                armed: workspace.physicalAnimationArmBinding("domain.amount.\(domain.id)")
            )
            Text(title)
                .frame(width: 92, alignment: .leading)
            CleanSteppedSlider(value: detentedSliderBinding(
                value: amount,
                update: { workspace.changePhysicalDomainAmount($0, domain: domain) }
            ), range: 0 ... 2, step: 0.05, identityDetent: 1,
            accessibilityLabel: "Contribución maestra de \(title)")
            .frame(minWidth: 150, maxWidth: .infinity)
            .help("Incrementos de 0,05 · detente en 1 físico")
            .opacity(isBypassed ? 0.45 : 1)
            DeferredDoubleTextField("", value: Binding(
                get: { amount },
                set: { workspace.changePhysicalDomainAmount($0, domain: domain) }
            ), in: PhysicalContributionLimits.standard.safeRange, fractionDigits: 0 ... 2)
            .textFieldStyle(.roundedBorder)
            .frame(width: 68)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel("Valor de contribución maestra de \(title)")
            .accessibilityHint("Editable aunque el dominio esté omitido")
            .opacity(isBypassed ? 0.45 : 1)
        }
        GridRow {
            contributionState(amount, isBypassed: isBypassed)
                .gridCellColumns(5)
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
                GroupBox("Cámara de captura") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Cámara", selection: Binding(
                            get: { workspace.selectedCapturePresetID ?? "" },
                            set: { id in
                                guard let preset = workspace.capturePresets.first(where: { $0.id == id }) else { return }
                                workspace.selectCapturePreset(preset, undoManager: undoManager)
                            }
                        )) {
                            ForEach(workspace.capturePresets) { preset in
                                Text(preset.name).tag(preset.id)
                            }
                        }
                        if let preset = workspace.capturePresets.first(where: {
                            $0.id == workspace.selectedCapturePresetID
                        }) {
                            Text(preset.calibration)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Valores copiados al modelo y editables · lente \(preset.defaultLensID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                        captureDetails(section)
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Grid(alignment: .leading, horizontalSpacing: 8) {
                        GridRow {
                            stageTitleControl(stage, title: title, value: value)
                            stageControl(stage, title: title, value: value)
                        }
                    }
                    .frame(maxWidth: .infinity)
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
            Button("Restablecer a físico") {
                workspace.resetPhysicalStage(stage)
            }
            Button("Restablecer parámetros del preset") {
                workspace.resetPhysicalParameters(stage, undoManager: undoManager)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Etapa \(title). \(affects)")
    }

    @ViewBuilder
    private func stageTitleControl(
        _ stage: PhysicalStageID,
        title: String,
        value: PhysicalModelController.StageValue
    ) -> some View {
        switch value.control {
        case .continuous:
            Toggle(isOn: Binding(
                get: { !value.isBypassed },
                set: { workspace.changePhysicalStageBypass(!$0, stage: stage, undoManager: undoManager) }
            )) {
                Text(title).fontWeight(.medium)
            }
            .toggleStyle(.switch)
            .tint(NativeTheme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Activar etapa \(title)")
        case .discrete:
            Text(title)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func stageControl(
        _ stage: PhysicalStageID,
        title: String,
        value: PhysicalModelController.StageValue
    ) -> some View {
        switch value.control {
        case let .continuous(amount, limits):
            CleanSteppedSlider(value: detentedSliderBinding(
                value: amount,
                update: { workspace.changePhysicalStageAmount($0, stage: stage) }
            ), range: limits.visualRange, step: 0.05, identityDetent: 1,
            accessibilityLabel: "Contribución de \(title)")
            .frame(width: 116)
            .help("Incrementos de 0,05 · detente en 1 físico")
            DeferredDoubleTextField("Amount", value: Binding(
                get: { amount },
                set: { workspace.changePhysicalStageAmount($0, stage: stage) }
            ), in: limits.safeRange, fractionDigits: 0 ... 2)
            .frame(width: 52)
            .multilineTextAlignment(.trailing)
            .accessibilityLabel("Valor de contribución de \(title)")
        case let .discrete(enabled):
            Toggle("Activa", isOn: Binding(
                get: { enabled },
                set: { workspace.changePhysicalStageEnabled($0, stage: stage) }
            ))
            .toggleStyle(.checkbox)
            .tint(NativeTheme.accent)
            .accessibilityLabel("Activar \(title)")
        }
    }

    @ViewBuilder
    private func stageState(_ value: PhysicalModelController.StageValue) -> some View {
        switch value.control {
        case let .continuous(amount, _):
            contributionState(amount, isBypassed: value.isBypassed)
        case let .discrete(enabled):
            Text(enabled ? "Discreta · Activa" : "Discreta · Desactivada")
                .font(.caption2)
                .foregroundStyle(enabled ? NativeTheme.accent : .secondary)
        }
    }

    private func contributionState(
        _ amount: Double,
        isBypassed: Bool = false
    ) -> some View {
        let label: String
        let color: Color
        if isBypassed {
            label = "BYPASSED · effective 0 · almacenado \(amount.formatted(.number.precision(.fractionLength(2))))"
            color = .secondary
        } else if amount == 0 {
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
        if let device = workspace.modelDeviceDefinition,
           let authored = workspace.physicalAuthoringState
        {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            switch section {
            case .emission:
                PhysicalDerivedRow(label: "Tecnología", value: device.panelTechnology.rawValue)
                PhysicalDerivedRow(label: "Modelo EOTF", value: device.emissionModel.rawValue)
                deviceDoubleRow("Gamma EOTF", \.eotfGamma, 1 ... 4, 0.01, "γ")
                deviceDoubleRow("Nivel negro", \.blackLevelNits, 0 ... 20, 0.01, "nit")
                deviceDoubleRow("Nivel blanco", \.whiteLevelNits, 1 ... 10_000, 1, "nit")
                chromaticityRows("Primaria R", \.red)
                chromaticityRows("Primaria G", \.green)
                chromaticityRows("Primaria B", \.blue)
                chromaticityRows("Blanco", \.white)
                vectorDeviceRows("Emisión angular", \.angularEmissionPower, range: 0 ... 64, step: 0.05)
            case .subpixelGeometry:
                deviceIntegerRow("Anchura raster", \.nativeWidth, 1 ... 32_768, "px")
                deviceIntegerRow("Altura raster", \.nativeHeight, 1 ... 32_768, "px")
                deviceDoubleRow("Anchura activa", \.activeWidthMeters, 0.001 ... 20, 0.001, "m")
                deviceDoubleRow("Altura activa", \.activeHeightMeters, 0.001 ... 20, 0.001, "m")
                GridRow {
                    PhysicalAnimationArmButton(
                        label: "Orden subpíxel",
                        armed: workspace.physicalAnimationArmBinding("device.stripeLayout")
                    )
                    Text("Orden subpíxel")
                    Picker("Orden subpíxel", selection: deviceBinding(\.stripeLayout)) {
                        ForEach(DeviceStripeLayout.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                    Text("")
                    deviceRestoreButton("Orden subpíxel", \.stripeLayout)
                }
                deviceDoubleRow("Black matrix", \.blackMatrixFraction, 0 ... 0.95, 0.01, "")
                PhysicalDerivedRow(
                    label: "Pixel pitch",
                    value: "\(device.pixelPitchMicrometers.formatted(.number.precision(.fractionLength(1)))) µm"
                )
            case .panelLightSpread:
                PhysicalDerivedRow(label: "Strength", value: "Control amount de cabecera")
                vectorDeviceRows("Core radius", \.panelLightSpread.coreRadiusMicrometers, range: 0 ... 5_000, step: 0.5, unit: "µm")
                vectorDeviceRows("Core weight", \.panelLightSpread.coreWeight, range: 0 ... 1, step: 0.01)
                vectorDeviceRows("Tail radius", \.panelLightSpread.tailRadiusMicrometers, range: 0 ... 20_000, step: 1, unit: "µm")
                vectorDeviceRows("Tail weight", \.panelLightSpread.tailWeight, range: 0 ... 1, step: 0.01)
            case .temporal:
                exactTimeRows("Periodo flicker", numerator: \.residualFlickerPeriod.numerator, denominator: \.residualFlickerPeriod.denominator)
                deviceDoubleRow("Flicker amplitude", \.residualFlickerAmplitude, 0 ... 1, 0.01, "")
                exactTimeRows("Fase flicker", numerator: \.residualFlickerPhase.numerator, denominator: \.residualFlickerPhase.denominator)
                exactTimeRows("Periodo banding", numerator: \.bandingPeriod.numerator, denominator: \.bandingPeriod.denominator)
                exactTimeRows("On banding", numerator: \.bandingOnDuration.numerator, denominator: \.bandingOnDuration.denominator)
                exactTimeRows("Fase banding", numerator: \.bandingPhase.numerator, denominator: \.bandingPhase.denominator)
                deviceDoubleRow("Banding artístico", \.bandingAmount, 0 ... 4, 0.05, "")
            case .coverGlass:
                GridRow {
                    Color.clear.frame(width: 16, height: 1)
                    Text("Preset base")
                    Picker("Preset Cover Glass", selection: Binding(
                        get: { authored.coverGlass.id },
                        set: { id in
                            guard let entry = library.document.coverGlasses.first(where: { $0.id == id }) else { return }
                            workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0.coverGlass = entry.value }
                        }
                    )) {
                        ForEach(library.document.coverGlasses) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                    Text("")
                    PhysicalParameterRestoreButton(
                        label: "Preset Cover Glass",
                        isModified: authored.coverGlass != workspace.physicalPresetAuthoringState!.coverGlass,
                        action: {
                            let value = workspace.physicalPresetAuthoringState!.coverGlass
                            workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0.coverGlass = value }
                        }
                    )
                }
                PhysicalDerivedRow(label: "Strength", value: "Control amount de cabecera")
                physicalDoubleRow("Espesor", \.coverGlass.thicknessMillimeters, 0.01 ... 20, 0.01, "mm")
                physicalDoubleRow("Índice refracción", \.coverGlass.refractiveIndex, 1 ... 3, 0.01, "IOR")
                physicalDoubleRow("Eficiencia AR", \.coverGlass.antiReflectiveEfficiency, 0 ... 1, 0.01, "")
                vectorPhysicalRows("Absorción", \.coverGlass.absorptionPerMillimeter, range: 0 ... 20, step: 0.01, unit: "mm⁻¹")
                physicalDoubleRow("Roughness", \.coverGlass.roughness, 0 ... 1, 0.01, "")
                physicalDoubleRow("Haze", \.coverGlass.haze, 0 ... 1, 0.01, "")
            case .environment:
                GridRow {
                    PhysicalAnimationArmButton(
                        label: "Patrón HDR",
                        armed: workspace.physicalAnimationArmBinding("environment.pattern")
                    )
                    Text("Patrón HDR")
                    Picker("Patrón HDR", selection: physicalUInt32Binding(\.environment.pattern)) {
                        Text("Ninguno").tag(UInt32(0))
                        Text("Cielo / suelo").tag(UInt32(1))
                        Text("Softbox").tag(UInt32(2))
                    }.labelsHidden()
                    Text("")
                    physicalRestoreButton("Patrón HDR", \.environment.pattern)
                }
                PhysicalDerivedRow(label: "Strength", value: "Control amount de cabecera")
                vectorPhysicalRows("Ambient ACEScg", \.environment.ambientRadianceACEScg, range: 0 ... 100_000, step: 1, unit: "nit")
                vectorPhysicalRows("Key ACEScg", \.environment.keyRadianceACEScg, range: 0 ... 100_000, step: 1, unit: "nit")
                vectorPhysicalRows("Dirección key", \.environment.keyDirectionLocal, range: -1 ... 1, step: 0.01)
                physicalDoubleRow("Radio key", \.environment.keyAngularRadiusDegrees, 0.01 ... 180, 0.1, "°")
                physicalDoubleRow("Rotación", \.environment.rotationDegrees, -360 ... 360, 0.5, "°")
            }
            }
        } else {
            Text("Selecciona un Device en General.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func captureDetails(_ section: CapturePhysicalSection) -> some View {
        if let authored = workspace.physicalAuthoringState {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                switch section {
                case .geometry:
                    PhysicalDerivedRow(label: "Input temporal", value: "STATIC_INPUT · tracks constantes")
                    physicalArrayRows("Cámara posición", \.cameraPose.position, labels: ["X", "Y", "Z"], range: -10 ... 10, step: 0.5, unit: "m")
                    physicalRotationRows("Cámara rotación", \.cameraPose.quaternion)
                    physicalArrayRows("Pantalla posición", \.screenPose.position, labels: ["X", "Y", "Z"], range: -10 ... 10, step: 0.5, unit: "m")
                    physicalRotationRows("Pantalla rotación", \.screenPose.quaternion)
                    physicalDoubleRow("Near clip", \.sceneLens.nearClipMeters, 0.0001 ... 100, 0.001, "m")
                    physicalDoubleRow("Far clip", \.sceneLens.farClipMeters, 0.01 ... 100_000, 0.1, "m")
                case .lens:
                    PhysicalDerivedRow(label: "Preset", value: "Valores efectivos del proyecto · ABI v2")
                    physicalDoubleRow("Focal", \.sceneLens.focalLengthMillimeters, 0.1 ... 2_000, 0.1, "mm")
                    physicalDoubleRow("Sensor ancho", \.sceneLens.sensorWidthMillimeters, 0.1 ... 200, 0.1, "mm")
                    physicalDoubleRow("Sensor alto", \.sceneLens.sensorHeightMillimeters, 0.1 ... 200, 0.1, "mm")
                    physicalArrayRows("Lens shift", \.sceneLens.lensShift, labels: ["X", "Y"], range: -2 ... 2, step: 0.001)
                    physicalDoubleRow("Distancia foco", \.sceneLens.focusDistanceMeters, 0.001 ... 100_000, 0.01, "m")
                    physicalDoubleRow("Diafragma", \.sceneLens.fStop, 0.1 ... 128, 0.05, "f/")
                    physicalArrayRows("Distorsión radial", \.sceneLens.radialDistortion, labels: ["K1", "K2", "K3"], range: -10 ... 10, step: 0.001)
                    physicalArrayRows("Distorsión tangencial", \.sceneLens.tangentialDistortion, labels: ["P1", "P2"], range: -10 ... 10, step: 0.001)
                    physicalArrayRows("CA longitudinal", \.sceneLens.longitudinalChromaticMeters, labels: ["R", "G", "B"], range: -1 ... 1, step: 0.0001, unit: "m")
                    physicalArrayRows("CA lateral", \.sceneLens.lateralChromaticScale, labels: ["R", "G", "B"], range: 0 ... 4, step: 0.001)
                    physicalDoubleRow("Vignetting", \.sceneLens.vignettingStrength, 0 ... 4, 0.01, "")
                    physicalArrayRows("Transmisión", \.sceneLens.transmissionRGB, labels: ["R", "G", "B"], range: 0 ... 4, step: 0.01)
                    physicalDoubleRow("Softness centro", \.sceneLens.centerSoftnessMicrometers, 0 ... 10_000, 0.1, "µm")
                    physicalDoubleRow("Softness borde", \.sceneLens.edgeSoftnessMicrometers, 0 ... 10_000, 0.1, "µm")
                case .exposureShutter:
                    physicalUInt16Row("Muestras temporales", \.shutterMotion.temporalSamples, 1 ... 256)
                    GridRow {
                        PhysicalAnimationArmButton(
                            label: "Tipo obturador",
                            armed: workspace.physicalAnimationArmBinding("shutter.readoutKind")
                        )
                        Text("Tipo obturador")
                        Picker("Tipo obturador", selection: physicalUInt16Binding(\.shutterMotion.readoutKind)) {
                            Text("Global").tag(UInt16(0))
                            Text("Rolling").tag(UInt16(1))
                        }.labelsHidden()
                        Text("")
                        physicalRestoreButton("Tipo obturador", \.shutterMotion.readoutKind)
                    }
                    physicalInt64Row("Readout num", \.shutterMotion.readoutDurationNumerator, -1_000_000 ... 1_000_000)
                    physicalUInt32Row("Readout den", \.shutterMotion.readoutDurationDenominator, 1 ... 1_000_000)
                    physicalUInt32Row("Dirección readout", \.shutterMotion.readoutDirection, 0 ... 3)
                    physicalDoubleRow("ND", \.shutterMotion.neutralDensityStops, 0 ... 32, 0.05, "stops")
                    physicalUInt64Row("Noise seed", \.shutterMotion.noiseSeed, 0 ... Int.max)
                    physicalInt64Row("Open offset num", \.shutterMotion.openOffsetNumerator, -1_000_000 ... 1_000_000)
                    physicalUInt32Row("Open offset den", \.shutterMotion.openOffsetDenominator, 1 ... 1_000_000)
                    physicalInt64Row("Close offset num", \.shutterMotion.closeOffsetNumerator, -1_000_000 ... 1_000_000)
                    physicalUInt32Row("Close offset den", \.shutterMotion.closeOffsetDenominator, 1 ... 1_000_000)
                    PhysicalDerivedRow(label: "Motion", value: "Tracks constantes · no motion activo")
                case .sensorCFA:
                    PhysicalDerivedRow(label: "Preset", value: "Valores efectivos del proyecto · ABI v2")
                    physicalUInt32Row("Anchura sensor", \.sensor.nativeWidth, 1 ... 32_768, unit: "px")
                    physicalUInt32Row("Altura sensor", \.sensor.nativeHeight, 1 ... 32_768, unit: "px")
                    GridRow {
                        PhysicalAnimationArmButton(
                            label: "Patrón CFA",
                            armed: workspace.physicalAnimationArmBinding("sensor.bayerPattern")
                        )
                        Text("Patrón CFA")
                        Picker("Patrón CFA", selection: physicalUInt32Binding(\.sensor.bayerPattern)) {
                            Text("RGGB").tag(UInt32(0)); Text("BGGR").tag(UInt32(1))
                            Text("GRBG").tag(UInt32(2)); Text("GBRG").tag(UInt32(3))
                        }.labelsHidden()
                        Text("")
                        physicalRestoreButton("Patrón CFA", \.sensor.bayerPattern)
                    }
                    physicalArrayRows("ACEScg→Sensor", \.sensor.acescgToSensor, labels: (0..<9).map { "M\($0 / 3)\($0 % 3)" }, range: -8 ... 8, step: 0.001)
                    physicalArrayRows("Saturación", \.sensor.saturationIlluminanceSeconds, labels: ["R", "G", "B"], range: 0.0001 ... 1_000_000, step: 0.01, unit: "lux·s")
                    physicalDoubleRow("Full well", \.sensor.fullWellElectrons, 1 ... 10_000_000, 1, "e⁻")
                    physicalUInt32Row("ADC", \.sensor.adcBits, 1 ... 31, unit: "bit")
                case .noise:
                    physicalDoubleRow("Dark current", \.sensor.darkCurrentElectronsPerSecond, 0 ... 1_000_000, 0.01, "e⁻/s")
                    physicalDoubleRow("Read noise", \.sensor.readNoiseElectronsRMS, 0 ... 1_000_000, 0.01, "e⁻ RMS")
                    physicalDoubleRow("Analog gain", \.sensor.analogGain, 0.0001 ... 1_000_000, 0.01, "")
                    physicalUInt64Row("Noise seed", \.shutterMotion.noiseSeed, 0 ... Int.max)
                case .developDemosaic:
                    PhysicalDerivedRow(label: "Demosaic", value: authored.develop.demosaicAuthority)
                    developWhiteBalanceRow(.temperature)
                    developWhiteBalanceRow(.tint)
                    physicalDoubleRow("Exposición", \.develop.exposureEV, -32 ... 32, 0.05, "EV")
                }
            }
        } else {
            Text("Selecciona un Device en General.").foregroundStyle(.secondary)
        }
    }

    private func deviceBinding<Value>(
        _ keyPath: WritableKeyPath<DeviceDefinition, Value>
    ) -> Binding<Value> {
        Binding(
            get: { workspace.modelDeviceDefinition![keyPath: keyPath] },
            set: { newValue in
                workspace.updateModelDevice(undoManager: undoManager) {
                    $0[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func physicalBinding<Value>(
        _ keyPath: WritableKeyPath<PhysicalPipelineAuthoringState, Value>
    ) -> Binding<Value> {
        Binding(
            get: { workspace.physicalAuthoringState![keyPath: keyPath] },
            set: { newValue in
                workspace.updatePhysicalAuthoring(undoManager: undoManager) {
                    $0[keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func deviceRestoreButton<Value: Equatable>(
        _ label: String,
        _ keyPath: WritableKeyPath<DeviceDefinition, Value>
    ) -> some View {
        PhysicalParameterRestoreButton(
            label: label,
            isModified: workspace.modelDeviceDefinition![keyPath: keyPath]
                != workspace.physicalPresetDeviceDefinition![keyPath: keyPath],
            action: {
                let value = workspace.physicalPresetDeviceDefinition![keyPath: keyPath]
                workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func physicalRestoreButton<Value: Equatable>(
        _ label: String,
        _ keyPath: WritableKeyPath<PhysicalPipelineAuthoringState, Value>
    ) -> some View {
        PhysicalParameterRestoreButton(
            label: label,
            isModified: workspace.physicalAuthoringState![keyPath: keyPath]
                != workspace.physicalPresetAuthoringState![keyPath: keyPath],
            action: {
                let value = workspace.physicalPresetAuthoringState![keyPath: keyPath]
                workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func deviceDoubleRow(
        _ label: String,
        _ keyPath: WritableKeyPath<DeviceDefinition, Double>,
        _ range: ClosedRange<Double>,
        _ step: Double,
        _ unit: String
    ) -> some View {
        PhysicalDoubleParameterRow(
            label: label,
            unit: unit,
            range: range,
            step: step,
            value: deviceBinding(keyPath),
            defaultValue: workspace.physicalPresetDeviceDefinition![keyPath: keyPath],
            onRestore: {
                let value = workspace.physicalPresetDeviceDefinition![keyPath: keyPath]
                workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: keyPath] = value }
            },
            animationArmed: workspace.physicalAnimationArmBinding(String(describing: keyPath))
        )
    }

    private func physicalDoubleRow(
        _ label: String,
        _ keyPath: WritableKeyPath<PhysicalPipelineAuthoringState, Double>,
        _ range: ClosedRange<Double>,
        _ step: Double,
        _ unit: String
    ) -> some View {
        PhysicalDoubleParameterRow(
            label: label,
            unit: unit,
            range: range,
            step: step,
            value: physicalBinding(keyPath),
            defaultValue: workspace.physicalPresetAuthoringState![keyPath: keyPath],
            onRestore: {
                let value = workspace.physicalPresetAuthoringState![keyPath: keyPath]
                workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath] = value }
            },
            animationArmed: workspace.physicalAnimationArmBinding(String(describing: keyPath))
        )
    }

    private enum DevelopWhiteBalanceControl {
        case temperature, tint
    }

    private func developWhiteBalanceRow(_ control: DevelopWhiteBalanceControl) -> some View {
        let baseline = DevelopWhiteBalanceControls.controls(
            gains: workspace.physicalPresetAuthoringState!.develop.whiteBalance,
            acescgToSensor: workspace.physicalPresetAuthoringState!.sensor.acescgToSensor
        )
        let isTemperature = control == .temperature
        let label = isTemperature ? "Temperatura" : "Tinte"
        let range = isTemperature
            ? DevelopWhiteBalanceControls.temperatureRange
            : DevelopWhiteBalanceControls.tintRange
        let animationID = isTemperature ? "develop.temperatureKelvin" : "develop.tint"
        return PhysicalDoubleParameterRow(
            label: label,
            unit: isTemperature ? "K" : "G–M",
            range: range,
            step: isTemperature ? 50 : 1,
            value: Binding(
                get: {
                    let state = workspace.physicalAuthoringState!
                    let controls = DevelopWhiteBalanceControls.controls(
                        gains: state.develop.whiteBalance,
                        acescgToSensor: state.sensor.acescgToSensor
                    )
                    return isTemperature ? controls.temperatureKelvin : controls.tint
                },
                set: { value in
                    workspace.updatePhysicalAuthoring(undoManager: undoManager) { state in
                        let controls = DevelopWhiteBalanceControls.controls(
                            gains: state.develop.whiteBalance,
                            acescgToSensor: state.sensor.acescgToSensor
                        )
                        state.develop.whiteBalance = DevelopWhiteBalanceControls.gains(
                            temperatureKelvin: isTemperature ? value : controls.temperatureKelvin,
                            tint: isTemperature ? controls.tint : value,
                            acescgToSensor: state.sensor.acescgToSensor
                        )
                    }
                }
            ),
            defaultValue: isTemperature ? baseline.temperatureKelvin : baseline.tint,
            onRestore: {
                workspace.updatePhysicalAuthoring(undoManager: undoManager) { state in
                    let controls = DevelopWhiteBalanceControls.controls(
                        gains: state.develop.whiteBalance,
                        acescgToSensor: state.sensor.acescgToSensor
                    )
                    state.develop.whiteBalance = DevelopWhiteBalanceControls.gains(
                        temperatureKelvin: isTemperature ? baseline.temperatureKelvin : controls.temperatureKelvin,
                        tint: isTemperature ? controls.tint : baseline.tint,
                        acescgToSensor: state.sensor.acescgToSensor
                    )
                }
            },
            animationArmed: workspace.physicalAnimationArmBinding(animationID)
        )
    }

    private func deviceIntegerRow(
        _ label: String,
        _ keyPath: WritableKeyPath<DeviceDefinition, Int>,
        _ range: ClosedRange<Int>,
        _ unit: String
    ) -> some View {
        PhysicalIntegerParameterRow(
            label: label,
            unit: unit,
            range: range,
            value: deviceBinding(keyPath),
            defaultValue: workspace.physicalPresetDeviceDefinition![keyPath: keyPath],
            onRestore: {
                let value = workspace.physicalPresetDeviceDefinition![keyPath: keyPath]
                workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: keyPath] = value }
            },
            animationArmed: workspace.physicalAnimationArmBinding(String(describing: keyPath))
        )
    }

    private func physicalUInt32Binding(
        _ keyPath: WritableKeyPath<PhysicalPipelineAuthoringState, UInt32>
    ) -> Binding<UInt32> {
        physicalBinding(keyPath)
    }

    private func physicalUInt16Binding(
        _ keyPath: WritableKeyPath<PhysicalPipelineAuthoringState, UInt16>
    ) -> Binding<UInt16> {
        physicalBinding(keyPath)
    }

    @ViewBuilder
    private func physicalArrayRows(
        _ label: String,
        _ keyPath: WritableKeyPath<PhysicalPipelineAuthoringState, [Double]>,
        labels: [String],
        range: ClosedRange<Double>,
        step: Double,
        unit: String = ""
    ) -> some View {
        ForEach(labels.indices, id: \.self) { index in
            PhysicalDoubleParameterRow(
                label: "\(label) \(labels[index])", unit: unit,
                range: range, step: step,
                value: Binding(
                    get: { workspace.physicalAuthoringState![keyPath: keyPath][index] },
                    set: { value in workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath][index] = value } }
                ),
                defaultValue: workspace.physicalPresetAuthoringState![keyPath: keyPath][index],
                onRestore: {
                    let value = workspace.physicalPresetAuthoringState![keyPath: keyPath][index]
                    workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath][index] = value }
                },
                animationArmed: workspace.physicalAnimationArmBinding(
                    "\(String(describing: keyPath)).\(index)"
                )
            )
        }
    }

    @ViewBuilder
    private func physicalRotationRows(
        _ label: String,
        _ keyPath: WritableKeyPath<PhysicalPipelineAuthoringState, [Double]>
    ) -> some View {
        ForEach(0..<3, id: \.self) { index in
            let axes = ["X", "Y", "Z"]
            PhysicalDoubleParameterRow(
                label: "\(label) \(axes[index])", unit: "°",
                range: -180 ... 180, step: 5,
                value: Binding(
                    get: {
                        PoseRotationProjection.degrees(
                            from: workspace.physicalAuthoringState![keyPath: keyPath]
                        )[index]
                    },
                    set: { value in
                        workspace.updatePhysicalAuthoring(undoManager: undoManager) { state in
                            var rotations = PoseRotationProjection.degrees(
                                from: state[keyPath: keyPath]
                            )
                            rotations[index] = value
                            state[keyPath: keyPath] = PoseRotationProjection.quaternion(
                                fromDegrees: rotations
                            )
                        }
                    }
                ),
                defaultValue: PoseRotationProjection.degrees(
                    from: workspace.physicalPresetAuthoringState![keyPath: keyPath]
                )[index],
                onRestore: {
                    let value = workspace.physicalPresetAuthoringState![keyPath: keyPath]
                    workspace.updatePhysicalAuthoring(undoManager: undoManager) {
                        $0[keyPath: keyPath] = value
                    }
                },
                animationArmed: workspace.physicalAnimationArmBinding(
                    "\(String(describing: keyPath)).rotation.\(index)"
                )
            )
        }
    }

    private func physicalUInt16Row(
        _ label: String,
        _ keyPath: WritableKeyPath<PhysicalPipelineAuthoringState, UInt16>,
        _ range: ClosedRange<Int>
    ) -> some View {
        PhysicalIntegerParameterRow(
            label: label, unit: "", range: range,
            value: Binding(
                get: { Int(workspace.physicalAuthoringState![keyPath: keyPath]) },
                set: { value in workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath] = UInt16(value) } }
            ),
            defaultValue: Int(workspace.physicalPresetAuthoringState![keyPath: keyPath]),
            onRestore: {
                let value = workspace.physicalPresetAuthoringState![keyPath: keyPath]
                workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath] = value }
            },
            animationArmed: workspace.physicalAnimationArmBinding(String(describing: keyPath))
        )
    }

    private func physicalUInt32Row(
        _ label: String,
        _ keyPath: WritableKeyPath<PhysicalPipelineAuthoringState, UInt32>,
        _ range: ClosedRange<Int>,
        unit: String = ""
    ) -> some View {
        PhysicalIntegerParameterRow(
            label: label, unit: unit, range: range,
            value: Binding(
                get: { Int(workspace.physicalAuthoringState![keyPath: keyPath]) },
                set: { value in workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath] = UInt32(value) } }
            ),
            defaultValue: Int(workspace.physicalPresetAuthoringState![keyPath: keyPath]),
            onRestore: {
                let value = workspace.physicalPresetAuthoringState![keyPath: keyPath]
                workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath] = value }
            },
            animationArmed: workspace.physicalAnimationArmBinding(String(describing: keyPath))
        )
    }

    private func physicalInt64Row(
        _ label: String,
        _ keyPath: WritableKeyPath<PhysicalPipelineAuthoringState, Int64>,
        _ range: ClosedRange<Int>
    ) -> some View {
        PhysicalIntegerParameterRow(
            label: label, unit: "", range: range,
            value: Binding(
                get: { Int(workspace.physicalAuthoringState![keyPath: keyPath]) },
                set: { value in workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath] = Int64(value) } }
            ),
            defaultValue: Int(workspace.physicalPresetAuthoringState![keyPath: keyPath]),
            onRestore: {
                let value = workspace.physicalPresetAuthoringState![keyPath: keyPath]
                workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath] = value }
            },
            animationArmed: workspace.physicalAnimationArmBinding(String(describing: keyPath))
        )
    }

    private func physicalUInt64Row(
        _ label: String,
        _ keyPath: WritableKeyPath<PhysicalPipelineAuthoringState, UInt64>,
        _ range: ClosedRange<Int>
    ) -> some View {
        PhysicalIntegerParameterRow(
            label: label, unit: "", range: range,
            value: Binding(
                get: { Int(clamping: workspace.physicalAuthoringState![keyPath: keyPath]) },
                set: { value in workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath] = UInt64(value) } }
            ),
            defaultValue: Int(clamping: workspace.physicalPresetAuthoringState![keyPath: keyPath]),
            onRestore: {
                let value = workspace.physicalPresetAuthoringState![keyPath: keyPath]
                workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath] = value }
            },
            animationArmed: workspace.physicalAnimationArmBinding(String(describing: keyPath))
        )
    }

    @ViewBuilder
    private func chromaticityRows(
        _ label: String,
        _ keyPath: WritableKeyPath<DeviceDefinition, DeviceChromaticity>
    ) -> some View {
        PhysicalDoubleParameterRow(
            label: "\(label) x", unit: "", range: 0 ... 1, step: 0.001,
            value: Binding(
                get: { workspace.modelDeviceDefinition![keyPath: keyPath].x },
                set: { value in workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: keyPath].x = value } }
            ),
            defaultValue: workspace.physicalPresetDeviceDefinition![keyPath: keyPath].x,
            onRestore: {
                let value = workspace.physicalPresetDeviceDefinition![keyPath: keyPath].x
                workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: keyPath].x = value }
            }
        )
        PhysicalDoubleParameterRow(
            label: "\(label) y", unit: "", range: 0 ... 1, step: 0.001,
            value: Binding(
                get: { workspace.modelDeviceDefinition![keyPath: keyPath].y },
                set: { value in workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: keyPath].y = value } }
            ),
            defaultValue: workspace.physicalPresetDeviceDefinition![keyPath: keyPath].y,
            onRestore: {
                let value = workspace.physicalPresetDeviceDefinition![keyPath: keyPath].y
                workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: keyPath].y = value }
            }
        )
    }

    @ViewBuilder
    private func vectorDeviceRows(
        _ label: String,
        _ keyPath: WritableKeyPath<DeviceDefinition, [Double]>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String = ""
    ) -> some View {
        ForEach(0..<3, id: \.self) { index in
            PhysicalDoubleParameterRow(
                label: "\(label) \(["R", "G", "B"][index])",
                unit: unit, range: range, step: step,
                value: Binding(
                    get: { workspace.modelDeviceDefinition![keyPath: keyPath][index] },
                    set: { value in workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: keyPath][index] = value } }
                ),
                defaultValue: workspace.physicalPresetDeviceDefinition![keyPath: keyPath][index],
                onRestore: {
                    let value = workspace.physicalPresetDeviceDefinition![keyPath: keyPath][index]
                    workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: keyPath][index] = value }
                }
            )
        }
    }

    @ViewBuilder
    private func vectorPhysicalRows(
        _ label: String,
        _ keyPath: WritableKeyPath<PhysicalPipelineAuthoringState, [Double]>,
        range: ClosedRange<Double>,
        step: Double,
        unit: String = ""
    ) -> some View {
        ForEach(0..<3, id: \.self) { index in
            PhysicalDoubleParameterRow(
                label: "\(label) \(["R", "G", "B"][index])",
                unit: unit, range: range, step: step,
                value: Binding(
                    get: { workspace.physicalAuthoringState![keyPath: keyPath][index] },
                    set: { value in workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath][index] = value } }
                ),
                defaultValue: workspace.physicalPresetAuthoringState![keyPath: keyPath][index],
                onRestore: {
                    let value = workspace.physicalPresetAuthoringState![keyPath: keyPath][index]
                    workspace.updatePhysicalAuthoring(undoManager: undoManager) { $0[keyPath: keyPath][index] = value }
                }
            )
        }
    }

    @ViewBuilder
    private func exactTimeRows(
        _ label: String,
        numerator: WritableKeyPath<DeviceDefinition, Int64>,
        denominator: WritableKeyPath<DeviceDefinition, UInt32>
    ) -> some View {
        PhysicalIntegerParameterRow(
            label: "\(label) num", unit: "", range: -1_000_000 ... 1_000_000,
            value: Binding(
                get: { Int(workspace.modelDeviceDefinition![keyPath: numerator]) },
                set: { value in workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: numerator] = Int64(value) } }
            ),
            defaultValue: Int(workspace.physicalPresetDeviceDefinition![keyPath: numerator]),
            onRestore: {
                let value = workspace.physicalPresetDeviceDefinition![keyPath: numerator]
                workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: numerator] = value }
            }
        )
        PhysicalIntegerParameterRow(
            label: "\(label) den", unit: "", range: 1 ... 1_000_000,
            value: Binding(
                get: { Int(workspace.modelDeviceDefinition![keyPath: denominator]) },
                set: { value in workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: denominator] = UInt32(value) } }
            ),
            defaultValue: Int(workspace.physicalPresetDeviceDefinition![keyPath: denominator]),
            onRestore: {
                let value = workspace.physicalPresetDeviceDefinition![keyPath: denominator]
                workspace.updateModelDevice(undoManager: undoManager) { $0[keyPath: denominator] = value }
            }
        )
    }

}

private extension PhysicalModelController.StageValue {
    var isDisabled: Bool {
        if isBypassed { return true }
        return switch control {
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
        case .panelLightSpread: "Panel Light Spread"
        case .temporal: "Temporal"
        case .coverGlass: "Cristal"
        case .environment: "Entorno"
        }
    }

    var affects: String {
        switch self {
        case .emission: "Afecta a: luminancia · contraste · color · nivel de negro"
        case .subpixelGeometry: "Afecta a: trama RGB · detalle · moiré · fringe"
        case .panelLightSpread: "Afecta a: contaminación luminosa · bloom entre píxeles · color"
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
        case .panelLightSpread:
            "Difunde físicamente emisión entre píxeles y subpíxeles mediante el perfil resuelto del panel."
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
