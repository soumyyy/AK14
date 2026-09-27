# Director latency review — 2026-09-27

## Measurement

This review uses the redacted exchanges under `runs/*/llm/` and the corresponding
`manifest.json` files. Image byte counts come from `providerCalls.thumbnailBytes`;
the persisted exchanges replace image payloads with `thumbnail:<asset-id>` references,
so their JSON byte size is not the upload size.

The ten recorded runs contain a 458-photo event and show a director stage of
36.5–108.6 s (median 48.2 s). The normal successful path is:

```text
triage ──> pool selection ──> planner ──> local composition
                              └─> repair/retry only after invalid output
```

Triage and planner cannot overlap: the planner's candidate pool and triage scores
are inputs to planning. Repairs and retries are also sequential because each
uses the previous response. The optional occasion split is a separate call before
the app's generation pipeline: `ImportReviewView` invokes it, then passes the
accepted result into `StoryPipeline`. It therefore adds serial wall time on the
iPhone, although it is not present in these CLI run artifacts. Judge calls, when
enabled, are serial per direction and perform two serial rankings per direction.

| Call | Images / upload bytes | System chars | User text chars | Input tokens | Output tokens (reasoning) | Observed latency |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| triage (10) | 60 / 529,440 | 2,014 | 7,401–7,406 | 5,573–5,584 | 2,464–2,577 (0–73) | 13.2–18.5 s |
| planner (10) | 24–35 / 990,518–1,525,752 | 3,195–4,070 | 7,112–8,894 | 7,855–10,586 | 3,060–5,058 (1,168–3,178) | 21.5–34.7 s |
| repair (3) | 0 / 0 | 341 | 3,941–10,054 | 4,480–4,945 | 933–2,832 (53–191) | 7.3–20.9 s |
| retry (1) | 24 / 990,518 | 3,195 | 7,229 | 7,904 | 4,978 (2,225) | 42.5 s |

The planner is the largest predictable cost, while retries create the largest
tail. The triage request is already low-detail, but it still sends 60 images.
The planner sends high-detail 384 px thumbnails for up to the whole planning
pool. The planner schema is intentionally rich: it asks for a spine, transition
reasons, and multiple directions, so output is materially larger than triage.

## Ranked changes

| Rank | Change | Expected saving | Risk / status |
| ---: | --- | --- | --- |
| 1 | Lower the maximum output allowance from the accidental 16k default to 5k for triage/repair and 8k for planner/retry; cap judge at 4k. | Usually 0–5 s; larger protection against long incomplete-response tails. | Implemented. Caps are above every observed completed call and preserve the request/response schemas. |
| 2 | Generate the independent triage and planning thumbnails concurrently in `StoryPipeline`. | Saves the slower thumbnail-preparation duration rather than their sum; likely sub-second on cached iPhone inputs, more on first decode. | Implemented. Both tiers and their bytes are unchanged. |
| 3 | Run independent occasion classification concurrently with generation preparation when the selected event is already known. | Up to the full occasion-split latency, commonly 5–20 s on the critical path. | Not implemented: the current iOS flow needs the accepted split before it chooses event segments, and the allowed files do not include the caller that starts the split. Requires a flow-level change plus cancellation/error tests. |
| 4 | Reduce triage image count, triage JPEG quality, or planning image tier/count. | Potentially 5–20 s, depending on provider vision processing. | Proposal only. This changes visual evidence and can miss safety, emotion, or story context; run an offline quality comparison before adopting. |
| 5 | Use lower reasoning effort for the planner and retry. | Potentially 8–20 s on the dominant planner call. | Proposal only. Recorded planner reasoning is 1,168–3,178 tokens; lowering it can change selection quality even though the JSON schema remains valid. |
| 6 | Trim planner instructions/schema fields or cap the number of directions. | Potentially 5–15 s and less output. | Proposal only. Removing rationale, transitions, or directions changes the creative brief and may reduce option quality. |
| 7 | Stream responses. | Improves time-to-first-result, but likely little change to completed-generation latency. | Proposal only. Requires incremental JSON handling and does not remove serial dependencies. |
| 8 | Add provider prompt-cache keys for repeated system prompts. | Unknown; likely small network/provider-side saving. | Proposal only. Requires confirming provider support and Worker allow-list compatibility; current calls already set `store: false`. |

## Safe implementation

`ArtDirector` now supplies explicit stage-specific `max_output_tokens` values.
The model, strict schemas, image details, prompts, and response decoding are
unchanged. The 5k/8k ceilings leave headroom over the recorded maxima rather
than changing the normal output budget. `StoryPipeline` also generates its
independent triage and planning thumbnail tiers concurrently; it does not alter
either tier's dimensions or JPEG quality.

This is deliberately a bounded improvement rather than a claim that the
roughly-2× target is met. The recorded successful calls do not approach the old
16k ceiling, so caps alone cannot explain a twofold median reduction. The
highest-leverage candidates are the image reduction and planner reasoning
changes, but both require a quality evaluation before production rollout.

## A/B result and decision (2026-09-27)

Largest IMG event (412 photos), 2 runs per arm, same build (`/tmp/ak14-speed`):

| Arm | Planner | Director stage |
| --- | ---: | ---: |
| medium reasoning, high detail (old default) | 32–41 s | 55–67 s |
| low reasoning | 15–16 s | 39–41 s |
| low detail | 25–30 s | 45–58 s |
| both | 13–16 s | 36 s (one run was 315 s: a composition slowdown, fixed in 924f015) |

A side-by-side review of the rendered options found comparable stories, photo choices and template use with low reasoning; one run repeated two similar shots. The owner approved **low reasoning as the default**. Image detail stays high, because low detail saved little. `AK14_PLANNER_REASONING=medium` restores the old behaviour for comparisons.
