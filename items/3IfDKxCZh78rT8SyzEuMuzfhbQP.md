## Capture

Moving cosmic to Lua 5.5. Researched and measured; **not blocked on cosmic and not
blocked on Lua — blocked on Teal**, which has no released version that can target
5.5. Not pullable as written.

### The headline, measured

The migration is cheap everywhere except one place, and that place is outside this
project's control.

| half | cost |
|---|---|
| the interpreter | **8 real patch conflicts** |
| cosmic's own Teal/Lua code | **zero** incompatibility hits |
| Teal | **no released version supports 5.5** |

### The interpreter: 8 conflicts, measured by running the mechanism

With `update.sh` and the numbered patches landed (#291), the cost of a 5.5 bump is
no longer an estimate. Running the mechanism at 5.5.1 against master:

```
$ sh third_party/lua/update.sh 5.5.1 1c4b4068… 62a7015b… 6d2e3db3…
39 of 58 stock files applied clean
19 files with rejects, 23 rejected hunks
```

Of those 23 hunks, **15 sit in the header/include region (< line 40)** — the
`0001-cosmo-build.patch` libc-header swaps, mechanical to re-apply. **8 are deep,
real code**, across 7 files: `lvm.c` ×2, then `lauxlib.h`, `lcode.c`, `linit.c`,
`lstate.c`, `ltable.c`, `ltablib.c`. Sampled, `lvm.c`'s two are inside the
`op_order` macro, where upstream restructured integer comparison.

The `.c`/`.h` file set is **identical** between 5.4.9 and 5.5.1 (`comm` over both
tags, both directions empty), so `update.sh` needs no structural change.

Checksums, for whoever does this: tarball `1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce`
(lua.org published), `ltests.c` `62a7015b036d366addd131e4f046f38557d66b8f48aae120e8aad992f3d90199`,
`ltests.h` `6d2e3db39c58bdadc3a0aaf3ded12873e0b56ad898ce11a872717da72efb4829` (both
from the `v5.5.1` tag).

### Cosmic's own code: zero collisions

Lua 5.5's manual §8 lists **12 incompatibilities** — 4 language, 1 library, 7 API:
`global` becomes a reserved word; the numeric-for control variable becomes read
only; `__call` chains cap at 15; a `nil` error object becomes a string;
`collectgarbage`'s `"incremental"`/`"generational"` parameter passing changes; and
seven C-API items (`lua_call` nresults ≤ 250, `lua_newstate` gains a hash-seed
parameter, `lua_resetthread` and `lua_setcstacklimit` deprecated, `lua_dump`
writer semantics, `LUA_GCINC`/`LUA_GCGEN` replaced by `LUA_GCPARAM`,
`lua_pushvfstring` reporting rather than raising errors).

**Every one scores zero hits in code cosmic ships or consumes.** `global` appears
only as Teal's own keyword; ~225 numeric `for` loops were scanned and none
reassigns its control variable; the 5 `__call` definitions are single-level
iterator sugar; all 15 `collectgarbage` calls use only `collect`/`stop`/`count`/
`restart`; and the C-API items appear only in vendored upstream source that a bump
replaces wholesale, or in `tool/net/redbean.c`, which is not one of the bindings
cosmic wraps.

Worth recording because it is easy to assume otherwise: the changes that made
5.1→5.4 painful — integer division, `math` semantics, string coercion, `__gc`,
goto, varargs, `load` — **are not in this hop's list at all**.

One item not classified as an incompatibility but capable of changing output:
floats now print with enough digits to round-trip. Cosmic formats through explicit
`%.17g` (`cosmic/_literal_format.tl:76`) and through the C encoder for JSON, so the
practical impact looks nil — unconfirmed inside `ljson.c`, and worth a check rather
than an assumption.

### Teal: the actual blocker

The pinned Teal is 0.24.8 (`3p/tl/tl_pin.tl`), and cosmic sets `gen_target = "5.4"`
(`cosmic/_teal_engine.tl:64`, mirrored in `tlconfig.lua:11` and gated by
`cosmic/teal_config_test.tl`).

```
$ curl -s https://raw.githubusercontent.com/teal-language/tl/v0.24.8/tl.lua | grep -c '"5\.5"'
0
$ …| grep -oE '"5\.[0-9]"' | sort -u
"5.1" "5.3" "5.4"

$ git ls-remote --tags --refs https://github.com/teal-language/tl | … | sort -V | tail -1
v0.24.8
```

**v0.24.8 is the newest tag.** 5.5 support exists only on unreleased `main`
(commit "allow Lua 5.5 as a target", plus named-varargs and const-for-control-var
work), which is **179 commits and one architectural rewrite** past the pin —
the monolithic 15,282-line `tl.lua` was split into a 39-file `teal/` tree with a
new macro system. Adopting it means either running an unpinned commit, against
this project's pin-and-verify trust model, or waiting for a release nobody has cut.

**And the three carried patches would need re-porting, not re-applying.**
`3p/tl/tl_patch/{ast_cache,closure,narrow}.tl` are 972 lines of exact-anchor
find/replace against 0.24.8's generated output, and `_make/patch.tl` requires each
anchor to match **exactly once**. A spot-check of `narrow`'s anchor found the
equivalent line now occurs **3 times** in `main`'s generated `tl.lua` — so the
mechanism fails loudly, which is correct, and the work is to re-locate each
behaviour in the new module tree. These patches carry real narrowing behaviour the
checker depends on, so a half-port degrades type checking quietly rather than
failing. Not line-by-line audited; the signal is qualitative but strong.

### Cosmic's own 5.4 assumptions, enumerated

Mechanical once Teal is available: `cosmic/_teal_engine.tl:64`
(`DEFAULT_GEN_TARGET`), `tlconfig.lua:11`, version-banner test literals
(`cosmic/version_test.tl:14,21,37,44`, `cosmic/binary_test.tl:68,78` — these read
`_VERSION` at run time, so only the expected literals move),
`docs/guides/index.md:3` (ships in the binary), `README.md:10`, `AGENTS.md`, and
`_types/gentl.tl:167,190,238` doc comments enumerating targets. No committed
`.d.tl` files exist — they are generated per build.

`gen_target` is passed through as a plain string with no enum validation in cosmic,
so cosmic itself imposes no gate; the gate is entirely Teal's.

### Sequencing

The **cold-build rule** means a checker bump cannot be one PR: generation 1
compiles the whole tree with the pinned release's checker, so a new checker lands
first, then a release, then the pin bump, then code that needs it.

The 5.4.9 bump (this item's blocker) should land regardless — it takes the
memory-safety fixes and commits nobody to 5.5.

### What would unblock this

A **released** Teal that accepts `gen_target = "5.5"`. Until one exists, this is
not a schedulable engineering task, and re-estimating it is wasted effort. The one
piece of real, estimable work identified is re-porting the three tl patches onto
the post-rewrite checker — and that only becomes worth starting once there is a
tagged version to port them against.

Re-check trigger: a new Teal tag beyond v0.24.8.

## Non-goals

- No decision to adopt 5.5.
- No Teal pin bump, and specifically no adoption of an untagged Teal commit.
