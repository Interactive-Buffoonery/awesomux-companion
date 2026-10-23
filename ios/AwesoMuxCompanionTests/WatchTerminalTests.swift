import AwesoMuxCompanionProtocol
import GhosttyTerminal
import SwiftUI
import UIKit
import XCTest
@testable import AwesoMuxCompanion

@MainActor
final class WatchTerminalTests: XCTestCase {
    private let initialGrid = CompanionTerminalStream.Grid(rows: 6, cols: 20)

    func testDrawableBudgetAcceptsBoundariesAndUsesAtLeastThreeTimesScale() throws {
        // 8192 x 1024 physical pixels is exactly 32 MiB in BGRA.
        let boundary = CGSize(width: 2048, height: 256)
        XCTAssertNoThrow(try WatchDrawableBudget.validate(size: boundary, displayScale: 4))
        XCTAssertThrowsError(try WatchDrawableBudget.validate(
            size: CGSize(width: 2048.25, height: 256), displayScale: 4)) {
            XCTAssertEqual($0 as? WatchTerminalFailure, .drawableTooLarge)
        }
        XCTAssertNoThrow(try WatchDrawableBudget.validate(
            size: CGSize(width: 640, height: 384), displayScale: 3))
        for scale in [CGFloat(1), 2, 3] {
            XCTAssertThrowsError(try WatchDrawableBudget.validate(
                size: CGSize(width: 1000, height: 1000), displayScale: scale)) {
                XCTAssertEqual($0 as? WatchTerminalFailure, .drawableTooLarge)
            }
        }
    }

    func testDrawableBudgetRejectsOversizedGridEstimatesAndCalibrationSizes() {
        let sizes: [CGSize] = [
            CGSize(width: 1000 * 8, height: 250 * 16),
            CGSize(width: 250 * 8, height: 1000 * 16),
            CGSize(width: 8193, height: 1),
            CGSize(width: 1, height: 8193),
            CGSize(width: 2048, height: 256.25),
            CGSize(width: CGFloat.infinity, height: 1),
            CGSize(width: 1, height: CGFloat.nan),
            CGSize(width: 0, height: 100),
            CGSize(width: 100, height: -1)
        ]
        for size in sizes {
            XCTAssertThrowsError(try WatchDrawableBudget.validate(size: size, displayScale: 4)) {
                XCTAssertEqual($0 as? WatchTerminalFailure, .drawableTooLarge)
            }
        }
        for scale in [CGFloat(0), -1, .infinity, .nan] {
            XCTAssertThrowsError(try WatchDrawableBudget.validate(
                size: CGSize(width: 100, height: 100), displayScale: scale)) {
                XCTAssertEqual($0 as? WatchTerminalFailure, .drawableTooLarge)
            }
        }
    }

    func testFontSizeKeepsSmallGridsAtThirteenAndFitsLargeGridsInBudget() throws {
        XCTAssertEqual(WatchDrawableBudget.fontSize(for: .init(rows: 24, cols: 80)), 13)
        for (rows, cols) in [(70, 240), (100, 400), (250, 1000), (1000, 250), (1000, 1)] {
            let fontSize = WatchDrawableBudget.fontSize(for: .init(rows: rows, cols: cols))
            XCTAssertLessThan(fontSize, 13)
            let cell = WatchDrawableBudget.cellSize(fontSize: fontSize)
            // Allow the estimate to run 20% small and still fit.
            XCTAssertNoThrow(try WatchDrawableBudget.validate(
                size: CGSize(width: CGFloat(cols) * cell.width * 1.2, height: CGFloat(rows) * cell.height * 1.2),
                displayScale: 3), "\(cols)x\(rows)")
        }
    }

    func testWideMacGridRendersAndGrowingPastItsFontRequestsSnapshot() async throws {
        let terminal = WatchTerminal()
        let host = try mount([terminal])
        defer { host.close(); terminal.clear() }
        let widest = CompanionTerminalStream.Grid(rows: 100, cols: 400)
        try terminal.reset(grid: widest, scrollbackBound: 4096)
        try await idle([terminal])
        XCTAssertEqual(terminal.reportedGrid, widest)
        let wide = CompanionTerminalStream.Grid(rows: 70, cols: 240)
        try terminal.reset(grid: wide, scrollbackBound: 4096)
        try await idle([terminal])
        XCTAssertEqual(terminal.reportedGrid, wide)
        try terminal.feed(Data("WIDE".utf8))
        try await idle([terminal])
        XCTAssertTrue(try XCTUnwrap(terminal.readViewportText()).contains("WIDE"))

        var failure: Error?
        terminal.onFailure = { failure = $0 }
        try terminal.resize(.init(rows: 140, cols: 480))
        XCTAssertEqual(failure as? WatchTerminalFailure, .gridOutgrewFont)
    }

