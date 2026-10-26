import SwiftUI
import Vision
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

    @MainActor
    func testStatusLabelRendersUpdateAgeAndConfirmedOffline() throws {
        let date = Date.now - 20 * 60
        for (status, expected) in [(GlanceStatus(connected: true, updatedAt: date), "Updated"),
                                   (GlanceStatus(connected: false, updatedAt: date), "Offline")] {
            let renderer = ImageRenderer(content: GlanceStatusLabel(status: status)
                .font(.title).foregroundStyle(.black).padding().background(.white).fixedSize())
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains(expected), text)
            if expected == "Updated" {
                XCTAssertTrue(text.contains("ago"), text)
                XCTAssertFalse(text.contains("Offline"), text)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "glance-\(expected)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testConfirmedFailureShowsOfflineRegardlessOfAge() {
        for age in [TimeInterval(60), TimeInterval(20 * 60)] {
            XCTAssertEqual(GlanceStatus(connected: false, updatedAt: updatedAt,
                                       now: updatedAt + age), .offline)
        }
    }
}
