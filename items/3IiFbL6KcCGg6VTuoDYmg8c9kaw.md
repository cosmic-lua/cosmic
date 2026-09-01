## Goal

Close one exactness gap in `cosmo.unix`'s descriptor-I/O contract,
found while classifying the 17 nil-admitting bindings of the
descriptor/terminal census (item 95kn_ULxq, sibling to #276/#277):
`unix.pipe`'s declared return shape claims four fixed, distinctly-typed
slots, but its C implementation only ever returns 2 values (success)
or 3 (failure), so on failure the declared `writer` slot actually
carries the error string and the declared `error` slot actually
carries the errno integer.

**Correction 2026-09-01**: this item originally proposed fixing the
annotation to honestly declare the sharing (matching how
`unix.nanosleep` was annotated at the time this item was opened,
2026-09-01T05:12Z). Since then, this repo has settled — via
`unix.nanosleep` itself (`e028f15b2` #315), `unix.capget` (`8180f14b4`
#309), `unix.gmtime`/`unix.localtime` (#321), and `unix.getrlimit`
(#324) — that the real fix for this deviation class is to BUNDLE the
shared success values into one table, not merely re-annotate the
sharing as honest. `unix.pipe`'s fix below is updated to match that
now-settled convention; the evidence (C source, probes, cosmic-side
spend) is unchanged and still holds — only the `## Change` differs
from the original.

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

**Probe**, re-run yourself against current master after
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

**Cosmic-side spend** (`grep -rn 'unix\.pipe(' cosmic/` in a
cosmic-lua/cosmic checkout): every call site already defends against
exactly this shift by checking only the first return value before
touching the second:

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
`tool/net/definitions.lua` doesn't say it. All six cosmic-side call
sites destructure `reader, writer` positionally and MUST be rewritten
to read one table's fields once this capture lands — a separate,
blocked-on-this, cosmic-side follow-up (see Non-goals), matching the
pattern the `unix.getrlimit`/`unix.gmtime` captures already set.

## Change

Bundle the 2-value success pair into one table return
(`{reader=…, writer=…}|nil, string?, unix.Errno?`), matching
`unix.capget`'s caps table, `unix.nanosleep`'s remainder table, and
`unix.getrlimit`'s `Rlimit` table, so slot 2 always means error
regardless of branch:

1. `third_party/lua/cosmo/lunix.c`, `LuaUnixPipe`: on success, push
   one table with fields `reader` and `writer` instead of two
   positional integers:

   ```c
   static int LuaUnixPipe(lua_State *L) {
     int pipefd[2], olderr = errno;
     if (!pipe2(pipefd, luaL_optinteger(L, 1, 0))) {
       lua_newtable(L);
       lua_pushinteger(L, pipefd[0]); lua_setfield(L, -2, "reader");
       lua_pushinteger(L, pipefd[1]); lua_setfield(L, -2, "writer");
       return 1;
     } else {
       return LuaUnixSysretErrno(L, "pipe", olderr);
     }
   }
   ```

2. `tool/net/definitions.lua`, same commit — add a new class and
   rewrite `unix.pipe`'s return block:

   ```
   --- A pipe's two file descriptors, as returned by `pipe`.
   ---@class unix.Pipe
   ---@field reader integer the read end's file descriptor
   ---@field writer integer the write end's file descriptor
   ```

   ```
   ---@return unix.Pipe|nil
   ---@return string? error
   ---@return unix.Errno? errno
   ---@nodiscard
   function unix.pipe(flags) end
   ```

3. Add or extend a test (wherever this repo's existing `unix.pipe`
   coverage lives — check first) asserting the new table shape on
   success and the clean 3-value tuple on failure (an `ulimit`-forced
   EMFILE, matching the evidence probe above, or an equivalent
   deterministic failure trigger).

No change to `unix.pipe`'s failure path — it already implements the
fork's standard `nil, error, errno` convention correctly.

## Non-goals

- No change to any other binding, including `unix.tiocgwinsz` and
  `unix.openpty`, which have the identical pattern and independent
  sibling captures.
- No change to cosmic's `cosmic/fd.tl`/`cosmic/quicksand/*` call
  sites in this PR — this is a BEHAVIOR change (the success shape
  moves from two positional integers to one table), so every
  positional destructuring of `unix.pipe()`'s success values breaks
  the moment this lands. Retiring those six call sites' destructuring
  for `.reader`/`.writer` field access is a separate, cosmic-side
  consumption slice, blocked on this capture landing — do not fold it
  into this diff, and do not bump the cosmos pin here.

## Acceptance

- `make -j$(nproc) o//tool/lua/test` passes.
- `grep -c '^---@class unix.Pipe' tool/net/definitions.lua` reports 1.
- `grep -A3 '^function unix.pipe' tool/net/definitions.lua | grep -c
  'integer|nil reader, integer writer'` reports 0 (today 1 — confirms
  the old positional annotation is gone).
- Re-running the evidence probes above shows: success returns one
  table with `.reader`/`.writer` integer fields; the `ulimit`-forced
  EMFILE probe still returns a clean `nil, <string>, <errno>` tuple.
