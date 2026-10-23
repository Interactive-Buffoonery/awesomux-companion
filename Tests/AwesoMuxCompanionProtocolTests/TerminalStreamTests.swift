import Foundation
import Testing
@testable import AwesoMuxCompanionProtocol

// Failure modes: a frame must survive encode/decode with its generation and
// sequence intact, oversize data must never be framed, an unknown type must
// end the stream rather than be skipped, and older envelopes must still decode.
@Suite struct TerminalStreamTests {
    typealias Stream = CompanionTerminalStream
    private static let id = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!

    private static let frames: [Stream.Frame] = [
        .snapshotBegin(.init(paneID: id.uuidString.lowercased(), targetVersion: id.uuidString.lowercased(),
            grid: .init(rows: 24, cols: 80), leader: "7", scrollbackBound: 10_000)),
        .snapshot(sequence: 0, bytes: Data("\u{1b}[2J\u{1b}[Hhello".utf8)),
        .snapshotEnd(.init(bytes: 12)),
        .output(sequence: UInt64.max, bytes: Data([0x00, 0xff, 0x1b])),
        .grid(.init(rows: 50, cols: 132)),
        .leader(.init(leader: nil)),
        .heartbeat,
        .end(.init(reason: .revoked)),
        .input(sequence: 3, bytes: Data("ls\r".utf8)),
        .claim(.init(grid: .init(rows: 40, cols: 60))),
        .ack(.init(sequence: 3)),
    ]

    @Test(arguments: frames) func frameRoundTrips(_ frame: Stream.Frame) throws {
        let encoded = try Stream.encode(frame, generation: 0xdead_beef)
        #expect(encoded[0] == frame.type.rawValue)
        #expect(Array(encoded[1..<5]) == [0xde, 0xad, 0xbe, 0xef])
        let decoded = try Stream.decode(encoded)
        #expect(decoded.generation == 0xdead_beef)
        #expect(decoded.frame == frame)
        _ = try CompanionFrame.encode(encoded, maximum: Stream.maximumFrameBytes)
    }

    @Test func snapshotBeginAlwaysMarksHistoryIncomplete() throws {
        let begin = Stream.SnapshotBegin(paneID: "p", targetVersion: "v", grid: .init(rows: 1, cols: 1), leader: nil, scrollbackBound: 0)
        let object = try JSONSerialization.jsonObject(with: CompanionProtocol.encoder().encode(begin)) as? [String: Any]
        #expect(object?["historyIncomplete"] as? Bool == true)
        #expect(object?["leader"] is NSNull)
    }

