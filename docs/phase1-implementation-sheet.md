# AK14 implementation sheet — Phase 0 quality pass to Phase 1

Status: active (2026-09-27). The local iOS flow previously passed a simulator UI smoke test on iOS 26.2, including Save to Photos. The latest signed build, with occasion splitting, AI planning default, native review polish and photo-derived backgrounds, was installed on the owner's iPhone 17. The Worker is deployed; a tiny live model request through the scoped iPhone invite succeeded, while a photo run from the iPhone still needs the owner's smoke test. The current simulator UI test is blocked by intermittent SpringBoard/XCTest automation crashes and a stalled editor-sheet step. The [composer-engine design](superpowers/specs/2026-09-26-composer-engine-design.md) supersedes older Plain/Designed/Wildcard descriptions in the original product spec.

## Decisions already made

- Move directly toward Phase 1; do not recruit the 12–15 person Phase 0 study now. Keep automated end-to-end checks and real-device smoke checks.
- The model provides a selection spine and 2–5 open style directions. The deterministic composer builds neutral Option N carousels plus an unlabeled photos-only baseline. Every option must be postable.
- Group photos by aesthetic compatibility. Time, cover-alone and emphasis-alone are soft preferences, not grouping constraints.
- Phase 1 minimum deployment target: iOS 26.
- Backend: Cloudflare Worker for the model proxy and remote, versioned style configuration. Do not ship an OpenAI key in the app.
- Prefer a thin iOS app over rebuilding the Mac engine. The existing Swift modules remain the reference implementation.

## Work sequence

| ID | Work | Deliverable and acceptance check | Status |
| --- | --- | --- | --- |
| Q1 | Burst selection | Near-identical frames with changed pose/framing remain available; representative selection considers people and visual quality; real folder comparison and E2E pass. | In progress |
| Q2 | Landscape and single-photo layout | Landscape group shots use intentional tall-canvas compositions with safe crops; single-photo slides vary position without losing hierarchy; rerender stays deterministic. | In progress |
| P1-A | Shared iOS build | Core, Analysis, Director and Render build for iOS 26 or have isolated platform adapters. An iOS app target builds in the iOS 26 simulator. | Simulator and signed device builds passed; latest build installed on iPhone |
| P1-B | Photo intake | User starts a date-range/selection flow, grants PhotoKit access (including limited access), and local assets enter the existing analysis pipeline with stable IDs and cache behavior. | Local simulator flow passed |
| P1-C | Worker | Worker accepts authenticated, bounded Responses requests, keeps the provider key server-side, and serves a versioned style config. | Deployed; live bounded model smoke passed with scoped invite; model-backed iPhone photo run pending |
| P1-D | Review and handoff | iPhone displays neutral options, supports existing constrained edits, and saves or shares ordered slides. A real photo set reaches this flow on simulator/device. | Simulator import → options → editor → Save passed; owner device smoke pending |
| P1-E | Reliability | Interrupted generation resumes or fails clearly, iCloud-backed assets and limited-library changes are handled, source photos remain untouched, and stage timing/cost are recorded. | Planned |

## Delegation waves (Claude plans and reviews; GPT-6 Luna implements via `codex exec` in isolated worktrees)

