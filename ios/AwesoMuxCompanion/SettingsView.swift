import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Bindable var store: CompanionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var notifications: UNAuthorizationStatus?
    @State private var confirmingUnpair = false

    var body: some View {
        List {
            if let record = store.record {
                Section {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.macName).font(.body.weight(.semibold)).foregroundStyle(Cat.text)
                        MacStatusLine(store: store, transport: record.transport)
                    }
                    .accessibilityElement(children: .combine)
                    Button("Pair Again") { store.showingPairing = true; dismiss() }
                    Button("Unpair This iPhone", role: .destructive) { confirmingUnpair = true }
                        .foregroundStyle(Cat.red)
                } header: { Text("Your Mac").foregroundStyle(Cat.subtext0) }
                .listRowBackground(Cat.card)
            }
            Section {
                Button(action: openNotificationSettings) {
                    LabeledContent("Notifications") {
                        HStack(spacing: 4) {
                            Text(notificationLabel)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                        }
                        .foregroundStyle(Cat.subtext0)
                    }
                    .foregroundStyle(Cat.text)
                }
                Toggle("Live Activity", isOn: $store.liveActivityEnabled).foregroundStyle(Cat.text)
            } header: { Text("Alerts").foregroundStyle(Cat.subtext0) }
            .listRowBackground(Cat.card)
            Section {
                LabeledContent("Version", value: Self.version).foregroundStyle(Cat.text)
                Button("Send Feedback", action: sendFeedback)
            } header: { Text("About").foregroundStyle(Cat.subtext0) }
            .listRowBackground(Cat.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Cat.page)
        .navigationTitle("Settings")
        .task(id: scenePhase) {
            notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
        .confirmationDialog("Unpair this iPhone?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { store.unpair() }
        } message: {
            Text("This iPhone forgets \(store.record?.macName ?? String(localized: "your Mac")) and its pairing key. To remove it from your Mac too, choose Unpair in awesoMux Settings.")
        }
    }

    private var notificationLabel: String {
        switch notifications {
        case .authorized, .provisional, .ephemeral: String(localized: "On")
        case .notDetermined: String(localized: "Not set")
        default: String(localized: "Off")
        }
    }

    private func openNotificationSettings() {
        if notifications == .notDetermined {
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            }
        } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            openURL(url)
        }
    }

    private func sendFeedback() {
        // TestFlight builds take feedback in the TestFlight app; elsewhere fall back to the public issue tracker.
        openURL(URL(string: "itms-beta://")!) { opened in
            if !opened { openURL(URL(string: "https://github.com/Interactive-Buffoonery/awesomux-companion/issues")!) }
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// "● Tailscale · checked in 1 min ago", shared by the Agents header and Settings.
struct MacStatusLine: View {
    let store: CompanionStore
    let transport: CompanionTransport

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(store.isConnected ? Cat.output : Cat.needs).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Group {
                if let updatedAt = store.snapshot?.updatedAt {
                    if store.isConnected {
                        Text("\(transport.title) · checked in \(updatedAt, format: .relative(presentation: .named))")
                    } else {
                        Text("\(transport.title) · offline, last checked in \(updatedAt, format: .relative(presentation: .named))")
                    }
                } else {
                    Text("\(transport.title) · \(store.message == nil ? String(localized: "connecting…") : String(localized: "offline"))")
                }
            }
            .font(.footnote).foregroundStyle(Cat.subtext0)
        }
    }
}
