import CryptoKit
import Foundation
import SwiftUI
import UIKit

@MainActor
final class SnapshotDiagnosticsModel: ObservableObject {
    enum Phase: String { case idle, sizing, replaying, replayPassed, connecting, watching, disconnected, failed }
    @Published private(set) var phase = Phase.idle {
        didSet {
            if phase != oldValue { UIAccessibility.post(notification: .announcement, argument: "Watch diagnostics: " + phase.rawValue) }
        }
    }
    @Published private(set) var status = "Ready for local replay"
    @Published private(set) var terminals: [DiagnosticTerminal] = []
    @Published private(set) var evidenceURL: URL?
    @Published private(set) var manualRendering = "unverified"
    @Published private(set) var manualReconnect = "unverified"
    @Published var url = ""
    @Published var token = ""
    @Published var pin = ""
    private var generation = UUID()
    private var resultGeneration = UUID()
    private var task: Task<Void, Never>?
    private var replayPrerequisite: [String: String] = [:]
    private var recoveryLog: [[String: String]] = []
    private var manualMarks: [String: [String: String]] = [:]
    @Published private(set) var liveViewportText = ""
    @Published private(set) var restoredViewportText = ""
    var canConnect: Bool { !replayPrerequisite.isEmpty }
    private var automatic: [String: String] = [:]
    private var network: [String: String] = [:]
    private var hashes: [String: String] = [:]

    func replay() {
        replayPrerequisite = [:]
        disconnect()
        let identity = generation
        terminals = [DiagnosticTerminal(), DiagnosticTerminal()]
        resetAttempt()
        phase = .sizing
        task = Task {
            do {
                try await waitForSize(identity)
                phase = .replaying
                let input = try fixture("input")
                let away = try fixture("away")
                let restored = try fixture("reattach")
                let live = terminals[0], fresh = terminals[1]
                try live.feed(input)
                try live.feed(away)
                try fresh.feed(restored)
                try await compare(live, fresh, label: "snapshot", identity: identity)
                let continuation = Data("\r\nLIVE-CONTINUE\r\nDONE".utf8)
                hashes["continuation"] = Self.hash(continuation)
                try live.feed(continuation)
                try fresh.feed(continuation)
                try await compare(live, fresh, label: "continuation", identity: identity)
                try current(identity)
                replayPrerequisite = ["originatingReplayGeneration": identity.uuidString,
                                      "fixtureSetSHA256": try fixtureFingerprint(),
                                      "sourceManifestSHA256": manifestHash()]
                phase = .replayPassed
                status = "PASS: viewport text and cursor agree before and after continuation"
                persist()
            } catch { fail(error, identity: identity) }
        }
    }

    func connect() {
        guard !replayPrerequisite.isEmpty,
              replayPrerequisite["fixtureSetSHA256"] == (try? fixtureFingerprint()),
              replayPrerequisite["sourceManifestSHA256"] == manifestHash() else {
            disconnect()
            resetAttempt()
            phase = .failed
            status = "Run and pass local replay before connecting"
            record("connectRejected", ["reason": "replay prerequisite missing or stale"])
            persist()
            return
        }
        disconnect()
        let identity = generation
        resetAttempt()
        terminals = []
        phase = .connecting
        status = "Connecting to synthetic fixture server"
        record("connect")
        task = Task {
            do {
                let connection = try FixtureConnection(url: url, token: token, pin: pin)
                let transport = FixtureTransport(connection)
                var recoveryOrigin: [String: String] = [:]
                while true {
                    try current(identity)
                    let (_, snapshotValue) = try await transport.request("snapshot")
                    try current(identity)
                    guard let snapshot = snapshotValue else { throw DiagnosticFailure.message("Snapshot missing") }
                    try snapshot.validate(kind: "snapshot")
                    guard let sequence = snapshot.sequence, sequence >= 0, sequence < Int.max, let encoded = snapshot.dataBase64,
                          let data = Data(base64Encoded: encoded) else { throw DiagnosticFailure.message("Invalid snapshot payload") }
                    // Replacing the model clears parser state, scrollback, and pending bytes.
                    terminals = [DiagnosticTerminal()]
                    phase = .sizing
                    try await waitForSize(identity)
                    let terminal = terminals[0]
                    try terminal.feed(data)
                    var after = sequence
                    network = ["runID": snapshot.runID, "snapshotSequence": String(sequence),
                               "snapshotSHA256": Self.hash(data), "lastSequence": String(sequence), "certificateSHA256": connection.pin,
                               "host": connection.baseURL.host ?? "", "transport": "HTTPS exact leaf pin; TLS >= 1.2"]
                    var recoveryOutcome = recoveryOrigin
                    recoveryOutcome["runID"] = snapshot.runID
                    recoveryOutcome["sequence"] = String(sequence)
                    recoveryOutcome["outcome"] = "fresh model applied"
                    record("snapshotApplied", recoveryOutcome)
                    recoveryOrigin = [:]
                    manualRendering = "unverified"
                    manualReconnect = "unverified"
                    manualMarks = [:]
                    restoredViewportText = terminal.session.readViewportText() ?? "unavailable"
                    phase = .watching
                    status = "Watching synthetic fixture, sequence \(after)"
                    persist()
                    while true {
                        try await Task.sleep(for: .seconds(1))
                        let (code, frameValue) = try await transport.request("events", query: [
                            URLQueryItem(name: "runID", value: snapshot.runID), URLQueryItem(name: "after", value: String(after))
                        ])
                        try current(identity)
                        if code == 409 {
                            recoveryOrigin = ["oldRunID": snapshot.runID, "oldSequence": String(after)]
                            record("historyGap409", ["oldRunID": snapshot.runID, "oldSequence": String(after), "outcome": "request fresh snapshot"])
                            persist()
                            break
                        }
                        guard let frame = frameValue else { throw DiagnosticFailure.message("Events missing") }
                        try frame.validate(kind: "events")
                        guard frame.runID == snapshot.runID, let events = frame.events else {
                            throw DiagnosticFailure.message("Event generation mismatch")
                        }
                        for event in events {
                            guard after < Int.max - 1, event.sequence == after + 1, let bytes = Data(base64Encoded: event.dataBase64) else {
                                throw DiagnosticFailure.message("Noncontiguous or invalid event")
                            }
                            try terminal.feed(bytes)
                            after = event.sequence
                            network["lastSequence"] = String(after)
                        }
                        network["lastSequence"] = String(after)
                        restoredViewportText = terminal.session.readViewportText() ?? "unavailable"
                        network["viewportText"] = restoredViewportText
                        status = "Watching synthetic fixture, sequence \(after)"
                        persist()
                    }
                    phase = .connecting
                    status = "History gap: fetching fresh snapshot"
                }
            } catch { fail(error, identity: identity) }
        }
    }

