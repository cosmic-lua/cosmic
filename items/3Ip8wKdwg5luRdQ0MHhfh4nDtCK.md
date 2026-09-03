## Change

Three `tool/net/definitions.lua` blocks declare a comma-separated success
list on the first `@return` line and then the error on its own line.
cosmic's generator splits that comma into slots, so the generated type
puts the error at slot 3 (mkstemp, wal_checkpoint) or slot 5 (Dir:read)
while the C pushes it at slot 2. Rewrite each block to one slot per
line, spelling slot 2 as a union of the success value and the error
string, exactly as `unix.tiocgwinsz` (definitions.lua:7469-7474) does
today and passes every gate with (no QALLOW entry names it):

- `definitions.lua:5281` (`unix.mkstemp`):
  `---@return integer|nil fd` / `---@return unix.MkstempPath|string path
  the created file's path on success, or the error string on failure`
  / `---@return unix.Errno? errno`.
- `definitions.lua:8054` (`unix.Dir:read`):
  `---@return string|nil name` / `---@return integer|string kind ... or
  the error string on failure` / `---@return integer|unix.Errno ino ...
  or the errno on failure` / `---@return integer off`. Keep the prose
  that end-of-stream is a bare `nil` (the `for` iterator relies on it).
- `definitions.lua:1052` (`lsqlite3.Database:wal_checkpoint`):
  `---@return integer|nil nlog` / `---@return integer|string nckpt ... or
  the error message on failure` / `---@return lsqlite3.ResultCode? errno`.

No whitespace around `|` and no dangling bar: checks 9 of
`tool/lua/test_definitions_coverage.lua` (#344/#346) refuse both.
Update the matching `lunix.c` shape comments (mkstemp `lunix.c:1805`,
Dir:read `lunix.c:4234`) only if their branch lines change meaning; the
count-level gate in `tool/lua/test_definitions_help.lua` needs neither.

## Evidence

The generator splits a top-level comma into another slot
(`sed -n 44,55p /home/user/cosmic/_types/gentype_return_test.tl`):

    ---@return integer seconds, integer nanos amount of CPU consumed in userspace.
    ...
    assert(dtl:match("cputime: function%(%): integer, integer\n"),

The C return order (`awk '/^static int LuaUnixMkstemp/,/^}/' lunix.c | grep -n 'lua_push\|return'`,
same for `LuaUnixDirRead` and `db_wal_checkpoint` in tool/net/lsqlite3.c):

    mkstemp:        push fd; newtable{path}; return 2   | failure: LuaUnixSysretErrno -> nil, err, errno
    Dir:read:       push name,kind,ino,off; return 4    | failure: LuaUnixSysretErrno -> nil, err, errno | EOF: nil
    wal_checkpoint: push nLog, nCkpt; return 2          | failure: pushnil; pushstring(errmsg); pushinteger(errcode); return 3

Current annotations (`sed -n '1052,1054p;5281,5283p;8054,8056p' tool/net/definitions.lua`):

    ---@return integer|nil nlog, integer nckpt
    ---@return string? errormsg
    ---@return integer|nil fd, unix.MkstempPath path
    ---@return string? error
    ---@return string|nil name, integer kind, integer ino, integer off
    ---@return string? error

Other blocks with the same comma-list-then-error shape
(awk over definitions.lua pairing a `---@return X|nil a, ...` line with a
following `---@return string? error|errormsg` line):

    601:  ---@return integer|nil rc, function? prev_func, any prev_udata || ---@return string? errormsg   (lsqlite3.config)
    2850: ---@return integer|nil status, table<string,string> headers, string body, string url || ...     (cosmo.Fetch)
    2874: ---@return integer|nil status, ... cosmo.StreamReader reader, string url || ...                   (cosmo.FetchStream)
    6603: ---@return integer|nil clientfd, uint32 ip, uint16 port || ---@return string? error               (unix.accept)
    6626 / 6639: ---@return uint32|nil ip, uint16 port || ---@return string? error      (getsockname / getpeername)
    6666: ---@return string|nil data, integer ip, integer port || ---@return string? error                  (unix.recvfrom)

`accept` and `Fetch`/`FetchStream` are the AGENTS.md-named multi-value
exception; `config`, `getsockname`, `getpeername`, `recvfrom` are not
named there and carry the identical slot drift. They are out of this
item's scope (file a sibling: same fix, or add them to the exception
paragraph) so this diff stays three blocks.

## Non-goals

The C shapes stay: this is an annotation fix. Bundling `fd`+`path` into
one table, or making `Dir:read` return a record, is a contract change
that needs its own item, a `definitions.lua` update in the same commit,
and a cosmic wrapper pass (`cosmic/fs/ops.tl:381`, `cosmic/fs/file.tl:94`,
`cosmic/embed/init.tl:375` destructure `fd, path` today).
