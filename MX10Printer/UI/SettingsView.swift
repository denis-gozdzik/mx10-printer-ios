import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var bluetoothManager: MX10BluetoothManager
    @ObservedObject var preferencesStore: PrintingPreferencesStore
    @ObservedObject var printQueue: PrintQueue

    var body: some View {
        Form {
            Section("Printer") {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(bluetoothManager.isConnected ? "Connected" : "Disconnected")
                        .foregroundStyle(.secondary)
                }

                Button("Scan") {
                    bluetoothManager.scanForMX10()
                }

                Button("Disconnect") {
                    bluetoothManager.disconnect()
                }
                .disabled(!bluetoothManager.isConnected)
            }

            Section("Printing") {
                Picker("Dithering", selection: ditheringModeBinding) {
                    ForEach(DitheringMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                VStack(alignment: .leading) {
                    Text("Threshold: \(preferencesStore.preferences.threshold)")
                    Slider(value: thresholdBinding, in: 0...255, step: 1)
                }

                Stepper(
                    "Feed after print: \(preferencesStore.preferences.defaultFeedAfterPrint)",
                    value: feedAfterPrintBinding,
                    in: 0...200
                )
            }

            Section("Developer") {
                Toggle("Show final 1-bit raster preview", isOn: finalRasterPreviewBinding)

                NavigationLink("Logs") {
                    DiagnosticLogView(
                        logger: .shared,
                        bluetoothManager: bluetoothManager,
                        preferencesStore: preferencesStore,
                        printQueue: printQueue
                    )
                }

                NavigationLink("BLE Diagnostics") {
                    BLEDiagnosticsView(bluetoothManager: bluetoothManager)
                }
            }

            Section("About") {
                LabeledContent("App", value: "MX10 Printer")
                LabeledContent("Mode", value: "Local")
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    private var ditheringModeBinding: Binding<DitheringMode> {
        Binding(
            get: { preferencesStore.preferences.ditheringMode },
            set: { preferencesStore.preferences.ditheringMode = $0 }
        )
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { Double(preferencesStore.preferences.threshold) },
            set: { preferencesStore.preferences.threshold = UInt8($0.rounded()) }
        )
    }

    private var feedAfterPrintBinding: Binding<Int> {
        Binding(
            get: { Int(preferencesStore.preferences.defaultFeedAfterPrint) },
            set: { preferencesStore.preferences.defaultFeedAfterPrint = UInt16($0) }
        )
    }

    private var finalRasterPreviewBinding: Binding<Bool> {
        Binding(
            get: { preferencesStore.preferences.showFinalRasterPreview },
            set: { preferencesStore.preferences.showFinalRasterPreview = $0 }
        )
    }
}
