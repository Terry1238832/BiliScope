import XCTest
@testable import BiliScopeCore

final class ChunkSizingTests: XCTestCase {
    let configuration = MITMProxy.Configuration(port: 0, concurrency: 8, chunkSize: 2 << 20)

    func testSmallRemainderUsesMinimumChunk() {
        // 1 MB spread over 8 connections would be 128 KB each, below minimum.
        XCTAssertEqual(MediaHandler.adaptiveChunkSize(remaining: 1 << 20, config: configuration), 256 << 10)
    }

    func testMediumFileSpreadsOverAllConnections() {
        let size: Int64 = 8 << 20
        let chunk = MediaHandler.adaptiveChunkSize(remaining: size, config: configuration)
        XCTAssertEqual(chunk, 1 << 20)
        let chunks = RangePlanner(chunkSize: chunk, maxConcurrency: 8).chunks(for: ByteSpan(start: 0, end: size))
        XCTAssertEqual(chunks.count, 8)
    }

    func testLargeFileKeepsConfiguredChunk() {
        let size: Int64 = 200 << 20
        XCTAssertEqual(MediaHandler.adaptiveChunkSize(remaining: size, config: configuration), 2 << 20)
    }
}
