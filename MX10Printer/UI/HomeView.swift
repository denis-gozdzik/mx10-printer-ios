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
                Button {
                    onNewPrint()
                } label: {
                    Label("Blank 384 px page", systemImage: "doc")
                }

                Button {
                    onOpenDocument(labelTemplate())
                } label: {
                    Label("Simple label", systemImage: "tag")
                }
            }
        }
    }

    private func labelTemplate() -> PrintDocument {
        let text = TextElement(
            frame: PrintElementFrame(x: 24, y: 40, width: 336, height: 120),
            text: "MX10\nLabel",
            fontSize: 34,
            isBold: true,
            alignment: .center
        )

        return PrintDocument(
            title: "Simple label",
            pages: [
                PrintPage(
                    height: 240,
                    elements: [.text(text)]
                )
            ]
        )
    }
}
