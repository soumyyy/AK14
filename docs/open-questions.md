# Open Questions — Phase 0 / Phase 1

> **Current decisions (2026-09-26):** The owner chose an iOS 26 minimum version and a Cloudflare Worker for the API proxy and remote StylePack config. The Phase 0 participant study is deferred while Phase 1 proceeds. New runs use open directions instead of fixed named concept types. See [the implementation sheet](phase1-implementation-sheet.md). Older questions below are retained as design history.

## Resolved (2026-09-25)
- App name: **AK14**.
- Q1: Phase 0 runs on Mac; the user supplies photo folders. A rough TestFlight app comes later for the study.
- Q2: Swift.
- Q3: One LLM call builds a shared selection spine. Plain renders it directly; Designed and Wildcard may deviate, and deviations are logged.
- Q4: Starter asset library built from free, openly licensed fonts, textures and decorations.
- Q5: Text on slides is limited to date/location stamps for now.
- Q9: Aspect ratio is inferred from the photos (dominant orientation) and can be overridden.
- Q13: First LLM provider is OpenAI GPT-6 Luna (launched Sept 2026; confirm the exact API model ID at implementation time). Keep ArtDirectorProvider provider-agnostic.
- Dev machine: macOS 27, so Vision aesthetics scoring is available.
- Defaults accepted: originals exported with metadata; one folder = one story; Mac editing is reorder/swap/remove/reroll; log cost per run (~$0.50 soft cap); a few minutes per run is fine; cheap triage pass ON.

Ranked by how much each answer changes the build. The recommended answer is in *italics*.

## Blocking (changes architecture)

1. **Who operates the Phase 0 study, and how do photos get in?**
   The spec says to use folder input and not start with the iOS app. But moving 500–2,000 photos off a participant's phone with metadata intact is a real hurdle for both friction and privacy. It also conflicts with "observe behavior for 7 days" and "allow normal editing," because participants need the output on their phones.
   Options:
   (a) Operator-run on a Mac: participants AirDrop or export folders, you run the pipeline and send back the slides.
   (b) A deliberately crude TestFlight app built on the same Swift core, using a date-range picker.
   (c) A mix: (a) first for your own and friends' events, then (b) for the study.
   *Recommend (c).*

2. **Phase 0 language and platform.**
   Swift (a macOS CLI plus a shared package) vs Python.
   Swift gives direct reuse in Phase 1 and native access to Apple Vision: feature prints, face capture quality, saliency, and on macOS 15+/iOS 18+ `VNCalculateImageAestheticsScoresRequest` with `isUtility`.
   Python iterates faster on ML (CLIP, open aesthetic models), but everything gets rewritten for Phase 1.
   *Recommend Swift.*

3. **Is the Plain Dump LLM-planned or deterministic?**
   §38 has one call return Plain + Designed + Wildcard. The build order has a separate "Plain Dump planner" step before the art director.
   Related: when Plain and Designed use different photo selections, "design lift" mixes up selection quality with design quality.
   *Recommend:* one LLM call produces a shared "selection spine." Plain renders the spine directly. Designed and Wildcard may deviate from it, and the deviation is logged, so design lift can be measured cleanly.

## Important (changes scope and effort)

4. **Who supplies the human-owned taste layer for Phase 0?** That means fonts (licensing), textures, tape/paper assets and the first 1–3 style directions. Without it, the Designed and Wildcard concepts have nothing to recombine.

5. **Text on slides.** Does the LLM write captions or handwritten text, or are date stamps and location text only? Is there a language/tone requirement?

6. **Where does "emotional relevance" come from?** Local features can't infer it. Only the top 20–30 candidates get thumbnails, so pre-LLM ranking decides what the model ever sees, which pushes toward conventional aesthetics.
   *Recommend:* a cheap vision-model triage pass over about 60–100 tiny thumbnails before final planning.

7. **Phase 0 story scope.** Is one folder one story, or does Phase 0 also split an event into stories? The Phase 0 build list omits story extraction and event detection.
   *Recommend:* one folder = one story in Phase 0.

8. **Editing in Phase 0.** What counts as "limited edits": reorder, swap and remove only, or the full V1 editor list?
   *Recommend:* reorder/swap/remove/reroll only.

9. **Default aspect ratio.** 4:5 or 3:4? Instagram's grid moved toward 3:4 in 2025.

10. **Definition of "without substantially rebuilding."**
    *Proposed:* ≤30% of final photos swapped and ≤30% of slides re-laid-out.
    How is "posted within 7 days" verified: self-report, or a link to the post?

## Phase 1 specifics

11. Minimum iOS version. "~5-year-old iPhones" means iPhone 12/13-era devices, which suggests iOS 17 or 18. That choice decides whether the Vision aesthetics API is available.
12. Backend stack for the proxy, remote config, assets and analytics (e.g. Cloudflare Workers + R2, Supabase, Firebase). Also auth: anonymous device ID, or Sign in with Apple?
13. LLM provider for the first implementation. It stays provider-agnostic, but one has to be first.
14. Budgets: target cost per generation and target end-to-end latency. The spec treats both as first-class but gives no numbers.
15. Does Phase 1 wait for the Phase 0 go/no-go? Outcome B (Plain dominates) changes Phase 1 heavily.
16. Team and timeline: solo, Swift experience, target date for the study.
