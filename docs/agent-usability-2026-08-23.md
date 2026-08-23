# Agent Usability Study — August 23, 2026

> **As of August 23, 2026, a working-tree build (head `98dde1f`).**
> A dated study log, not live guidance: identifiers and error texts
> cited below are the ones that build shipped. Method per
> `skills/agent-eval/SKILL.md`; the fully isolated protocol (env
> scrub, per-agent HOME, no skill roster) was used, and the leak
> probe returned NONE before the fleet ran.

Four Sonnet agents, each in a clean directory containing only the
`cosmic` binary and a project brief. The four briefs exercise
different surfaces: a JSON-backed CLI with subcommands, a log
parser/aggregator with fixtures, a SQLite CRUD tool, and a
multi-module generator. Each brief required a compiled `o/bin/<name>`,
unit tests, and a green `ci`.

## Results

| agent | brief | built+tested | first build | green ci |
|-------|-------|--------------|-------------|----------|
| 1 | bookmark: JSON CLI (flags, fs, json) | yes, verified | attempt 2 | attempt 2 |
| 2 | logstats: log analyzer (string, re, testdata) | yes, verified | attempt 1 | attempt 2 |
| 3 | inventory: SQLite CRUD | yes, verified | attempt 2 | attempt 2 |
| 4 | sitegen: multi-module generator | yes, verified | attempt 1 | attempt 2 |

Every claimed artifact was verified independently: each binary run
end-to-end against fresh input (including agent 3's
insufficient-stock failure path and agent 4's rendering pipeline),
and each project's `ci: PASS` reproduced from its own tree. All four
context self-reports were clean — no session priming; agents 1, 2,
and 4 disclosed general Lua/Teal/Cosmopolitan familiarity from
training, which is the floor every round shares.

No agent needed more than two attempts at any gate, and every failure
was resolved in one cycle by reading the error line. The remaining
friction is no longer "can't get there" but "one predictable wasted
cycle" — and it is remarkably consistent across agents.

## The one shared trap: first `ci` always fails on fmt/lint

All four agents went 2 attempts to green `ci`, and all four first
failures were the fmt or lint stage catching what `--make build` and
`--make test` deliberately skip. The docs state this — the quickstart
says it in prose and every `build`/`test` run ends with
`note: fmt and lint did not run here` — and three of four agents
QUOTED that warning back in their journals while still tripping on
it. Agent 2: "it bit me exactly as predicted." Agent 1 hit the
cast-justification lint the same way; agent 3 the formatter's
opinion on trailing `-- cast:` comments.

Two mitigations already work: the fmt failure names `cosmic --fix`,
and every agent recovered in exactly one cycle. What would remove the
cycle entirely, per the error-site-first principle: the trailer note
on a FIRST successful build could actively recommend the inner loop
(`run ci, not build+test, before you call it done`) rather than
stating what did not run — three agents independently suggested the
hint arrives one run too late to change behavior.

## Ranked findings (cross-agent)

1. **`sqlite` docs model the pattern the checker rejects.** Agent 3's
   only build failure was 11 sites of bare `db:close()` — the
   discarded-fallible-return rule — while the shipped examples show
   `db:close()` inside `assert(...)`, which reads as the idiom. Either
   the docs adopt the captured form (`local _ok, _err = db:close()`)
   everywhere, or close-like effects earn a documented idiom of their
   own. The check itself was praised ("I *did* want to be forced to
   check `take`'s result") — it is the doc/check mismatch that costs.
2. **Module composition is discoverable only module-by-module.**
   Agents 1 and 2 both wanted one page mapping "a typical CLI tool"
   to the module set it composes (`fs` + `json` + `flags` + `proc`;
   `fs` + `string` + `re`). `guide.recipes` appears to be exactly
   this, but nothing early points at it — agent 2 flagged that a
   newcomer reinvents the composition before learning the guide
   exists. Cheap fix: name `guide.recipes` in `--help` and in the
   quickstart's first screen, not its last line.
3. **`require` resolution differs between plain-script and project
   mode, undocumented.** Agent 4 burned two guesses learning that
   dotted project paths resolve against the project root under
   `--check`/`--make` while `guide.modules` describes
   script-directory-relative resolution for plain runs. One sentence
   in `guide.modules` (and/or the `--check` help) closes it.
4. **Smaller doc surfaces.** The shadowed-builtin lint's reserved-name
   list is discoverable only by tripping it (agent 1 — though the
   error message itself was praised); `fs.find`'s rendered type
   snippet omits the array part the prose relies on (agent 4);
   `cosmic.string`'s patternless contract is easy to skim past when
   hunting for a line parser, and nothing routes the reader to
   `cosmic.re` (agent 2); the `flags.command` docs' single-command
   example invites re-parsing `d.parsed` (agent 1, self-caught).

## What was pleasantly easy (keep it)

- `--docs` as a complete offline reference: agent 3 wrote its whole
  storage layer against `--docs sqlite` with zero
  does-this-method-exist trials.
- Error messages naming file:line, the problem, and the fix or fix
  command; `cosmic --fix` correct on first use for every agent that
  needed it.
- Position-is-the-manifest: zero configuration; `cmd/<name>/main.tl`
  → `o/bin/<name>` and directory = import path worked on first read
  for all four agents, including agent 4's four-module tree.
- `sqlite.open(":memory:")` plus `check.must`/`check.equal` for
  tests; the warm rebuild loop fast enough that iteration never hurt.

## Comparison with prior rounds

The June study's worst case was ~17 error cycles on the sqlite brief;
the early-August rounds converged to 1/1/1/1 first-build attempts.
This round holds that level on different, slightly harder briefs
(subcommand dispatch, multi-module imports): worst case anywhere was
2 attempts, no silent bugs, and every journal independently reports
that friction was low and every failure self-explained. The signal
has shifted from traps to polish: one wasted ci cycle per project and
a handful of doc-routing gaps.
