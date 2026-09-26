# M6 — Study Readiness

> Execute inline. Per the user: no unit tests; verify with e2e tests and a dry run on `IMG/`.

**Goal:** An operator can run the Phase 0 study end to end:
1. consent and disclose
2. run a participant's folder under a pseudonymous code
3. review and edit in Studio
4. transfer to the participant's phone
5. record the day-7 follow-up
6. compute the go/no-go bar across the cohort
7. delete a participant's data on request

**Spec:** §1.3 (success criteria, the 30% rebuild rule and its sensitivity), §9.1 (`--study-code`), §10.5 (privacy and retention), §12 M6, and the product spec's §46 go/no-go bar.

## Build

1. **Study code and consent** (`ak14 run`)
   - `--study-code P07` is stored in `manifest.studyCode` and shown in the report. Codes must match `^[A-Za-z0-9_-]{1,16}$` (no names).
   - Before the first model call, the CLI prints the provider disclosure: what leaves the machine, where it goes, and retention. It then asks `Send thumbnails? [y/N]`. `--yes` skips the prompt for scripted runs. Without consent, the Director stage is skipped with status `skipped: no consent`.
   - `manifest.consent` records `{acknowledgedAt, disclosureVersion}`.
2. **Crash visibility**
   - `manifest.json` is written with `completedAt = nil` as soon as the run directory exists, and rewritten at the end.
   - The Studio run list, `study summary` and `report` treat a run with no `completedAt` as incomplete: shown as such, never counted.
   - Re-running the folder reuses all cached local work.
3. **Follow-up** (`ak14 followup <runDir> --posted yes|no [--platform instagram|other] [--reused-another-event yes|no]`)
   - Appends a `followup_recorded` event with days since the last export.
   - No post URLs or free text are stored, only whether a link was shown to the operator (`--link-seen yes|no`).
4. **Cohort summary** (`ak14 study summary [runsDir] [--out DIR]`)
   - For each completed run with a study code, it computes:
     - selected concept (last `concept_selected`)
     - exported/shared
     - rebuild metrics for the selected concept vs its original: `photoChangeFraction` = |original photos not in final| / |original photos|, and `slideRelayoutFraction` = fraction of slides whose photos changed, or 1.0 if the concept was rerolled
     - substantially rebuilt at 20%, 30% and 40%
     - posted within 7 days (from follow-up)
     - repeat demand (the same study code with 2 or more runs)
   - Cohort:
     - the minimum signal: at least 50% selected and exported/shared without substantial rebuild at 30%, with the 20% and 40% sensitivity alongside
     - the strong signal: at least 33% posted within 7 days
     - Plain/Designed/Wildcard picks, median edit burden, cost and latency
   - Writes `study-summary.json` and `study-summary.md`. Participants are identified only by code.
5. **Deletion** (`ak14 delete <runDir> [--purge-cache]`)
   - Removes the run directory.
   - With `--purge-cache`, also removes the thumbnails, features and feature prints cached for that run's photos, unless another remaining run still uses them.
6. **Versions** (`ak14 versions`): prints every component version, for freezing into the protocol.
7. **Docs** (`docs/study/`)
   - `protocol.md`: the pre-registered bar, the 30% rule with its 20%/40% sensitivity, cohort, schedule, frozen versions, retention and deletion
   - `operator-guide.md`: export from iPhone with metadata, AirDrop in, run, Studio, AirDrop the slides back, posting, day-7 follow-up, deletion
   - `consent.md`: the participant-facing plain-language consent, matching the CLI disclosure text

## Verify

- E2E tests:
  - no consent means no model calls
  - a study code is recorded, and invalid codes are rejected
  - an incomplete run is excluded from the summary
  - follow-up events are recorded
  - summary metrics are correct for a scripted cohort: 3 participants, one of whom rebuilds heavily and one of whom posts
  - delete with purge removes only unshared cache entries
- Dry run on `IMG/`: `run --study-code DRY01`, Studio-equivalent edits through `RunSession`, export, follow-up, summary, then delete.
