
## 2026-09-26
- Never chain `swift test | grep ... && git commit && git push`: the grep succeeds even when tests fail, so a failing tree got pushed. Check the "Test run with … passed" line first, then commit in a separate step.
- Tests over composed carousels must not assume a style axis survives: runs have random ids (seeds), and the composer's diversity remedy may legitimately nudge an axis. Assert invariants (counts, bounds), not seed-dependent values. Run the suite three times after touching the composer.
- Don't impose hard aesthetic rules (such as a time limit for grouping). The owner wants grouping driven by how photos look together, with every rule a soft cost.
