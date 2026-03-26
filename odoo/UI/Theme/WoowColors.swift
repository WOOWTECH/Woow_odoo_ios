import SwiftUI

/// Brand color palette from woowtech_claude_brand_prompt_library.pdf.
/// Direct port from Android: Color.kt — same hex values.
enum WoowColors {

    // MARK: - Brand Colors

    static let primaryBlue = Color(hex: "#6183FC")
    static let brandWhite = Color.white
    static let lightGray = Color(hex: "#EFF1F5")
    static let gray = Color(hex: "#646262")
    static let deepGray = Color(hex: "#212121")

    // MARK: - 10 Accent Colors

    static let accentCyan = Color(hex: "#7BDBE0")
    static let accentYellow = Color(hex: "#F8D158")
    static let accentSkyBlue = Color(hex: "#65C2E0")
    static let accentRoyalBlue = Color(hex: "#6791DE")
    static let accentGreen = Color(hex: "#8CD37F")
    static let accentBrown = Color(hex: "#B17148")
    static let accentSand = Color(hex: "#F1C692")
    static let accentOrange = Color(hex: "#E66D3E")
    static let accentCoral = Color(hex: "#F45D6D")
    static let accentLavender = Color(hex: "#C09FE0")

    /// All brand colors for the color picker (5 brand + 10 accent).
    static let brandColors: [String] = [
        "#6183FC", "#FFFFFF", "#EFF1F5", "#646262", "#212121"
    ]

    static let accentColors: [String] = [
        "#7BDBE0", "#F8D158", "#65C2E0", "#6791DE", "#8CD37F",
        "#B17148", "#F1C692", "#E66D3E", "#F45D6D", "#C09FE0"
    ]
}

// MARK: - Color Extension for Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6: // RGB
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
