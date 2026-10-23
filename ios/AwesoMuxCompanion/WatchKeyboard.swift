import SwiftUI
import UIKit

struct WatchKeyboard: UIViewRepresentable {
    let input: WatchInput
    let terminal: WatchTerminal
    @Binding var isShown: Bool

    func makeUIView(context: Context) -> WatchKeyboardResponder {
        let view = WatchKeyboardResponder()
        view.input = input
        view.readModes = { [weak terminal] in await terminal?.inputModes() }
        view.onHide = { isShown = false }
        return view
    }

    func updateUIView(_ view: WatchKeyboardResponder, context: Context) {
        view.onHide = { isShown = false }
        if isShown, input.canType {
            if !view.isFirstResponder { view.becomeFirstResponder() }
        } else {
            view.stopInput()
        }
    }

    static func dismantleUIView(_ view: WatchKeyboardResponder, coordinator: ()) { view.stopInput() }
}

@MainActor
final class WatchKeyboardResponder: UIView, UIKeyInput {
    weak var input: WatchInput?
    var readModes: @MainActor () async -> WatchInputModes? = { nil }
    var onHide: () -> Void = {}
    private(set) var modifiers = WatchKeyModifiers()
    private var actions: [Action] = []
    private var worker: Task<Void, Never>?
    private var epoch = UUID()
    private var workerSessionID: UUID?
    private var lastControlTap = -Double.infinity
    private var lastAltTap = -Double.infinity
    private weak var controlButton: UIButton?
    private weak var altButton: UIButton?
    private lazy var bar = makeBar()
    private enum Action {
        case key(String, control: Bool, alt: Bool)
        case bytes(Data)
        case arrow(Character, control: Bool, alt: Bool)
        case paste(String)
    }

    override var canBecomeFirstResponder: Bool { input?.canType == true }
    override var inputAccessoryView: UIView? { bar }
    var hasText: Bool { true }
    var autocorrectionType = UITextAutocorrectionType.no
    var autocapitalizationType = UITextAutocapitalizationType.none
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    var keyboardType = UIKeyboardType.asciiCapable

    func insertText(_ text: String) {
        if text == "\r\n" || text.count > 1 { append(.paste(text)) }
        else { append(.key(text == "\n" ? "\r" : text, control: false, alt: false)) }
    }

    func arrow(_ final: Character, control: Bool = false, alt: Bool = false) {
        append(.arrow(final, control: control, alt: alt))
    }

    func deleteBackward() { append(.key("\u{7f}", control: false, alt: false)) }

