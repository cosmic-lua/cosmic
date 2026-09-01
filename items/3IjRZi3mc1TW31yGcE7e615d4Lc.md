## Goal

G3 — `unix.sigaction`'s declared return lies about which slots can
hold the error: `flags` and `mask` are typed as plain non-nilable
`integer`/`unix.Sigset`, but the binding's only failure path (an
EINVAL a valid-but-unactionable signal like `SIGKILL`/`SIGSTOP`
produces, or an EFAULT unreachable from Lua) returns exactly `nil,
error, errno` — three values that land in the FIRST three declared
slots (`oldhandler`, `flags`, `mask`), not in the fifth/sixth
`error`/`errno` lines the annotation names. Per AGENTS.md's contract
rule ("When slot 1 of a declared return admits nil, slot 2 is the
error — an annotation that deviates is a bug"), this is that bug for
`sigaction`. The union stays (`sig` is already validated and raises
separately, lines 2653-2656 below; the remaining failure is genuinely
environmental — which signal was named) — only the annotation is
dishonest.

## Evidence

Measured against cosmic-lua/cosmopolitan master `275b73b1d`.

`third_party/lua/cosmo/lunix.c`, `LuaUnixSigaction` (lines 2647-2728):
`sig` is range-checked and raises at lines 2652-2656 (`luaL_argerror`
if `!(1 <= sig && sig <= NSIG)`) — a separate, already-correct raise,
not part of this capture. On success (line 2700, `if (!sigaction(sig,
saptr, &oldsa))`) the function pushes 3 values (`oldhandler`, `flags`,
`mask`; lines 2701-2724). On failure (line 2726) it calls
`LuaUnixSysretErrno(L, "sigaction", olderr)`, which returns exactly 3
values: `nil, error string, errno`.

The annotation (`tool/net/definitions.lua:6651-6655`):

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
slot flags occupies on success.` — a live wrapper already coded
against exactly this undocumented sharing.

## Change

`tool/net/definitions.lua` only (annotation, no C or behavior change)
— rewrite the return block at lines 6651-6655 to declare the sharing
honestly, matching the style `unix.nanosleep`/`unix.gmtime` already
use:

```
---@param mask? unix.Sigset
---@return function|integer|nil oldhandler previous handler, or nil when
--- the call failed
---@return integer|string flags previous sa_flags, or the error string
--- when the call failed — failure returns exactly `nil, error, errno`,
--- so its two values land in the slots `flags` and `mask` occupy on
--- success, not in slots of their own
---@return unix.Sigset|unix.Errno mask previous signal mask, or the
--- errno when the call failed
function unix.sigaction(sig, handler, flags, mask) end
```

Also add, in `tool/lua/test_signal.lua`, beside the existing sigaction
coverage:

```lua
-- sigaction's one reachable failure (a valid-but-unactionable signal
-- like SIGKILL) shares two return slots with its own success values
-- (tool/net/definitions.lua); pin that shape live.
local prev, flags_or_err, mask_or_errno = unix.sigaction(unix.SIGKILL, unix.SIG_IGN)
assert(prev == nil, "sigaction on SIGKILL must report nil in the oldhandler slot")
assert(type(flags_or_err) == "string",
  "the error string must land in the slot flags occupies on success")
assert(mask_or_errno == unix.EINVAL,
  "errno must land in the slot mask occupies on success")
```

## Non-goals

- No change to `third_party/lua/cosmo/lunix.c` — `LuaUnixSigaction`'s
  runtime behavior is already correct; only its `definitions.lua`
  annotation lies.
- No change to the existing `sig` range check (lines 2652-2656) — that
  failure already raises and is out of this capture's scope (it is
  not part of the `nil`-admitting return this census scoped).
- No addition to the pure-function `PROBES` ratchet in
  `tool/lua/test_definitions_conformance.lua` — `sigaction` installs a
  real signal disposition, so it is not the "zero-risk... no side
  effects" binding that file scopes itself to.
- No cosmic-side edit — `cosmic/signal.tl`'s wrapper already
  destructures and branches on exactly this shape; nothing there
  changes.

## Acceptance

Run from the cosmopolitan repo root:

- `make -j$(nproc) o//tool/lua/test` exits 0.
- `grep -A4 '^---@param mask? unix.Sigset' tool/net/definitions.lua |
  grep -c '|string\|unix.Errno'` reports 2 or more (today 0: `flags`
  and `mask` are undecorated).
- `grep -B10 '^function unix.sigaction' tool/net/definitions.lua |
  grep -c '^---@return string? error$'` reports 0 (today 1: the
  phantom line this change deletes).

## Enablement

none needed. Documentation-only; independent of every other capture
(touches a `definitions.lua` block none of the others touch, plus an
appended `tool/lua/test_signal.lua` block).
