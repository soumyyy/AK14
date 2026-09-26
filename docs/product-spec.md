# Product Spec — Autonomous Art Director for Camera-Roll Carousels

> **Current implementation note (2026-09-26):** The fixed Plain/Designed/Wildcard concept descriptions below are historical. New runs use open model directions, a deterministic composer, and neutral Option N presentation as specified in [the composer-engine design](superpowers/specs/2026-09-26-composer-engine-design.md). The owner has chosen to defer the Phase 0 participant study and proceed to an iOS 26 app with a Cloudflare Worker proxy. See [the active implementation sheet](phase1-implementation-sheet.md).

> Restructured from the original 73-section spec. Content is preserved; order is grouped by concern.
> Items marked **[OPEN]** are unresolved ambiguities — see `docs/open-questions.md`.

| | |
|---|---|
| Status | Pre-MVP / validation |
| Platform | iOS first |
| Media | Still photos only (V1) |
| LLM | API-based multimodal only; no on-device LLM |
| Business model | Free during validation |
| Primary objective | Prove the system turns a large real-world photo set into a carousel the owner genuinely wants to post |

**One-line brief:** Use local iPhone intelligence to reduce hundreds or thousands of event photos to a manageable candidate set. Then use an API multimodal LLM to art-direct several distinct Instagram carousel concepts, including a plain photo-dump control. Deterministic native code handles geometry, rendering and editing.

---

## Part I — Product

### 1. Thesis
Users already have the photos. After a trip, birthday, concert, party, wedding or night out they have 200–2,000+ images, and turning them into a carousel takes too much effort. That effort covers selecting, deduping, finding stories, grouping, picking a cover, setting hierarchy, composing slides, sequencing, keeping imperfect shots, avoiding repetition, editing and exporting. Because of it, users postpone the post or never make it.

> *Your camera roll already contains the post. We find it and art-direct it for you.*

The long-term goal is an **autonomous visual art director for personal memories**, not a photo editor or template library.

### 2. Target user
- Cares a lot about how their Instagram looks; follows visual and cultural trends
- Dislikes generic or "normie" posts and Canva/CapCut template fingerprints
- Prefers personality-heavy photo dumps that look effortless
- Takes 500–2,000+ photos at important events
- Values candids, flash, blur, mirror shots, signs, food and random details
- Wants help without losing individuality

The product competes on **taste and effort reduction**.

### 3. Core hypothesis
> Given someone's own 200–2,000 photos from a meaningful event, can the system generate several carousel concepts that the person genuinely wants to post?

Nothing else matters until this is proven.

### 4. Principles
1. **Taste over technical perfection.** Tell *unusable accidents* apart from *useful imperfection*. Aesthetic scores are supporting features, never the final judge.
2. **AI art-directs; it does not generate pixels.** The original photos stay the content.
3. **The LLM decides intent; deterministic code executes it.** The LLM says "83 dominant, 27 small overlapping detail, dense and slightly messy." Code decides x/y, crop, size, z-index, margins, face-safe crop, overlap and export geometry.
4. **Personalization must not converge to repetition.** Learn boundaries, not favorites. Explore widely inside the acceptable region.
5. **Novelty is required.** Compare each output against the user's recent carousels, covers, primitive combinations, pacing, decoration families and global app fingerprints. Target reaction: *"feels like me, but I wouldn't have made it exactly this way."*
6. **Design must earn its presence.** Always be able to produce a **Plain Dump** concept.

**Core rules**
- *AI rule:* the LLM decides **what** should happen; code decides **how exactly** it happens.
- *Photo rule:* before removing a strange photo, ask "unusable, or merely imperfect?" Only remove the unusable ones automatically.
- *Personalization rule:* history mainly teaches what to **avoid**, not what to repeat.
- *Design rule:* if the best carousel is just a great cover, great sequence and great photos, output exactly that.

