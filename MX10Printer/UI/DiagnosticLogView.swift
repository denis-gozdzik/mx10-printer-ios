import SwiftUI
import UIKit

struct DiagnosticLogView: View {
    @ObservedObject var logger: DiagnosticLogger
    @ObservedObject var bluetoothManager: MX10BluetoothManager
    @ObservedObject var preferencesStore: PrintingPreferencesStore
    @ObservedObject var printQueue: PrintQueue

    @State private var selectedCategory: DiagnosticCategory?
    @State private var shareItem: DiagnosticShareItem?
    @State private var statusMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            filters

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filteredEntries) { entry in
                            Text(entry.formattedLine)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(entry.category == .error ? .red : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(12)
                }
                .background(Color(.systemBackground))
                .onChange(of: logger.entries.count) { _, _ in
                    guard let last = filteredEntries.last else {
                        return
                    }

                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            if let first = filteredEntries.first {
                                proxy.scrollTo(first.id, anchor: .top)
                            }
                        } label: {
                            Label("Oldest", systemImage: "arrow.up.to.line")
                        }

                        Button {
                            if let last = filteredEntries.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        } label: {
                            Label("Newest", systemImage: "arrow.down.to.line")
                        }
                    }
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
        }
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = logger.exportText(context: exportContext)
                    statusMessage = "Copied"
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }

                Button {
                    shareLog()
                } label: {
                    Label("Share Log", systemImage: "square.and.arrow.up")
                }

                Button(role: .destructive) {
                    logger.clear()
                    statusMessage = "Cleared"
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(activityItems: [item.url])
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    selectedCategory = nil
                } label: {
                    Text("All")
                }
                .buttonStyle(.borderedProminent)
                .tint(selectedCategory == nil ? .accentColor : .secondary)

                ForEach(DiagnosticCategory.allCases) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        Text(category.rawValue)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(selectedCategory == category ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private var filteredEntries: [DiagnosticLogEntry] {
        guard let selectedCategory else {
            return logger.entries
        }

        return logger.entries.filter { $0.category == selectedCategory }
    }

    private var exportContext: DiagnosticLogExportContext {
        DiagnosticLogExportContext(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
            iosVersion: UIDevice.current.systemVersion,
            deviceModel: Self.deviceModelIdentifier(),
            printerPeripheralUUID: bluetoothManager.connectedPeripheralIdentifier?.uuidString ?? "None",
            bluetoothState: bluetoothManager.bluetoothStateText,
            printerConnectionState: bluetoothManager.printerStateText,
            advertisedService: MX10BluetoothManager.advertisedServiceUUIDString,
            protocolService: MX10BluetoothManager.protocolServiceUUIDString,
            writeCharacteristic: MX10BluetoothManager.writeCharacteristicUUIDString,
            notifyCharacteristic: MX10BluetoothManager.notifyCharacteristicUUIDString,
            ditheringMode: preferencesStore.preferences.ditheringMode.rawValue,
            threshold: "\(preferencesStore.preferences.threshold)",
            currentPrintJobState: printQueue.diagnosticStateText
        )
    }

    private func shareLog() {
        do {
            let url = try logger.writeExportFile(context: exportContext)
            shareItem = DiagnosticShareItem(url: url)
            statusMessage = "Prepared log export"
        } catch {
            statusMessage = error.localizedDescription
            logger.log(.error, "log export failed", metadata: ["error": error.localizedDescription])
        }
    }

    private static func deviceModelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)

        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else {
                return
            }

            identifier.append(String(UnicodeScalar(UInt8(value))))
        }
    }
}

private struct DiagnosticShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
