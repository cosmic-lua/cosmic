# Agent Usability Study — June 2026

> **As of June 2026, build `8c7e138`.** This is a dated study log, not
> live guidance: module names, guide entry numbers, and error messages
> cited below are the ones that binary shipped, and several have since
> been renamed or retired (`cosmic.io`, `cosmic.fs_walk`,
> `cosmic.assert`; gotcha entries are now cited by slug). Read it for
> the methodology and the findings' direction, not the identifiers.

Four Sonnet agents were given a clean directory containing only the `cosmic`
binary (build `8c7e138`) and a coding task. No repo access, no web, no other
runtimes. Tasks covered four surface areas:

| sandbox | task | result | cosmic invocations |
|---------|------|--------|--------------------|
| A | JSON stats CLI with error paths | completed, zero type errors | ~20 |
| B | reusable module + tests via `--test`/`--report` | completed, 1 type error | ~15 |
| C | sqlite file indexer (fs.walk + hash + sqlite) | completed, ~17 errors/cycles | ~33 |
| D | child-process TCP echo orchestrator | completed, 1 type error + 1 silent logic bug | ~23 |

All four finished, which is a strong baseline: `--help`, `--docs` search, and
`--docs guide.*` were enough to get from zero to working code. Cost scaled
with how far the task strayed from documented idioms — agent C needed roughly
twice the tool calls of agent A, almost all spent re-deriving undocumented
semantics by trial and error.

Every finding below was reproduced against the binary directly; agent
self-reports alone were not trusted.

## What already works well (keep it)

- `--help` is excellent first contact: lists every flag, the full module
  list, doc entry points, and the `proc.is_main()` pattern.
- `--check types` prints `Type check passed` on success — positive
  confirmation matters to agents.
- `--check fmt` shows an actionable diff; `--report` failure output
  includes captured stderr and traceback.
- `--skill` generating SKILL.md is exactly the right idea.
- `--docs` keyword search surfaces functions *and* examples.

## P0 — bugs (fix first)

1. **Require hints never fire for `.tl` scripts.** `--help` advertises
   "helpful module-not-found suggestions" (`COSMIC_NO_REQUIRE_HINTS`), but
   `require("json")` in a script yields only
   `error: module not found: 'json'`. The hint machinery in
   `_cli/require_hints.tl:166` matches Lua's `module 'x' not found` format,
   while the Teal loader emits `module not found: 'x'` — so the hints are
   dead on the primary code path. (The hints *do* work in `--examples`
   lookup, where `--examples child` correctly suggests `cosmic.child`.)

2. **`--docs` cannot address re-exported functions or record methods.**
   `cosmic --docs cosmic.fs.walk` → `symbol 'walk' not found in 'cosmic.fs'`;
   `cosmic --docs cosmic.sqlite.query` → same. These are the highest-traffic
   APIs. Agent C only found walk's docs after discovering the internal
   `fs_walk` submodule name. Index re-exports under the public module name,
   and make `Db:query`-style record methods addressable.

3. **Doc renderer garbles multi-line function types in records.**
   `--docs cosmic.poll` renders a stray dangling line
   `fd: number, events: Events)` inside the `Poller` record, making the
   module look broken (source: `cosmic/poll.tl:41-46`).