    func testProductionRendererReplaysCapturedReattachAndContinuation() async throws {
        let live = WatchTerminal(), restored = WatchTerminal()
        let host = try mount([live, restored])
        defer { host.close(); live.clear(); restored.clear() }
        try live.reset(grid: initialGrid, scrollbackBound: 1 << 20)
        try restored.reset(grid: initialGrid, scrollbackBound: 1 << 20)
        try await idle([live, restored])
        try live.feed(fixture("input"))
        try live.feed(fixture("away"))
        try restored.feed(fixture("reattach"))
        try await idle([live, restored])
        let before = try XCTUnwrap(live.readViewportText())
        XCTAssertEqual(before, restored.readViewportText())
        for value in ["AWAY", "$ next", "FINAL"] { XCTAssertTrue(before.contains(value)) }

        let continuation = Data("\r\nLIVE-CONTINUE\r\nDONE".utf8)
        try live.feed(continuation)
        try restored.feed(continuation)
        try await idle([live, restored])
        let after = try XCTUnwrap(live.readViewportText())
        XCTAssertEqual(after, restored.readViewportText())
        XCTAssertTrue(after.contains("LIVE-CONTINUE"))
        XCTAssertTrue(after.contains("DONE"))
        XCTAssertEqual(live.reportedGrid, initialGrid)
        XCTAssertEqual(restored.reportedGrid, initialGrid)
        await displayCycles()
        attach(host.window, name: "Production Watch replay after live continuation")

        // Reset must replace parser state, retained cells and queued operations.
        try restored.reset(grid: initialGrid, scrollbackBound: 1 << 20)
        try await idle([restored])
        XCTAssertFalse(try XCTUnwrap(restored.readViewportText()).contains("DONE"))
        try restored.feed(fixture("reattach"))
        try restored.feed(continuation)
        try await idle([restored])
        XCTAssertEqual(after, restored.readViewportText())
    }

    func testModeProbesRecoverAfterNativeParameterDigitWrap() async throws {
        let terminal = WatchTerminal()
        let host = try mount([terminal])
        defer { host.close(); terminal.clear() }
        try terminal.reset(grid: initialGrid, scrollbackBound: 4096)
        try await idle([terminal])
        for digits in [255, 256, 257, 300] {
            try terminal.feed(Data("\u{1b}[?2004h\u{1b}[?1h".utf8))
            try terminal.feed(Data(("\u{1b}[?" + String(repeating: "0", count: digits - 4) + "2004$p").utf8))
            try terminal.feed(Data("\u{1b}[?2004l\u{1b}[?1l".utf8))
            try await idle([terminal])
            let modes = await terminal.inputModes()
            XCTAssertEqual(modes, WatchInputModes())
        }
    }

    func testSplitControlSequencesAndWideCombiningUTF8KeepParserState() async throws {
        let whole = WatchTerminal(), split = WatchTerminal()
        let host = try mount([whole, split])
        defer { host.close(); whole.clear(); split.clear() }
        try whole.reset(grid: initialGrid, scrollbackBound: 4096)
        try split.reset(grid: initialGrid, scrollbackBound: 4096)
        try await idle([whole, split])
        let bytes = Data("\u{1b}[2J\u{1b}[Hone 界 e\u{301}\r\n\u{1b}[31mRED\u{1b}[0m\r\nend".utf8)
        try whole.feed(bytes)
        // Split inside CSI parameters, SGR and each multibyte character.
        for byte in bytes { try split.feed(Data([byte])) }
        try await idle([whole, split])
        let text = try XCTUnwrap(split.readViewportText())
        XCTAssertEqual(text, whole.readViewportText())
        XCTAssertTrue(text.contains("界"))
        XCTAssertTrue(text.precomposedStringWithCanonicalMapping.contains("é"))
        XCTAssertTrue(text.contains("RED"))
        XCTAssertTrue(text.contains("end"))
    }

    func testAuthoritativeGridChangeOrdersOutputAndPhoneLayoutKeepsGrid() async throws {
        let changing = WatchTerminal(), reference = WatchTerminal()
        let host = try mount([changing, reference], initialZoom: 2)
        defer { host.close(); changing.clear(); reference.clear() }
        let larger = CompanionTerminalStream.Grid(rows: 8, cols: 24)
        try changing.reset(grid: initialGrid, scrollbackBound: 4096)
        try reference.reset(grid: larger, scrollbackBound: 4096)
        try await idle([changing, reference])
        XCTAssertEqual(changing.reportedGrid, initialGrid)
        XCTAssertEqual(reference.reportedGrid, larger)
        let prefix = Data("BEFORE\r\nSECOND".utf8)
        let suffix = Data("\r\nAFTER 界 e\u{301}".utf8)
        try changing.feed(prefix)
        try changing.resize(larger)
        try changing.feed(suffix)
        try reference.feed(prefix)
        try reference.feed(suffix)
        try await idle([changing, reference])
        XCTAssertEqual(changing.reportedGrid, larger)
        let text = try XCTUnwrap(changing.readViewportText())
        XCTAssertEqual(text, reference.readViewportText())
        XCTAssertTrue(text.contains("BEFORE"))
        XCTAssertTrue(text.contains("AFTER"))

        host.window.frame.size = CGSize(width: 740, height: 360)
        host.window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        try await idle([changing, reference])
        XCTAssertEqual(changing.reportedGrid, larger)
        XCTAssertEqual(changing.readViewportText(), text)
        await displayCycles()
        attach(host.window, name: "Production Watch authoritative grid after phone layout change")
    }

