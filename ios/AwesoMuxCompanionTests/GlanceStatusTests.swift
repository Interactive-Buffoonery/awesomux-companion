import XCTest
@testable import AwesoMuxCompanion

final class GlanceStatusTests: XCTestCase {
    private let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testAgedConnectedDataShowsUpdateAgeInsteadOfOffline() {
        XCTAssertEqual(GlanceStatus(connected: true, updatedAt: updatedAt,
                                   now: updatedAt + 20 * 60), .updated(updatedAt))
        XCTAssertEqual(GlanceStatus(connected: true, updatedAt: updatedAt,
                                   isStale: true, now: updatedAt + 60), .updated(updatedAt))
    }

    func testFreshConnectedDataKeepsCurrentContent() {
        XCTAssertEqual(GlanceStatus(connected: true, updatedAt: updatedAt,
                                   now: updatedAt + 60), .current)
        XCTAssertEqual(GlanceStatus(connected: true, updatedAt: updatedAt,
                                   now: updatedAt + SharedSnapshot.freshFor), .updated(updatedAt))
    }

    func testConfirmedFailureShowsOfflineRegardlessOfAge() {
        for age in [TimeInterval(60), TimeInterval(20 * 60)] {
            XCTAssertEqual(GlanceStatus(connected: false, updatedAt: updatedAt,
                                       now: updatedAt + age), .offline)
        }
    }
}
