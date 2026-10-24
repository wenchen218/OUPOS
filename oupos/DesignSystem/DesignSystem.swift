import SwiftUI

enum POSColor {
    static let background = Color(hex: 0xF2F2F4)
    static let surface = Color.white
    static let surfaceSecondary = Color(hex: 0xF7F7F7)
    static let topBar = Color(hex: 0x444444)
    static let primary = Color(hex: 0x8EAFCA)
    static let primaryStrong = Color(hex: 0x7E9FBC)
    static let selectedOrange = Color(hex: 0xFF8A45)
    static let success = Color(hex: 0x20D56E)
    static let danger = Color(hex: 0xFF4D4F)
    static let warning = Color(hex: 0xFFB84D)
    static let categorySelected = Color(hex: 0xA9C7DD)
    static let categoryNormal = Color(hex: 0xF5F5F5)
    static let modifierSelected = Color(hex: 0xD5EFDF)
    static let modifierNormal = Color(hex: 0xF5F1F1)
    // Selection modes are recognizable before tapping: single=pink, checkbox=yellow.
    static let modifierSingleNormal = Color(hex: 0xFCE8F0)
    static let modifierSingleSelected = Color(hex: 0xF8BED4)
    static let modifierSingleBorder = Color(hex: 0xD95689)
    static let modifierCheckboxNormal = Color(hex: 0xFFF3C4)
    static let modifierCheckboxSelected = Color(hex: 0xFFE18A)
    static let modifierCheckboxBorder = Color(hex: 0xD5A000)
    static let textPrimary = Color(hex: 0x111111)
    static let textSecondary = Color(hex: 0x555555)
    static let border = Color(hex: 0xD8D8D8)
    static let divider = Color(hex: 0xC9C9C9)
}

enum POSSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum POSRadius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
    static let large: CGFloat = 14
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

struct POSCardModifier: ViewModifier {
    var padding: CGFloat = POSSpacing.md

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(POSColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: POSRadius.medium, style: .continuous))
    }
}

extension View {
    func posCard(padding: CGFloat = POSSpacing.md) -> some View {
        modifier(POSCardModifier(padding: padding))
    }
}

struct FilledActionButtonStyle: ButtonStyle {
    let color: Color
    var height: CGFloat = 56

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(color.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: POSRadius.medium, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}



// MARK: - Shared authentication and setup form appearance
// Keep local merchant setup, POS account login, and account recovery
// visually consistent throughout the application.
enum OUPOSAuthAppearance {
    static let foreground = Color(hex: 0x293C53)
    static let background = Color(hex: 0xFCFDFF)
    static let border = Color(hex: 0xD4DBE3)
    static let primary = Color(hex: 0x2B4C75)
    static let radius: CGFloat = 11
    static let controlHeight: CGFloat = 50
}

struct OUPOSAuthInputModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 16))
            .foregroundStyle(OUPOSAuthAppearance.foreground)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: OUPOSAuthAppearance.controlHeight)
            .background(OUPOSAuthAppearance.background)
            .overlay {
                RoundedRectangle(cornerRadius: OUPOSAuthAppearance.radius, style: .continuous)
                    .strokeBorder(OUPOSAuthAppearance.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: OUPOSAuthAppearance.radius, style: .continuous))
    }
}

struct OUPOSAuthPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 14 : 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 15 : 18)
            .frame(maxWidth: compact ? nil : .infinity,
                   minHeight: compact ? 44 : OUPOSAuthAppearance.controlHeight)
            .background(OUPOSAuthAppearance.primary.opacity(configuration.isPressed ? 0.8 : 1))
            .opacity(isEnabled ? 1 : 0.5)
            .clipShape(RoundedRectangle(cornerRadius: OUPOSAuthAppearance.radius, style: .continuous))
    }
}

struct OUPOSAuthOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 14 : 16, weight: .semibold))
            .foregroundStyle(OUPOSAuthAppearance.foreground)
            .padding(.horizontal, compact ? 15 : 18)
            .frame(maxWidth: compact ? nil : .infinity,
                   minHeight: compact ? 44 : OUPOSAuthAppearance.controlHeight)
            .background(configuration.isPressed ? Color(hex: 0xF0F4F8) : .white)
            .opacity(isEnabled ? 1 : 0.5)
            .overlay {
                RoundedRectangle(cornerRadius: OUPOSAuthAppearance.radius, style: .continuous)
                    .strokeBorder(OUPOSAuthAppearance.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: OUPOSAuthAppearance.radius, style: .continuous))
    }
}

struct OUPOSAuthDestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(hex: 0xB4232B))
            .padding(.horizontal, 15)
            .frame(minHeight: 44)
            .background(configuration.isPressed ? Color(hex: 0xFFF0F1) : .white)
            .opacity(isEnabled ? 1 : 0.5)
            .overlay {
                RoundedRectangle(cornerRadius: OUPOSAuthAppearance.radius, style: .continuous)
                    .strokeBorder(Color(hex: 0xE8B6B9), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: OUPOSAuthAppearance.radius, style: .continuous))
    }
}

extension View {
    func ouposAuthInput() -> some View {
        modifier(OUPOSAuthInputModifier())
    }
}
