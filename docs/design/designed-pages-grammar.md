# Designed pages: design grammar (reference study, 2026-09-27)

Measured from 120 carousel templates of the reference app 17V28 (a study only: no templates, stickers or fonts copied; the owner's team holds those rights). These numbers are the brief for AK14's own designed-page library.

- **Base:** pure white (#FFFFFF) in 226/231 templates. No blurred photo backgrounds and no cream paper as the default base. Paper and texture are accents inside a page, not the canvas.
- **Seamless is the signature:** 38–63% of photo slots cross a slide edge. A carousel is designed as one continuous canvas of N slides. Slot groups flow across seams, and every slide still reads alone when viewed by itself.
- **Slot shapes:** mostly 4:5 portrait (median w/h 0.8) and square. Photos are cropped to their slot, and slots are not shaped to their photos. AK14 must use face-safe crops into slots.
- **Scale contrast:** the median slot covers about 16% of a slide and the top quartile over 50%. Pair a few large anchors with several small, rhythmic photos.
- **Bleeds:** the minimum margin is often 0; bleeding to the slide edge is normal. Where margins exist they are consistent (about 20% of slide width at most).
- **Overlap:** photo slots overlap in about 18% of templates. Use layering as an accent, not the default.
- **Rotation, stickers and type** are inside the templates' archives (not studied). AK14 uses its own kit: tape at photo corners, at most a few stickers per slide, and one type moment per carousel (a cover title or a date line), in the OFL fonts.

Rules for AK14 pages:
1. Designed pages are hand-authored as data (unit-space slots, text slots, sticker anchors, seam behaviour), never generated procedurally.
2. A page is used only when the photos fit its slots after face-safe cropping (people kept whole, crop at most about 35%). Otherwise the photo gets a clean full-bleed or white-border slide.
3. Each designed set is 1–3 slides. The resolver may use one for every group whose photos fit. Slides that do not fit stay clean.
4. Every page ships only after it has been rendered with real photos and reviewed by eye.

## Engine note (2026-09-27)

The 104 imported sets are vocabulary for `LayoutResolver`. The planner prompt (v9) describes this grammar in words: mostly white, one large photo, smaller photos as rhythm, a photo crosses a slide edge only as one continuous moment, and photos on a page belong to the same moment. The model still returns a spine and directions. It does not return template ids or coordinates. Every set of the carousel's own aspect is available. Its slots say what it is for, and the photos pick that job. A crop that would cut a face refuses the set. If none fit, the slide stays a full bleed or the other primitive. The photos-only baseline does not use the vocabulary. A set does not change the aspect of slides outside its window, because one carousel has one aspect.

## Permission (2026-09-27)
The owner states that the 17V28 account owner (the team) permits AK14 to use 17V28's templates and assets. On that basis AK14 may convert 17V28 template geometry (photo placeholders, frames, layouts) into its own designed-set format. Keep the written confirmation from the account owner on file. Raw 17V28 files are not committed; only converted AK14 data is. Decorative assets (stickers, frames, fonts that are not OFL) come from the team's source files, with their provenance recorded in the asset manifest.
