import SwiftUI

struct HomeView: View {
    @ObservedObject var bluetoothManager: MX10BluetoothManager
    @ObservedObject var documentStore: PrintDocumentStore

    let onNewPrint: () -> Void
    let onOpenDocument: (PrintDocument) -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("MX10 Printer")
                        .font(.largeTitle.bold())

                    HStack {
                        Text("Printer status:")
                        Spacer()
                        Text(bluetoothManager.isConnected ? "Connected" : "Disconnected")
                            .fontWeight(.semibold)
                            .foregroundStyle(bluetoothManager.isConnected ? .green : .secondary)
                    }

                    Button {
                        onNewPrint()
                    } label: {
                        Label("New Print", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(.vertical, 8)
            }

            Section("Recent") {
                if documentStore.recentDocuments.isEmpty {
                    Text("No recent prints")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(documentStore.recentDocuments) { document in
                        Button {
                            onOpenDocument(document)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(document.title)
                                    .font(.headline)
                                Text(document.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Templates") {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ],
                    spacing: 12
                ) {
                    Button {
                        onNewPrint()
                    } label: {
                        TemplateCard(
                            title: "Blank",
                            subtitle: "Pusta strona 384 px",
                            systemImageName: "doc"
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(PrintTemplateKind.allCases) { template in
                        Button {
                            onOpenDocument(template.makeDocument())
                        } label: {
                            TemplateCard(
                                title: template.title,
                                subtitle: template.subtitle,
                                systemImageName: template.systemImageName
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct TemplateCard: View {
    let title: String
    let subtitle: String
    let systemImageName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImageName)
                .font(.system(size: 30, weight: .semibold))
                .frame(height: 34)
                .foregroundStyle(.primary)

            Text(title)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
