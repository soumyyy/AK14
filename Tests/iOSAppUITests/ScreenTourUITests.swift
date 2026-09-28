import XCTest

/// Walks the main flow and keeps a screenshot of every screen for design review.
final class ScreenTourUITests: XCTestCase {
    @MainActor
    func testScreenTour() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ak14.modelAssist", "NO"]
        app.launch()
        snap(app, "01-launch")
        let access = app.buttons["photosPermissionCTA"]
        if access.waitForExistence(timeout: 5) { access.tap() }
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.buttons["Allow Full Access"].waitForExistence(timeout: 5) { system.buttons["Allow Full Access"].tap() }
        XCTAssertTrue(app.staticTexts["Choose photos for your story."].waitForExistence(timeout: 20))
        if app.buttons["Find photos"].waitForExistence(timeout: 10) { app.buttons["Find photos"].tap() }
        XCTAssertTrue(app.buttons["photo-1"].waitForExistence(timeout: 20))
        snap(app, "02-choose-photos")
        app.swipeUp(); snap(app, "03-choose-photos-scrolled"); app.swipeDown()
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue with '")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 15)); review.tap()
        XCTAssertTrue(app.staticTexts["Review your selection"].waitForExistence(timeout: 60))
        snap(app, "04-review")
        app.swipeUp(); snap(app, "05-review-scrolled")
        let generate = app.buttons["Create options"]
        XCTAssertTrue(generate.waitForExistence(timeout: 20)); generate.tap()
        Thread.sleep(forTimeInterval: 1.5); snap(app, "06-generating")
        XCTAssertTrue(app.staticTexts["Choose an option"].waitForExistence(timeout: 300))
        Thread.sleep(forTimeInterval: 2); snap(app, "07-options")
        let slide = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Slide '")).firstMatch
        if slide.waitForExistence(timeout: 10) { slide.tap(); Thread.sleep(forTimeInterval: 1); snap(app, "08-photo-selected") }
        if app.buttons["adjustPhotoButton"].waitForExistence(timeout: 5) {
            app.buttons["adjustPhotoButton"].tap(); Thread.sleep(forTimeInterval: 1); snap(app, "09-adjust")
        }
    }

    @MainActor private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
