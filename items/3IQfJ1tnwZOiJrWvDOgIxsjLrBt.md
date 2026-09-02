## Goal

G3 — an honest type layer. The `cosmic/**` half of the parent's
`check.must` sweep: the bulk of the test/example census, and the half
that still needs a cut of its own before any of it is pullable.

**Measured.** The parent (3IPXQ1Zw) re-ran the census's Method
(`docs/design/nil-flow.md`, `## Method`) on a tree carrying the four
narrowing rules and recorded **101 sites in 29 files** under
`cosmic/**`, measured 2026-08-25 against a tree carrying PR #1383,
which has since landed (`57dda9bd`).

**Re-measured 2026-09-02 at `5a36e7c9`: 103 sites in the same 29
files** (`cosmic/embed_test.tl` 9 → 11, two more tests of the same
shape from #1590/#1593; every other file unmoved). The strict binary
reproduced the Method's proof-of-life (all six diagnostics) and both
sink-shape probes before the scan was trusted. Full per-file table:

```text
cosmic/time_parse_test.tl 12   cosmic/proc_test.tl 4            cosmic/signal_test.tl 2
cosmic/fetch/verbs_test.tl 11  cosmic/script_test.tl 3          cosmic/fs/walk_test.tl 2
cosmic/embed_test.tl 11        cosmic/quicksand/caps_test.tl 3  cosmic/fetch/stream_test.tl 2
cosmic/embed_advanced_test.tl 7  cosmic/net/init_test.tl 3      cosmic/embed_env_test.tl 2
cosmic/tty_pty_test.tl 6       cosmic/net/connect_test.tl 3     1 each: stream_test, signal_example,
cosmic/fs/path_test.tl 6       cosmic/json_test.tl 3            quicksand/proxy/serve_test, net/io_test,
cosmic/fd_test.tl 5            cosmic/fetch/init_test.tl 3      hash_test, fs/walk_example, fs/traps_test,
cosmic/check_test.tl 5                                          fetch/retry_test, fetch/multiheader_test,
                                                                codec_test
```

The same scan's other shares, which every child quotes as its
"unmoved" baseline: `cosmic/**` library **12** rows (all under
`cosmic/sandbox/`: `init.tl` 8, `landlock.tl` 3, `plan.tl` 1);
non-`cosmic/**` test/example/benchmark **0**; non-`cosmic/**` other
**11** (all `_perf/bench/*_bench.tl`, outside every sweep item);
total **126**.

The committed pre-rules census holds 145 rows in the same tree
(measured 2026-08-26, re-confirmed 2026-09-02):

```text
awk -F'\t' '$1 ~ /_test\.tl$|_example\.tl$|_benchmark\.tl$/ && $1 ~ /^cosmic\//' \
  docs/design/nil-flow-sites.tsv | wc -l
```

## Change

**This is a container, not a slice.** 103 sites across 29 files is
several sessions' worth of diff, and two sessions editing one file is
the merge conflict the cut exists to avoid. The 2026-09-02 pass cut
the current `cosmic/**` rows into five file-disjoint children under
this item, each carrying its measured file list, count, and
acceptance:

| child | files | rows | edits |
|---|---|---|---|
| `cosmic/fs/**` | 4 | 10 | 1 wrap + 5 loop-variable wraps |
| `cosmic/fetch/**` | 5 | 18 | 7 wraps + 1 loop-variable wrap + 11 declared-type widenings |
| `cosmic/net/**` + `cosmic/quicksand/**` | 5 | 11 | 9 wraps + 1 loop-variable wrap |
| flat A: `embed_test`, `embed_advanced_test`, `embed_env_test`, `time_parse_test` | 4 | 32 | 29 wraps + 1 `require` |
| flat B: the other 11 flat files | 11 | 32 | 21 wraps + 4 declaration widenings + 1 must-for-assert swap + 1 `require` |

(`cosmic/net/**` and `cosmic/quicksand/**` are subtrees the original
three-way cut did not name; they are file-disjoint from every other
child.) A "wrap" is the sibling's move — wrap the producing call in
`check.must` so the local is a plain `T`, adding
`local check = require("cosmic.check")` where absent. Three other
shapes recur and are named per site in the children:

- **loop variable** (7 rows): the value is a `for … in` variable
  over an iterator the library declares `function(): string | nil`
  (`fs.find_iter`'s `FileIter.__call`, `stream.lines`' `LineIter`,
  `fetch` `Body.lines`); tl types the variable from the iterator's
  first return, so the terminating nil leaks into the body. There is
  no producing call to wrap; the test-side fix is
  `check.must(<var>)` at the use.
- **declared-type widening**: a test-local declaration narrower than
  what it receives (`local ok: number` then `ok, err = …`;
  `echo_request`'s callback type in `fetch/verbs_test.tl`). Widen the
  declaration to `T | nil`; the existing assert already guards.
- **deliberate nil branch** (1 row, `cosmic/fd_test.tl:305`): keeps
  its shape with the widening above; named in its PR.

## Non-goals

- **No file outside `cosmic/**`.** The tooling trees and the tail are
  the sibling item.
- **No library-code `check.must`.** It throws, and AGENTS.md forbids
  it. Only `_test.tl`, `_example.tl` and `_benchmark.tl` — including
  the `_test.tl` files that sit beside library sources under
  `cosmic/`. The three iterator declarations behind the loop-variable
  rows are library types and stay untouched here.
- **No checker change.** `3p/tl/tl_patch/**` and `_make/patch.tl` are
  untouched.
- **Do not change what a test asserts.**
- **Do not rewrite `docs/design/nil-flow.md` or its `.tsv`.**

## Acceptance

This container is done when its five children are done and the
outcome is observable directly: re-running the census's Method over
the tree reports **0** rows under `cosmic/**` in `*_test.tl`,
`*_example.tl` and `*_benchmark.tl`, except deliberate nil-branch
tests named in their own PRs —

```text
git ls-files '*.tl' | grep -v '/testdata/' | xargs o/bin/cosmic --check types \
  | grep -E '^cosmic/' | grep -E '_(test|example|benchmark)\.tl'
```

— with the library share unmoved at **12** and the non-`cosmic/**`
shares unmoved at **0** / **11**, and `bin/cosmic --make ci` ending
`ci: PASS`.

## Enablement

none needed for the decomposition. The site list comes from
`docs/design/nil-flow.md`'s `## Method`, re-run; `cosmic.check`'s
contract is in AGENTS.md and `cosmic --docs cosmic.check`. The four
narrowing rules these counts assume landed as `57dda9bd`.

Practical recipe the 2026-09-02 pass used, for a child re-deriving
its baseline: `bin/cosmic --make build` from the pin, then
`cp o/bin/cosmic o/cosmic-lax`; apply the Method's two hinges to
`o/3p/tl/tl.lua` (the narrow patch set is already applied there and
shares no anchor with either hinge); `o/cosmic-lax --make build` —
`build` is not a converging gate, so the lax copy builds the strict
`o/bin/cosmic` without re-exec'ing into it; run the proof-of-life
probe; scan. Restore afterwards with `rm -rf o/3p/tl && bin/cosmic
--make fetch && cp o/cosmic-lax o/bin/cosmic` — a hinged `tl.lua`
still contains every patch `replace` string, so `fetch` alone reads
it as already patched and will not restore it.
