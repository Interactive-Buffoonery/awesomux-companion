import AwesoMuxCompanionProtocol
import XCTest
@testable import AwesoMuxCompanion

final class WatchStreamTests: XCTestCase {
    private typealias Stream = CompanionTerminalStream
    private let paneID = UUID()
    private let targetVersion = UUID()

    func testSnapshotThenOutputPreservesRawSplitControlAndUnicodeBytes() throws {
        var stream = try makeStream()
        let begin = begin()
        XCTAssertEqual(try stream.consume(packet(.snapshotBegin(begin))), .reset(begin))
        let parts = [Data([0x1b, 0x5b]), Data("2J界e\u{301}".utf8).prefix(4), Data([0x95, 0x8c])]
        var total = 0
        for (index, bytes) in parts.enumerated() {
            total += bytes.count
            XCTAssertEqual(try stream.consume(packet(.snapshot(sequence: UInt64(index), bytes: bytes))), .bytes(bytes))
        }
        XCTAssertEqual(try stream.consume(packet(.snapshotEnd(.init(bytes: total)))), .ready)
        let output = Data([0x00, 0xff, 0x1b])
        XCTAssertEqual(try stream.consume(packet(.output(sequence: UInt64(parts.count), bytes: output))), .bytes(output))
        XCTAssertEqual(try stream.consume(packet(.grid(.init(rows: 40, cols: 132)))), .grid(.init(rows: 40, cols: 132)))
        XCTAssertEqual(try stream.consume(packet(.leader(.init(leader: nil)))), .leader(nil))
    }

    func testNewGenerationResetsSequenceAndRequiresSnapshotAgain() throws {
        var stream = try makeStream()
        _ = try stream.consume(packet(.snapshotBegin(begin()), generation: 10))
        _ = try stream.consume(packet(.snapshot(sequence: 0, bytes: Data([1])), generation: 10))
        _ = try stream.consume(packet(.snapshotEnd(.init(bytes: 1)), generation: 10))
        XCTAssertEqual(try stream.consume(packet(.snapshotBegin(begin()), generation: 11)), .reset(begin()))
        XCTAssertEqual(try stream.consume(packet(.snapshot(sequence: 0, bytes: Data([2])), generation: 11)), .bytes(Data([2])))
        XCTAssertThrowsError(try stream.consume(packet(.output(sequence: 1, bytes: Data([3])), generation: 11)))
    }

    func testRejectsGapDuplicateAndSequenceOverflow() throws {
        for sequence: UInt64 in [1, UInt64.max] {
            var stream = try makeStream()
            _ = try stream.consume(packet(.snapshotBegin(begin())))
            XCTAssertThrowsError(try stream.consume(packet(.snapshot(sequence: sequence, bytes: Data([1])))))
        }
        var stream = try makeStream()
        _ = try stream.consume(packet(.snapshotBegin(begin())))
        _ = try stream.consume(packet(.snapshot(sequence: 0, bytes: Data([1]))))
        XCTAssertThrowsError(try stream.consume(packet(.snapshot(sequence: 0, bytes: Data([1])))))
    }

    func testRejectsStaleGenerationIncludingOldSnapshotBegin() throws {
        for stale in [Stream.Frame.output(sequence: 0, bytes: Data()), .snapshotBegin(begin()), .heartbeat] {
            var stream = try makeStream()
            _ = try stream.consume(packet(.snapshotBegin(begin()), generation: 7))
            XCTAssertThrowsError(try stream.consume(packet(stale, generation: 6)))
        }
        var stream = try makeStream()
        _ = try stream.consume(packet(.snapshotBegin(begin())))
        XCTAssertThrowsError(try stream.consume(packet(.snapshotBegin(begin()))))
    }

    func testRejectsMissingSnapshotOutputDuringSnapshotAndSnapshotAfterEnd() throws {
        var stream = try makeStream()
        XCTAssertThrowsError(try stream.consume(packet(.output(sequence: 0, bytes: Data()))))
        _ = try stream.consume(packet(.snapshotBegin(begin())))
        XCTAssertThrowsError(try stream.consume(packet(.output(sequence: 0, bytes: Data()))))
        _ = try stream.consume(packet(.snapshotEnd(.init(bytes: 0))))
        XCTAssertThrowsError(try stream.consume(packet(.snapshot(sequence: 0, bytes: Data()))))
        XCTAssertThrowsError(try stream.consume(packet(.snapshotEnd(.init(bytes: 0)))))
    }

