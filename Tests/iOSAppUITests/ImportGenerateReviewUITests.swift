import XCTest

final class ImportGenerateReviewUITests: XCTestCase {
    @MainActor
    func testImportGenerateAndReviewOptions() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ak14.modelAssist", "NO"]   // deterministic on-device flow; no Worker in the simulator
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
        // With access already granted the app may load the recent library straight away; "Find photos" is optional.
        if findPhotos.waitForExistence(timeout: 10), findPhotos.isEnabled { findPhotos.tap() }
        let selected = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'photos selected'")).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 20), "Expected a visible selected-photo count")
        let firstPhoto = app.buttons["photo-1"]
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10), "Expected the date-range photos, selected by default")

        let exactMode = app.buttons["Pick exact photos"]
        XCTAssertTrue(exactMode.waitForExistence(timeout: 2))
        exactMode.tap()
        let keepOrder = app.switches["Keep my order"]
        XCTAssertTrue(keepOrder.waitForExistence(timeout: 2))
        if (keepOrder.value as? String) != "1" { keepOrder.tap() }

        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue with '")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(review.isEnabled, "At least one simulator photo should be selected")
        review.tap()
        XCTAssertTrue(app.staticTexts["Review your selection"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'All '")).firstMatch.exists)

        if app.buttons["allEventsChoice"].waitForExistence(timeout: 2) {
            let eventChoice = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'eventChoice-'" )).firstMatch
            XCTAssertTrue(eventChoice.exists, "The event picker should contain event rows")
            eventChoice.tap()
        }
        let storyHint = app.descendants(matching: .any)["storyHintField"]
        XCTAssertTrue(storyHint.waitForExistence(timeout: 20), "The Review stage should show the optional story field")
        storyHint.tap()
        storyHint.typeText("Misty hike with my cousins")
        let generate = app.buttons["Create options"]
        XCTAssertTrue(generate.waitForExistence(timeout: 20))
        generate.tap()
        XCTAssertTrue(app.staticTexts["Choose an option"].waitForExistence(timeout: 300),
                      "Expected the generated option review screen")
        // Pick an option that has at least two slides so a reorder is possible; the simulator library varies.
        let optionButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS ' slides' AND NOT (label BEGINSWITH 'Share') AND NOT (label BEGINSWITH 'Save')"))
        XCTAssertGreaterThan(optionButtons.count, 0, "Expected generated options")
        let multi = optionButtons.allElementsBoundByIndex.first { button in
            let words = button.label.split(separator: " ")
            return zip(words, words.dropFirst()).contains { Int($0) ?? 0 >= 2 && $1.hasPrefix("slides") }
        }
        (multi ?? optionButtons.firstMatch).tap()
        // Editing happens on the options screen itself; there is no separate edit route.
        XCTAssertFalse(app.buttons["Edit slides"].exists, "Editing must not sit behind a separate Edit control")
        XCTAssertTrue(app.buttons["Add text"].waitForExistence(timeout: 30), "The selected option should expose its editing toolbar")
        XCTAssertTrue(app.buttons["Share slides"].exists)
        let save = app.buttons["Save to Photos"]
        XCTAssertTrue(save.exists)
        save.tap()
        XCTAssertTrue(app.alerts["Saved to Photos"].waitForExistence(timeout: 60),
                      "The selected carousel should save back to Photos")

        let logPathElement = app.staticTexts["interactionLogPath"]
        XCTAssertTrue(logPathElement.waitForExistence(timeout: 10))
        let logURL = URL(fileURLWithPath: logPathElement.label)
        let expected = ["concepts_presented", "concept_selected", "carousel_exported"]
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

    @MainActor
    func testIncomingBatchOpensExactReview() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--seed-incoming-batch", "-ak14.modelAssist", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Review your selection"].waitForExistence(timeout: 30))
        XCTAssertEqual(app.staticTexts["exactSetCount"].label, "All 3 photos will be used")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'eventChoice-'" )).firstMatch.exists)
    }
}
