# Taste Engine Design

Status: approved direction (2026-09-26). Supersedes the "V1 = instrumentation only" note in product spec §38 and gives §39 (novelty) a concrete home. Builds on the [composer engine](2026-09-26-composer-engine-design.md).

## 1. Goal and principles

AK14 should pick the carousel a person would actually post, and get better at it over time without our training models.

Taste has three layers, and each has a different owner:

| Layer | Question | Where it comes from |
|---|---|---|
| General quality | Is this a good carousel at all? | Frontier multimodal models, used as judges at inference time |
| Personal preference | Which of several good options would *this* person post? | A small preference memory built from their own choices |
| What is current | What looks fresh this season? | Versioned, remotely updatable StylePack content, approved by the owner |

Principles (owner decisions, not reopened here):

- **No training or fine-tuning.** Taste lives in data: written principles, reference images, preference notes, human labels. Models read it in their context window. A better model therefore makes the whole system better with no code change.
- **Measure everything against humans.** A human-labelled eval set is the single yardstick for any change to prompts, models, weights or style packs. It is the durable asset of this project.
- **Generation stays cheap and deterministic; judgement goes to the model.** The composer produces many safe candidates for free. The model only ranks them.
- **Safety is never delegated.** Face and people protection, crop limits and social-safety flags stay in deterministic code and veto any judge decision.
- **Pairwise, not scores.** People and models are both far more reliable at "A or B?" than at "rate 1–10".

## 2. Architecture

```
Photos ─► analysis ─► reduction ─► Director: spine + 2–5 directions
                                          │  (+ preference notes, reference images)
                                          ▼
                       Composer: N safe whole-carousel candidates per direction  (free, deterministic)
                                          │
                                          ▼
                       NEW Judge: model ranks rendered candidate strips pairwise
                         reads: StylePack constitution + reference images + trend notes
                                + the user's preference notes
                                          │  (safety veto stays in the composer)
                                          ▼
                       render ─► review / edit ─► export / share
                                          │
                                          ▼
                       interaction log ─► PreferenceProfile (on device, optional sync)

 Eval set (human A/B labels) ─► `ak14 eval score` ─► agreement with humans ─► gates every change
 Worker cron (monthly) ─► trend notes ─► StylePack draft ─► owner approves ─► remote rollout
```

Where each piece lives:

| Piece | Mac engine (`Core`, `Director`, `Render`, `CLI`) | iOS app | Cloudflare Worker |
|---|---|---|---|
| Candidate pool | `ComposerEngine` | same code | — |
| Judge | `Director` stage `judge` | calls through `WorkerTransport` | proxies `/v1/responses` under the existing caps |
| Constitution, references, trend notes | `StylePack` fields, pinned per run | same, via `StyleConfigClient` | `/v1/config`, reference images in R2 |
| Preference memory | `PreferenceProfile` built from `InteractionLog` | stored on device | optional sync, keyed by an anonymous user id |
| Eval set and labels | `ak14 eval …` | — | optional rater page for scale |
| Trend refresh | — | — | scheduled job, owner approval endpoint |

Every run records what shaped it in `manifest.versions`: `judge` (prompt version and model), `stylePack`, `preferenceProfile` (version and evidence count), and `taste` (the config hash). The eval harness can then attribute any quality change.

## 3. Eval set and labelling (build first)

**Why first:** without it, every later change is a guess.

- **Eval set** (`Core/Taste/EvalSet.swift`): about 10 real, consenting events. Each event is stored as an existing run directory, referenced by path in `eval/evalset.json`, never committed to git. An `EvalPair` is `{pairID, runID, left: CandidateRef, right: CandidateRef}`, where a `CandidateRef` names a carousel id plus its composition seed. That is enough to re-render it deterministically.
- **Pair generation** (`ak14 eval pairs <runDir>…`): for each run, render low-res strips (all slides side by side, 1 image per carousel) for the options and for alternative composer candidates. Emit pairs that differ in meaningful ways: different directions, the same direction with different candidates, and each direction vs the baseline. Sides are randomised and recorded.
- **Labelling page** (`ak14 eval label <evalDir>`): writes a self-contained static HTML page showing one pair at a time with "Left / Right / Can't choose", plus keyboard shortcuts. Labels save to the browser's local storage and export as `labels-<rater>.json`. `ak14 eval import` merges them. This is the owner's path: no server and no uploads.
- **`EvalLabel`**: `{pairID, rater, choice: left|right|tie, shownLeft, decidedAt, versions}`.
- **Scoring** (`ak14 eval score [--config taste.json]`): runs the configured chooser (the composer alone, or composer plus judge with a given prompt and model) on every labelled pair. It reports agreement with human majority labels, a bootstrap 95% confidence interval, per-event breakdowns and cost, and writes `eval/report-<timestamp>.md`. Ties are excluded from agreement and reported separately.
- **Scaling later (optional):** the Worker can serve the same page to paid raters (for example via Prolific, targeting people who post carousels). Only the owner's consenting events are used, never public or scraped photos.

