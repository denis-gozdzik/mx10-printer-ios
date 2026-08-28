import Foundation
import CoreBluetooth

struct BLEDiscoveredDevice: Identifiable {
    let id: UUID
    let peripheralName: String?
    let localName: String?
    let rssi: Int
    let serviceUUIDs: [String]
    let overflowServiceUUIDs: [String]
    let solicitedServiceUUIDs: [String]
    let manufacturerDataHex: String?
    let isConnectable: Bool?
    let isMX10Candidate: Bool
    let discoveryCount: Int
    let latestSequence: Int

    var displayName: String {
        peripheralName ?? localName ?? "Unknown"
    }
}

private struct BLEAdvertisementRecord {
    let sequence: Int
    let peripheralIdentifier: UUID
    let peripheralName: String?
    let localName: String?
    let rssi: Int
    let serviceUUIDs: [String]
    let overflowServiceUUIDs: [String]
    let solicitedServiceUUIDs: [String]
    let manufacturerDataHex: String?
    let isConnectable: Bool?
}

final class MX10BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let advertisedServiceUUID = CBUUID(string: "AF30")
    private static let mx10ServiceUUID = CBUUID(string: "AE30")
    private static let writeCharacteristicUUID = CBUUID(string: "AE01")
    private static let notifyCharacteristicUUID = CBUUID(string: "AE02")
    private static let lastConnectedPrinterKey = "lastConnectedMX10PeripheralIdentifier"

    @Published var bluetoothStateText: String = "Unknown"
    @Published var printerStateText: String = "Disconnected"
    @Published var isScanning: Bool = false
    @Published var totalDiscoveries: Int = 0
    @Published var discoveredDevices: [BLEDiscoveredDevice] = []
    @Published var connectedPeripheralName: String?
    @Published var connectedPeripheralIdentifier: UUID?
    @Published var servicesDiscovered: [String] = []
    @Published var characteristicsDiscovered: [String] = []
    @Published var ae30Found: Bool = false
    @Published var ae01Found: Bool = false
    @Published var ae02Found: Bool = false
    @Published var ae02NotificationsEnabled: Bool = false

    private var centralManager: CBCentralManager!
    private var advertisementRecords: [BLEAdvertisementRecord] = []
    private var devicesByIdentifier: [UUID: BLEDiscoveredDevice] = [:]
    private var peripheralsByIdentifier: [UUID: CBPeripheral] = [:]
    private var selectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var didAttemptAutoReconnect = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    var isConnected: Bool {
        selectedPeripheral?.state == .connected
    }

    var canSendPrintData: Bool {
        isConnected && writeCharacteristic != nil
    }

    var uniqueDeviceCount: Int {
        discoveredDevices.count
    }

    var mx10CandidateCount: Int {
        discoveredDevices.filter(\.isMX10Candidate).count
    }

    func scanForMX10() {
        advertisementRecords.removeAll()
        devicesByIdentifier.removeAll()
        peripheralsByIdentifier.removeAll()
        discoveredDevices.removeAll()

        if !isConnected {
            selectedPeripheral = nil
            resetConnectionDiagnostics(clearConnectedPeripheral: true)
        }

        guard centralManager.state == .poweredOn else {
            isScanning = false
            printerStateText = "Bluetooth unavailable"
            return
        }

        totalDiscoveries = 0
        printerStateText = "Scanning"
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true
            ]
        )
    }

    func connectToFirstDiscoveredPeripheral() {
        guard let device = discoveredDevices.first,
              let peripheral = peripheralsByIdentifier[device.id] else {
            printerStateText = "No BLE devices discovered"
            return
        }

        connect(peripheral)
    }

    func connect(to device: BLEDiscoveredDevice) {
        guard let peripheral = peripheralsByIdentifier[device.id] else {
            printerStateText = "Peripheral unavailable"
            return
        }

        connect(peripheral)
    }

    func connect(_ peripheral: CBPeripheral) {
        centralManager.stopScan()
        isScanning = false
        selectedPeripheral = peripheral
        connectedPeripheralIdentifier = peripheral.identifier
        connectedPeripheralName = displayName(for: peripheral)
        resetConnectionDiagnostics(clearConnectedPeripheral: false)
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
            reconnectToLastKnownMX10OrScan()
        case .poweredOff:
            bluetoothStateText = "Off"
            isScanning = false
            printerStateText = "Bluetooth off"
        case .resetting:
            bluetoothStateText = "Resetting"
            isScanning = false
        case .unauthorized:
            bluetoothStateText = "Unauthorized"
            isScanning = false
        case .unsupported:
            bluetoothStateText = "Unsupported"
            isScanning = false
        case .unknown:
            bluetoothStateText = "Unknown"
            isScanning = false
        default:
            bluetoothStateText = "Unavailable"
            isScanning = false
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let record = BLEAdvertisementRecord(
            sequence: totalDiscoveries + 1,
            peripheralIdentifier: peripheral.identifier,
            peripheralName: peripheral.name,
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            rssi: RSSI.intValue,
            serviceUUIDs: Self.uuidStrings(from: advertisementData[CBAdvertisementDataServiceUUIDsKey]),
            overflowServiceUUIDs: Self.uuidStrings(from: advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey]),
            solicitedServiceUUIDs: Self.uuidStrings(from: advertisementData[CBAdvertisementDataSolicitedServiceUUIDsKey]),
            manufacturerDataHex: Self.hexString(from: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data),
            isConnectable: Self.boolValue(from: advertisementData[CBAdvertisementDataIsConnectable])
        )

        advertisementRecords.append(record)
        totalDiscoveries = advertisementRecords.count
        peripheralsByIdentifier[peripheral.identifier] = peripheral

        let isCandidate = Self.isMX10Candidate(record)
        let discoveryCount = (devicesByIdentifier[peripheral.identifier]?.discoveryCount ?? 0) + 1
        let device = BLEDiscoveredDevice(
            id: peripheral.identifier,
            peripheralName: record.peripheralName,
            localName: record.localName,
            rssi: record.rssi,
            serviceUUIDs: record.serviceUUIDs,
            overflowServiceUUIDs: record.overflowServiceUUIDs,
            solicitedServiceUUIDs: record.solicitedServiceUUIDs,
            manufacturerDataHex: record.manufacturerDataHex,
            isConnectable: record.isConnectable,
            isMX10Candidate: isCandidate,
            discoveryCount: discoveryCount,
            latestSequence: record.sequence
        )

        devicesByIdentifier[peripheral.identifier] = device
        discoveredDevices = devicesByIdentifier.values.sorted {
            if $0.isMX10Candidate != $1.isMX10Candidate {
                return $0.isMX10Candidate && !$1.isMX10Candidate
            }

            return $0.latestSequence > $1.latestSequence
        }

        if isCandidate {
            printerStateText = "MX10 candidate discovered"
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        selectedPeripheral = peripheral
        connectedPeripheralIdentifier = peripheral.identifier
        connectedPeripheralName = displayName(for: peripheral)
        resetConnectionDiagnostics(clearConnectedPeripheral: false)
        printerStateText = "Connected"
        peripheral.delegate = self
        peripheral.discoverServices([Self.mx10ServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        printerStateText = "Connection failed"
        if let error {
            print("Failed to connect: \(error.localizedDescription)")
        }

        scanForMX10()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        selectedPeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        connectedPeripheralName = nil
        connectedPeripheralIdentifier = nil
        resetConnectionDiagnostics(clearConnectedPeripheral: true)
        printerStateText = "Disconnected"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            printerStateText = "Service discovery failed"
            return
        }

        let services = peripheral.services ?? []
        servicesDiscovered = services.map { $0.uuid.uuidString }
        ae30Found = services.contains { $0.uuid == Self.mx10ServiceUUID }

        guard ae30Found else {
            printerStateText = "AE30 service missing"
            return
        }

        persistLastConnectedMX10(peripheral)

        for service in services where service.uuid == Self.mx10ServiceUUID {
            peripheral.discoverCharacteristics([Self.writeCharacteristicUUID, Self.notifyCharacteristicUUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            printerStateText = "Characteristic discovery failed"
            return
        }

        guard let characteristics = service.characteristics else {
            printerStateText = "Characteristics unresolved"
            return
        }

        let discovered = characteristics.map { $0.uuid.uuidString }
        characteristicsDiscovered = Array(Set(characteristicsDiscovered + discovered)).sorted()

        for characteristic in characteristics {
            switch characteristic.uuid {
            case Self.writeCharacteristicUUID:
                ae01Found = true
                writeCharacteristic = characteristic
            case Self.notifyCharacteristicUUID:
                ae02Found = true
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
            if characteristic.uuid == Self.notifyCharacteristicUUID {
                ae02NotificationsEnabled = false
            }

            printerStateText = "Notify setup failed"
            return
        }

        if characteristic.uuid == Self.notifyCharacteristicUUID {
            ae02NotificationsEnabled = characteristic.isNotifying
            printerStateText = characteristic.isNotifying ? "Connected" : "AE02 notify disabled"
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

    private func resetConnectionDiagnostics(clearConnectedPeripheral: Bool) {
        writeCharacteristic = nil
        notifyCharacteristic = nil
        servicesDiscovered = []
        characteristicsDiscovered = []
        ae30Found = false
        ae01Found = false
        ae02Found = false
        ae02NotificationsEnabled = false

        if clearConnectedPeripheral {
            connectedPeripheralName = nil
            connectedPeripheralIdentifier = nil
        }
    }

    private func reconnectToLastKnownMX10OrScan() {
        guard !didAttemptAutoReconnect else {
            scanForMX10()
            return
        }

        didAttemptAutoReconnect = true

        guard let identifierString = UserDefaults.standard.string(forKey: Self.lastConnectedPrinterKey),
              let identifier = UUID(uuidString: identifierString) else {
            scanForMX10()
            return
        }

        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [identifier])
        guard let peripheral = peripherals.first else {
            scanForMX10()
            return
        }

        peripheralsByIdentifier[peripheral.identifier] = peripheral
        selectedPeripheral = peripheral
        connectedPeripheralIdentifier = peripheral.identifier
        connectedPeripheralName = peripheral.name ?? "Last MX10"
        resetConnectionDiagnostics(clearConnectedPeripheral: false)
        printerStateText = "Reconnecting"
        centralManager.connect(peripheral, options: nil)
    }

    private func persistLastConnectedMX10(_ peripheral: CBPeripheral) {
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.lastConnectedPrinterKey)
    }

    private func displayName(for peripheral: CBPeripheral) -> String {
        devicesByIdentifier[peripheral.identifier]?.displayName ?? peripheral.name ?? "Unknown"
    }

    private static func isMX10Candidate(_ record: BLEAdvertisementRecord) -> Bool {
        record.peripheralName == "MX10" ||
        record.localName == "MX10" ||
        record.serviceUUIDs.contains(Self.advertisedServiceUUID.uuidString)
    }

    private static func uuidStrings(from advertisementValue: Any?) -> [String] {
        guard let uuids = advertisementValue as? [CBUUID] else {
            return []
        }

        return uuids.map { $0.uuidString }.sorted()
    }

    private static func hexString(from data: Data?) -> String? {
        guard let data else {
            return nil
        }

        return data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func boolValue(from advertisementValue: Any?) -> Bool? {
        if let value = advertisementValue as? Bool {
            return value
        }

        if let value = advertisementValue as? NSNumber {
            return value.boolValue
        }

        return nil
    }
}
