# Creative Studio Design: 17V28-level output, a canvas editor, and exact photo sets

Status: approved direction (2026-09-27, owner request). This builds on the [composer engine](2026-09-26-composer-engine-design.md) and the [taste engine](2026-09-26-taste-engine-design.md).

**Change of direction:** it reverses product spec §29 ("the editor is not the product"). The AI still makes the first draft automatically, but the user can then finish it in a real layer editor.

## 1. Goals

1. **Automatic output at the level of 17V28** ([App Store](https://apps.apple.com/us/app/17v28-creative-carousel/id1636313936)): seamless carousels, scrapbook, film, minimal, grid, journal and recap looks, with typography, stickers, film frames and textures. Everything is produced by the engine from the user's photos and the model's directions, with no manual template picking.
2. **A canvas editor on iPhone** for photos and the canvas: move, resize, rotate, layer order, crop, replace, photo adjustments, text, stickers and backgrounds, with undo and redo.
3. **Exact photo sets:** the user can hand AK14 exactly the photos they want in the carousel, either picked in the app or shared from the Photos app. The AI then orders and designs them without dropping any.

## 2. Principles

- **Recipes are data, not code.** Looks are described in StylePack data (geometry slots, asset references, type styles), so new looks ship by remote config.
  - The composer chooses among recipes from the direction's style axes.
  - Recipes are design vocabulary, never user-facing concept names; options stay neutral "Option N" (see the no-named-types decision).
- **One document model.** Generation, editing and export share a single `CanvasDocument`. The renderer draws documents. The editor edits documents. Nothing is rendered twice in different ways.
- **Deterministic and safe by default.** Generated documents keep the existing face, people, crop and legibility rules. The user may override anything in the editor; that is their choice.
- **Licensed assets only:**
  - fonts: SIL OFL or Apache
  - stickers and textures: made by us, procedural or hand-drawn vector
  - every asset is listed in the asset manifest with its licence
  - no scraping of 17V28 or anyone else's assets

## 3. The document model: `CanvasDocument` (Core, new)

```text
CanvasDocument { id, aspect, slideCount, seamless: Bool, background: Fill,
                 layers: [Layer], recipeID, stylePackPin, sourcePlanID, version }
Layer { id, kind: photo|text|sticker|shape|texture, frame (document space), rotation,
        z, opacity, locked, slideHint?,
        photo:   { assetID, crop, adjustments {exposure, contrast, warmth, saturation, grain, filmLook}, border, shadow, mask(rect|rounded|torn) }
        text:    { string, fontID, size, colour, alignment, tracking, lineHeight, background? }
        sticker: { assetID, tint? }
        shape:   { kind: rect|roundedRect|line, fill, stroke }
        texture: { assetID, blend, intensity } }
Fill = colour | gradient | photo(assetID, blur, dim) | paper(assetID)
```

- **Document space.** It spans `slideCount × slideWidth` by `slideHeight`. When `seamless` is true, layers may cross slide edges and export slices the one canvas into slides. When it is false, each layer belongs to one slide. The document can then be sliced the same way, which keeps the model uniform.
- **Conversion.** `ResolvedCarousel → CanvasDocument` is lossless for today's layouts: photo elements become photo layers, tape and stamp elements become sticker and text layers. Old runs therefore open in the editor.
- **Rendering.** The `Render` module draws a `CanvasDocument` to slide PNGs. It must be byte-deterministic for the same document and sources. `CarouselRenderer` becomes a thin wrapper that converts and then renders.
- **Storage.** Documents live in `documents/<optionID>.json` inside the run. Edits write a new version of that file. The originals under `plans/` and `layouts/` are never modified.

## 4. Automatic quality: recipes, seamless layout, type and assets

**Recipes** (`StylePack.recipes`). A recipe is a parametric page design, not a fixed template. It has:
- slot rules: photo slots with aspect ranges, bleed or inset, overlap, rotation range and mask
- a text slot (title, date, place or caption, from the owner's story hint and event data, never invented)
- sticker and texture budgets, a background fill rule, and seamless-flow rules (which slots may cross slide edges)

The first set of families:
- **Minimal** (clean bleed and white space, one line of type)
- **Film** (film frames, grain, date imprint)
- **Scrapbook** (paper, tape, torn masks, stickers, handwriting)
- **Grid** (strict gutters)
- **Journal** (paper plus handwriting plus small prints)
- **Recap** (a cover title plus a dense collage)
- **Seamless panorama** (one wide canvas, photos flowing across edges)

**Selection by axes.** The composer maps a direction's StyleVector onto a recipe family, for example:
- decoration rich + rotation some → scrapbook or journal
- decoration light + whitespace airy → minimal or film
- grouping collage + density dense → grid or recap
- overlap bold + a seamless flag → seamless panorama

It then fills the slots with the existing scoring: crop, faces, legibility, colour harmony and hierarchy. The model may ask for seamless or typography through two new direction fields: `seamless: Bool` and `titleIdea: String?` (at most 40 characters, grounded in the story hint).

**Seamless layout.** The composer plans across the whole canvas. It places slot groups so that some photos straddle slide boundaries, with safety rules:
- no face is ever cut by a slide edge
- each slide stands on its own when viewed alone
- the first slide works as a cover

**Typography.**
- Bundle 6–8 OFL fonts: an editorial serif, a clean grotesk, a mono, two handwriting fonts and a condensed display font.
- Text is only ever the owner's words (story hint or title), dates and places the owner confirmed, or short model-suggested titles grounded in the hint.
- Captions are off by default. The owner can edit every string.

**Assets.**
- A first-party kit of about 60 vector or procedural pieces: tapes, paper scraps, torn edges, film frames (35 mm and instant), doodles, stars, arrows, hearts, labels, light leaks, grain and dust.
- All are generated by our own code or drawn as SVG paths in the repo.
- They are listed in `Resources/Assets/manifest.json` with licence "first-party".
- More packs can ship remotely through the Worker's asset route.

**Photo looks.** Per-photo adjustments (exposure, contrast, warmth, saturation, grain, film look) and a light, carousel-wide grade so adjacent slides feel like one edit. These come from the Sol review.

## 5. The editor (iOS)

- **Opening it:** from any option, "Edit" opens the canvas: a horizontal scroll across the whole document, with slide boundaries shown.
- **Gestures:** tap to select a layer, drag to move, pinch to resize, two-finger rotate, and double-tap a photo to crop inside its frame. Snapping to slide edges, centres and other layers, with haptics.
- **Toolbar:**
  - Photo: replace (from the run's photos or the library), crop, adjust, mask, border
  - Text: add or edit, font, size, colour
  - Stickers: kit browser
  - Background: colour, photo or paper
  - Arrange: forward, back, front, back-most; lock
  - Slides: add, remove, reorder
- **History:** undo and redo with a history of at least 50 steps. Autosave to the run's document.
- **Export:** Save to Photos and Share, as today. Every edit is logged as interaction events: `layer_moved`, `layer_resized`, `text_edited` and so on, which feed preference memory.
- **Rendering while editing:**
  - The editor shows a live SwiftUI canvas that mirrors the document.
  - Export uses the deterministic `Render` path.
  - A preview-versus-export parity check runs in UI tests.

## 6. Exact photo sets

- **In the app:** the photo picker has a switch: "Choose the best from these" (today's behaviour) or "Use exactly these".
- **Share extension:** an iOS Share Extension, "AK14". Selecting photos in Photos and sharing to AK14 copies them into the app group container and opens AK14 with those photos pre-selected, in exact mode.
- **Exact mode in the engine** (`RunOptions.exactSet` on the Mac, `--exact`; a `StoryPipeline` flag on iOS):
  - Every selected photo is used. Reduction only analyses; it never drops a photo.
  - Event splitting is skipped: the user's set *is* the story.
  - The Director gets `exactSet: true`. The spine must contain every photo, and the model orders them and proposes directions. Triage and planner prompts gain a rule for this.
  - The composer places every photo; grouping may put several on a slide.
  - A requested slide count is honoured by grouping, never by dropping photos.
- **Order:** by default the model's story order. The user can choose "Keep my order" (the selection order), which is then fixed.

## 7. Fit with the rest of the app

- **Taste engine:** the judge ranks rendered documents, not just layouts. The eval set gains document-level A/B pairs, and editor interactions feed preference memory.
- **Worker:** serves recipe packs, fonts and sticker packs as versioned assets.
- **StylePack:** gains `recipes`, `fonts` and `assets`, all validated and pinned per run.
- **Mac Studio:** it gets read-only document preview. Editing is iOS-first.

## 8. Tasks (for Luna, in isolated worktrees; each is reviewed, verified and merged by Claude)

| ID | Task | Area | Depends on |
|---|---|---|---|
| CS-1 | `CanvasDocument` model, `ResolvedCarousel` → document conversion, and a document renderer (deterministic, byte-identical to today's output for converted layouts) | Core + Render | — |
| CS-2 | Exact photo sets: Mac `--exact` and `--keep-order`, Director `exactSet` (prompt rules; the spine must include all), composer places all, e2e tests | Core + Director + CLI | — |
| CS-3 | iOS "Use exactly these" / "Keep my order" and a Share Extension target (app group handoff) | iOS | CS-2 |
| CS-4 | Asset kit v1: about 60 first-party vector and procedural stickers, textures and film frames; 6–8 OFL fonts with licences; manifest; rendering support for sticker, text, texture and mask layers | Render + Resources | CS-1 |
| CS-5 | Recipes v1 (Minimal, Film, Scrapbook, Grid, Journal, Recap) in StylePack data, plus a recipe filler in the composer that uses the existing scoring; direction fields `seamless` and `titleIdea` | Core + Director + StylePack | CS-1, CS-4 |
| CS-6 | Seamless panorama: cross-slide layout with the edge-safety rules, and slicing on export | Core + Render | CS-1, CS-5 |
| CS-7 | iOS canvas editor v1: select, move, resize, rotate, crop, replace, text, stickers, background, arrange, undo/redo, autosave, export, interaction events | iOS | CS-1, CS-4 |
| CS-8 | Photo looks: per-photo adjustments and a carousel-wide grade | Render + editor | CS-1, CS-7 |
| CS-9 | Quality gate: a GPT-6 Sol review of rendered outputs against 17V28-style references, and taste-eval pairs | Review | CS-5, CS-6 |

Parallel lanes: CS-1 and CS-2 now; then CS-3, CS-4 and CS-7 (skeleton); then CS-5 and CS-6; then CS-8 and CS-9.
