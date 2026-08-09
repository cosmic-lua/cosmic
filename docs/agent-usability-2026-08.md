# Agent Usability Study — August 2026, round 4

> **As of August 2026, main `26bb9bf`.** A dated study log, not live
> guidance: the module names, guide slugs and error messages quoted
> below are the ones that build shipped. Read it for the findings and
> the fixes they motivated, not the identifiers. The method is
> `skills/agent-eval/SKILL.md`; the predecessor study is
> [agent-usability.md](agent-usability.md).

Four Sonnet agents, four fresh briefs, one file each: the `cosmic`
binary built from `26bb9bf` (`ci: PASS (5 stages)` before staging).
No repo access, no web, no skill roster, a throwaway `HOME` per agent
and the session env scrubbed. The isolation probe returned `NONE`, so
these numbers are not lower bounds the way round 1's were — all four
self-reports confirm the prompt was first contact with cosmic.

## Results

| agent | brief | surfaces | first build | green ci | verified |
|-------|-------|----------|-------------|----------|----------|
| 1 | `todo` — JSON-backed task CLI, subcommands, `--json` | flags, fs, json | 1 | 2 | yes |
| 2 | `logstat` — access-log parser, percentiles, histogram | string, time, testdata | 2 | 3 | yes |
| 3 | `notes` — SQLite CRUD, tags, transactions, search | sqlite, flags, time | 2 | 2 | yes |
| 4 | `mkproj` — spec-driven scaffolder, ≥4 modules | imports, project model | 1 | 1 | yes |

4/4 built, tested and green. "verified" means checked here, not
self-reported: each project's `o/bin/<name>` was run by hand
(`todo stats --json`, `logstat sample.log`, `notes new|list|search`,
`mkproj --dry-run` and a real scaffold plus its clobber refusal), and
`--make ci` was re-run in each tree from this session — all four
reported `ci: PASS (4 stages)` (`example` skipped: no `*_example.tl`).

Nobody hit a dead end. Every failure any agent reported was resolved
in the same session from the tool's own output; no agent had to guess
at undocumented behaviour, and none reported a wrong answer from the
docs.

## What the journals agree on

Two frictions showed up in more than one journal. Those are the
findings worth spending on; a single agent's stumble is noise.

**1. `cast-justify` reads as per-statement, and is per-line.**
(agents 2 and 3, one lost `ci` cycle each.) Both wrote a multi-line
table literal widening a `{string: any}` row into a typed record, put
one `-- cast:` comment above the whole constructor, and were surprised
that lint wanted one per field. Both had *read* the rule first; both
misparsed "the whole line" as "the whole statement". Agent 3: "I read
'the pattern' rather than 'the line' the first time through." Agent 2
asked for the same fix independently: a worked multi-line example.

**2. multi-return values spread where you did not mean them to.**
(agent 3 three times, agent 4 among the constructs that fired.) Agent
3 hit `time.format_iso8601(time.now())` (two returns into a one-arg
call), then `return check.must(child.run(...))`, then
`check.must(db:query_value(...))` — where `query_value`'s third return
shape (`value, found, err`) puts a boolean into `must`'s `err?: string`
slot. The existing hints caught all three at the exact line, so each
cost one edit rather than a debugging session — but the trap fires
often enough that agent 3 ranked it #1 despite having read the
`tuple-spread` gotcha up front. This is the round-3 lesson again: the
hint converts a stall into an edit; it does not prevent the write.

Single-agent findings worth acting on:

