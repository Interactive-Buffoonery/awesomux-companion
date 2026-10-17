import SwiftUI

extension GlanceGroup {
    var tint: Color {
        switch self {
        case .needsYou: .orange
        case .working: .green
        case .done: .gray
        }
    }
}

struct ProviderAvatar: View {
    let provider: String
    var size: CGFloat = 36

    var body: some View {
        Text(Self.letter(for: provider))
            .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.tint(for: provider).gradient, in: Circle())
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
        case "Claude Code": .orange
        case "Codex": .teal
        case "OpenCode": .blue
        case "Pi": .purple
        case "Grok": .pink
        default: .gray
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
