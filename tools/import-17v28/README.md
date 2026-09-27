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

Import the complete locally available template vocabulary with:

```sh
swift tools/import-17v28/import.swift
```

Template JSON is decoded after trailing commas are removed. The output keeps
photo-slot geometry, corner radii, role-only text styling, mapped bundled-font
IDs, resolvable frame IDs, category families, backgrounds, and decorative
coverage. Literal source sample text is intentionally discarded. Pages with
decorative coverage over 12% or decoration intersecting a photo slot are
reported as rejected and are not written to `designed-sets.json`; the contact
sheets are written under `/tmp` for review only.
