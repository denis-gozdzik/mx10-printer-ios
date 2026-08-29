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

private struct PendingWriteResumeContext {
    let rowDescription: String?
    let frameDescription: String
}

final class MX10BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate, PrintFrameTransport {
    static let advertisedServiceUUIDString = "AF30"
    static let protocolServiceUUIDString = "AE30"
    static let writeCharacteristicUUIDString = "AE01"
    static let notifyCharacteristicUUIDString = "AE02"

    private static let advertisedServiceUUID = CBUUID(string: advertisedServiceUUIDString)
    private static let mx10ServiceUUID = CBUUID(string: protocolServiceUUIDString)
    private static let writeCharacteristicUUID = CBUUID(string: writeCharacteristicUUIDString)
    private static let notifyCharacteristicUUID = CBUUID(string: notifyCharacteristicUUIDString)
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
    @Published var maxWriteWithoutResponseLength: Int?
    @Published var currentMaximumWriteWithoutResponse: Int?
    @Published var transportState: PrinterTransportState = .idle

    var onTransportActivity: ((PrintJobProgressActivity) -> Void)?

    private let logger: DiagnosticLogger
    private var centralManager: CBCentralManager!
    private var advertisementRecords: [BLEAdvertisementRecord] = []
    private var devicesByIdentifier: [UUID: BLEDiscoveredDevice] = [:]
    private var peripheralsByIdentifier: [UUID: CBPeripheral] = [:]
    private var selectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var didAttemptAutoReconnect = false
    private var activeTransportJobID: UUID?
    private var readinessContinuation: CheckedContinuation<Void, Error>?
    private var pendingWriteResumeContext: PendingWriteResumeContext?
    private var transportCancelled = false

    init(logger: DiagnosticLogger = .shared) {
        self.logger = logger
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        logger.log(.app, "Bluetooth manager initialized")
    }

    var isConnected: Bool {
        selectedPeripheral?.state == .connected
    }

    var canSendPrintData: Bool {
        isConnected && writeCharacteristic != nil
    }

    var isReadyForWriteWithoutResponse: Bool {
        selectedPeripheral?.canSendWriteWithoutResponse ?? false
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
            logger.log(
                .ble,
                "scan start blocked",
                metadata: ["centralState": bluetoothStateText]
            )
            return
        }

        totalDiscoveries = 0
        printerStateText = "Scanning"
        isScanning = true
        logger.log(
            .ble,
            "scan start",
            metadata: [
                "withServices": "nil",
                "allowDuplicates": true
            ]
        )
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
        stopScan(reason: "connect requested")
        selectedPeripheral = peripheral
        connectedPeripheralIdentifier = peripheral.identifier
        connectedPeripheralName = displayName(for: peripheral)
        resetConnectionDiagnostics(clearConnectedPeripheral: false)
        printerStateText = "Connecting"
        logger.log(
            .ble,
            "connect requested",
            metadata: [
                "name": connectedPeripheralName ?? "Unknown",
                "identifier": peripheral.identifier.uuidString
            ]
        )
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral = selectedPeripheral else {
            printerStateText = "Disconnected"
            logger.log(.ble, "disconnect requested without selected peripheral")
            return
        }

