# UI cleanup: one clear path from photos to a postable carousel

Status: approved direction (2026-09-27). Owner: "the UI is kind of very messy, clean it according to UX." Audit: a screen tour at iPhone 17 Pro size (`Tests/iOSAppUITests/ScreenTourUITests.swift`).

## Audit findings
1. **Photos:**
   - Four competing controls before any photo: a mode pair ("Choose the best" / "Use exactly these"), a date range, "Find photos", and an unexplained "Choose" pill.
   - 130 photos arrive pre-selected with no explanation.
2. **Review:**
   - A wall of privacy and AI text takes half the screen.
   - It contradicts itself: "AI planning is on by default" appears next to a toggle that is off.
   - "Set up AI-assisted planning" competes with "Create options".
3. **Generating:** there is no dedicated state; the review screen stays up with a small "Keep processing images" pill.
4. **Options (the most important screen):**
   - Controls are stacked in four rows of small bordered chips: a text field plus Add text; Undo/Redo; Move slide left/right and Remove slide; Share/Save.
   - The slide position is shown twice (dots on the photo, and a "Slide 1 of 10" label).
   - The Adjust panel covers the photo being adjusted.
   - Options are text chips ("Option 1") with no preview.
5. **Silent fallback:** when the AI is unavailable, the owner sees a plain carousel with no explanation (the root cause of a whole afternoon of "plain" output).

## Design rules
Native iOS 26, dark and photo-first:
- one primary action per screen
- secondary actions live in the navigation bar, menus or sheets
- no paragraphs on primary screens
- 44 pt touch targets, and Dynamic Type safe
- keep the existing palette (`AK14Palette`) and Liquid Glass buttons

## Screens
**Photos**
- Title, then a single segmented control: "Best of a period" / "Pick exact photos". It replaces the mode pair.
- "Best of a period": a date-range row (From–To) that loads photos automatically when changed. No "Find photos" button unless the load failed; then show "Retry".
- Remove the "Choose" pill.
- A grid with a selected-count badge in the bottom bar: "Continue with 130 photos". Add a "Select none" / "Select all" menu in the nav bar.
- "Pick exact photos": the system picker button and "Keep my order" (unchanged behaviour).

**Review**
- Order: the photo strip, then "What was this?" (the story hint field, the primary input), then one compact row, "AI story planning · On/Off", with a chevron to a sheet. The sheet holds the privacy explanation, the toggle and the invite setup.
- The row shows the real state: "On", "Off", or "Needs setup".
- The bottom primary button is "Create options". Nothing else competes with it.

**Generating**
- A full-screen state: a large cover-photo blur or collage, the current stage ("Picking the best moments…", "Designing option 2 of 3…") with a determinate progress bar where possible, and a Cancel button.

**Options** (the editor stays inline; there is no separate edit route):
- **Top:** a horizontal row of option cards, each showing the cover slide thumbnail (about 64×80) and "Option N" below it, with the selected card outlined in the accent colour. Undo and Redo sit as icon buttons in the navigation bar (trailing), along with a "…" menu containing: Move slide left, Move slide right, Remove slide, and Add slide text.
- **Middle:** the canvas with a single page indicator (dots overlaid, or "1 / 10" text; not both).
- **Bottom:** a contextual toolbar with ONE row of icon+label buttons:
  - nothing selected: [Text] [Adjust all]
  - photo selected: [Replace] [Crop] [Adjust] [Delete]
  - text selected: [Edit] [Font] [Colour] [Delete]
  Replace opens a bottom sheet with the thumbnail strip. Adjust opens a compact bottom sheet (`presentationDetents([.height(240)])`) so the photo stays visible above it. Text opens an inline text-entry sheet.
- **Below the toolbar:** the primary "Save" button (glassProminent) and a Share icon button beside it.
- **Fallback banner:** when the run's director status is not ok (for example the AI was unavailable or the usage limit was reached), show a slim banner above the canvas: "AI planning unavailable — this is a photos-only draft. [Try again]". Try again re-runs generation with the same inputs.

## Constraints
- Keep every behaviour: the exact set, the Share extension, save/share bookkeeping, and editor gestures and undo.
- Keep these accessibility identifiers and labels, or update the UI tests in the same change:
  - identifiers: "photosPermissionCTA", "photo-N", "storyHintField", "exactSetCount", "newSlideText" (for the text-entry field), "selectedTextField", "adjustPhotoButton", "elementControls", "emptyElementControls", "interactionLogPath"
  - labels: "Create options", "Undo edit", "Redo edit", "Add text", "Save to Photos", "Share slides", "Choose an option"
- All UI tests pass: Editor ×2, ImportGenerateReview ×2, ScreenTour.

## Speed and reliability (owner, 2026-09-27: "it takes time to shift between images, the editing is flaky")
Measured causes in the current code:
1. `EditorModel.init` calls `requestPreview()`, which re-renders every slide at export resolution from the full-size originals, one after another. The run's rendered slides (`option.slides`) already show exactly the same document.
2. `OptionsReviewStage` rebuilds `EditorModel` on every option switch (`editorModel = nil`, then a new one), so going back to an option renders everything again.
3. Every edit re-renders all slides, not just the slides whose layers changed.
4. `PagerStrip.setURLs` tears down and rebuilds every tile whenever any URL changes, which causes a flash and a loss of scroll state.

Requirements:
- **Open instantly.** When no saved `documents/<id>.json` exists, the preview is `option.slides`, and nothing is rendered on open. When a saved document exists, show `option.slides` immediately and re-render in the background only the slides that differ.
- **Switch instantly.** Keep one `EditorModel` per option for the session, in a dictionary keyed by option ID. Switching back reuses it; nothing is re-rendered.
- **Edit fast.** An edit re-renders only the slides touched by the change:
  - the slides the edited layer was on, before and after the change
  - all slides for seamless documents, or when slides are added, removed or reordered
  Other slides keep their current URLs. The edited slide renders first.
- **Paging:** `PagerStrip` updates only the tiles whose URL changed, keeps the current page, and loads images off the main thread (already the case). There is no flash.
- **Gestures:** a drag that starts on empty canvas pages the carousel; a drag that starts on the selected layer moves it. Tap-to-select must work on the first tap. A pinch on an unselected area does nothing.
- **Target:** switching options feels instant (under 100 ms to show slides), and a single edit's preview updates in under 1 s on an iPhone 17.
