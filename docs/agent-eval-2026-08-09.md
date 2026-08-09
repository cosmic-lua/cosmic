# Agent Eval Round — 2026-08-09

> A dated round log from the `agent-eval` skill, not live guidance.
> Identifiers cited are the ones the candidate binary shipped.

Four Sonnet agents, four briefs, one file each: the `cosmic` binary.
Candidate built from `6473ef6` (cosmos pin `2026.08.08-7d8770074`),
gate verdict `ci: PASS (5 stages)` before staging.

## Isolation

The probe returned `cosmic: NONE`, `Teal: NONE`; a second probe
confirmed each agent's cwd was its own empty workspace. `Skill` was
disallowed (drops the skill roster), `CLAUDE_CODE_SESSION_ID`,
`CLAUDE_CODE_CHILD_SESSION` and
`CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD` were unset, and each
agent got a throwaway `HOME`. All four self-reported no cosmic/Teal
priming; all four reported the same general prior knowledge — Teal as
a typed Lua dialect, and Cosmopolitan's APE format — with everything
cosmic-specific coming from `--help`/`--docs`. This is the cleanest
isolation any round has had, so the numbers are not lower bounds.

## Results

| agent | brief | surfaces | built+tested | first build | green ci |
|-------|-------|----------|--------------|-------------|----------|
| 1 | `notes` — JSON-backed CLI, subcommands, 3 error paths | flags, fs, json | yes | 2 | 2 |
| 2 | `logstat` — CLF parser/aggregator, `--since` | string, time, testdata | yes | 2 | 2 |
| 3 | `bookmarks` — SQLite CRUD, m2m, upsert | sqlite, flags | yes | 1 | 3 |
| 4 | `sitegen` — 4 modules + e2e | imports, project model | yes | 1 | 2 |

4/4 succeeded. Verified independently, not from self-reports: every
`o/bin/<name>` exists and runs (notes' three error paths exit 1 with a
message and no traceback; bookmarks' duplicate-URL add updates row #1
and rm drops the join rows; logstat reports 13 requests / 4 malformed
over its fixtures; sitegen renders three pages with the index ordered
newest-first), and `--make ci` re-run in each workspace prints
`ci: PASS (4 stages)`.

Every ci failure across all four agents was `fmt` drift, except agent
1's, which added three unjustified `as` casts. No agent hit a
narrowing trap — the error-site hints from the August rounds appear to
be holding.

## Findings

Ranked by cost paid, each reproduced against the binary. P1-P5 were
fixed in the same change as this record; the reproductions below are
what the binary did BEFORE those fixes.

### P1 — `--docs` publishes private locals as public API

`--docs cosmic.time` documents `parse_offset` with a full signature
and prose. It does not exist: `cosmic.time` exports `parse_iso8601`,
`parse_date`, `parse_http`, … and `parse_offset` is a
`local function` at `cosmic/time.tl:290`, never assigned into `M`.
This cost agent 2 its only build failure — the single doc/reality
mismatch of the round, in the one surface a clean-room user has.

Root cause: the filter exists, but only on one path.
`_tool/doc/init.tl:176` indexes `local function`s with
`is_local = true`; `_tool/doc/render.tl:68` drops them unless the
module record re-exports the name; the embedded index
(`_tool/doc/index.tl` → `.docs/index.lua`) keeps them, and the
`--docs` query path (`cosmic/doc/show.tl`) never consults `is_local`.
So the published markdown is clean and the in-binary docs are not.

Scope: **79 phantom top-level callables across 22 public modules**
(documented as `function name(...)`, absent from the module table).
Worst pages: `cosmic.ip` (16), `cosmic.tar` (7), `cosmic.searcher`
(7), `cosmic.literal` (6), `cosmic.time` (5), `cosmic.re` (5),
`cosmic.zip` (5). `cosmic.ip` is the sharpest: its private
`addr_format(self: Addr)` is published under its internal name, so a
reader reaches for `ip.addr_format(a)` (nil) instead of `a:format()`.

Fixed by filtering on the index path with the rule `render.tl` already
applies, plus two extractor bugs the ratchet then exposed: a module
that IS its record (`return stream`) had no readable export list, and
`function stream.write_all(...)` was indexed under the table's name
because the name pattern stopped at the dot — six entries all called
`stream`, and the six real functions documented nowhere. A third bug
fell out of the same test: a `function` word inside a doc comment
started a match that ran past the newline and swallowed the real
definition, which is why `stream.lines` was missing entirely. A
definition begins its own line — the rule that fixes it also drops the
phantom `on` that came from prose inside a string literal.

The fix is structural rather than a ratchet: the index derives an
export SURFACE for every module — the table literal it assigns, in all
four shapes the tree uses, unioned with its interface record's
function-typed fields — and publishes nothing outside it. There is no
"unknown" case left to leak through, because an underivable surface is
empty and an empty surface publishes no locals at all. Omission is
visible and harmless; an invented function costs the reader a build.

