import Foundation
import XCTest
@testable import AwesoMuxCompanion

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

final class AuthenticationDelegateTests: XCTestCase {
    func testPlatformTrustIsDefaultAndCredentialChallengesAreCancelled() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://mac.example.ts.net:8443")!)
        for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodDefault] {
            let space = URLProtectionSpace(host: "mac.example.ts.net", port: 8443, protocol: "https", realm: nil, authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: ChallengeSender())
            let (disposition, suppliedCredential) = await withCheckedContinuation { continuation in
                NoRedirectDelegate().urlSession(session, task: task, didReceive: challenge) { disposition, credential in
                    continuation.resume(returning: (disposition, credential))
                }
            }
            XCTAssertEqual(disposition, method == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge)
            XCTAssertNil(suppliedCredential)
        }
    }
}
