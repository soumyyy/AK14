# Template generation and inline options: V1 spec

## Goal

AK14 automatically applies suitable layouts from its bundled designed-set library while building story options. A person can select an option and edit its design directly on the options screen, then save or share the current result.

## Current state

- `designed-sets.json` contains 104 validated geometries (77 templates and 27 layouts). `LayoutResolver` fills the eligible ones when a caller passes them as vocabulary. The baseline does not.
- Resolved slides persist per run. The options screen edits the rendered option in place.

## Decision (2026-09-27)

The earlier window-paste path, the `local-designed` option, and adopting a set's aspect for the whole carousel are withdrawn. There is one resolver. The model still returns a spine and style directions. Planner v9 describes the measured page grammar in words and does not name templates. The window-paste adapter is gone.

## Generation contract

1. Load and validate the bundled library once for a run. A missing or invalid library must leave normal generated options usable and record a warning.
2. Keep the photos-only baseline on the primitive path. For every other plan, pass every imported set of this carousel's aspect. Each set has a job. The photos pick that job. Layouts are not scored against each other.
3. For a consecutive group of planned slides, fill a vocabulary set when the expanded slot count matches the photos, without repeating an asset. The hero photo goes in the largest slot. Keep the set only when every crop retains at least 65% and faces fit, and no face or significant person is cut by a slide edge. Rank survivors by crop retention and hero size. A seam adds no points. The seed chooses among scores within 6 points. If none pass, that slide stays on the six primitives.
4. One carousel has one aspect. A set never changes it. Render with `CarouselRenderer`. The chosen set is recorded on the slide as `variant` `template.<id>`.
5. On-device generation without AI still produces the baseline plus directions. It does not add a special designed option.
6. A template may be used only when its aspect, slide window and photo count fit. Never stretch a set into a different aspect or leave a photo placeholder empty. A clean existing layout is the fallback.

## Options screen contract

1. The selected option opens on the same navigation screen in an editable canvas; tapping a photo or text layer selects it, and the controls beside or below the canvas act on that selection. No separate Edit or Edit design button, sheet, or route is needed.
2. Options remain easy to compare through a compact horizontal picker with visible selected state and useful labels. The canvas gets most of the screen. A slide strip or page control shows position and allows direct navigation. The main actions stay reachable in the bottom safe area.
3. Editing a selected option is local to that option. Changes persist when switching options, update its preview, and support Undo/Redo. Save and Share export the latest document state. Slide arrangement and photo replacement/removal controls should be reachable from the same screen, without a separate editing sheet.
4. While a render or edit is running, show local progress and prevent conflicting actions. Preserve the last good preview on failure and show a specific error. Respect Dynamic Type, VoiceOver, reduced motion, minimum touch targets and safe areas.
5. Use native SwiftUI controls, system typography and materials. Let the photographs be the visual focus; remove redundant headings, tiny toolbar glyphs and repeated status copy.

## Acceptance checks

- A creative option records `template.<id>` on a slide when a vocabulary set fits, and the same seed repeats that placement. The baseline does not.
- Selecting an option shows its editable design in place; changing an element, switching options and returning retains the change.
- Saving and sharing after an edit use the changed slides, not the original rendered PNGs.
- The baseline and incompatible photo collections still render; malformed designed-set data never leaves a half-written run.
- iPhone build succeeds and the flow is exercised on an iOS simulator or device.

## Scope decisions

- The library supplies geometry; automatic stickers and extra typography are deferred until photo placement, inline editing and export are reliable.
- Existing runs remain readable; new document and template metadata are additive.
- Template choice is automatic in V1. Manual browsing of all 104 sets is a later feature.
