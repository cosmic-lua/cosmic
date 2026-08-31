## Change

Bump vendored Lua from 5.4.9 to 5.5.1 and run cosmic's gate against it.

**Both halves are MERGED:**
- cosmic-lua/cosmopolitan#294 -> `6dfa6728a` on master (`LUA_VERSION` now 5/5/1)
- cosmic-lua/cosmic#1587 -> `beb0f15c` on main (`for_control_var.tl` present)

They landed separately, and that was safe: the only cross-repo coupling is
`3p/cosmos/cosmos_pin.tl`, which neither PR touches. cosmic's main still runs the
5.4 pin with an inert patch; master carries 5.5 with no consumer yet.

Steps 1-3 below are done and verified. What remains is **step 4**, which is also
the only step that proves anything about cosmic on 5.5.

**Step 4 is currently BLOCKED on cosmic's release pipeline, for an unrelated
reason.** `release.yml` has been failing since 2026-08-31T13:04Z on `de5268e98`
(#1588, the `_perf` helper dedupe) — not on the perf work in this item, and not on
either merge above, both of which landed after that run started. The failure is the
perf gate, not a build or test error:

```
embed_run_startup    1.42 ms -> 1.64 ms   +14.9%  (noise ±10.0%)  regression
49 scenarios: 1 regression, 1 faster, 47 ok
perf gate: this release regressed against the previous one and was not published.
```

Last good release is `2026-08-30-ce897b1`. No cosmos release can be cut, and so no
pin can be bumped, until that gate passes or a release is dispatched with
`perf_gate: false`. A regression in `embed_run_startup` immediately following a
refactor OF THE BENCHMARK HARNESS is worth suspecting as an artifact of the
refactor rather than a real slowdown — worth its own item either way.

(One oddity in that log, noted but not chased: the A/A self-check the gate runs to
separate real regressions from noise printed numbers identical to the comparison
that triggered it, regression line included. An A/A run reporting the same
regression as A/B suggests it did not actually re-measure.)

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

### Cosmic's exposure: five real breaks, found by parsing what Teal emits

Lua 5.5's manual section 8 lists 12 incompatibilities — 4 language, 1 library,
7 API. Eleven score zero hits in code cosmic ships or consumes; the C-API items
appear only in vendored upstream source that a bump replaces wholesale, or in
`tool/net/redbean.c`, which is not a binding cosmic wraps.

The twelfth — "the control variable in for loops is read only" — **does** bite,
in five places. Getting this right took two wrong answers first, both recorded
below, because the manual does not say WHICH variable of a generic `for` it
means and a careless probe answers the question the wrong way round.

Measured on a real 5.5.1 interpreter:

```
for p in ipairs{1} do p = 9 end        --> attempt to assign to const 'p'
for k,v in pairs{a=1} do k = "z" end   --> attempt to assign to const 'k'
for i = 1, 2 do i = i + 1 end          --> attempt to assign to const 'i'
for _,v in ipairs{1} do v = 9 end      --> accepted
```

The rule is **the FIRST variable of either loop form**, numeric and generic
alike. Only the first: a generic for's later variables stay ordinary locals.

Grepping sources cannot settle this, because what has to load on 5.5 is what
Teal EMITS. So the check is a parse sweep: build the tree, then `loadfile` every
emitted `.lua` under a real 5.5.1 binary. Excluding `o/stage/**` (5.4 bytecode,
which fails on version, not syntax), 833 text sources parse and **5 fail**:

```
o/cosmic/string.lua:209          const 'line'    <-- SHIPPED PUBLIC API
o/_build/snippets_test.lua:151   const 'line'
o/_tool/doc/dtl.lua:73           const 'param_part'
o/_tool/doc/index.lua:222        const 'base_name'
o/_types/gentype_render.lua:123  const 'part'
```

`cosmic.string.lines` is the serious one. A parse error kills the whole module,
not just the loop, so on 5.5 `require("cosmic.string")` would fail outright.

(Two further files report `unexpected symbol near '{'` under both 5.4 and 5.5:
the `.docs/index.lua` payloads, which are bare table literals loaded as
`load("return " .. source)` in `cosmic/doc/query.tl:29` — never chunks. A 5.4
control sweep reports exactly the same two, and nothing else.)

### The carried patch, landed

Closed by a carried tl patch — `3p/tl/tl_patch/for_control_var.tl`,
cosmic-lua/cosmic#1587 — which makes the generator emit `local i = i` as the
body's first statement, but only when the body reassigns the loop's first
variable. Four entries: a checker half and a generator half for each loop form,
each anchored to a `find` string occurring exactly once in the pinned `tl.lua`.

After the patch, the same sweep over the rebuilt tree reports **0** real
failures — the two data payloads and nothing else, identical to 5.4.

Discrimination is exact, and byte-identical output is preserved where no shadow
is needed:

```
for line in f() do              -->  for line in f() do local line = line;
  line = line:sub(1, -2)                line = line:sub(1, -2)
for _, v in ipairs{...} do      -->  unchanged (later var: 5.5 allows it)
for i = 1, 3 do print(i) end    -->  unchanged (never reassigned)
```

Non-vacuity proven with `_make.patch`'s `reverse` (the documented probe — a
`package.path` prepend is silently outranked by the binary's own `/zip`
searcher, and reports a confident wrong answer): de-patched, both
shadow-expected cases emit nothing. Five cases are pinned in `3p/tl/tl_test.tl`.

