import XCTest
@testable import AwesoMuxCompanion

final class MacClientTests: XCTestCase {
    func testEmptyRequestUsesClientFailure() {
        XCTAssertThrowsError(try MacClient.frameRequest(Data())) { error in
            XCTAssertEqual(error as? MacClientFailure, .invalidResponse)
        }
    }

    func testOversizedRequestUsesClientFailure() {
        XCTAssertThrowsError(try MacClient.frameRequest(Data(repeating: 0, count: 8193))) { error in
            XCTAssertEqual(error as? MacClientFailure, .oversizedFrame)
        }
    }

    func testMaximumRequestPreservesFrameAndPayload() throws {
        let payload = Data(repeating: 42, count: 8192)
        let frame = try MacClient.frameRequest(payload)

        XCTAssertEqual(Array(frame.prefix(4)), [0, 0, 32, 0])
        XCTAssertEqual(frame.dropFirst(4), payload)
    }
}
