import SwiftUI

struct ContentView: View {
    @StateObject private var bluetoothManager = MX10BluetoothManager()

    private func printer() -> MX10Printer {
        MX10Printer(bluetoothManager: bluetoothManager)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                diagnosticsSummary
                connectionDiagnostics
                scanControls
                printerControls
                discoveredDevicesList
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var diagnosticsSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bluetooth state: \(bluetoothManager.bluetoothStateText)")
                .font(.headline)
            Text("Printer state: \(bluetoothManager.printerStateText)")
                .font(.headline)
            Text("Scanning: \(bluetoothManager.isScanning ? "YES" : "NO")")
            Text("Total discoveries: \(bluetoothManager.totalDiscoveries)")
            Text("Unique devices: \(bluetoothManager.uniqueDeviceCount)")
            Text("MX10 candidates: \(bluetoothManager.mx10CandidateCount)")
        }
    }

    private var connectionDiagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection diagnostics")
                .font(.headline)
            Text("Connected peripheral: \(bluetoothManager.connectedPeripheralName ?? "None")")
            Text("Services discovered: \(textList(bluetoothManager.servicesDiscovered))")
            Text("Characteristics discovered: \(textList(bluetoothManager.characteristicsDiscovered))")
            Text("AE30 found: \(bluetoothManager.ae30Found ? "YES" : "NO")")
            Text("AE01 found: \(bluetoothManager.ae01Found ? "YES" : "NO")")
            Text("AE02 found: \(bluetoothManager.ae02Found ? "YES" : "NO")")
            Text("AE02 notifications enabled: \(bluetoothManager.ae02NotificationsEnabled ? "YES" : "NO")")
        }
    }

    private var scanControls: some View {
        HStack(spacing: 12) {
            Button("Scan") {
                bluetoothManager.scanForMX10()
            }
            .buttonStyle(.borderedProminent)

            Button("Disconnect") {
                bluetoothManager.disconnect()
            }
            .buttonStyle(.bordered)
            .disabled(!bluetoothManager.isConnected)
        }
    }

    private var printerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Printer commands")
                .font(.headline)

            HStack(spacing: 12) {
                Button("Read Status") {
                    printer().requestStatus()
                }

                Button("Feed Paper") {
                    printer().feed(steps: 16)
                }

                Button("Print Test") {
                    printer().printTestPattern()
                }
            }
            .buttonStyle(.bordered)
            .disabled(!bluetoothManager.isConnected)
        }
    }

    private var discoveredDevicesList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Discovered devices")
                .font(.headline)

            ForEach(bluetoothManager.discoveredDevices) { device in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Name: \(device.peripheralName ?? "Unknown")")
                            Text("Local name: \(device.localName ?? "None")")
                            Text("RSSI: \(device.rssi)")
                            Text("UUID: \(device.id.uuidString)")
                            Text("Services: \(textList(device.serviceUUIDs))")
                            Text("Overflow services: \(textList(device.overflowServiceUUIDs))")
                            Text("Solicited services: \(textList(device.solicitedServiceUUIDs))")
                            Text("Manufacturer: \(device.manufacturerDataHex ?? "None")")
                            Text("Connectable: \(boolText(device.isConnectable))")
                            Text("Discoveries: \(device.discoveryCount)")
                            Text("MX10 candidate: \(device.isMX10Candidate ? "YES" : "NO")")
                        }
                        .font(.caption)
                        .textSelection(.enabled)

                        Spacer(minLength: 12)

                        Button("Connect") {
                            bluetoothManager.connect(to: device)
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider()
                }
            }
        }
    }

    private func textList(_ values: [String]) -> String {
        values.isEmpty ? "None" : values.joined(separator: ", ")
    }

    private func boolText(_ value: Bool?) -> String {
        guard let value else {
            return "Unknown"
        }

        return value ? "true" : "false"
    }
}

#Preview {
    ContentView()
}
