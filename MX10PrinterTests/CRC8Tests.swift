import XCTest
@testable import MX10Printer

final class CRC8Tests: XCTestCase {
    func testCRC8For10And00() {
        let data = Data([0x10, 0x00])
        let checksum = CRC8.crc8(for: data)

        XCTAssertEqual(checksum, 0x57)
    }
}
