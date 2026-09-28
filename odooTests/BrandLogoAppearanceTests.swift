import UIKit
import XCTest
@testable import odoo

/// 全面實測 I16（I16-05-login-dark.png）：深色模式登入頁的 Apporo logo 是一塊不透明白色方框。
/// `ApporoLogo` 沿用 App 圖示那張「白底合成、無 alpha」的 PNG，也沒有深色版本。深色外觀改用
/// 透明底、淺色鳥形的變體；淺色外觀維持原本白底圖（與白色背景一致）。兩個品牌的登入 logo
/// 都在同一個資產目錄裡，所以兩個品牌的建置都驗兩張。
final class BrandLogoAppearanceTests: XCTestCase {

    private static let logoAssets = ["ApporoLogo", "WoowLogo"]
    private static let side = 64

    /// RGBA8 pixels of the asset's variant for `style`, drawn at `side`×`side`.
    private func pixels(_ name: String, _ style: UIUserInterfaceStyle) throws -> [UInt8] {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let image = try XCTUnwrap(UIImage(named: name, in: Bundle(for: SettingsViewModel.self), compatibleWith: traits),
                                  "\(name) missing from the asset catalog")
        let cgImage = try XCTUnwrap(image.cgImage)
        let side = Self.side
        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        try buffer.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return buffer
    }

    private func alpha(_ px: [UInt8], x: Int, y: Int) -> UInt8 { px[(y * Self.side + x) * 4 + 3] }

    func test_brandLogo_isOneOfTheCheckedAssets() {
        XCTAssertTrue(Self.logoAssets.contains(AppBrand.current.logoAsset))
    }

    func test_logo_givenDarkAppearance_hasTransparentCorners() throws {
        let last = Self.side - 1
        for name in Self.logoAssets {
            let px = try pixels(name, .dark)
            for (x, y) in [(0, 0), (last, 0), (0, last), (last, last)] {
                XCTAssertEqual(alpha(px, x: x, y: y), 0, "\(name) 深色外觀角落 (\(x),\(y)) 不可是不透明底色")
            }
        }
    }

    /// The Apporo mark is #4D4D4D grey (≈2.5:1 on black). Its dark variant must stay readable on a
    /// dark background: every clearly opaque pixel ≥ 3:1 against black (WCAG 1.4.11 graphics).
    func test_apporoLogo_givenDarkAppearance_markIsLightEnoughOnBlack() throws {
        let px = try pixels("ApporoLogo", .dark)
        var opaque = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] == 255 {
            opaque += 1
            let luminance = [px[i], px[i + 1], px[i + 2]].map { c -> Double in
                let v = Double(c) / 255
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            let l = 0.2126 * luminance[0] + 0.7152 * luminance[1] + 0.0722 * luminance[2]
            XCTAssertGreaterThanOrEqual((l + 0.05) / 0.05, 3, "像素 \(i / 4) 在黑底上對比不足")
            if (l + 0.05) / 0.05 < 3 { return }
        }
        XCTAssertGreaterThan(opaque, 0, "深色變體必須真的有鳥形")
    }
}
