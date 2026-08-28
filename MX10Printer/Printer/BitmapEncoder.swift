import Foundation

struct BitmapEncoder {
    static let rowByteCount = 48

    static func solidRow(_ value: UInt8 = 0xFF) -> Data {
        Data(repeating: value, count: rowByteCount)
    }

    static func testRows() -> [Data] {
        var rows: [Data] = []

        for index in 0..<24 {
            var row = Data(repeating: 0x00, count: rowByteCount)

            if index % 3 == 0 {
                row = Data(repeating: 0xFF, count: rowByteCount)
            } else if index % 3 == 1 {
                for byteIndex in 0..<rowByteCount {
                    if byteIndex % 2 == 0 {
                        row[byteIndex] = 0xFF
                    }
                }
            } else {
                for byteIndex in 0..<rowByteCount {
                    if byteIndex % 4 == 0 || byteIndex % 4 == 1 {
                        row[byteIndex] = 0xFF
                    }
                }
            }

            rows.append(row)
        }

        return rows
    }
}
