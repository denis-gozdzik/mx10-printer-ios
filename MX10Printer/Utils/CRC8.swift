import Foundation

enum CRC8 {
    static let polynomial: UInt8 = 0x07

    static func crc8(for data: Data) -> UInt8 {
        var crc: UInt8 = 0x00

        for byte in data {
            crc ^= byte

            for _ in 0..<8 {
                if (crc & 0x80) != 0 {
                    crc = ((crc << 1) ^ CRC8.polynomial) & 0xFF
                } else {
                    crc = (crc << 1) & 0xFF
                }
            }
        }

        return crc
    }
}
