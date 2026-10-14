//
//  odooUITestsLaunchTests.swift
//  odooUITests
//
//  Created by Alan Lin on 2026/3/26.
//

import XCTest

final class odooUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)"]
        app.launch()

        let brandName = app.staticTexts[SharedTestConfig.appDisplayName]
        XCTAssertTrue(
            brandName.waitForExistence(timeout: 15),
            "The selected brand did not reach its login UI after launch",
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(SharedTestConfig.appDisplayName) Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
