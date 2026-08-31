## Change

Give `third_party/lua` the structure `third_party/sqlite3` already has — pristine
upstream sources, a mechanical rewrite, and numbered patches — and land the
5.4.6 → 5.4.9 bump as the first exercise of it.

Backporting the individual safety fixes was the cheaper option and is rejected
deliberately: it treats the symptom, leaves the version string describing a tree it
no longer matches, and leaves the next bump exactly as expensive as this one.

### The gap that motivates moving at all

`third_party/lua/lua.h` declares `LUA_VERSION_RELEASE "6"`; `README.cosmo` names
`lua/lua@6443185167c7`, "New release number (5.4.6)", 2 May 2023. Upstream's 5.4
line reached **5.4.9** (25 Aug 2026) and is now closed. Between them: **50 bug-fix
commits, 32 files, +488/-296**, including a use-after-free, a GC write-barrier bug,
and an integer overflow. Two were probed and are absent here:

```
$ grep -c "anchor 't'" third_party/lua/lvm.c
0                                   # luaV_finishset use-after-free fix

$ grep -n "count > 5" third_party/lua/lutf8lib.c
91:    if (count > 5 || res > MAXUTF || res < limits[count])
                                    # pre-fix form; upstream returns early
                                    # on c >= 0xfe before the shift
```

### What the divergence actually is

It reads as 3,312 changed lines across 58 files with **zero pristine files**, which
sounds intractable. Decomposed, it is mostly mechanical:

| | lines |
|---|---|
| banner/header blocks (cosmo's license box replacing Lua's `/* $Id */`) | 980 |
| include-path rewrites to full repo paths | 801 |
| **mechanical subtotal** | **1,781** |
| **semantic remainder** | **1,531** |

and the semantic half is concentrated: `lapi.c` 453 and `lauxlib.c` 408 are **56% of
it**, then `lctype.h` 94, `luaconf.h` 67, `lvm.c` 56, `lua.h` 41, `ldo.c` 41.

Separately, **27 files in that directory are not Lua at all** — bindings and glue
that merely share the folder, ~8,700 lines:

```
lunix.c 5111   luac.main.c 746   luaencodeluadata.c 616   lrepl.c 534
luaencodejsondata.c 433   lua.main.c 416   luacallwithtrace.c 89
luaencodeurl.c 84   serialize.c 68   luaparseurl.c 60   visitor.c 59
cosmo.h 49   luapushheaders.c 45   lreplmod.c 45  … and 13 smaller
```

Five stock files are dropped outright: `lctype.c`, `lua.c`, `onelua.c`,
`ljumptab.h`, `lopnames.h`.

### The model is already in this tree

`third_party/sqlite3/update.sh` fetches pristine upstream by URL, verifies sha256,
applies a mechanical `rewrite_includes`, then applies `patches/*.patch` in order.
Its own comment states the principle this item is applying to Lua:

> any further deviation must be checked into patches/ as a numbered patch so
> version bumps stay mechanical

So this is not a new mechanism. It is the second use of one this fork already
built, for the dependency where the payoff is largest.

### The work, in landing order

1. **Move the 27 non-Lua files out of `third_party/lua/`.** They are bindings, not
   interpreter. Mostly `git mv` plus `BUILD.mk` and include-path updates. After
   this the directory is Lua plus a delta, which is what makes the rest legible.
2. **Write `third_party/lua/update.sh`** on the sqlite3 model: fetch a pinned
   `lua-<version>.tar.gz` by URL, verify sha256, install the pristine sources,
   apply the mechanical transform (the banner block and the include rewrite — both
   are scriptable and together account for 1,781 of the 3,312 lines), then apply
   `patches/*.patch`.
3. **Extract the 1,531 semantic lines into numbered patches**, starting with the two
   files carrying the majority. Each patch gets a header saying what it is for, as
   sqlite3's do.
4. **Bump to 5.4.9** by running the machinery, and update `README.cosmo` with the
   version and sha256.

Each step is its own PR; step 1 is independent and can land first.

### The acceptance test that proves the extraction lost nothing

Before bumping, run `update.sh` pinned at **5.4.6** and byte-compare the result
against the current tree. Identical output means the mechanical transform plus the
patch set fully capture the divergence — nothing was silently dropped. Only then
change the version argument to 5.4.9. Without this check, an incomplete extraction
is indistinguishable from a successful one until something breaks at runtime.

### Gate

`make -j$(nproc) o//tool/lua/test`, including the binding annotation ratchet
(`definitions coverage`, `return arity`) that catches a binding broken by the move.
Re-probe both absent fixes above. Cosmic side: a cosmos release, a
`3p/cosmos/cosmos_pin.tl` bump, and `bin/cosmic --make ci` — the Teal compiler and
the whole stdlib run on this interpreter.

### The cost, stated

This grows the diff against `jart/cosmopolitan` in a directory that already
diverges heavily, which is a property this project otherwise protects. Taken
deliberately: the current shape charges its cost at every bump forever, upstream is
running about two commits a month so waiting for them to do it is not a plan, and
the restructure is offerable upstream as a PR on its own merits — the sqlite3 one
established the pattern there.

## Non-goals

- **Not Lua 5.5.** Separate item. 5.4.9 is the terminal release of the line this
  tree already targets, and the machinery built here is what makes 5.5 assessable.
- **No behaviour change to the bindings.** Step 1 moves files; it does not change
  what they do.
- No attempt to upstream any of the semantic patches to lua.org.