**3. `{Key = value}` infers a closed record, and tl's message points
the wrong way.** (agent 2, ranked #3, "the one gap I'd most want
added".) A month-name lookup table produced:

```text
error: cannot index object of type record (Jan: integer; Feb: integer)
with a string, consider using an enum
```

The suggestion fits a fixed key *set*; for a lookup *table* the fix is
`local months: {string: integer} = ...`. No hint fired, and the
message's own advice sends you to an enum.

**4. `--test <output> <cmd>...` reads as "the binary under test".**
(agent 4, ranked #2, and the only real dead end in the round.) Agent 4
ran `cosmic --test o/foo o/bin/mkproj spec_test.tl`, which cheerfully
ran *its own CLI* against the test file as if it were a spec and
reported invalid JSON. `guide.testing` spells the argument out as
`<cosmic_binary>`; `--help` did not.

## Fixed in this change

Following the skill's priority — hint at the error site first, gotcha
entry second, guide prose third:

- **finding 3 → a hint at the error site.** `cosmic/_teal_hints.tl`
  gains pattern 4d for `cannot index object of type record ... with a
  string`, naming the map annotation and saying what an enum is
  actually for. A canary test in `cosmic/teal_test.tl` provokes the
  real message through the real check path, so a tl bump that rewords
  it fails there instead of silently killing the hint.
- **finding 3 → a `record-vs-map` gotcha entry**, next to
  `integer-vs-number` where agent 2 asked for it.
- **finding 1 → `guide.lint`** says "one PHYSICAL line ... never a
  whole statement" and carries the multi-line worked example both
  agents wanted — the `{string: any}`-row-into-record shape they each
  wrote.
- **finding 4 → `sys/help.md`** says `<cmd>` is the cosmic binary that
  runs the test file, not the program under test.

Finding 2 is left where it is on purpose: the hints already fire on
every instance, name the fix, and cost one edit. The remaining cost is
that the trap is *writable*, which no error-site change reaches.

## Backlog (not fixed here)

- **`flags` has no cross-cutting flag.** (agent 1, ranked #1, and the
  largest chunk of non-obvious code in that project.) A `--json` or
  `--file` meant to apply to every subcommand has no home in a
  `CommandSpec`, so agent 1 hand-rolled an argv pre-scanner and had to
  reason about `--file=path` vs `--file path`, bare `--file`, and
  flags before *or* after the verb. The `flags` doc's own example is a
  todo CLI, so it stops one step short of the case a todo CLI needs.
- **`json.array` returns `{any}`.** (agent 1, ranked #2.) Marking a
  genuinely-empty table for round-trip-safe encoding costs the element
  type, and the obvious repair (`as {Task}` at each call site) is
  exactly what `cast-justify` then nags about; the good repair (one
  generic wrapper) is not suggested anywhere.
- **`check.must` meets a three-value return.** `query_value` returns
  `value, found, err`; `must`'s second parameter is `err?: string`.
  The collision is legible only after the checker points at it.
- **`cosmic.string`'s "no Lua patterns" reads as a prohibition.**
  (agent 2, minor.) It means "this module does not take them", not
  "cosmic programs do not have them" — one clarifying clause.
- **`--help` says `cosmic-lua`, everything else says `cosmic`.**
  (agent 1, minor.) A moment of "did I get the right binary".

Not actionable, recorded for the next reader: `file(1)` calls the APE
binary a DOS/MBR boot sector (agents 3 and 4 both paused on it), and
the `example` stage reporting "nothing to do" for a project with no
examples surprised nobody but does mean a green project prints
`ci: PASS (4 stages)`, not 5.

## What stayed easy

All four journals converge here, and it is the same list as round 3 —
worth keeping intact:

- **`--docs` is sufficient.** Every agent said outright that the
  no-web constraint never bound, and that they never had to read
  source or guess a signature. `guide.quickstart` was named by three
  of the four as the thing that produced a correct layout with zero
  guessing.
- **Error messages that name their own fix.** Every agent listed this.
  Agent 3: "I never had to guess at a fix; I just followed what the
  tool printed."
- **`cosmic --fix <file>`** — named by all four; the fmt failure
  message prints the literal command, and copy-pasting it is the whole
  repair.
- **`cosmic.flags`** — named by all four as the best batteries-included
  moment: one spec table yields parsing, dispatch and an aligned
  `--help`. (The gap in finding-5 above is a gap *in* something all
  four agents liked.)
- **The position-declares-meaning project model.** Agent 4:
  "`cmd/mkproj/main.tl` just *became* `o/bin/mkproj` the moment it
  existed in the right place."
- **One command for the gate.** `--make ci` ending in one verdict line
  meant nobody had to remember a chain of invocations.
- **The spawn-your-own-binary test pattern** from `guide.testing`
  mapped onto "test the subcommand dispatch" with no harness design
  needed (agents 1, 2, 3).

## Reading these numbers against round 3

Round 3's fully-isolated fleet converged to 1/1/1/1 on first build.
This round is 1/2/2/1 — but on harder briefs (round 3's did not
require a spec-driven multi-module generator or transactional SQLite),
and both 2s were single type errors caught by hinted messages, not
stalls. The comparable claim is the one this round supports directly:
**every failure was a one-edit fix from the tool's own output**, and
the two that repeated across agents are both now fixed at the error
site or in the guide they misread.
