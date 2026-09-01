## Goal

Close one exactness gap in `cosmo.unix`'s descriptor-I/O contract,
found while classifying the 17 nil-admitting bindings of the
descriptor/terminal census (item 95kn_ULxq, sibling to #276/#277):
`unix.tiocgwinsz`'s declared return shape claims four fixed,
distinctly-typed slots, but its C implementation only ever returns 2
values (success) or 3 (failure), so on failure the declared `cols`
slot actually carries the error string and the declared `error` slot
actually carries the errno integer. Fix the annotation to say so,
honestly, the same way `unix.nanosleep` already does for its own
shared slot.

## Evidence

**C source** — `third_party/lua/cosmo/lunix.c:2893-2906`:

```c
// unix.tiocgwinsz(fd:int)
//     ├─→ rows:int, cols:int
//     └─→ nil, error:str, errno:int
static int LuaUnixTiocgwinsz(lua_State *L) {
  struct winsize ws;
  int olderr = errno;
  if (!ioctl(luaL_checkinteger(L, 1), TIOCGWINSZ, &ws)) {
    lua_pushinteger(L, ws.ws_row);
    lua_pushinteger(L, ws.ws_col);
    return 2;
  } else {
    return LuaUnixSysretErrno(L, "tiocgwinsz", olderr);
  }
}
```

`LuaUnixSysretErrno` (`third_party/lua/cosmo/lunix.c:219-238`) always
returns exactly 3 values on failure — `nil`, a formatted error string,
and the raw errno integer — never 4. The C comment documents the
2-value/3-value split correctly; only the Lua-facing annotation
overclaims a fixed 4-slot shape.

**`tool/net/definitions.lua:7272-7277`** (current, wrong shape):

```
---@param fd integer
---@return integer|nil rows, integer cols cellular dimensions of pseudoteletypewriter display.
---@return string? error
---@return unix.Errno? errno
---@nodiscard
function unix.tiocgwinsz(fd) end
```

**Probe**, run from the cosmopolitan repo root after
`make -j$(nproc) o//tool/lua/lua` (a bad file descriptor is always
available, no fd-table exhaustion needed):

```
$ o//tool/lua/lua -e '
local unix = require "unix"
local rows, cols, err, errno = unix.tiocgwinsz(999999)
print("rows="..tostring(rows), "cols="..tostring(cols), "err="..tostring(err), "errno="..tostring(errno))
'
rows=nil	cols=tiocgwinsz: EBADF: Bad file descriptor	err=9	errno=nil
```

The variable named `cols` (declared plain `integer`, no `nil`, no
`string`) actually holds the error message string; the variable named
`err` (declared `string?`) actually holds the raw errno integer; the
variable named `errno` (declared `unix.Errno?`) is `nil` — nothing at
that position, because the C side never returns a 4th value.

**Cosmic-side spend** (`grep -rn 'unix\.tiocgwinsz' /home/user/cosmic/cosmic/`):

```
cosmic/tty.tl:121:  local rows, cols = unix.tiocgwinsz(fd)
cosmic/tty.tl:122:  if rows == nil then
cosmic/tty.tl:123:    -- On failure the binding returns (nil, err, errno): the error string
cosmic/tty.tl:124:    -- arrives in the second slot, where the columns would have been.
cosmic/tty.tl:125:    return nil, errstr(cols, "tiocgwinsz")
cosmic/tty.tl:126:  end
cosmic/tty.tl:127:  return {rows = rows, cols = cols}
```

`cosmic/tty.tl:123-124`'s comment states the exact bug this capture
fixes at the source, in cosmic's own words — tribal knowledge this
wrapper has to carry by hand today because `tool/net/definitions.lua`
doesn't say it. Note the wrapper also silently discards the real errno
(there is nowhere honest to read it from with the current annotation).

## Change

Rewrite `unix.tiocgwinsz`'s return annotation in
`tool/net/definitions.lua` to declare the real, shared-slot shape,
following the `unix.nanosleep` precedent
(`tool/net/definitions.lua:5876-5887`) exactly: a union type in the
slot that doubles, with prose stating the failure tuple explicitly.

Replace:

```
---@param fd integer
---@return integer|nil rows, integer cols cellular dimensions of pseudoteletypewriter display.
---@return string? error
---@return unix.Errno? errno
---@nodiscard
function unix.tiocgwinsz(fd) end
```

with:

```
---@param fd integer
---@return integer|nil rows
---@return integer|string cols cellular dimensions of pseudoteletypewriter
--- display on success, or the error string when the call failed —
--- failure returns exactly `nil, error, errno`, so the error lands in
--- this slot, not one of its own
---@return unix.Errno? errno the errno on failure; nil on success
---@nodiscard
function unix.tiocgwinsz(fd) end
```

No C code changes — `LuaUnixTiocgwinsz` already implements the fork's
standard `nil, error, errno` failure convention correctly; only the
doc comment overclaimed a shape the implementation never produces.

## Non-goals

- No change to `LuaUnixTiocgwinsz`'s C implementation or its return
  arity — the 2-success/3-failure shape stays; only the annotation
  changes.
- No change to any other binding, including `unix.pipe` and
  `unix.openpty`, which have the identical pattern and independent
  sibling captures.
- No change to `cosmic/tty.tl`'s `window_size` — it already handles the
  real shape correctly (modulo discarding the errno, which is a
  cosmic-side follow-up outside this capture's scope, not this one).

## Acceptance

- `tool/net/definitions.lua`'s `unix.tiocgwinsz` annotation states the
  `cols` slot's real dual nature (`integer|string`) and documents the
  exact failure tuple in prose, matching `unix.nanosleep`'s style.
- `make -j$(nproc) o//tool/lua/test` still passes (this is a comment-only
  change; no binding behavior changes).
- The EBADF probe above, re-run against the rebuilt binary, still
  returns byte-identical values — the fix documents reality, it does
  not change it.