**Taste Constitution V1**
Good composition requires hierarchy · Not every photo needs decoration · Density should vary across slides · Imperfection can carry emotional value · Repeated perfection feels artificial · A carousel responds to its particular photos · Surprise is valuable when coherent · Avoid template fingerprints · Don't optimize every image for generic beauty · Random images give rhythm and personality · Whitespace is active · A cover creates interest; it doesn't just maximize aesthetic score · Concepts must differ structurally · A plain photo can beat a designed slide · Design must earn its presence.

**Agent optimization priority (do not reverse):**
1. Post-worthiness
2. Photo selection
3. Sequencing
4. Design lift over Plain Dump
5. Concept diversity
6. Non-template appearance
7. Effort reduction
8. Reliability
9. Latency
10. Cost
11. Automation

---

## Part II — Scope

### 5. V1 includes
Photo-library permission · foreground recent-moment detection · manual date-range/event selection · candidate analysis · duplicate/shot clustering · story generation · 3 concepts by default · 5–20 slides · API multimodal art direction · deterministic rendering · limited editor · Save to Photos · share sheet · interaction logging · style-pack versioning · remote style config · remote style assets (where practical).

### 6. V1 excludes
Reliable background notifications · video · animated Live Photos · direct Instagram publishing · creator marketplace · neural personalization · Canva-style editing · generative photo replacement · on-device LLM.

---

## Part III — Domain Model

### 7. Event (Moment)
The primitive is a **Moment/Event**, not a "trip." An event is a temporally, and optionally geographically, coherent cluster of photo activity that differs meaningfully from the user's normal capture behavior. Examples: trip, birthday, concert, wedding, party, festival, college event, dinner, night out, graduation, weekend, holiday, or an unusually dense session.

### 8. Story
One event can hold several postable stories. For example, a Japan trip might yield "whole trip", "Tokyo nights", "Kyoto", "cafés & food", "friends" and "architecture".
- **Event detection:** which experience do these photos belong to?
- **Story extraction:** which narrative could become a post? The user chooses.

### 9. Concepts
Three concepts by default, each materially different:

| Concept | Description |
|---|---|
| **A — Plain Dump** (mandatory in Phase 0) | Selection and sequencing only. One photo per slide, full or near-full frame. No decoration, scrapbook effects, complex type or collage. The strongest possible baseline, not a deliberately boring one. |
| **B — Designed** | Strongly designed and compatible with the content |
| **C — Wildcard** | More experimental composition, pacing and primitive use |

Possible later set: Plain / Safe / Alternate / Wildcard, if cost and UX allow.

**Diversity check** compares selected-photo overlap, cover, slide count, single/multi ratio, primitive distribution, density rhythm, decoration use and overall fingerprint. If two concepts are too similar, regenerate or mutate one.

### 10. Carousel length
Users choose 5–20 slides and the system recommends a number (e.g. "Recommended: 12"). Never pad to hit a target.

### 11. Aspect ratio
`carouselAspectRatio` is first-class config. Primitives must never bake in one ratio, and every slide in a carousel shares the same ratio. **[OPEN: default ratio]**

---

## Part IV — Pipeline Architecture

```text
APPLE PHOTO LIBRARY
  → PHOTOKIT INDEXER → LOCAL PHOTO DATABASE
      ├→ EVENT DETECTOR
      └→ PHOTO UNDERSTANDING → SHOT/DUPLICATE CLUSTERS → CANDIDATE REDUCTION
            → STORY EXTRACTOR → TASTE + NOVELTY + STYLE CONTEXT
            → API MULTIMODAL LLM ART DIRECTOR → STRUCTURED PLANS
            → CONSTRAINT RESOLVER → NATIVE RENDERER → LIMITED EDITOR
            → PHOTOS / SHARE SHEET
```

**Replaceable module interfaces:** `EventDetector`, `ShotClusterer`, `PhotoAnalyzer`, `CandidateRanker`, `StoryExtractor`, `ArtDirectorProvider`, `TasteStore`, `NoveltyScorer`, `StyleProvider`, `LayoutResolver`, `Renderer`. No intelligence component may be hard-wired.