| Wave | Task | Branch | Scope (files) | Acceptance | Status |
| --- | --- | --- | --- | --- | --- |
| 1 | T1 Landscape compositions (rest of Q2) | `w1-landscape` | `Sources/Core/Layout/*`, `CarouselAspect` inference, `Tests/CLITests/RenderE2ETests.swift` | Landscape singles and pairs get intentional tall-canvas arrangements (full-width band, stacked full-width pair) with crop ≤ 20% and no people cut; 4:5 is suggested when ≥ 60% of the selected photos are landscape; rerender is byte-identical; `swift test` passes | Done (merged ecab62d; aspect rule kept: landscape-heavy uses square) |
| 1 | T2 iPhone reliability (P1-E) | `w1-ios-reliability` | `Sources/iOSApp/StoryPipeline.swift`, `ImportReviewView.swift` (progress and error states only) | iCloud-only originals download with progress and fail clearly offline; an interrupted generation leaves no half-written run and can be retried; per-run stage timings and model cost are saved; imported originals are removed when a run is deleted; the iOS simulator build succeeds | Done (merged; the delete helper still needs a UI control) |
| 1 | T3 Worker deploy readiness (P1-C) | `w1-worker` | `backend/worker/**` | Per-invite-token daily request and spend caps in KV; each call logs model, tokens and estimated cost; README deploy steps (`wrangler secret put`, KV namespace, invite tokens); `npm run check` passes | Done (merged; deployed to Cloudflare; public health/config respond) |
| 2 | TE-1 Eval harness (taste engine) | `w2-eval` | new `Sources/Core/Taste/*`, `Sources/CLI/EvalCommand.swift`, `Arguments.swift` and `AK14Command.swift` (eval subcommand only), new `Tests/CLITests/EvalE2ETests.swift` | `ak14 eval pairs / label / import / score` work on fixture runs; the composer-only baseline score and 95% CI are reported; `swift test` passes | Done (merged) |
| 3 | TE-2 Candidate pool and strips | `w3-candidates` | `Sources/Core/Compose/ComposerEngine.swift` (top-N API only), new `Sources/Render/StripRenderer.swift`, tests | N safe candidates per direction, deterministic strips | Done (merged) |
| 3 | TE-4 iOS interaction logging | `w3-ios-events` | `Sources/iOSApp/*` event calls, UI test | Studio-equivalent events written in order on the simulator | Done (merged) |
| 3 | TE-5 StylePack v2 (constitution, references, trend notes, judge config) | `w3-stylepack2` | `Core/Plan/StylePack.swift`, `Render/StyleConfigClient.swift`, `backend/worker/**`, planner prompt | old and new packs decode; pinning holds; Worker checks pass | Done (merged) |
| 4 | Q3a Event segmentation + story hint (engine, Mac) | `w4-events-core` | new `Sources/Core/Events/EventSegmenter.swift`; `RunPipeline` / `RunOptions` / `Arguments` (`--event`, `--all-events`, `--story`); `ArtDirector` (story hint in the planner content and planner prompt v5); `CompositionContext` (event membership) | A selection spanning several occasions is split into events (gap ≥ 36 h, or ≥ 8 h with a location jump ≥ 100 km); a run uses one event unless told otherwise; the hint reaches the planner and is stored with the run; e2e with a fixture of 3 separated events | Done (merged; content-aware splitting still needed) |
| 4 | Q3b Event chooser + story hint (iPhone) | `w4-events-ios` | `Sources/iOSApp/*` | After import, more than one event shows an event picker (date range, photo count, a cover thumbnail, and "one story across all"); an optional story-hint field before generating; both are passed to the pipeline and saved with the run; simulator UI test | Done (merged; newer build not confirmed on phone) |
| 4 | TE-3 Judge stage | `w4-judge` | new `Director/Judge.swift`, `judge.system.md`, `Schemas.swift`, `ArtDirector.swift`, CLI eval config | FakeModel e2e; owner runs live `ak14 eval score` | Parked; uncommitted worktree preserved for rewrite after Wave 5 |
| 5 | W5-A Occasion split (content-aware) + planner v6 | `w5-occasion` | Core EventSegmenter (time blocks and a local scene-signature fallback), new Director OccasionSplitter (one cheap model call), RunPipeline, prompts, Worker schema allow-list | IMG splits the wedding from the trip; the trip spine has no wedding, beach or arcade frame without a transition reason | Merged; local IMG pass separated 447 trip photos and 11 likely wedding photos; live model split and trip story taste still unverified |
| 5 | W5-B Candid recall in the pool | `w5-pool` | Core/Reduction (Ranker, DiversitySelector, config) and RunPipeline's selectPool | Triage weight ±40%; characterful and candid frames reach planning; representatives consider triage | Merged; 59 Swift tests and simulator build passed on branch; cached IMG pool unchanged because new burst alternates lack cached triage |
| 5 | W5-C Legibility, pairing and scale rules | `w5-layout` | Core/Layout/Composer.swift, Core/Compose/ComposerEngine.swift | Minimum on-slide face size; pairs need a people or scene relationship; deliberate bleed, band and inset scales; no runs of small centered cards | Merged; relevant tests and full 58-test suite passed |
| 6 | W5-D Staged evaluation (split, selection, cover, layout, "neither") | `w7-eval-stages` | eval harness | per-stage agreement and "neither" rate; old evalsets still work | Running |
| 6 | W6-A AI planning default and one-time Worker setup | `w6-ai-default` | iOS app settings and secure token storage | AI planning starts enabled when configured; missing setup is explicit; user may opt out | Merged; scoped invite provisioned, device model run pending |
| 6 | W6-B Photo-first layouts inspired by 17V28 | `w6-design` | Core layout and renderer | Fewer pale mats; purposeful photo backdrops, scale and layering; safe faces and crops | Merged; real six-photo preview reviewed; taste on full IMG set and owner device pending |
| 7 | CS-1 CanvasDocument model + document renderer | `w7-document` | new `Core/Document/*`, `Render` document renderer, conversion from `ResolvedCarousel` | Converted layouts render byte-identical to today; documents round-trip; e2e | Running |
| 7 | CS-2 Exact photo sets (engine and Mac) | `w7-exact` | `RunOptions`/`Arguments` (`--exact`, `--keep-order`), `RunPipeline`, Director (`exactSet`, prompt rules), composer | Every selected photo appears exactly once; no event split or pool drop; `--keep-order` fixes the order; e2e | Running |
| 7 | CS-3 iOS exact mode + Share Extension | `w7-ios-exact` | iOS + share extension target | exact/keep-order UI; Share → AK14 app-group handoff; UI test | Running |
| 7 | CS-4a Asset kit v1 (about 60 first-party procedural and vector pieces; 8 OFL fonts already added) | `w7-kit` | new Render/Kit | deterministic drawing, manifest, preview sheet | Running |
| 7 | CS-4b Kit rendering in documents | — | DocumentRenderer | after CS-1, CS-4a | Queued |
| 7 | CS-5a Recipe format + 7 starter recipes (data) | `w7-recipes` | StylePack, Recipe types, validation, starter pack, Worker config | decode, validate, fonts resolve | Running |
| 7 | CS-5b Recipe filler in the composer; `seamless` and `titleIdea` direction fields | — | Core + Director | after CS-1, CS-4b, CS-5a | Queued |
| 7 | CS-6 Seamless panorama | — | Core + Render | after CS-5 | Queued |
| 7 | CS-7 iOS canvas editor v1 | — | iOS | after CS-1, CS-4 | Queued |
| 7 | CS-8 Photo looks and carousel grade | — | Render + editor | after CS-7 | Queued |
| 7 | CS-9 Quality gate: Sol review against 17V28-style references, and eval pairs | — | Review | after CS-5, CS-6 | Queued |
| 5 | TE-6 Preference memory, TE-7 references on iOS (TE-8 trend refresh deferred per the Sol review) | see spec §10 | see spec §10 | see spec §10 | After TE-3/4/5 |
| 2 | Model-assisted flow on device through the deployed Worker | — | iOS settings and Worker URL | Configure a scoped invite in the app and complete an end-to-end device run | Pending device smoke |
| 2 | Taste calibration from the owner's picks on 2–3 events | — | Composer weights | Needs the owner's picks | Blocked on owner |