        logger.log(
            .ble,
            "disconnect requested",
            metadata: ["identifier": peripheral.identifier.uuidString]
        )
        centralManager.cancelPeripheralConnection(peripheral)
    }

    func send(data: Data) {
        Task { [weak self] in
            do {
                try await self?.sendFrame(
                    data,
                    context: .control(
                        command: data.count > 2 ? data[2] : 0,
                        kind: .control
                    )
                )
            } catch {
                self?.logger.log(
                    .error,
                    "send(data:) failed",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.log(
            .ble,
            "centralManagerDidUpdateState",
            metadata: ["state": Self.centralStateText(central.state)]
        )

        switch central.state {
        case .poweredOn:
            bluetoothStateText = "On"
            reconnectToLastKnownMX10OrScan()
        case .poweredOff:
            bluetoothStateText = "Off"
            isScanning = false
            printerStateText = "Bluetooth off"
            failActiveTransport(reason: "Bluetooth powered off")
        case .resetting:
            bluetoothStateText = "Resetting"
            isScanning = false
            failActiveTransport(reason: "Bluetooth resetting")
        case .unauthorized:
            bluetoothStateText = "Unauthorized"
            isScanning = false
            failActiveTransport(reason: "Bluetooth unauthorized")
        case .unsupported:
            bluetoothStateText = "Unsupported"
            isScanning = false
            failActiveTransport(reason: "Bluetooth unsupported")
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

        logger.log(
            .ble,
            "didDiscover",
            metadata: [
                "sequence": record.sequence,
                "peripheralName": record.peripheralName ?? "nil",
                "localName": record.localName ?? "nil",
                "identifier": record.peripheralIdentifier.uuidString,
                "rssi": record.rssi,
                "serviceUUIDs": record.serviceUUIDs.joined(separator: ","),
                "overflowServiceUUIDs": record.overflowServiceUUIDs.joined(separator: ","),
                "solicitedServiceUUIDs": record.solicitedServiceUUIDs.joined(separator: ","),
                "manufacturerData": record.manufacturerDataHex ?? "nil",
                "connectable": record.isConnectable.map { String($0) } ?? "unknown"
            ]
        )

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
            logger.log(
                .ble,
                "MX10 candidate marked",
                metadata: [
                    "identifier": peripheral.identifier.uuidString,
                    "name": device.displayName,
                    "services": device.serviceUUIDs.joined(separator: ",")
                ]
            )
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        selectedPeripheral = peripheral
        connectedPeripheralIdentifier = peripheral.identifier
        connectedPeripheralName = displayName(for: peripheral)
        resetConnectionDiagnostics(clearConnectedPeripheral: false)
        printerStateText = "Connected"
        peripheral.delegate = self
        maxWriteWithoutResponseLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        currentMaximumWriteWithoutResponse = maxWriteWithoutResponseLength
        logger.log(
            .ble,
            "didConnect",
            metadata: [
                "name": connectedPeripheralName ?? "Unknown",
                "identifier": peripheral.identifier.uuidString,
                "maximumWriteWithoutResponse": maxWriteWithoutResponseLength ?? -1,
                "maximumWriteValueLengthWithoutResponse": maxWriteWithoutResponseLength ?? -1
            ]
        )
        peripheral.discoverServices([Self.mx10ServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        printerStateText = "Connection failed"
        logger.log(
            .error,
            "didFailToConnect",
            metadata: [
                "identifier": peripheral.identifier.uuidString,
                "error": error?.localizedDescription ?? "unknown"
            ]
        )

        scanForMX10()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.log(
            error == nil ? .ble : .error,
            "didDisconnectPeripheral",
            metadata: [
                "identifier": peripheral.identifier.uuidString,
                "error": error?.localizedDescription ?? "none"
            ]
        )
        failActiveTransport(reason: error?.localizedDescription ?? "Peripheral disconnected")
        selectedPeripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        maxWriteWithoutResponseLength = nil
        currentMaximumWriteWithoutResponse = nil
        connectedPeripheralName = nil
        connectedPeripheralIdentifier = nil
        resetConnectionDiagnostics(clearConnectedPeripheral: true)
        printerStateText = "Disconnected"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            printerStateText = "Service discovery failed"
            logger.log(
                .error,
                "service discovery failed",
                metadata: ["error": error?.localizedDescription ?? "unknown"]
            )
            return
        }

        let services = peripheral.services ?? []
        servicesDiscovered = services.map { $0.uuid.uuidString }
        ae30Found = services.contains { $0.uuid == Self.mx10ServiceUUID }
        logger.log(
            .ble,
            "service discovery",
            metadata: [
                "services": servicesDiscovered.joined(separator: ","),
                "ae30Found": ae30Found
            ]
        )

        guard ae30Found else {
            printerStateText = "AE30 service missing"
            logger.log(.error, "AE30 service missing")
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
            logger.log(
                .error,
                "characteristic discovery failed",
                metadata: [
                    "service": service.uuid.uuidString,
                    "error": error?.localizedDescription ?? "unknown"
                ]
            )
            return
        }

        guard let characteristics = service.characteristics else {
            printerStateText = "Characteristics unresolved"
            return
        }

        let discovered = characteristics.map { $0.uuid.uuidString }
        characteristicsDiscovered = Array(Set(characteristicsDiscovered + discovered)).sorted()
        logger.log(
            .ble,
            "characteristic discovery",
            metadata: [
                "service": service.uuid.uuidString,
                "characteristics": discovered.joined(separator: ",")
            ]
        )

        for characteristic in characteristics {
            switch characteristic.uuid {
            case Self.writeCharacteristicUUID:
                ae01Found = true
                writeCharacteristic = characteristic
                logger.log(.ble, "AE01 write characteristic found")
            case Self.notifyCharacteristicUUID:
                ae02Found = true
                notifyCharacteristic = characteristic
                logger.log(.ble, "AE02 notify characteristic found")
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
            logger.log(
                .error,
                "notification state update failed",
                metadata: [
                    "characteristic": characteristic.uuid.uuidString,
                    "error": error?.localizedDescription ?? "unknown"
                ]
            )
            return
        }

        if characteristic.uuid == Self.notifyCharacteristicUUID {
            ae02NotificationsEnabled = characteristic.isNotifying
            printerStateText = characteristic.isNotifying ? "Connected" : "AE02 notify disabled"
            logger.log(
                .ble,
                "notification state changed",
                metadata: [
                    "characteristic": characteristic.uuid.uuidString,
                    "isNotifying": characteristic.isNotifying
                ]
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            logger.log(
                .error,
                "notification read failed",
                metadata: [
                    "characteristic": characteristic.uuid.uuidString,
                    "error": error?.localizedDescription ?? "unknown"
                ]
            )
            return
        }

        if let value = characteristic.value {
            if let frame = MX10Protocol.parseFrame(value) {
                logger.log(
                    .printer,
                    "AE02 notification parsed",
                    metadata: [
                        "characteristic": characteristic.uuid.uuidString,
                        "bytes": value.count,
                        "command": String(format: "0x%02X", frame.command),
                        "mode": String(format: "0x%02X", frame.mode),
                        "payloadBytes": frame.payload.count,
                        "payloadHex": frame.payload.diagnosticHexString,
                        "crc": String(format: "0x%02X", frame.crc),
                        "crcValid": frame.isCRCValid,
                        "hex": value.diagnosticHexString
                    ]
                )
            } else {
                logger.log(
                    .printer,
                    "AE02 notification unknown",
                    metadata: [
                        "characteristic": characteristic.uuid.uuidString,
                        "bytes": value.count,
                        "hex": value.diagnosticHexString
                    ]
                )
            }
            onTransportActivity?(.notificationReceived)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        printerStateText = "Connected"
        var metadata: [String: Any] = [
            "identifier": peripheral.identifier.uuidString,
            "canSendWriteWithoutResponse": peripheral.canSendWriteWithoutResponse
        ]

        if let pendingWriteResumeContext {
            metadata["resumeRow"] = pendingWriteResumeContext.rowDescription ?? "n/a"
            metadata["resumeFrame"] = pendingWriteResumeContext.frameDescription
        }

        logger.log(
            .ble,
            "peripheralIsReady(toSendWriteWithoutResponse:)",
            metadata: metadata
        )
        transportState = activeTransportJobID == nil ? .idle : .sending
        resumeReadinessContinuation(with: .success(()))
    }

    func beginPrintTransport(
        jobID: UUID,
        totalRows: Int,
        configuration: PrinterTransportConfiguration
    ) {
        activeTransportJobID = jobID
        transportCancelled = false
        transportState = .preparing
        let cachedMaximum = maxWriteWithoutResponseLength
        let currentMaximum = selectedPeripheral?.maximumWriteValueLength(for: .withoutResponse)
        if let currentMaximum {
            currentMaximumWriteWithoutResponse = currentMaximum
            maxWriteWithoutResponseLength = currentMaximum
        }
        logger.log(
            .queue,
            "transport preparing",
            metadata: [
                "job": jobID.uuidString,
                "rows": totalRows,
                "cachedMaximumWriteWithoutResponse": cachedMaximum ?? -1,
                "currentMaximumWriteWithoutResponse": currentMaximum ?? -1,
                "interPacketDelayNanoseconds": configuration.interPacketDelayNanoseconds
            ]
        )
    }

    func sendFrame(_ frame: Data, context: PrintPacketContext) async throws {
        guard !transportCancelled else {
            throw PrintTransportError.cancelled
        }

        guard let peripheral = selectedPeripheral else {
            transportState = .failed
            throw PrintTransportError.peripheralUnavailable
        }

        guard peripheral.state == .connected else {
            transportState = .failed
            throw PrintTransportError.disconnected
        }

        guard let characteristic = writeCharacteristic else {
            transportState = .failed
            throw PrintTransportError.writeCharacteristicMissing
        }

        let cachedMaximum = maxWriteWithoutResponseLength
        let currentMaximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
        currentMaximumWriteWithoutResponse = currentMaximum
        maxWriteWithoutResponseLength = currentMaximum

        guard currentMaximum > 0 else {
            transportState = .failed
            logger.log(
                .error,
                "invalid maximumWriteWithoutResponse",
                metadata: packetMetadata(frame: frame, context: context).merging([
                    "cachedMaximumWriteWithoutResponse": cachedMaximum.map { "\($0)" } ?? "unknown",
                    "currentMaximumWriteWithoutResponse": "\(currentMaximum)",
                    "hex": frame.diagnosticHexString
                ]) { current, _ in current }
            )
            throw PrintTransportError.invalidMaximumWriteLength(currentMaximum)
        }

        guard frame.count <= currentMaximum else {
            transportState = .failed
            logger.log(
                .error,
                "maximumWriteWithoutResponse too small for MX10 frame",
                metadata: packetMetadata(
                    frame: frame,
                    context: context,
                    currentMaximumWriteWithoutResponse: currentMaximum,
                    cachedMaximumWriteWithoutResponse: cachedMaximum
                ).merging(["hex": frame.diagnosticHexString]) { current, _ in current }
            )
            throw PrintTransportError.maximumWriteLengthTooSmall(
                frameBytes: frame.count,
                currentMaximum: currentMaximum,
                cachedMaximum: cachedMaximum
            )
        }

        if context.shouldLogFrame {
            logger.log(
                logCategory(for: context),
                "write frame",
                metadata: packetMetadata(
                    frame: frame,
                    context: context,
                    currentMaximumWriteWithoutResponse: currentMaximum,
                    cachedMaximumWriteWithoutResponse: cachedMaximum
                )
            )
        }

        try await waitUntilReadyToWrite(
            peripheral: peripheral,
            frame: frame,
            context: context,
            currentMaximumWriteWithoutResponse: currentMaximum,
            cachedMaximumWriteWithoutResponse: cachedMaximum
        )

        guard !transportCancelled else {
            throw PrintTransportError.cancelled
        }

        guard peripheral.state == .connected else {
            transportState = .failed
            throw PrintTransportError.disconnected
        }

        transportState = .sending
        peripheral.writeValue(frame, for: characteristic, type: .withoutResponse)
        printerStateText = "Connected"
    }

    func completePrintTransport(jobID: UUID) {
        guard activeTransportJobID == jobID else {
            return
        }

        transportState = .completed
        activeTransportJobID = nil
        transportCancelled = false
        pendingWriteResumeContext = nil
        resumeReadinessContinuation(with: .success(()))
        logger.log(.queue, "transport completed", metadata: ["job": jobID.uuidString])
    }

    func failPrintTransport(jobID: UUID?, reason: String) {
        if let jobID, activeTransportJobID != jobID {
            return
        }

        failActiveTransport(reason: reason)
    }

    func cancelActiveTransport() {
        transportCancelled = true
        transportState = .cancelled
        logger.log(
            .queue,
            "transport cancelled",
            metadata: ["job": activeTransportJobID?.uuidString ?? "none"]
        )
        activeTransportJobID = nil
        pendingWriteResumeContext = nil
        resumeReadinessContinuation(with: .failure(PrintTransportError.cancelled))
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
        maxWriteWithoutResponseLength = nil
        currentMaximumWriteWithoutResponse = nil

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
        logger.log(
            .ble,
            "reconnect requested",
            metadata: ["identifier": peripheral.identifier.uuidString]
        )
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

        return data.diagnosticHexString
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

    private func stopScan(reason: String) {
        if isScanning {
            logger.log(.ble, "scan stop", metadata: ["reason": reason])
        }

        centralManager.stopScan()
        isScanning = false
    }

    private func waitForPeripheralReady() async throws {
        if selectedPeripheral?.canSendWriteWithoutResponse == true {
            return
        }

        guard readinessContinuation == nil else {
            throw PrintTransportError.concurrentPeripheralReadyWait
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readinessContinuation = continuation
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelActiveTransport()
            }
        }
    }

    private func resumeReadinessContinuation(with result: Result<Void, Error>) {
        guard let continuation = readinessContinuation else {
            return
        }

        readinessContinuation = nil

        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func failActiveTransport(reason: String) {
        guard activeTransportJobID != nil || readinessContinuation != nil else {
            return
        }

        transportState = .failed
        logger.log(
            .error,
            "transport failed",
            metadata: [
                "job": activeTransportJobID?.uuidString ?? "none",
                "reason": reason
            ]
        )
        activeTransportJobID = nil
        transportCancelled = false
        pendingWriteResumeContext = nil
        resumeReadinessContinuation(with: .failure(PrintTransportError.disconnected))
    }

    private func waitUntilReadyToWrite(
        peripheral: CBPeripheral,
        frame: Data,
        context: PrintPacketContext,
        currentMaximumWriteWithoutResponse: Int,
        cachedMaximumWriteWithoutResponse: Int?
    ) async throws {
        while !peripheral.canSendWriteWithoutResponse {
            guard !transportCancelled else {
                throw PrintTransportError.cancelled
            }

            guard peripheral.state == .connected else {
                transportState = .failed
                throw PrintTransportError.disconnected
            }

            transportState = .waitingForPeripheralReady
            pendingWriteResumeContext = PendingWriteResumeContext(
                rowDescription: rowDescription(for: context),
                frameDescription: "\(frame.count) bytes"
            )
            logger.log(
                .ble,
                "backpressure",
                metadata: packetMetadata(
                    frame: frame,
                    context: context,
                    currentMaximumWriteWithoutResponse: currentMaximumWriteWithoutResponse,
                    cachedMaximumWriteWithoutResponse: cachedMaximumWriteWithoutResponse
                ).merging(["canSendWriteWithoutResponse": "false"]) { current, _ in current }
            )

            do {
                try await waitForPeripheralReady()
                pendingWriteResumeContext = nil
            } catch {
                pendingWriteResumeContext = nil
                throw error
            }
        }
    }

    private func packetMetadata(
        frame: Data,
        context: PrintPacketContext,
        currentMaximumWriteWithoutResponse: Int? = nil,
        cachedMaximumWriteWithoutResponse: Int? = nil
    ) -> [String: String] {
        var metadata: [String: String] = [
            "packetBytes": "\(frame.count)",
            "frameBytes": "\(frame.count)",
            "writeType": "withoutResponse",
            "canSendWriteWithoutResponse": "\(selectedPeripheral?.canSendWriteWithoutResponse ?? false)",
            "transportState": transportState.rawValue,
            "command": String(format: "0x%02X", context.command),
            "kind": context.kind.rawValue,
            "crc": frame.count >= 2 ? String(format: "0x%02X", frame[frame.count - 2]) : "n/a"
        ]

        if let currentMaximumWriteWithoutResponse {
            metadata["currentMaximumWriteWithoutResponse"] = "\(currentMaximumWriteWithoutResponse)"
        }

        if let cachedMaximumWriteWithoutResponse {
            metadata["cachedMaximumWriteWithoutResponse"] = "\(cachedMaximumWriteWithoutResponse)"
        }

        if let jobID = context.jobID {
            metadata["job"] = jobID.uuidString
        }

        if let rowIndex = context.rowIndex,
           let totalRows = context.totalRows {
            metadata["row"] = "\(rowIndex + 1)/\(totalRows)"
        }

        if context.shouldLogFullHex {
            metadata["hex"] = frame.diagnosticHexString
        }

        return metadata
    }

    private func rowDescription(for context: PrintPacketContext) -> String? {
        guard let rowIndex = context.rowIndex,
              let totalRows = context.totalRows else {
            return nil
        }

        return "\(rowIndex + 1)/\(totalRows)"
    }

    private func logCategory(for context: PrintPacketContext) -> DiagnosticCategory {
        context.kind == .bitmapRow ? .protocolLog : .ble
    }

    private static func centralStateText(_ state: CBManagerState) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .resetting:
            return "resetting"
        case .unsupported:
            return "unsupported"
        case .unauthorized:
            return "unauthorized"
        case .poweredOff:
            return "poweredOff"
        case .poweredOn:
            return "poweredOn"
        @unknown default:
            return "unavailable"
        }
    }
}