### 12. Resolution escalation
| Tier | Data | Used for |
|---|---|---|
| A | Metadata | Event detection, timestamps, location clustering, screenshot detection, dimensions, capture density |
| B | Small thumbnails | Similarity, faces, scene classification, quality, rough composition |
| C | Medium thumbnails | Final shortlist; multimodal API reasoning |
| D | Originals | Final render/export only |

### 13. Photo index — `PhotoAssetRecord`
Persistent and incremental; never reprocess the whole library.
```text
assetId, createdAt, addedAt, latitude?, longitude?
width, height, aspectRatio
isScreenshot, isFavorite, isHidden
processingVersion
eventId?, shotClusterId?, duplicateClusterId?
aestheticScore?, qualityFlags[]
faceCount, faceRegions[], personRegions[]
sceneLabels[], contentTags[]
dominantColors[], saliencyRegions[]
featureVectorReference?, candidateScore?
```

### 14. Event detection (mostly deterministic)
**Inputs:** photos per hour/day, time gaps, geographic displacement and clustering, duration, unique locations, deviation from normal capture rate, day/night pattern, repeated people, screenshot/camera ratio.

**Example:** a normal day has 8 photos. Fri 220 → Sat 480 → Sun 340 → Mon 90 → Tue 7 is a likely event.

**Closure:** density drops, plus a significant time gap, plus a possible location change, plus a return to normal behavior. Closure is reversible, and adjacent events can be merged later.

### 15. Photo understanding (per-photo features)
Aesthetic prior · technical quality · face count/regions · person regions · subject saliency · orientation · single vs group · scene and semantic tags · dominant colors · brightness/contrast · negative-space estimate · visual density · similarity embedding · flash/night heuristic · screenshot status · candid-vs-posed heuristic.

### 16. Shot / duplicate clustering
28 near-identical selfies form one `ShotCluster` with {representative, alternates, size, visual similarity, capture interval}. Downstream reasoning mostly sees representatives.

### 17. Junk filter — *filter accidents, preserve personality*
| Remove / strongly penalize | Never auto-remove |
|---|---|
| Exact duplicates, black frames, corrupted files, extreme blur with no subject, pocket shots, irrelevant screenshots | Intentional motion blur, flash, awkward candids, food, signs, low light, random details, messy compositions |

### 18. Social safety (hard/semi-hard rule, not learned)
Don't use other people's faces as the hero when the frame shows an obvious blink, a severe accidental crop, a poor expression, an awkward close-up, or is clearly unflattering and a safer alternative exists. These photos can still appear deeper in the carousel.

### 19. Candidate reduction (adaptive numbers)
```text
1,500 images → metadata filter → 1,250 stills
  → shot/dup clustering → 300–400 distinct moments
  → quality + people + semantics + diversity → 60–100 strong candidates
  → story-specific ranking → 30–60 planning candidates
  → LLM reasoning → 5–20 final slides
```

### 20. Story extraction
Signals: capture time, geography, repeated people, scene/content tags, day/night, semantic similarity, visual style, event sub-clusters. Example: whole Goa trip / Goa nights / beach days / friends. The system can recommend several stories; the user picks one.

---

## Part V — Art Direction

### 21. `ArtDirectorProvider` (provider-agnostic)
Builds the multimodal request, calls the model, validates structured output, retries or repairs malformed plans, and captures tokens, images, latency and estimated cost. The model can be swapped without architecture changes.

**LLM decides:** final selection, cover, grouping, order, hierarchy, primitive choice, dense vs quiet slides, intentional use of imperfect images, style interpretation, concept differentiation.
**LLM does not:** generate pixels, render, bypass constraints, invent unsupported effects, or see the raw camera roll.

