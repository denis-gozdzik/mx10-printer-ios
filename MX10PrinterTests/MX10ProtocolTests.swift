import XCTest
@testable import MX10Printer

final class MX10ProtocolTests: XCTestCase {
    func testRequestStatusFrame() {
        let actual = MX10Protocol.requestStatus()
        let expected = Data([0x51, 0x78, 0xA3, 0x00, 0x01, 0x00, 0x00, 0x00, 0xFF])

        XCTAssertEqual(actual, expected)
    }

    func testFeedFrameFor16Steps() {
        let actual = MX10Protocol.feed(steps: 16)
        let expected = Data([0x51, 0x78, 0xA1, 0x00, 0x02, 0x00, 0x10, 0x00, 0x57, 0xFF])

        XCTAssertEqual(actual, expected)
    }

    func testPrintRowAccepts48ByteRow() throws {
        let row = Data(repeating: 0xFF, count: 48)
        let frame = try MX10Protocol.printRow(row)

        XCTAssertTrue(frame.count > 0)
        XCTAssertEqual(frame[0], 0x51)
        XCTAssertEqual(frame[1], 0x78)
        XCTAssertEqual(frame[2], 0xA2)
    }

    func testPrintRowRejects47ByteRow() {
        let row = Data(repeating: 0xFF, count: 47)

        XCTAssertThrowsError(try MX10Protocol.printRow(row))
    }

    func testPrintRowRejects49ByteRow() {
        let row = Data(repeating: 0xFF, count: 49)

        XCTAssertThrowsError(try MX10Protocol.printRow(row))
    }
}
