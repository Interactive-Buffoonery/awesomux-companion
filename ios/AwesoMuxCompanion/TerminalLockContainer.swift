import os
import SwiftUI
import UIKit

/// Keep polling and alert tasks outside this container. Issue #10 can reuse it
/// around terminal content without moving authentication into the transport.
struct TerminalLockContainer<Content: View>: View {
    let model: TerminalLockModel
    let protectsContent: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(model)
            .disabled(protectsContent && model.isLocked)
            .allowsHitTesting(!protectsContent || !model.isLocked)
            .accessibilityHidden(protectsContent && model.isLocked)
            .overlay {
                if protectsContent && model.isLocked { TerminalLockGate(model: model) }
            }
            .background {
                ScenePrivacyBridge(model: model, protectsContent: protectsContent)
            }
    }
}

struct TerminalLockGate: View {
    let model: TerminalLockModel

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    Spacer()
                    Image(systemName: "lock.fill").font(.largeTitle).accessibilityHidden(true)
                    Text("awesoMux Locked").font(.title2.bold())
                    Text("Authenticate to view your agents and terminals.")
                        .multilineTextAlignment(.center)
                    Button("Unlock") { Task { await model.unlock() } }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Cat.crust)
                        .disabled(model.isAuthenticating || !model.isActive)
                    if model.isAuthenticating {
                        ProgressView("Authenticating…")
                    }
                    if let message = model.authenticationFailureMessage {
                        Text(message)
                            .font(.callout).multilineTextAlignment(.center)
                    }
                    Spacer()
                    TerminalProtectionToggle(model: model)
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .foregroundStyle(Cat.text)
        .background(Cat.page.ignoresSafeArea())
        .tint(Cat.accent)
    }
}

struct TerminalProtectionToggle: View {
    let model: TerminalLockModel

    var body: some View {
        Toggle("Lock App", isOn: Binding(
            get: { model.isEnabled },
            set: { enabled in Task { await model.setEnabled(enabled) } }))
            .disabled(model.isAuthenticating || !model.isActive)
            .accessibilityHint("Turning Lock App off requires device authentication.")
    }
}

struct AppPrivacyCover: View {
    var body: some View {
        Color(uiColor: .systemBackground)
            .ignoresSafeArea()
            .overlay {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("awesoMux hidden")
    }
}

private struct ScenePrivacyBridge: UIViewRepresentable {
    let model: TerminalLockModel
    let protectsContent: Bool

    func makeUIView(context: Context) -> ScenePrivacyAnchor {
        ScenePrivacyAnchor(model: model, protectsContent: protectsContent)
    }

    func updateUIView(_ view: ScenePrivacyAnchor, context: Context) {
        view.protectsContent = protectsContent
        view.updateCover()
    }

    static func dismantleUIView(_ view: ScenePrivacyAnchor, coordinator: ()) {
        view.detach()
    }
}

/// UIKit scene notifications install the cover synchronously before snapshotting.
/// A separate window covers sheets as well as the SwiftUI root. It becomes
/// key while locked so hardware keyboard input cannot reach underlying content.
final class ScenePrivacyAnchor: UIView {
    let model: TerminalLockModel
    var protectsContent: Bool
    private(set) var privacyWindow: UIWindow?
    private weak var observedScene: UIWindowScene?
    private weak var previousKeyWindow: UIWindow?
    private var blockedWindows: [BlockedWindow] = []
    private var announcedFailure: String?
    private var preferencesObserver: NSObjectProtocol?

    private struct BlockedWindow {
        weak var window: UIWindow?
        let interactionEnabled: Bool
        let accessibilityHidden: Bool
    }

