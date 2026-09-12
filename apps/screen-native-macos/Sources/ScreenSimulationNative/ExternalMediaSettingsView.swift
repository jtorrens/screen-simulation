import SwiftUI

struct ExternalMediaSettingsView: View {
    let usages: [ExternalMediaUsage]
    let navigate: (ExternalMediaUsage) -> Void
    let replace: (ExternalMediaUsage) -> Void
    let changeSourceDirectory: (ExternalMediaUsage) -> Void
    let reveal: (ExternalMediaUsage) -> Void

    @State private var sortOrder = [KeyPathComparator(\ExternalMediaUsage.systemItem)]

    private var sortedUsages: [ExternalMediaUsage] {
        usages.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Media Externa").font(.title2.weight(.semibold))
                Text(
                    usages.count == 1
                        ? "1 dependencia externa declarada"
                        : "\(usages.count) dependencias externas declaradas"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if usages.isEmpty {
                ContentUnavailableView(
                    "Sin media externa",
                    systemImage: "externaldrive",
                    description: Text(
                        "Las escenas guardadas no declaran Source, Reference ni HDRI externos."
                    )
                )
            } else {
                Table(sortedUsages, sortOrder: $sortOrder) {
                    TableColumn("Elemento del sistema", value: \.systemItem) { usage in
                        Button(usage.systemItem) { navigate(usage) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                            .help("Abrir \(usage.systemItem)")
                    }
                    TableColumn("Ruta absoluta", value: \.absoluteDirectoryPath) { usage in
                        mediaCell(usage.absoluteDirectoryPath, usage: usage, includeDirectory: true)
                    }
                    TableColumn("Nombre de archivo", value: \.fileName) { usage in
                        mediaCell(
                            usage.exists ? usage.fileName : "\(usage.fileName) · Ausente",
                            usage: usage,
                            includeDirectory: false
                        )
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func mediaCell(
        _ text: String,
        usage: ExternalMediaUsage,
        includeDirectory: Bool
    ) -> some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(usage.exists ? Color.secondary : Color.red)
            .help(usage.exists ? usage.authoredPath : "Ausente · \(usage.authoredPath)")
            .contextMenu {
                if includeDirectory {
                    Button("Cambiar directorio de origen…") {
                        changeSourceDirectory(usage)
                    }
                }
                Button("Reemplazar medio…") { replace(usage) }
                Button("Mostrar en Finder") { reveal(usage) }
                    .disabled(!usage.exists)
            }
    }
}
