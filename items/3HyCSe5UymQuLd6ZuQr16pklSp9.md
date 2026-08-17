Imported from whilp/cosmic#1123.

## Goal

G6 — the defining paths, via epic #1120. goals.md: &#34;where peers are the scoreboard, a
published table records absolute standing; the ambition is that sustained ratcheting
puts and keeps cosmic ahead, and the table says whether that is true — it never
gates.&#34; No such table exists anywhere today. This card is the startup table only —
the smallest defensible table — with the four shaping decisions settled below.

## Change

Publish, with every release, a ONE-METRIC peer table: the wall-clock cost of spawning
a hello-world script that prints `perf-hello`, measured for cosmic, CPython, Node and
Go on one machine in one job, by the harness that already measures
`startup_run_lua`.

**The task, identically for every row.** `_perf/bench/startup_bench.tl` spawns
` /hello.lua` through `cosmic.child.run`, asserts spawn + exit 0, trims
stdout, and its `check` requires stdout to equal exactly `perf-hello`; the harness
calibrates an iteration count so each sample lasts ≥ `DEFAULT_MIN_SAMPLE_SECS` and
takes `DEFAULT_SAMPLES` samples, reporting median wall ns/op with min/max/spread.
Every peer row runs that same shape: a script FILE that prints exactly `perf-hello`,
spawned through the same `child.run` capture path, timed by the same
`_perf.harness.run_scenario`, checked by the same exact-stdout rule. Not
`python3 -c pass` and not `node -e &#39;&#39;`: they produce no output, so the mandatory
`check()` every scenario must define (`_perf/perf_test.tl:61`) would have nothing to
verify, and they skip the script open+read that cosmic&#39;s row pays — a shorter task
for the peer than for cosmic is a table that flatters us.

The four rows, in this fixed order, which is the row order in every output:

| id | argv timed | artifact provenance |
|---|---|---|
| `cosmic-lua` | ` hello.lua` (`print(&#34;perf-hello&#34;)`) | prebuilt (`--bin`) |
| `cpython` | `python3 hello.py` (`print(&#34;perf-hello&#34;)`) | prebuilt, on PATH |
| `node` | `node hello.js` (`console.log(&#34;perf-hello&#34;)`) | prebuilt, on PATH |
| `go` | `./hello` | compiled at setup: `go build -o hello hello.go` |

Go&#39;s compile runs in setup, outside the timed region, because cosmic&#39;s binary is
prebuilt too — compilation is not part of the startup task. Each row records the
peer&#39;s version string, the artifact&#39;s path and byte size, its provenance, the exact
argv, and the probe argv that produced the version.

```facts
$ wc -l _perf/bench/startup_bench.tl
169 _perf/bench/startup_bench.tl
$ test -d _perf/peers &amp;&amp; echo exists || echo absent
absent
$ ls _perf
baseline.tl
baseline_test.tl
bench
compare.tl
compare_test.tl
gate.tl
gate_test.tl
harness.tl
harness_test.tl
perf_test.tl
perf_types.tl
run.tl
run_test.tl
stats.tl
stats_test.tl
$ ls _perf/bench | wc -l
17
$ grep -n &#34;^local DEFAULT_SAMPLES\|^local DEFAULT_MIN_SAMPLE_SECS&#34; _perf/harness.tl
21:local DEFAULT_SAMPLES = 5
22:local DEFAULT_MIN_SAMPLE_SECS = 0.15
$ grep -n &#34;s.check ~= nil&#34; _perf/perf_test.tl
61:      assert(s.check ~= nil, name .. &#34;/&#34; .. s.name
$ grep -n &#34;recursive = false&#34; _perf/run.tl
184:    {glob = &#34;*_bench.tl&#34;, recursive = false, sorted = true})
$ sed -n 205p cmd/cosmic/embed_gen.tl
    if f.path:sub(-3) == &#34;.tl&#34; and (f.kind == &#34;module&#34; or f.kind == &#34;entry&#34;) then
$ grep -o peers .github/workflows/release.yml | wc -l
0
$ wc -l .github/workflows/release.yml _build/workflows_test.tl
  251 .github/workflows/release.yml
  278 _build/workflows_test.tl
  529 total
$ grep -o &#39;\[&#34;[a-z]*\.yml:[a-z]*&#34;\]&#39; _build/workflows_test.tl
[&#34;pr.yml:smoke&#34;]
[&#34;release.yml:release&#34;]
```

Five new files under `_perf/peers/` (Teal, versioned, tested — the harness already
owns calibration, sampling, medians and the mandatory `check()`; workflow shell would
re-implement all of it untested), plus two edits. Keep each new file ≤ 200 lines,
well inside the 500-line cap.