    func testRejectsTruncatedSnapshotAndAggregateBeyondAdvertisedBound() throws {
        var stream = try makeStream(limits: limits(maximumSnapshotBytes: 4))
        _ = try stream.consume(packet(.snapshotBegin(begin(scrollbackBound: 4))))
        _ = try stream.consume(packet(.snapshot(sequence: 0, bytes: Data([1, 2]))))
        XCTAssertThrowsError(try stream.consume(packet(.snapshotEnd(.init(bytes: 3))))) { error in
            XCTAssertEqual(error as? WatchFailure, .truncatedSnapshot)
        }
        XCTAssertThrowsError(try stream.consume(packet(.snapshot(sequence: 1, bytes: Data([3, 4, 5]))))) { error in
            XCTAssertEqual(error as? WatchFailure, .snapshotTooLarge)
        }
    }

    func testSnapshotAtAdvertisedBoundIsAcceptedWithoutTruncating() throws {
        var stream = try makeStream(limits: limits(maximumSnapshotBytes: 4))
        _ = try stream.consume(packet(.snapshotBegin(begin(scrollbackBound: 4))))
        let bytes = Data([0x1b, 0x5b, 0x32, 0x4a])
        XCTAssertEqual(try stream.consume(packet(.snapshot(sequence: 0, bytes: bytes))), .bytes(bytes))
        XCTAssertEqual(try stream.consume(packet(.snapshotEnd(.init(bytes: 4)))), .ready)
    }

    func testRejectsDataBeyondAdvertisedFrameBound() throws {
        var stream = try makeStream(limits: limits(maximumDataBytes: 2))
        _ = try stream.consume(packet(.snapshotBegin(begin())))
        XCTAssertThrowsError(try stream.consume(packet(.snapshot(sequence: 0, bytes: Data([1, 2, 3])))))
    }

    func testRejectsWrongTargetAndInvalidDimensionsBeforeRendererReset() throws {
        let invalid = [begin(paneID: UUID()), begin(targetVersion: UUID()),
                       begin(grid: .init(rows: 0, cols: 80)), begin(grid: .init(rows: -1, cols: 80)),
                       begin(grid: .init(rows: Int.max, cols: Int.max)),
                       begin(grid: .init(rows: 65535, cols: 65535)), begin(scrollbackBound: -1)]
        for begin in invalid {
            var stream = try makeStream()
            XCTAssertThrowsError(try stream.consume(packet(.snapshotBegin(begin))))
        }
        var stream = try makeStream()
        _ = try stream.consume(packet(.snapshotBegin(begin())))
        XCTAssertThrowsError(try stream.consume(packet(.grid(.init(rows: 24, cols: 0)))))
    }

    func testRejectsInteractiveFramesAndReportsEndBeforeFirstSnapshot() throws {
        for type in [Stream.FrameType.input, .reply, .claim, .ack] {
            var stream = try makeStream()
            _ = try stream.consume(packet(.snapshotBegin(begin())))
            XCTAssertThrowsError(try stream.consume(packet(.phoneSent(type))))
        }
        var stream = try makeStream()
        XCTAssertThrowsError(try stream.consume(packet(.end(.init(reason: .revoked))))) { error in
            XCTAssertEqual(error as? WatchFailure, .ended(.revoked))
        }
    }

    private func makeStream(limits: Stream.Capabilities = .init()) throws -> WatchStream {
        try WatchStream(paneID: paneID, targetVersion: targetVersion, capabilities: limits)
    }

    private func packet(_ frame: Stream.Frame, generation: UInt32 = 1) -> WatchPacket {
        WatchPacket(frame: frame, generation: generation)
    }

    private func begin(paneID: UUID? = nil, targetVersion: UUID? = nil,
                       grid: Stream.Grid = .init(rows: 24, cols: 80),
                       scrollbackBound: Int = Stream.maximumSnapshotBytes) -> Stream.SnapshotBegin {
        .init(paneID: (paneID ?? self.paneID).uuidString, targetVersion: (targetVersion ?? self.targetVersion).uuidString,
              grid: grid, leader: nil, scrollbackBound: scrollbackBound)
    }

    private func limits(maximumDataBytes: Int = Stream.maximumDataBytes,
                        maximumSnapshotBytes: Int = Stream.maximumSnapshotBytes) throws -> Stream.Capabilities {
        let data = try CompanionProtocol.encoder().encode(Stream.Capabilities())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["maximumDataBytes"] = maximumDataBytes
        object["maximumSnapshotBytes"] = maximumSnapshotBytes
        return try CompanionProtocol.decoder().decode(Stream.Capabilities.self,
            from: JSONSerialization.data(withJSONObject: object))
    }
}