    init(model: TerminalLockModel, protectsContent: Bool) {
        self.model = model
        self.protectsContent = protectsContent
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let scene = window?.windowScene else { detach(); return }
        guard observedScene !== scene else { return }
        detach()
        observedScene = scene
        model.securityDidChange = { [weak self] in self?.updateCover() }
        let center = NotificationCenter.default
        preferencesObserver = center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.synchronizePreference()
                self?.updateCover()
            }
        }
        center.addObserver(self, selector: #selector(willDeactivate), name: UIScene.willDeactivateNotification, object: scene)
        center.addObserver(self, selector: #selector(didEnterBackground), name: UIScene.didEnterBackgroundNotification, object: scene)
        center.addObserver(self, selector: #selector(willEnterForeground), name: UIScene.willEnterForegroundNotification, object: scene)
        center.addObserver(self, selector: #selector(didActivate), name: UIScene.didActivateNotification, object: scene)
        if scene.activationState == .foregroundActive { model.becomeActive() }
        updateCover()
    }

    @objc private func willDeactivate() {
        WatchDiagnostics.lifecycle.notice("scene_changed origin=lifecycle source=scene_bridge phase=inactive")
        model.becomeInactive(); updateCover()
    }
    @objc private func didEnterBackground() { model.enterBackground(); updateCover() }
    @objc private func willEnterForeground() { model.enterForeground(); updateCover() }
    @objc private func didActivate() { model.becomeActive(); updateCover() }

    func updateCover() {
        guard let scene = observedScene else { return }
        if model.isActive, let message = model.authenticationFailureMessage {
            if announcedFailure != message {
                UIAccessibility.post(notification: .announcement, argument: message)
                announcedFailure = message
            }
        } else if model.authenticationFailureMessage == nil {
            announcedFailure = nil
        }
        let needsCover = !model.isActive || (protectsContent && model.isLocked)
        guard needsCover else {
            restoreWindows()
            privacyWindow?.isHidden = true
            return
        }
        // Do this synchronously in the lifecycle callback, before presenting the
        // cover. Include presentation windows, not just the representable's root.
        for window in scene.windows where window !== privacyWindow {
            window.endEditing(true)
            if !blockedWindows.contains(where: { $0.window === window }) {
                blockedWindows.append(BlockedWindow(
                    window: window,
                    interactionEnabled: window.isUserInteractionEnabled,
                    accessibilityHidden: window.accessibilityElementsHidden))
            }
            window.isUserInteractionEnabled = false
            window.accessibilityElementsHidden = true
        }
        if privacyWindow == nil {
            let cover = UIWindow(windowScene: scene)
            cover.windowLevel = .alert + 1
            cover.backgroundColor = .systemBackground
            privacyWindow = cover
        }
        let content = PrivacyWindowContent(model: model)
        if let host = privacyWindow?.rootViewController as? UIHostingController<PrivacyWindowContent> {
            host.rootView = content
        } else {
            privacyWindow?.rootViewController = UIHostingController(rootView: content)
        }
        privacyWindow?.isUserInteractionEnabled = model.isActive
        privacyWindow?.accessibilityViewIsModal = true
        privacyWindow?.isHidden = false
        if model.isActive, privacyWindow?.isKeyWindow != true {
            previousKeyWindow = scene.windows.first(where: { $0.isKeyWindow })
            privacyWindow?.makeKey()
        }
    }

    private func restoreWindows() {
        for blocked in blockedWindows {
            blocked.window?.isUserInteractionEnabled = blocked.interactionEnabled
            blocked.window?.accessibilityElementsHidden = blocked.accessibilityHidden
        }
        blockedWindows.removeAll()
        if privacyWindow?.isKeyWindow == true { previousKeyWindow?.makeKey() }
        previousKeyWindow = nil
    }

    func detach() {
        NotificationCenter.default.removeObserver(self)
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        preferencesObserver = nil
        model.securityDidChange = nil
        restoreWindows()
        privacyWindow?.isHidden = true
        privacyWindow = nil
        observedScene = nil
    }
}

private struct PrivacyWindowContent: View {
    let model: TerminalLockModel

    var body: some View {
        if model.isActive {
            TerminalLockGate(model: model)
        } else {
            AppPrivacyCover()
        }
    }
}
