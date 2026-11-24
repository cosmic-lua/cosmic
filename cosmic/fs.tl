--- Files and directories.
---
--- Every call goes through the syscall table, so one call behaves the
--- same on Linux and on macOS. [`Fs.read`], [`Fs.stat`], [`Fs.list`],
--- [`Fs.mkdtemp`], [`Fs.absolute`], [`Fs.readlink`], [`Fs.open_read`],
--- [`Fs.open_write`], [`Fs.take`], [`Fs.create`], [`Fs.walk`],
--- [`Fs.walk_following`], [`Fs.scratch`] and [`Fs.relative`] return
--- `(T) | (nil, Failure)`: the value alone, or nil and a [`Failure`]
--- that names the path (none for `take`, which reads a descriptor) and
--- the errno (0 for `relative`, which reads nothing). Other fallible calls
--- that produce a value still return `T | nil, string`: a value and `""`
--- on success, or nil and an error. A predicate uses the same contract, with false
--- as a valid result. [`Fs.write`], [`Fs.mkdirs`], [`Fs.remove`],
--- [`Fs.remove_tree`], [`Fs.rename`], [`Fs.chmod`], [`Fs.symlink`],
--- [`Fs.set_mtime`], [`Fs.append`], [`Fs.copy_tree`], [`Fs.put`],
--- [`Fs.fsync`] and [`Fs.close`] only have an effect, and return
--- `(true) | (false, Failure)`; one on a descriptor names no path.
---
--- A descriptor from [`Fs.open_read`] or [`Fs.open_write`] is a plain
--- integer, closed with [`Fs.close`], so a `<close>` variable cannot hold
--- it. One holds a value whose type has a [`__close`] metamethod, written
--- `local h <close> = assert(Child.start(argv, { timeout_ns = Child.FOREVER }))`: `assert` narrows the
--- `T | nil` an opener returns, which `<close>` refuses, to `T`.
---
--- `basename`, `dirname`, `within` and `relative` work on a path's
--- text alone and read nothing. The first three cannot fail, so each
--- returns a plain value. `relative` returns nil and a Failure, with
--- errno 0, when the path is not within the directory.
---
--- The syscall table itself is [`cosmic.sys`]. A call this module does not
--- wrap -- `lstat`, `chdir`, `pread` and others -- is there, and
--- `cosmic docs cosmic.sys` lists every one.

local Env = require("cosmic.env")
local Failure = require("cosmic.failure")
local sys = require("cosmic.sys")

--- A private directory made by [`Fs.scratch`], removed with everything
--- in it when a `<close>` variable holding it ends its scope.
local class Scratch
  --- The directory, a child of the one [`Fs.scratch`] was given.
  path: string
  --- A descriptor of the `owner` file inside `path`, which is on the
  --- directory's own filesystem and locked for as long as the
  --- scratch directory is open. Leave the file alone, and neither
  --- read nor close the descriptor.
  mut owner: integer

  function __close(self)
    -- A second close would close whatever descriptor reused `owner`.
    if self.owner < 0 then return end
    local _, _ = sys.remove_tree(self.path)
    local _, _ = sys.close(self.owner)
    self.owner = -1
  end
end

local record Fs
  --- What a path is and what it holds.
  Stat: sys.Stat

  --- What a path is, as a [`Stat`]'s `kind` and [`Fs.walk`]'s `skip`
  --- name it: [`sys.Kind`]'s members. Comparing a `Stat`'s `kind`, or a
  --- `skip`'s third parameter, with a name outside them (`"directory"`)
  --- is a compile error, the parameter left untyped or declared
  --- [`Fs.Kind`], since a function literal's untyped parameter is the
  --- type its callee declares.
  type Kind = sys.Kind

  --- How [`Fs.walk`] walks.
  record WalkOptions
    --- Take each link for what it leads to, as `find -L root -type f`
    --- lists them: a link to a file is listed as a file, under the
    --- link's own path, and a link to a directory is walked into. A
    --- link that leads nowhere (or to a device, a socket or a pipe) is
    --- not listed. A directory already being walked, reached again
    --- through a link (`loop -> .`), is not walked a second time, so a
    --- loop ends the walk of that branch rather than failing it. As with
    --- `find -L`, a file reached along several paths (a diamond of
    --- links) is listed once per path, and a link to a directory above
    --- the root is walked in full, but for the directories the walk is
    --- already inside. `skip` is asked before a link is followed, so it
    --- is told `"link"` and may refuse one. Each directory, and each
    --- link, is stat'd. Default false.
    follow?: boolean
    --- Asked of each entry (its relative path, its bare name, its
    --- [`Fs.Kind`]); true leaves it out, and a directory's whole tree.
    skip?: function(string, string, Fs.Kind): boolean
  end

  --- What [`Fs.status`] finds at a path: whether anything is there,
  --- whether it is a directory, and its [`Stat`] when it is there. A
  --- missing path is a Status, not a failure.
  record Status
    --- Whether anything is at the path.
    exists: boolean
    --- Whether a directory is at the path.
    is_dir: boolean
    --- What [`Fs.stat`] answers for the path, there only where it exists.
    stat?: sys.Stat
  end

  --- A file at a path being written through a temporary neighbor and a
  --- rename, as [`Fs.create`] returns it: the calls of a
  --- [`cosmic.stream`] Writer (`write`, `close` and `abort`), answering
  --- a [`Failure`], and `sync`; [`Stream.create`] offers it as a Writer.
  --- Every failure names the path, never the temporary file, and is
  --- sticky.
  interface Staged
    --- Appends `data`: false and a [`Failure`] when it cannot all be
    --- written.
    write: function(Staged, string): (true) | (false, Failure)
    --- Flushes what was written to storage, so that the rename `close`
    --- makes cannot reach it before the data does.
    sync: function(Staged): (true) | (false, Failure)
    --- Renames the file onto its path: false and a [`Failure`] when a
    --- write failed, or the rename or the closing of the file does.
    --- Safe to call more than once; after `abort` it renames nothing
    --- and answers true.
    close: function(Staged): (true) | (false, Failure)
    --- Removes the temporary file and leaves the path as it was. It
    --- cannot fail, and is safe to call more than once.
    abort: function(Staged)
  end

  --- What [`Fs.cache_dir`], [`Fs.program_cache_dir`] and
  --- [`Fs.data_dir`] read.
  record CacheOptions
    --- The variables to read (`XDG_CACHE_HOME` or `XDG_DATA_HOME`, and
    --- `HOME`), by name; the process's own when nil.
    environment?: {string:string}
    --- Whether to make and check the directory; true when nil. False
    --- answers the name alone.
    make?: boolean
  end

  type Scratch = Scratch

  --- The descriptor of standard input, 0: what [`Fs.take`] reads from.
  stdin: integer
  --- The descriptor of standard output, 1: what [`Fs.put`] writes to.
  stdout: integer
  --- The descriptor of standard error, 2: what [`Fs.put`] writes to.
  stderr: integer
