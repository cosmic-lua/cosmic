# Migrate the tree to runner mode

D29's last mechanical step: delete the test self-call lines across the
tree so every `*_test.tl` runs because the toolchain found its cases,
not because the file calls them. The compile seam that makes this
possible landed (#1446); what remains is the edit itself, cut into
file-disjoint batches that land independently.

**Observable outcome** (the exit test for this container): every
`*_test.tl` in the tree classifies `runner` or `empty` under
`_tool/discover`, no file classifies `legacy` or `mixed`,
`bin/cosmic --make ci` ends `ci: PASS`, and `grep -rn
'^test_[A-Za-z0-9_]*()$' --include='*_test.tl' .` (excluding `o/`)
returns nothing.

## What is measured, and stays true for every child

Measured 2026-08-27 against `origin/main` at `cb39b65d`, with the
commands beside each claim.

- **2,946 self-call lines in 275 test files.** The pattern is exactly
  `^test_[A-Za-z0-9_]*()$` — a bare call, no indentation, no
  arguments. Command: the probe below; the capture's 2,786 in 260
  files is the same shape, measured earlier.
- **The mechanical edit is complete: 0 files fail to reach runner
  mode.** Deleting every line matching that pattern and re-classifying
  with `_tool.discover` (token-exact, the same walk the seam and the
  lint use) leaves 0 of 275 files in `legacy` or `mixed`. So the
  capture's hedge — "a file whose calls are load-bearing beyond
  invocation (if any) is left legacy and noted" — has an answer:
  there are none, and no child needs an exception list. Run it again
  before a batch if the tree has moved:

  ```lua
  -- save outside the tree; a *.tl inside it joins the build graph
  local discover = require("_tool.discover")
  local fs = require("cosmic.fs")
  local function lines_of(c: string): {string}
    local out: {string} = {}
    for l in (c .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = l end
    return out
  end
  for _, p in ipairs(fs.find(".", {glob = "*_test.tl", sorted = true})) do
    local src = fs.read(p)
    local kept: {string} = {}
    for _, l in ipairs(lines_of(src)) do
      if not l:match("^test_[A-Za-z0-9_]*%(%)$") then kept[#kept + 1] = l end
    end
    local after = table.concat(kept, "\n")
    local d = discover.discover(p, after, lines_of(after))
    if d.mode ~= "runner" and d.mode ~= "empty" then print(p, d.mode) end
  end
  ```

  Run it as `o/bin/cosmic /path/outside/the/tree/probe.tl` from the
  repo root. It must print nothing.
- **The deletion is fmt-, check- and lint-clean.** Applied to
  `_build/**` (12 files, 43 lines) as a trial: `--make fmt` → `fmt:
  PASS (547 files)`, `--make check _build` → `check: PASS (19 files)`,
  `--make lint _build` → `lint: PASS (19 files)`. Deleting the call
  line leaves the blank line that followed it, which is what fmt
  already wants, so no reflow rides along.
- **`--make check` still passes in THIS repo**, though the seam does
  not reach `_make/check.tl` (3IU4umVT): gate verbs converge here, so
  the build compiles every test file through the seam first and
  `proved_by_graph` skips them all. 3IU4umVT is a downstream bug, not
  a blocker for these batches — but it should land before anyone
  outside this repo is told to write runner-mode tests.
- **The coverage ratchet has nothing to say.** `grep -c "_test.tl"
  .cosmic-coverage` → 0: the floor holds source rows only, and the
  tail runs the same cases the deleted lines did, so no source row
  moves down. The standard clause still applies to every child: if
  the gate does complain, run exactly the regen command its failure
  message prints and commit the result — never weaken it another way.

## The blocker every batch shares

**The cold-build rule bites.** `_build/coldbuild_test.tl` type-checks
the whole tree with the PINNED release's checker
(`BOOTSTRAP --check types --include-dir . …`), and the pin
(`bin/cosmic.pin`, `2026-08-27-6b88a0d`) predates the seam, so a
runner-mode file fails it with the uncalled-local warning. Measured on
the `_build` trial: `--make test _build` → `test: FAIL (1 of 12
files)`, `_build/workflows_test.tl:115:1: warning: unused function
test_the_image_is_pinned_by_digest`, with coldbuild's own assertion
message naming the remedy — "Stage the change behind a release + pin
bump".

So the first child is the pin bump to a release carrying #1446, and
every batch is blocked on it. #1446 merged 2026-08-27 04:40Z, ahead of
release.yml's daily 06:00 cron, so the release that carries it is the
next one.

## Cutting the batches

File-disjoint by directory, each a pure deletion of 300–500 lines —
sized so the whole diff is one reviewable mechanical edit and two
batches never touch one file. Counts are self-call lines, measured as
above:

| batch | scope | lines |
|-------|-------|-------|
| 1 | `_build`, `_docs`, `_types`, `3p`, `_fuzz`, `_eval`, `_perf`, `_tool` | 481 |
| 2 | `_cli`, `_make` | 483 |
| 3 | `cosmic/{fs,child,format,flags,coverage,sandbox}` | 338 |
| 4 | `cosmic/{sqlite,quicksand,fetch,net,doc}` | 414 |
| 5 | `cosmic/*.tl`, `_literal_format_test.tl` … `hash_test.tl` | 420 |
| 6 | `cosmic/*.tl`, `html_test.tl` … `sse_test.tl` | 404 |
| 7 | `cosmic/*.tl`, `stream_test.tl` … `zip_test.tl` | 406 |

Batches 5–7 are contiguous alphabetical spans of the 70 top-level
`cosmic/*_test.tl` files; the boundaries are file names, so a file
added between two batches belongs to whichever span its name falls in
and no batch has to be re-cut.

## Walls for every batch

No semantic edits ride along: the diff is deletions of the self-call
lines and nothing else — no renames, no assertion changes, no test
added or removed, no reflow. No change to `cosmic/test.tl`,
`_tool/seam.tl`, `_tool/discover.tl`, or the `call-after-define` lint
(retiring it is 3IOCdvXF; it passes on a runner-mode file already). No
testrun or report change (3IOCdZCA). No file outside the batch's
scope.