### 22. Input
Event, story, target slide count, user boundaries (avoid / soft affinities), recent history, style pack, available primitives, and candidates with structured features. Illustrative candidate:
```text
photo_17 — group, 4 faces, flash, nightlife, candid, emotional relevance high   [OPEN: source of "emotional relevance"]
```

**Cost strategy (30–60 candidates):**
- All candidates: metadata, tags, structured features, quality, type, shot-cluster info
- Top ~20–30: low-res thumbnails
- Originals: never sent for planning

**One call returns all concepts** (Plain + Designed + Wildcard). This lowers cost and latency, lets the model reason about diversity directly, and avoids duplicating images. Split into separate calls only if testing shows lower quality. **[OPEN: Plain Dump is LLM-planned here but a separate step in the build order]**

### 23. Structured plan (no pixel coordinates from the LLM)
```text
CarouselPlan: conceptId, conceptType, storyId, stylePackId, stylePackVersion,
              aspectRatio, slideCount, slides[]
SlidePlan:    id, primitive, mood, density, photoElements[], decorationElements[], textElements[]
PhotoElement: assetId, role, importance, cropIntent, anchorIntent, overlapIntent, rotationIntent
```

---

## Part VI — Style System (human-owned taste layer)

Humans own the primitive library, fonts, decorations, style directions, parameter ranges, prompt guidance, and the retirement of stale treatments. The LLM recombines these ingredients; it does not decide what is culturally current.

### 24. Primitives (not fixed template IDs)
`hero`, `full_bleed`, `framed_hero`, `inset`, `overlap_cluster`, `asymmetric_pair`, `vertical_strip`, `horizontal_strip`, `scatter`, `grid`, `cutout`, `detail_image`, `background_image`, `text_anchor`. Each defines constraints and parameter ranges.

### 25. Decorations (from controlled libraries)
Film grain, paper texture, tape, torn edge, date stamp, handwritten text, simple stickers, frame, caption, color block, film edge. **[OPEN: asset sourcing and who writes text]**

### 26. StylePack (remote-configurable; Phase 1 / V1 requirement)
```text
id, version, active, minAppVersion
primitiveWeights, decorationSet, fontSet, textureSet
allowedRotations, overlapRanges, spacingRanges, colorRules, grainRules, densityProfile
promptHints, explorationWeight
createdAt, deprecatedAt?
```
**Remotely changeable at minimum:** style on/off, primitive weights, decoration availability, font set, rotation/spacing/overlap ranges, grain intensity, density tendencies, prompt hints, exploration weight. Assets are downloaded and cached where practical. Every carousel stores `stylePackId` and `stylePackVersion` to support rollback, experiments, regression analysis and freshness updates.

---

## Part VII — Layout, Rendering, Editing, Export

### 27. Constraint resolver
- **Inputs:** canvas ratio, primitive definition, photo aspect ratios, face/person regions, saliency, element importance, anchor intent
- **Outputs:** x, y, width, height, rotation, crop, z-index, mask, decoration geometry
- **Constraints:** protect important faces, minimum subject visibility, minimum element size, allowed overlap, safe margins, rotation limits, canvas bounds, correct output ratio

### 28. Renderer
Core Graphics + Core Image, with Metal as an option later. Handles crop, masks, transforms, grain, paper/tape assets, borders, text, compositing and export. **Deterministic.**

### 29. Editor (fixes output; it is not the product)
**V1:** reorder slides, replace/add/remove photo, reposition crop, move/resize constrained elements, regenerate slide, switch slide layout, reroll carousel, adjust design intensity (limited).
**Not V1:** layer editor, vector drawing, advanced masking, unlimited typography, Canva replacement.

### 30. Export
Save to Photos in slide order, plus the iOS share sheet. Surface the share sheet prominently because it's a stronger behavioral signal.

### 31. Latency UX
Show progress right away: *Finding the best moments → Building the story → Art-directing the post → Rendering your options.* Deliver the Plain Dump first if possible. Never show an unexplained spinner. **[OPEN: latency budget]**