After: **zero bare-name phantoms on any page, public or internal**
(79 → 33, all 33 remaining being record methods like `handle:read`,
documented under the record that owns them), and nothing lost — the
exported-but-undocumented set is unchanged at 11, down from 18 because
the dotted names now resolve.

### P2 — a line labelled `warning:` that is fatal, with nothing saying so

Agent 1's top friction and its first build failure. Reproduced:

```
$ cosmic --check types shadow/shadow.tl
shadow/shadow.tl:3:1: warning: function shadows previous declaration of 'load'
check exit=1
```

Warnings are errors here, but the output never says it — the word
"warning" reads as survivable until the exit code contradicts it.
`guide.gotchas` does not cover shadowing a builtin. Per the rounds'
own lesson (fix at the error site first), the fix is a line on the
failing output, not a gotcha entry.

### P3 — every file-taking flag silently ignored all paths but the first

Agent 3 reported the `--fix` symptom; reproduced exactly. Two files,
both unformatted:

```
$ cosmic --fix a.tl b.tl ; echo $?
0
```

`a.tl` is rewritten, `b.tl` untouched, exit 0, no output — invisible
until the next `ci` fails on the file that was skipped, which is part
of why agent 3's green-ci count was 3.

Chasing it found the same root cause under `--check`, where it is
worse than a papercut — it is a **false green**:

```
$ cosmic --check types a.tl d.tl   # a.tl clean, d.tl has a type error
Type check passed
exit=0
```

The dispatcher's pre-scan stopped at the first positional past a
flag's declared arity and treated the rest as a script name, so the
gate reported PASS over a file it never read. `--check`, `--fix` and
`--format` now take a path list, run over every path, and return the
worst exit code; each success line names its file.

### P4 — a shipped recipe that does not type-check

`guide.recipes`' sqlite example calls
`db:query("SELECT * FROM files WHERE path LIKE ?", "%src%")` with a
bare trailing argument, while `cosmic.sqlite`'s own contract is one
table (`params?: Params`). Checking that shape:

```
r.tl:4:45: error: argument 2: got string "%src%", expected Params
```

Agent 3 spotted the contradiction and followed the module's worked
examples instead, so it cost minutes rather than a cycle — but
`guide.recipes` is exactly what a clean-room agent copies, and the
`Example_*` doc-testing that covers module examples evidently does not
cover recipe pages.

The snippet gate that does exist (`_build/skills_test.tl`) holds guide
fences to being formatter fixpoints, not to type-checking — which is
exactly the hole this fell through. The recipe is fixed and now
type-checks and runs; extending that gate to types is left open (see
below).

### P5 — fmt drift is invisible until `ci`

All four agents hit it; three ranked it. `--make build` and
`--make test` accept a file the formatter will reject, so the first
complaint arrives at `ci`. This is documented in
`guide.quickstart`, agents 3 and 4 had read it, and they hit it
anyway — the same "docs alone do not prevent a trap" pattern the
earlier rounds recorded. Both suggested the same fix independently: a
one-line note at the end of `build`/`test` that fmt and lint were not
run. That is what shipped, emitted only for a verb the user typed —
inside a converging gate the build is a step, not a result.

### P6 — coverage does not attribute subprocess-exercised lines

Agent 1: `cmd/notes/main.tl` scored 0/111 lines in the baseline
although `main_test.tl` exercises every branch by spawning
`o/bin/notes`. `guide.testing` teaches that spawn pattern for CLI
tests without mentioning what it costs at the coverage ratchet.

### P7 — optional valued flags: `nil` or `""`?

Agents 2 and 3 ran the experiment and reached opposite conclusions
(agent 2: `""`; agent 3: a real `nil`), each having to write a
throwaway script because the docs pin down only the `arg_optional`
shape. The static type says plain `string` either way, so a reader who
trusts it risks a `nil` concatenate. Whichever the truth is, it should
be stated for the plain optional-flag case.

### P8 — `cosmic.fs.find`'s page is stamped "internal module — not API"

Agent 4: `FindOptions` is documented on the shard page, which carries
the internal-module banner, although `fs.find` is public API
re-exported on `cosmic.fs`. The banner is about the shard path, not
the function, but nothing on the page says so.

## What held up

Named by more than one agent, unprompted: `--docs` coverage and
cross-linking; error messages carrying `file:line:col` plus the exact
fix command; the `value | nil, string` doctrine being applied without
exception; `cosmic.flags` generating correct per-command help and
collecting repeated flags with no extra code; the test sandbox
accepting `child.run` against a built binary with no configuration;
and `guide.gotchas` read up front actually preventing its gotchas —
agent 4 wrote five files that each passed `--check types` on the first
try and finished the whole project without a single type error.

## Left open

- **P6, P7, P8**, which are documentation questions rather than
  defects — and P7 needs its answer settled by experiment first, since
  two agents reported opposite behaviour.