**Current goal (2026-09-27, Claude drives; Luna implements until its limits, then Claude):** wave 7 complete (CS-1 to CS-9). Automatic 17V28-level carousels, a full iPhone canvas editor, and exact photo sets (in the app and via Share), verified by e2e and UI tests, a GPT-6 Sol quality review, and an owner device build.

Creative studio (wave 7): [spec](superpowers/specs/2026-09-27-creative-studio-design.md): 17V28-level automatic output, a canvas editor, and exact photo sets.

Reviews: [GPT-6 Sol taste review](reviews/2026-09-26-gpt6-sol-taste-review.md) drives wave 5.

Taste engine: [spec](superpowers/specs/2026-09-26-taste-engine-design.md). Task briefs are written when a task's dependencies have merged, so they describe the code as it actually is.

## iPhone interface direction

The installed [apple-design skill](../.agents/skills/apple-design/SKILL.md) is web-oriented, so apply its principles through native SwiftUI controls and system behaviors. Use a photo-first **Photos → Review → Options** navigation flow. Keep the primary action near the bottom safe area, show live stage progress, and keep model transfer opt-in and explained at the moment it is chosen. Option names stay neutral; the baseline's identity and internal style details stay out of participant-facing results. Support Dynamic Type, VoiceOver selection state, Reduce Motion, and native sheets. Avoid decorative custom navigation or animation that competes with the photos.

## Integration contract

1. Keep `Core` platform-neutral. Put PhotoKit, iOS file access and image decoding behind `Analysis` adapters; put iOS presentation in a separate app target.
2. `ResponsesClient` keeps its transport protocol. The iOS app uses a proxy transport and never receives the OpenAI key. The Mac CLI can retain direct transport for local development.
3. The Worker accepts only the model and request shape needed by AK14. It passes upstream response JSON through so existing usage, retry and validation behavior remains intact.
4. The app pins the StylePack ID/version/config with each generated carousel. It must never silently change an old composition after remote config updates.
5. Continue neutral Option N labels, shuffled baseline placement, no participant-facing style briefs, and deterministic rerender from saved direction/seed.

## Completion gate for the first iOS slice

- Build and launch on an iOS 26 simulator; check the same flow on a physical iPhone before broader distribution.
- Choose a real event, grant limited or full Photos access, generate options through the Worker, review them, and save/share ordered images.
- Confirm no provider key is in the app bundle, no original images are sent for planning, and failed or cancelled requests do not corrupt saved runs.
- Run the existing Swift E2E suite and focused iOS/Worker integration checks. External participant study remains deferred by owner decision.

## Deferred until after the first slice

Video still extraction, location stamps, automatic event discovery, background notifications, multi-story extraction, neural personalization, direct Instagram posting, and the original 12–15 person Phase 0 study. Taste calibration can use the owner's picks on two or three events once the iOS flow is usable.
