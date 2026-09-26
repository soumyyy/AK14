# AK14 Phase 0 — Operator Guide

## Before the session

- `git pull`, then `swift build -c release`. Check that `.build/release/ak14 versions` matches `docs/study/protocol.md`.
- `OPENAI_API_KEY` is set in `.env`, which is gitignored. Run `ak14 run <small test folder> --yes` once to confirm the model answers.
- Have the participant's study code ready (`P01`…`P15`). Never use names.

## 1. Consent

Read `docs/study/consent.md` aloud and answer questions. Continue only after a clear yes.

## 2. Getting the photos onto the Mac (keeping metadata)

On the participant's iPhone:
1. **Photos:** select the event's photos, which should be the whole event (200–2,000 photos).
2. **Share → Options:** turn **Location** on and **All Photos Data** on. This keeps capture time and location, which the story detection needs.
3. **Share → AirDrop →** the operator Mac. The files land in `~/Downloads`. Move them into one folder, e.g. `~/Study/P07/`.

Don't use WhatsApp, Messages or screenshots: they strip the metadata. Videos are fine to include; AK14 skips them.

## 3. Run

```bash
.build/release/ak14 run ~/Study/P07 --study-code P07
```

- **Consent prompt:** the disclosure prints, then `Send thumbnails to the model? [y/N]`. Answer `y` only with the participant's consent.
- **Time:** about 1–2 minutes for 500 photos on the first run (analysis is cached after that). The model costs well under $0.05.
- **Interrupted run:** just run it again. Local work is reused, and the interrupted run shows as incomplete and isn't counted.
- **No consent or no model:** runs made without consent, or where the model was skipped, have no concepts. They never count as the participant's study run or as repeat demand.
- **What the model sees:** the model gets "a personal event" and its length in days, never the folder name or calendar dates. It's still good practice to name intake folders by study code only.

## 4. Review in Studio (with the participant)

```bash
swift run -c release Studio
```

1. Pick the run. Studio asks once for the source folder (`~/Study/P07`) and checks that the photos are unchanged.
2. Compare **Plain Dump**, **Designed** and **Wildcard**.
3. The allowed edits:
   - **Move earlier/later**
   - **Swap…** (similar shots first)
   - **Remove**
   - **Reroll layout**

   Don't edit on the participant's behalf. Let them drive, and keep quiet about your own preference.
4. They click **Use this** on the concept they would post.

All actions are logged in the run's `interaction-events.jsonl` and appear in `report.html`.

## 5. Hand-off to the phone

Either:
- **Share** (the button next to Export) → AirDrop to their iPhone, or
- **Export…** to a folder, then AirDrop the ordered `ak14-<concept>-NN.png` files.

On the phone, the slides arrive in order, ready for an Instagram carousel. The slides are 1080 px wide at the run's aspect ratio (3:4, 4:5 or 1:1).

## 6. Day-7 follow-up

Ask whether they posted it, **how many days after receiving it**, where, and whether they'd use AK14 for another event. Record it on the participant's study run:

```bash
.build/release/ak14 followup runs/<runID> --posted yes --posted-days 3 --platform instagram --reused-another-event yes --link-seen yes
```

`--posted-days` is required when `--posted yes`. Posting counts toward the strong signal only if it happened 0–7 days after hand-off and the selected concept was exported or shared.

If they want to try another event, run it with the **same** study code. That counts as repeat demand.

## 7. Results

```bash
.build/release/ak14 study summary runs --out results/
```

This writes `study-summary.md` and `study-summary.json`: the go/no-go table, the 20%/30%/40% sensitivity, picks and per-participant rows.

## 8. Deletion (end of study, or on request)

```bash
.build/release/ak14 delete --study-code P07 --purge-cache
rm -rf ~/Study/P07
```

This removes **every** run recorded under that code, including interrupted and no-consent runs, plus any cached thumbnails or analysis that no other run uses. Also delete any folders you exported their slides to. If you used a non-default `--cache DIR` for `run`, pass the same `--cache DIR` here. `ak14 delete` refuses anything that isn't a single run directory.
