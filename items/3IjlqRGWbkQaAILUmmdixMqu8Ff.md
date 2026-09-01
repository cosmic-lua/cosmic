## Goal

G3, via the cosmo-contracts container: close one of the eleven
`unix` stat/directory-stream/temp-fd bindings' tuple-shape deviations
from the settled `T|nil, err string, errno?` archetype
(`unix.nanosleep`, fixed by #315). `unix.Dir:read()` currently declares
no error slot at all, so a genuine `readdir()` failure is
indistinguishable from ordinary end-of-directory.

## Evidence

`third_party/lua/cosmo/lunix.c:4211-4228`:

```c
// unix.Dir:read()
//     ├─→ name:str, kind:int, ino:int, off:int
//     └─→ nil
static int LuaUnixDirRead(lua_State *L) {
  struct dirent *ent;
  if ((ent = readdir(GetDirOrDie(L)))) {
    lua_pushlstring(L, ent->d_name, strnlen(ent->d_name, sizeof(ent->d_name)));
    lua_pushinteger(L, ent->d_type);
    lua_pushinteger(L, ent->d_ino);
    lua_pushinteger(L, ent->d_off);
    return 4;
  } else {
    // end of directory stream condition
    // we make the assumption getdents() won't fail
    lua_pushnil(L);
    return 1;
  }
}
```

`tool/net/definitions.lua:7896-7911` declares the return as a single
line with no error slot:

```
---@return string|nil name, integer kind, integer ino, integer off
---@nodiscard
function unix.Dir:read() end
```

`libc/stdio/dirstream.c:602-613`, the underlying `readdir()`'s own doc
comment, states the intended disambiguation technique explicitly:

```
/**
 * Reads next entry from directory stream.
 * ...
 * @return next entry or NULL on end or error, which can be
 *     differentiated by setting errno to 0 beforehand
 * @threadunsafe
 */
```

`LuaUnixDirRead` does not zero `errno` before calling `readdir()` and
does not inspect it after — the C comment's own acknowledged
"assumption" is exactly the gap.

Probe (from the cosmopolitan repo root, against `o//tool/lua/lua`
built by `make -j$(nproc) o//tool/lua/lua`), demonstrating the two
conditions are indistinguishable today:

```
$ o//tool/lua/lua -e 'local u=require("unix");local d=u.opendir("/tmp");while d:read() do end;print(d:read())'
nil
$ o//tool/lua/lua -e 'local u=require("unix");local d=u.opendir(".");local fd=d:fd();u.close(fd);print(d:read())'
nil
```

The second transcript invalidates the directory stream's underlying fd
out from under it (a real, if unusual, runtime condition — e.g. a
concurrent close via a duplicated fd, or a future genuine `readdir()`
I/O error) before calling `read()`; `readdir()` fails, but the binding
returns the same bare `nil` as ordinary end-of-directory, with no way
for a caller to tell the two apart.

`cosmic/fs/dir.tl:25-29` (`wrap_dir`'s `read` method) inherits the
ambiguity one layer up without adding disambiguation:

```
read = function(_self: Dir): string | nil, integer
  if is_closed then return nil end
  local name, kind = raw:read()
  return name, kind
end,
```

## Change

Zero `errno` before calling `readdir()` in `LuaUnixDirRead` and check
it after: on a `NULL` return, if `errno` is nonzero, push `nil,
strerror(errno), errno` (the standard `LuaUnixSysretErrno`-style
tuple, matching the archetype `T|nil, err string, errno?`); if `errno`
is still zero, push a bare `nil` for legitimate end-of-directory, as
today. Update `tool/net/definitions.lua`'s declared return to add the
error and errno slots on the failure branch (mirroring the shape
`unix.nanosleep`'s fix (#315) and `unix.wait`'s recorded deviation use),
keeping the four-value success shape unchanged. This is a C-boundary
contract change (per this repo's AGENTS.md: "a deliberate contract
change needs a matching `definitions.lua` update here and a type regen
+ wrapper fix on the cosmic side, landed as its own change, never
inside an optimization") — land it here first, then land the matching
`cosmic/fs/dir.tl` `wrap_dir.read` update (surfacing the new error
slot, or documenting why it is deliberately still swallowed) as a
follow-up on the cosmic side, never in the same commit.

## Non-goals

- No change to `unix.Dir:read()`'s success-path four-value shape
  (`name, kind, ino, off`) — only the failure branch gains slots.
- No change to any other binding in this slice (`stat`, `fstat`,
  `statfs`, `fstatfs`, `opendir`, `fdopendir`, `Dir:close`, `Dir:fd`,
  `Dir:tell`, `tmpfd`) — all ten are tuple-exact already, per the
  parent census item's summary table.
- No change to the Windows (`readdir_nt`) or zip (`readdir_zipos`)
  branches' internal logic beyond whatever `errno` discipline the fix
  requires them to also observe — this item is about the Lua-boundary
  tuple, not a semantic change to directory iteration itself.
- No cosmic-side wrapper change in this item — that is a separate,
  dependent follow-up (see Change).

## Acceptance

- `LuaUnixDirRead` zeroes `errno` before `readdir()` and branches on it
  after, per the `readdir()` doc comment's own stated technique.
- `tool/net/definitions.lua`'s `unix.Dir:read` declares the failure
  branch as `nil, string, unix.Errno?` (or equivalent), leaving the
  success branch's four values unchanged.
- A new test in `tool/lua/test_unix.lua` (or wherever this repo's
  `Dir:read` tests live) demonstrates: (a) ordinary end-of-directory
  still yields a bare `nil` with no error tuple; (b) a directory stream
  whose underlying fd is closed out from under it yields `nil, <a
  string>, <a non-nil errno>` on the next `read()`.
- `make -j$(nproc) o//tool/lua/test` passes, including the annotation
  coverage ratchet.

## Enablement

none needed — the fix is self-contained in `LuaUnixDirRead` and its
`definitions.lua` declaration; the cosmic-side wrapper update is an
explicit, separate follow-up per Non-goals.
