import Foundation
import CoreBluetooth

final class MX10BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let mx10ServiceUUID = CBUUID(string: "AE30")
    private static let writeCharacteristicUUID = CBUUID(string: "AE01")
    private static let notifyCharacteristicUUID = CBUUID(string: "AE02")

    @Published var bluetoothStateText: String = "Unknown"
    @Published var printerStateText: String = "Disconnected"
    @Published var discoveredDevices: [String] = []
    @Published var connectedPeripheralName: String?

    private var centralManager: CBCentralManager!
    private var discoveredPeripherals: [CBPeripheral] = []
    private var selectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    var isConnected: Bool {
        selectedPeripheral?.state == .connected
    }

    func scanForMX10() {
        discoveredDevices.removeAll()
        discoveredPeripherals.removeAll()
        writeCharacteristic = nil
        notifyCharacteristic = nil

        guard centralManager.state == .poweredOn else {
            printerStateText = "Bluetooth unavailable"
            return
        }

        printerStateText = "Scanning"
        centralManager.scanForPeripherals(withServices: [Self.mx10ServiceUUID], options: nil)
    }

    func connectToFirstDiscoveredPeripheral() {
        guard let peripheral = discoveredPeripherals.first else {
            printerStateText = "No MX10 discovered"
            return
        }

        connect(peripheral)
    }

    func connect(_ peripheral: CBPeripheral) {
        selectedPeripheral = peripheral
        printerStateText = "Connecting"
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral = selectedPeripheral else {
            printerStateText = "Disconnected"
            return
        }

        centralManager.cancelPeripheralConnection(peripheral)
    }

    func send(data: Data) {
        guard isConnected else {
            printerStateText = "Disconnected"
            return
        }

        guard let characteristic = writeCharacteristic else {
            printerStateText = "AE01 missing"
            return
        }

        guard let peripheral = selectedPeripheral else {
            printerStateText = "MX10 unavailable"
            return
        }

        if peripheral.state == .connected {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            printerStateText = "Connected"
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStateText = "On"
            scanForMX10()
        case .poweredOff:
            bluetoothStateText = "Off"
            printerStateText = "Bluetooth off"
        case .resetting:
            bluetoothStateText = "Resetting"
        case .unauthorized:
            bluetoothStateText = "Unauthorized"
        case .unsupported:
            bluetoothStateText = "Unsupported"
        case .unknown:
            bluetoothStateText = "Unknown"
        default:
            bluetoothStateText = "Unavailable"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"

        let matchesService = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.contains(Self.mx10ServiceUUID) ?? false
        let matchesName = name == "MX10"

        guard matchesService || matchesName else {
            return
        }

        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
            discoveredDevices.append(name)
        }

        self.selectedPeripheral = peripheral
        self.printerStateText = "Discovered"
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        selectedPeripheral = peripheral
        connectedPeripheralName = peripheral.name ?? "MX10"
        printerStateText = "Connected"
        peripheral.delegate = self
        peripheral.discoverServices([Self.mx10ServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        printerStateText = "Connection failed"
        if let error {
            print("Failed to connect: \(error.localizedDescription)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        selectedPeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        connectedPeripheralName = nil
        printerStateText = "Disconnected"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            printerStateText = "Service discovery failed"
            return
        }

        guard let services = peripheral.services else {
            printerStateText = "AE30 service missing"
            return
        }

        for service in services where service.uuid == Self.mx10ServiceUUID {
            peripheral.discoverCharacteristics([Self.writeCharacteristicUUID, Self.notifyCharacteristicUUID], for: service)
            return
        }

        printerStateText = "AE30 service missing"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            printerStateText = "Characteristic discovery failed"
            return
        }

        guard let characteristics = service.characteristics else {
            printerStateText = "Characterstics unresolved"
            return
        }

        for characteristic in characteristics {
            switch characteristic.uuid {
            case Self.writeCharacteristicUUID:
                writeCharacteristic = characteristic
            case Self.notifyCharacteristicUUID:
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }

        if writeCharacteristic == nil {
            printerStateText = "AE01 missing"
        } else if notifyCharacteristic == nil {
            printerStateText = "AE02 missing"
        } else {
            printerStateText = "Connected"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            printerStateText = "Notify setup failed"
            return
        }

        if characteristic.uuid == Self.notifyCharacteristicUUID {
            printerStateText = "Connected"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            print("Notification read failed: \(error?.localizedDescription ?? "unknown")")
            return
        }

        if let value = characteristic.value {
            print("Received MX10 notification: \(value.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        printerStateText = "Connected"
    }
}
