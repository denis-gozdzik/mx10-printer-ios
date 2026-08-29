import Foundation

enum MX10ProtocolError: LocalizedError {
    case invalidPrintRowLength(Int)
    case invalidFrame

    var errorDescription: String? {
        switch self {
        case .invalidPrintRowLength(let count):
            return "Expected a 48-byte row for MX10 printing but received \(count) bytes."
        case .invalidFrame:
            return "Invalid MX10 protocol frame."
        }
    }
}

struct MX10ProtocolFrame: Equatable {
    let command: UInt8
    let mode: UInt8
    let payload: Data
    let crc: UInt8
    let isCRCValid: Bool
}

enum MX10Protocol {
    static let framePrefix: [UInt8] = [0x51, 0x78]
    static let fixedByte: UInt8 = 0x00
    static let terminator: UInt8 = 0xFF
    static let printerWidthBytes = 48

    static func frame(command: UInt8, payload: Data = Data()) -> Data {
        var data = Data(framePrefix)
        data.append(command)
        data.append(fixedByte)

        let length = UInt16(payload.count)
        data.append(UInt8(length & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(payload)

        let crc = CRC8.crc8(for: payload)
        data.append(crc)
        data.append(terminator)

        return data
    }

    static func requestStatus() -> Data {
        let payload = Data([0x00])
        return frame(command: 0xA3, payload: payload)
    }

    static func feed(steps: UInt16) -> Data {
        let payload = Data([
            UInt8(steps & 0xFF),
            UInt8((steps >> 8) & 0xFF)
        ])
        return frame(command: 0xA1, payload: payload)
    }

    static func printRow(_ row: Data) throws -> Data {
        guard row.count == printerWidthBytes else {
            throw MX10ProtocolError.invalidPrintRowLength(row.count)
        }

        return frame(command: 0xA2, payload: row)
    }

    static func parseFrame(_ data: Data) -> MX10ProtocolFrame? {
        guard data.count >= 8,
              data[0] == framePrefix[0],
              data[1] == framePrefix[1],
              data[data.count - 1] == terminator else {
            return nil
        }

        let payloadLength = Int(data[4]) | (Int(data[5]) << 8)
        let expectedCount = 2 + 1 + 1 + 2 + payloadLength + 1 + 1
        guard data.count == expectedCount else {
            return nil
        }

        let payloadStartIndex = 6
        let payloadEndIndex = payloadStartIndex + payloadLength
        let payload = Data(data[payloadStartIndex..<payloadEndIndex])
        let crc = data[payloadEndIndex]

        return MX10ProtocolFrame(
            command: data[2],
            mode: data[3],
            payload: payload,
            crc: crc,
            isCRCValid: CRC8.crc8(for: payload) == crc
        )
    }
}