Success criteria: the composer-only baseline agreement is measured and recorded, so every later task has a number to beat.

## 4. Model judge (build second)

- **Candidate pool:** `ComposerEngine.compose` already evaluates `candidateCount` whole compositions per direction. Expose the top-N safe ones as `[Composition]`, ranked by the composer score (N = 6 by default, taken from the StylePack). Any candidate that the composer's safety terms flag (people cut, faces covered, visibility failures) is removed before judging.
- **Strips** (`Render/StripRenderer.swift`): one small JPEG per candidate, with all slides in a row, about 96 px per slide height. It is deterministic, and it is the only image the judge sees for that candidate.
- **Judge stage** (`Director/Judge.swift`, prompt `judge.system.md`, strict JSON schema):
  - The input is the strips of one direction's candidates in randomised order, plus the constitution, up to 6 reference images, the trend notes and the user's preference notes.
  - The output is `{ranking: [candidateIndex], reasons: [shortTag]}`. Reason tags come from a fixed enum (for example `hierarchy`, `rhythm`, `cover`, `whitespace`, `colour-harmony`, `energy`), so reasons stay analysable.
  - **Position bias control:** each call is made twice with reversed candidate order; the two rankings are averaged using Borda counts. This doubles cost but is required. Cost is kept low with `detail: low` strips.
  - The winner replaces the composer's pick. If the judge fails or times out, the composer's pick is used and the manifest records `judge: skipped` with the reason.
- **Cover check:** the same stage may also rank the top 3 cover candidates per direction, within the existing cover-safety rules.
- **Budget:** at most $0.005 extra and 10 s per run on gpt-6-luna. Directions are judged in parallel. On iOS the calls go through the Worker, so the Worker's daily caps also bound them.
- **Recorded as:** `JudgeResult {directionID, candidateSeeds, ranking, reasons, model, promptVersion, costUSD, latency}` in `plans/judge.json`, plus a `concept_judged` entry in the run's call log.
- **Ship gate:** turned on by default only when `ak14 eval score` shows higher agreement than composer-only, with the confidence intervals not overlapping or the margin agreed by the owner.

## 5. Preference memory (build third)

- **Signal:** the interaction log. The iOS app must write the same `InteractionEvent`s as Studio (task TE-4): `concepts_presented`, `concept_selected`, `photo_swapped`, `photo_removed`, `slide_reordered`, `concept_rerolled`, `carousel_exported`, `carousel_shared`, plus `generation_abandoned`. Exports and shares carry the strongest weight, selection medium weight, and edits weak weight.
- **`PreferenceProfile`** (`Core/Taste/PreferenceProfile.swift`), computed on device from all of a user's runs:
  - **Style-axis affinities:** for every StyleVector axis value, a Beta(wins + 1, losses + 1) count. A "win" is a chosen or exported option having that value while a presented alternative had a different one. A 90-day half-life decay keeps it current. A minimum of 3 decisive events is needed before a value is used, so one edit never overfits.
  - **Photo-level tendencies:** counts of removed vs kept by triage tag (for example `food`, `selfie`, `landscape`) and by cover type.
  - **Notes:** at most 5 short natural-language lines, regenerated by the model at most once a week from the counts only (no images). For example: "Prefers airy layouts and candid group shots; usually removes food photos."
- **Use:**
  - The Director receives the notes and affinities, so its directions lean toward the person without abandoning variety: at least one direction must stay outside their strongest affinities (the novelty requirement from product spec §39).
  - The judge receives the notes.
- **Storage and privacy:**
  - The profile lives on device beside the runs, as numbers and short text only.
  - Optional sync through the Worker (`PUT /v1/profile`), keyed by a random install id, never by name or email.
  - It is deleted with the user's data.

## 6. References and "make it feel like these"

- **StylePack gains** (with validation added to `StyleConfigClient`):
  - `constitution` (markdown text replacing the hard-coded taste list in `planner.system.md`)
  - `referenceImages`: `[{id, url, sha256, tags}]`
  - `trendNotes`: `[String]`
  - `judge`: `{candidates, model, enabled}`

  Images are hosted by the Worker in R2, versioned with the pack, and cached on device by hash. The existing pinning (`StylePackPin`) guarantees that old runs never change after a new pack ships.
- **User references (iOS):** in Story settings, the user can attach 3–10 screenshots or saved posts to a run. They are downscaled to at most 384 px and sent only to the Director and the judge, as "the look this person wants". This is covered by the same consent as thumbnails; the consent text gets one added sentence. They are stored with the run and deleted with it.

## 7. Trend refresh (build last)