**Half of it is carried indefinitely.** teal-language/tl#1058 does exactly this
for the GENERIC form, so the `forin` half is ours only until a tl pin bump
carries #1058 — at which point its anchors stop matching and the fetch fails
loudly, which is the signal to drop that half. There is no numeric-for
equivalent upstream and no reason to expect one, so the `fornum` half is
permanent.

**Three corrections to earlier versions of this item**, all of them
overestimates or misreadings that measuring properly refuted:

1. It claimed the blocker was that no released Teal supports
   `gen_target = "5.5"` — true (v0.24.8 is still the newest tag, and it contains
   no `"5.5"`) but irrelevant, because 5.5 does not need its own target.
2. It treated the carried tl patches as work only a *Teal* bump implies. That
   held until this item added one of its own.
3. It said the const-control-variable rule covered only the numeric form, and
   that cosmic's 11 generic-for reassignments were "harmless, since 5.5 accepts
   that form" — and that #1058 therefore "fixes the wrong thing". All wrong.
   The error was probing with `for _, line in ...`, whose reassigned variable is
   the SECOND one, and generalizing from the one case the rule does not cover.
   #1058 fixes a real half; it simply has no numeric-for twin.

### What to do

1. ~~Run `update.sh` at 5.5.1 and resolve the rejected hunks.~~ Done in #294.
   The dry-run estimate of 8 deep hunks was low: applied SEQUENTIALLY, as
   `update.sh` really does, 28 files rejected across the three patches. Also
   found: `update.sh` never reached patches 2 and 3 on a real run, because
   `patch -p1` returns non-zero on any failed hunk and `set -e` aborts first.
2. ~~Confirm the round-trip invariant.~~ Verified independently: the real
   unmodified script re-run from the committed tree applies with zero rejects
   and leaves `git diff --stat third_party/lua` empty.
3. ~~`make o//tool/lua/test`.~~ Exit 0 from a cleaned `o/`, ratchets intact.
4. Cut a cosmos release, bump `3p/cosmos/cosmos_pin.tl`, and run
   `bin/cosmic --make ci`. **This is the real proof.** Everything above is static
   analysis plus a hand-built interpreter; running cosmic's own suite on a 5.5
   runtime is what actually settles it.
5. ~~Update the version-banner literals~~ — `README.cosmo` is done in #294; the
   cosmic-side banner literals and docs still move with the pin bump in step 4: (`cosmic/version_test.tl:14,21,37,44`,
   `cosmic/binary_test.tl:68,78` — they read `_VERSION` at run time, so only the
   expected strings move) and the docs that name 5.4 (`docs/guides/index.md:3`,
   which ships in the binary; `README.md:10`; `AGENTS.md`).

### Known unverified

- The other 11 incompatibilities were checked by source search, not by running
  cosmic on 5.5. Step 4 is what covers them.
- The parse sweep above is a hand-run probe, not a gate: it needs a 5.5
  interpreter, which the tree will not have until this bump lands. Once cosmos
  ships 5.5, worth wiring as a build check — it is the only thing that catches
  a NEW const-control-variable break in one pass.
- `third_party/lua/test/` in the fork is the vendored upstream **Lua 5.4** test
  suite (41 tracked files, guarded by its own `local version = "Lua 5.4"` in
  `all.lua`, referenced by no makefile or workflow). This bump makes it stale
  rather than breaking it — it would refuse to run against 5.5 by its own guard,
  and three of its files no longer parse. #294 deliberately leaves it alone,
  since replacing it means vendoring the 5.5 suite, a separate artifact with its
  own provenance. Worth its own item if the suite is meant to be live at all.
- 5.5 prints floats with enough digits to round-trip. Cosmic formats via explicit
  `%.17g` (`cosmic/_literal_format.tl:76`) and via the C encoder for JSON, so the
  practical impact looks nil — not confirmed inside `ljson.c`.

## Non-goals

- No Teal pin bump, and no adoption of an untagged Teal commit.
- No change to `gen_target`, which stays `"5.4"`.
