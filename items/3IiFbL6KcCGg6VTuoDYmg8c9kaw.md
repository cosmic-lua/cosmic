## Goal

Close one exactness gap in `cosmo.unix`'s descriptor-I/O contract,
found while classifying the 17 nil-admitting bindings of the
descriptor/terminal census (item 95kn_ULxq, sibling to #276/#277):
`unix.pipe`'s declared return shape claims four fixed, distinctly-typed
slots, but its C implementation only ever returns 2 values (success)
or 3 (failure), so on failure the declared `writer` slot actually
carries the error string and the declared `error` slot actually
carries the errno integer. Fix the annotation to say so, honestly, the
same way `unix.nanosleep` already does for its own shared slot.

## Evidence

**C source** — `third_party/lua/cosmo/lunix.c:1446-1458`:

```c
// unix.pipe([flags:int])
//     ├─→ reader:int, writer:int
//     └─→ nil, error:str, errno:int
static int LuaUnixPipe(lua_State *L) {
  int pipefd[2], olderr = errno;
  if (!pipe2(pipefd, luaL_optinteger(L, 1, 0))) {
    lua_pushinteger(L, pipefd[0]);
    lua_pushinteger(L, pipefd[1]);
    return 2;
  } else {
    return LuaUnixSysretErrno(L, "pipe", olderr);
  }
}
```

`LuaUnixSysretErrno` (`third_party/lua/cosmo/lunix.c:219-238`) always
returns exactly 3 values on failure — `nil`, a formatted error string,
and the raw errno integer — never 4. The C comment already documents
the 2-value/3-value split correctly; only the Lua-facing annotation
overclaims a fixed 4-slot shape.

**`tool/net/definitions.lua:4831-4880`** (current, wrong shape):

```
---@return integer|nil reader, integer writer
---@return string? error
---@return unix.Errno? errno
---@nodiscard
function unix.pipe(flags) end
```

**Probe**, run from the cosmopolitan repo root after
`make -j$(nproc) o//tool/lua/lua`:

```
$ o//tool/lua/lua -e '
local unix = require "unix"
local reader, writer, err, errno = unix.pipe()
print("success:", reader, writer, err, errno)
'
success:	3	4	nil	nil
```

```
$ (ulimit -n 20 && o//tool/lua/lua -e '
local unix = require "unix"
local fds = {}
for i = 1, 50 do
  local r, w, err, errno = unix.pipe()
  if not r then
    print("failed at i="..i, "reader="..tostring(r), "writer="..tostring(w),
          "err="..tostring(err), "errno="..tostring(errno))
    break
  end
  fds[#fds+1] = r; fds[#fds+1] = w
end
')
failed at i=9	reader=nil	writer=pipe: EMFILE: Too many open files	err=24	errno=nil
```

On failure, the variable a caller names `writer` (declared type plain
`integer`, no `nil`, no `string`) actually holds the error message
string, the variable named `err` (declared `string?`) actually holds
the raw errno integer, and the variable named `errno` (declared
`unix.Errno?`) is `nil` — nothing at that position, because the C side
never returns a 4th value.

**Cosmic-side spend** (`grep -rn 'unix\.pipe(' /home/user/cosmic/cosmic/`):
every call site already defends against exactly this shift by checking
only the first return value before touching the second:

```
cosmic/quicksand/proc.tl:166:  local r, w = unix.pipe()
cosmic/quicksand/proc.tl:167:  if not r then return nil, errno.format(w, "pipe") end
cosmic/quicksand/proxy.tl:117:  local r, w = unix.pipe()
cosmic/quicksand/proxy.tl:118:  if not r then return nil, errno.format(w, "pipe") end
cosmic/quicksand/init.tl:111:  local r, w = unix.pipe(unix.O_CLOEXEC)
cosmic/quicksand/init.tl:112:  if not r then return false end
cosmic/quicksand/box/run.tl:266:  local er, ew = unix.pipe(unix.O_CLOEXEC)
cosmic/quicksand/box/run.tl:267:  if not er then ...
cosmic/fd.tl:247:  local reader_fd, writer_fd = unix.pipe(flags)
cosmic/fd.tl:248:  if not reader_fd then
cosmic/fd.tl:249:    -- On failure the binding returns (nil, err, errno): the error string
cosmic/fd.tl:250:    -- arrives in the second slot, where the writer fd would have been.
cosmic/child/init.tl:243:    local r, w = unix.pipe(unix.O_CLOEXEC)
cosmic/child/init.tl:244:    if r == nil or w == nil then
```

`cosmic/fd.tl:249-250`'s comment states the exact bug this capture
fixes at the source, in cosmic's own words — tribal knowledge every one
of these call sites has to carry by hand today because
`tool/net/definitions.lua` doesn't say it.

## Change

Rewrite `unix.pipe`'s return annotation in
`tool/net/definitions.lua` to declare the real, shared-slot shape,
following the `unix.nanosleep` precedent
(`tool/net/definitions.lua:5876-5887`) exactly: a union type in the
slot that doubles, with prose stating the failure tuple explicitly.

Replace:

```
---@return integer|nil reader, integer writer
---@return string? error
---@return unix.Errno? errno
```

with:

```
---@return integer|nil reader
---@return integer|string writer the write fd on success, or the error
--- string when the call failed — failure returns exactly `nil, error,
--- errno`, so the error lands in this slot, not one of its own
---@return unix.Errno? errno the errno on failure; nil on success
```

No C code changes — `LuaUnixPipe` already implements the fork's
standard `nil, error, errno` failure convention correctly; only the
doc comment overclaimed a shape the implementation never produces.
Regenerating cosmic's Teal types from this file
(`bin/cosmic --make build`) after the fix is the acceptance check on
the cosmic side, but is not part of this capture — this capture is
scoped to the `tool/net/definitions.lua` line, in whilp/cosmopolitan.

## Non-goals

- No change to `LuaUnixPipe`'s C implementation or its return arity —
  the 2-success/3-failure shape stays; only the annotation changes.
- No change to any other binding, including `unix.tiocgwinsz` and
  `unix.openpty`, which have the identical pattern and independent
  sibling captures.
- No change to cosmic's `cosmic/fd.tl`/`cosmic/quicksand/*` call
  sites — they already handle the real shape correctly; nothing there
  is broken by this doc fix.

## Acceptance

- `tool/net/definitions.lua`'s `unix.pipe` annotation states the
  `writer` slot's real dual nature (`integer|string`) and documents
  the exact failure tuple in prose, matching `unix.nanosleep`'s style.
- `make -j$(nproc) o//tool/lua/test` still passes (this is a comment-only
  change; no binding behavior changes).
- A probe run against the rebuilt binary
  (`o//tool/lua/lua -e 'print(require("unix").pipe())'` on success, and
  the `ulimit -n 20` EMFILE probe above on failure) still returns
  byte-identical values to those recorded in this capture's evidence —
  the fix documents reality, it does not change it.
