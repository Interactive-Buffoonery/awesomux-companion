import SwiftUI

extension GlanceGroup {
    var tint: Color {
        switch self {
        case .needsYou: Cat.needs
        case .working: Cat.running
        case .done: Cat.done
        }
    }
}

struct ProviderAvatar: View {
    let provider: String
    var size: CGFloat = 36

    var body: some View {
        Text(Self.letter(for: provider))
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(Self.tint(for: provider))
            .frame(width: size, height: size)
            // Same family rule as the Mac's AgentTile: one tile color, identity in the hue.
            .background(Cat.tile, in: RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }

    static func letter(for provider: String) -> String {
        switch provider {
        case "Codex": "X"
        default: provider.first.map { String($0).uppercased() } ?? "?"
        }
    }

    static func tint(for provider: String) -> Color {
        switch provider {
        case "Claude Code": Cat.peach
        case "Codex": Cat.lavender
        case "OpenCode": Cat.sky
        case "Pi": Cat.mauve
        case "Grok": Cat.green
        case "Hermes": Cat.yellow
        case "Shell": Cat.text
        default: Cat.teal
        }
    }
}

/// Proportional needsYou / working / done bar from the Glance mockup.
struct GroupBar: View {
    let needsYou: Int
    let working: Int
    let done: Int

    var body: some View {
        GeometryReader { proxy in
            let total = max(needsYou + working + done, 1)
            let segments = [(needsYou, GlanceGroup.needsYou), (working, .working), (done, .done)].filter { $0.0 > 0 }
            let gaps = CGFloat(max(segments.count - 1, 0)) * 3
            HStack(spacing: 3) {
                ForEach(segments, id: \.1) { count, group in
                    Capsule().fill(group.tint)
                        .frame(width: (proxy.size.width - gaps) * CGFloat(count) / CGFloat(total))
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Compact age ("4 min") that SwiftUI keeps current, including inside widgets.
struct AgeText: View {
    let date: Date

    var body: some View { Self.text(since: date) }

    static func text(since date: Date) -> Text {
        Text(.currentDate, format: .offset(to: date, allowedFields: [.minute, .hour, .day], maxFieldCount: 1, sign: .never))
    }
}
