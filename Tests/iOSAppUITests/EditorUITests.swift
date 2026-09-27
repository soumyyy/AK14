import XCTest

final class EditorUITests: XCTestCase {
    @MainActor
    func testCanvasEditorAddMoveUndoRedoAndSave() throws {
        let app = openOptionsEditor()
        // The selected option is edited in place: add text, and it becomes the selected element.
        let field = app.textFields["newSlideText"]
        XCTAssertTrue(field.waitForExistence(timeout: 30)); field.tap(); field.typeText("Munnar")
        app.buttons["Add text"].tap()
        let selected = app.textFields["selectedTextField"]
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        XCTAssertEqual(selected.value as? String, "Munnar")
        app.buttons["Undo edit"].tap(); app.buttons["Redo edit"].tap()
        app.buttons["Save to Photos"].tap()
        XCTAssertTrue(app.alerts["Saved to Photos"].waitForExistence(timeout: 90))
    }

    @MainActor
    func testAdjustPhotoWarmthIsUndoable() throws {
        let app = openOptionsEditor()
        let slide = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Slide '")).firstMatch
        XCTAssertTrue(slide.waitForExistence(timeout: 30))
        slide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let adjust = app.buttons["adjustPhotoButton"]
        XCTAssertTrue(adjust.waitForExistence(timeout: 10))
        adjust.tap()
        let warmth = app.sliders["Warmth"]
        XCTAssertTrue(warmth.waitForExistence(timeout: 10))
        warmth.adjust(toNormalizedSliderPosition: 0.8)
        let undo = app.buttons["Undo edit"]
        let enabled = NSPredicate(format: "enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: undo)], timeout: 5), .completed)
        undo.tap()
        let disabled = NSPredicate(format: "enabled == false")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: disabled, object: undo)], timeout: 5), .completed)
    }

    @MainActor
    private func openOptionsEditor() -> XCUIApplication {
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
        XCTAssertTrue(photo.waitForExistence(timeout: 20))
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review '")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 15)); review.tap()
        XCTAssertTrue(app.staticTexts["Review your selection"].waitForExistence(timeout: 60))
        if app.buttons["allEventsChoice"].waitForExistence(timeout: 2) { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'eventChoice-'" )).firstMatch.tap() }
        let generate = app.buttons["Create options"]
        XCTAssertTrue(generate.waitForExistence(timeout: 20)); generate.tap()
        XCTAssertTrue(app.staticTexts["Choose an option"].waitForExistence(timeout: 300))
        return app
    }
}
