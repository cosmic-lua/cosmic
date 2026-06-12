# Agent Usability Study — June 2026

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
- `--check-types` prints `Type check passed` on success — positive
  confirmation matters to agents.
- `--check-format` shows an actionable diff; `--report` failure output
  includes captured stderr and traceback.
- `--skill` generating SKILL.md is exactly the right idea.
- `--docs` keyword search surfaces functions *and* examples.

## P0 — bugs (fix first)

1. **Require hints never fire for `.tl` scripts.** `--help` advertises
   "helpful module-not-found suggestions" (`COSMIC_NO_REQUIRE_HINTS`), but
   `require("json")` in a script yields only
   `error: module not found: 'json'`. The hint machinery in
   `lib/cosmic/require.tl:166` matches Lua's `module 'x' not found` format,
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
   module look broken (source: `lib/cosmic/poll.tl:41-46`).

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

13. **`--check-format` mismatch output can look like identical lines**
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

- The `--check-format` hint's in-place command was used successfully by
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
