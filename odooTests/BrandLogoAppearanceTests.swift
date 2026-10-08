import UIKit
import XCTest
@testable import odoo

/// 全面實測 I16（I16-05-login-dark.png）：深色模式登入頁的 Apporo logo 是一塊不透明白色方框。
/// 2026-10-08 擁有者要求「Logo都要是圓型外框」，取代 I16 當時的透明底淺色標誌方案：`ApporoLogo`
/// 改成和 `WoowLogo` 一樣的單一圓形徽章（白色圓盤、#D9D9D9 內緣外框、原色 #4D4D4D 標誌，圓外透明），
/// 淺色、深色外觀共用同一張。兩個品牌的登入 logo 都在同一個資產目錄裡，所以兩個品牌的建置都驗兩張。
final class BrandLogoAppearanceTests: XCTestCase {

    private static let logoAssets = ["ApporoLogo", "WoowLogo"]
    private static let side = 64

    /// RGBA8 pixels of the asset's variant for `style`, drawn at `side`×`side`.
    private func pixels(_ name: String, _ style: UIUserInterfaceStyle, side: Int = BrandLogoAppearanceTests.side) throws -> [UInt8] {
        let traits = UITraitCollection(userInterfaceStyle: style)
        let image = try XCTUnwrap(UIImage(named: name, in: Bundle(for: SettingsViewModel.self), compatibleWith: traits),
                                  "\(name) missing from the asset catalog")
        let cgImage = try XCTUnwrap(image.cgImage)
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

    /// Relative luminance of an sRGB8 pixel (WCAG 2.x).
    private func luminance(_ px: [UInt8], _ i: Int) -> Double {
        let linear = [px[i], px[i + 1], px[i + 2]].map { c -> Double in
            let v = Double(c) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    /// 2026-10-08 圓形徽章：深色外觀下 logo 仍是不透明白色圓盤（不再是 I16 的透明底淺色標誌），
    /// 標誌維持原色深灰，與圓盤的對比 ≥ 3:1（WCAG 1.4.11 graphics）；圓盤本身在深色背景上自然醒目。
    func test_apporoLogo_givenDarkAppearance_isOpaqueWhiteDiscWithDarkMark() throws {
        // 256 pt keeps the mark's strokes several pixels wide, so their true colour survives downsampling.
        let side = 256
        let px = try pixels("ApporoLogo", .dark, side: side)
        let centreRow = side / 2
        // Opaque white disc fill between the ring and the mark (left of centre on the middle row).
        let fill = (centreRow * side + side / 8) * 4
        XCTAssertEqual(px[fill + 3], 255, "深色外觀圓盤必須不透明")
        XCTAssertGreaterThanOrEqual(min(px[fill], px[fill + 1], px[fill + 2]), 250, "深色外觀圓盤必須是白色")
        let disc = luminance(px, fill)
        var dark = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] == 255 {
            let l = luminance(px, i)
            if (disc + 0.05) / (l + 0.05) >= 3 { dark += 1 }
        }
        XCTAssertGreaterThan(dark, 500, "白色圓盤上必須有對比足夠的深色標誌")
        // Same single image for both appearances (no dark variant any more).
        XCTAssertEqual(try pixels("ApporoLogo", .light, side: side), px, "淺色、深色外觀應共用同一張圓形徽章")
    }
}
