# Full 17V28 templates: type, frames and full-bleed pages

Status: approved direction (2026-09-27). Owner: "I would not post any of these… it does not use the designs and templates we gave it; the output is very plain."

## Why the output is plain
1. The AI calls were being blocked (Worker daily cap). Fixed separately.
2. **We imported only the photo boxes.** 17V28 pages are mostly full-bleed photos with typography over them (for example "trip recap" and "one day in copenhagen" in script or serif faces), frames and paper cut-outs, and tight grids. The DS-1 import kept only the slot rectangles and painted them on white, and "hero.clean" puts every other photo on a white card.

The reference is `/tmp/17extract/previews/template-N-thumb.png`, extracted from the installed app's Assets.car. It is for review only and is never committed.

## Scope (phase A: everything available locally)
Decorative image layers (paper, tape, stickers) live in on-demand packs that are not on this Mac. They are phase B and depend on the owner's files. Phase A uses what the template JSON already describes:

| 17V28 layer | Count | Phase A |
|---|---:|---|
| photo placeholder (`placeholderCenter/Size`, `cornerRadius`) | 1,138 + 65 | yes (already slots; add corner radius) |
| text (`text.{text,fontName,fontSize,textColor,textAlignment,lineSpacing,letterSpacing,numberOfLines}`, `center`, `size`, `scaling`, `rotation`) | ~1,190 | **yes** |
| frame (`frameImage`, `frameCenter`, …) | 537 | **yes** (frames were extracted in FR-1) |
| decorative image (`image`, `imageExtension`) | ~1,630 | no (phase B); record the geometry only |
| `backgroundColor` | 231 | yes |

## Rules
1. **Text is never invented and never copied.** 17V28's sample strings ("my favorite", "iced latte season!!") are never rendered. Each imported text layer gets a role:
   - `title`: the largest text on the page
   - `caption`: smaller text
   - `accent`: emoji or symbols only
   It is filled as follows:
   - `title` ← `Direction.titleIdea` (the model's title, at most 40 characters, grounded in the owner's story hint). With no titleIdea, use the owner's story hint only when it is 3–28 characters; otherwise drop the layer.
   - `caption` ← the capture date of the photos on that page, formatted like "29 may" (lowercase, matching the template's casing style). Use a place only if the photo has an owner-confirmed place (currently never). Otherwise drop the layer.
   - `accent` → dropped.
   A page whose title layer is dropped still works: every template must look complete without its text.
2. **A title appears once per carousel,** on the first slide that can host it, and preferably slide 1. Captions: at most 2 per carousel.
3. **Decor-dependent templates are excluded.** If a template's decorative image layers cover more than 12% of the page area, or sit under or over a photo slot, the page would look broken without them. It is excluded from the vocabulary until phase B. The importer records `decorCoverage` for this check.
4. **Fonts:** map each `fontName` to a bundled font. Add the missing OFL faces from Google Fonts with their licences and manifest entries: Pinyon Script, Cedarville Cursive, Outfit, Ballet, Special Elite. Map Inter-*, Roboto-* → Inter; DotGothic16 → DotGothic16; InstrumentSerif(-Italic) → Instrument Serif; AmaticSC → Amatic SC; Anton → Anton. Any other font maps to the closest bundled face, and each mapping gets a comment.
5. **Full-bleed first:** a single photo that a statement template (one slot, optionally with type) can host at ≥65% crop retention with faces safe uses that template instead of "hero.clean". The white card remains the fallback.
6. **A coherent family per carousel.** `categoryId` is the template's family. For each non-baseline carousel, choose one family (seeded by the plan id plus the layout seed, weighted by the style axes: `decoration == "none"` prefers families whose pages mostly have no text; otherwise families with text and frames). Prefer that family's pages across the carousel, falling back to others when no page in the family fits. Families are internal vocabulary and never shown to the user.
7. **Safety is unchanged:** the 65% crop floor, facesFit, no subject across a seam, and the seam only with `direction.seamless`. Text must not sit over a detected face: shift it within the page by the template's safe area, or drop it.
8. **Rendering:**
   - text layers render multi-line (CTFramesetter), with rotation, letter spacing and line spacing, deterministically
   - frame layers draw the frame PNG over the slot
   - slot corner radius clips the photo
   - `backgroundColor` fills the page
   - the legacy byte-parity test still covers bridge conversions
   - template documents render natively (already the case)
   - the editor can edit the title text: it is a normal text layer in the CanvasDocument

## Deliverables
- The importer: `tools/import-17v28/` gains text, frame, corner-radius, background, `categoryId` and decor-coverage extraction. `designed-sets.json` is regenerated, and its version is bumped.
- `DesignedSet` gains optional `texts`, `frames`, `cornerRadius` per slot, `family`, `decorCoverage`. Old files still decode.
- `TemplateVocabulary` fills text and frames, chooses the family, and prefers statement templates. `ResolvedElement` gains the ability to carry text styling (font, size, colour, alignment, spacing, role), or a new element kind, so documents carry editable text.
- `DocumentRenderer`: multi-line text, frames, corner radius, background.
- Tests (e2e):
  - importer output validity
  - a title appears once and only from `titleIdea` or the hint
  - no 17V28 sample string appears in any resolved slide
  - decor-heavy templates are excluded
  - the family is consistent within a carousel
  - rendering is deterministic
- A review script: `ak14 rerender <run> --source IMG --recompose` on the 8 IMG runs, then contact sheets. The rate of landscape-on-white and hero.clean pages must drop substantially from 46%.

## Phase B (blocked on assets)
Decorative image layers: ship them only with the owner's files, via the Worker asset route (`/v1/assets/<sha>`), under the permission recorded in docs/design/designed-pages-grammar.md.
