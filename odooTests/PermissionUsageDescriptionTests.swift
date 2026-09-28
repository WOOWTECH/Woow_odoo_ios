import XCTest
@testable import odoo

/// App Review 2026-09（woowtech platform 1.0 (3) 退件，同一份程式的 Apporo 也會中）：
/// - 2.1(a)：iPad 在 Odoo 討論區按麥克風當掉。Info.plist 沒有 `NSMicrophoneUsageDescription`，WKWebView
///   向系統要麥克風時 TCC 直接終止 App。
/// - 5.1.1(ii)：相機／照片權限說明太空泛，須寫明用途並舉具體例子。
///
/// 這裡驗「實際建出來的 App bundle」（兩個 scheme 各跑一次＝兩品牌）：Info.plist 有這三把鍵（系統只看
/// Info.plist 是否有鍵來決定當不當機），三語 InfoPlist.strings 都有在地化說明、帶品牌名與具體用途。
final class PermissionUsageDescriptionTests: XCTestCase {

    private let languages = ["en", "zh-Hans", "zh-Hant"]
    private let keys = ["NSMicrophoneUsageDescription", "NSCameraUsageDescription", "NSPhotoLibraryUsageDescription"]

    private var appBundle: Bundle { Bundle(for: SettingsViewModel.self) }

    private func lproj(_ lang: String) throws -> Bundle {
        let path = try XCTUnwrap(appBundle.path(forResource: lang, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    /// The prompt text iOS shows for `lang`: the lproj InfoPlist.strings value, else the Info.plist default.
    private func prompt(_ key: String, _ lang: String) throws -> String {
        let localized = try lproj(lang).localizedString(forKey: key, value: nil, table: "InfoPlist")
        if localized != key { return localized }
        return try XCTUnwrap(appBundle.object(forInfoDictionaryKey: key) as? String, "\(key) missing from Info.plist")
    }

    /// Words that must appear, per key and language: a concrete purpose and an example.
    private let required: [String: [String: [String]]] = [
        "NSMicrophoneUsageDescription": [
            "en": ["microphone", "voice message", "voice call", "Odoo Discuss"],
            "zh-Hant": ["麥克風", "語音訊息", "語音通話", "討論"],
            "zh-Hans": ["麦克风", "语音消息", "语音通话", "讨论"],
        ],
        "NSCameraUsageDescription": [
            "en": ["camera", "photo", "for example", "quotation", "expense", "maintenance"],
            "zh-Hant": ["相機", "拍照", "例如", "報價單", "費用報銷", "維修"],
            "zh-Hans": ["相机", "拍照", "例如", "报价单", "费用报销", "维修"],
        ],
        "NSPhotoLibraryUsageDescription": [
            "en": ["photo", "attach", "Odoo record", "chat message", "for example"],
            "zh-Hant": ["相簿", "附加", "Odoo 紀錄", "聊天訊息", "例如"],
            "zh-Hans": ["相册", "附加", "Odoo 记录", "聊天消息", "例如"],
        ],
    ]

    func test_infoPlist_givenBuiltApp_declaresMicrophoneCameraAndPhotoKeys() {
        for key in keys {
            let value = appBundle.object(forInfoDictionaryKey: key) as? String
            XCTAssertFalse((value ?? "").isEmpty, "\(key) must be in Info.plist or iOS terminates the app on use")
        }
    }

    func test_prompts_givenEveryLanguage_nameTheBrandAndConcretePurpose() throws {
        for key in keys {
            for lang in languages {
                let text = try prompt(key, lang)
                XCTAssertTrue(text.contains(AppBrand.current.displayName(localization: lang)),
                              "\(key) [\(lang)] must name the app: \(text)")
                for word in try XCTUnwrap(required[key]?[lang]) {
                    XCTAssertTrue(text.contains(word), "\(key) [\(lang)] lacks “\(word)”: \(text)")
                }
                XCTAssertGreaterThanOrEqual(text.count, lang == "en" ? 90 : 35, "\(key) [\(lang)] too vague: \(text)")
            }
        }
    }

    func test_prompts_givenChineseLanguages_areTranslatedNotEnglishCopies() throws {
        for key in keys {
            let english = try prompt(key, "en")
            for lang in ["zh-Hans", "zh-Hant"] {
                let text = try prompt(key, lang)
                XCTAssertNotEqual(text, english, "\(key) [\(lang)] is an English copy")
                XCTAssertNotNil(text.range(of: "\\p{Han}", options: .regularExpression), "\(key) [\(lang)]")
            }
        }
    }
}
