import CryptoKit
import Foundation
import GhosttyTerminal
import Metal
import QuartzCore
import SwiftUI
import UIKit

enum Observation: String, CaseIterable, Codable, Identifiable {
    case pending
    case passed
    case failed

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ManualCheck: String, CaseIterable, Identifiable {
    case rendering
    case selection
    case keyboardIME
    case voiceOver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rendering: "Metal rendering"
        case .selection: "Touch selection and copy"
        case .keyboardIME: "Keyboard and IME input"
        case .voiceOver: "VoiceOver terminal content"
        }
    }

    var instructions: String {
        switch self {
        case .rendering:
            "Confirm colored ASCII and the Unicode sample render without clipping or corruption."
        case .selection:
            "Double-tap a word, extend the selection, then copy it from the native edit menu."
        case .keyboardIME:
            "Open the keyboard, type plain text, then commit marked text from an IME; confirm callback bytes."
        case .voiceOver:
            "Enable VoiceOver and swipe onto the terminal. Pass only if its rendered content is announced meaningfully."
        }
    }
}

@MainActor
final class RendererSpikeModel: ObservableObject {
    static let dependencyRevision = "42bacd1339f323a693ddbca779295f4f77e5a697"
    static let expectedCursorReportHex = "1B 5B 35 3B 31 30 52"

    #if DEBUG
        static let buildConfiguration = "Debug"
    #else
        static let buildConfiguration = "Release"
    #endif

    @Published private(set) var callbackHex = ""
    @Published private(set) var selfCheckPassed = false
    @Published private(set) var selfCheckSummary = "Waiting for terminal surface"
    @Published private(set) var viewportSummary = "Viewport not reported"
    @Published private(set) var evidencePath = "Not written yet"
    @Published private(set) var lifecycleCheckSummary = "Surface rebuild check not run"
    @Published private(set) var lifecycleCheckRunning = false
    private var lifecycleLayerCounts: [Int] = []
    private var blendingPixelFormats: [UInt] = []
    private var lifecycleExpectedReport: Data?
    private var lifecycleReportBytes = Data()
    private var lifecycleReportReceived = false
    @Published private var observations: [ManualCheck: Observation] = Dictionary(
        uniqueKeysWithValues: ManualCheck.allCases.map { ($0, .pending) }
    )

    let terminal = TerminalViewState()
    let session: InMemoryTerminalSession

    private let observer: SessionObserver
    private var callbackBytes = Data()
    private var callbackChunks: [CallbackChunk] = []
    private var started = false
    private var didRunAutomaticCheck = false
    private var lastViewport: InMemoryTerminalViewport?
    private var fixtureFedAt: Date?
    private var cursorQuerySentAt: Date?
    private var cursorResponseTimeoutTask: Task<Void, Never>?
    private var viewportText = ""

