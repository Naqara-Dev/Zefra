import AppKit
import SwiftUI

/// Near-black, light type, hairlines for structure. Colour means something: the heat of a reading,
/// or the one accent the user picked.
enum Theme {
    static let window = tone(dark: 0x0C0D0F, light: 0xF5F5F3)
    static let sidebar = tone(dark: 0x101113, light: 0xEEEEEB)
    static let card = tone(dark: 0x18191C, light: 0xFFFFFF)
    static let cardHover = tone(dark: 0x212226, light: 0xF0F0ED)
    static let field = tone(dark: 0x15161A, light: 0xFFFFFF)
    static let line = tone(dark: 0xFFFFFF, darkAlpha: 0.075, light: 0x101114, lightAlpha: 0.1)

    static let ink = tone(dark: 0xF1F1EF, light: 0x16171A)
    static let secondary = tone(dark: 0x9A9BA1, light: 0x62636A)
    static let tertiary = tone(dark: 0x63646B, light: 0x9A9BA1)

    static let cool = tone(dark: 0x7FC8E8, light: 0x2F86AE)
    static let mild = tone(dark: 0x8FD8C6, light: 0x2F9078)
    static let warm = tone(dark: 0xE6C27A, light: 0xA67F24)
    static let hot = tone(dark: 0xEE9A62, light: 0xC4672B)
    static let danger = tone(dark: 0xEA7F74, light: 0xC4493C)

    enum Accent: String, CaseIterable, Identifiable {
        case mint, ice, amber, coral, lilac, white
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var color: Color {
            switch self {
            case .mint: Theme.mild
            case .ice: Theme.cool
            case .amber: Theme.warm
            case .coral: Theme.danger
            case .lilac: Theme.tone(dark: 0xC4A9E8, light: 0x7F58B5)
            case .white: Theme.ink
            }
        }
    }

    static var accentChoice: Accent {
        get { UserDefaults.standard.string(forKey: "ZefraAccent").flatMap(Accent.init(rawValue:)) ?? .mint }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ZefraAccent") }
    }

    static var accent: Color { accentChoice.color }
    static var onAccent: Color { tone(dark: 0x0C0D0F, light: 0xFFFFFF) }

    /// The colour of a temperature, in degrees Celsius.
    static func heat(_ celsius: Double?) -> Color {
        guard let celsius else { return tertiary }
        switch celsius {
        case ..<45: return cool
        case ..<65: return mild
        case ..<80: return warm
        case ..<92: return hot
        default: return danger
        }
    }

    static func tone(dark: UInt32, darkAlpha: CGFloat = 1, light: UInt32, lightAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha)
                : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}