1. **`_perf/peers/peers.tl`** — the registry and the measurement.
   - `record Peer` with `id`, `label`, `exe`, `probe_argv: {string}`, `script`,
     `source` (the hello text), `build_argv: {string} | nil`, and
     `run_argv: function(exe: string, target: string): {string}`.
   - `PEERS &lt; const &gt;: {Peer}` holding the four rows above in that order, and
     `EXPECT &lt; const &gt; = &#34;perf-hello&#34;`.
   - `check_stdout(out: string): boolean, string` — the exact-match rule, pure, so
     the check is unit-testable.
   - `probe(p: Peer): string | nil, string` — `child.run(p.probe_argv)`; a spawn
     failure or nonzero exit returns nil plus the reason; success returns the first
     line of stdout (falling back to stderr) trimmed.
   - `stage(dir: string, p: Peer): string | nil, string` — writes `p.source` to
     `dir/p.script`, runs `build_argv` in `dir` when present, and returns the path
     of the artifact to spawn.
   - `scenario(p: Peer, exe: string, target: string): pt.Scenario` — `fn` spawns
     `p.run_argv(exe, target)` via `child.run` and returns trimmed stdout; `check`
     is `check_stdout`. Same shape as `startup_bench.tl`&#39;s `spawn_capture`.
   - `measure(opts: MeasureOptions): Report, string` — staging directory from
     `fs.temp_dir(fs.join(TEST_TMPDIR or TMPDIR or &#34;/tmp&#34;, &#34;perf-peers-XXXXXX&#34;))`,
     removed with `fs.remove_all` when done. Per selected peer: probe, then either
     an `absent` row carrying the reason, or `harness.run_scenario` with the given
     `pt.Options` and a `measured` row carrying version, exe, `exe_bytes`
     (`fs.stat(...):size()`), provenance, argv, probe argv, `wall_ns`, `min_ns`,
     `max_ns`, `spread_pct`, `iterations`. cosmic&#39;s row takes its exe from
     `opts.bin` and its version from ` --version`; a cosmic row that fails to
     spawn or fails its check is an error return, not a row — a table without
     cosmic in it is not a table.
   - Local records `Row`, `Report {meta, task, rows}` and `PeerMeta` (timestamp,
     os, isa, nproc, samples, min_sample_secs, runner, cosmic_bin, cosmic_bin_sha
     via `hash.sha256_hex(fs.read(bin))` as `_perf/run.tl` does, cosmic_version).
     `runner` is `env.get(&#34;ImageOS&#34;) or &#34;local&#34;`.
