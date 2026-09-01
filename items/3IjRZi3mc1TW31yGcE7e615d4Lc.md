## Goal

G3 — `unix.sigaction`'s success path pushes 3 positional values
(`oldhandler`, `flags`, `mask`) while its failure path pushes `nil,
error, errno` — the same slots 2 and 3 mean unrelated things
depending on branch, and the CURRENT annotation compounds this by
declaring `flags`/`mask` as plain non-nilable `integer`/`unix.Sigset`,
which is simply false on the failure branch. This repo has since
settled how a tuple-sharing deviation like this gets fixed — NOT by
merely re-annotating the sharing as honest, but by bundling the shared
success values into one table, matching `e028f15b2` (`unix.nanosleep`,
#315) and `8180f14b4` (`unix.capget`, #309). This capture applies that
same fix to `sigaction`.

## Evidence

Measured against a live fetch of cosmic-lua/cosmopolitan master
`e028f15b2`, built fresh in `/home/user/wt-7Gbq-census`.

`third_party/lua/cosmo/lunix.c`, `LuaUnixSigaction` (lines 2662-2743):
`sig` is range-checked and raises at lines 2667-2671 (`luaL_argerror`
if `!(1 <= sig && sig <= NSIG)`) — a separate, already-correct raise,
out of this capture's scope. On success (line 2715, `if
(!sigaction(sig, saptr, &oldsa))`) the function pushes 3 values
(`oldhandler`, `flags`, `mask`; lines 2716-2739). On failure (line
2741) it calls `LuaUnixSysretErrno(L, "sigaction", olderr)`, which
returns exactly 3 values: `nil, error string, errno`.

The annotation (`tool/net/definitions.lua:6669-6673`):

```
---@param mask? unix.Sigset
---@return function|integer|nil oldhandler, integer flags, unix.Sigset mask
---@return string? error
---@return unix.Errno? errno
function unix.sigaction(sig, handler, flags, mask) end
```

`flags` (slot 2) is declared plain `integer` and `mask` (slot 3) plain
`unix.Sigset` — neither admits the string/errno they actually hold on
failure; the declared `error`/`errno` (slots 5/6) are never actually
populated, since the C never returns more than 3 values on failure.

Probe transcript, from the cosmopolitan repo root:

```
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.sigaction(unix.SIGKILL, unix.SIG_IGN))'
nil	sigaction: EINVAL: Invalid argument	22
```

(3 values: `oldhandler` is `nil` as declared; `flags` holds the error
STRING, not an integer; `mask` holds the errno integer `22`, not a
`unix.Sigset`; the declared `error`/`errno` slots are simply absent.)

Cosmic-side spend: `grep -n 'unix.sigaction' cosmic/signal.tl` →
`cosmic/signal.tl:252`, `local prev, prev_flags, prev_mask =
unix.sigaction(sig, raw_handler, flags, mask)`, followed by
(`cosmic/signal.tl:253-254`) `if prev == nil then -- On failure the
binding returns (nil, err, errno): the error string -- arrives in the
slot flags occupies on success.` — a live wrapper coded against
exactly this undocumented sharing; it destructures 3 positional
values today and MUST be rewritten to read one table's fields once
this capture lands (see Non-goals).

Precedent for the fix shape, both already merged on this master:

- `e028f15b2` (#315): bundled `unix.nanosleep`'s two positional
  remainder integers into one `unix.SleepRemainder` table, keeping
  slot 1 the value-or-nil, slots 2/3 always error/errno.
- `8180f14b4` (#309): bundled `unix.capget`'s three positional
  bitmasks into one `unix.Caps` table, same shape.

## Change

1. `third_party/lua/cosmo/lunix.c`, `LuaUnixSigaction`: replace the
   3-value push (lines 2716-2739) with one table carrying `handler`,
   `flags`, `mask` fields:

   ```c
   // unix.sigaction(sig:int[, handler:func|int[, flags:int[, mask:unix.Sigset]]])
   //     ├─→ previous:table
   //     └─→ nil, error:str, errno:int
   ...
   if (!sigaction(sig, saptr, &oldsa)) {
     lua_rawgetp(L, LUA_REGISTRYINDEX, &kSignalHandlers);
     lua_newtable(L);           // the result table, pushed before the handler lookup consumes the stack
     if (lua_rawgeti(L, -2, sig) != LUA_TFUNCTION) {
       lua_pop(L, 1);
       lua_pushinteger(L, (intptr_t)oldsa.sa_handler);
     }
     lua_setfield(L, -2, "handler");
     if (saptr) {
       if (sa.sa_sigaction == LuaUnixOnSignal) {
         lua_pushvalue(L, -3);
       } else {
         lua_pushnil(L);
       }
       lua_rawseti(L, -3, sig);   // update the registry lua table (unchanged)
     }
     lua_remove(L, -2);           // remove the signal handler table from stack (unchanged)
     lua_pushinteger(L, oldsa.sa_flags);
     lua_setfield(L, -2, "flags");
     LuaPushSigset(L, oldsa.sa_mask);
     lua_setfield(L, -2, "mask");
     return 1;
   } else {
     return LuaUnixSysretErrno(L, "sigaction", olderr);
   }
   ```

   (The exact stack-index arithmetic above is a sketch, not a literal
   patch — `LuaUnixSigaction`'s existing stack juggling around the
   registry handler-table lookup is intricate; the implementer must
   re-derive the precise `lua_newtable`/`lua_setfield`/`lua_remove`
   ordering against the CURRENT function body at
   `third_party/lua/cosmo/lunix.c:2662-2743`, preserving every existing
   comment about why the registry update and the trailing-nil handling
   work the way they do. The invariant to preserve: build ONE table
   with `handler`/`flags`/`mask` fields, return it as the sole success
   value.)

2. `tool/net/definitions.lua`, same commit — new class plus rewritten
   return block:

   ```
   --- Previous signal disposition returned by `sigaction`.
   ---@class unix.SignalAction
   ---@field handler function|integer Previous handler: a Lua function,
   --- `SIG_IGN`, `SIG_DFL`, or a raw function pointer.
   ---@field flags integer Previous `sa_flags`.
   ---@field mask unix.Sigset Previous signal mask.

   ---@param mask? unix.Sigset
   ---@return unix.SignalAction|nil previous
   ---@return string? error
   ---@return unix.Errno? errno
   function unix.sigaction(sig, handler, flags, mask) end
   ```

   Update the doc examples in the same comment block
   (`tool/net/definitions.lua:6639-6653`) that destructure
   `unix.sigaction`'s result — none currently capture `flags`/`mask`
   from a successful call, so no example needs a field-access rewrite,
   but re-check at implementation time.

3. `tool/lua/test_signal.lua`: add, before the trailing `print("PASS")`:

   ```lua
   -- sigaction now bundles its previous-disposition success values
   -- into one table (tool/net/definitions.lua); pin both branches.
   local ok_action = assert(unix.sigaction(unix.SIGUSR1))
   assert(type(ok_action) == "table" and type(ok_action.flags) == "number"
     and ok_action.mask ~= nil,
     "a successful sigaction query must return one table")
   local bad_action, err, eno = unix.sigaction(unix.SIGKILL, unix.SIG_IGN)
   assert(bad_action == nil, "sigaction on SIGKILL must report nil")
   assert(type(err) == "string", "the error must be a string, not a table field")
   assert(eno == unix.EINVAL, "errno must be EINVAL, not a table field")
   ```

## Non-goals

- No change to the existing `sig` range check (lines 2667-2671) — that
  failure already raises and is out of this capture's scope.
- No addition to the pure-function `PROBES` ratchet in
  `tool/lua/test_definitions_conformance.lua` — `sigaction` installs a
  real signal disposition, so it is not the "zero-risk... no side
  effects" binding that file scopes itself to.
- **Cosmic-side edit required, but not by this capture.** This is a
  BEHAVIOR change, unlike the honest-annotation-only fix this capture
  previously proposed: `cosmic/signal.tl:251-252`'s
  `local prev, prev_flags, prev_mask = unix.sigaction(...)` breaks the
  moment this lands (`prev_flags`/`prev_mask` go from real values to
  always-nil). Retiring that destructuring for `result.handler` /
  `result.flags` / `result.mask` is the sibling consumption slice,
  BLOCKED on this capture landing — do not fold it into this diff, and
  do not bump the cosmos pin here.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `o//tool/lua/lua -e 'local u=require("unix") local r=assert(u.sigaction(u.SIGUSR1))
  assert(type(r)=="table") assert(type(r.flags)=="number") assert(r.mask~=nil)
  local bad,e,en=u.sigaction(u.SIGKILL,u.SIG_IGN) assert(bad==nil)
  assert(type(e)=="string") assert(en==u.EINVAL)'` exits 0.
- `grep -c '^---@class unix.SignalAction' tool/net/definitions.lua`
  reports 1 (today 0).
- `grep -A2 '^function unix.sigaction' tool/net/definitions.lua |
  grep -c 'integer flags, unix.Sigset mask'` reports 0 (today 1: the
  positional 3-value return this change replaces).

## Enablement

none needed. Documentation- and C-change; independent of
`3IjRa88PfMHXoRab5q1vZjeIuTa` (setitimer, different C function,
different `definitions.lua` block) and of the raise/sigprocmask
captures. Both this capture and `3IjRa88PfMHXoRab5q1vZjeIuTa` append
to `tool/lua/test_signal.lua`, so whichever merges second rebases a
short append.
