import SwiftUI
import UIKit
import UserNotifications

/// One Mac's settings: its pairing, terminal previews and permission requests. App-wide settings are in
/// `AppSettingsView`, from the host list.
struct SettingsView: View {
    let store: CompanionStore
    /// Permission requests are read from the open Mac only, so other Macs' settings don't link them.
    var showsDecisions = true
    @Environment(\.dismiss) private var dismiss
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
                } header: { Text("This Mac").foregroundStyle(Cat.subtext0) }
                    footer: { Text("Pair Again renews this Mac's pairing. To add another Mac, use + pair a mac in Hosts.").foregroundStyle(Cat.subtext0) }
                .disabled(store.isUnpairing)
                .listRowBackground(Cat.card)
                TerminalPreviewSection(store: store)
                if showsDecisions {
                    Section {
                        NavigationLink("Permission requests") { DecisionsView(store: store) }.foregroundStyle(Cat.text)
                    } footer: {
                        Text("Answer Claude's once-only permission requests from this iPhone.").foregroundStyle(Cat.subtext0)
                    }
                    .listRowBackground(Cat.card)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Cat.page)
        .navigationTitle(store.record?.macName ?? String(localized: "Settings"))
        .onChange(of: store.record == nil) { _, unpaired in if unpaired { dismiss() } }
        .confirmationDialog("Unpair this iPhone?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { Task { await store.unpair() } }
        } message: {
            Text("Unpair this iPhone from \(store.record?.macName ?? "your Mac"). Your other Macs stay paired. If this Mac can’t be reached, you can finish there later.")
        }
    }
}

/// Settings for the whole app, whichever Mac is open.
struct AppSettingsView: View {
    @Bindable var hosts: Hosts
    @Environment(TerminalLockModel.self) private var terminalLock
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var notifications: UNAuthorizationStatus?

    var body: some View {
        List {
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
                Toggle("Live Activity", isOn: $hosts.liveActivityEnabled).foregroundStyle(Cat.text)
            } header: { Text("Alerts").foregroundStyle(Cat.subtext0) }
                footer: { Text("Alerts come from every paired Mac. The widget and Live Activity show the Mac you opened last.").foregroundStyle(Cat.subtext0) }
            .listRowBackground(Cat.card)
            Section {
                TerminalProtectionToggle(model: terminalLock).foregroundStyle(Cat.text)
                if let message = terminalLock.authenticationFailureMessage {
                    Text(message).font(.callout).foregroundStyle(Cat.subtext0)
                }
            } header: { Text("Privacy").foregroundStyle(Cat.subtext0) }
                footer: { Text("Use Face ID, Touch ID, or your device passcode to unlock the app.").foregroundStyle(Cat.subtext0) }
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

/// "● Tailscale · checked in 1 min ago", shown in Settings. Names the route in use.
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
