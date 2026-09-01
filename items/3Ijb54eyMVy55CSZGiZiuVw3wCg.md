## Goal

G3, cosmo-contracts: conform `unix.getrlimit`'s return shape to the
`T|nil, err:string, errno?` invariant so a caller narrowing slot 1 does
not also need to know slot 2 means different things on the two
branches — the `unix.nanosleep`/`remnanos` deviation, recurring here,
and already worked around by hand on the cosmic side.

## Evidence

Measured against cosmic-lua/cosmopolitan master `9ca98b646166a8f5`
(16 commits ahead of `1e165815`; unaffected by any of them —
`getrlimit` is untouched between the two).

- C source: `third_party/lua/cosmo/lunix.c:1254-1264`
  (`LuaUnixGetrlimit`) — success path (`!getrlimit(...)`) pushes two
  integers (`soft`, `hard`) and `return 2;`; failure path is
  `LuaUnixSysretErrno` (`lunix.c:219-238`), returning exactly 3 values
  (`nil, error:string, errno:int`).
- `tool/net/definitions.lua:6808-6813` —
  `---@return integer|nil soft, integer hard` (one `@return` tag
  naming two positions) / `---@return string? error` /
  `---@return unix.Errno? errno`: 4 named positions describing what is
  actually a 2-value-or-3-value tuple depending on branch.
- Probe (from the cosmopolitan repo root, built binary
  `o//tool/lua/lua`, built by `make -j$(nproc) o//tool/lua/lua`):
  ```
  $ o//tool/lua/lua -e '
  local unix = require("unix")
  print(unix.getrlimit(unix.RLIMIT_NOFILE))
  print(unix.getrlimit(-1))
  '
  20000	20000
  nil	getrlimit: EINVAL: Invalid argument	22
  ```
  Success returns exactly 2 values; failure returns exactly 3. Slot 2
  is `hard` (a plain, non-nullable `integer` per the annotation) on
  success and the error string on failure — the same slot carries two
  unrelated meanings, and unlike the pre-fix `nanosleep` (which at
  least admitted `integer|string` for the shared slot), `getrlimit`'s
  annotation doesn't even admit the string is possible there.
- Cosmic-side spend: `grep -rn 'unix\.getrlimit' cosmic/` →
  `cosmic/proc/rusage.tl:41`. The wrapper already works around this
  exact hazard by hand:
  ```
  local function getrlimit(resource: integer): Rlimit | nil, string
    local soft, hard = unix.getrlimit(resource)
    if soft == nil then
      -- On failure the binding returns (nil, err, errno): the error string
      -- arrives in the second slot, where the hard limit would have been.
      return nil, errstr(hard, "getrlimit")
    end
    return {soft = soft, hard = hard}
  end
  ```
  (`cosmic/proc/rusage.tl:40-48`, comment verbatim at lines 43-44).
  The wrapper is correct and already bundles the pair into a
  `Rlimit` record on the cosmic side — this capture is about the raw
  binding's own undocumented-as-such shape, which a caller reaching for
  `unix.getrlimit` directly (bypassing `cosmic.proc`) would not expect.

## Change

Pick one shape and make declaration and implementation agree — the
same fork `unix.capget` (#309) and `unix.nanosleep` (#315) took:

(a) keep the 2-value success tuple but bundle it into one table return
(`{soft=…, hard=…}|nil, string?, unix.Errno?`), matching
`unix.capget`'s caps table and `unix.nanosleep`'s remainder table, so
slot 2 always means error regardless of branch; or
(b) document today's positional sharing explicitly as a `@overload`
pair, making clear this binding is NOT expected to conform to the
ordinary invariant.

Land whichever the goal owner picks as this item's convention, then
apply the same shape to no other binding without its own capture. If
(a) is picked, update `cosmic/proc/rusage.tl`'s `getrlimit` wrapper in
the same commit (or a same-PR follow-up in the cosmic repo) — it can
drop its positional-sharing workaround once the binding returns a
table on success, but that follow-up needs a fresh pin bump on the
cosmic side and is out of scope for this capture's own PR.

## Non-goals

- No change to `setrlimit` — already a clean `true|nil, string?,
  unix.Errno?` 3-slot tuple with a single success shape, confirmed by
  this slice's probe (`o//tool/lua/lua -e 'print(require("unix").setrlimit(999999, 100, 100))'`
  → `nil	setrlimit: EINVAL: Invalid argument	22`).
- No change to any other multi-return binding in this slice (`chroot`,
  `unshare`, `setns`, `mount`, `unmount`, `pivot_root`, `pledge`,
  `unveil`, the four `landlock_*` bindings, `sysconf`, `uname`) — all
  confirmed exact 3-slot tuples with a single, unambiguous success
  value; see the parent item's summary table.
- No change to `cosmic/proc/rusage.tl` in this capture's own PR (see
  Change, above) — land the binding fix first; the cosmic-side
  simplification is a separate, later change once a pin bump carries
  this fix.

## Acceptance

- `getrlimit`'s `definitions.lua` annotation and its C implementation's
  actual return arity/meaning agree at every call outcome.
- The PR includes a probe distinguishing the success values from the
  failure values (the transcript above, turned into an assertion in
  `test/tool/net/lunix_test.lua`, which exists today with no
  `getrlimit` coverage).
- `make -j$(nproc) o//tool/lua/test` passes.
