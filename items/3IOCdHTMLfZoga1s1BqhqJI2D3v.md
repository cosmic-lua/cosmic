For a runner-mode `_test.tl`, the compile seam appends the generated
tail — `return require("cosmic.test").main({...})` from the
discovery module's case list — to the source fed to BOTH the strict
type check and the compiler, so warnings-as-errors holds (no
unused-local for uncalled tests) and the checker checks what runs.
Appending changes no line number; the tree, fmt, and legacy-mode
files are untouched. After this lands, a runner-mode file builds and
runs end to end under `--make test`. Context:
docs/design/test-runner.md (branch claude/cosmic-test-runner-rgb819).
