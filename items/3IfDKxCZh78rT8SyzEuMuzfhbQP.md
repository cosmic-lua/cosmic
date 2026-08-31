## Change

Bump vendored Lua from 5.4.9 to 5.5.1 and run cosmic's gate against it. Measured,
this is a days-scale experiment, not a migration — **no Teal bump is required and
there is no dependency blocker.**

An earlier version of this item said the opposite (blocked on Teal's release
cadence, months-scale). That was wrong, twice over, and the corrections are
recorded below because both were the result of measuring the wrong thing.

### The interpreter: 8 real conflicts, measured

Running the `update.sh` mechanism at 5.5.1 against master:

```
39 of 58 stock files applied clean
19 files with rejects, 23 rejected hunks
  15 shallow  — header/include region (< line 40), 0001-cosmo-build's libc swaps
   8 deep     — real code, across 7 files
```

The deep ones: `lvm.c` ×2 (inside the `op_order` macro, where upstream restructured
integer comparison), then one each in `lauxlib.h`, `lcode.c`, `linit.c`,
`lstate.c`, `ltable.c`, `ltablib.c`.

The `.c`/`.h` file set is **identical** between 5.4.9 and 5.5.1, so `update.sh`
needs no structural change.

Checksums: tarball `1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce`
(lua.org published, verified by `sha256sum -c` against the real download),
`ltests.c` `62a7015b036d366addd131e4f046f38557d66b8f48aae120e8aad992f3d90199`,
`ltests.h` `6d2e3db39c58bdadc3a0aaf3ded12873e0b56ad898ce11a872717da72efb4829`
(both from the `v5.5.1` tag).

### Cosmic's exposure: zero, verified on a real 5.5 interpreter

Lua 5.5's manual §8 lists 12 incompatibilities — 4 language, 1 library, 7 API.
Every one scores zero hits in code cosmic ships or consumes; the C-API items appear
only in vendored upstream source that a bump replaces wholesale, or in
`tool/net/redbean.c`, which is not a binding cosmic wraps.

The one that could plausibly have bitten is "the control variable in for loops is
read only". The manual does not say whether that covers generic `for-in` as well as
numeric `for`. **Settled empirically** by building stock Lua 5.5.1 (`cc -O1
-DLUA_USE_LINUX`) and running both forms:

```
$ lua55 -e 'for _,line in ipairs{"ab"} do line = line:sub(1,-2) print(line) end'
a                                     ← for-in assignment is ACCEPTED

$ lua55 -e 'for i=1,2 do i = i + 1 end'
attempt to assign to const variable 'i'   ← numeric for is REJECTED
```

So only the numeric form errors. Scanning for it:

```
cosmic Teal sources:        248 numeric for loops, 0 control-variable reassignments
tl.lua 0.24.8 (embedded):    58 numeric for loops, 0 control-variable reassignments
```

Both clean. Cosmic does reassign generic `for-in` control variables at 11 sites
(`cosmic/string.tl:209`, `cosmic/env.tl:147`, `_tool/doc/dtl.tl:73,87`,
`_types/gentype_render.tl:123,141,288` and others) — **harmless**, since 5.5
accepts that form.

### Why no Teal bump is needed

[teal-language/tl#1058](https://github.com/teal-language/tl/pull/1058) ("compat:
Lua 5.3 semantics for control variables in Lua 5.4+", merged 2026-02-01) states
that `--gen-target 5.4` is the correct setting for both Lua 5.4 and Lua 5.5. So
`gen_target` stays `"5.4"` (`cosmic/_teal_engine.tl:64`, mirrored in
`tlconfig.lua:11`) and no 5.5 target mode is required.

That PR is not in the pinned 0.24.8 — verified: the pinned compiler emits a bare
`line = line:sub(1, -2)` inside a `for-in` with no `local line = line` shadow. It
does not matter, because the form it would shadow is the one 5.5 accepts, and the
pinned compiler emits no numeric-for reassignments at all.

**Two corrections to earlier versions of this item.** First, it claimed the blocker
was that no released Teal supports `gen_target = "5.5"` — true (v0.24.8 is still
the newest tag, and it contains no `"5.5"`) but irrelevant, because 5.5 does not
need its own target. Second, it treated the three carried tl patches
(`3p/tl/tl_patch/`) as work this item implies; they are only implicated by a *Teal*
bump, which this item does not require. Re-porting them onto Teal's post-rewrite
39-module tree remains real future work, but it belongs to a tl pin bump, not here.

### What to do

1. Run `update.sh` at 5.5.1; resolve the 8 deep hunks (upstream's `op_order`
   restructuring in `lvm.c` is the substantive one), leaving the 15 shallow
   header hunks to mechanical re-application.
2. Confirm the round-trip invariant still holds: re-running at 5.5.1 from the
   committed tree must produce an empty `git diff --stat third_party/lua`.
3. `make -j$(nproc) o//tool/lua/test` must pass with the binding ratchets intact.
4. Cut a cosmos release, bump `3p/cosmos/cosmos_pin.tl`, and run
   `bin/cosmic --make ci`. **This is the real proof.** Everything above is static
   analysis plus a hand-built interpreter; running cosmic's own suite on a 5.5
   runtime is what actually settles it.
5. Update the version-banner literals (`cosmic/version_test.tl:14,21,37,44`,
   `cosmic/binary_test.tl:68,78` — they read `_VERSION` at run time, so only the
   expected strings move) and the docs that name 5.4 (`docs/guides/index.md:3`,
   which ships in the binary; `README.md:10`; `AGENTS.md`).

### Known unverified

- The other 11 incompatibilities were checked by source search, not by running
  cosmic on 5.5. Step 4 is what covers them.
- 5.5 prints floats with enough digits to round-trip. Cosmic formats via explicit
  `%.17g` (`cosmic/_literal_format.tl:76`) and via the C encoder for JSON, so the
  practical impact looks nil — not confirmed inside `ljson.c`.

## Non-goals

- No Teal pin bump, and no adoption of an untagged Teal commit.
- No change to `gen_target`, which stays `"5.4"`.
