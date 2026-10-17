import SwiftUI

struct InboxView: View {
    let store: CompanionStore
    @State private var pairing = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let snapshot = store.snapshot {
                        NavigationLink {
                            ThreadView(store: store)
                        } label: {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.title2).foregroundStyle(.tint)
                                    .frame(width: 46, height: 46)
                                    .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack { Text("Codex").font(.headline); Spacer(); Text(store.activeHostLabel ?? "Host").font(.caption).foregroundStyle(.secondary) }
                                    Text(snapshot.messages.last?.text ?? "Your conversation is ready.")
                                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    if !snapshot.pending.isEmpty {
                                        Label("Needs your input", systemImage: "questionmark.circle.fill")
                                            .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                                    } else { Text("Up to date").font(.caption).foregroundStyle(.secondary) }
                                }
                            }.padding(.vertical, 6)
                        }.accessibilityIdentifier("session-row")
                    } else {
                        ContentUnavailableView("Your sessions, close by", systemImage: "bubble.left.and.bubble.right",
                            description: Text(store.message ?? "Connect a host to see your sessions."))
                            .listRowBackground(Color.clear)
                    }
                }
                if let message = store.message, store.snapshot != nil {
                    Section { Label(message, systemImage: "wifi.slash").font(.subheadline).foregroundStyle(.secondary) }
                }
                Section {
                    if let host = store.activeHostLabel { Text(host).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if case .quarantined(let priorHost) = store.connectionState {
                        Button("Retry \(priorHost ?? "saved host")") { retryConnection() }
                    } else if store.connectionState == .loadFailed {
                        Button("Retry saved connection") { retryConnection() }
                    }
                    if store.canPair { Button(store.activeHostLabel == nil ? "Connect a host" : "Change host") { pairing = true } }
                    if store.activeHostLabel != nil || store.connectionState == .loadFailed {
                        Button("Disconnect host", role: .destructive) { try? store.disconnectHost() }
                    }
                }
            }
            .navigationTitle("awesoMux")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { connectionLabel } }
            .refreshable { await store.refresh() }
            .sheet(isPresented: $pairing) { PairHostView(store: store) }
        }.tint(Color.accentColor)
    }
    private func retryConnection() {
        do { try store.retryConnection(); Task { await store.refresh() } } catch { /* Store retains actionable status. */ }
    }
    private var connectionLabel: some View {
        Label(store.isFresh ? "Connected" : "Offline", systemImage: store.isFresh ? "circle.fill" : "circle")
            .font(.caption).foregroundStyle(store.isFresh ? Color.secondary : Color.orange)
            .accessibilityLabel(store.isFresh ? "Host connected" : "Host not connected")
    }
}
