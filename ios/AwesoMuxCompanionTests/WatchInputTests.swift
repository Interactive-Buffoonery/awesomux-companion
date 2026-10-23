import AwesoMuxCompanionProtocol
import Foundation
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class WatchInputTests: XCTestCase {
    typealias Stream = CompanionTerminalStream

    func testAttachAndSnapshotNeverSendAndWatchReasonExplainsPermission() async {
        let wire = InputTestConnection(accepted: .init(role: .watch, watchReason: .inputOff))
        let input = WatchInput()
        input.attach(wire, ownLeaderID: "phone", authority: { true })
        input.begin(generation: 1, leader: "mac")
        input.type(Data([65])); input.takeOver()
        input.ready()
        input.type(Data([65])); input.takeOver()
        await Task.yield()
        XCTAssertTrue(wire.frames.isEmpty)
        XCTAssertFalse(input.canType)
        XCTAssertEqual(input.watchMessage, "Typing from this iPhone is off. Allow it on the Mac in Settings › Companion.")
        input.disconnect()
    }

    func testFirstKeyOrdersGridBeforeClaimingInputAndEscapeIsAlone() async {
        let (input, wire) = fixture()
        input.type(Data("early".utf8))
        XCTAssertTrue(wire.frames.isEmpty)
        input.ready()
        input.preferredGrid = .init(rows: 30, cols: 40)
        for bytes in [Data("a".utf8), Data([27]), Data("b".utf8)] { input.type(bytes) }
        await drain(wire, count: 6)
        XCTAssertEqual(wire.frames.map(\.frame), [
            .grid(.init(rows: 30, cols: 40)), .input(sequence: 0, bytes: Data([97])),
            .grid(.init(rows: 30, cols: 40)), .input(sequence: 1, bytes: Data([27])),
            .grid(.init(rows: 30, cols: 40)), .input(sequence: 2, bytes: Data([98]))])
        XCTAssertTrue(wire.frames.allSatisfy { $0.generation == 10 })
        input.disconnect()
    }

    func testTakeOverUsesLatestGridAndDoesNotInjectInputOrAssumeLeadership() async {
        let (input, wire) = fixture()
        input.ready()
        input.preferredGrid = .init(rows: 22, cols: 38)
        input.takeOver()
        await drain(wire, count: 1)
        XCTAssertEqual(wire.frames.first?.frame, .claim(.init(grid: .init(rows: 22, cols: 38))))
        XCTAssertEqual(input.drivingText, "Mac is driving")
        input.leader = "phone"
        XCTAssertEqual(input.drivingText, "You're driving")
        input.leader = nil
        XCTAssertEqual(input.drivingText, "No one is driving")
        input.disconnect()
    }

    func testSequenceRestartsAndStaleAckCannotCompleteNewPaste() async {
        let (input, wire) = fixture()
        input.ready()
        input.paste("first", modes: .init())
        await drain(wire, count: 2)
        input.begin(generation: 11, leader: "mac")
        XCTAssertEqual(input.pasteDelivery, .mayHaveRun)
        input.ready()
        input.paste("second", modes: .init())
        await drain(wire, count: 4)
        XCTAssertEqual(wire.frames[3].frame, .input(sequence: 0, bytes: Data("second".utf8)))
        XCTAssertEqual(wire.frames[3].generation, 11)
        input.acknowledge(0, generation: 10)
        XCTAssertEqual(input.pasteDelivery, .sending)
        input.acknowledge(0, generation: 11)
        XCTAssertEqual(input.pasteDelivery, .sent)
        input.disconnect()
    }

    func testAckBudgetLateAckAndOnePasteInFlight() async {
        var now: TimeInterval = 50
        let wire = InputTestConnection()
        let input = WatchInput(now: { now })
        input.attach(wire, ownLeaderID: "phone", authority: { true })
        input.begin(generation: 1, leader: "mac"); input.ready()
        input.paste("one", modes: .init())
        input.paste("two", modes: .init())
        await drain(wire, count: 2)
        XCTAssertEqual(wire.frames.count, 2)
        now = 51.999; input.checkDeadlines()
        XCTAssertEqual(input.pasteDelivery, .sending)
        now = 52; input.checkDeadlines()
        XCTAssertEqual(input.pasteDelivery, .mayHaveRun)
        input.acknowledge(0, generation: 1)
        XCTAssertEqual(input.pasteDelivery, .sent)
        input.paste("two", modes: .init())
        await drain(wire, count: 4)
        input.disconnect()
        XCTAssertEqual(input.pasteDelivery, .mayHaveRun)
        XCTAssertEqual(wire.frames.count, 4)
    }

    func testDisconnectDistinguishesQueuedPasteFromSentAndReportsTypedUncertainty() async {
        let (input, wire) = fixture()
        input.ready()
        wire.blockGrid = true
        input.paste("queued", modes: .init())
        await drain(wire, count: 1)
        input.disconnect()
        XCTAssertEqual(input.pasteDelivery, .notSent)
        wire.releaseGrid()
        await Task.yield()
        XCTAssertEqual(wire.frames.count, 1)

        let (typed, typedWire) = fixture()
        typed.ready(); typed.type(Data([13]))
        await drain(typedWire, count: 2)
        typed.disconnect()
        XCTAssertNotNil(typed.typedNotice)
        let (acked, ackedWire) = fixture()
        acked.ready(); acked.type(Data([13]))
        await drain(ackedWire, count: 2)
        acked.acknowledge(0, generation: 10)
        acked.disconnect()
        XCTAssertNil(acked.typedNotice)
    }

    func testPasteConfirmationCancellationModeChangeAndGenerationFence() async {
        let (input, wire) = fixture()
        input.ready()
        input.paste("echo a\n", modes: .init())
        XCTAssertNotNil(input.confirmation)
        XCTAssertTrue(wire.frames.isEmpty)
        input.cancelPaste()
        XCTAssertNil(input.confirmation)
        input.paste("echo a\n", modes: .init())
        input.confirmPaste(modes: .init(bracketedPaste: true))
        await drain(wire, count: 2)
        XCTAssertEqual(wire.frames[1].frame, .input(sequence: 0, bytes: Data("\u{1b}[200~echo a\n\u{1b}[201~".utf8)))
        input.acknowledge(0, generation: 10)
        input.paste("\u{1b}[201~", modes: .init(bracketedPaste: true))
        XCTAssertTrue(input.confirmation?.preview.contains(" [201~") == true)
        input.begin(generation: 11, leader: nil)
        XCTAssertNil(input.confirmation)
        input.confirmPaste(modes: .init())
        XCTAssertEqual(wire.frames.count, 2)
        input.disconnect()
    }

    func testPasteLimitCountsEncodedUTF8AndFencesAndEnterIsOneByte() async {
        for bracketed in [false, true] {
            let (input, wire) = fixture()
            input.ready()
            let overhead = bracketed ? 12 : 0
            input.paste(String(repeating: "x", count: 65_536 - overhead), modes: .init(bracketedPaste: bracketed))
            await drain(wire, count: 2)
            guard case .input(_, let bytes) = wire.frames[1].frame else { return XCTFail("missing paste") }
            XCTAssertEqual(bytes.count, 65_536)
            input.acknowledge(0, generation: 10)
            input.paste(String(repeating: "x", count: 65_537 - overhead), modes: .init(bracketedPaste: bracketed))
            XCTAssertEqual(input.pasteDelivery, .notSent)
            XCTAssertEqual(input.pasteError, WatchPaste.tooLarge)
            XCTAssertEqual(wire.frames.count, 2)
            input.disconnect()
        }
        let (input, wire) = fixture()
        input.ready(); input.type(Data([13]))
        await drain(wire, count: 2)
        XCTAssertEqual(wire.frames[1].frame, .input(sequence: 0, bytes: Data([13])))
        input.disconnect()
    }

    func testPasteEncodingMatchesGhosttyStripAndSafetyRules() {
        let stripText = String(bytes: WatchPaste.strip.sorted(), encoding: .utf8)!
        XCTAssertEqual(WatchPaste.encode(stripText, bracketed: false), Data(repeating: 32, count: WatchPaste.strip.count))
        XCTAssertEqual(WatchPaste.encode("a\r\nb\nc\td", bracketed: false), Data("a\r\rb\rc\td".utf8))
        XCTAssertEqual(WatchPaste.encode("a\r\nb", bracketed: true), Data("\u{1b}[200~a\r\nb\u{1b}[201~".utf8))
        for bracketed in [true, false] {
            XCTAssertFalse(WatchPaste.isSafe("x\u{1b}[201~y", bracketed: bracketed))
            XCTAssertTrue(WatchPaste.isSafe("hello\t世界", bracketed: bracketed))
        }
        for ending in ["\r", "\n", "\r\n"] {
            XCTAssertFalse(WatchPaste.isSafe(ending, bracketed: false))
            XCTAssertTrue(WatchPaste.isSafe(ending, bracketed: true))
        }
    }

    func testModifiersAreOneShotAndDoubleTapLocksAndArrowsRespectDECCKM() {
        var modifiers = WatchKeyModifiers()
        modifiers.control = WatchKeyModifiers.tapped(.off, doubleTap: false)
        XCTAssertEqual(modifiers.encode("C"), Data([3]))
        XCTAssertEqual(modifiers.control, .off)
        modifiers.alt = .once
        XCTAssertEqual(modifiers.encode("x"), Data([27, 120]))
        XCTAssertEqual(modifiers.alt, .off)
        modifiers.control = WatchKeyModifiers.tapped(.once, doubleTap: true)
        XCTAssertEqual(modifiers.encode("c"), Data([3]))
        XCTAssertEqual(modifiers.control, .locked)
        XCTAssertEqual(modifiers.encode("d"), Data([4]))
        XCTAssertEqual(WatchKeyModifiers.tapped(.locked, doubleTap: false), .off)
        XCTAssertEqual(WatchKeyModifiers.arrow("A", application: false), "\u{1b}[A")
        XCTAssertEqual(WatchKeyModifiers.arrow("D", application: true), "\u{1b}OD")
    }

    private func fixture() -> (WatchInput, InputTestConnection) {
        let wire = InputTestConnection()
        let input = WatchInput()
        input.attach(wire, ownLeaderID: "phone", authority: { true })
        input.begin(generation: 10, leader: "mac")
        return (input, wire)
    }

    private func drain(_ wire: InputTestConnection, count: Int) async {
        for _ in 0..<1000 {
            if wire.frames.count >= count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) frames, got \(wire.frames.count)")
    }
}

private final class InputTestConnection: WatchConnection, @unchecked Sendable {
    let capabilities = CompanionTerminalStream.Capabilities()
    let accepted: CompanionTerminalStream.Accepted
    @MainActor var frames: [WatchPacket] = []
    @MainActor var blockGrid = false
    @MainActor private var gridWaiter: CheckedContinuation<Void, Never>?

    init(accepted: CompanionTerminalStream.Accepted = .init(role: .interactive)) { self.accepted = accepted }
    @MainActor func send(_ frame: CompanionTerminalStream.Frame, generation: UInt32,
                         canSend: @escaping @MainActor @Sendable () -> Bool) async throws {
        guard canSend() else { throw CancellationError() }
        frames.append(.init(frame: frame, generation: generation))
        if case .grid = frame, blockGrid { await withCheckedContinuation { gridWaiter = $0 } }
    }
    @MainActor func releaseGrid() { gridWaiter?.resume(); gridWaiter = nil }
    func receive() async throws -> WatchPacket { throw CancellationError() }
    func cancel() {}
}