end

local chunk_size = 1 << 16

-- TODO: read through Stream.read_all, and copy_bytes through Stream.copy,
-- so that read-to-end is one loop and the write loop below is
-- Stream.to_fd's, once cosmic.fs may require cosmic.stream: cosmic.fs
-- is a harness module (build/harness_epoch.tl's `library` lists it for
-- the worker's reads, binds and report), the harness reaches no other
-- cosmic.* module than `library` names, and cosmic.stream, with the
-- cosmic.hash, cosmic.poll and cosmic.time it requires, is none of
-- them; cosmic.stream also requires cosmic.fs today, a cycle its
-- reads and writes through sys would end.
--- Reads the whole of a file as bytes, loading it in one call. Use this for
--- the common io.open/io.read or io.lines case when streaming and Lua file
--- handles are unnecessary. It answers the bytes alone, or nil and a
--- [`Failure`] that names `path` and the errno that says why
--- (`why.errno == sys.ENOENT` for a file that is not there).
function Fs.read(path: string): (string) | (nil, Failure)
  local fd, _, errno = sys.open(path, sys.O_RDONLY)
  if fd == nil then
    return nil, Failure.system(errno, path)
  end
  -- A regular file says how big it is, so its bytes come in one read
  -- into one string of that size; chunks follow only for whatever it
  -- holds past that, or for a file that does not say (a pipe, /proc).
  local st, _ = sys.fstat(fd)
  local ask = chunk_size
  if st ~= nil and st.kind == "file" and st.size > chunk_size then
    ask = st.size
  end
  local parts: mut {string} = {}
  while true do
    local chunk, _, read_errno = sys.read(fd, ask)
    if chunk == nil then
      local _, _ = sys.close(fd)
      return nil, Failure.system(read_errno, path)
    end
    if #chunk == 0 then
      break
    end
    parts[#parts + 1] = chunk
    ask = chunk_size
  end
  local _, _ = sys.close(fd)
  return table.concat(parts)
end

--- The failure of a call that answered `why` and `errno`: the errno's
--- own words where one is set, `why` where none is (0).
local function failure_of(errno: integer, why: string, path?: string): Failure
  if errno ~= 0 then return Failure.system(errno, path) end
  return Failure.new(why, path)
end

--- Writes all of `data` to `fd`; a write that moves nothing fails
--- "`blame`write made no progress", `blame` being "fs: " where no caller
--- names the file.
--- The errno of a failed write is the third value, 0 where no system
--- call failed.
local function write_all(fd: integer, data: string, blame: string): (true) | (false, string, integer)
  local at = 1
  while at <= #data do
    -- The whole string the first time, rather than a copy of it.
    local rest = if at == 1 then data else data:sub(at) end
    local put, trouble, errno = sys.write(fd, rest)
    if put == nil then
      return false, trouble, errno
    end
    if put == 0 then
      return false, blame .. "write made no progress", 0
    end
    at = at + put
  end
  return true
end

-- How an object of this module is made: see the note on objects in
-- cosmic/stream.tl.

--- Remembers `why` and `errno` as the file's Failure, naming the caller's path: a
--- failure is sticky, and never names the temporary file, which the
--- caller never chose and which is gone when it reads the message.
local function failing(self: StagedFile, why: string, errno: integer): Failure
  local failure = failure_of(errno, why, self.path)
  self.failure = failure
  return failure
end

--- What [`Fs.create`] returns: its methods live on the record's own
--- table, so creating a file costs a table, not four closures.
local class StagedFile is Fs.Staged
  path: string
  temporary: sys.TemporaryFile
  -- nil until a call fails.
  mut failure?: Failure
  mut closed: boolean

  function write(self, data: string): (true) | (false, Failure)
    if self.closed then return false, Failure.new("the file is closed", self.path) end
    local failed = self.failure
    if failed ~= nil then return false, failed end
    local ok, why, errno = write_all(self.temporary.fd, data, "")
    if not ok then return false, failing(self, why, errno) end
    return true
  end

  function sync(self): (true) | (false, Failure)
    if self.closed then return false, Failure.new("the file is closed", self.path) end
    local failed = self.failure
    if failed ~= nil then return false, failed end
    local ok, why, errno = sys.fsync(self.temporary.fd)
    if not ok then return false, failing(self, why, errno) end
    return true
  end

  function abort(self)
    if self.closed then return end
    self.closed = true
    local _, _ = sys.close(self.temporary.fd)
    local _, _ = sys.unlink(self.temporary.path)
  end

  function close(self): (true) | (false, Failure)
    local temporary = self.temporary
    local failed = self.failure
    if self.closed then
      if failed ~= nil then return false, failed end
      return true
    end
    self.closed = true
    if failed ~= nil then
      local _, _ = sys.close(temporary.fd)
      local _, _ = sys.unlink(temporary.path)
      return false, failed
    end
    local closed, close_trouble, close_errno = sys.close(temporary.fd)
    if not closed then
      local _, _ = sys.unlink(temporary.path)
      return false, failing(self, close_trouble, close_errno)
    end
    local moved, why, errno = sys.rename(temporary.path, self.path)
    if not moved then
      local _, _ = sys.unlink(temporary.path)
      return false, failing(self, why, errno)
    end
    return true
  end
end

--- Whether a file of `kind` takes bytes where it is, so that a rename
--- onto it would put a regular file in its place: a device or a FIFO.
local function in_place_kind(kind: sys.Kind): boolean
  return kind == "char" or kind == "block" or kind == "fifo"
end

--- Whether `path` names one of the process's own descriptors through a
--- link the system keeps (`/dev/stdout`, `/dev/stderr`, `/dev/fd/1`,
--- `/proc/self/fd/1`): a name no one plants, which [`Fs.output`] follows.
local function descriptor_name(path: string): boolean
  return path == "/dev/stdout" or path == "/dev/stderr" or path:match("^/dev/fd/%d+$") ~= nil or
    path:match("^/proc/self/fd/%d+$") ~= nil
end

--- What a refusal calls a file of `kind`, as [`sys.lstat`] names it.
local KIND_WORDS <const>: {string:string} = {
  char = "character device", block = "block device", fifo = "FIFO", socket = "socket",
}

--- Why [`Fs.create`] refuses `path`: it names a device, a FIFO or a
--- socket, or a link to one, which the rename onto it would replace with
--- a regular file (the root's `/dev/null`, say). Nil for a regular file,
--- a directory, a link to either, or nothing, which take the rename (a
--- directory fails it).
local function replaces_special(path: string): Failure?
  local st, _ = sys.lstat(path)
  if st == nil or st.kind == "file" or st.kind == "dir" then return nil end
  if st.kind == "link" and descriptor_name(path) then
    return Failure.new("one of the process's own descriptors, which writing a file here would " ..
        "replace with a regular file", path)
  end
  if st.kind == "link" then
    local target, _ = sys.stat(path)
    if target == nil or target.kind == "file" or target.kind == "dir" then return nil end
    local words = KIND_WORDS[target.kind] or target.kind
    return Failure.new("a link to a " .. words .. ", which writing a file here would replace " ..
        "with a regular file; name the " .. words .. " itself", path)
  end
  local words = KIND_WORDS[st.kind]
  if words == nil then return nil end
  return Failure.new("a " .. words .. ", which writing a file here would replace with a regular file", path)
end

--- The file [`Fs.create`] starts, as its own class, so [`Fs.write`] reads
--- its failure as a value.
local function staged_file(path: string, mode?: integer): (StagedFile) | (nil, Failure)
  local refused = replaces_special(path)
  if refused ~= nil then return nil, refused end
  local temporary, why, errno = sys.open_temporary(path, mode or 0x1a4)
  if temporary == nil then return nil, failure_of(errno, why, path) end
  local staged: StagedFile = {
    path = path, temporary = temporary, failure = nil, closed = false,
  }
  return staged
end

--- Starts writing a file at `path`: bytes go to a new temporary neighbor,
--- created exclusively (so two writers never share one and a planted
--- symlink is never followed), which `close` renames onto `path`, so a
--- reader of `path` sees the old contents or the new, never a mix. A
--- failure, or `abort`, leaves `path` as it was and removes the
--- temporary file. The file is always a new one, so it gets `mode`
--- (default 0644, less the umask) and never keeps an existing file's
--- mode. Nothing is synced unless `sync` is called, so a crash can
--- still lose the write. It answers nil and a Failure naming `path`
--- when the temporary file cannot be made, or when `path` names a
--- device, a FIFO or a socket, a link to one, or one of the process's own
--- descriptors (`/dev/stdout`), which the rename would replace with a
--- regular file: [`Fs.output`] writes those in place, for an output a
--- person names. [`Stream.create`] is this, as a [`cosmic.stream`]
--- Writer.
function Fs.create(path: string, mode?: integer): (Fs.Staged) | (nil, Failure)
  local staged, why = staged_file(path, mode)
  if staged == nil then return nil, why end
  return staged
end

--- Writes `data` to `path` through a temporary file and a rename, in
--- place of io.open/io.write: [`Fs.create`], one write and the close. A
--- reader sees the old contents or the new, never a mix, and a
--- failure before the rename leaves the old file. The file is always a
--- new one, so it gets `mode` (default 0644, less the umask) and never
--- keeps an existing file's mode. Nothing is synced, so a crash can
--- still lose the write. A device, FIFO or socket at `path` is refused,
--- as [`Fs.create`] says. Answers true, or false and a [`Failure`] that
--- names `path` and the errno.
function Fs.write(path: string, data: string, mode?: integer): (true) | (false, Failure)
  local file, trouble = staged_file(path, mode)
  if file == nil then return false, trouble end
  local wrote, write_failure = file:write(data)
  if not wrote then
    file:abort()
    return false, write_failure
  end
  return file:close()
end

--- What [`Fs.output`] returns for a path written in place (a device, a
--- FIFO, `/dev/stdout`): the calls of [`Fs.Staged`] over a descriptor,
--- with no temporary file, so `abort` only closes it.
local class InPlaceFile is Fs.Staged
  path: string
  fd: integer
  -- nil until a call fails.
  mut failure?: Failure
  mut closed: boolean

  function write(self, data: string): (true) | (false, Failure)
    if self.closed then return false, Failure.new("the file is closed", self.path) end
    local failed = self.failure
    if failed ~= nil then return false, failed end
    local ok, why, errno = write_all(self.fd, data, "")
    if not ok then
      local failure = failure_of(errno, why, self.path)
      self.failure = failure
      return false, failure
    end
    return true
  end

  -- A character device or a FIFO has no storage to flush, and fsync on
  -- one fails EINVAL (Linux) or ENOTSUP: no failure of the write.
  function sync(self): (true) | (false, Failure)
    if self.closed then return false, Failure.new("the file is closed", self.path) end
    local failed = self.failure
    if failed ~= nil then return false, failed end
    local ok, why, errno = sys.fsync(self.fd)
    if ok or errno == sys.EINVAL or errno == sys.EOPNOTSUPP then return true end
    local failure = failure_of(errno, why, self.path)
    self.failure = failure
    return false, failure
  end

  function abort(self)
    if self.closed then return end
    self.closed = true
    local _, _ = sys.close(self.fd)
  end

  function close(self): (true) | (false, Failure)
    local failed = self.failure
    if self.closed then
      if failed ~= nil then return false, failed end
      return true
    end
    self.closed = true
    local closed, why, errno = sys.close(self.fd)
    if failed ~= nil then return false, failed end
    if not closed then
      local failure = failure_of(errno, why, self.path)
      self.failure = failure
      return false, failure
    end
    return true
  end
end

--- Whether [`Fs.output`] writes `path` in place: a device or a FIFO
--- itself (never a link to one, which may be planted), or one of the
--- process's own descriptors by its system name (`/dev/stdout`,
--- `/dev/stderr`, `/dev/fd/<n>`, `/proc/self/fd/<n>`). False where
--- nothing is there or anything else is; nil and a [`Failure`] where
--- `path` cannot be looked at.
function Fs.in_place(path: string): (boolean) | (nil, Failure)
  local st, why, errno = sys.lstat(path)
  if st == nil then
    if errno == sys.ENOENT then return false end
    return nil, failure_of(errno, why, path)
  end
  return in_place_kind(st.kind) or (st.kind == "link" and descriptor_name(path))
end

--- Starts writing an output a person named, such as a verb's `-o`: as
--- [`Fs.create`] does, but a device, a FIFO or one of the process's own
--- descriptors ([`Fs.in_place`]) is written in place, as a shell's `>`
--- writes it, so `-o /dev/null` discards and `-o /dev/stdout` prints.
--- There is then no temporary file: `mode` is not used, nothing written
--- can be taken back, and `abort` only closes the descriptor. A FIFO's
--- open waits for a reader. A descriptor that is a regular file is
--- appended to, so a shell's `>>` holds. Nil and a [`Failure`] naming
--- `path` when it cannot be opened.
function Fs.output(path: string, mode?: integer): (Fs.Staged) | (nil, Failure)
  local in_place, trouble = Fs.in_place(path)
  if in_place == nil then return nil, trouble end
  if not in_place then return Fs.create(path, mode) end
  local named = descriptor_name(path)
  -- A device itself is opened without following a link swapped in
  -- since the look; a descriptor's name is the system's link, followed.
  local flags = sys.O_WRONLY | sys.O_NOCTTY
  if not named then flags = flags | sys.O_NOFOLLOW end
  local fd, why, errno = sys.open(path, flags)
  if fd == nil then return nil, failure_of(errno, why, path) end
  local st, stat_why, stat_errno = sys.fstat(fd)
  local fits = st ~= nil and (in_place_kind(st.kind) or (named and st.kind == "file"))
  if st == nil or not fits then
    local _, _ = sys.close(fd)
    if st == nil then return nil, failure_of(stat_errno, stat_why, path) end
    return nil, Failure.new("a " .. (KIND_WORDS[st.kind] or st.kind) .. ", not a device or a FIFO", path)
  end
  if st.kind == "file" then
    -- Reopened through its name, the descriptor's offset and append mode
    -- are lost: appending keeps what a `>>` redirection kept.
    local _, _ = sys.close(fd)
    fd, why, errno = sys.open(path, sys.O_WRONLY | sys.O_NOCTTY | sys.O_APPEND)
    if fd == nil then return nil, failure_of(errno, why, path) end
  end
  local file: InPlaceFile = { path = path, fd = fd, failure = nil, closed = false }
  return file
end

--- Writes `data` to an output a person named ([`Fs.output`]): in place
--- for a device, a FIFO or one of the process's own descriptors, through
--- a temporary file and a rename, as [`Fs.write`], for anything else.
function Fs.write_output(path: string, data: string, mode?: integer): (true) | (false, Failure)
  local file, trouble = Fs.output(path, mode)
  if file == nil then return false, trouble end
  local wrote, write_failure = file:write(data)
  if not wrote then
    file:abort()
    return false, write_failure
  end
  return file:close()
end

local class AppendFile
  mut fd: integer

  function __close(self)
    if self.fd < 0 then return end
    local fd = self.fd
    self.fd = -1
    local _, _ = sys.close(fd)
  end
end

--- Appends `data` in place, creating `path` if missing, with `mode`
--- (default 0644, less the umask). An existing file keeps its inode and
--- mode, and a symlink is followed. Empty data still creates a missing
--- file. Each write starts at the file's current end, but short writes
--- can interleave with another appender, and a failure can leave a
--- prefix appended. Nothing is synced; use [`Fs.write`] to replace a
--- file atomically instead. Answers true, or false and a [`Failure`]
--- naming `path`; a write failure wins over a close failure.
function Fs.append(path: string, data: string, mode?: integer): (true) | (false, Failure)
  local file <close>: AppendFile = { fd = -1 }
  local fd, open_why, open_errno = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND, mode or 0x1a4)
  if fd == nil then return false, failure_of(open_errno, open_why, path) end
  file.fd = fd
  local ok, why, errno = write_all(fd, data, "")
  -- close can report failure after releasing the descriptor: never retry it.
  file.fd = -1
  local closed, close_why, close_errno = sys.close(fd)
  if not ok then return false, failure_of(errno, why, path) end
  if not closed then return false, failure_of(close_errno, close_why, path) end
  return true
end

--- Metadata for a path, or nil and a [`Failure`] that names `path`
--- and the errno that says why (`why.errno == sys.ENOENT` where nothing
--- is there).
function Fs.stat(path: string): (sys.Stat) | (nil, Failure)
  local st, _, errno = sys.stat(path)
  if st == nil then return nil, Failure.system(errno, path) end
  return st
end

--- What is at a path, looked at as [`Fs.stat`] looks: a [`Fs.Status`],
--- whose `exists` is false where nothing is there (the path or a parent
--- of it is missing, or a parent is not a directory). Any other failure
--- to look, such as a parent without search permission or a symlink
--- loop, is nil and a [`Failure`] naming the path, never a missing path.
function Fs.status(path: string): (Fs.Status) | (nil, Failure)
  local st, trouble, number = sys.stat(path)
  if st ~= nil then
    return { exists = true, is_dir = st.kind == "dir", stat = st }
  end
  if number == sys.ENOENT or number == sys.ENOTDIR then
    return { exists = false, is_dir = false }
  end
  return nil, failure_of(number, trouble, path)
end

--- `path` without its trailing slashes, scanned back from the end: a
--- pattern anchored at `$` would retry at every slash of a long run.
local function unslashed(path: string): string
  local to = #path
  while to > 0 and path:byte(to) == 47 do to = to - 1 end
  return path:sub(1, to)
end

--- Creates a directory and every missing directory above it, as
--- `mkdir -p` does. Each directory it makes gets `mode` (less the
--- umask, as `mkdir(2)` gives it) as it is made, so a private one is
--- never open to others for a moment; [`sys.mkdir`]'s default where nil.
--- A directory that is already there keeps its mode.
function Fs.mkdirs(path: string, mode?: integer): (true) | (false, Failure)
  path = unslashed(path)
  if path == "" then
    return true
  end
  local st, _, errno = sys.stat(path)
  if st ~= nil and st.kind == "dir" then
    return true
  end
  if st == nil and errno ~= sys.ENOENT and errno ~= sys.ENOTDIR then
    return false, Failure.system(errno, path)
  end
  local parent = path:match("^(.*)/[^/]+$")
  if parent ~= nil and parent ~= "" then
    local ok, trouble = Fs.mkdirs(parent, mode)
    if not ok then
      return false, trouble
    end
  end
  local made, _, number: boolean, string, integer
  if mode ~= nil then
    made, _, number = sys.mkdir(path, mode)
  else
    made, _, number = sys.mkdir(path)
  end
  if made then
    return true
  end
  if number == sys.EEXIST then
    local raced, _, race_errno = sys.stat(path)
    if raced == nil and race_errno ~= sys.ENOENT and race_errno ~= sys.ENOTDIR then
      return false, Failure.system(race_errno, path)
    end
    if raced == nil then
      -- A link to nothing: say that something is there.
      return false, Failure.system(number, path)
    end
    if raced.kind == "dir" then
      return true
    end
  end
  return false, Failure.system(number, path)
end

--- A fresh, empty temporary directory under the system temp directory,
--- named with `prefix` and a random suffix: `mktemp -d`. `TMPDIR` picks the
--- temp directory when it is set, and `/tmp` otherwise.
function Fs.mkdtemp(prefix: string): (string) | (nil, Failure)
  local base = Env.read("TMPDIR") or "/tmp"
  local template = base .. "/" .. prefix .. "XXXXXX"
  local path, _, errno = sys.mkdtemp(template)
  if path == nil then return nil, Failure.system(errno, template) end
  return path
end

--- A directory of this user's own at `path`, made 0700 when missing:
--- one that exists owned by another user, or writable by its group or
--- by others, is refused, since whatever such a directory holds could
--- have been put there by someone else.
local function private_dir(path: string): (true) | (false, Failure)
  local made, why, number = sys.mkdir(path, 0x1c0)
  if not made and number ~= sys.EEXIST then
    return false, failure_of(number, why, path)
  end
  local st, trouble, errno = sys.stat(path)
  if st == nil then
    return false, failure_of(errno, trouble, path)
  end
  if st.kind ~= "dir" then
    return false, Failure.new("not a directory", path)
  end
  if st.uid ~= sys.getuid() then
    return false, Failure.new("owned by another user", path)
  end
  if st.mode & 0x12 ~= 0 then
    return false, Failure.new("writable by its group or others", path)
  end
  return true
end

--- The XDG base directory `variable` names in `environment` (the
--- process's own where nil), or `home_default` under `HOME`. A value
--- that is not an absolute path is not one, as the XDG spec says, and
--- is passed over; with neither absolute this is nil and a Failure,
--- naming `what`.
local function xdg_base(environment: {string:string}?, variable: string, home_default: string,
                        what: string): (string) | (nil, Failure)
  local function get(name: string): string
    if environment ~= nil then
      return environment[name] or ""
    end
    return Env.get(name) or ""
  end
  local base = get(variable)
  if base:sub(1, 1) ~= "/" then
    local home = get("HOME")
    if home:sub(1, 1) ~= "/" then
      return nil, Failure.new("fs: no " .. what .. " directory: neither " .. variable .. " nor HOME is an absolute path")
    end
    base = home .. "/" .. home_default
  end
  return base
end

--- The last of `names`, each a path under `base` below the one before.
--- With `opts.make` false it is the name alone. Otherwise `base` is made
--- where missing, and refused where another user owns it (root aside).
--- Each of `names` is made 0700 where missing, and refused where another
--- user owns it or its group or others may write to it. A refusal,
--- or a failure to make one, is nil and a Failure naming the path.
local function own_dir(base: string, names: {string}, opts?: Fs.CacheOptions): (string) | (nil, Failure)
  local last = base .. "/" .. assert(names[#names])
  if opts ~= nil and opts.make == false then
    return last
  end
  local made, trouble = Fs.mkdirs(base)
  if not made then
    return nil, trouble
  end
  local st, strouble = Fs.stat(base)
  if st == nil then
    return nil, strouble
  end
  if st.uid ~= sys.getuid() and st.uid ~= 0 then
    return nil, Failure.new("owned by another user", base)
  end
  for _, name in ipairs(names) do
    local ok, ptrouble = private_dir(base .. "/" .. name)
    if not ok then
      return nil, ptrouble
    end
  end
  return last
end

--- A Failure for a `name` that is not one directory's name: empty,
--- `.`, `..`, or holding a slash.
local function refused_name(name: string): Failure?
  if name == "" or name == "." or name == ".." or name:find("/", 1, true) ~= nil then
    return Failure.new("fs: " .. string.format("%q", name) .. " is not the name of one directory")
  end
  return nil
end

--- `$XDG_CACHE_HOME/cosmic/<tool>`, or `$HOME/.cache/cosmic/<tool>`
--- when `XDG_CACHE_HOME` is unset, empty or not absolute, created when
--- missing. What a tool keeps there it trusts on later runs, so there
--- is no shared fallback: with neither variable naming an absolute
--- path this is nil and a Failure, as it is when the base directory is
--- owned by another user (root aside), or `cosmic` or `cosmic/<tool>`
--- under it is owned by another user or writable by its group or by
--- others. The two are made 0700 when missing. `opts.environment` is
--- the variables to read, by default the process's own. With
--- `opts.make` false only the name is answered, from the environment
--- alone: nothing is made, looked at or checked, so the directory may
--- not be there. A program's own cache, outside `cosmic/`, is
--- [`Fs.program_cache_dir`].
function Fs.cache_dir(tool: string, opts?: Fs.CacheOptions): (string) | (nil, Failure)
  local environment = if opts ~= nil then opts.environment else nil end
  local base, base_trouble = xdg_base(environment, "XDG_CACHE_HOME", ".cache", "cache")
  if base == nil then
    return nil, base_trouble
  end
  return own_dir(base, { "cosmic", "cosmic/" .. tool }, opts)
end

--- `$XDG_CACHE_HOME/<name>`, or `$HOME/.cache/<name>`, the cache of the
--- program named `name`, held to what [`Fs.cache_dir`] holds its
--- directories to: made 0700 when missing, and refused where it, or the
--- base (root aside), is another user's, or it is writable by its group
--- or by others.
--- `name` is one directory's name. `opts` are [`Fs.cache_dir`]'s.
function Fs.program_cache_dir(name: string, opts?: Fs.CacheOptions): (string) | (nil, Failure)
  local refused = refused_name(name)
  if refused ~= nil then return nil, refused end
  local environment = if opts ~= nil then opts.environment else nil end
  local base, base_trouble = xdg_base(environment, "XDG_CACHE_HOME", ".cache", "cache")
  if base == nil then
    return nil, base_trouble
  end
  return own_dir(base, { name }, opts)
end

--- `$XDG_DATA_HOME/<name>`, or `$HOME/.local/share/<name>` when
--- `XDG_DATA_HOME` is unset, empty or not absolute: where the program
--- named `name` keeps what it keeps (its databases, its credentials).
--- It is made 0700 when missing, and refused, as [`Fs.cache_dir`]
--- refuses its own, where it or the base (root aside) is another user's, or it is
--- writable by its group or by others: nil and a Failure, as with neither
--- variable naming an absolute path. `name` is one directory's name.
--- `opts` are [`Fs.cache_dir`]'s: with `opts.make` false the name
--- alone.
function Fs.data_dir(name: string, opts?: Fs.CacheOptions): (string) | (nil, Failure)
  local refused = refused_name(name)
  if refused ~= nil then return nil, refused end
  local environment = if opts ~= nil then opts.environment else nil end
  local base, base_trouble = xdg_base(environment, "XDG_DATA_HOME", ".local/share", "data")
  if base == nil then
    return nil, base_trouble
  end
  return own_dir(base, { name }, opts)
end

--- Removes a name: the path operation corresponding to os.remove, or
--- `unlink`. A name that is already gone is not a failure.
function Fs.remove(path: string): (true) | (false, Failure)
  local gone, _, number = sys.unlink(path)
  if gone or number == sys.ENOENT or number == sys.ENOTDIR then
    return true
  end
  return false, Failure.system(number, path)
end

--- Removes a path and, when it is a directory, everything under it:
--- the `rm -rf` a scratch directory wants ([`Fs.scratch`] makes one).
--- A link is removed, never followed, so nothing outside `path` is
--- touched -- not even by a process that swaps an entry for a link
--- while this walks, which is
--- removed with the rest: the walk is by descriptor, from each directory
--- to its entries. A path that is already gone is not a failure. A
--- directory that cannot be opened, or that something keeps filling,
--- fails the call, with what was removed gone.
function Fs.remove_tree(path: string): (true) | (false, Failure)
  local removed, _, number = sys.remove_tree(path)
  if not removed then return false, Failure.system(number, path) end
  return true
end

--- The names in a directory, sorted, without `.` and `..`.
local function sorted_names(entries: {string:Fs.Kind}): {string}
  local names: mut {string} = {}
  for name in pairs(entries) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- The entries of a directory, sorted, without `.` and `..`: `ls -A`, or
--- `readdir`.
function Fs.list(path: string): ({string}) | (nil, Failure)
  local entries, _, errno = sys.readdir(path)
  if entries == nil then return nil, Failure.system(errno, path) end
  return sorted_names(entries)
end

--- The directories a following walk is inside, innermost first, each
--- by its device and inode.
local record Above
  key: string
  up?: Above
end

--- A directory still to list, by its path relative to the root, and
--- the directories it is inside.
local record Pending
  relative: string
  above?: Above
end

--- [`Fs.walk`], following links where `follow` is true.
local function walk(root: string, follow: boolean,
                    skip?: function(string, string, Fs.Kind): boolean): ({string}) | (nil, Failure)
  local found: mut {string} = {}
  local pending: mut {Pending} = { { relative = "", above = nil } }
  while #pending > 0 do
    local next_one = assert(table.remove(pending), "pending is not empty inside the loop")
    local relative = next_one.relative
    local directory = if relative == "" then root else root .. "/" .. relative end
    local above = next_one.above
    local inside = true
    if follow then
      local st, stat_why, stat_errno = sys.stat(directory)
      if st == nil then
        return nil, failure_of(stat_errno, stat_why, directory)
      end
      local key = tostring(st.dev) .. ":" .. tostring(st.ino)
      local up = above
      while up ~= nil and inside do
        inside = up.key ~= key
        up = up.up
      end
      above = { key = key, up = above }
    end
    local entries: {string:Fs.Kind} = {}
    if inside then
      local listed, list_why, list_errno = sys.readdir(directory)
      if listed == nil then
        return nil, failure_of(list_errno, list_why, directory)
      end
      entries = listed
    end
    for _, name in ipairs(sorted_names(entries)) do
      local entry = if relative == "" then name else relative .. "/" .. name end
      local kind = assert(entries[name], "name is one of sorted_names(entries)")
      if skip == nil or not skip(entry, name, kind) then
        if kind == "link" and follow then
          local st, _ = sys.stat(directory .. "/" .. name)
          kind = if st ~= nil then st.kind else "other" end
        end
        if kind == "dir" then
          pending[#pending + 1] = { relative = entry, above = above }
        elseif kind == "file" then
          found[#found + 1] = entry
        end
      end
    end
  end
  table.sort(found)
  return found
end

--- Every file under a root, as `find root -type f` lists them but
--- relative to `root`: no leading `/` or `./` (`a.txt`, `css/main.css`),
--- so `root .. "/" .. path` names the file. Only a regular file is
--- listed (`-type f`). Unless `opts.follow` ([`Fs.WalkOptions`]), a
--- link is neither listed nor walked into, and nothing is stat'd; with
--- it, the walk lists what `find -L root -type f` lists. The
--- paths are sorted bytewise, whole. `opts.skip` is asked about each
--- entry's relative path, its bare name second, and what the listing
--- says it is third, a [`Fs.Kind`] as [`Fs.stat`]'s `kind` names it
--- (`"file"`, `"dir"`, `"link"`, `"socket"` and so on), and may refuse
--- a whole directory. `opts` may also be the `skip` function alone,
--- which ci/ and the files in ci/bootstrap-files.txt pass on the pinned
--- release.
function Fs.walk(root: string, opts?: Fs.WalkOptions | function(string, string, Fs.Kind): boolean): ({string}) | (nil, Failure)
  if opts == nil then return walk(root, false, nil) end
  if opts is Fs.WalkOptions then return walk(root, opts.follow == true, opts.skip) end
  return walk(root, false, opts)
end

-- TODO: once ci/cosmic-driver.pin names a release with Fs.WalkOptions,
-- move ci/ and the files in ci/bootstrap-files.txt to Fs.walk's options,
-- then delete Fs.walk_following, the bare function in Fs.walk's `opts`
-- and fs_test's test_walk_takes_a_bare_skip.

--- [`Fs.walk`] with `follow`, for the files in ci/bootstrap-files.txt
--- on the pinned release.
function Fs.walk_following(root: string,
                           skip?: function(string, string, Fs.Kind): boolean): ({string}) | (nil, Failure)
  return walk(root, true, skip)
end

local class Descriptor
  fd: integer

  function __close(self)
    local _, _ = sys.close(self.fd)
  end
end

--- A fresh, empty, private directory under `parent`, which must exist,
--- and a `.scratch-gate` file there. The directory is removed, with its
--- contents, when the result's `<close>` variable ends its scope. A
--- process that dies first leaves it, and the next call under the same
--- `parent` removes it: a directory is swept only when its owner file
--- can be locked, which no live holder allows, so the directories of
--- other live processes, even in other namespaces or containers sharing
--- `parent`, are never touched. A name the sweep does not recognize, or
--- a directory with no owner file, is left alone. The directory holds
--- one file, `owner`, so work goes in a subdirectory of it. A relative
--- `parent` gives a relative path, which a change of directory before
--- the close would point elsewhere.
---
--- The gate is locked by every call from before its sweep until the new
--- directory's owner is locked, so no sweep sees a directory whose owner
--- is not yet held. It is released before this returns, and the work in
--- the directory runs outside it. Use one `parent` for one kind of
--- scratch directory: calls under it sweep each other's.
function Fs.scratch(parent: string): (Fs.Scratch) | (nil, Failure)
  local fd, gate_why, gate_errno = sys.open(parent .. "/.scratch-gate", sys.O_RDWR | sys.O_CREAT | sys.O_NOFOLLOW, 0x180)
  if fd == nil then return nil, failure_of(gate_errno, gate_why, parent) end
  local gate <close>: Descriptor = { fd = fd }
  local locked, lock_why, lock_errno = sys.flock(gate.fd, "exclusive", -1)
  if not locked then return nil, failure_of(lock_errno, lock_why, parent) end
  local names, list_why = Fs.list(parent)
  if names == nil then return nil, list_why end
  for _, name in ipairs(names) do
    -- A name not of this form is not this function's to sweep, and one
    -- with no owner file has nothing to prove its holder dead.
    -- TODO: a removal that fails after deleting `owner` leaves a directory
    -- no later sweep proves dead, so it stays; remove `owner` last (or
    -- sweep an ownerless directory older than the gate's last hold) to
    -- reclaim it.
    if name:match("^%.scratch%.[%w]+$") then
      local path = parent .. "/" .. name
      local owner, _ = sys.open(path .. "/owner", sys.O_RDWR | sys.O_NOFOLLOW)
      if owner ~= nil then
        local probe <close>: Descriptor = { fd = owner }
        local dead, _ = sys.flock(probe.fd, "exclusive", 0)
        if dead then local _, _ = Fs.remove_tree(path) end
      end
    end
  end
  local path, create_why, create_errno = sys.mkdtemp(parent .. "/.scratch.XXXXXX")
  if path == nil then return nil, failure_of(create_errno, create_why, parent) end
  local owner, owner_why, owner_errno = sys.open(path .. "/owner", sys.O_RDWR | sys.O_CREAT | sys.O_EXCL, 0x180)
  if owner == nil then
    local _, _ = Fs.remove_tree(path)
    return nil, failure_of(owner_errno, owner_why, path .. "/owner")
  end
  local holding: Fs.Scratch = { path = path, owner = owner }
  local held, hold_why, hold_errno = sys.flock(owner, "exclusive", 0)
  if not held then
    local _cleanup <close> = holding
    return nil, failure_of(hold_errno, hold_why, path .. "/owner")
  end
  return holding
end

--- A path with no link and no `..` left in it: `realpath`.
function Fs.absolute(path: string): (string) | (nil, Failure)
  local resolved, _, errno = sys.realpath(path)
  if resolved == nil then return nil, Failure.system(errno, path) end
  return resolved
end

--- Moves a name, replacing the destination if it is there; this corresponds
--- to os.rename, or `mv -T` within one file system. A failure names `from`.
function Fs.rename(from: string, to: string): (true) | (false, Failure)
  local moved, _, number = sys.rename(from, to)
  if not moved then
    return false, Failure.system(number, from)
  end
  return true
end

--- Sets a path's permission bits, following a link to its target:
--- `chmod`. `mode` is the bits as an integer (0x1ed for 0755), setuid,
--- setgid and sticky included; one outside 0 to 0xfff raises, since
--- the kernel would silently drop the bits it does not hold.
--- `assert(Fs.stat(path)).mode & 0xfff` reads them back.
function Fs.chmod(path: string, mode: integer): (true) | (false, Failure)
  if mode < 0 or mode > 0xfff then
    local shown = if mode > 0 and math.tointeger(mode) ~= nil then string.format("0x%x", mode) else tostring(mode) end
    error("fs: mode " .. shown .. " is outside 0 to 0xfff", 2)
  end
  local changed, _, number = sys.chmod(path, mode)
  if not changed then
    return false, Failure.system(number, path)
  end
  return true
end

--- The Lua io module and io.open handles are unavailable. This opens a file
--- for reading and returns an integer descriptor instead. Most callers want
--- [`Fs.read`]; use Fs.take and Fs.close when a file must be read in pieces.
function Fs.open_read(path: string): (integer) | (nil, Failure)
  -- TODO: a descriptor a `<close>` variable can hold (a record with
  -- [`__close`] over the fd), here and in open_write, so a file read or
  -- written in pieces is closed on every way out of its block: callers
  -- write `local f <close> = assert(Fs.open_read(path))` and meet an
  -- integer, which `<close>` refuses.
  local fd, why, errno = sys.open(path, sys.O_RDONLY)
  if fd == nil then
    return nil, failure_of(errno, why, path)
  end
  return fd
end

--- Opens a file for writing, creating it and emptying it, and returns an
--- integer descriptor rather than an io.open file handle. Use Fs.put and
--- Fs.close; Fs.write is safer when the whole replacement is available.
--- `mode` is the permission bits of a file this call creates, as an
--- integer (0x1a4 for 0644, the default), less the process's umask; an
--- existing file keeps its own.
function Fs.open_write(path: string, mode?: integer): (integer) | (nil, Failure)
  local flags = sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC
  local fd, why, errno = sys.open(path, flags, mode or 0x1a4)
  if fd == nil then
    return nil, failure_of(errno, why, path)
  end
  return fd
end

--- Reads up to `count` bytes from a descriptor. This is the streaming byte
--- operation in place of io.read; an empty string is the end of the file.
function Fs.take(fd: integer, count: integer): (string) | (nil, Failure)
  local data, why, errno = sys.read(fd, count)
  if data == nil then
    return nil, failure_of(errno, why)
  end
  return data
end

--- Closes a descriptor returned by Fs.open_read or Fs.open_write; it does not
--- accept a Lua io.close file handle.
function Fs.close(fd: integer): (true) | (false, Failure)
  local ok, why, errno = sys.close(fd)
  if not ok then
    return false, failure_of(errno, why)
  end
  return true
end

--- Writes bytes to a descriptor, without a newline. Fs.stdout and Fs.stderr
--- are the standard-stream descriptors used instead of io.write/io.output.
function Fs.put(fd: integer, data: string): (true) | (false, Failure)
  local ok, why, errno = write_all(fd, data, "fs: ")
  if not ok then return false, failure_of(errno, why) end
  return true
end

--- Creates a symbolic link at `path` pointing at `target`, which is
--- stored verbatim and never resolved: `ln -s target path`.
function Fs.symlink(target: string, path: string): (true) | (false, Failure)
  local made, _, number = sys.symlink(target, path)
  if not made then
    return false, Failure.system(number, path)
  end
  return true
end

--- The target of a symbolic link.
function Fs.readlink(path: string): (string) | (nil, Failure)
  local target, _, errno = sys.readlink(path)
  if target == nil then return nil, Failure.system(errno, path) end
  return target
end

--- Sets a path's modification time to `seconds` since the epoch and
--- `ns` nanoseconds after them (default 0), the shape a `Stat` reports
--- it in (`st.mtime`, `st.mtime_ns`), leaving its access time as it
--- is, as `touch -h -m -d` does. Changes the link itself, not its
--- target. `ns` outside [0, 1e9) raises.
function Fs.set_mtime(path: string, seconds: integer, ns?: integer): (true) | (false, Failure)
  if ns ~= nil and (ns < 0 or ns >= 1000000000) then
    error("fs: nanoseconds are outside [0, 1e9)", 2)
  end
  local set, _, number = sys.utimensat(path, nil, nil, seconds, ns)
  if not set then
    return false, Failure.system(number, path)
  end
  return true
end

--- Flushes a descriptor's data and metadata to storage.
function Fs.fsync(fd: integer): (true) | (false, Failure)
  local ok, why, errno = sys.fsync(fd)
  if not ok then
    return false, failure_of(errno, why)
  end
  return true
end

--- Copies one regular file's bytes a chunk at a time, so a large file
--- is never held in memory whole.
local function copy_bytes(from: string, to: string): (true) | (false, Failure)
  -- A source swapped for a link, a named pipe or a terminal since its
  -- lstat is refused rather than followed, waited on for a writer, or
  -- taken as this process's terminal.
  local input, _, open_errno = sys.open(from,
    sys.O_RDONLY | sys.O_NOFOLLOW | sys.O_NONBLOCK | sys.O_NOCTTY)
  if input == nil then return false, Failure.system(open_errno, from) end
  local st, _, stat_errno = sys.fstat(input)
  if st == nil or st.kind ~= "file" then
    local _, _ = Fs.close(input)
    if st == nil then return false, Failure.system(stat_errno, from) end
    return false, Failure.new("no longer a regular file", from)
  end
  -- Exclusive: a name that appeared since the target was checked, a
  -- planted link included, is refused rather than written through.
  local output, _, create_errno = sys.open(to,
    sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, 0x180)
  if output == nil then
    local _, _ = Fs.close(input)
    return false, Failure.system(create_errno, to)
  end
  local failure: Failure? = nil
  while true do
    local chunk, _, read_errno = sys.read(input, 1 << 20)
    if chunk == nil then
      failure = Failure.system(read_errno, from)
      break
    end
    if chunk == "" then break end
    local put, put_why, put_errno = write_all(output, chunk, "")
    if not put then
      failure = failure_of(put_errno, put_why, to)
      break
    end
  end
  -- A read-only source has nothing to lose in closing.
  local _, _ = Fs.close(input)
  local closed, close_why = Fs.close(output)
  if failure ~= nil then return false, failure end
  if not closed then return false, failure_of(close_why.errno, close_why.message, to) end
  return true
end

-- TODO: keep what `cp -a` also keeps -- hard links as links (Stat has
-- ino, dev and nlink; it needs a map from (dev, ino) to the first copy
-- and a binding for link(2)), and the owner when run as root (once
-- cosmic.sys carries lchown).

--- Copies the tree at `from` to a new `to`, as `cp -Rp` does: each
--- regular file's bytes, each directory, and each symbolic link as a link to the
--- same target, never followed. Every permission bit is kept, the umask
--- not applied, except setuid and setgid: the copy belongs to whoever
--- makes it, so they are dropped. Each access and modification time is
--- kept to the nanosecond, as the source's own `lstat` read it before
--- the copy. `to` must not exist yet; each listing is read before its copy
--- is made, so a tree copied into itself is not copied again. Anything
--- else in the tree (a device, a socket, a named pipe) stops the copy
--- with its path, and a copy that stops leaves what it made so far in
--- place.
function Fs.copy_tree(from: string, to: string): (true) | (false, Failure)
  local present, _, number = sys.lstat(to)
  if present ~= nil then
    return false, Failure.system(sys.EEXIST, to)
  elseif number ~= sys.ENOENT then
    return false, Failure.system(number, to)
  end
  local function copy(source: string, target: string): (true) | (false, Failure)
    local st, _, stat_errno = sys.lstat(source)
    if st == nil then return false, Failure.system(stat_errno, source) end
    local permissions = st.mode & 0x3ff
    if st.kind == "link" then
      local target_of, link_why = Fs.readlink(source)
      if target_of == nil then return false, link_why end
      local linked, symlink_why = Fs.symlink(target_of, target)
      if not linked then return false, symlink_why end
    elseif st.kind == "file" then
      local copied, copy_why = copy_bytes(source, target)
      if not copied then return false, copy_why end
      local changed, chmod_why = Fs.chmod(target, permissions)
      if not changed then return false, chmod_why end
    elseif st.kind == "dir" then
      local entries, _, list_errno = sys.readdir(source)
      if entries == nil then return false, Failure.system(list_errno, source) end
      local made, _, mkdir_errno = sys.mkdir(target, 0x1c0)
      if not made then return false, Failure.system(mkdir_errno, target) end
      for _, name in ipairs(sorted_names(entries)) do
        local copied, why = copy(source .. "/" .. name, target .. "/" .. name)
        if not copied then return false, why end
      end
      -- The directory's own mode last, so a read-only one still took
      -- its entries.
      local changed, chmod_why = Fs.chmod(target, permissions)
      if not changed then return false, chmod_why end
    else
      return false, Failure.new("not a file, directory or symbolic link", source)
    end
    local timed, _, time_errno = sys.utimensat(target, st.atime, st.atime_ns,
      st.mtime, st.mtime_ns)
    if not timed then return false, Failure.system(time_errno, target) end
    return true
  end
  return copy(from, to)
end

--- The last component of a path, as basename(1) names it: trailing
--- slashes are ignored, "/" is itself, and "" stays "". Lexical: nothing
--- is read from disk.
function Fs.basename(path: string): string
  if path == "" then return "" end
  local trimmed = unslashed(path)
  if trimmed == "" then return "/" end
  local at = #trimmed
  while at > 0 and trimmed:byte(at) ~= 47 do at = at - 1 end
  return trimmed:sub(at + 1)
end

--- The directory a path names its last component in, as dirname(1)
--- answers: trailing slashes are ignored, a bare name is in ".", and
--- "/" and a component directly under it are in "/". Lexical: nothing
--- is read from disk, and "a/.." is in "a".
function Fs.dirname(path: string): string
  local trimmed = unslashed(path)
  if trimmed == "" then
    return if path == "" then "." else "/" end
  end
  local at = #trimmed
  while at > 0 and trimmed:byte(at) ~= 47 do at = at - 1 end
  if at == 0 then return "." end
  local directory = unslashed(trimmed:sub(1, at))
  if directory == "" then return "/" end
  return directory
end

--- Whether `path` is `directory` or lies under it, comparing the text
--- component by component: "a/bc" is not within "a/b". Trailing slashes
--- on either are ignored. Lexical, so both should be written the same
--- way (absolute, or relative to one place, with no "." or ".."); an
--- empty directory holds nothing.
function Fs.within(path: string, directory: string): boolean
  if directory == "" then return false end
  local base = unslashed(directory)
  if base == "" then return path:sub(1, 1) == "/" end
  return unslashed(path) == base or path:sub(1, #base + 1) == base .. "/"
end

--- `path` relative to `directory`, lexically: "." when they are the same,
--- the rest after the directory's "/" when `path` is within it, and nil
--- and a Failure, with errno 0, when it is not.
function Fs.relative(path: string, directory: string): (string) | (nil, Failure)
  if not Fs.within(path, directory) then
    return nil, Failure.new("not within " .. directory, path)
  end
  local base = unslashed(directory)
  local from = #base + 1
  while path:byte(from) == 47 do from = from + 1 end
  local rest = unslashed(path:sub(from))
  if rest == "" then return "." end
  return rest
end

Fs.stdin = 0
Fs.stdout = 1
Fs.stderr = 2

return Fs
