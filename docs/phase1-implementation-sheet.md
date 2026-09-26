# AK14 implementation sheet — Phase 0 quality pass to Phase 1

Status: active (2026-09-26). The local iOS flow passed a simulator UI smoke test on iOS 26.2, including Save to Photos. A signed development build was installed on the owner's iPhone 17; the owner will run the physical-device smoke. The Worker remains local only. This sheet records the owner's latest decisions from the Claude transcript and the work now underway. The [composer-engine design](superpowers/specs/2026-09-26-composer-engine-design.md) supersedes older Plain/Designed/Wildcard descriptions in the original product spec.

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
| P1-A | Shared iOS build | Core, Analysis, Director and Render build for iOS 26 or have isolated platform adapters. An iOS app target builds in the iOS 26 simulator. | Simulator and signed device builds passed; installed on iPhone |
| P1-B | Photo intake | User starts a date-range/selection flow, grants PhotoKit access (including limited access), and local assets enter the existing analysis pipeline with stable IDs and cache behavior. | Local simulator flow passed |
| P1-C | Worker | Local Worker accepts authenticated, bounded Responses requests, keeps the provider key server-side, and serves a versioned style config. No deployment until app and access design are reviewable. | In progress |
| P1-D | Review and handoff | iPhone displays neutral options, supports existing constrained edits, and saves or shares ordered slides. A real photo set reaches this flow on simulator/device. | Simulator import → options → editor → Save passed; owner device smoke pending |
| P1-E | Reliability | Interrupted generation resumes or fails clearly, iCloud-backed assets and limited-library changes are handled, source photos remain untouched, and stage timing/cost are recorded. | Planned |

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
