import AppKit
import SwiftUI

/// The dashboard's look: a near-black navy background, one blue hue for
/// every chart, and SF Mono throughout. The dashboard window is always dark,
/// whatever the system appearance.
enum Theme {
    static let background = Color(hex: 0x07090E)
    static let sidebar = Color(hex: 0x0B0E15)
    /// Chart surface. The blue ramp was checked against this color.
    static let card = Color(hex: 0x121824)
    static let cardHover = Color(hex: 0x182131)
    static let border = Color(hex: 0x1E2737)
    static let track = Color(hex: 0x1C2433)
    static let textSecondary = Color(hex: 0x8B98AE)

    /// Eight blue steps, light to dark, evenly spaced in OKLCH lightness so
    /// neighbors stay distinguishable. Even the darkest clears 2:1 on `card`.
    static let blues: [Color] = [
        0xB7E4FF, 0x94CDFF, 0x74B6FF, 0x599FFF, 0x4488E7, 0x3473C9, 0x2B60A7, 0x264D83,
    ].map { Color(hex: $0) }

    static let accent = blues[4]

    /// One radius for every panel, badge and chart bar, for a sharper look.
    static let cornerRadius: CGFloat = 4

    /// Ranked items get lighter shades the larger they are.
    static func shade(rank: Int) -> Color {
        blues[min(max(rank, 0), blues.count - 1)]
    }

    static let barGradient = LinearGradient(colors: [blues[2], blues[6]], startPoint: .top, endPoint: .bottom)
    static let meterGradient = LinearGradient(colors: [blues[6], blues[3]], startPoint: .leading, endPoint: .trailing)

    static let nsBackground = NSColor(hex: 0x07090E)
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

/// Small uppercase label with wide tracking, used for section and card titles.
struct SectionLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .textCase(.uppercase)
            .tracking(1.2)
            .foregroundStyle(Theme.textSecondary)
    }
}

extension View {
    func sectionLabel() -> some View { modifier(SectionLabel()) }

    func themedCard(cornerRadius: CGFloat = Theme.cornerRadius, fill: Color = Theme.card) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Title in the top-left corner inside the box, like the stat cards, so
/// every panel has the same gap to the next one.
struct ThemedGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .sectionLabel()
            configuration.content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedCard()
    }
}
