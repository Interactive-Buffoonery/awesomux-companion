import SwiftUI
import UIKit

/// Catppuccin, matching awesoMux's `AwColors` on the Mac: Mocha in dark mode, Latte in light,
/// and the Mac's high-contrast ramps under Increase Contrast. Hex values are copied from
/// `Sources/DesignSystem/Tokens/AwColor.swift`; keep them in step.
enum Cat {
    static let base = dynamic(mocha: "#1e1e2e", latte: "#eff1f5")
    static let crust = dynamic(mocha: "#11111b", latte: "#dce0e8")

    // Roles: Latte has nothing lighter than base, so light mode lifts cards by sinking the page.
    static let page = dynamic(mocha: "#1e1e2e", latte: "#dce0e8")
    static let card = dynamic(mocha: "#313244", latte: "#eff1f5")
    static let tile = dynamic(mocha: "#1e1e2e", latte: "#ccd0da")
    static let text = dynamic(mocha: "#cdd6f4", latte: "#4c4f69", mochaHC: "#ffffff", latteHC: "#0a0a14")
    static let subtext0 = dynamic(mocha: "#a6adc8", latte: "#6c6f85", mochaHC: "#e8edff", latteHC: "#1e1e2e")

    static let peach = dynamic(mocha: "#fab387", latte: "#fe640b", mochaHC: "#ffc8a3", latteHC: "#9b3d07")
    static let lavender = dynamic(mocha: "#b4befe", latte: "#7287fd", mochaHC: "#d0d8ff", latteHC: "#354fb5")
    static let sky = dynamic(mocha: "#89dceb", latte: "#04a5e5", mochaHC: "#aeefff", latteHC: "#0058a8")
    static let mauve = dynamic(mocha: "#cba6f7", latte: "#8839ef", mochaHC: "#dcc2ff", latteHC: "#6f20d1")
    static let green = dynamic(mocha: "#a6e3a1", latte: "#40a02b", mochaHC: "#c2f5bd", latteHC: "#29661c")
    static let yellow = dynamic(mocha: "#f9e2af", latte: "#df8e1d", mochaHC: "#fff0c2", latteHC: "#835100")
    static let teal = dynamic(mocha: "#94e2d5", latte: "#179299", mochaHC: "#b0f4ea", latteHC: "#00685c")
    static let red = dynamic(mocha: "#f38ba8", latte: "#d20f39", mochaHC: "#ffb3c4", latteHC: "#b00030")

    // The Mac's status tokens: Latte values are darkened from stock to clear 3:1 on chrome.
    /// Peach accent for buttons and links; stock Latte peach is under 3:1 on base, so light uses the darkened value.
    static let accent = dynamic(mocha: "#fab387", latte: "#ad4001", mochaHC: "#ffc8a3", latteHC: "#9b3d07")
    static let needs = dynamic(mocha: "#fab387", latte: "#ad4001", mochaHC: "#ffc8a3", latteHC: "#9b3d07")
    static let running = dynamic(mocha: "#74c7ec", latte: "#0a6d86", mochaHC: "#9ee4ff", latteHC: "#00627d")
    static let done = dynamic(mocha: "#94e2d5", latte: "#116e74", mochaHC: "#b0f4ea", latteHC: "#00685c")
    static let output = dynamic(mocha: "#a6e3a1", latte: "#2d711f", mochaHC: "#c2f5bd", latteHC: "#29661c")

    static func uiColor(mocha: String, latte: String, mochaHC: String? = nil, latteHC: String? = nil) -> UIColor {
        UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            let high = traits.accessibilityContrast == .high
            return UIColor(hex: dark ? (high ? mochaHC ?? mocha : mocha) : (high ? latteHC ?? latte : latte))
        }
    }

    private static func dynamic(mocha: String, latte: String, mochaHC: String? = nil, latteHC: String? = nil) -> Color {
        Color(uiColor: uiColor(mocha: mocha, latte: latte, mochaHC: mochaHC, latteHC: latteHC))
    }
}

private extension UIColor {
    convenience init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
