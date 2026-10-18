import SwiftUI

struct SnapshotDiagnosticsView: View {
    @StateObject private var model = SnapshotDiagnosticsModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Experimental renderer uses private CAIOSurfaceLayer. Synthetic fixture only; no Chat or shell input.")
                        .font(.caption)
                    Text(model.phase.rawValue).font(.headline)
                    Text(model.status).accessibilityIdentifier("diagnostics-status")
                    Button("Run local replay") { model.replay() }.buttonStyle(.borderedProminent)
                    ForEach(model.terminals) { terminal in
                        DiagnosticTerminalView(terminal: terminal).id(terminal.id)
                    }
                    Text("Live / reference viewport").font(.headline)
                    Text(model.liveViewportText.isEmpty ? "Not captured" : model.liveViewportText)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityLabel("Live reference viewport: " + model.liveViewportText)
                    Text("Restored viewport").font(.headline)
                    Text(model.restoredViewportText.isEmpty ? "Not captured" : model.restoredViewportText)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityLabel("Restored viewport: " + model.restoredViewportText)
                    Group {
                        Text("Synthetic HTTPS fixture").font(.headline)
                        TextField("https://host:8769", text: $model.url)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Per-launch bearer token", text: $model.token)
                        TextField("Leaf certificate SHA256", text: $model.pin)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        HStack {
                            Button("Connect / reconnect") { model.connect() }.disabled(!model.canConnect)
                            Button("Disconnect") { model.disconnect() }
                        }.buttonStyle(.bordered)
                    }
                    Text("Reconnect marks are tester attestations, never automatic. Manual observations are separate from parser assertions. Mark reconnect passed only after observing a physical network interruption and fresh snapshot recovery.")
                        .font(.caption)
                    Picker("Rendering", selection: Binding(get: { model.manualRendering }, set: { model.markManual("rendering", value: $0) })) {
                        ForEach(["unverified", "passed", "failed"], id: \.self) { Text($0) }
                    }
                    Picker("Physical reconnect", selection: Binding(get: { model.manualReconnect }, set: { model.markManual("physicalNetworkReconnect", value: $0) })) {
                        ForEach(["unverified", "passed", "failed"], id: \.self) { Text($0) }
                    }
                    if let url = model.evidenceURL { ShareLink("Export JSON evidence", item: url) }
                }.padding()
            }
            .navigationTitle("Watch diagnostics")
            .onOpenURL { model.configure($0) }
            .onChange(of: model.url) { model.configurationChanged() }
            .onChange(of: model.token) { model.configurationChanged() }
            .onChange(of: model.pin) { model.configurationChanged() }
            .onChange(of: model.manualRendering) { model.persist() }
            .onChange(of: model.manualReconnect) { model.persist() }
        }
    }
}
