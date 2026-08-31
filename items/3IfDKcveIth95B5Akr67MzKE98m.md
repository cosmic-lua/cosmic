## Change

Bump the vendored Lua from 5.4.6 to 5.4.9 in `third_party/lua/`, re-applying the
fork's integration over upstream's changes.

### The gap, and why it matters here

`third_party/lua/lua.h` declares `LUA_VERSION_RELEASE "6"` and
`third_party/lua/README.cosmo` names the provenance as `lua/lua@6443185167c7`,
"New release number (5.4.6)", 2 May 2023. Upstream's 5.4 line has since reached
**5.4.9** (25 Aug 2026) and is now closed — lua.org states no further 5.4 releases
are planned.

Between them are **50 bug-fix commits touching 32 files, +488/-296**. Several are
memory-safety or GC correctness in an interpreter that runs arbitrary user code:

```
Bug: Use after free in 'luaV_finishset'
Bug: shift overflow in utf-8 decode
Bug: new metatable in weak table can fool the GC
Bug: Issues with write barrier for __newindex
Bug: Constructors with nils can overflow counters
Bug: GC checks stack space before running finalizer
Bug: Loading a binary chunk does not run the GC
Bug: luaL_traceback may need more than 5 stack slots
Bug: Bad stack manipulation in 'multiline' (REPL)
```

**Two were probed directly and are absent from this tree**, so the gap is real
rather than inferred:

```
$ grep -c "anchor 't'" third_party/lua/lvm.c
0                                    # the luaV_finishset use-after-free fix

$ grep -n "count > 5" third_party/lua/lutf8lib.c
91:    if (count > 5 || res > MAXUTF || res < limits[count])
                                     # the pre-fix form; upstream now returns
                                     # early on c >= 0xfe before the shift
```

### The cost, measured, and where it actually lands

`third_party/lua` diverges from stock 5.4.6 by **3,312 changed lines across 58
files** — `lapi.c` 515, `lauxlib.c` 453, `lvm.c` 120, `ldo.c` 114, `lobject.c` 96,
`lcode.c` 68, `lparser.c` 64, `llex.c` 63 and so on. **Almost none of that is this
fork's.** Measured against `jart/cosmopolitan@3293fad0`, this fork's own changes
under `third_party/lua` are 13 files, +2,169/-332, and they are bindings sharing
the directory rather than interpreter code:

```
+1655 -239  lunix.c            +174 -2   luaencodeluadata.c
 +169 -22   luaencodejsondata.c +46  -0   lrepl.c
  +45 -0    lreplmod.c          +45 -58   lua.main.c
   +6 -5    lauxlib.c   <- the ONLY core Lua file this fork touches
```

So the rebase is over **upstream cosmopolitan's** integration, not ours. Take the
5.4.9 sources, re-apply that integration, and verify. The upstream delta being
+488/-296 is what makes this tractable: it is a small change to rebase a large
patch set across.

### The decision this item must make first

Upstream cosmopolitan (`jart/cosmopolitan`) is the natural owner of this bump —
the integration being rebased is theirs — but that repo is running roughly two
commits a month, and doing the bump here increases this fork's divergence from it,
which is a property this project has chosen to protect. Settle which before
starting:

- do it here and carry a larger delta (and offer it upstream as a PR); or
- do it here narrowly by backporting only the safety-relevant commits, keeping the
  version at 5.4.6 and the delta small; or
- wait for upstream, having established that waiting is acceptable given the fixes
  named above.

The middle option deserves explicit consideration: it is smaller and it targets the
actual risk, at the cost of a version string that no longer describes the tree.

### Gate

`make -j$(nproc) o//tool/lua/test` — which includes the binding annotation ratchet
(`definitions coverage`, `return arity`) that would catch a binding broken by the
rebase. Re-probe both fixes above afterwards. Cosmic side: a cosmos release, a
`3p/cosmos/cosmos_pin.tl` bump, and `bin/cosmic --make ci`, since the Teal
compiler and the whole stdlib run on this interpreter.

## Non-goals

- **Not Lua 5.5.** That is a separate capture; 5.4.9 is the terminal release of the
  line this tree is already on.
- No change to the fork's own bindings beyond what the rebase requires.