    func testHostEffectsAreDeniedAndTerminalRepliesAreDiscarded() async throws {
        let terminal = WatchTerminal()
        let host = try mount([terminal])
        let previousItems = UIPasteboard.general.items
        defer { terminal.clear(); host.close(); UIPasteboard.general.items = previousItems }
        UIPasteboard.general.string = "watch-test-private-clipboard"
        try terminal.reset(grid: initialGrid, scrollbackBound: 4096)
        try await idle([terminal])
        let count = terminal.discardedWriteByteCount
        try terminal.feed(Data(("SAFE\u{1b}]52;c;cmVwbGFjZWQ=\u{7}"
            + "\u{1b}]52;c;?\u{1b}\\"
            + "\u{1b}]777;notify;title;body\u{7}"
            + "\u{1b}]8;;https://example.invalid\u{1b}\\link\u{1b}]8;;\u{1b}\\"
            + "\u{1b}[6n").utf8))
        try await idle([terminal])
        XCTAssertEqual(UIPasteboard.general.string, "watch-test-private-clipboard")
        XCTAssertGreaterThan(terminal.discardedWriteByteCount, count)
        XCTAssertTrue(try XCTUnwrap(terminal.readViewportText()).contains("SAFE"))
        let views = descendants(host.window).compactMap { $0 as? UITerminalView }
        XCTAssertEqual(views.count, 1)
        let view = try XCTUnwrap(views.first)
        XCTAssertFalse(view.canBecomeFirstResponder)
        XCTAssertFalse(view.interactions.contains { $0 is UIDropInteraction })
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
        XCTAssertNil(terminal.failure)
        // No desktop notification or URL-opening delegate is installed. This
        // verifies clipboard/query behavior, not operating-system notification UI.
    }

    func testInputReadsPasteAndCursorModesFromNativeEmulatorAndResetsThem() async throws {
        let terminal = WatchTerminal()
        let host = try mount([terminal])
        defer { host.close(); terminal.clear() }
        try terminal.reset(grid: initialGrid, scrollbackBound: 4096)
        try await idle([terminal])
        let initial = await terminal.inputModes()
        XCTAssertEqual(initial, WatchInputModes())
        try terminal.feed(Data("\u{1b}[?2004h\u{1b}[?1h".utf8))
        let enabled = await terminal.inputModes()
        XCTAssertEqual(enabled, WatchInputModes(bracketedPaste: true, applicationCursor: true))
        try terminal.feed(Data("\u{1b}[?2004l\u{1b}[?1l".utf8))
        let disabled = await terminal.inputModes()
        XCTAssertEqual(disabled, WatchInputModes())
        let phone = terminal.phoneGrid(for: CGSize(width: 390, height: 500))
        XCTAssertTrue((20...60).contains(phone.cols))
        XCTAssertTrue((10...40).contains(phone.rows))
    }

    func testModeProbeAccountsForQueriesInAbortedDCSHeaders() async throws {
        let terminal = WatchTerminal()
        let host = try mount([terminal])
        defer { host.close(); terminal.clear() }
        try terminal.reset(grid: initialGrid, scrollbackBound: 4096)
        try await idle([terminal])
        try terminal.feed(Data("\u{1b}[?2004h\u{1b}[?1h\u{1b}P".utf8) + Data([0x9b])
                          + Data("?2004$p\u{1b}P".utf8) + Data([0x9b])
                          + Data("?1$p\u{1b}[?2004l\u{1b}[?1l".utf8))
        try await idle([terminal])
        let modes = await terminal.inputModes()
        XCTAssertEqual(modes, WatchInputModes())
    }

