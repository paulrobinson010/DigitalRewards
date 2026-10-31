import SwiftUI

/// The cyberpunk look from the app icon (`Branding/app-icon.svg`): neon on near-black purple.
/// Credit is green, debit magenta, warnings yellow.
enum Theme {
    static let bgTop = Color(hex: 0x1A0B3B)
    static let bgBottom = Color(hex: 0x07030F)
    static let cyan = Color(hex: 0x00F0FF)
    static let magenta = Color(hex: 0xFF2BD6)
    static let yellow = Color(hex: 0xF5FF3D)
    static let green = Color(hex: 0x39FF14)
    /// Card fill: dark translucent purple.
    static let card = Color(hex: 0x24124D, opacity: 0.72)

    static let credit = green
    static let debit = magenta
    static let warning = yellow

    static func balanceColor(_ minutes: Int) -> Color { minutes < 0 ? debit : credit }

    /// Heavy monospaced numbers, like an arcade scoreboard.
    static func arcade(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .monospaced)
    }

    /// Heavy rounded text for labels like "PLAYER 1".
    static func label(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .rounded)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

// MARK: - Modifiers

/// Neon glow: a tight bright shadow plus a wide soft one.
struct NeonGlow: ViewModifier {
    var color: Color
    var radius: CGFloat

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.9), radius: radius / 3)
            .shadow(color: color.opacity(0.55), radius: radius)
    }
}

/// Dark translucent card with a thin neon border.
struct NeonCard: ViewModifier {
    var border: Color
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(border.opacity(0.55), lineWidth: 1))
    }
}

extension View {
    func neonGlow(_ color: Color, radius: CGFloat = 8) -> some View {
        modifier(NeonGlow(color: color, radius: radius))
    }

    func neonCard(border: Color = Theme.cyan, padding: CGFloat = 16) -> some View {
        modifier(NeonCard(border: border, padding: padding))
    }

    #if os(iOS)
    /// Lists and Forms: drop the default grey background and show the theme gradient.
    func themedList() -> some View {
        scrollContentBackground(.hidden)
            .background(ThemeBackground())
    }
    #endif
}

/// The app's dark purple gradient, edge to edge.
struct ThemeBackground: View {
    var body: some View {
        LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

/// Big filled neon capsule button.
struct NeonButtonStyle: ButtonStyle {
    var color: Color = Theme.cyan

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(17))
            .foregroundStyle(Theme.bgBottom)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(color))
            .neonGlow(color, radius: configuration.isPressed ? 4 : 10)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
