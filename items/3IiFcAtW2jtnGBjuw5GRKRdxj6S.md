## Goal

Close one exactness gap in `cosmo.unix`'s descriptor-I/O contract,
found while classifying the 17 nil-admitting bindings of the
descriptor/terminal census (item 95kn_ULxq, sibling to #276/#277):
`unix.isatty` is documented to return `nil` plus an error/errno on
`EBADF` (bad fd) or `EPERM` (pledge), but its C implementation's
`nil`-returning branch is dead code — the underlying libc `isatty()`
never returns the sentinel (`-1`) the branch checks for — so a bad fd
silently returns `false`, a value that is not even in the binding's
declared `true|nil` return type. This is the strongest form of the
class-2 "verify the tuple" check: not a shared slot, but a declared
type that is wrong in both directions (claims a `nil` that can never
happen; omits the `false` that always can).

## Evidence

**Underlying libc contract** — `libc/calls/isatty.c:30-57`:

```c
/**
 * Tells if file descriptor is a terminal.
 *
 * @param fd is file descriptor
 * @return 1 if is terminal, otherwise 0 w/ errno
 * @raise EBADF if fd isn't a valid file descriptor
 * @raise ENOTTY if fd is something other than a terminal
 * @raise EPERM if pledge() was used without tty
 */
bool32 isatty(int fd) {
  bool32 res;
  struct winsize ws;
  if (__isfdkind(fd, kFdZip)) {
    enotty();
    res = false;
  } else if (IsWindows() || IsMetal()) {
    res = sys_isatty(fd);
  } else if (!sys_ioctl(fd, TIOCGWINSZ, &ws)) {
    res = true;
  } else {
    res = false;
    if (errno != EBADF && errno != EPERM) {
      enotty();
    }
  }
  STRACE("isatty(%d) → %hhhd% m", fd, res);
  return res;
}
```

`isatty()`'s return type is `bool32` and every branch assigns `true` or
`false` — there is no path that returns `-1` (or anything else). Its
own doc comment matches POSIX: "return 1 if is terminal, otherwise 0 w/
errno" — the failure signal is `errno`, not the return value.

**Lua wrapper** — `third_party/lua/cosmo/lunix.c:2878-2891`:

```c
// unix.isatty(fd:int)
//     ├─→ true
//     ├─→ false
//     └─→ nil, error:str, errno:int
static int LuaUnixIsatty(lua_State *L) {
  int olderr = errno;
  int rc = isatty(luaL_checkinteger(L, 1));
  if (rc == -1) {
    return LuaUnixSysretErrno(L, "isatty", olderr);
  } else {
    lua_pushboolean(L, rc != 0);
    return 1;
  }
}
```

`rc = isatty(fd)` can only ever be `0` or `1` (see above), so
`rc == -1` is provably always false: the `nil`-returning branch is
dead code. Every call — good fd, bad fd, non-tty fd, pledge-restricted
fd — falls through to `lua_pushboolean(L, rc != 0)` and returns a
single boolean.

**`tool/net/definitions.lua:7256-7270`** (current, wrong on two counts):

```
--- Returns true if file descriptor is a teletypewriter. Otherwise nil
--- with an Errno object holding one of the following values:
---
--- - `ENOTTY` if `fd` is valid but not a teletypewriter
--- - `EBADF` if `fd` isn't a valid file descriptor.
--- - `EPERM` if pledge() is used without `tty` in lenient mode
---
--- No other error numbers are possible.
---
---@param fd integer
---@return true|nil
---@return string? error
---@return unix.Errno? errno
---@nodiscard
function unix.isatty(fd) end
```

**Probes**, run from the cosmopolitan repo root after
`make -j$(nproc) o//tool/lua/lua`:

```
$ o//tool/lua/lua -e '
local unix = require "unix"
print("bad fd:", unix.isatty(999999))
print("stdin:", unix.isatty(0))
local fd = unix.open("/etc/hostname", unix.O_RDONLY)
print("regular file (valid fd, not a tty):", unix.isatty(fd))
'
bad fd:	false	nil	nil
stdin:	false	nil	nil
regular file (valid fd, not a tty):	false	nil	nil
```

All three cases — a genuinely invalid fd (should be `EBADF` per the
doc), a valid non-tty fd (should be `ENOTTY` per the doc, and the one
case the doc itself calls the normal/non-error outcome), and the
harness's actual stdin (redirected to a pipe, so also non-tty here —
returns `false` either way, correctly by accident) — are
indistinguishable: all return `false, nil, nil`. A caller cannot tell
"this fd is not a terminal" from "this fd is not even valid" — the
`nil, error, errno` branch the docs promise for the latter is
unreachable.

