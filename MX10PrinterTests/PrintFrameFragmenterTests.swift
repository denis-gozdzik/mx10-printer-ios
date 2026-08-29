import XCTest
@testable import MX10Printer

final class PrintFrameFragmenterTests: XCTestCase {
    func testFiftySixBytesWithMaxTwentyUsesTwentyTwentySixteen() throws {
        XCTAssertEqual(try chunkSizes(frameBytes: 56, maximumLength: 20), [20, 20, 16])
    }

    func testTwentyBytesWithMaxTwentyUsesOneChunk() throws {
        XCTAssertEqual(try chunkSizes(frameBytes: 20, maximumLength: 20), [20])
    }

    func testNineteenBytesWithMaxTwentyUsesOneChunk() throws {
        XCTAssertEqual(try chunkSizes(frameBytes: 19, maximumLength: 20), [19])
    }

    func testTwentyOneBytesWithMaxTwentyUsesTwentyOne() throws {
        XCTAssertEqual(try chunkSizes(frameBytes: 21, maximumLength: 20), [20, 1])
    }

    func testFiftySixBytesWithMaxOneHundredUsesOneChunk() throws {
        XCTAssertEqual(try chunkSizes(frameBytes: 56, maximumLength: 100), [56])
    }

    func testZeroMaximumLengthThrowsExplicitError() {
        XCTAssertThrowsError(
            try PrintFrameFragmenter.chunks(for: Data([0x01]), maximumLength: 0)
        ) { error in
            XCTAssertEqual(error as? PrintFrameFragmentationError, PrintFrameFragmentationError.invalidMaximumLength(0))
        }
    }

    func testConcatenatingChunksReproducesOriginalFrame() throws {
        let frame = Data((0..<56).map { UInt8($0) })
        let chunks = try PrintFrameFragmenter.chunks(for: frame, maximumLength: 20)

        XCTAssertEqual(reconstruct(chunks), frame)
    }

    func testFragmentedMX10FrameKeepsSingleLogicalCrcAndTerminator() throws {
        let row = Data(repeating: 0x00, count: BitmapRasterizer.rowByteCount)
        let frame = try MX10Protocol.printRow(row)
        let chunks = try PrintFrameFragmenter.chunks(for: frame, maximumLength: 20)

        XCTAssertEqual(frame.count, 56)
        XCTAssertEqual(chunks.map { $0.data.count }, [20, 20, 16])
        XCTAssertEqual(reconstruct(chunks), frame)
        XCTAssertEqual(frame.filter { $0 == MX10Protocol.terminator }.count, 1)
        let lastChunk = try XCTUnwrap(chunks.last)
        XCTAssertEqual(Data(lastChunk.data.suffix(2)), Data(frame.suffix(2)))
        XCTAssertTrue(chunks.dropLast().allSatisfy { Data($0.data.suffix(2)) != Data(frame.suffix(2)) })
        XCTAssertNotNil(MX10Protocol.parseFrame(reconstruct(chunks)))
        XCTAssertTrue(chunks.allSatisfy { MX10Protocol.parseFrame($0.data) == nil })
    }

    private func chunkSizes(frameBytes: Int, maximumLength: Int) throws -> [Int] {
        let frame = Data(repeating: 0xA5, count: frameBytes)
        return try PrintFrameFragmenter.chunks(for: frame, maximumLength: maximumLength).map { $0.data.count }
    }

    private func reconstruct(_ chunks: [PrintFrameChunk]) -> Data {
        chunks.reduce(into: Data()) { result, chunk in
            result.append(chunk.data)
        }
    }
}
