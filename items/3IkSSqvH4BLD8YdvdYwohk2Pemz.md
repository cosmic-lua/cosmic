## Goal

A cosmos pin bump that changes a `cosmo.*` binding's return SHAPE
cannot land in `cosmic-lua/cosmic` AT ALL — not narrowed, not
partial — while `bin/cosmic.pin` stays fixed, if ANY of a specific set
of `cosmic/*.tl` modules (reachable during the build's own generation
phase, or loaded by `_cli/main_handlers.tl` on every cold invocation)
would need their internal destructuring of an affected binding to
change. This is a full precondition on the pin bump itself, not a
"leave these wrappers on old code" workaround.

## Evidence

**Updated 2026-09-02, second builder pass.** The first pass (see
history below) proposed narrowing the pin-bump item
(`3IkMf7BY1UOxBTAIwbNFQwRZJDA`) to exclude the affected wrappers
(`cosmic/fd.tl`, `cosmic/fs/ops.tl`, `cosmic/fs/file.tl`,
`cosmic/embed/init.tl`, `cosmic/child/init.tl`,
`cosmic/proc/rusage.tl`, `cosmic/time.tl`, `_cli/main_handlers.tl`),
leaving them on their OLD (pre-bump) destructuring. That narrowing was
insufficient: a fresh clean-tree `bin/cosmic --make ci` with the pin
bumped, the narrowed-safe wrappers fixed, and the 8 excluded files left
UNCHANGED still fails — not during generation this time, but at the
LATER `compile-batch o/.groups/cosmic.compiled`/`_cli.compiled` step,
which correctly resolves the tree's fresh, post-bump `cosmo.unix`
types against the excluded files' still-old destructuring:

```
_cli/main_handlers.tl:98:28: error: argument 1: got MkstempPath, expected string
cosmic/fd.tl:253:32: error: argument 1: got Pipe (inferred at cosmic/fd.tl:248:3), expected integer
cosmic/time.tl:83:38: error: assignment in declaration did not produce an initial value for variable 'eintr_ns'
cosmic/time.tl:89:28: error: cannot use operator '*' for types SleepRemainder and integer
... (18 more time.tl errors, gmtime/localtime tuple fields)
cosmic -c: compile-batch: 2 of 140 failed
make: the converging build failed
ci: FAIL (build failed)
```