**Cosmic-side spend** (`grep -rn 'unix\.isatty' /home/user/cosmic/cosmic/`):

```
cosmic/tty.tl:112:--- @return boolean True if fd is a terminal
cosmic/tty.tl:113:  return unix.isatty(fd or 1) or false
```

`cosmic/tty.tl` already declares `is_tty`'s return type as a bare
`boolean` (not `boolean|nil`) and defensively normalizes with
`or false` — i.e. cosmic's own wrapper has independently arrived at
"this never really returns nil" and coded around it, even though
nothing in `tool/net/definitions.lua` says so today.

## Change

Two independent fixes are available; this capture's `Change` is the
first only — the second is named as a follow-up, not adopted here, to
keep this capture's risk to a documentation-only edit.

**1. (this capture) Fix the annotation to match actual behavior.**
Replace, in `tool/net/definitions.lua`:

```
--- Returns true if file descriptor is a teletypewriter. Otherwise nil
--- with an Errno object holding one of the following values:
---
--- - `ENOTTY` if `fd` is valid but not a teletypewriter
--- - `EBADF` if `fd` isn't a valid file descriptor.
--- - `EPERM` if pledge() is used without `tty` in lenient mode
---
--- No other error numbers are possible.
---
---@param fd integer
---@return true|nil
---@return string? error
---@return unix.Errno? errno
---@nodiscard
function unix.isatty(fd) end
```

with:

```
--- Returns true if file descriptor is a teletypewriter, false
--- otherwise — including when `fd` is invalid (`EBADF`) or
--- pledge()-restricted (`EPERM`). The underlying libc isatty() never
--- signals failure through its return value (only through `errno`,
--- which this binding does not currently surface), so there is no nil
--- case: a bad fd and a valid non-terminal fd are indistinguishable
--- here.
---@param fd integer
---@return boolean
---@nodiscard
function unix.isatty(fd) end
```

No C code changes in this capture — `LuaUnixIsatty`'s actual behavior
(a single boolean, always) is unchanged; only the doc comment and
declared type are corrected to match it. This alone moves
`unix.isatty` from NIL to EXACT in the census.

**2. (named, not part of this capture) Behavioral fix, if wanted.**
`LuaUnixIsatty` could call `ioctl(fd, TIOCGWINSZ, &ws)` directly (as
`LuaUnixTiocgwinsz` already does) instead of going through libc
`isatty()`, and branch on `errno`: `ENOTTY` → `false`; `EBADF`/`EPERM`
→ `nil, error, errno` — which is what the CURRENT doc comment already
(incorrectly) claims happens. That would be a real behavior change at
the C boundary (and needs the matching `definitions.lua` update plus a
cosmic-side type regen and `cosmic/tty.tl` review, per this repo's
"binding contracts are frozen at the C boundary... landed as its own
change" convention) — left for the goal owner's `compare` to decide
whether it's worth a separate item.

## Non-goals

- No change to `LuaUnixIsatty`'s C implementation in this capture —
  see "2." above, explicitly deferred, not adopted.
- No change to any other binding.
- No change to `cosmic/tty.tl`'s `is_tty` — its `boolean` return type
  and `or false` guard already match the corrected annotation; nothing
  there needs to change.

## Acceptance

- `tool/net/definitions.lua`'s `unix.isatty` annotation declares
  `---@return boolean` with no `nil`/`string?`/`unix.Errno?` slots, and
  its prose states plainly that a bad fd returns `false`, not `nil`.
- `make -j$(nproc) o//tool/lua/test` still passes (this is a comment-only
  change; no binding behavior changes).
- Re-running `census.awk` (item 95kn_ULxq's `## Evidence`) after the
  fix classifies `unix.isatty` as EXACT, not NIL.
- The three probes above, re-run against the rebuilt binary, still
  return byte-identical values — the fix documents reality, it does
  not change it.
