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

    func testCountsModeQueriesButIgnoresStringsAndInterruptedCSI() {
        var boundary = WatchTerminalBoundary()
        boundary.receive(Data("\u{1b}]2;[?2004$p\u{7}\u{1b}[?2004$p\u{1b}[?01$p".utf8))
        XCTAssertEqual(boundary.pasteRequests, 1)
        XCTAssertEqual(boundary.cursorRequests, 1)
        boundary.receive(Data("\u{1b}[?2004\u{18}$p".utf8))
        XCTAssertEqual(boundary.pasteRequests, 1)
        XCTAssertTrue(boundary.canProbe)
    }
}
