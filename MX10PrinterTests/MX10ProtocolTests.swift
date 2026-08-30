import XCTest
@testable import MX10Printer

final class MX10ProtocolTests: XCTestCase {
    func testRequestStatusFrame() {
        let actual = MX10Protocol.requestStatus()
        let expected = Data([0x51, 0x78, 0xA3, 0x00, 0x01, 0x00, 0x00, 0x00, 0xFF])

        XCTAssertEqual(actual, expected)
    }

    func testFeedPaperFrameFor16Lines() {
        let actual = MX10Protocol.feedPaper(lines: 16)
        let expected = Data([0x51, 0x78, 0xBD, 0x00, 0x01, 0x00, 0x10, 0x70, 0xFF])

        XCTAssertEqual(actual, expected)
    }

    func testManualFeedFrameFor16Steps() {
        let actual = MX10Protocol.feed(steps: 16)
        let expected = Data([0x51, 0x78, 0xA1, 0x00, 0x02, 0x00, 0x10, 0x00, 0x57, 0xFF])

        XCTAssertEqual(actual, expected)
    }

    func testQualityCommandFrame() {
        let actual = MX10Protocol.setQuality()
        let expected = Data([0x51, 0x78, 0xA4, 0x00, 0x01, 0x00, 0x32, 0x9E, 0xFF])

        XCTAssertEqual(actual, expected)
    }

    func testEnergyFrame() {
        let actual = MX10Protocol.setEnergy()
        let expected = Data([0x51, 0x78, 0xAF, 0x00, 0x02, 0x00, 0xFF, 0xFF, 0x24, 0xFF])

        XCTAssertEqual(actual, expected)
    }

    func testApplyEnergyFrame() {
        let actual = MX10Protocol.applyEnergy()
        let expected = Data([0x51, 0x78, 0xBE, 0x00, 0x01, 0x00, 0x01, 0x07, 0xFF])

        XCTAssertEqual(actual, expected)
    }

    func testLatticeStartExactFrame() {
        let actual = MX10Protocol.latticeStart()
        let expected = Data([
            0x51, 0x78, 0xA6, 0x00, 0x0B, 0x00,
            0xAA, 0x55, 0x17, 0x38, 0x44, 0x5F, 0x5F, 0x5F, 0x44, 0x38, 0x2C,
            0xA1, 0xFF
        ])

        XCTAssertEqual(actual, expected)
    }

    func testLatticeEndExactFrame() {
        let actual = MX10Protocol.latticeEnd()
        let expected = Data([
            0x51, 0x78, 0xA6, 0x00, 0x0B, 0x00,
            0xAA, 0x55, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x17,
            0x11, 0xFF
        ])

        XCTAssertEqual(actual, expected)
    }

    func testSetPaperExactFrame() {
        let actual = MX10Protocol.setPaper()
        let expected = Data([0x51, 0x78, 0xA1, 0x00, 0x02, 0x00, 0x30, 0x00, 0xF9, 0xFF])

        XCTAssertEqual(actual, expected)
    }

    func testFeedPaperFrame() {
        let actual = MX10Protocol.feedPaper(lines: 0)
        let expected = Data([0x51, 0x78, 0xBD, 0x00, 0x01, 0x00, 0x00, 0x00, 0xFF])

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

    func testPrintRowReversesBitsForMX10WireOrder() throws {
        var row = Data(repeating: 0x00, count: 48)
        row[0] = 0x80
        row[1] = 0x40
        row[2] = 0x01
        row[3] = 0xFF
        row[4] = 0x00

        let frame = try MX10Protocol.printRow(row)
        let parsed = try XCTUnwrap(MX10Protocol.parseFrame(frame))

        XCTAssertEqual(MX10Protocol.reverseBitsForMX10Wire(0x80), 0x01)
        XCTAssertEqual(MX10Protocol.reverseBitsForMX10Wire(0x40), 0x02)
        XCTAssertEqual(MX10Protocol.reverseBitsForMX10Wire(0x01), 0x80)
        XCTAssertEqual(MX10Protocol.reverseBitsForMX10Wire(0xFF), 0xFF)
        XCTAssertEqual(MX10Protocol.reverseBitsForMX10Wire(0x00), 0x00)
        XCTAssertEqual(Data(parsed.payload.prefix(5)), Data([0x01, 0x02, 0x80, 0xFF, 0x00]))
    }

    func testPrintRowCRCAfterBitReversal() throws {
        var row = Data(repeating: 0x00, count: 48)
        row[0] = 0x80

        let frame = try MX10Protocol.printRow(row)
        let parsed = try XCTUnwrap(MX10Protocol.parseFrame(frame))

        XCTAssertEqual(parsed.payload.first, 0x01)
        XCTAssertEqual(parsed.crc, 0x08)
        XCTAssertEqual(parsed.isCRCValid, true)
    }

    func testPrintRowRejects47ByteRow() {
        let row = Data(repeating: 0xFF, count: 47)

        XCTAssertThrowsError(try MX10Protocol.printRow(row))
    }

    func testPrintRowRejects49ByteRow() {
        let row = Data(repeating: 0xFF, count: 49)

        XCTAssertThrowsError(try MX10Protocol.printRow(row))
    }

    func testParseStatusNotificationFrame() {
        let frame = MX10Protocol.parseFrame(
            Data([0x51, 0x78, 0xA3, 0x01, 0x03, 0x00, 0x00, 0x00, 0xB6, 0x0B, 0xFF])
        )

        XCTAssertEqual(frame?.command, 0xA3)
        XCTAssertEqual(frame?.mode, 0x01)
        XCTAssertEqual(frame?.payload, Data([0x00, 0x00, 0xB6]))
        XCTAssertEqual(frame?.crc, 0x0B)
        XCTAssertEqual(frame?.isCRCValid, true)
    }

    func testParseRejectsMalformedFrame() {
        let frame = MX10Protocol.parseFrame(Data([0x51, 0x78, 0xA3, 0x01, 0xFF]))

        XCTAssertNil(frame)
    }
}