---

## Part VIII — Platform & Infrastructure

### 32. Client stack
Swift, SwiftUI, PhotoKit, Vision, Core ML (task-specific models), Core Image, Core Graphics, SwiftData or SQLite, URLSession. BackgroundTasks and UserNotifications come later.

### 33. Device compatibility
Target iPhones roughly 5 years old. All local work (indexing, Vision, clustering, reduction, rendering, editing) runs on older devices, and creative reasoning is always done via the API, so older phones don't get worse carousels. The pipeline adapts to speed, thermals, memory and background availability. **[OPEN: min iOS version]**

### 34. Backend (initial)
LLM API proxy, model routing, secrets, remote style config, style asset hosting, prompt versioning, feature flags, generation analytics, cost tracking, experiment assignment. Photo preprocessing stays on device unless evidence says otherwise. **[OPEN: backend stack]**

### 35. Privacy
There's no privacy marketing promise, but minimize uploads: local filtering → 30–60 candidates → compressed thumbnails + features → API. Never upload originals in bulk. Avoid long-term server storage of imagery.

### 36. Background processing (later)
Library changes → incremental indexing → event confidence rises → event looks closed → notification candidate. Opportunistic only: if background work fails, opening the app recovers.

### 37. Notifications (later)
*"Your Goa trip looks like a post. I found 3 stories."* Don't run expensive LLM planning until the user says yes.

---

## Part IX — Taste, Novelty, Instrumentation

### 38. Taste engine
**Model:** an *acceptable aesthetic range* made of hard boundaries (repeatedly rejected), soft affinities (often accepted), exploration tolerance, and context differences (nightlife ≠ travel).

**V1 = instrumentation only.** Don't overfit: one removed food photo doesn't mean the user dislikes food.

**Events:** `concept_selected|rejected|rerolled`, `photo_added|removed|swapped`, `cover_changed`, `slide_reordered`, `layout_changed|regenerated`, `element_resized|moved`, `carousel_exported|shared`, `generation_abandoned`.

### 39. Novelty engine
```text
FinalScore = BoundaryFit + StoryQuality + StyleCoherence + NoveltyVsHistory
           + ConceptDistinctiveness + EmotionalValue
           - RepetitionPenalty - TemplateFingerprintPenalty
```
**Exported-carousel fingerprint:** cover structure, primitive distribution, density sequence, overlap distribution, whitespace, decoration family, text use, grain, single/multi ratio, visual rhythm.

### 40. Cost instrumentation (per generation)
`modelProvider, model, promptVersion, inputTokens, outputTokens, imageCount, thumbnailBytes, latency, retryCount, estimatedCost, candidateCount, conceptCount`

### 41. Version everything (per generation)
`modelProvider, modelVersion, promptVersion, stylePackId, stylePackVersion, candidatePipelineVersion, rankingVersion, tasteProfileVersion, noveltyVersion, rendererVersion`

### 42. Analytics funnel
`moment_seen → story_selected → generation_started → concepts_presented → concept_selected → edit_session → exported → shared`

### 43. Quality metrics (tracked independently)
Selection quality · story quality · design quality · **design lift** (designed vs Plain) · personal fit · novelty · concept diversity · effort reduction.

**Optional failure feedback:** wrong photos / boring / too clean / too busy / not me / too AI / bad cover / too repetitive. Behavioral signals matter more.

### 44. Internal evaluation dataset (consenting users)
Event metadata, candidate features, generated concepts, selected concept, plain-vs-designed choice, edits, final plan, export/share, actual-post outcome, feedback. Keep derived structure instead of raw media where media shouldn't be retained.

**Research inputs:** Taste for Makers, The Shape of Design, personalized image-aesthetics research, PARA, AVA (generic prior only), and real target-user behavior.

---

## Part X — Validation

