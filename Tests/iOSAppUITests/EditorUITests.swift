import XCTest

final class EditorUITests: XCTestCase {
    @MainActor
    func testCanvasEditorAddMoveUndoRedoAndSave() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ak14.modelAssist", "NO"]
        app.launch()
        let access = app.buttons["photosPermissionCTA"]
        if access.waitForExistence(timeout: 5) { access.tap() }
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.buttons["Allow Full Access"].waitForExistence(timeout: 5) { system.buttons["Allow Full Access"].tap() }
        if system.buttons["Limit Access…"].waitForExistence(timeout: 1) { system.buttons["Limit Access…"].tap() }
        if system.buttons["Add Selected Photos"].waitForExistence(timeout: 3) { system.buttons["Add Selected Photos"].tap() }
        if system.buttons["Add"].waitForExistence(timeout: 2) { system.buttons["Add"].tap() }
        if system.buttons["Done"].waitForExistence(timeout: 2) { system.buttons["Done"].tap() }
        XCTAssertTrue(app.staticTexts["Choose photos for your story."].waitForExistence(timeout: 20))
        if app.buttons["Find photos"].waitForExistence(timeout: 10) { app.buttons["Find photos"].tap() }
        let photo = app.buttons["photo-1"]
        XCTAssertTrue(photo.waitForExistence(timeout: 20)); photo.tap()
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review '")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 15)); review.tap()
        XCTAssertTrue(app.staticTexts["Review your selection"].waitForExistence(timeout: 60))
        if app.buttons["allEventsChoice"].waitForExistence(timeout: 2) { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'eventChoice-'" )).firstMatch.tap() }
        let generate = app.buttons["Create options"]
        XCTAssertTrue(generate.waitForExistence(timeout: 20)); generate.tap()
        XCTAssertTrue(app.staticTexts["Choose an option"].waitForExistence(timeout: 300))
        let edit = app.buttons["Edit design"]
        XCTAssertTrue(edit.waitForExistence(timeout: 20)); edit.tap()
        XCTAssertTrue(app.navigationBars["Edit design"].waitForExistence(timeout: 30))
        app.buttons["Text"].tap()
        let field = app.textFields["Text"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Munnar")
        app.alerts.buttons["Add"].tap()
        app.buttons["Stickers"].tap()
        XCTAssertTrue(app.navigationBars["Stickers"].waitForExistence(timeout: 5))
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'doodle-star'")).firstMatch.tap()
        let layer = app.otherElements.matching(NSPredicate(format: "label CONTAINS 'Text: Munnar' OR label == 'Sticker layer'" )).firstMatch
        XCTAssertTrue(layer.waitForExistence(timeout: 5))
        layer.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        app.buttons["Undo"].tap(); app.buttons["Redo"].tap()
        app.buttons["Save to Photos"].tap()
        XCTAssertTrue(app.alerts["Saved to Photos"].waitForExistence(timeout: 90))
    }
}
