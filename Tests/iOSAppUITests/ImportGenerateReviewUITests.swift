import XCTest

final class ImportGenerateReviewUITests: XCTestCase {
    @MainActor
    func testImportGenerateAndReviewOptions() throws {
        let app = XCUIApplication()
        app.launch()

        let access = app.buttons["photosPermissionCTA"]
        if access.waitForExistence(timeout: 5) { access.tap() }
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowFull = system.buttons["Allow Full Access"]
        if allowFull.waitForExistence(timeout: 5) { allowFull.tap() }
        let allowLimited = system.buttons["Limit Access…"]
        if allowLimited.waitForExistence(timeout: 1) { allowLimited.tap() }
        let limitedPicker = system.buttons["Add Selected Photos"]
        if limitedPicker.waitForExistence(timeout: 3) { limitedPicker.tap() }
        let addButton = system.buttons["Add"]
        if addButton.waitForExistence(timeout: 2) { addButton.tap() }
        let doneButton = system.buttons["Done"]
        if doneButton.waitForExistence(timeout: 2) { doneButton.tap() }

        XCTAssertTrue(app.staticTexts["Choose photos for your story."].waitForExistence(timeout: 20),
                      "The permission action should return to the Photos stage")
        let findPhotos = app.buttons["Find photos"]
        XCTAssertTrue(findPhotos.waitForExistence(timeout: 20), "Photos access should reveal the date controls")
        if findPhotos.isEnabled { findPhotos.tap() }
        let selected = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'photos selected'")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 20), "Expected a visible selected-photo count")

        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review '")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(review.isEnabled, "At least one simulator photo should be selected")
        review.tap()
        XCTAssertTrue(app.staticTexts["Review your selection"].waitForExistence(timeout: 60))

        let generate = app.buttons["Create options"]
        XCTAssertTrue(generate.waitForExistence(timeout: 20))
        generate.tap()
        XCTAssertTrue(app.staticTexts["Choose an option"].waitForExistence(timeout: 300),
                      "Expected the generated option review screen")
        let optionButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS ' slides'"))
        XCTAssertGreaterThan(optionButtons.count, 1, "Expected multiple generated options")
        optionButtons.element(boundBy: 1).tap()
        let edit = app.buttons["Edit slides"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.tap()
        XCTAssertTrue(app.staticTexts["Slides"].waitForExistence(timeout: 10))
        let moveEarlier = app.buttons["Move slide 2 earlier"]
        XCTAssertTrue(moveEarlier.waitForExistence(timeout: 5))
        XCTAssertTrue(moveEarlier.isEnabled, "Expected at least two slides to reorder")
        moveEarlier.tap()
        let done = app.buttons["Done"]
        let editFinished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: done)
        XCTAssertEqual(XCTWaiter.wait(for: [editFinished], timeout: 120), .completed)
        done.tap()
        let editorClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                     object: app.navigationBars["Edit slides"])
        XCTAssertEqual(XCTWaiter.wait(for: [editorClosed], timeout: 20), .completed)
        XCTAssertTrue(app.buttons["Share slides"].exists)
        let save = app.buttons["Save to Photos"]
        XCTAssertTrue(save.exists)
        save.tap()
        XCTAssertTrue(app.alerts["Saved to Photos"].waitForExistence(timeout: 60),
                      "The selected carousel should save back to Photos")

        let logPathElement = app.staticTexts["interactionLogPath"]
        XCTAssertTrue(logPathElement.waitForExistence(timeout: 10))
        let logURL = URL(fileURLWithPath: logPathElement.label)
        let expected = ["concepts_presented", "concept_selected", "slide_reordered", "carousel_exported"]
        var observed: [String] = []
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let contents = try? String(contentsOf: logURL, encoding: .utf8) {
                observed = contents.split(separator: "\n").compactMap { line in
                    guard let data = line.data(using: .utf8),
                          let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                    return event["event"] as? String
                }
                if expected.allSatisfy(observed.contains) { break }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        var expectedIndex = 0
        for event in observed where expectedIndex < expected.count && event == expected[expectedIndex] {
            expectedIndex += 1
        }
        XCTAssertEqual(expectedIndex, expected.count, "Expected events in order; got \(observed)")
    }
}
