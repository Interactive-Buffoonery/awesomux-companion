import Foundation
import GhosttyTerminal
import SwiftUI

@MainActor
final class DiagnosticTerminal: ObservableObject, Identifiable {
    let id = UUID()
    let state = TerminalViewState()
    let session: InMemoryTerminalSession
    @Published private(set) var viewport: InMemoryTerminalViewport?
    @Published var size = CGSize(width: 220, height: 120)
    private(set) var callback = Data()
    private let relay: TerminalRelay
    private var sizingAttempts = 0

    var ready: Bool { viewport?.columns == 20 && viewport?.rows == 6 }

    init() {
        let relay = TerminalRelay()
        self.relay = relay
        session = InMemoryTerminalSession(
            write: { [weak relay] data in relay?.output(data) },
            resize: { [weak relay] viewport in relay?.resize(viewport) }
        )
        relay.owner = self
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session), fontSize: 13)
    }

    fileprivate func resized(_ value: InMemoryTerminalViewport) {
        viewport = value
        guard !ready, sizingAttempts < 12, value.columns > 0, value.rows > 0 else { return }
        sizingAttempts += 1
        if value.cellWidthPixels == 0 || value.cellHeightPixels == 0 {
            // The pinned binary reports zero cell metrics on iOS. Center the
            // requested grid within its rounding interval using observed cells.
            size = CGSize(
                width: value.columns == 20 ? size.width : size.width * 20.5 / (CGFloat(value.columns) + 0.5),
                height: value.rows == 6 ? size.height : size.height * 6.5 / (CGFloat(value.rows) + 0.5)
            )
            return
        }
        let scale = UIScreen.main.scale
        let extraWidth = max(0, Int(value.widthPixels) - Int(value.columns) * Int(value.cellWidthPixels))
        let extraHeight = max(0, Int(value.heightPixels) - Int(value.rows) * Int(value.cellHeightPixels))
        size = CGSize(width: CGFloat(20 * Int(value.cellWidthPixels) + extraWidth) / scale,
                      height: CGFloat(6 * Int(value.cellHeightPixels) + extraHeight) / scale)
    }

    func feed(_ bytes: Data) throws {
        guard ready else { throw DiagnosticFailure.message("Renderer dimensions are not 20×6") }
        session.receive(bytes)
        guard session.waitForPendingOutput() else { throw DiagnosticFailure.message("Renderer did not drain output") }
    }

    func cursor() async throws -> String {
        callback = Data()
        try feed(Data("\u{1b}[6n".utf8))
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(25))
            let text = String(decoding: callback, as: UTF8.self)
            if let range = text.range(of: "\u{1b}\\[[0-9]+;[0-9]+R", options: .regularExpression) {
                return String(text[range])
            }
        }
        throw DiagnosticFailure.message("DSR cursor callback timed out")
    }

    fileprivate func output(_ bytes: Data) {
        // Input never leaves this model. Only bounded DSR evidence is retained.
        callback.append(bytes)
        if callback.count > 1024 { callback.removeFirst(callback.count - 1024) }
    }
}

@MainActor
private final class TerminalRelay {
    weak var owner: DiagnosticTerminal?
    nonisolated func output(_ bytes: Data) {
        Task { @MainActor [weak self] in self?.owner?.output(bytes) }
    }
    nonisolated func resize(_ viewport: InMemoryTerminalViewport) {
        Task { @MainActor [weak self] in self?.owner?.resized(viewport) }
    }
}

enum DiagnosticFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): value }
    }
}

struct DiagnosticTerminalView: View {
    @ObservedObject var terminal: DiagnosticTerminal
    var body: some View {
        VStack(alignment: .leading) {
            TerminalSurfaceView(context: terminal.state)
                .frame(width: terminal.size.width, height: terminal.size.height)
                .fixedSize()
                .layoutPriority(1)
                .allowsHitTesting(false)
                .accessibilityLabel("Read-only synthetic terminal")
            Text("Reported: \(terminal.viewport?.columns ?? 0)×\(terminal.viewport?.rows ?? 0)")
                .font(.caption.monospaced())
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
