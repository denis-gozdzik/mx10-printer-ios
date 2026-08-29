import Foundation

struct MX10PrinterProfile: Equatable, Codable {
    var name: String
    var advertisedServiceUUID: String
    var protocolServiceUUID: String
    var writeCharacteristicUUID: String
    var notifyCharacteristicUUID: String
    var printWidthPixels: Int
    var rowByteCount: Int
    var printConfiguration: MX10PrintConfiguration

    static let safeDefault = MX10PrinterProfile(
        name: "MX10",
        advertisedServiceUUID: "AF30",
        protocolServiceUUID: "AE30",
        writeCharacteristicUUID: "AE01",
        notifyCharacteristicUUID: "AE02",
        printWidthPixels: 384,
        rowByteCount: 48,
        printConfiguration: MX10PrintConfiguration()
    )
}

struct MX10PrintConfiguration: Equatable, Codable {
    var transport: PrinterTransportConfiguration
    var allowUnverifiedInitializationCommands: Bool
    var unverifiedEnergy: UInt16?
    var unverifiedQuality: UInt8?
    var unverifiedFeedSpeed: UInt8?

    init(
        transport: PrinterTransportConfiguration = .debugDefault,
        allowUnverifiedInitializationCommands: Bool = false,
        unverifiedEnergy: UInt16? = nil,
        unverifiedQuality: UInt8? = nil,
        unverifiedFeedSpeed: UInt8? = nil
    ) {
        self.transport = transport
        self.allowUnverifiedInitializationCommands = allowUnverifiedInitializationCommands
        self.unverifiedEnergy = unverifiedEnergy
        self.unverifiedQuality = unverifiedQuality
        self.unverifiedFeedSpeed = unverifiedFeedSpeed
    }
}

struct MX10ProtocolCommandFinding: Identifiable, Equatable {
    var commandByte: UInt8
    var payloadFormat: String
    var likelyPurpose: String
    var sourceReference: String
    var confidenceLevel: String
    var crcFraming: String
    var physicallyVerifiedOnMX10: Bool

    var id: UInt8 { commandByte }

    var commandHex: String {
        String(format: "0x%02X", commandByte)
    }
}

enum MX10ProtocolFindings {
    static let findings: [MX10ProtocolCommandFinding] = [
        MX10ProtocolCommandFinding(
            commandByte: 0xA8,
            payloadFormat: "one byte, usually 0x00",
            likelyPurpose: "request device information by AE02 notification",
            sourceReference: "fulda1 Thermal_Printer cat-printer protocol wiki; lisp3r BLE capture",
            confidenceLevel: "medium for compatible AE30 printers; unverified on this MX10",
            crcFraming: "51 78 command 00 lenLE payload crc8(payload) FF",
            physicallyVerifiedOnMX10: false
        ),
        MX10ProtocolCommandFinding(
            commandByte: 0xA3,
            payloadFormat: "one byte, 0x00",
            likelyPurpose: "request device state by AE02 notification",
            sourceReference: "physically verified MX10 status request; fulda1 protocol wiki",
            confidenceLevel: "high",
            crcFraming: "51 78 A3 00 01 00 00 00 FF",
            physicallyVerifiedOnMX10: true
        ),
        MX10ProtocolCommandFinding(
            commandByte: 0xBB,
            payloadFormat: "one byte, observed 0x01 in BLE capture",
            likelyPurpose: "device identifier or model selection command",
            sourceReference: "lisp3r BLE capture; parzivail X6h protocol command table",
            confidenceLevel: "low; purpose unclear",
            crcFraming: "51 78 command 00 lenLE payload crc8(payload) FF",
            physicallyVerifiedOnMX10: false
        ),
        MX10ProtocolCommandFinding(
            commandByte: 0xA4,
            payloadFormat: "one byte quality value, reported values 0x31-0x36 or model-specific 0x01/0x03/0x05",
            likelyPurpose: "print quality or concentration setting",
            sourceReference: "fulda1 Thermal_Printer cat-printer protocol wiki; parzivail X6h notes",
            confidenceLevel: "medium for compatible printers; value mapping varies",
            crcFraming: "51 78 command 00 lenLE payload crc8(payload) FF",
            physicallyVerifiedOnMX10: false
        ),
        MX10ProtocolCommandFinding(
            commandByte: 0xA6,
            payloadFormat: "eleven-byte lattice payload; separate start/end constant payloads reported",
            likelyPurpose: "start/end lattice or printhead setup sequence",
            sourceReference: "fulda1 Thermal_Printer cat-printer protocol wiki; lisp3r captured image header/footer",
            confidenceLevel: "medium for compatible printers; semantics unclear",
            crcFraming: "51 78 command 00 lenLE payload crc8(payload) FF",
            physicallyVerifiedOnMX10: false
        ),
        MX10ProtocolCommandFinding(
            commandByte: 0xAF,
            payloadFormat: "little-endian UInt16, reported range 1...0xFFFF",
            likelyPurpose: "thermal printhead energy",
            sourceReference: "fulda1 Thermal_Printer cat-printer protocol wiki; parzivail X6h notes",
            confidenceLevel: "medium for compatible printers; unsafe to vary blindly",
            crcFraming: "51 78 command 00 lenLE payload crc8(payload) FF",
            physicallyVerifiedOnMX10: false
        ),
        MX10ProtocolCommandFinding(
            commandByte: 0xBE,
            payloadFormat: "one byte print type, or print type plus grayscale depth on some models",
            likelyPurpose: "drawing/print mode, for example image vs text",
            sourceReference: "fulda1 Thermal_Printer cat-printer protocol wiki; parzivail X6h notes",
            confidenceLevel: "medium for compatible printers; variant-dependent",
            crcFraming: "51 78 command 00 lenLE payload crc8(payload) FF; some variants report hardcoded CRC exceptions",
            physicallyVerifiedOnMX10: false
        ),
        MX10ProtocolCommandFinding(
            commandByte: 0xBD,
            payloadFormat: "one byte feed speed or model-specific speed value",
            likelyPurpose: "paper feed or print speed control",
            sourceReference: "fulda1 Thermal_Printer cat-printer protocol wiki; lisp3r captured image header/footer",
            confidenceLevel: "medium for compatible printers; value mapping unknown",
            crcFraming: "51 78 command 00 lenLE payload crc8(payload) FF",
            physicallyVerifiedOnMX10: false
        ),
        MX10ProtocolCommandFinding(
            commandByte: 0xBF,
            payloadFormat: "four-byte payload observed in captures; exact structure unclear",
            likelyPurpose: "binary compressed single scanline or print data/control segment",
            sourceReference: "lisp3r captured image header/footer; parzivail X6h protocol command table",
            confidenceLevel: "low; not understood",
            crcFraming: "51 78 command 00 lenLE payload crc8(payload) FF",
            physicallyVerifiedOnMX10: false
        )
    ]
}
