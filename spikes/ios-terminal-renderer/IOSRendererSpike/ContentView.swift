import GhosttyTerminal
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var model = RendererSpikeModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    status

                    TerminalSurfaceView(context: model.terminal)
                        .frame(minHeight: 300)
                        .background(Color.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("libghostty Metal terminal test surface")
                        .accessibilityHint("Use direct touch to select text. Tap once to show or hide the keyboard.")

                    controls
                    output
                    manualChecks
                }
                .padding()
            }
            .navigationTitle("iOS Renderer Spike")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Hide keyboard") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
        .task {
            model.start()
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(model.selfCheckSummary, systemImage: model.selfCheckPassed ? "checkmark.circle.fill" : "clock")
                .foregroundStyle(model.selfCheckPassed ? .green : .secondary)
                .accessibilityIdentifier("renderer-self-check")
            Text(model.viewportSummary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("The automatic check proves parser round-trip only. Record rendering, selection, keyboard/IME, and VoiceOver on a physical device below.")
                .font(.caption)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Exercises")
                .font(.headline)
            HStack {
                Button("Feed fixture") { model.feedFixture() }
                    .buttonStyle(.borderedProminent)
                Button("Query cursor") { model.queryCursor() }
                    .buttonStyle(.bordered)
            }
            HStack {
                Button("Show keyboard") { model.showKeyboard() }
                    .buttonStyle(.bordered)
                Button("Read viewport") { model.captureViewport() }
                    .buttonStyle(.bordered)
            }
            Text("The fixture contains ANSI color, bold text, box drawing, emoji, Japanese, Arabic, and combining marks. Type with the native keyboard or an IME; emitted bytes appear below.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Terminal output callback")
                .font(.headline)
            Text(model.callbackHex.isEmpty ? "No bytes received" : model.callbackHex)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("output-callback-hex")
        }
    }

    private var manualChecks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Physical-device observations")
                .font(.headline)
            ForEach(ManualCheck.allCases) { check in
                VStack(alignment: .leading, spacing: 6) {
                    Text(check.title)
                    Text(check.instructions)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(check.title, selection: model.binding(for: check)) {
                        ForEach(Observation.allCases) { observation in
                            Text(observation.title).tag(observation)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            Text("Evidence: \(model.evidencePath)")
                .font(.caption2.monospaced())
                .textSelection(.enabled)
        }
    }
}