    func testModeProbesWaitForSplitControlStringsAndUTF8WithoutChangingOutput() async throws {
        let terminal = WatchTerminal()
        let host = try mount([terminal])
        defer { host.close(); terminal.clear() }
        try terminal.reset(grid: initialGrid, scrollbackBound: 4096)
        try await idle([terminal])
        for (prefix, suffix) in [(Data("\u{1b}[?2004".utf8), Data("h".utf8)),
                                 (Data("\u{1b}]2;title".utf8), Data("\u{1b}\\".utf8)),
                                 (Data([0xe7, 0x95]), Data([0x8c]))] {
            try terminal.feed(prefix)
            let read = Task { await terminal.inputModes() }
            await Task.yield()
            try terminal.feed(suffix)
            let modes = await read.value
            XCTAssertEqual(modes?.bracketedPaste, true)
        }
        try await idle([terminal])
        XCTAssertTrue(try XCTUnwrap(terminal.readViewportText()).contains("界"))
        XCTAssertFalse(try XCTUnwrap(terminal.readViewportText()).contains("�"))
        // Earlier Mac queries must not satisfy the local probe with stale modes.
        try terminal.feed(Data("\u{1b}[?2004$p\u{1b}[?2004l".utf8))
        let latest = await terminal.inputModes()
        XCTAssertEqual(latest?.bracketedPaste, false)
    }

    func testAuthorityIsRecheckedByPendingDrainAndCopy() async throws {
        let terminal = WatchTerminal()
        var allowed = true
        terminal.canRender = { allowed }
        let host = try mount([terminal])
        defer { host.close(); terminal.clear() }
        try terminal.reset(grid: initialGrid, scrollbackBound: 4096)
        try await idle([terminal])
        let view = try XCTUnwrap(descendants(host.window).compactMap { $0 as? UITerminalView }.first)
        try terminal.feed(Data("PRIVATE".utf8))
        allowed = false
        // Exercise the live callback boundary before any SwiftUI onChange.
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
        XCTAssertNil(terminal.readViewportText())
        XCTAssertFalse(terminal.isReady)
        XCTAssertThrowsError(try terminal.feed(Data("late".utf8)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(terminal.isReady)
    }

    func testReadinessBufferOverflowFailsClosedBeforeViewAttaches() throws {
        let terminal = WatchTerminal()
        defer { terminal.clear() }
        var failure: Error?
        terminal.onFailure = { failure = $0 }
        try terminal.reset(grid: initialGrid, scrollbackBound: 4096)
        let frame = Data(repeating: 65, count: CompanionTerminalStream.maximumDataBytes)
        for _ in 0..<(CompanionTerminalStream.maximumSnapshotBytes / frame.count) { try terminal.feed(frame) }
        XCTAssertThrowsError(try terminal.feed(Data([66])))
        XCTAssertNotNil(failure)
        XCTAssertFalse(terminal.isReady)
        XCTAssertNil(terminal.readViewportText())
    }

    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "bin", subdirectory: "SnapshotReplay")
            ?? bundle.url(forResource: name, withExtension: "bin"), "Missing bundled replay fixture: \(name)")
        return try Data(contentsOf: url)
    }

    private func idle(_ terminals: [WatchTerminal]) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        while ContinuousClock.now < deadline {
            for terminal in terminals { if let failure = terminal.failure { throw failure } }
            if terminals.allSatisfy(\.isIdle) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Production Watch renderer did not reach its exact grid and drain before the deadline")
        throw WatchTerminalFailure.readinessTimeout
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func displayCycles() async {
        let rendered = expectation(description: "Display cycles before pixel capture")
        let observer = WatchDisplayCycles { rendered.fulfill() }
        observer.start()
        defer { observer.stop() }
        await fulfillment(of: [rendered], timeout: 2)
    }

    private func attach(_ window: UIWindow, name: String) {
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        XCTAssertTrue(hasVisibleContent(image), "Mounted Watch screenshot must contain visible content")
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func hasVisibleContent(_ image: UIImage) -> Bool {
        guard let source = image.cgImage else { return false }
        var pixels = [UInt32](repeating: 0, count: 32 * 64)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 64,
                                          bitsPerComponent: 8, bytesPerRow: 32 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: 32, height: 64))
            let values = buffer.bindMemory(to: UInt32.self)
            return values.contains { $0 != values[0] }
        }
    }

    private func mount(_ terminals: [WatchTerminal], initialZoom: Double = 1) throws -> TestHost {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        window.rootViewController = UIHostingController(rootView: VStack {
            ForEach(Array(terminals.enumerated()), id: \.offset) { _, terminal in
                WatchTerminalView(terminal: terminal, initialZoom: initialZoom).frame(height: 280)
            }
        })
        window.makeKeyAndVisible()
        return TestHost(window: window, previous: previous)
    }
}

@MainActor
private struct TestHost {
    let window: UIWindow
    weak var previous: UIWindow?
    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKey()
    }
}

@MainActor
private final class WatchDisplayCycles: NSObject {
    private var link: CADisplayLink?
    private var remaining = 3
    private let completed: () -> Void

    init(completed: @escaping () -> Void) { self.completed = completed }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    func stop() { link?.invalidate(); link = nil }

    @objc private func tick() {
        remaining -= 1
        if remaining == 0 { stop(); completed() }
    }
}