So each of the 8 files has exactly two states — old destructuring,
new destructuring — and BOTH fail one of the build's two compile
passes under the current `bin/cosmic.pin`:
- NEW destructuring → generation's own compile of
  `_types/tlast_gen.tl`/`_make/bytecode.tl` (which runs under
  `bin/cosmic.pin`'s stale, pre-bump embedded types) rejects it.
- OLD destructuring → the later `compile-batch` pass (which runs
  against the tree's fresh, post-bump regenerated types) rejects it.

There is no third option and no scope-narrowing that avoids it: as
long as the pin advances past a release these 8 files' bindings
change shape in, `--make ci` cannot go green, regardless of which of
the two destructuring styles those 8 files carry. The pin bump itself
is blocked, full stop, until this resolves.

(First-pass evidence, for the underlying mechanism: `_types/tlast_gen.tl`
and `_make/bytecode.tl` both `require("cosmic.child")`/`require("cosmic.fs")`
(and `_types/tlast_gen.tl` also `require("cosmic.proc")`) to spawn a
subprocess during generation, which runs BEFORE `_types/types_gen.tl`'s
own output exists; `_cli/main_handlers.tl` loads on every cold
`bin/cosmic` invocation for the same reason. This generalizes AGENTS.md's
documented cold-build staging rule — "a source that needs the tree's
own checker... stages behind a release and pin bump" — from a checker
FEATURE to a runtime BINDING CONTRACT. `_build/coldbuild_test.tl` does
not catch this: it exercises generation-1's type check against the
target build states, not this specific generation-time execution path.)

**Updated 2026-09-04, decision pass — the exact new shapes, measured
against `cosmic-lua/cosmopolitan` `tool/net/definitions.lua`:**

```
$ grep -n "^---@class unix.MkstempPath" -A2 tool/net/definitions.lua
5260:---@class unix.MkstempPath
5261:---@field path string the created file's path

$ grep -n "^---@class unix.Pipe" -A3 tool/net/definitions.lua
4968:---@class unix.Pipe
4969:---@field reader integer the read end's file descriptor
4970:---@field writer integer the write end's file descriptor

$ grep -n "^---@class unix.SleepRemainder" -A3 tool/net/definitions.lua
6042:---@class unix.SleepRemainder
6043:---@field seconds integer Whole seconds left to sleep.
6044:---@field nanos integer Nanoseconds left to sleep, past `seconds`.

$ grep -n "^---@class unix.BrokenDownTime" -A11 tool/net/definitions.lua
7296:---@class unix.BrokenDownTime
7297:---@field year integer four-digit year
7298:---@field mon integer 1 ≤ mon ≤ 12
7299:---@field mday integer 1 ≤ mday ≤ 31
7300:---@field hour integer 0 ≤ hour ≤ 23
7301:---@field min integer 0 ≤ min ≤ 59
7302:---@field sec integer 0 ≤ sec ≤ 60
7303:---@field gmtoffsec integer ±93600 seconds
7304:---@field wday integer 0 ≤ wday ≤ 6
7305:---@field yday integer 0 ≤ yday ≤ 365
7306:---@field dst integer 1 if daylight savings, 0 if not, -1 if unknown
7307:---@field zone string time zone abbreviation, e.g. "UTC"
```

`unix.mkstemp`'s 2nd return is `unix.MkstempPath|string` (table on
success, error string on failure — same slot, new success type).
`unix.pipe`'s single return is `unix.Pipe|nil`, not two positional
fds. `unix.gmtime`/`unix.localtime` each return one
`unix.BrokenDownTime|nil`, not an 11-value positional tuple.
`unix.nanosleep`'s EINTR remainder is one `unix.SleepRemainder`, not
two positional integers.

The tree's own current (pre-bump) code already shows the OLD
positional style at every one of these sites — confirming the 8 files
are still unmigrated and would hit exactly the dual-failure above the
moment the pin crosses a release carrying these shapes:

- `cosmic/fd.tl:246-253` — `local reader_fd, writer_fd = unix.pipe(flags)`
- `cosmic/time.tl:83` — `local rem_s, rem_ns, eno, eintr_s, eintr_ns = unix.nanosleep(seconds, ns)`
- `cosmic/time.tl:127-128` — `local year, mon, mday, hour, min, sec, gmtoff, wday, yday, isdst, zone = unix.gmtime(unixts)`
- `cosmic/time.tl:157-158` — the same shape for `unix.localtime`
- `_cli/main_handlers.tl:93,98` — `local tmp_fd, tmp_path = unix.mkstemp(...)` then `fs.write(tmp_path, content)`

## Decision

**(b)** — decouple the generation-phase spawn from `cosmic.fs`/
`cosmic.child`/`cosmic.proc`, and separate `_cli/main_handlers.tl`'s
`mkstemp`-using code from whatever forces it to compile early.

(a) does not close the deadlock, by its own text: it reopens for
"every future one whose window touches one of these 8 files'
bindings." It is also not a well-formed two-step sequence as stated —
producing a `cosmic-lua` release that already carries the NEW
destructuring means building it through this same pipeline, which is
exactly what is blocked; it would need an out-of-band, hand-built
release outside this project's own build process, which is neither
documented nor repeatable. (b) is bounded (the two generators'
subprocess-spawning need is small: write a file, run a subprocess,
read its output, clean up a temp dir) and permanent: once the
generation phase no longer transitively reaches `cosmic.fd`,
`cosmic.time`, or the other affected wrappers, a future pin bump
touching their bindings is an ordinary one-PR fix again, with no
staging tax. This also matches the project's own stated bias against
recurring workarounds (G9, docs/goals.md) over a repeated manual
process.

## Change

### `_types/tlast.tl` — stop requiring `cosmic.fs`

Current usage (measured, `grep -n "fs\." _types/tlast.tl`): `fs.temp_dir`,
`fs.join`, `fs.write`, `fs.read`, `fs.remove_all` — five calls, all on
plain paths/strings, none touching a fd, pipe, or time value.

Add `_types/gen_io.tl` (or fold into `_types/tlast.tl` directly if it
stays clear of the 500-line cap — check first): a minimal, this-repo-
internal module implementing exactly these five operations directly
against `cosmo.unix`/`cosmo.path` (`mkdtemp`, path joining via
`table.concat`/string formatting, `unix.open`+`unix.write`+`unix.close`
for `fs.write`, `unix.open`+`unix.read`+`unix.close` for `fs.read`, a
recursive `unix.unlink`/`unix.rmdir` walk or `unix.rmrf`-equivalent for
`remove_all`). No error-message polish needed — this module's callers
are generators, not user-facing wrappers; propagate `nil, string` and
stop there. `_types/tlast.tl` and `_make/bytecode.tl` both use it,
neither requires `cosmic.fs`/`cosmic.fd` again.

### `_make/bytecode.tl` — stop requiring `cosmic.fs`/`cosmic.child`

Current usage (measured, `grep -n "fs\.\|child\." _make/bytecode.tl`):
`fs.make_dirs`, `fs.join`, `fs.copy`, `fs.set_mode`+`fs.octal`,
`fs.write`, `child.run`, `fs.remove_all`. The `fs.*` calls fold into
the same `_types/gen_io.tl` helper above (add `make_dirs`, `copy`,
`set_mode`/octal-mode support — `unix.mkdir` per path segment,
`unix.open`+`unix.sendfile`-or-read/write loop, `unix.chmod`). `child.run`
becomes a direct `unix.fork`+`unix.execve`(or `unix.commandv`+`unix.execve`)
+`unix.wait4` sequence scoped to exactly the one shape `bytecode.tl`
needs (argv list in, exit code + stdout out) — not a general child-
process wrapper; that generality is what `cosmic.child` is for and
`bytecode.tl` does not need it. This is the piece most worth a second
pair of eyes at review, since process spawning has more failure modes
than file I/O.

### `_cli/main_handlers.tl` — the `mkstemp` site

**First step for whoever builds this**: confirm, with a command and
pasted output, whether `_cli/main_handlers.tl`'s early-compile claim
(Evidence, "loads on every cold `bin/cosmic` invocation for the same
reason") is actually load-bearing for the SAME dual-failure dynamic as
`cosmic.fd`/`cosmic.time` — i.e. does leaving `main_handlers.tl` on
NEW destructuring alone (pin unbumped, `cosmic.fd`/`cosmic.time`
decoupled per above) fail generation the same way the 8-file evidence
showed, or does `main_handlers.tl` only ever fail the LATER
compile-batch pass (in which case it is not part of the generation-
phase deadlock at all, and its fix is the ordinary one-line
destructuring update — `local tmp_fd, tmp_res = unix.mkstemp(...)`,
`fs.write(tmp_res.path, content)`, guard on `tmp_res` — deferred to the
follow-up item like the rest of the 8, with no decoupling needed for
it specifically). Write whichever this measurement finds into this
item's Evidence before closing it; only build the decoupling below if
the answer is yes.

If yes: move the `write-if-changed` handler (the only function in
`_cli/main_handlers.tl` touching `mkstemp`) into its own file,
required only from the one CLI branch that dispatches to it — but
note in the PR whether this alone is sufficient, since Teal type-
checks a required file's full body at compile time regardless of
whether the `require` call site itself is lazy; if splitting the file
does not change WHEN it gets pulled into the same compile unit as
`cosmic.fd`/`cosmic.time`, the real fix is ensuring that new file is
outside whatever dependency edge currently pulls `main_handlers.tl`
into the generation-phase compile, which the confirming measurement
above should reveal.

### Gate

`bin/cosmic --make ci` on the tree as-is (pin unbumped) must still
pass after this change — it does not touch the 8 files' own
destructuring, so `--make ci` today is not evidence either way for
the deadlock; the real gate is a rehearsal: bump `3p/cosmos/cosmos_pin.tl`
to any release carrying the four binding-shape changes above in a
throwaway branch, apply ONLY this item's decoupling (not the 8 files'
fixes), and confirm generation now succeeds where it previously failed
— then discard that branch; the actual pin bump is
`3IkMf7BY1UOxBTAIwbNFQwRZJDA`'s job, not this item's.

## Non-goals

- Does not itself fix any of the 8 listed files' destructuring or
  land the pin bump — that is deferred work on
  `3IkMf7BY1UOxBTAIwbNFQwRZJDA` (or a fresh item, since the pin has
  likely moved again by the time this lands) once this decision's
  code merges.
- Does not relitigate `3IkMf7BY1UOxBTAIwbNFQwRZJDA` (the pin-bump
  item), which stays blocked on this item until it merges.
- No change to `cosmic.fs`/`cosmic.child`/`cosmic.proc`'s own public
  contracts — `_types/gen_io.tl` (or equivalent) is new, internal, and
  parallel to them, not a replacement.
