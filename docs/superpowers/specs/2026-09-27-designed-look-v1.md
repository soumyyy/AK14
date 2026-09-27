# Designed look v1: cover title, full-bleed pages, distinct options

Status: approved direction (2026-09-27). Owner: "I would not post any of these… very plain"; "it's just giving me one option."

Evidence, from 8 real IMG runs re-rendered with commit 0675ef5 (in /tmp/ak14-ft):
- **Photos on white cards:** 46% of direction slides are `hero.clean`, almost all of them landscapes. Portraits already go full-bleed.
- **No titles:** 0 titles rendered, although the model supplied a good `titleIdea` for every direction ("Days in the mist", "Above the tea hills", …). Few 4:5 templates carry text after the decor filter.
- **Near-identical options:** within a run, the options show the same photos in almost the same order. The owner reads that as "one option".

## 1. Cover title (carousel-level typography)
- Slide 1 of every non-baseline carousel shows `Direction.titleIdea` (or the owner's story hint when it is 3–28 characters). With neither, there is no title. Never show sample or invented text. The baseline never gets a title.
- **The cover photo is full-bleed.** Choose the cover's crop so a clear, low-detail region exists for the type. Measure it on the analysed photo: low edge density and low saliency, well away from faces and humans (`PhotoFeatures.faces` / `.humans` and saliency, if available). Candidate regions are top-left, top-centre, bottom-left, bottom-centre and centre, as bands of about 18–28% of the height.
- **Type styles.** Pick one deterministically from the layout seed. Each is a pure function of (title, region, luminance) → text element(s):
  1. **Script:** Pinyon Script or Cedarville Cursive, large (9–13% of the height), 1–2 lines.
  2. **Editorial serif:** Instrument Serif (italic for one word, optionally), 7–10% of the height, left-aligned, tight leading.
  3. **Small caps / mono:** Inter or DotGothic16, 2.8–3.5% of the height, letter-spaced 0.12em, uppercase. The date goes on a second line, smaller.
- **Colour:** white on a dark region (mean luma < 0.55), else near-black (#1A1A1A). There is no text box and no shadow. If the chosen region's contrast is too low (WCAG < 3:1 against the region's mean), try the next region, then the next style. If nothing works, show no title.
- The title is a normal text element (`kind .text`, `textRole "title"`), so it is editable in the editor.
- A title placed by a template counts: never two titles.

## 2. Full-bleed by default
In `ComposerEngine.choosePrimitive` (clean policy) and the matching resolver path, a single photo goes full-bleed when:
- **all** faces and significant humans fit inside the cover crop (`CropPlanner.facesFit`), and
- the salient subject box (if analysed) keeps ≥ 85% of its area inside the crop, and
- crop retention is ≥ 0.58. This covers 4:3 landscapes on 4:5, at 0.60 retention.
Otherwise the existing white card is used (16:9 panoramas, and group shots that would cut people). Keep the landscape-stacking bonus from 5dcc3e1, but a landscape that can go full-bleed no longer "floats" (update `floats`).

## 3. Distinct options
Options in one run must differ visibly:
- **Different covers** (already a rule; enforce it).
- **Photo overlap:** for any two directions, the Jaccard overlap of their photo sets is ≤ 0.7, or, when the pool is too small for that, their order differs by Kendall-tau distance ≥ 0.35.
- **Layout differences:** different template families, and at least one differing style axis in practice (density or grouping).

Enforce this in `ComposerEngine.composeSet` as a remedy after composition. If a pair is too similar, re-compose the later direction using:
- an unused strong pool photo as its cover
- its `orderedAssetIDs` rotated to start from a different story beat
- up to 30% of its photos swapped for unused, high-strength pool photos from the same event
Record a warning. Also tighten the planner prompt (`Sources/Director/Resources/Prompts/planner.system.md`) with one rule: "Each direction must use a different cover and a noticeably different selection or sequence; do not return two directions with the same photos in the same order."

## Verification
- E2E tests: the cover title is present with `titleIdea` and absent without it; the title avoids face boxes; the contrast rule holds; the baseline has no title; the full-bleed rule applies to 4:3 landscapes with faces fitting and not to people-cutting crops; the distinct-options remedy produces overlap ≤ 0.7 on a fixture; everything is deterministic.
- Real-photo check (free): `ak14 rerender <run> --source IMG --recompose` for every run in /tmp/ak14-ft/*/2026*. Report the hero.clean share (target < 15%), titles rendered per carousel, and the pairwise photo overlap between options.
