# D29 — a test runs because it is defined, not because its file called it

- **date:** 2026-08
- **status:** active
- **context:** a `*_test.tl` is a script. every zero-argument
  `local function test_*` must call itself on the line after its `end`,
  and today that is **2,870 call lines across 266 files** — one per
  definition, so the tree is entirely self-calling. three mechanisms hold
  the convention up: the `call-after-define` lint in `_cli/lint.tl`
  refuses a `test_*` not called immediately after its definition;
  warnings-are-errors makes an uncalled `local function` an unused local
  that `--check types` rejects, so a forgotten call cannot slip through
  but surfaces as "unused variable" rather than as the actual mistake;
  and `_tool/testrun.tl` already scans for `^local function (test_%w+)`
  and writes the names to a `.tests` sidecar. the convention costs three
  things. the first failure kills the file, so one run reports one defect
  and whether the file's other tests also broke is invisible until the
  next round trip. a test has no per-test identity — the report counts
  files, narrowing is by file path only, and there is no equivalent of
  `go test -run`. and the ceremony itself is held in place by a lint rule
  and a warning that exist only to police boilerplate.
- **decision:** a test runs because the toolchain found it, not because
  its file remembered it.
  - **discovery is by name**, from the compile-time lexer walk
    `call-after-define` already uses. a top-level
    `local function test_*` IS the enrolment. the walk is token-exact, so
    a fixture quoting `end` inside a string cannot confuse it, and source
    order is the run order.
  - **invocation is a toolchain-generated in-chunk tail**, appended at
    the compile/check seam —
    `return require("cosmic.test").main({...})`. in-chunk because that is
    the only place file-local functions are reachable; appended because
    it changes no line number, so a failing test's traceback still points
    at the real source line. the same augmented source goes to the type
    checker, so the checker checks what runs and the uncalled-local
    warning never fires. the tail is never written to the tree and the
    formatter and `fmt` never see it.
  - **a file is all-or-nothing.** every `test_*` self-called is legacy
    mode and compiles unchanged; none self-called is runner mode and gets
    the tail; MIXED is a lint failure. mixed is the one shape that must
    never pass, because its uncalled half would silently not run under
    legacy semantics.
  - **the 0/2/fail exit grammar is unchanged** — 0 all passed, 2 nothing
    ran, nonzero otherwise. `check.needs` and `check.reap` keep exiting
    the process, because a missing fixture invalidates the file rather
    than one test.
- **rejected:**
  - **a registration API** (`test.case(fn)`) — moves the forgettable
    call, does not remove it. the failure mode is identical to today's
    and the ceremony survives under a new name.
  - **body extraction, the way `Example_*` works** — recompiles bodies
    lax and orphans shared helpers. a test file is checked whole and
    strictly today, with its requires and helpers in scope; that is the
    property the example runner gives up and the one a test file cannot.
  - **tests as globals in a custom `_ENV`** — trades a visible generated
    tail for invisible environment magic and cross-file global
    declarations. the tail can be printed; an `_ENV` swap cannot.
  - **a `t` handle** (`t.Error`, `t.Fatal`) — throwing already IS the
    failure mechanism in Lua, so the reason Go needs a handle does not
    exist here. `assert` and `cosmic.check` stay the whole vocabulary.
  - **a per-file cliff instead of mode dispatch** — 266 files here and
    every user project's tests cannot migrate in one commit, and a
    half-migrated file must fail rather than half-run.
- **consequences:** enables continue-past-failure, per-test identity in
  the `.tests` sidecar, and a `--filter` matching the substring contract
  the benchmark and example runners already honour. costs a compile seam
  that injects source the tree never contains, which is a new place a bug
  can hide and a new thing a reader of the file cannot see. makes
  `cosmic/test.tl` PUBLIC api — a user project's compiled tests require
  it at runtime — so its signature is frozen by
  [D20](d20-naming-charter.md)'s charter once shipped. forbids a
  half-migrated test file, permanently. [D23](d23-check-throws.md) stands
  unchanged underneath: throwing stays the failure mechanism, and the
  runner's `pcall` is what turns a throw into a per-test result instead
  of a dead file. the legacy arm stays until a release has carried the
  toolchain that understands both modes, because a runner-mode file under
  an old cosmic must fail loudly — and it does: the old strict compile
  rejects the uncalled locals before the lint even speaks. revisit if
  per-test isolation — a temp dir or a process per test — turns out to be
  needed, since an in-process runner is what forecloses it.