2. **`_perf/peers/report.tl`** — pure rendering, no I/O:
   `format_markdown(rep: Report): string` (header naming the task and the one
   command that regenerates the table, the host/runner line, the table with columns
   `runtime | version | artifact | argv | ns/op | ±spread | iters` rendering ns
   through `harness.format_ns`, a fairness paragraph stating the same-task rule and
   Go&#39;s setup-time compile, a per-row `re-run` line, then the summary line LAST);
   `summary_line(rep): string` → `startup: cosmic-lua 1.23 ms | cpython 18.4 ms |
   node 31.2 ms | go 0.90 ms` (an absent peer renders `go absent`);
   `verdict(rep): string` → `peers: OK 4/4 measured`,
   `peers: OK 3/4 measured (absent: go)`, or `peers: FAIL ()`.
3. **`_perf/peers/run.tl`** — the one command, shaped like `_perf/baseline.tl`
   (shebang, `cosmic.flags` spec, `proc.is_main()` guard, module table, verdict line
   last). Flags: `--bin PATH` (default `PERF_BIN`, then `arg[-1]`, exactly
   `startup_bench.tl`&#39;s `find_bin` precedence), `--out FILE` (peers.json via
   `cosmic.json`), `--md FILE` (peers.md), `--samples N`, `--min-secs S`,
   `--only ID` (exact id match; matching nothing prints
   `peers: FAIL (--only  matched nothing)` and exits 1, mirroring
   `_perf/run.tl`&#39;s rule for the same flag). Creates parent directories for both
   outputs. Prints the markdown to stdout, then the verdict line; exits 0 on OK,
   1 on FAIL. It has no notion of a threshold and no comparison mode, so &#34;never
   gates&#34; is structural here rather than a workflow guard.
4. **`_perf/peers/peers_test.tl`** — no peer toolchain required: registry integrity
   (four peers, unique ids, cosmic first, fixed order, every `source` prints exactly
   `perf-hello`), `check_stdout` accepting `perf-hello` and rejecting `&#34;&#34;`,
   `&#34;hello&#34;`, `&#34;perf-hello extra&#34;`, `stage` writing each script peer&#39;s file under
   `TEST_TMPDIR` and returning its path (no execution), and `probe` of
   `{&#34;cosmic-no-such-peer-exe&#34;, &#34;--version&#34;}` returning nil with a reason.
5. **`_perf/peers/report_test.tl`** — pure: `format_markdown` over a literal 4-row
   `Report` (row order preserved, one row per peer), over a `Report` with an absent
   row, `summary_line`, `verdict` in all three cases, and that the markdown&#39;s LAST
   line is the summary line — the release notes read it with `tail -n1`.
6. **`.github/workflows/release.yml`** — one new job plus wiring, no other step
   touched:
   - a `peers` job: `needs: build`, `runs-on: ubuntu-latest`, **no container**,
     `timeout-minutes: 15`. Steps: `actions/checkout` and
     `actions/download-artifact` at the same pinned SHAs already used in this file,
     `name: cosmic-lua`, `path: dl/`; recover the binary with the same
     unzip-then-`find dl -type f -name cosmic` shape `pr.yml`&#39;s `smoke` job uses,
     `chmod +x`; then ONE command, the downloaded artifact run directly with no
     build and no fetch:
     `./cosmic _perf/peers/run.tl --bin ./cosmic --out o/perf/peers.json --md o/perf/peers.md`;
     then `actions/upload-artifact` at the pinned SHA, `name: cosmic-peers`, with
     both files. A comment records why the lane is uncontainerised (the pinned
     buildpack-deps image has python3 — `pr.yml`&#39;s `repro` job already relies on
     `python3 -m zipfile` — but no node and no go, while the runner image ships all
     three), that the versions are the runner image&#39;s and are recorded per row, and
     that the table reports standing and never gates.
   - the `release` job: `needs: [build, peers]`; locate `peers.json` and `peers.md`
     with the same `find artifacts -type f -name ...` pattern as the other assets,
     add both to the missing-asset guard, copy them into `release/`, attach both to
     `gh release create`, and extend `notes` with a third line,
     `&#34;$(tail -n1 release/peers.md)&#34;`.
7. **`_build/workflows_test.tl`** — add one entry to `UNCONTAINERISED` (line 103):
   `[&#34;release.yml:peers&#34;] = &#34;peer versions are the runner image&#39;s: the pinned
   container has no node and no go&#34;`. Without it
   `test_every_build_job_is_containerised` fails on the new job. Headroom: 278/500.

Ratchets: if the coverage stage complains about the new `_perf/peers/**` rows, run
`o/bin/cosmic --make coverage --baseline` and commit the result; if the cast ratchet
complains, run `bin/cosmic --make run _build/casts.tl --baseline` and commit it. Those
regen commands are in scope; no gate is weakened any other way, and every `as` cast
carries its `-- cast: `.

## Non-goals

- **The table never gates.** goals.md, G6: &#34;cosmic ahead on every defining path is
  the ambition the table reports, never a gate&#34;, and its outcomes preamble: &#34;where
  peers are the scoreboard, a published table records absolute standing ... it never
  gates.&#34; No threshold, no comparison, no verdict about speed anywhere in this
  slice. The only thing that fails the `peers` job is a broken cosmic row — an
  unspawnable binary or a failed `check()` — which is wrongness, not slowness.
- **No cycles-per-task peers.** G1&#39;s eval instrument owns those (goals.md G1: &#34;run
  against Python/Node/Go sandboxes on the same tasks&#34;). Nothing in this slice counts
  agent cycles, tokens, or errors.
- **Checker-latency peers are deferred.** No `tsc` row, no `mypy` row, no peer for
  `teal_check_module`. It earns its own card once this table exists; picking a
  defensible checker analogue is an open question and is not settled here.
- **One metric only.** No `startup_run_teal` row, no compile row, no embed-cycle
  row, no RSS or memory column, no second table.
- **Do not touch the perf results schema or the suite.** `_perf/perf_types.tl`,
  `_perf/run.tl`, `_perf/compare.tl`, `_perf/gate.tl`, `_perf/baseline.tl` and every
  `_perf/bench/**` module stay byte-unchanged: `perf.json` is what #1122 will gate
  on, and a peer row inside it would gate peers by accident. Read `pt.Scenario`,
  `pt.Options` and `pt.Measurement`; add no field to them.
- **Nothing under `_perf/bench/`, and no `*_bench.tl` name.** A bench module is
  auto-discovered by `_perf/run.tl` and by `_perf/perf_test.tl`, which would make
  every perf run and every CI test spawn peer toolchains.
- **No pinned peer toolchains and no new `*_pin.tl`.** Every `bin/cosmic --make
  fetch`, in every tree and every lane, resolves every pin; ~200 MB of toolchains on
  the trust root&#39;s fetch path for a report that never gates is not a trade this card
  makes.
- **No new `COSMIC_*` environment variable.** `_cli/env_vars.tl` is a ratcheted
  registry (`_build/env_vars_test.tl`); `--bin` and the existing `PERF_BIN` already
  select the binary.
- **No changes to `pr.yml` or `docs.yml`.** The gate lane is fenced (no network) and
  containerised (no node, no go), and docs.yml renders from the tree at push time
  with no release-time measurement, so neither can carry a measured table.
- **No new environment pins.** The `peers` job runs no build machinery, so the
  container/privilege/non-root-builder pins do not apply to it; that is exactly what
  the `UNCONTAINERISED` entry records.
- Never weaken a scenario or its `check()` to make a number look better.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _perf/peers/peers_test.tl _perf/peers/report_test.tl`
  ends `test: PASS (2 files)`.
- `bin/cosmic --make test _build/workflows_test.tl` ends `test: PASS (1 file)` —
  this is what proves the new uncontainerised job is recorded rather than
  accidental.
- The table comes from ONE command:
  `bin/cosmic --make run _perf/peers/run.tl --bin o/bin/cosmic --out o/perf/peers.json --md o/perf/peers.md`
  ends `peers: OK 4/4 measured` on a host with `python3`, `node` and `go` on PATH.
  On a host missing one it ends `peers: OK /4 measured (absent: )` and that
  peer&#39;s row reads `absent` — also a pass. `peers: FAIL (...)` is not a pass. Paste
  the verdict line and the rendered table into the PR body, so the reviewer sees the
  peer versions the run recorded.
- Every cell is traceable to a re-runnable command:
  `bin/cosmic --make run _perf/peers/run.tl --bin o/bin/cosmic --only cpython --out o/perf/cell.json --md o/perf/cell.md`
  ends `peers: OK 1/1 measured`, and the full table&#39;s `re-run` line for the
  `cpython` row is exactly that command&#39;s `--only cpython` form.
- `bin/cosmic --make run _perf/peers/run.tl --bin o/bin/cosmic --only nosuch` ends
  `peers: FAIL (--only nosuch matched nothing)` and exits 1.
- `tail -n1 o/perf/peers.md` prints the summary line and it starts with
  `startup: ` — that line is what the release notes carry.
- The release job&#39;s invocation shape works with no build and no fetch:
  `o/bin/cosmic _perf/peers/run.tl --bin o/bin/cosmic --out o/perf/bare.json --md o/perf/bare.md`
  (the built binary, invoked directly, no `--make`) ends with the same verdict line
  as the `--make run` invocation. The artifact carries `_perf/**` (see the
  `embed_gen.tl` fact above), so the workflow needs neither.
- `ls _perf/peers | grep -o &#39;_bench\.tl&#39; | wc -l` prints `0`.
- `grep -c &#39;^  peers:&#39; .github/workflows/release.yml` prints `1`.

**What CI cannot check, stated plainly.** No `--make ci` lane measures a single cell:
the gate lane is fenced and containerised, so it has neither a network nor node nor
go. In CI only the pure tests run (the two `--make test` lines above), which cover the
registry, the exact-stdout check, the staging, the absent-row path, the markdown, the
summary line and the verdict grammar. The measured cells are verified by the local
runs above — recorded in the PR body — and by the `peers` job itself, whose first real
run is the next release. A peer that vanishes from the runner image therefore shows up
as an `absent` row in a published table, never as a red release: that is the intended
failure mode for a report that never gates.

## Enablement

none needed. All four shaping decisions are settled in `Change` above (same-task
rule, runner-preinstalled versions recorded per row, release assets as the home,
`_perf/peers/` Teal modules). The machinery exists: `_perf/harness.tl` supplies
calibration, sampling, medians, spread and the mandatory `check()`;
`_perf/bench/startup_bench.tl` is the spawn-and-verify shape to copy;
`_perf/baseline.tl` is the file shape for a `--make run` script with a verdict line;
`release.yml` already publishes `perf.json`/`size.json` assets and builds its notes
from asset tail lines. The one non-obvious trap — a new uncontainerised job failing
`_build/workflows_test.tl` — is named in `Change` with its exact key and reason, and
that ratchet&#39;s failure message already tells an implementer what to do.

**On size, stated for you rather than discovered by you.** This is a large slice —
five new files plus two workflow edits, near the one-session threshold. It is kept
whole because G6&#39;s outcome is a table PUBLISHED with each release, and a card that
measures without publishing does not move that win condition. If it does not fit
one session, do not improvise a split: the seam is items 1-5 and 7 (the
`_perf/peers/` modules, their tests, and the `UNCONTAINERISED` entry — everything
locally runnable and fully covered by the two `--make test` lines) versus item 6
(the `release.yml` job, asset wiring and notes line). Bounce the card naming that
seam and the planner will cut it there.


---
_Generated by [Claude Code](https://claude.ai/code)_