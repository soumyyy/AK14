import XCTest

final class EditorUITests: XCTestCase {
    @MainActor
    func testCanvasEditorAddEditUndoRedoAndSave() throws {
        let app = openOptionsEditor()
        attachScreenshot(of: app, named: "editor-options")

        // Text entry is presented as a sheet from the contextual toolbar.
        let addText = app.buttons["Add text"]
        XCTAssertTrue(addText.waitForExistence(timeout: 10))
        addText.tap()
        let field = app.descendants(matching: .any)["newSlideText"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        attachScreenshot(of: app, named: "editor-add-text-sheet")
        field.tap()
        field.typeText("Munnar")
        app.buttons["confirmSlideText"].tap()

        // The new layer is selected; Edit opens the same text sheet with its current value.
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        let selected = app.descendants(matching: .any)["selectedTextField"]
        XCTAssertTrue(selected.waitForExistence(timeout: 10))
        XCTAssertEqual(selected.value as? String, "Munnar")
        attachScreenshot(of: app, named: "editor-edit-text-sheet")
        // Replace the known value whether focus selects all text or leaves the caret at its end.
        selected.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        selected.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Munnar".count) + "Munnar again")
        app.buttons["Apply text"].tap()

        let undo = app.buttons["Undo edit"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        undo.tap()
        edit.tap()
        XCTAssertEqual(selected.value as? String, "Munnar")
        app.buttons["Cancel"].tap()
        let redo = app.buttons["Redo edit"]
        XCTAssertTrue(redo.isEnabled)
        redo.tap()
        edit.tap()
        XCTAssertEqual(selected.value as? String, "Munnar again")
        app.buttons["Cancel"].tap()
        app.buttons["Save to Photos"].tap()
        XCTAssertTrue(app.alerts["Saved to Photos"].waitForExistence(timeout: 90))
    }

    @MainActor
    func testAdjustPhotoWarmthIsUndoable() throws {
        let app = openOptionsEditor()
        attachScreenshot(of: app, named: "editor-options-adjustment")

        // Select the photo on the visible canvas, then adjust it in the compact bottom sheet.
        let slide = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Slide '")).firstMatch
        XCTAssertTrue(slide.waitForExistence(timeout: 30))
        slide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let adjust = app.buttons["adjustPhotoButton"]
        XCTAssertTrue(adjust.waitForExistence(timeout: 10))
        adjust.tap()
        let warmth = app.sliders["Warmth"]
        XCTAssertTrue(warmth.waitForExistence(timeout: 10))
        attachScreenshot(of: app, named: "editor-adjust-sheet")
        warmth.adjust(toNormalizedSliderPosition: 0.8)
        app.buttons["Done"].tap()

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
        // The importer seed creates a deterministic three-photo incoming batch and opens Review.
        app.launchArguments = ["--seed-incoming-batch", "-ak14.modelAssist", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Review your selection"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["exactSetCount"].label, "All 3 photos will be used")
        let generate = app.buttons["Create options"]
        XCTAssertTrue(generate.waitForExistence(timeout: 20))
        generate.tap()
        XCTAssertTrue(app.staticTexts["Choose an option"].waitForExistence(timeout: 300))
        XCTAssertTrue(app.buttons["Save to Photos"].waitForExistence(timeout: 30))
        return app
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
