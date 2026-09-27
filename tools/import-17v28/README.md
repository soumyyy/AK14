# Importing permitted 17V28 frames

The 17V28 account owner has permitted AK14 to use these assets; see
[`docs/design/designed-pages-grammar.md`](../../docs/design/designed-pages-grammar.md).
Keep the source app and extracted files out of the repository. The committed files
are normalized frame geometry and optimized PNG copies, with provenance in the
Render asset manifest.

On macOS with the source app installed, extract the largest CoreUI renditions:

```sh
swift tools/import-17v28/ExtractAssetCatalog.swift \
  /Applications/app17v28.app/Wrapper/app17v28.app/Assets.car \
  /tmp/17extract/frames \
  film-frame paper-frame polaroid-frame digital-frame pb-frame vday-frame layout-
```

Then import all definitions whose image was extracted. Valentine-category
frames are skipped by default; `--include-valentine` enables them for a later
import:

```sh
python3 tools/import-17v28/ImportFrames.py
python3 tools/import-17v28/ImportFrames.py --include-valentine
```

The importer tolerates trailing commas in `frames.json`, handles its plain and
digital frame geometry formats, rewrites PNGs losslessly with the system `sips`
tool, and regenerates `Assets/frames.json` plus frame entries in `manifest.json`.
