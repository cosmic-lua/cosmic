## Goal

G3 — `unix.setitimer`'s declared return lies the same way
`unix.sigaction`'s does (`3IjRZi3mc1TW31yGcE7e615d4Lc`): `intervalns`, `valuesec`, and
`valuens` are typed as plain non-nilable `integer`, but the binding's
only failure (EINVAL for an invalid `which`) returns exactly `nil,
error, errno` — three values that land in the first three declared
slots (`intervalsec`, `intervalns`, `valuesec`), not in the
fifth/sixth `error`/`errno` lines the annotation names.

## Evidence

Measured against cosmic-lua/cosmopolitan master `275b73b1d`.

`third_party/lua/cosmo/lunix.c:2755-2777`, `LuaUnixSetitimer`: on
success (`!setitimer(which, itptr, &oldit)`, line 2768) pushes 4
integers (lines 2769-2772). On failure (line 2775) calls
`LuaUnixSysretErrno(L, "setitimer", olderr)` — exactly 3 values: `nil,
error string, errno`.

The annotation (`tool/net/definitions.lua:6693-6702`):

```
---@param which integer
---@param intervalsec integer
---@param intervalns integer needs to be on the interval `[0,1000000000)`
---@param valuesec integer
---@param valuens integer needs to be on the interval `[0,1000000000)`
---@return integer|nil intervalsec, integer intervalns, integer valuesec, integer valuens
---@return string? error
---@return unix.Errno? errno
---@overload fun(which: integer): intervalsec: integer, intervalns: integer, valuesec: integer, valuens: integer
function unix.setitimer(which, intervalsec, intervalns, valuesec, valuens) end
```

`intervalns`/`valuesec`/`valuens` are declared plain `integer` — none
admits the string/errno `intervalns`/`valuesec` actually hold on
failure, and `valuens` is simply absent (never returned) on failure
though declared as always present.

Probe transcript, from the cosmopolitan repo root:

```
$ o//tool/lua/lua -e 'local unix=require("unix") print(unix.setitimer(999))'
nil	setitimer: EINVAL: Invalid argument	22
```

(3 values: `intervalsec` nil as declared; `intervalns` holds the error
STRING; `valuesec` holds the errno integer `22`; `valuens` and the
declared `error`/`errno` slots are absent.)

Cosmic-side spend: `grep -n 'unix.setitimer' cosmic/signal.tl` →
`cosmic/signal.tl:201`, `local old_isec, old_ins, old_vsec, old_vns =
unix.setitimer(...)`, followed by (`cosmic/signal.tl:208-211`) `if
old_isec == nil then -- On failure the binding returns (nil, err,
errno): the error string -- arrives in the second slot. return nil,
errstr(old_ins, "setitimer") end` — a live wrapper already coded
against exactly this undocumented sharing.

## Change

`tool/net/definitions.lua` only — rewrite the return block at lines
6698-6700 (three lines becoming four) to declare the sharing
honestly; the `---@overload` line and the `function
unix.setitimer(...) end` line are unchanged:

```
---@return integer|nil intervalsec previous interval seconds, nil when
--- the call failed
---@return integer|string intervalns previous interval nanoseconds, or
--- the error string when the call failed — failure returns exactly
--- `nil, error, errno`, so its two values land in the slots
--- `intervalns` and `valuesec` occupy on success, not in slots of
--- their own past `valuens`
---@return integer|unix.Errno valuesec previous value seconds, or the
--- errno when the call failed
---@return integer? valuens previous value nanoseconds, present only
--- on success
```

Also add, in `tool/lua/test_signal.lua`, beside the existing setitimer
coverage:

```lua
-- setitimer's one reachable failure (an invalid `which`) shares two
-- return slots with its own success values (tool/net/definitions.lua);
-- pin that shape live.
local isec, ins_or_err, vsec_or_errno = unix.setitimer(999)
assert(isec == nil, "setitimer(999) must report nil in the intervalsec slot")
assert(type(ins_or_err) == "string",
  "the error string must land in the slot intervalns occupies on success")
assert(vsec_or_errno == unix.EINVAL,
  "errno must land in the slot valuesec occupies on success")
```

## Non-goals

- No change to `third_party/lua/cosmo/lunix.c` —
  `LuaUnixSetitimer`'s runtime behavior is already correct; only its
  `definitions.lua` annotation lies.
- No addition to the pure-function `PROBES` ratchet in
  `tool/lua/test_definitions_conformance.lua` — `setitimer` arms a
  real interval timer, so it is not the "zero-risk... no side
  effects" binding that file scopes itself to.
- No cosmic-side edit — `cosmic/signal.tl`'s wrapper already
  destructures and branches on exactly this shape; nothing there
  changes.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `grep -c '^---@return integer|string intervalns' tool/net/definitions.lua`
  reports 1 (today 0).
- `grep -B10 '^function unix.setitimer' tool/net/definitions.lua |
  grep -c '^---@return string? error$'` reports 0 (today 1: the
  phantom line this change deletes).

## Enablement

none needed. Documentation-only; independent of every other capture.
