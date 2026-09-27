# Coherent generation and direct editing

## Outcome
Generate postable carousel choices, select one, and finish it directly on the options screen. The visible design and exported images must agree.

## Product contract
- Keep the current dark, photo-focused screen and native paging. Selecting an option exposes its editable content immediately. Tap a photo/text element for contextual controls; no separate Edit route or Edit sheet.
- V1 controls: photo replacement, safe crop, move/resize/rotate, text add/change/remove, undo/redo, and slide movement/removal where it will not break a continuous layout. Save and Share stay in the bottom safe area.
- Every option owns one persisted CanvasDocument. Preview and export render that document through the same rendering rules. Edits survive option switching. A failed render preserves the last good preview. Export never silently uses an older revision.
- Save reports success/errors, records the exact document handed off, and updates completion state. Share records completion only after the system reports success.

## Generation contract
- Imported layouts remain vocabulary within LayoutResolver. Preserve one carousel aspect and the photo-only baseline.
- Classify layout needs from intended hierarchy and grouping; the presence of a hero role alone must not exclude balanced pairs/groups.
- Seam layouts require explicit seamless story intent. A wide source image alone is insufficient. Protect faces/people from crops and slide seams; keep the 65% crop-retention floor.
- Composer evaluation, candidate judging and final rendering receive the same vocabulary and seed. Preserve planned stamps/decorations safely, or fall back when a template cannot support them.
- Persist template provenance and backgrounds through conversion to editable documents. Preserve original rendering treatment when an edit adds text or changes a photo.
- Keep fallback behavior for unavailable/incompatible libraries. No separate template pipeline or forced designed option.

## Verification
- Focused tests cover balanced layouts, explicit seam intent, crop/face safety, template provenance and render preservation.
- Exercise create → select → direct edit → switch options → return → undo/redo → save/share. Compare preview/export from the same revision.
- Build the iOS target and run package tests; investigate the intermittent legacy rerender test. Inspect an iPhone-size screenshot before installing the build.
