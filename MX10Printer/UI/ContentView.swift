import SwiftUI

struct ContentView: View {
    @StateObject private var bluetoothManager = MX10BluetoothManager()

    private func printer() -> MX10Printer {
        MX10Printer(bluetoothManager: bluetoothManager)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Bluetooth: \(bluetoothManager.bluetoothStateText)")
                .font(.headline)

            Text("MX10: \(bluetoothManager.printerStateText)")
                .font(.headline)

            if let connectedPeripheral = bluetoothManager.connectedPeripheralName {
                Text("Connected device: \(connectedPeripheral)")
            }

            if !bluetoothManager.discoveredDevices.isEmpty {
                Text("Discovered: \(bluetoothManager.discoveredDevices.joined(separator: ", "))")
                    .font(.subheadline)
            }

            HStack(spacing: 12) {
                Button("Scan") {
                    bluetoothManager.scanForMX10()
                }

                Button(bluetoothManager.isConnected ? "Disconnect" : "Connect") {
                    if bluetoothManager.isConnected {
                        bluetoothManager.disconnect()
                    } else {
                        bluetoothManager.connectToFirstDiscoveredPeripheral()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
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
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview {
    ContentView()
}
