// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AwesoMuxCompanionProtocol",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "AwesoMuxCompanionProtocol", targets: ["AwesoMuxCompanionProtocol"])],
    targets: [
        .target(name: "AwesoMuxCompanionProtocol"),
        .testTarget(name: "AwesoMuxCompanionProtocolTests", dependencies: ["AwesoMuxCompanionProtocol"],
                    resources: [.copy("Fixtures")]),
    ]
)
