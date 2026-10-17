import SwiftUI

struct ThreadView: View {
    let store: CompanionStore
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if let message = store.message {
                    Label(message, systemImage: "wifi.slash")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                if store.earlierOutcomeUnknown {
                    Label("An earlier answer's outcome is unknown. Check the thread before answering again.", systemImage: "exclamationmark.circle")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(store.snapshot?.messages ?? []) { message in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(message.role == "user" ? "You" : "Codex")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(message.text).font(.body).textSelection(.enabled)
                        if message.truncated { Text("Message shortened").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(message.role == "user" ? Color.accentColor.opacity(0.07) : Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                ForEach(store.snapshot?.pending ?? []) { control in
                    QuestionCard(control: control, store: store, context: store.answerContext)
                        .id(String(store.answerContext.revision) + ":" + (store.snapshot?.generation ?? "") + ":" + control.id)
                }
                if store.snapshot?.unsupportedRequest == true {
                    Label("This session needs an action on your Mac.", systemImage: "desktopcomputer")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if store.snapshot?.messages.isEmpty == true && store.snapshot?.pending.isEmpty == true {
                    Text("The conversation will appear here.").foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Codex").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Text(store.activeHostLabel ?? "Unavailable host").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("connected-host") } }
        .accessibilityIdentifier("thread-view")
    }
}
