import Foundation

/// Build-selected identity, never inferred from locale or a user's account.
/// Invalid/missing configuration fails closed rather than selecting another brand.
struct AppBrand: Sendable, Equatable {
    enum Code: String, Sendable { case woowtech, apporo }
    let code: Code
    let bundleID: String
    let urlScheme: String

    init?(code: String?, bundleID: String?, urlScheme: String?) {
        guard let code = code.flatMap(Code.init(rawValue:)),
              let bundleID, let urlScheme else { return nil }
        let valid: Bool
        switch code {
        case .woowtech:
            valid = bundleID == "io.woowtech.odoo" && urlScheme == "woowodoo"
        case .apporo:
            valid = (bundleID == "com.apporo.odoo" && urlScheme == "apporoodoo") ||
                (bundleID == "com.apporo.odoo.dev" && urlScheme == "apporoodoo-dev")
        }
        guard valid else { return nil }
        self.code = code
        self.bundleID = bundleID
        self.urlScheme = urlScheme
    }

    static let current: AppBrand = {
        guard let brand = AppBrand(
            code: Bundle.main.object(forInfoDictionaryKey: "AppBrand") as? String,
            bundleID: Bundle.main.bundleIdentifier,
            urlScheme: Bundle.main.object(forInfoDictionaryKey: "AppURLScheme") as? String
        ) else { fatalError("Missing or inconsistent app brand configuration") }
        return brand
    }()

    var displayName: String { code == .apporo ? "Apporo platform" : "woowtech platform" }
    var primaryColorHex: String { code == .apporo ? "#8B6B24" : "#6183FC" }
    var logoAsset: String { code == .apporo ? "ApporoLogo" : "WoowLogo" }
    var signature: String { code == .apporo ? "APPORO UNION INC." : "\u{00A9} 2026 WoowTech" }
    var websiteHost: String { code == .apporo ? "www.apporo.ai" : "aiot.woowtech.io" }
    var websiteURL: String { "https://" + websiteHost }
    var contactEmail: String { code == .apporo ? "info@apporo.ai" : "woowtech@designsmart.com.tw" }
    var keychainService: String { bundleID + ".keychain" }

    enum CompliancePage: String, CaseIterable, Sendable {
        case support = "/odoo-support"
        case privacy = "/odoo-privacy"
        case accountDeletion = "/odoo-account-deletion"
    }

    func pageURL(_ page: CompliancePage, language: String?) -> String {
        let english: Bool
        if code == .apporo {
            // Both Chinese localizations use the Traditional Chinese page;
            // every other locale, including missing locale, uses English.
            english = !(language == "zh" || language?.hasPrefix("zh-") == true || language?.hasPrefix("zh_") == true)
        } else {
            // Preserve WOOW's existing fallback semantics.
            english = language.map { $0 == "en" || $0.hasPrefix("en-") || $0.hasPrefix("en_") } ?? false
        }
        return websiteURL + page.rawValue + (english ? "-en" : "")
    }

    func acceptsScheme(_ scheme: String?) -> Bool { scheme == urlScheme }

    func localized(_ key: String) -> String {
        String(format: NSLocalizedString(key, comment: "Brand-aware text"), displayName)
    }
}
