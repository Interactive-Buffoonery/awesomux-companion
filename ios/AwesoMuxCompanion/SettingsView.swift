import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @Bindable var store: CompanionStore
    @Environment(TerminalLockModel.self) private var terminalLock
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
                        MacStatusLine(store: store)
                    }
                    .accessibilityElement(children: .combine)
                    Button("Pair Again") { store.showingPairing = true; dismiss() }
                    Button("Unpair This iPhone", role: .destructive) { confirmingUnpair = true }
                        .foregroundStyle(Cat.red)
                    if store.isUnpairing {
                        ProgressView("Unpairing…")
                    } else if let message = store.message {
                        Text(message).font(.footnote).foregroundStyle(Cat.subtext0)
                    }
                    if let message = store.unpairMessage {
                        Text(message).font(.footnote).foregroundStyle(Cat.subtext0)
                    }
                } header: { Text("Your Mac").foregroundStyle(Cat.subtext0) }
                .disabled(store.isUnpairing)
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
            if store.record != nil { TerminalPreviewSection(store: store) }
            Section {
                TerminalProtectionToggle(model: terminalLock).foregroundStyle(Cat.text)
                if let message = terminalLock.authenticationFailureMessage {
                    Text(message).font(.callout).foregroundStyle(Cat.subtext0)
                }
            } header: { Text("Privacy").foregroundStyle(Cat.subtext0) }
                footer: { Text("Lock App is optional. When enabled, use Face ID, Touch ID, or your device passcode to view agents and terminals.").foregroundStyle(Cat.subtext0) }
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
            Button("Unpair", role: .destructive) { Task { await store.unpair() } }
        } message: {
            Text("Unpair this iPhone from your Mac. If your Mac can’t be reached, you can finish there later.")
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

/// "● Tailscale · checked in 1 min ago", shared by the Agents header and Settings. Names the route in use.
struct MacStatusLine: View {
    let store: CompanionStore

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(store.isConnected ? Cat.output : Cat.needs).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Group {
                if let updatedAt = store.snapshot?.updatedAt {
                    if store.isConnected, let route = store.activeRoute {
                        Text("\(route.transport.title) · checked in \(updatedAt, format: .relative(presentation: .named))")
                    } else {
                        Text("Offline, last checked in \(updatedAt, format: .relative(presentation: .named))")
                    }
                } else {
                    Text(store.message == nil ? String(localized: "Connecting…") : String(localized: "Offline"))
                }
            }
            .font(.footnote).foregroundStyle(Cat.subtext0)
        }
    }
}
