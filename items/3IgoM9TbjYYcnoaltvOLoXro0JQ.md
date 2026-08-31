## Change

Decide whether `third_party/lua/test/` in the fork is meant to be live, and
either make it so at 5.5 or delete it. It is currently neither: 41 tracked
files (33 `.lua`, 552K) of the upstream **Lua 5.4** test suite that nothing
runs, now one minor version behind the interpreter beside it.

Filed as a loose end of the 5.5 move (MuzfhbQP), which deliberately left it
alone rather than widening that change.

## What is actually there

Measured on master `736818245`:

- 41 tracked files under `third_party/lua/test/`.
- `all.lua:6` guards itself: `local version = "Lua 5.4"`, and it writes to
  stderr and exits when `_VERSION` differs. So against the 5.5 interpreter it
  **refuses to run** rather than failing — stale, not broken.
- Referenced by **no** makefile, workflow, or shell script. `update.sh` does not
  manage it either; that script's `test` mentions are `ltests.c`/`ltests.h` (the
  `MODE=dbg` debugging module) and `make o//tool/lua/test`, which is the fork's
  OWN test target, a different thing entirely.
- 3 of its 33 `.lua` files no longer parse under 5.5, all from the
  const-control-variable rule:

```
third_party/lua/test/attrib.lua:239   attempt to assign to const variable 't'
third_party/lua/test/closure.lua:63   attempt to assign to const variable 'i'
third_party/lua/test/nextvar.lua:614  attempt to assign to const variable 'i'
```

## Why this is not a drop-in replacement

Upstream publishes the matching suite —
`https://www.lua.org/tests/lua-5.5.1-tests.tar.gz` is live (HTTP 200), sha256
`da07b543872dc0bb2ff12aabd0c248578d78df3eb6b67efdc537a46d455c7f31`. But the
vendored copy is **not pristine**, and `README.cosmo` says so:

> Some of Lua's tests have been modified to accommodate Cosmo's changes. (And
> some of Lua's tests have been commented out due to Cosmo's changes.)

So replacing it is the same shape of problem as the interpreter patches: local
modifications that have to be re-identified and re-applied on top of new
upstream sources, with nothing today recording what they are. Nobody has had to
carry them across a version bump before.

Two further traps `README.cosmo` records, both easy to destroy silently:

- Five files intentionally contain **ISO-8859-1**, not UTF-8: `db.lua`,
  `files.lua`, `pm.lua`, `sort.lua`, `strings.lua`. Editing them as UTF-8
  corrupts those bytes and makes tests fail.
- The `.c` header rewriting and `__static_yoink` conventions that
  `update.sh`'s patches handle have no equivalent here.

## The decision, first

This is a decision item before it is a work item, and the work differs
completely by answer:

**(a) It is meant to be live.** Then it needs the whole `update.sh` treatment:
the pristine 5.5.1 tarball fetched by URL and verified by sha, the fork's
modifications extracted into numbered patches, the round-trip invariant
(re-running reproduces the tree byte-for-byte), and a build target plus a CI
lane that actually runs it. That is real work, and it buys the upstream
interpreter conformance suite — which the fork's own `o//tool/lua/test` does
not attempt to cover.

**(b) It is dead weight.** Then delete it: 552K and 41 files of vendored code
that no gate reads, whose staleness nobody noticed until a version bump made
three files stop parsing. Deleting is honest and cheap, and the history keeps
it if anyone wants it back.

Deciding (a) without doing the work leaves the tree exactly where it is now.

## Non-goals

- Not patching the three files that stopped parsing. Making a suite nothing
  runs parse again is the worst of both options: it costs work and still
  proves nothing.
- Not a `MuzfhbQP` reopen. The 5.5 move is complete and green; this suite was
  never in its path.