- **Job:** a Worker cron runs monthly. It reads the owner-controlled sources listed in `TREND_SOURCES`:
  - Are.na channels, through its public API
  - optionally Pinterest boards, through API v5 once the app is approved
- **Distillation:** the model summarises the new images into at most 8 trend notes and suggests at most 6 reference images. Together these form a draft StylePack version `x.y+1-draft`, stored in KV.
- **Approval:**
  - The draft is visible at `GET /v1/admin/drafts`, protected by an admin token.
  - The owner approves with `POST /v1/admin/drafts/:id/approve`, and it becomes the active pack.
  - Rollback means reactivating the previous version.
- **No Instagram scraping.** It breaks Instagram's terms and is brittle. The official Instagram API only covers the owner's own or business accounts, and its hashtag search is limited to a small number of hashtags per week. The strongest trend signal is what users themselves upload as references (§6).

## 8. Safeguards

- **Judge bias:** models favour polished, "safe" images. The eval set measures this, and trend notes and references counter it. Any judge configuration that lowers agreement on candid or "imperfect" pairs is rejected, even if its overall agreement rises.
- **Position bias:** order is randomised, and each judgement is run twice with reversed order (§4).
- **Drift limits:** trend notes and references change style preferences only. They can never change safety rules, crop limits, face protection or the StylePack's geometry bounds, which `StyleConfigClient` validates.
- **Filter bubble:** the novelty requirement (§5) keeps at least one direction outside a user's affinities.
- **Cost:** judge calls count against the Worker's per-token daily request and spend caps. The manifest records judge cost separately.
- **Privacy:** only low-res strips, thumbnails and user-chosen references leave the device, never originals. The consent text is updated to cover strips and references.

## 9. Data model and versions

| Type or field | Module | Notes |
|---|---|---|
| `EvalSet`, `EvalPair`, `CandidateRef`, `EvalLabel`, `EvalReport` | `Core/Taste` | Codable, local files under `eval/` (gitignored) |
| `Composition` top-N list | `Core/Compose` | added to `ComposerEngine`; the existing single result stays the default |
| `JudgeResult` | `Core/Taste` | `plans/judge.json` |
| `PreferenceProfile`, `AxisAffinity` | `Core/Taste` | on device; version `pref-1` |
| `StylePack.constitution`, `referenceImages`, `trendNotes`, `judge` | `Core/Plan/StylePack.swift` | optional, with tolerant decoding; old packs remain valid |
| `manifest.versions` keys | `judge`, `taste`, `preferenceProfile` | absent means off |

Backward compatibility: old runs lack these fields and are treated as composer-only. `rerender` never calls the judge; it re-renders the stored winner.

## 10. Task list

Each task can be built and checked on its own. "Check" is what the reviewer runs. Tasks marked ⟂ can run in parallel with the others in the same wave.

| ID | Task | Area | Depends on | Check |
|---|---|---|---|---|
| TE-1 | Eval harness: `EvalSet` types, `ak14 eval pairs`, `ak14 eval label` (static page), `ak14 eval import`, `ak14 eval score` for composer-only | Mac/Core + CLI | — | e2e test on fixture runs: pairs are generated, labels round-trip, score and CI are computed, report is written |
| TE-2 | Candidate pool and strips: top-N safe compositions from `ComposerEngine`, `StripRenderer` | Core + Render | TE-1 | e2e: N candidates, all safe, deterministic strips |
| TE-3 | Judge stage: prompt, schema, double-order Borda ranking, fallback, `JudgeResult`, manifest versions, `ak14 eval score --config` using the judge | Director + CLI | TE-2 | e2e with FakeModel (ranking applied; fallback on garbage; cost recorded); live `ak14 eval score` run by the owner |
| TE-4 ⟂ | iOS interaction logging, matching Studio's events | iOS | wave 1 T2 | simulator UI test: events written in order |
| TE-5 ⟂ | StylePack v2 fields (`constitution`, `referenceImages`, `trendNotes`, `judge`), validation, R2 hosting, planner reads the constitution | Core + Render + Worker | wave 1 T3 | Worker checks; e2e: old and new packs decode, pinning holds |
| TE-6 | `PreferenceProfile` from events, notes regeneration, injection into Director and judge, novelty rule | Core + Director | TE-3, TE-4 | e2e: a scripted event history yields the expected affinities; one direction stays outside them |
| TE-7 | "Make it feel like these": reference attach on iOS, sent to Director and judge, consent sentence | iOS + Director | TE-5, TE-6 | simulator UI test; e2e: references appear in the request |
| TE-8 | Trend refresh cron, Are.na source, draft and approve endpoints, rollback | Worker | TE-5 | Worker checks with a stubbed Are.na and model |
| TE-9 (optional) | Rater page on the Worker for scaled labelling | Worker | TE-1 | Worker checks |
