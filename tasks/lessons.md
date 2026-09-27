
## 2026-09-26
- Never chain `swift test | grep ... && git commit && git push`: the grep succeeds even when tests fail, so a failing tree got pushed. Check the "Test run with … passed" line first, then commit in a separate step.
- Tests over composed carousels must not assume a style axis survives: runs have random ids (seeds), and the composer's diversity remedy may legitimately nudge an axis. Assert invariants (counts, bounds), not seed-dependent values. Run the suite three times after touching the composer.
- Don't impose hard aesthetic rules (such as a time limit for grouping). The owner wants grouping driven by how photos look together, with every rule a soft cost.
- Codex delegation: always run `codex exec ... < /dev/null`. Without it, Codex waits on stdin forever ("Reading additional input from stdin..."). Pass images with `-i` only when the prompt comes on stdin, because `-i <FILE>...` swallows the positional prompt.
- A wait loop that greps `ps` for a pattern also contained in its own command line waits on itself forever. Use `pgrep -f` on the actual binary (codex-darwin), or wait on a PID or a completion file.
- Luna's sandbox can't read fixture photos or run the simulator, so its "checks passed" never covers e2e or UI. Always run the full suite and the UI test before merging.

## cursor-agent -p stops to ask for confirmation (2026-09-27)
In print mode, Cursor models (gpt-5.6-luna-high) propose a design, ask "please confirm", and exit without editing. Every brief must end with: "Implement now. Do not ask for confirmation; you are running non-interactively."