    override func paste(_ sender: Any?) {
        guard input?.canType == true, let text = UIPasteboard.general.string else { return }
        append(.paste(text))
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        action == #selector(paste(_:)) && input?.canType == true && input?.pasteInFlight == false
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "v", modifierFlags: .command, action: #selector(paste(_:)))]
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            let control = key.modifierFlags.contains(.control)
            let alt = key.modifierFlags.contains(.alternate)
            let special: String?
            switch key.keyCode {
            case .keyboardEscape: special = "\u{1b}"
            case .keyboardTab: special = key.modifierFlags.contains(.shift) ? "\u{1b}[Z" : "\t"
            case .keyboardReturnOrEnter, .keypadEnter: special = "\r"
            case .keyboardDeleteOrBackspace: special = "\u{7f}"
            case .keyboardDeleteForward: special = "\u{1b}[3~"
            case .keyboardHome: special = "\u{1b}[H"
            case .keyboardEnd: special = "\u{1b}[F"
            case .keyboardPageUp: special = "\u{1b}[5~"
            case .keyboardPageDown: special = "\u{1b}[6~"
            case .keyboardUpArrow: arrow("A", control: control, alt: alt); continue
            case .keyboardDownArrow: arrow("B", control: control, alt: alt); continue
            case .keyboardRightArrow: arrow("C", control: control, alt: alt); continue
            case .keyboardLeftArrow: arrow("D", control: control, alt: alt); continue
            default: special = nil
            }
            if let special { append(.key(special, control: control, alt: alt)) }
            else if (control || alt), !key.modifierFlags.contains(.command), !key.charactersIgnoringModifiers.isEmpty {
                append(.key(key.charactersIgnoringModifiers, control: control, alt: alt))
            } else { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    func stopInput() {
        resignFirstResponder()
        epoch = UUID()
        worker?.cancel()
        worker = nil
        actions.removeAll()
        modifiers = WatchKeyModifiers()
        updateButtons()
    }

    private func append(_ action: Action) {
        guard input?.canType == true else { return }
        if worker != nil, workerSessionID != input?.sessionID {
            epoch = UUID()
            worker?.cancel()
            worker = nil
            actions.removeAll()
        }
        guard actions.count < 64 else {
            if case .paste = action { input?.refuseQueuedInput(paste: true) }
            else { input?.refuseQueuedInput(paste: false) }
            return
        }
        switch action {
        case .key(let text, let control, let alt):
            actions.append(.bytes(modifiers.encode(text, control: control, alt: alt)))
        case .arrow(let final, let control, let alt):
            let useControl = control || modifiers.control != .off
            let useAlt = alt || modifiers.alt != .off
            if modifiers.control == .once { modifiers.control = .off }
            if modifiers.alt == .once { modifiers.alt = .off }
            actions.append(.arrow(final, control: useControl, alt: useAlt))
        default: actions.append(action)
        }
        updateButtons()
        guard worker == nil, let generation = input?.generation else { return }
        let identity = epoch
        let sessionID = input?.sessionID
        workerSessionID = sessionID
        worker = Task { [weak self] in
            guard let self else { return }
            var modesUnavailable = false
            while self.epoch == identity, !self.actions.isEmpty, !Task.isCancelled {
                let action = self.actions.removeFirst()
                guard let input = self.input, input.sessionID == sessionID, input.generation == generation, input.canType else {
                    self.actions.removeAll()
                    self.worker = nil
                    return
                }
                switch action {
                case .bytes(let bytes): input.type(bytes)
                case .arrow(let final, let control, let alt):
                    if control || alt {
                        input.type(Data("\u{1b}[1;\(1 + (control ? 4 : 0) + (alt ? 2 : 0))\(final)".utf8))
                    } else {
                        guard !modesUnavailable else { input.refuseModeRead(paste: false); continue }
                        guard let modes = await self.readModes(), !Task.isCancelled,
                              input.sessionID == sessionID, input.canType else {
                            if !Task.isCancelled, input.sessionID == sessionID {
                                modesUnavailable = true
                                input.refuseModeRead(paste: false)
                            }
                            continue
                        }
                        input.type(Data(WatchKeyModifiers.arrow(final, application: modes.applicationCursor).utf8))
                    }
                case .paste(let text):
                    guard !modesUnavailable else { input.refuseModeRead(paste: true); continue }
                    guard let modes = await self.readModes(), !Task.isCancelled,
                          input.sessionID == sessionID, input.canType else {
                        if !Task.isCancelled, input.sessionID == sessionID {
                            modesUnavailable = true
                            input.refuseModeRead(paste: true)
                        }
                        continue
                    }
                    input.paste(text, modes: modes)
                case .key: break
                }
                self.updateButtons()
            }
            if self.epoch == identity { self.worker = nil }
        }
    }

    private func makeBar() -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 4, leading: 4, bottom: 4, trailing: 4)
        stack.backgroundColor = .secondarySystemBackground
        stack.frame = CGRect(x: 0, y: 0, width: 390, height: 44)
        stack.autoresizingMask = [.flexibleWidth]
        func button(_ title: String, label: String? = nil, _ action: @escaping () -> Void) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            button.accessibilityLabel = label ?? title
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            stack.addArrangedSubview(button)
            return button
        }
        _ = button("Esc", label: "Escape") { [weak self] in self?.append(.key("\u{1b}", control: false, alt: false)) }
        _ = button("Tab") { [weak self] in self?.append(.key("\t", control: false, alt: false)) }
        controlButton = button("Ctrl", label: "Control, tap once for next key, double tap to lock") { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.modifiers.control = WatchKeyModifiers.tapped(self.modifiers.control, doubleTap: now - self.lastControlTap < 0.35)
            self.lastControlTap = now
            self.updateButtons()
        }
        altButton = button("Alt", label: "Option, tap once for next key, double tap to lock") { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.modifiers.alt = WatchKeyModifiers.tapped(self.modifiers.alt, doubleTap: now - self.lastAltTap < 0.35)
            self.lastAltTap = now
            self.updateButtons()
        }
        for (title, final, label) in [("←", Character("D"), "Left arrow"), ("↑", Character("A"), "Up arrow"),
                                      ("↓", Character("B"), "Down arrow"), ("→", Character("C"), "Right arrow")] {
            _ = button(title, label: label) { [weak self] in self?.append(.arrow(final, control: false, alt: false)) }
        }
        let hide = button("", label: "Hide keyboard") { [weak self] in self?.stopInput(); self?.onHide() }
        hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        configureModifierActions(controlButton, control: true)
        configureModifierActions(altButton, control: false)
        return stack
    }

    private func configureModifierActions(_ button: UIButton?, control: Bool) {
        let name = control ? "Control" : "Option"
        let set: (WatchKeyModifiers.State) -> Void = { [weak self] state in
            guard let self else { return }
            if control { self.modifiers.control = state } else { self.modifiers.alt = state }
            self.updateButtons()
        }
        button?.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Lock \(name)") { _ in set(.locked); return true },
            UIAccessibilityCustomAction(name: "Unlock \(name)") { _ in set(.off); return true }
        ]
        button?.menu = UIMenu(children: [
            UIAction(title: "Lock \(name)") { _ in set(.locked) },
            UIAction(title: "Unlock \(name)") { _ in set(.off) }
        ])
    }

    private func updateButtons() {
        for (button, state) in [(controlButton, modifiers.control), (altButton, modifiers.alt)] {
            button?.isSelected = state != .off
            button?.backgroundColor = state == .off ? .clear : .tertiarySystemFill
            button?.accessibilityValue = state == .locked ? "Locked" : (state == .once ? "Next key" : "Off")
            button?.layer.cornerRadius = 6
        }
    }
}