    @Test func dataCapIsEnforced() throws {
        let full = Data(repeating: 0x41, count: Stream.maximumDataBytes)
        let encoded = try Stream.encode(.output(sequence: 1, bytes: full), generation: 1)
        #expect(encoded.count == Stream.maximumFrameBytes)
        #expect(throws: Stream.Failure.tooLarge) {
            try Stream.encode(.output(sequence: 1, bytes: full + [0]), generation: 1)
        }
        #expect(throws: Stream.Failure.tooLarge) { try Stream.decode(encoded + [0]) }
    }

    @Test func controlCapMatchesDecoderCap() throws {
        #expect(throws: Stream.Failure.tooLarge) {
            try Stream.encode(.leader(.init(leader: String(repeating: "a", count: Stream.maximumFrameBytes))), generation: 1)
        }
    }

    // A snapshot byte count is bounded independently of the small JSON frame
    // carrying it; aggregate chunk accounting belongs to the stream consumer.
    @Test(arguments: [-1, Stream.maximumSnapshotBytes + 1, Int.max])
    func invalidSnapshotEndCountCannotBeEncoded(_ count: Int) {
        #expect(throws: Stream.Failure.invalidControl) {
            try Stream.encode(.snapshotEnd(.init(bytes: count)), generation: 1)
        }
    }

    @Test(arguments: [-1, Stream.maximumSnapshotBytes + 1, Int.max])
    func invalidSnapshotEndCountCannotBeDecoded(_ count: Int) {
        let wire = Data([Stream.FrameType.snapshotEnd.rawValue, 0, 0, 0, 1])
            + Data("{\"bytes\":\(count)}".utf8)
        #expect(throws: Stream.Failure.invalidControl) { try Stream.decode(wire) }
    }

    @Test(arguments: [0, Stream.maximumSnapshotBytes])
    func snapshotEndCountBoundariesRoundTrip(_ count: Int) throws {
        let frame = Stream.Frame.snapshotEnd(.init(bytes: count))
        let decoded = try Stream.decode(Stream.encode(frame, generation: 1))
        #expect(decoded.frame == frame)
    }

    @Test func paneTargetVersionCanBeUsedInWatchRequest() throws {
        let pane = CompanionAPIResponse.Pane(
            paneID: Self.id.uuidString.lowercased(), kind: "terminal", title: "Shell", availability: "available",
            targetVersion: Self.id.uuidString.lowercased())
        let paneID: UUID = try #require(UUID(uuidString: pane.paneID))
        let targetVersion: UUID = try #require(pane.targetVersion.flatMap(UUID.init(uuidString:)))
        let request = CompanionAPIRequest(
            operation: CompanionOperation.watchTerminal.rawValue, connectionID: Self.id,
            paneID: paneID, targetVersion: targetVersion, streamVersion: 1)
        let decoded = try CompanionProtocol.decoder().decode(
            CompanionAPIRequest.self, from: CompanionProtocol.encoder().encode(request))
        #expect(decoded.targetVersion == Self.id)
        let begin = Stream.SnapshotBegin(
            paneID: pane.paneID, targetVersion: try #require(pane.targetVersion),
            grid: .init(rows: 24, cols: 80), leader: nil, scrollbackBound: Stream.maximumSnapshotBytes)
        #expect(UUID(uuidString: begin.targetVersion) == decoded.targetVersion)
    }

    @Test func malformedFramesAreRejected() {
        #expect(throws: Stream.Failure.unknownType(0x7f)) { try Stream.decode(Data([0x7f, 0, 0, 0, 1, 0x7b, 0x7d])) }
        #expect(throws: Stream.Failure.tooShort) { try Stream.decode(Data([Stream.FrameType.output.rawValue, 0, 0, 0, 1, 0])) }
        #expect(throws: Stream.Failure.tooShort) { try Stream.decode(Data([Stream.FrameType.heartbeat.rawValue, 0, 0])) }
        #expect(throws: Stream.Failure.invalidControl) {
            try Stream.decode(Data([Stream.FrameType.end.rawValue, 0, 0, 0, 1]) + Data("{\"reason\":\"later\"}".utf8))
        }
        #expect(throws: Stream.Failure.invalidControl) { try Stream.encode(.phoneSent(.reply), generation: 1) }
    }

    @Test func replyDecodesOnlyAsRejectable() throws {
        let decoded = try Stream.decode(Data([Stream.FrameType.reply.rawValue, 0, 0, 0, 2]) + Data([0, 0, 0, 0, 0, 0, 0, 1, 0x61]))
        #expect(decoded.frame == .phoneSent(.reply))
        #expect(decoded.generation == 2)
    }

    // ADR-0041: an empty input frame is a protocol error and the cap is exact.
    @Test func inputBoundsAreEnforced() throws {
        let header = Data([Stream.FrameType.input.rawValue, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(throws: Stream.Failure.invalidInput) { try Stream.decode(header) }
        #expect(throws: Stream.Failure.invalidInput) { try Stream.encode(.input(sequence: 0, bytes: Data()), generation: 1) }
        let full = Data(repeating: 0x61, count: Stream.maximumInputBytes)
        #expect(try Stream.decode(Stream.encode(.input(sequence: 0, bytes: full), generation: 1)).frame == .input(sequence: 0, bytes: full))
        #expect(throws: Stream.Failure.invalidInput) { try Stream.encode(.input(sequence: 0, bytes: full + [0x61]), generation: 1) }
    }

    @Test func watchReasonIsLenientAndWatchOnly() throws {
        func accepted(_ json: String) throws -> Stream.Accepted {
            try CompanionProtocol.decoder().decode(Stream.Accepted.self, from: Data(json.utf8))
        }
        #expect(try accepted("{\"role\":\"watch\",\"streamVersion\":1,\"watchReason\":\"input_off\"}").watchReason == .inputOff)
        #expect(try accepted("{\"role\":\"watch\",\"streamVersion\":1,\"watchReason\":\"later\"}").watchReason == nil)
        #expect(try accepted("{\"role\":\"interactive\",\"streamVersion\":1,\"watchReason\":\"input_off\"}").watchReason == nil)
        #expect(Stream.Accepted(role: .interactive, watchReason: .remotePane).watchReason == nil)
    }

    @Test func olderCapabilitiesHaveNoInput() throws {
        let old = Data(#"{"version":1,"maximumDataBytes":65536,"maximumPendingBytes":4194304,"maximumSnapshotBytes":8388608,"heartbeatSeconds":15,"idleTimeoutSeconds":45,"maximumStreamsPerDevice":2,"maximumStreamsPerMac":4}"#.utf8)
        #expect(try CompanionProtocol.decoder().decode(Stream.Capabilities.self, from: old).inputFrameMax == nil)
        #expect(Stream.Capabilities().inputFrameMax == 65_536)
    }

    @Test func capabilityDiscoveryUsesPairedRequestEnvelope() throws {
        let request = CompanionAPIRequest(operation: "get_capabilities", connectionID: Self.id)
        let decoded = try CompanionProtocol.decoder().decode(
            CompanionAPIRequest.self, from: CompanionProtocol.encoder().encode(request))
        #expect(CompanionOperation(rawValue: decoded.operation) != nil)
        #expect(decoded.connectionID == Self.id)
        #expect(decoded.paneID == nil)
    }

    @Test func watchRequestVector() throws {
        let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "vector-13", withExtension: "json", subdirectory: "Fixtures")))
        let request = try CompanionProtocol.decoder().decode(CompanionAPIRequest.self, from: data)
        #expect(request.operation == CompanionOperation.watchTerminal.rawValue)
        #expect(request.paneID == Self.id)
        #expect(request.targetVersion == Self.id)
        #expect(request.streamVersion == 1)
        #expect(request.grid == .init(rows: 40, cols: 100))
        let rebuilt = CompanionAPIRequest(
            operation: CompanionOperation.watchTerminal.rawValue, connectionID: Self.id, paneID: Self.id,
            targetVersion: Self.id, streamVersion: 1, grid: .init(rows: 40, cols: 100), requestID: Self.id)
        let encoded = try #require(JSONSerialization.jsonObject(with: CompanionProtocol.encoder().encode(rebuilt)) as? NSDictionary)
        let canonical = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: Self.id.uuidString.lowercased(), with: Self.id.uuidString).utf8)
        #expect(encoded == (try #require(JSONSerialization.jsonObject(with: canonical) as? NSDictionary)))
    }

    @Test func acceptedReplyVectorAndOldEnvelope() throws {
        let data = try Data(contentsOf: #require(Bundle.module.url(forResource: "vector-14", withExtension: "json", subdirectory: "Fixtures")))
        let response = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: data)
        #expect(response.terminalStreamAccepted == .init(role: .watch))
        #expect(response.terminalStream == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: CompanionProtocol.encoder().encode(response)) as? NSDictionary)
        let canonical = Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: Self.id.uuidString.lowercased(), with: Self.id.uuidString).utf8)
        #expect(encoded == (try #require(JSONSerialization.jsonObject(with: canonical) as? NSDictionary)))

        let old = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: Data("{\"schemaVersion\":1}".utf8))
        #expect(old.terminalStreamAccepted == nil)
        let unknownRole = try CompanionProtocol.decoder().decode(
            CompanionAPIResponse.self,
            from: Data("{\"schemaVersion\":1,\"terminalStreamAccepted\":{\"role\":\"owner\",\"streamVersion\":1}}".utf8))
        #expect(unknownRole.terminalStreamAccepted == nil)
        let status = CompanionAPIResponse(connectionStatus: "connected", terminalStream: .init())
        let decoded = try CompanionProtocol.decoder().decode(CompanionAPIResponse.self, from: CompanionProtocol.encoder().encode(status))
        #expect(decoded.terminalStream == .init())
        #expect(decoded.terminalStream?.maximumDataBytes == 65_536)
    }
}