4. **`fs.walk` visitor docs are actively misleading.** The signature names
   the first parameter `dir`, but it receives the entry's *full path*.
   Agent C wrote `fs.join(dir, name)`, got doubled paths
   (`testdata/config.ini/config.ini`), and lost several cycles to a silent
   runtime bug. Rename the documented parameter to `path` and state "first
   arg is the full path; second is the basename". Also: `--examples
   cosmic.fs_walk` has no examples, and the `WalkStat` type is only
   importable as `cosmic.fs_types.WalkStat` — agent C needed three failed
   annotations to discover that.

5. **`--test` with missing arguments reports `unknown option '--test'`.**
   Should report usage for the flag instead.

## P1 — high-leverage documentation

6. **Put one complete, runnable example at the top of every module doc
   page.** Module pages do embed examples, but at the bottom of 300+ line
   pages; no agent ever reached them. The single change with the highest
   payoff: open → use → close in the first screenful (especially sqlite,
   child, net, fs).

7. **Add a `guide.gotchas` (or `guide.types`) covering the traps every agent
   hit:**
   - `integer` vs `number` (agents B and D both lost a cycle; `string.sub`
     wants `integer`, `WEXITSTATUS` returns `number`)
   - traversing `any` from `json.decode`: the cast chain
     `data as {any}` / `item as {string:any}`
   - `arg` is `{string}` with `string | nil` elements; guard before use
   - multi-return capture: `local rows, err = db:query(...)` (can't use
     directly in `for ... in`)
   - local modules: `require("mymod")` works relative to the script
     (currently documented nowhere)

8. **`cosmic.io` shadows Lua's `io` and has no `stderr`.** Two agents
   independently probed for `cosmic.io.stderr`. Add a note to the module
   docs: alias it (`local cio = require("cosmic.io")`) and use standard
   `io.stderr` for streams.

9. **Make the testing guide's "Running Tests" section copy-pasteable.**
   Agent B ended up with `slug_test.got.got` because the `<output_prefix>`
   semantics (writes `.out`/`.err`/`.got`, report on the `.got`) are stated
   in prose but never shown end-to-end. Also state explicitly that `--test`
   propagates the test's exit code and `--report` aggregates.

10. **Add a worked child-process + pipe example.** `child.Opts.stdout:
    number` is a raw fd for dup2 in the child; the parent must pass
    `pipe.writer:fd()` and close the write end. Agent D inferred this from
    Unix lore, not docs. (Related: a `net` helper or documented idiom for
    "bind port 0, recover the real port via `getsockname`".)

## P2 — error-message ergonomics

11. **Teach the type checker fix-hints for the top three traps:**
    `got number, expected integer` → "annotate the variable `: number` or
    use `math.tointeger`"; `got string | nil, expected string` → "narrow
    with `if x == nil then ... end` first"; `wrong number of returns` →
    "capture with `local v, err = ...`".

12. **Rename or reword the `assert-order` style diagnostic.** The message
    `function 'foo' not called immediately after definition` is labeled
    `assert-order`, which reads as being about `assert()`; agent A could not
    tell what rule fired or whether it mattered.

13. **`--check fmt` mismatch output can look like identical lines**
    (invisible whitespace). Append a hint: "run `cosmic --format <file>` to
    fix", and consider an in-place `--format --output <same file>` shortcut
    in the docs.

14. **Runtime tracebacks leak internals** (`/zip/main.lua:418: in local
    'main'`). Trim frames below the user's script.

## P3 — API ergonomics (smaller, nice-to-have)

15. **`assert_eq(actual, expected, label?)` helper** for tests — every agent
    hand-rolled `assert(x == y, "got: " .. tostring(x))`.
16. **`net` convenience for ephemeral ports**: `listen(host, 0)` returning
    the bound port.
17. **`--examples <name>` should accept the bare names its own listing
    prints** (`--examples` prints `child:`, but `--examples child` errors
    and demands `cosmic.child`). Its "did you mean" list also surfaces
    noise like `cosmic.fs_ops.FsOpsModule.chmod`.

## Method notes

Agents were instructed to work only from the binary's own help/docs, report
every command run, every verbatim error, and their top frictions. Claims
were then re-verified directly against the binary; a few agent claims were
dropped as inaccurate (e.g. "`--help` truncates the module list" — it
doesn't; the agent's own pager did).

---

# Round 2 — after the fixes

All 17 findings were addressed (commits `41f8f36`..`fb1953f`), and the
experiment was repeated: four fresh Sonnet agents, identical prompts and
tasks, clean sandboxes containing only the rebuilt binary (`e13e92d`).

## Results

| sandbox | task | round 1 | round 2 |
|---------|------|---------|---------|
| A | JSON stats CLI | clean, but burned cycles on `arg`/`any`/style confusion | 1 error total (format mismatch, fixed via the new hint in one step) |
| B | module + tests | 1 type error; ended up with a file named `slug_test.got.got` | 1 type error — the new fix-hint resolved it in one edit; test workflow correct first time |
| C | sqlite indexer | ~17 errors incl. a silent path-doubling runtime bug; ~70 tool calls | **type check passed on the first attempt**; 2 errors total; 36 tool calls |
| D | child + TCP echo | 2 type errors plus a silent server/probe race | 3 small errors, **no silent bugs**; used `net.listen_tcp` and the child+pipe example directly |

Fixes observed working in the wild (not just in unit tests):

- The `--check fmt` hint's in-place command was used successfully by
  three of four agents on their first formatting failure.
- The `got number, expected integer` fix-hint appeared verbatim in agent
  B's transcript and was resolved in a single edit (round 1: a full
  probe-and-experiment cycle).
- `guide.gotchas` was read by three agents and answered the `any`-casting,
  `arg`-nil, and io-shadowing questions before they became errors.
- Every per-symbol docs lookup attempted resolved: `cosmic.net.listen_tcp`,
  `cosmic.child.{spawn,Opts,Handle,Pipe}`, `cosmic.fs_walk.walk`,
  `cosmic.sqlite.{open,Database}`.
- No agent hit the fs.walk path-doubling bug or the io-shadowing trap.
- `cosmic.assert` was discovered organically via `--docs assert`.

## Remaining backlog (new or surviving findings)

1. `--docs <module>.<TypeName>` still misses nested record *types*
   (`cosmic.fs_types.WalkStat` → "symbol not found"); round-1 fix covered
   record methods only.
2. The `arg` table layout is undocumented: `arg[-1]` is the interpreter
   path, `arg[0]` is `/zip/main.lua` — agent D needed this to self-spawn
   and found it only by experiment. Document in `cosmic.proc` docs and
   `guide.gotchas`.
3. A `--fix` shorthand for formatting (two independent requests); the
   working incantation `--write-if-changed --output <f> --format <f>` is
   verbose and order-sensitive.
4. Point to `guide.gotchas` from `--help` ("Common pitfalls: cosmic --docs
   guide.gotchas").
5. Formatter rules for nested/callback indentation are discoverable only by
   failing; name the violated rule in the mismatch output or document the
   rules in `guide.formatting`.
6. `--report` counts test *files*, not `test_*` functions; per-function
   reporting would make green runs verifiable.
7. Smaller: a `LIKE`/`WHERE` example in the sqlite docs; surface
   `cosmic.ip` string→int conversion from the net docs; note that
   `child.Pipe.fd` is a field while `io.Handle:fd()` is a method; document
   local `require` resolution in `guide.modules` (it is in `gotchas` but
   one agent looked in `modules`).

---

# Round 3 — backlog fixes

All seven surviving findings were addressed (commit `1f0926c`). Sub-agent
capacity was unavailable for this round, so changes were implemented and
verified directly against a rebuilt binary rather than via a fresh
clean-room run.

1. **Nested record types resolve in `--docs`.**
   `cosmic --docs cosmic.fs_types.WalkStat` now renders the WalkStat record
   with its doc comment and methods. Root cause was deeper than lookup: the
   doc parser flattened nested `record X ... end` blocks into the parent
   record, so WalkStat never existed in the index and module pages showed
   one misattributed blob. Nested records are now parsed as their own
   entries (`doc.tl`), record names participate in cross-module
   did-you-mean (`cosmic --docs cosmic.fs.WalkStat` → "Did you mean?
   cosmic --docs cosmic.fs_types.WalkStat"), and symbol-not-found lists the
   module's available symbols inline instead of telling the agent to go
   look. Lookup helpers moved to a new `docs_lookup.tl` (500-line cap).
2. **`arg` layout documented** in `cosmic.proc` docs and the
   `guide.gotchas` `arg[0]` entry, since retired (`arg[-1]` =
   interpreter path, `arg[0]` = `/zip/main.lua`; `proc.interpreter()`
   is today's answer).
3. **`--fix <file>` formats in place**; the `--check fmt` hint now says
   `run 'cosmic --fix <file>' to fix in place`. The formatting guide's
   previous in-place recipe documented a flag order that did not work; it
   is replaced.
4. **`--help` points to `guide.gotchas`** in the Documentation section.
5. **Formatter rules documented in `guide.formatting`** — derived
   empirically: no spaces inside table braces, call-argument table
   constructors and anonymous-function bodies indent two levels with the
   closer one level in.
6. **`--report` shows per-file test-function counts** — `--test` records
   `test_*` definitions from the `*_test.tl` source to `<out>.tests`;
   passing checks render as `✓ foo (14 test functions)`.
7. **Smaller items:** sqlite `LIKE` example (`%` wildcard noted),
   `ip.parse("127.0.0.1")` cross-referenced from `net.connect_tcp`/
   `listen_tcp` docs, `child.Pipe.fd` field-vs-method note.

New backlog candidate observed during this round: `fetch_example.tl`
examples depend on httpbin.org and fail intermittently in CI; examples
should avoid third-party services (e.g. spin up a local listener).

---

# Round 3 re-test — clean-room verification

After the round-3 fixes merged (#413), the experiment was repeated a third
time: four fresh Sonnet agents, identical prompts, sandboxes containing
only the merged binary.

## Results across all three rounds

| task | round 1 | round 2 | round 3 |
|------|---------|---------|---------|
| JSON stats CLI | clean, cycle-burning confusion, ~23 calls | 1 format error, 21 calls | **0 checker errors**, 16 calls |
| module + tests | 1 type error + `.got.got` maze, ~25 calls | 1 type error, 24 calls | **0 errors of any kind**, 22 calls |
| sqlite indexer | ~17 errors + silent path bug, ~70 calls | 2 errors, 36 calls | 1 warning + 1 format miss, 26 calls |
| child + TCP | 2 errors + silent race, ~39 calls | 3 errors, 52 calls | 1 type error, 37 calls |

No silent bugs anywhere in round 3. Round-3 fixes observed working
in the wild:

- `--report` printed `✓ slug_test (14 test functions)` — the per-function
  count was used to confirm coverage.
- The sqlite agent's format mismatch was fixed with a single `--fix`
  invocation, exactly as the new hint instructed.
- `--docs cosmic.fs_types.WalkStat` resolved; the fs.walk "do not join"
  warning and the new sqlite `LIKE` example were both consumed directly.
- The child+TCP agent used `rawget(arg, -1)` from the gotchas guide's
  `arg[0]` entry (since retired — `proc.interpreter()` is the answer now) and
  explicitly noted it would otherwise have burned time on a silently
  broken `arg[0]` spawn; it also used `listen_tcp` with port 0 and
  pipe-based readiness.
- Agents now front-load `guide.gotchas` and `guide.formatting` before
  writing code — the two zero-error runs both did this.
- The one type error that occurred (`os.exit` wants `integer | boolean`)
  carried the number/integer fix-hint and was resolved in one edit.

## Round-4 backlog

1. **`--docs` exact-module-name queries should short-circuit the fuzzy
   search** (three independent complaints): `--docs io` / `--docs string` /
   `--docs fs` dump a flat substring grab-bag instead of leading with the
   module page. Related inconsistency: `--docs child.Handle` 404s while
   `--docs cosmic.child` and colon-forms work — short-name symbol lookups
   should resolve or suggest.
2. **`cosmic.net` has no examples** — the module most central to the TCP
   task returns "No examples for cosmic.net"; add a minimal echo
   server/client pair. Also document `Socket:recv`/`send`/`accept` EOF and
   blocking semantics (what signals "connection closed").
3. **New gotchas entries:** `print(f(...))` prints every return of a
   `(value, error)` function (trailing `nil` trap — capture first);
   `os.exit` requires `integer | boolean`, so a `number`-returning `main`
   breaks `os.exit(main())`.
4. **Cross-reference the `arg[-1]` gotcha from `cosmic.child` spawn docs**
   — that is where agents look first when spawning cosmic-as-child.
5. **A `guide.recipes` cookbook** for common module compositions
   (walk+hash+sqlite indexing; a CLI script skeleton: args → slurp →
   decode → transform → encode → print with error exits).
6. **`--check fmt` could show context lines** around the mismatch;
   `--help` could carry one-line argument shapes for `--test`/`--report`.
