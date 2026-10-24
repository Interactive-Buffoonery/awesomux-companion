import Foundation
import XCTest
@testable import AwesoMuxCompanion

final class WatchTerminalBoundaryTests: XCTestCase {
    func testProbesRequireCompleteCSIUTF8AndControlStrings() {
        for (prefix, suffix) in [(Data("\u{1b}[?2004".utf8), Data("h".utf8)),
                                 (Data([0xe7, 0x95]), Data([0x8c])),
                                 (Data("\u{1b}]title".utf8), Data([7])),
                                 (Data("\u{1b}P+q544e".utf8), Data("\u{1b}\\".utf8)),
                                 (Data("\u{1b}_payload".utf8), Data("\u{1b}\\".utf8)),
                                 (Data("\u{1b}(".utf8), Data("B".utf8))] {
            var boundary = WatchTerminalBoundary()
            boundary.receive(prefix)
            XCTAssertFalse(boundary.canProbe)
            boundary.receive(suffix)
            XCTAssertTrue(boundary.canProbe)
        }
    }

    func testQueriesAndInterruptedCSIReturnToGround() {
        var boundary = WatchTerminalBoundary()
        boundary.receive(Data("\u{1b}]2;[?2004$p\u{7}\u{1b}[?2004$p\u{1b}[?01$p".utf8))
        boundary.receive(Data("\u{1b}[?2004\u{18}$p".utf8))
        XCTAssertTrue(boundary.canProbe)
    }
    func testC1TransitionsMatchAPCAndDCSKinds() {
        for prefix in ["\u{1b}_payload", "\u{1b}Xpayload", "\u{1b}^payload", "\u{1b}P", "\u{1b}P1", "\u{1b}P "] {
            var boundary = WatchTerminalBoundary()
            boundary.receive(Data(prefix.utf8))
            boundary.receive(Data([0x9c]))
            XCTAssertTrue(boundary.canProbe, prefix)
        }
        var query = WatchTerminalBoundary()
        query.receive(Data("\u{1b}_payload".utf8) + Data([0x9b]) + Data("?2004$p".utf8))
        XCTAssertTrue(query.canProbe)
        for prefix in ["\u{1b}]title", "\u{1b}Pqpayload", "\u{1b}P:", "\u{1b}P 1"] {
            var boundary = WatchTerminalBoundary()
            boundary.receive(Data(prefix.utf8) + Data([0x9c]))
            XCTAssertFalse(boundary.canProbe, prefix)
            boundary.receive(Data("\u{1b}\\".utf8))
            XCTAssertTrue(boundary.canProbe)
        }
    }

    func testLongCSIRecoversAndCountsZeroPaddedModeRequests() {
        var boundary = WatchTerminalBoundary()
        boundary.receive(Data(("\u{1b}[" + String(repeating: "1;", count: 300) + "m").utf8))
        XCTAssertTrue(boundary.canProbe)
        boundary.receive(Data(("\u{1b}[?" + String(repeating: "0", count: 300) + "2004$p").utf8))
        XCTAssertTrue(boundary.canProbe)
    }

    func testModeProbeNeedsFreshReportsAndItsOrderedMarkers() {
        let reports = WatchModeReports()
        let first = UUID(), second = UUID()
        let markers: [UInt16] = [40_001, 50_002, 60_003]
        let modes = Data("\u{1b}[?2004;1$y\u{1b}[?1;1$y".utf8)
        let end = Data(markers.map { "\u{1b}[?\($0);0$y" }.joined().utf8)
        reports.receive(modes)
        reports.beginProbe(first, markers: markers)
        reports.receive(end)
        XCTAssertNil(reports.readProbe(first))
        reports.receive(Data("\u{1b}[?2004;2$y\u{1b}[?1;2$y".utf8))
        reports.receive(Data("\u{1b}[?40001;0$y\u{1b}[?60003;0$y".utf8))
        XCTAssertNil(reports.readProbe(first))
        reports.receive(end)
        XCTAssertEqual(reports.readProbe(first), WatchInputModes())
        reports.beginProbe(second, markers: [40_004, 50_005, 60_006])
        reports.receive(modes + end)
        XCTAssertNil(reports.readProbe(first))
        XCTAssertNil(reports.readProbe(second))
    }

    func testInvalidUTF8AndStrayC1DoNotLeaveOpenSequences() {
        let cases: [[UInt8]] = [[0xc0], [0xf5], [0x80], [0x9b], [0xc2, 0x1b, 0x5b, 0x6d]]
        for bytes in cases {
            var boundary = WatchTerminalBoundary()
            boundary.receive(Data(bytes))
            XCTAssertTrue(boundary.canProbe)
        }
    }

}