    init() {
        let observer = SessionObserver()
        self.observer = observer
        session = InMemoryTerminalSession(
            write: { [weak observer] data in
                observer?.recordOutput(data)
            },
            resize: { [weak observer] viewport in
                observer?.recordResize(viewport)
            }
        )
        observer.model = self
        terminal.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            fontSize: 13
        )
    }

    func start() {
        guard !started else { return }
        started = true
        writeEvidence()
        print("RENDERER_SPIKE dependency_revision=\(Self.dependencyRevision)")
        if ProcessInfo.processInfo.arguments.contains("--check-surface-rebuilds") {
            Task { @MainActor in
                for _ in 0..<60 {
                    if selfCheckPassed {
                        checkSurfaceRebuilds()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                lifecycleCheckSummary = "FAIL: initial surface did not answer the cursor query"
                writeEvidence()
            }
        }
    }

    func feedFixture() {
        fixtureFedAt = Date()
        session.receive(Self.fixture)
        writeEvidence()
        print("RENDERER_SPIKE fixture_fed=true")
    }

    func queryCursor() {
        cursorResponseTimeoutTask?.cancel()
        selfCheckSummary = "Waiting for exact cursor report 5;10"
        cursorQuerySentAt = Date()
        session.receive(Self.cursorProbe)
        let drained = session.waitForPendingOutput()
        writeEvidence()
        print("RENDERER_SPIKE cursor_query_sent=true drained=\(drained)")
        guard drained else {
            selfCheckSummary = "FAIL: cursor probe did not reach an attached surface"
            writeEvidence()
            return
        }
        cursorResponseTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, !selfCheckPassed {
                selfCheckSummary = "FAIL: expected cursor report \(Self.expectedCursorReportHex)"
                writeEvidence()
                print("RENDERER_SPIKE_SELF_CHECK fail expected=\(Self.expectedCursorReportHex) actual=\(callbackHex)")
            }
        }
    }

    func showKeyboard() {
        terminal.requestFocus()
    }

    func checkSurfaceRebuilds() {
        guard !lifecycleCheckRunning else { return }
        lifecycleCheckRunning = true
        lifecycleLayerCounts = []
        blendingPixelFormats = []
        Task { @MainActor in
            defer {
                lifecycleExpectedReport = nil
                lifecycleCheckRunning = false
                writeEvidence()
            }
            for cycle in 1...5 {
                lifecycleCheckSummary = "Rebuilding surface \(cycle)/5"
                let fontSize: Float = terminal.configuration.fontSize == 13 ? 14 : 13
                terminal.configuration.fontSize = fontSize
                var ready = false
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if terminal.fontSize == fontSize {
                        ready = true
                        break
                    }
                }
                guard ready, let view = terminal.attachedPlatformView else {
                    lifecycleCheckSummary = "FAIL: surface did not rebuild with the new font"
                    return
                }
                feedFixture()
                let column = 11 + cycle
                lifecycleExpectedReport = Data("\u{1B}[2;\(column)R".utf8)
                lifecycleReportBytes = Data()
                lifecycleReportReceived = false
                session.receive("\u{1B}[2;\(column)H\u{1B}[6n")
                guard session.waitForPendingOutput() else {
                    lifecycleCheckSummary = "FAIL: rebuilt surface did not receive its cursor query"
                    return
                }
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if lifecycleReportReceived { break }
                }
                guard lifecycleReportReceived else {
                    lifecycleCheckSummary = "FAIL: rebuilt surface did not answer its cursor query"
                    return
                }
                let count = view.layer.sublayers?.filter { $0 is CAMetalLayer }.count ?? 0
                lifecycleLayerCounts.append(count)
                guard count == 1 else {
                    lifecycleCheckSummary = "FAIL: \(count) Metal layers after rebuild \(cycle)"
                    return
                }
            }
            guard let layer = terminal.attachedPlatformView?.layer.sublayers?.compactMap({ $0 as? CAMetalLayer }).first else {
                lifecycleCheckSummary = "FAIL: no Metal layer for blending check"
                return
            }
            for (mode, format) in [("native", MTLPixelFormat.bgra8Unorm), ("linear", .bgra8Unorm_srgb), ("native", .bgra8Unorm)] {
                lifecycleCheckSummary = "Checking color blending: \(mode)"
                let config = TerminalConfiguration { $0.withCustom("alpha-blending", mode) }
                guard terminal.controller.terminalConfiguration == config || terminal.controller.setTerminalConfiguration(config) else {
                    lifecycleCheckSummary = "FAIL: blending configuration was rejected"
                    return
                }
                session.receive("\u{1B}[8;1HBlend mode: \(mode)\u{1B}[K")
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(50))
                    if layer.pixelFormat == format { break }
                }
                blendingPixelFormats.append(layer.pixelFormat.rawValue)
                guard layer.pixelFormat == format, layer.superlayer != nil else {
                    lifecycleCheckSummary = "FAIL: Metal pixel format did not follow \(mode) blending"
                    return
                }
            }
            captureViewport()
            lifecycleCheckSummary = "PASS: 5 surface rebuilds, one Metal layer each"
        }
    }

    func captureViewport() {
        viewportText = session.readViewportText() ?? ""
        writeEvidence()
        print("RENDERER_SPIKE viewport_utf8_bytes=\(viewportText.utf8.count)")
    }

    func binding(for check: ManualCheck) -> Binding<Observation> {
        Binding(
            get: { self.observations[check] ?? .pending },
            set: { value in
                self.observations[check] = value
                self.writeEvidence()
                print("RENDERER_SPIKE manual_\(check.rawValue)=\(value.rawValue)")
            }
        )
    }

    fileprivate func receivedOutput(_ data: Data) {
        if let expected = lifecycleExpectedReport {
            lifecycleReportBytes.append(data)
            if lifecycleReportBytes.count > 512 {
                lifecycleReportBytes.removeFirst(lifecycleReportBytes.count - 512)
            }
            lifecycleReportReceived = lifecycleReportBytes.range(of: expected) != nil
        }
        callbackChunks.append(CallbackChunk(
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            hex: data.hexString
        ))
        if callbackChunks.count > 100 {
            callbackChunks.removeFirst(callbackChunks.count - 100)
        }
        callbackBytes.append(data)
        if callbackBytes.count > 512 {
            callbackBytes.removeFirst(callbackBytes.count - 512)
        }
        callbackHex = callbackBytes.map { String(format: "%02X", $0) }.joined(separator: " ")

        if !selfCheckPassed, callbackBytes.range(of: Self.expectedCursorReport) != nil {
            cursorResponseTimeoutTask?.cancel()
            cursorResponseTimeoutTask = nil
            selfCheckPassed = true
            selfCheckSummary = "PASS: libghostty returned cursor position 5;10"
            captureViewport()
            print("RENDERER_SPIKE_SELF_CHECK pass cursor_report_hex=\(callbackHex)")
        }
        writeEvidence()
    }

    fileprivate func receivedResize(_ viewport: InMemoryTerminalViewport) {
        lastViewport = viewport
        viewportSummary = "\(viewport.columns)x\(viewport.rows) cells, \(viewport.widthPixels)x\(viewport.heightPixels) px"
        writeEvidence()

        guard !didRunAutomaticCheck, viewport.columns > 0, viewport.rows > 0 else { return }
        didRunAutomaticCheck = true
        feedFixture()
        guard session.waitForPendingOutput() else {
            selfCheckSummary = "FAIL: fixture did not reach an attached surface"
            writeEvidence()
            return
        }
        queryCursor()
    }

    private func writeEvidence() {
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("IOSRendererSpike", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("latest-evidence.json")
            let encodedObservations = Dictionary(
                uniqueKeysWithValues: observations.map { ($0.key.rawValue, $0.value.rawValue) }
            )
            let evidence = Evidence(
                recordedAt: ISO8601DateFormatter().string(from: Date()),
                dependencyRevision: Self.dependencyRevision,
                buildConfiguration: Self.buildConfiguration,
                sourceManifestSHA256: Self.sourceManifestSHA256,
                deviceModel: UIDevice.current.model,
                systemName: UIDevice.current.systemName,
                systemVersion: UIDevice.current.systemVersion,
                simulator: ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil,
                viewportColumns: lastViewport?.columns,
                viewportRows: lastViewport?.rows,
                fixtureFedAt: fixtureFedAt.map { ISO8601DateFormatter().string(from: $0) },
                cursorQuerySentAt: cursorQuerySentAt.map { ISO8601DateFormatter().string(from: $0) },
                callbackHex: callbackHex,
                callbackChunks: callbackChunks,
                expectedCursorReportHex: Self.expectedCursorReportHex,
                cursorReportDetected: selfCheckPassed,
                viewportText: viewportText,
                lifecycleCheckSummary: lifecycleCheckSummary,
                lifecycleLayerCounts: lifecycleLayerCounts,
                blendingPixelFormats: blendingPixelFormats,
                manualObservations: encodedObservations
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(evidence).write(to: url, options: .atomic)
            evidencePath = url.path
        } catch {
            evidencePath = "Write failed: \(error.localizedDescription)"
            print("RENDERER_SPIKE_EVIDENCE_ERROR \(error)")
        }
    }

    private static var sourceManifestSHA256: String {
        guard let url = Bundle.main.url(forResource: "source-manifest", withExtension: "txt"),
              let data = try? Data(contentsOf: url)
        else { return "missing" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let expectedCursorReport = Data([0x1B, 0x5B, 0x35, 0x3B, 0x31, 0x30, 0x52])
    private static let cursorProbe = "\u{1B}[5;10H\u{1B}[6n"

    private static let fixture = """
    \u{1B}[2J\u{1B}[H\u{1B}[1;36mlibghostty iOS Metal renderer\u{1B}[0m\r
    \u{1B}[32mANSI sample\u{1B}[0m  color + \u{1B}[1mbold\u{1B}[0m\r
    Box: ┌──────────────┐\r
         │ GhosttyTerm  │\r
         └──────────────┘\r
    UTF-8: 👩🏽‍💻 日本語 مرحبا é\r
    Select the word GhosttyTerm, then try keyboard and IME input.\r
    """
}

private extension Data {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

private struct CallbackChunk: Codable {
    let recordedAt: String
    let hex: String
}

private struct Evidence: Codable {
    let recordedAt: String
    let dependencyRevision: String
    let buildConfiguration: String
    let sourceManifestSHA256: String
    let deviceModel: String
    let systemName: String
    let systemVersion: String
    let simulator: Bool
    let viewportColumns: UInt16?
    let viewportRows: UInt16?
    let fixtureFedAt: String?
    let cursorQuerySentAt: String?
    let callbackHex: String
    let callbackChunks: [CallbackChunk]
    let expectedCursorReportHex: String
    let cursorReportDetected: Bool
    let viewportText: String
    let lifecycleCheckSummary: String
    let lifecycleLayerCounts: [Int]
    let blendingPixelFormats: [UInt]
    let manualObservations: [String: String]
}

@MainActor
private final class SessionObserver {
    weak var model: RendererSpikeModel?

    nonisolated func recordOutput(_ data: Data) {
        Task { @MainActor [weak self] in
            self?.model?.receivedOutput(data)
        }
    }

    nonisolated func recordResize(_ viewport: InMemoryTerminalViewport) {
        Task { @MainActor [weak self] in
            self?.model?.receivedResize(viewport)
        }
    }
}
