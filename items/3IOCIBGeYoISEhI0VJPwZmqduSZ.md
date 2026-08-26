# A test runner: tests run because they are defined

Today a `_test.tl` is a script: every `test_*` function must call
itself on the line after its `end` (2,786 call lines across 260
files), the first failure kills the whole file, tests have no per-test
identity in the report, and there is no name filter. The proposed
shape is charted in the 253-line `docs/design/test-runner.md` added by
design-only PR whilp/cosmic#1366, closed in favor of this item. **Read
it in that PR's diff** — the branch it lived on,
`claude/cosmic-test-runner-rgb819`, has been deleted and the file is in
no reachable ref (`git ls-remote --heads origin | grep rgb819` is empty,
checked 2026-08-26). Every child item under this container still cites
the branch; the PR is the durable location. The shape: discovery by name
via the lexer walk the `call-after-define` lint already uses, a
generated in-chunk tail (`return require("cosmic.test").main({...})`)
appended at the compile/check seam, a small public `cosmic/test.tl`
runner that continues past failure and keeps the 0/2/fail exit
grammar, all-or-nothing legacy/runner mode dispatch so migration is
incremental per file (old toolchains reject new-style files loudly via
warnings-as-errors), per-test statuses in the `.tests` sidecar, and a
`--filter` substring matching the benchmark/example contract. The
doc's decision table records the rejected alternatives (registration
API, `Example_*`-style body extraction, `_ENV` scanning, a `t`
handle) and a phasing: decision record, runner module, toolchain,
mechanical migration, retire the legacy arm. Decomposition into
slices should follow that phasing.
