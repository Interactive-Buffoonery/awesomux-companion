import SwiftUI

struct PairHostView: View {
    let store: CompanionStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var key = ""
    @State private var errorMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://host.tailnet.ts.net:8443", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).accessibilityIdentifier("host-address")
                    SecureField("Connection key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("connection-key")
                } header: { Text("Your Mac") } footer: {
                    Text("This key lets you read and answer questions in the managed Codex session on this host. Enter the private HTTPS address and key shown on your Mac.")
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
                Section {
                    Button("Connect") {
                        do {
                            try store.pair(ConnectionConfiguration(endpoint: address, token: key))
                            key = ""; dismiss()
                            Task { await store.refresh() }
                        } catch BridgeFailure.invalidConfiguration {
                            errorMessage = "Use the exact private HTTPS address with port 8443 or 10000, and its connection key."
                        } catch { errorMessage = "Could not save this connection. Return to the inbox to retry the previous host." }
                    }.disabled(address.isEmpty || key.isEmpty || !store.canPair)
                }
            }.navigationTitle("Connect a host")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { key = ""; dismiss() } } }
                .onDisappear { key = "" }
        }
    }
}
