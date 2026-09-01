## Goal

Close one exactness gap in `cosmo.unix`'s descriptor-I/O contract,
found while classifying the 17 nil-admitting bindings of the
descriptor/terminal census (item 95kn_ULxq, sibling to #276/#277):
`unix.openpty`'s declared return shape claims five fixed,
distinctly-typed slots, but its C implementation only ever returns 3
values (success) or 3 (failure), so on failure the declared `sfd` slot
actually carries the error string and the declared `name` slot
actually carries the errno integer — the worst instance of this
pattern in the slice, shifting two slots instead of one. Fix the
annotation to say so, honestly, the same way `unix.nanosleep` already
does for its own shared slot.

## Evidence

**C source** — `third_party/lua/cosmo/lunix.c:1460-1476`:

```c
// unix.openpty()
//     ├─→ mfd:int, sfd:int, name:str
//     └─→ nil, error:str, errno:int
static int LuaUnixOpenpty(lua_State *L) {
  int mfd, sfd, olderr = errno;
  // openpty() strcpy()s the subordinate path out of a char[16] field, so
  // the name it writes is at most 16 bytes including the NUL.
  char name[32];
  if (!openpty(&mfd, &sfd, name, 0, 0)) {
    lua_pushinteger(L, mfd);
    lua_pushinteger(L, sfd);
    lua_pushstring(L, name);
    return 3;
  } else {
    return LuaUnixSysretErrno(L, "openpty", olderr);
  }
}
```

`LuaUnixSysretErrno` (`third_party/lua/cosmo/lunix.c:219-238`) always
returns exactly 3 values on failure — `nil`, a formatted error string,
and the raw errno integer — never 5. The C comment documents the
3-value/3-value split correctly; only the Lua-facing annotation
overclaims a fixed 5-slot shape.

**`tool/net/definitions.lua:6373-6378`** (current, wrong shape):

```
---@return integer|nil mfd, integer sfd, string name
---@return string? error
---@return unix.Errno? errno
---@nodiscard
function unix.openpty() end
```

**Probe**, run from the cosmopolitan repo root after
`make -j$(nproc) o//tool/lua/lua` (lowering the fd-table limit forces
`EMFILE`, a real, correct-caller-reachable failure):

```
$ (ulimit -n 15 && o//tool/lua/lua -e '
local unix = require "unix"
local fds = {}
for i = 1, 30 do
  local mfd, sfd, name, e, en = unix.openpty()
  if not mfd then
    print("failed at i="..i, "mfd="..tostring(mfd), "sfd="..tostring(sfd),
          "name="..tostring(name), "e="..tostring(e), "en="..tostring(en))
    break
  end
  fds[#fds+1] = mfd; fds[#fds+1] = sfd
end
')
failed at i=7	mfd=nil	sfd=openpty: EMFILE: Too many open files	name=24	e=nil	en=nil
```

The variable named `sfd` (declared plain `integer`, no `nil`, no
`string`) actually holds the error message string; the variable named
`name` (declared plain `string`, no numeric union) actually holds the
raw errno integer; the variables named `e` and `en` (declared
`string?`/`unix.Errno?`) are both `nil` — nothing at those positions,
because the C side never returns a 5th or 4th value on failure.

**Cosmic-side spend** (`grep -rn 'unix\.openpty' /home/user/cosmic/cosmic/`):

```
cosmic/tty.tl:82:  local mfd, sfd, name = unix.openpty()
cosmic/tty.tl:83:  if not mfd then
cosmic/tty.tl:84:    -- on failure the binding returns (nil, err, errno), so the second
cosmic/tty.tl:85:    -- slot carries the error string rather than a descriptor
cosmic/tty.tl:86:    return nil, errstr(sfd, "openpty")
cosmic/tty.tl:87:  end
cosmic/tty.tl:88:  return {manager = mfd, subordinate = sfd, name = name}
```

`cosmic/tty.tl:84-85`'s comment states the exact bug this capture fixes
at the source, in cosmic's own words — tribal knowledge this wrapper
has to carry by hand today because `tool/net/definitions.lua` doesn't
say it. The wrapper never reads `name`/the true errno at all on this
path (there is nowhere honest to read it from with the current
annotation).

## Change

Rewrite `unix.openpty`'s return annotation in
`tool/net/definitions.lua` to declare the real, shared-slot shape,
following the `unix.nanosleep` precedent
(`tool/net/definitions.lua:5876-5887`) exactly: union types in the two
slots that double, with prose stating the failure tuple explicitly.

Replace:

```
---@return integer|nil mfd, integer sfd, string name
---@return string? error
---@return unix.Errno? errno
---@nodiscard
function unix.openpty() end
```

with:

```
---@return integer|nil mfd
---@return integer|string sfd the subordinate fd on success, or the
--- error string when the call failed — failure returns exactly
--- `nil, error, errno`, so the error lands in this slot, not one of
--- its own
---@return string|integer|nil name the subordinate's filesystem path on
--- success, or the errno on failure; nil is never actually returned
--- here but kept for symmetry with the other two slots
---@nodiscard
function unix.openpty() end
```

No C code changes — `LuaUnixOpenpty` already implements the fork's
standard `nil, error, errno` failure convention correctly; only the
doc comment overclaimed a shape the implementation never produces.

## Non-goals

- No change to `LuaUnixOpenpty`'s C implementation or its return
  arity — the 3-success/3-failure shape stays; only the annotation
  changes.
- No change to any other binding, including `unix.pipe` and
  `unix.tiocgwinsz`, which have the identical pattern and independent
  sibling captures.
- No change to `cosmic/tty.tl`'s `open_pty` — it already handles the
  real shape correctly; nothing there is broken by this doc fix.

## Acceptance

- `tool/net/definitions.lua`'s `unix.openpty` annotation states the
  `sfd`/`name` slots' real dual nature and documents the exact failure
  tuple in prose, matching `unix.nanosleep`'s style.
- `make -j$(nproc) o//tool/lua/test` still passes (this is a comment-only
  change; no binding behavior changes).
- The EMFILE probe above, re-run against the rebuilt binary, still
  returns byte-identical values — the fix documents reality, it does
  not change it.
