import AwesoMuxCompanionProtocol
import XCTest
@testable import AwesoMuxCompanion

final class PairingRouteTests: XCTestCase {
    private let key = String(repeating: "A", count: 43)

    func testV2LinkKeepsBothRoutesLANFirst() throws {
        let link = try PairingLink("awesomuxcompanion://pair?v=2&tailscale=100.100.20.30&lan=192.168.1.20&p=43123&fp=\(key)&s=\(key)&n=Mac")
        XCTAssertEqual(link.version, 2)
        XCTAssertEqual(link.routes, [CompanionRoute(transport: .lan, host: "192.168.1.20"),
                                     CompanionRoute(transport: .tailscale, host: "100.100.20.30")])
    }

    func testV1LinkStaysSingleRoute() throws {
        let link = try PairingLink("awesomuxcompanion://pair?v=1&h=100.100.20.30&p=43123&fp=\(key)&s=\(key)&n=Mac&t=tailscale")
        XCTAssertEqual(link.version, 1)
        XCTAssertEqual(link.routes, [CompanionRoute(transport: .tailscale, host: "100.100.20.30")])
    }

    func testRoutesMustMatchTheirClass() {
        for (transport, host) in [(CompanionTransport.lan, "100.100.20.30"), (.lan, "8.8.8.8"), (.lan, "192.168.01.2"),
                                  (.lan, "192.168.1"), (.lan, "172.32.0.1"), (.tailscale, "100.128.0.1"),
                                  (.tailscale, "192.168.1.20")] {
            XCTAssertNil(CompanionRoute.validated(transport, host), "\(transport) \(host)")
        }
        XCTAssertNotNil(CompanionRoute.validated(.lan, "172.31.255.1"))
        XCTAssertNotNil(CompanionRoute.validated(.lan, "10.0.0.1"))
        XCTAssertNotNil(CompanionRoute.validated(.tailscale, "100.64.0.1"))
        XCTAssertThrowsError(try PairingLink("awesomuxcompanion://pair?v=2&lan=100.100.20.30&p=43123&fp=\(key)&s=\(key)&n=Mac"))
    }

    func testRouteMetadataIsAllOrNothing() {
        XCTAssertEqual(CompanionRoute.routes(CompanionRoutes(p: 1, lan: "10.0.0.2", tailscale: nil)),
                       [CompanionRoute(transport: .lan, host: "10.0.0.2")])
        XCTAssertNil(CompanionRoute.routes(CompanionRoutes(p: 1, lan: "10.0.0.2", tailscale: "10.0.0.3")))
        XCTAssertNil(CompanionRoute.routes(CompanionRoutes(p: 1, lan: nil, tailscale: nil)))
    }

    func testReportedRoutesKeepOmittedKinds() {
        let lan = CompanionRoute(transport: .lan, host: "192.168.1.20")
        let tailscale = CompanionRoute(transport: .tailscale, host: "100.100.20.30")
        let movedLAN = CompanionRoute(transport: .lan, host: "10.0.0.2")
        let movedTailscale = CompanionRoute(transport: .tailscale, host: "100.100.20.31")
        // A reply sent while Tailscale is still coming up must not strand the phone away from home.
        XCTAssertEqual(CompanionRoute.merged([movedLAN], keeping: [lan, tailscale]), [movedLAN, tailscale])
        XCTAssertEqual(CompanionRoute.merged([movedTailscale], keeping: [lan, tailscale]), [lan, movedTailscale])
        XCTAssertEqual(CompanionRoute.merged([movedTailscale, movedLAN], keeping: [lan]), [movedLAN, movedTailscale])
        XCTAssertEqual(CompanionRoute.merged([movedLAN], keeping: [movedLAN]), [movedLAN])
    }

    func testV1RecordStillDecodes() throws {
        let json = #"{"macName":"Mac","host":"192.168.1.20","port":43123,"macFingerprint":"x","transport":"lan","connectionID":"01234567-89AB-CDEF-0123-456789ABCDEF","identityTag":"t","identityStorage":"secureEnclave","pairedAt":0}"#
        let record = try JSONDecoder().decode(PairingRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.routes)
        XCTAssertEqual(record.allRoutes, [CompanionRoute(transport: .lan, host: "192.168.1.20")])
    }
}