    func disconnect() {
        record("disconnect", ["runID": network["runID"] ?? "none", "sequence": network["lastSequence"] ?? network["snapshotSequence"] ?? "none"])
        generation = UUID()
        task?.cancel()
        task = nil
        phase = .disconnected
        status = "Disconnected; reconnect always starts from a fresh snapshot"
        persist()
    }

    func configure(_ link: URL) {
        guard link.scheme == "awesomuxdiagnostics" else { return }
        switch link.host {
        case "replay": replay(); return
        case "connect": connect(); return
        case "disconnect": disconnect(); return
        default: break
        }
        guard link.host == "fixture",
              let components = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return }
        let items = components.queryItems ?? []
        func value(_ key: String) -> String { items.first { $0.name == key }?.value ?? "" }
        disconnect()
        resetAttempt()
        terminals = []
        url = value("url"); token = value("token"); pin = value("pin")
        status = "Fixture configuration loaded; press Connect"
        persist()
    }

    func configurationChanged() {
        disconnect()
        resetAttempt()
        terminals = []
        status = "Fixture configuration changed; press Connect"
        persist()
    }

    private func resetAttempt() {
        resultGeneration = generation
        automatic = [:]
        network = [:]
        hashes = [:]
        manualRendering = "unverified"
        manualReconnect = "unverified"
        manualMarks = [:]
        liveViewportText = ""
        restoredViewportText = ""
        persist()
    }

    private func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: "bin") else {
            throw DiagnosticFailure.message("Missing bundled fixture \(name)")
        }
        let data = try Data(contentsOf: url)
        hashes[name] = Self.hash(data)
        return data
    }

    private func waitForSize(_ identity: UUID) async throws {
        for _ in 0..<100 {
            try current(identity)
            if !terminals.isEmpty && terminals.allSatisfy(\.ready) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DiagnosticFailure.message("Fail closed: renderer did not report source dimensions 20×6")
    }

    private func compare(_ live: DiagnosticTerminal, _ fresh: DiagnosticTerminal, label: String, identity: UUID) async throws {
        let liveCursor = try await live.cursor()
        let freshCursor = try await fresh.cursor()
        try current(identity)
        guard live.ready && fresh.ready, let left = live.session.readViewportText(),
              let right = fresh.session.readViewportText() else { throw DiagnosticFailure.message("Viewport unavailable or resized") }
        liveViewportText = left
        restoredViewportText = right
        automatic[label + "LiveText"] = left
        automatic[label + "ReattachText"] = right
        automatic[label + "LiveCursor"] = liveCursor
        automatic[label + "ReattachCursor"] = freshCursor
        let expectedCursor = label == "snapshot" ? "\u{1b}[6;6R" : "\u{1b}[6;5R"
        let expectedText = label == "snapshot" ? ["AWAY", "$ next", "FINAL"] : ["LIVE-CONTINUE", "DONE"]
        let retained = expectedText.allSatisfy { left.contains($0) && right.contains($0) }
        automatic[label + "ExpectedCursor"] = expectedCursor
        automatic[label + "ExpectedTextRetained"] = retained ? "passed" : "failed"
        let equal = left == right && liveCursor == freshCursor && liveCursor == expectedCursor && retained
        automatic[label + "Result"] = equal ? "passed" : "failed"
        persist()
        guard equal else { throw DiagnosticFailure.message("\(label) viewport or cursor mismatch") }
    }

    private func current(_ identity: UUID) throws {
        guard generation == identity, !Task.isCancelled else { throw CancellationError() }
    }

    private func fail(_ error: Error, identity: UUID) {
        guard generation == identity else { return }
        record("failure", ["outcome": error is DiagnosticFailure ? "fixture validation failed" : "transport failed", "runID": network["runID"] ?? "none", "sequence": network["lastSequence"] ?? "none"])
        phase = .failed
        // Avoid exporting request URLs or headers from transport errors.
        status = (error as? DiagnosticFailure)?.errorDescription ?? "Fixture transport failed; verify endpoint and exact certificate pin"
        persist()
    }

    func markManual(_ check: String, value: String) {
        guard ["unverified", "passed", "failed"].contains(value) else { return }
        if value == "passed" {
            guard check == "rendering" ? (phase == .replayPassed || phase == .watching) : phase == .watching else { return }
            if check == "physicalNetworkReconnect", ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil { return }
        }
        if check == "rendering" { manualRendering = value } else { manualReconnect = value }
        manualMarks[check] = ["result": value, "phase": phase.rawValue, "generation": generation.uuidString,
                              "recordedAt": ISO8601DateFormatter().string(from: Date()), "provenance": "tester attested", "runID": network["runID"] ?? "local replay"]
        persist()
    }

    private func record(_ event: String, _ details: [String: String] = [:]) {
        var entry = details
        entry["event"] = event
        entry["generation"] = generation.uuidString
        entry["recordedAt"] = ISO8601DateFormatter().string(from: Date())
        recoveryLog.append(entry)
        if recoveryLog.count > 32 { recoveryLog.removeFirst(recoveryLog.count - 32) }
    }

    private func fixtureFingerprint() throws -> String {
        var bytes = Data()
        for name in ["input", "away", "reattach"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "bin") else {
                throw DiagnosticFailure.message("Missing replay fixture")
            }
            bytes.append(Data(name.utf8))
            bytes.append(Data(Self.hash(try Data(contentsOf: url)).utf8))
        }
        return Self.hash(bytes)
    }

    private func manifestHash() -> String {
        guard let url = Bundle.main.url(forResource: "source-manifest", withExtension: "txt"),
              let bytes = try? Data(contentsOf: url) else { return "missing" }
        return Self.hash(bytes)
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func persist() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
                .appendingPathComponent("SnapshotDiagnostics")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("latest-evidence.json")
            let dimensions = terminals.map { ["columns": Int($0.viewport?.columns ?? 0), "rows": Int($0.viewport?.rows ?? 0),
                "widthPixels": Int($0.viewport?.widthPixels ?? 0), "heightPixels": Int($0.viewport?.heightPixels ?? 0),
                "cellWidthPixels": Int($0.viewport?.cellWidthPixels ?? 0), "cellHeightPixels": Int($0.viewport?.cellHeightPixels ?? 0),
                "requestedWidthPoints": Int($0.size.width), "requestedHeightPoints": Int($0.size.height)] }
            #if DEBUG
            let buildConfiguration = "Debug"
            #else
            let buildConfiguration = "Release"
            #endif
            let manifest = Bundle.main.url(forResource: "source-manifest", withExtension: "txt")
                .flatMap { try? Data(contentsOf: $0) }
            let evidence: [String: Any] = [
                "buildConfiguration": buildConfiguration,
                "applicationVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "applicationBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
                "systemName": UIDevice.current.systemName, "systemVersion": UIDevice.current.systemVersion,
                "deviceModel": UIDevice.current.model,
                "sourceManifestSHA256": manifest.map(Self.hash) ?? "missing",
                "recordedAt": ISO8601DateFormatter().string(from: Date()), "generation": generation.uuidString,
                "dependencyRevision": "42bacd1339f323a693ddbca779295f4f77e5a697",
                "experimentalPrivateCAIOSurfaceLayer": true, "phase": phase.rawValue, "status": status,
                "sourceDimensions": ["columns": 20, "rows": 6], "reportedDimensions": dimensions,
                "fixtureSHA256": hashes, "automaticReplay": automatic, "syntheticNetwork": network,
                "replayPrerequisite": replayPrerequisite, "recoveryLog": recoveryLog,
                "manualAttestations": manualMarks,
                "resultGeneration": resultGeneration.uuidString,
                "manualResults": ["generation": resultGeneration.uuidString, "rendering": manualRendering, "physicalNetworkReconnect": manualReconnect],
                "simulator": ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
            ]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
            evidenceURL = destination
        } catch { status = "Evidence write failed"; evidenceURL = nil }
    }
}
