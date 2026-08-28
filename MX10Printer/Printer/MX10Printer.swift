import Foundation

final class MX10Printer {
    private let bluetoothManager: MX10BluetoothManager

    init(bluetoothManager: MX10BluetoothManager) {
        self.bluetoothManager = bluetoothManager
    }

    func requestStatus() {
        bluetoothManager.send(data: MX10Protocol.requestStatus())
    }

    func feed(steps: UInt16) {
        bluetoothManager.send(data: MX10Protocol.feed(steps: steps))
    }

    func printRow(_ row: Data) throws {
        let frame = try MX10Protocol.printRow(row)
        bluetoothManager.send(data: frame)
    }

    func printTestPattern() {
        let rows = BitmapEncoder.testRows()

        for row in rows {
            do {
                let frame = try MX10Protocol.printRow(row)
                bluetoothManager.send(data: frame)
            } catch {
                print("Failed to print test row: \(error.localizedDescription)")
            }
        }
    }
}
