//
//  ErrorBannerViewTests.swift
//  odooTests
//
//  2026-10-08 contrast fix: the error banner drew white text on `Color.red.opacity(0.85)`, about
//  3.1:1 in light mode (below WCAG AA 4.5:1). It now uses an opaque darker red in both modes.
//

import XCTest
import SwiftUI
import UIKit
@testable import odoo

@MainActor
final class ErrorBannerViewTests: XCTestCase {

    private func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(color.getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(a, 1, accuracy: 0.0001, "banner fill must be opaque")
        return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    func test_backgroundHex_givenWhiteText_returnsAtLeastAAContrast() throws {
        XCTAssertEqual(ErrorBannerView.backgroundHex, "#D70015")
        let ratio = try XCTUnwrap(WoowTheme.contrastRatio(ErrorBannerView.backgroundHex, "#FFFFFF"))
        XCTAssertGreaterThanOrEqual(ratio, 4.5)
        XCTAssertEqual(ratio, 5.38, accuracy: 0.01)
    }

    func test_background_givenLightAndDarkMode_isOpaqueAndMeetsAA() throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let resolved = UIColor(ErrorBannerView.background)
                .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            let fill = hex(resolved)
            XCTAssertEqual(fill, ErrorBannerView.backgroundHex, "style \(style.rawValue)")
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(WoowTheme.contrastRatio(fill, "#FFFFFF")), 4.5)
        }
    }

    /// Documents the regression: system red at 85% over a white page, the old light-mode fill.
    func test_contrastRatio_givenOldTranslucentRedOverWhite_returnsBelowAA() throws {
        let old = UIColor.systemRed.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(old.getRed(&r, green: &g, blue: &b, alpha: &a))
        let blend = { (c: CGFloat) in Int((0.85 * c * 255 + 0.15 * 255).rounded()) }
        let composite = String(format: "#%02X%02X%02X", blend(r), blend(g), blend(b))
        XCTAssertLessThan(try XCTUnwrap(WoowTheme.contrastRatio(composite, "#FFFFFF")), 4.5)
    }
}
