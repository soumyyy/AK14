# Implementation plan

1. Generation: correct template matching and thread vocabulary through composition, judging and final resolution. Test real compatibility and fallback behavior.
2. Rendering: retain provenance and legacy visual treatments in CanvasDocument; expose faithful document previews that use export rendering rules.
3. iOS: bind the main options canvas to the document, add direct contextual editing, retain native paging, persist edits, and restore Save/Share completion feedback and snapshots.
4. Integration: review parallel changes, run focused and full checks, inspect simulator screenshots, fix remaining issues, build and install on the connected phone.

Luna agents own the independent generation, rendering, and iOS areas. The parent handles integration, checks and device installation.