### 45. Phase 0 protocol
Recruit 12–15 target users, each bringing one genuine high-photo-count event of their own. For each participant:
1. Run the actual pipeline
2. Produce a Plain Dump + ≥2 designed concepts
3. Allow normal editing
4. Allow export/share
5. Observe behavior for 7 days

Optionally make a human-made reference carousel to estimate the design ceiling. Never mix handmade results with pipeline results.

### 46. Go/No-Go bar (written before testing)
| Signal | Bar | With n=15 |
|---|---|---|
| Minimum | ≥50% select a pipeline concept **and** export/share it **without substantially rebuilding** | ≥8 |
| Strong | ≥33% of cohort actually **post** a pipeline carousel within 7 days | ≥5 |

These are minimums, not stretch goals. **[OPEN: definition of "substantially rebuilding"; how posting is verified]**

**Also answer:**
- **Design lift:** Plain vs Designed vs Wildcard picks
- **Editing burden:** users replacing half the photos or rebuilding every slide means generation isn't working
- **Repeat demand:** do users volunteer another event?

### 47. Interpreting outcomes
| Case | Meaning |
|---|---|
| A — Designed dominates | Build the full art-direction system |
| B — Plain dominates | The product may be great selection and sequencing; don't force design |
| C — Liked but not posted | Entertaining, but doesn't solve the posting problem |
| D — Posted but heavily edited | Promising; art direction isn't good enough yet |
| E — Posted + returned with another event | Strongest signal |

### 48. Recognizability test (recurring)
Show outputs from several users and ask: *"Same app?"* If yes: raise primitive diversity, vary structure, reduce repeated decoration signatures, update style packs, and increase novelty penalties.

### 49. Major failure modes
Taste failure · template fingerprint · design overreach · over-personalization · conventional-aesthetic bias · bad event detection · social embarrassment · cost · latency · battery/thermal · permission friction · editor bloat · automation fragility.

---

## Part XI — Roadmap

| Phase | Goal | Build | Gate |
|---|---|---|---|
| **0 — Prove the magic** | Validate the core hypothesis | No polished app. Folder/date-range input (200–2,000 photos), local preprocessing, dup clustering, features, candidate reduction, API art director, simple rendering, Plain + Designed + Wildcard | §46 metrics, not compliments |
| **1 — Foreground iOS MVP** | Shippable app | SwiftUI app, Photos permission, incremental index, recent-moment discovery, manual date range, story selection, 3 concepts, 5–20 slides, Plain option, limited editor, Save/share, analytics, cost instrumentation, API proxy. **Day one:** StylePack schema, versioning, remote config, remote toggles, remote primitive/decoration params, prompt/config versioning | — |
| **2 — Improve intelligence** | Use behavior data | Story extraction, ranking, cover selection, diversity, novelty, design intensity, basic boundaries, style-pack quality, cost/latency. No neural personalization yet | — |
| **3 — Automation** | Proactive | Background indexing, event-closure confidence, proactive suggestions, notifications, multi-story recs, foreground catch-up | — |
| **4 — Deeper personalization** | — | Pairwise preference learning, context-specific taste, exploration tolerance, long-term novelty, anti-fingerprinting | — |
| **5 — Expansion** | Only after retention | Video, Live Photos, Instagram workflow, creator styles, marketplace, premium, Android, other formats | — |

### Phase 0 build order ("do not start with the iOS app")
1. **Dataset harness:** folder in → stable asset IDs → thumbnails
2. **Local analyzer:** timestamps, dimensions, duplicates, similarity, faces, scene tags, quality
3. **Candidate reducer:** 500–1,500 → ~30–60
4. **Plain Dump planner:** select and order 5–20; no design; the baseline
5. **Art director API:** candidates + thumbnails → Designed + Wildcard
6. **Constraint-based renderer:** semantic plan → slides
7. **Evaluation UI:** view, choose, reject/reroll, limited edits, export
8. **Run the 12–15 person study.** No background automation.
