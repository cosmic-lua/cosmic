## Goal

G5 — adversarial verification. `test/tool/net/**` holds 28 checks that
pass but never run: the lane is in no workflow, and until `3c36bc35`
(#275) it did not compile. Some of that coverage exists nowhere else in
the fork — the JSON conformance corpus above all. This slice moves what
is genuinely uncovered into `tool/lua/`, where the gate actually runs,
so the parent's retirement child can delete the directory without
losing anything.

## Evidence

Measured 2026-08-25 against whilp/cosmopolitan `3c36bc35`.

**The lane runs nowhere.** `grep -rn 'test/tool/net|tool/lua/test'
.github/workflows/` names only `o/x86_64/tool/lua/test`, in `pr.yml:26`
and `release.yml:38`. AGENTS.md names the same target as the
pre-PR correctness gate.

**28 of 40 checks pass** (`ls o//test/tool/net/*.runs | wc -l` was 28
with the clock.h include applied; that include has since landed).

**The json corpus is vendored inline and has no counterpart.**

```
$ wc -l test/tool/net/jsontestsuite_pass_test.lua \
        test/tool/net/jsontestsuite_fail1_test.lua \
        test/tool/net/ljson_test.lua
340  437  228
$ wc -l tool/lua/test_data_formats.lua
288
```

`test_data_formats.lua` is a CONTRACT test — array metatables,
`NaN`/`Infinity` rejection, empty-collection round-tripping
(`grep -n 'json' tool/lua/test_data_formats.lua`) — not a corpus one.
The nine `json*`/`ljson*` files in `test/tool/net/` are the
JSONTestSuite and json.org bodies.

**The other 27 passing files are unaudited.** `ls test/tool/net/*.lua`
lists 38 Lua files; the 12 failing ones are named in the parent. What
the remaining passers cover, and how much of it `tool/lua/test_*.lua`
already covers, has NOT been measured — that inventory is this slice's
first deliverable, and the port list follows from it.

## Change

Two steps, in order, both in whilp/cosmopolitan.

**1. Inventory (the research half).** For each of the 28 passing
checks in `test/tool/net/`, record one line: what binding surface it
exercises, and which `tool/lua/test_*.lua` covers the same ground
(or `none`). The 31 files in `tool/lua/` (`ls tool/lua/test_*.lua`)
are the comparison set. Write the table into this item's spec
(`gitboard spec <this-id> FILE`) before writing any code — the port
list in step 2 is exactly its `none` rows.

**2. Port the `none` rows into `tool/lua/`.** One new
`tool/lua/test_<name>.lua` per ported check, following the shape of
the existing suite: plain Lua, `assert` with a message, a final
`print("test_<name>: PASS")` line, `cosmo.*` for bindings rather than
redbean globals. Vendored corpus bodies move verbatim — do not
re-derive, re-minify, or trim a corpus. Wire each new file into the
`tool/lua/test` target the same way the existing `test_*.lua` files
are wired (read `tool/lua/BUILD.mk` for the rule; follow it, do not
invent a second mechanism).

The json corpus is a `none` row by the measurement above, so it ports
whatever else the inventory finds.

## Non-goals

- **Do not delete anything under `test/tool/net/`, and do not touch
  `test/tool/BUILD.mk`.** Retirement is the parent's second child and
  is blocked on this one landing. This slice only adds to `tool/lua/`.
- **Do not repair the 12 failing checks.** The parent records why they
  are retired rather than fixed: they assert redbean's `:errno()`
  object, redbean's globals, and a `cosmo` module redbean does not
  link. Porting one of them means rewriting it into a test
  `tool/lua/` already has.
- **Do not change any binding.** The `cosmo.*` C boundary,
  `tool/net/definitions.lua`, and every return shape and error string
  are frozen here. A test that will not port because a binding differs
  from redbean is evidence for the inventory, not a reason to move the
  binding.
- **Do not touch anything in whilp/cosmic.** No pin bump, no type
  regen, no wrapper change.
- **Do not add a CI lane or edit `.github/workflows/**`.** The ported
  tests join `o//tool/lua/test`, which both workflows already run;
  that is the whole point of porting them there.
- **Keep the fork mergeable with upstream**: surgical diffs, no
  drive-by reformatting of the files you touch (AGENTS.md).

## Acceptance

Run from the whilp/cosmopolitan repo root.

- `make -j$(nproc) o//tool/lua/test` passes.
- The check count strictly rises: record
  `ls o//tool/lua/*.ok 2>/dev/null | wc -l` (or whatever the target's
  per-test stamp is — read `tool/lua/BUILD.mk` and use its actual
  stamp) before and after, and quote both in the PR. The delta equals
  the number of ported files.
- `ls tool/lua/test_*.lua | wc -l` is 31 + the number ported.
- Each new file, run directly, prints its `test_<name>: PASS` line.
- The inventory table is in this item's spec before the code diff
  exists — quote its `none` rows in the PR description, and confirm
  the ported files are exactly those rows.
- `git diff --name-only master` names only files under `tool/lua/`.
- `git diff --stat master -- test/tool/net .github` is empty.

## Enablement

none needed. The parent carries the decision and its evidence; the
comparison set is `ls tool/lua/test_*.lua` and the shape to copy is any
file in it (`tool/lua/test_unix_errno.lua` is a short one).
Conventions are whilp/cosmopolitan's AGENTS.md. The one thing this
slice must discover rather than read is the inventory, which is why it
is step 1 and why its output is written back to this spec.
