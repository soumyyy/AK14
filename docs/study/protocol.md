# AK14 Phase 0 — Study Protocol

**Status:** Frozen for recruitment. Re-freeze this document if any version below changes.

## Question

Given someone's own 200–2,000 photos from one meaningful event, does AK14 produce a carousel concept they actually want to post?

## Cohort

- 12–15 target users (see the product spec §2), each bringing **one** genuine high-volume event: a trip, birthday, night out, concert or similar.
- Each participant is known only by a pseudonymous study code, e.g. `P07`. No names appear in any AK14 artifact.

## Procedure (per participant)

1. **Consent:** read them `docs/study/consent.md`, which is the same text `ak14 run` shows.
2. **Intake:** export the event from their iPhone as unmodified originals with location, then AirDrop it to the operator Mac (see the operator guide).
3. **Run:** `ak14 run <folder> --study-code P07`, and answer the consent prompt.
4. **Review:** open the run in Studio together. The participant compares Plain Dump, Designed and Wildcard, makes only the allowed edits (reorder, swap, remove, reroll layout), and clicks **Use this** on their choice.
5. **Hand-off:** export or share the chosen concept to their phone.
6. **Day 7:** record the follow-up with `ak14 followup <runDir> --posted yes|no …`.
7. **Deletion:** delete their data when the study ends, or earlier if they ask (see Retention).

A human-made reference carousel may be produced separately to estimate the design ceiling. It is never counted as a pipeline result.

## Pre-registered go/no-go bar

Computed with `ak14 study summary`. Each participant's **first eligible** run is the study run: completed, consented, and with concepts. Later eligible runs count as repeat demand. Runs without consent, and failed runs, are reported separately and never counted. Metrics are scored on the exact plan that was handed off (snapshotted at export or share of the selected concept), not on later edits.

| Signal | Definition | Bar |
|---|---|---|
| **Minimum** | Selected a pipeline concept **and** exported or shared it **without substantially rebuilding** it | ≥ 50% of participants |
| **Strong** | Actually posted a pipeline carousel within 7 days (self-reported at follow-up) | ≥ 33% of participants |

**Substantially rebuilt** (fixed before recruitment) means that, for the selected concept, more than 30% of its original photos were swapped out or removed, **or** more than 30% of its slides were re-laid out. A layout reroll counts as re-laying out every slide.

- **Sensitivity:** the summary also reports the minimum signal under 20% and 40% rules.
- **No redefinition:** the rule is not redefined after seeing results.

**Also reported:**
- concept picks (Plain, Designed, Wildcard), which show design lift against the Plain control
- median share of photos changed (edit burden)
- repeat demand: the participant ran another event, or said at follow-up they'd reuse AK14
- mean model cost and Director time

A Plain win is valid evidence, not a failure.

## Posting verification

The participant self-reports at day 7, including how many days after hand-off they posted (`--posted-days`). A post counts only if it was 0–7 days after hand-off and the selected concept was exported or shared. The operator may look at the post if the participant shows it (`--link-seen yes`), but the URL is never stored. A share is logged only when the macOS share actually completes, not when a service is picked.

## Frozen versions

| Component | Version |
|---|---|
| analyzer | vision-2 |
| thumbnailer | thumb-1 |
| reduction | reduction-1 |
| model | gpt-6-luna |
| pricing | openai-2026-09 |
| prompts | triage v1+40dfc3c0 · planner v1+536bde51 · repair v1+9c346c59 · mutation v1+292c7a41 |
| style pack | starter-editorial@1.0.0 |
| resolver / renderer | layout-1 / render-1 |
| report | report-1 |
| disclosure | disclosure-1 |

Check before each session with `ak14 versions`. Every run also records its versions in `manifest.json`.

## Privacy and retention

- Originals, analysis and rendering stay on the operator Mac.
- The only data sent out is small thumbnails and text notes for up to about 100 shortlisted photos, sent to OpenAI's API. Per OpenAI's current API terms, API data isn't used for training and may be kept up to 30 days for abuse monitoring. **Verify the current terms before recruiting.**
- Run folders contain photo thumbnails. They stay local, are never uploaded or shared, and are deleted with `ak14 delete <runDir> --purge-cache` at the end of the study or on request.
- The participant's exported photo folder (`IMG/`-style intake) is deleted with their run.
- No GPS coordinates, absolute paths or names are written into run artifacts. The source folder location lives only in Studio's app preferences.
