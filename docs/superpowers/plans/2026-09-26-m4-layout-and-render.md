# M4 — Layout Resolver and Designed Rendering

> Execute inline. Per the user: no unit tests; verify with e2e tests in `Tests/CLITests` and real runs on `IMG/`.

**Goal:** Every concept (Plain, Designed, Wildcard) renders to deterministic PNG slides. A pure-geometry `LayoutResolver` turns the model's intent into exact frames, crops, rotation and z-order. A single `CarouselRenderer` draws them with a procedural style layer and a bundled date-stamp font.

**Spec:** §7 (resolver), §8 (renderer, StylePack, asset manifest), §9.3 (layouts/, slides/), §11.3 (determinism), §12 M4.

## Global Constraints

- The resolver is in `Core`, uses Foundation only, and is deterministic. The seed is a SHA-256 of `runID + conceptType + resolverVersion`, fed into a SplitMix generator. The same inputs and seed always produce the same layout JSON and the same PNG bytes.
- Geometry is normalized with a top-left origin, and is ratio-agnostic. Export sizes: 3:4 is 1080×1440, 4:5 is 1080×1350, 1:1 is 1080×1080.
- Margins: 4–7% of the canvas short side, from the StylePack's `spacingRanges`. Full-bleed edges are exempt.
- Rotation: photo panels up to ±2°, decorations up to ±4° (StylePack `allowedRotations`). Full-bleed photos never rotate.
- Overlap is allowed only in `inset`, `asymmetric_pair` and `overlap_cluster`. Every covered photo keeps at least 55% visible (StylePack `minimumVisibleFraction`), and no upper frame covers a lower photo's face box.
- Crop priority: hero face visibility, then person visibility, then saliency, then crop intent.
- The resolver may downgrade a primitive, with a warning, when a plan violates its constraints. It never invents a primitive.
- Decorations are procedural (grain, paper, tape, film edge), so there is no licensing surface. The date stamp uses bundled DSEG7 Classic Bold (SIL OFL 1.1). Every asset is listed in `Resources/Assets/manifest.json`.
- Location stamps are omitted with a warning. Turning GPS into a place name needs a network geocoder, which Phase 0 privacy excludes.
- Date stamps use the photo's capture date in the current time zone, formatted `'YY MM DD` (film-camera style). If the photo has no date, the stamp is omitted with a warning.

## Tasks

1. **Core/Layout:**
   - `ResolvedElement`, `ResolvedSlide`, `ResolvedCarousel`
   - `SeededRandom`
   - `CropPlanner`: cover crop toward a focus. This replaces `PlainRenderer.coverCrop`.
   - `LayoutResolver` with rules for all six primitives, face-safe overlap placement, decoration and stamp placement, and downgrade warnings
2. **Render:**
   - `StyleLayer`: procedural paper, grain, tape and film edge
   - `StampRenderer`: DSEG7 date text via CoreText, with the font loaded from bundle data
   - `CarouselRenderer`: draws resolved slides and replaces `PlainRenderer`, which becomes a thin wrapper
   - the asset manifest and the OFL license file
3. **Pipeline:**
   - Resolve and render all concepts into `layouts/<concept>/slide-NN.json` and `slides/<concept>/slide-NN.png`.
   - `ConceptsReport.renderedSlides[concept]`, decoded tolerantly for old runs.
   - The report shows every concept's slides.
   - `rerender` re-renders all concepts, with an optional `--seed`.
4. **E2E tests (fake model):**
   - Designed and Wildcard slides exist.
   - Rerender produces byte-identical PNGs.
   - Every non-full-bleed frame sits inside the canvas.
   - Visible fraction is at least 0.55 for overlapped photos.
   - No face box is covered by a higher element.
   - Date stamps are omitted gracefully for undated photos.
5. **Real run on IMG/:** look at every concept's slides by eye, fix any visual defects, and record the results.
