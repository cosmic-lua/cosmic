--- Files and directories.
---
--- Every call goes through the syscall table, so one call behaves the
--- same on Linux and on macOS. A fallible call that produces a value
--- returns `T | nil, string`: a value and `""` on success, or nil and
--- an error. A predicate uses the same contract, with false as a valid
--- answer. A call that only has an effect returns `boolean, string`.
---
--- A descriptor from [`Fs.open_read`] or [`Fs.open_write`] is a plain
--- integer, closed with [`Fs.close`], so a `<close>` variable cannot hold
--- it. One holds a value whose type has a `__close` metamethod, written
--- `local h <close> = assert(Child.start(argv))`: `assert` narrows the
--- `T | nil` an opener answers, which `<close>` refuses, to `T`.
---
--- `basename`, `dirname`, `within` and `relative` work on a path's
--- text alone and read nothing. The first three cannot fail, so each
--- answers a plain value; `relative` answers nil and why when the path
--- is not within the directory.
---
--- The syscall table itself is [`cosmic.sys`]. A call this module does not
--- wrap -- `lstat`, `chdir`, `pread` and others -- is there, and
--- `cosmic docs cosmic.sys` lists every one.

local Env = require("cosmic.env")
local sys = require("cosmic.sys")

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

  --- A file at a path being written through a temporary neighbor and a
  --- rename, as [`Fs.create`] returns it: a [`cosmic.stream`] Writer
  --- (`write`, `close` and `abort`) that can also `sync`. Every failure
  --- names the path, never the temporary file, and is sticky.
  interface Staged
    --- Appends `data`: false and why when it cannot all be written.
    write: function(Staged, string): boolean, string
    --- Flushes what was written to storage, so that the rename `close`
    --- makes cannot reach it before the data does.
    sync: function(Staged): boolean, string
    --- Renames the file onto its path: false and why when a write
    --- failed, or the rename or the closing of the file does. Safe to
    --- call more than once; after `abort` it renames nothing and
    --- answers true.
    close: function(Staged): boolean, string
    --- Removes the temporary file and leaves the path as it was. Safe
    --- to call more than once.
    abort: function(Staged): boolean, string
  end

  --- What [`Fs.cache_dir`] reads.
  record CacheOptions
    --- The variables to read (`XDG_CACHE_HOME`, `HOME`), by name; the
    --- process's own when nil.
    environment: {string:string}
    --- Whether to make and check the directory; true when nil. False
    --- answers the name alone.
    make: boolean
  end

  --- A private directory made by [`Fs.scratch`], removed with everything
  --- in it when a `<close>` variable holding it ends its scope.
  record Scratch
    --- The directory, a child of the one [`Fs.scratch`] was given.
    path: string
    --- A descriptor of the `owner` file inside `path`, which is on the
    --- directory's own filesystem and locked for as long as the
    --- scratch directory is open. Leave the file alone, and neither
    --- read nor close the descriptor.
    owner: integer
    metamethod __close: function(Scratch)
  end

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
--- handles are unnecessary.
function Fs.read(path: string): string | nil, string
  local fd, trouble = sys.open(path, sys.O_RDONLY)
  if fd == nil then
    return nil, path .. ": " .. trouble
  end
  -- A regular file says how big it is, so its bytes come in one read
  -- into one string of that size; chunks follow only for whatever it
  -- holds past that, or for a file that does not say (a pipe, /proc).
  local st, _ = sys.fstat(fd)
  local ask = chunk_size
  if st ~= nil and st.kind == "file" and st.size > chunk_size then
    ask = st.size
  end
  local parts: {string} = {}
  while true do
    local chunk, failure = sys.read(fd, ask)
    if chunk == nil then
      local _, _ = sys.close(fd)
      return nil, path .. ": " .. failure
    end
    if #chunk == 0 then
      break
    end
    parts[#parts + 1] = chunk
    ask = chunk_size
  end
  local _, _ = sys.close(fd)
  if #parts == 1 then
    return parts[1], ""
  end
  return table.concat(parts), ""
end

--- Writes all of `data` to `fd`; a write that moves nothing fails
--- "`blame`write made no progress", `blame` being "fs: " where no caller
--- names the file.
local function write_all(fd: integer, data: string, blame: string): boolean, string
  local at = 1
  while at <= #data do
    -- The whole string the first time, rather than a copy of it.
    local rest = at == 1 and data or data:sub(at)
    local put, trouble = sys.write(fd, rest)
    if put == nil then
      return false, trouble
    end
    if put == 0 then
      return false, blame .. "write made no progress"
    end
    at = at + put
  end
  return true, ""
end

-- How an object of this module is made: see the note on objects in
-- cosmic/stream.tl.

--- What [`Fs.create`] returns: its methods live on the record's own
--- table, so creating a file costs a table, not four closures.
local record StagedFile is Fs.Staged
  path: string
  temporary: sys.TemporaryFile
  -- "" until a call fails.
  failed: string
  closed: boolean
  write: function(StagedFile, string): boolean, string
  sync: function(StagedFile): boolean, string
  close: function(StagedFile): boolean, string
  abort: function(StagedFile): boolean, string
end

local staged_file_mt: metatable<StagedFile> = { __index = StagedFile }

--- Remembers `why` as the file's failure, naming the caller's path: a
--- failure is sticky, and never names the temporary file, which the
--- caller never chose and which is gone when it reads the message.
local function failing(self: StagedFile, why: string): string
  self.failed = self.path .. ": " .. why
  return self.failed
end

function StagedFile:write(data: string): boolean, string
  if self.closed then return false, self.path .. ": the file is closed" end
  if self.failed ~= "" then return false, self.failed end
  local ok, why = write_all(self.temporary.fd, data, "")
  if not ok then return false, failing(self, why) end
  return true, ""
end

function StagedFile:sync(): boolean, string
  if self.closed then return false, self.path .. ": the file is closed" end
  if self.failed ~= "" then return false, self.failed end
  local ok, why = sys.fsync(self.temporary.fd)
  if not ok then return false, failing(self, why) end
  return true, ""
end

function StagedFile:abort(): boolean, string
  if self.closed then return true, "" end
  self.closed = true
  local _, _ = sys.close(self.temporary.fd)
  local _, _ = sys.unlink(self.temporary.path)
  return true, ""
end

function StagedFile:close(): boolean, string
  local temporary = self.temporary
  if self.closed then
    if self.failed ~= "" then return false, self.failed end
    return true, ""
  end
  self.closed = true
  if self.failed ~= "" then
    local _, _ = sys.close(temporary.fd)
    local _, _ = sys.unlink(temporary.path)
    return false, self.failed
  end
  local closed, close_trouble = sys.close(temporary.fd)
  if not closed then
    local _, _ = sys.unlink(temporary.path)
    return false, failing(self, close_trouble)
  end
  local moved, why = sys.rename(temporary.path, self.path)
  if not moved then
    local _, _ = sys.unlink(temporary.path)
    return false, failing(self, why)
  end
  return true, ""
end

--- Starts writing a file at `path`: bytes go to a new temporary neighbor,
--- created exclusively (so two writers never share one and a planted
--- symlink is never followed), which `close` renames onto `path`, so a
--- reader of `path` sees the old contents or the new, never a mix. A
--- failure, or `abort`, leaves `path` as it was and removes the
--- temporary file. The file is always a new one, so it gets `mode`
--- (default 0644, less the umask) and never keeps an existing file's
--- mode. Nothing is synced unless `sync` is called, so a crash can
--- still lose the write. [`Stream.create`] is this, as a
--- [`cosmic.stream`] Writer.
function Fs.create(path: string, mode?: integer): Fs.Staged | nil, string
  local temporary, trouble = sys.open_temporary(path, mode or 0x1a4)
  if temporary == nil then
    return nil, path .. ": " .. trouble
  end
  local staged: StagedFile = setmetatable({
    path = path, temporary = temporary, failed = "", closed = false,
  }, staged_file_mt)
  return staged, ""
end

--- Writes `data` to `path` through a temporary file and a rename, in
--- place of io.open/io.write: [`Fs.create`], one write and the close. A
--- reader sees the old contents or the new, never a mix, and a
--- failure before the rename leaves the old file. The file is always a
--- new one, so it gets `mode` (default 0644, less the umask) and never
--- keeps an existing file's mode. Nothing is synced, so a crash can
--- still lose the write.
function Fs.write(path: string, data: string, mode?: integer): boolean, string
  local file, trouble = Fs.create(path, mode)
  if file == nil then
    return false, trouble
  end
  local ok, why = file:write(data)
  if not ok then
    local _, _ = file:abort()
    return false, why
  end
  return file:close()
end

local record AppendFile
  metamethod __close: function(AppendFile)
  fd: integer
end

local append_mt: metatable<AppendFile> = {
  __close = function(self: AppendFile)
    if self.fd < 0 then return end
    local fd = self.fd
    self.fd = -1
    local _, _ = sys.close(fd)
  end,
}

--- Appends `data` in place, creating `path` if missing, with `mode`
--- (default 0644, less the umask). An existing file keeps its inode and
--- mode, and a symlink is followed. Empty data still creates a missing
--- file. Each write starts at the file's current end, but short writes
--- can interleave with another appender, and a failure can leave a
--- prefix appended. Nothing is synced; use [`Fs.write`] to replace a
--- file atomically instead. Answers true and an empty reason on success,
--- or false and a reason naming `path`; a write failure wins over a
--- close failure.
function Fs.append(path: string, data: string, mode?: integer): boolean, string
  if type(data) ~= "string" then error("fs: append data must be a string", 2) end
  local file <close>: AppendFile = setmetatable({ fd = -1 }, append_mt)
  local fd, trouble = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_APPEND, mode or 0x1a4)
  if fd == nil then return false, path .. ": " .. trouble end
  file.fd = fd
  local ok, why = write_all(fd, data, "")
  -- close can report failure after releasing the descriptor: never retry it.
  file.fd = -1
  local closed, close_trouble = sys.close(fd)
  if not ok then return false, path .. ": " .. why end
  if not closed then return false, path .. ": " .. close_trouble end
  return true, ""
end

--- Metadata for a path, or nil and an error if it cannot be inspected.
function Fs.stat(path: string): sys.Stat | nil, string
  local st, trouble = sys.stat(path)
  if st == nil then
    return nil, path .. ": " .. trouble
  end
  return st, ""
end

--- Whether anything is at a path. A missing path is false, while an error
--- inspecting the path is nil.
function Fs.exists(path: string): boolean | nil, string
  local st, trouble, number = sys.stat(path)
  if st ~= nil then
    return true, ""
  end
  if number == sys.ENOENT or number == sys.ENOTDIR then
    return false, ""
  end
  return nil, path .. ": " .. trouble
end

--- Whether a directory is at a path. A missing path or an existing
--- non-directory is false, while an error inspecting the path is nil.
function Fs.is_dir(path: string): boolean | nil, string
  local st, trouble, number = sys.stat(path)
  if st ~= nil then
    return st.kind == "dir", ""
  end
  if number == sys.ENOENT or number == sys.ENOTDIR then
    return false, ""
  end
  return nil, path .. ": " .. trouble
end

--- `path` without its trailing slashes, scanned back from the end: a
--- pattern anchored at `$` would retry at every slash of a long run.
local function unslashed(path: string): string
  local to = #path
  while to > 0 and path:byte(to) == 47 do to = to - 1 end
  return path:sub(1, to)
end

--- Creates a directory and every missing directory above it, as
--- `mkdir -p` does.
function Fs.mkdirs(path: string): boolean, string
  path = unslashed(path)
  if path == "" then
    return true, ""
  end
  local directory, inspection = Fs.is_dir(path)
  if directory == nil then
    return false, inspection
  end
  if directory then
    return true, ""
  end
  local parent = path:match("^(.*)/[^/]+$")
  if parent ~= nil and parent ~= "" then
    local ok, trouble = Fs.mkdirs(parent)
    if not ok then
      return false, trouble
    end
  end
  local made, why, number = sys.mkdir(path)
  if made then
    return true, ""
  end
  if number == sys.EEXIST then
    local raced, race_trouble = Fs.is_dir(path)
    if raced == nil then
      return false, race_trouble
    end
    if raced then
      return true, ""
    end
  end
  return false, path .. ": " .. why
end

--- A fresh, empty temporary directory under the system temp directory,
--- named with `prefix` and a random suffix: `mktemp -d`. `TMPDIR` picks the
--- temp directory when it is set, and `/tmp` otherwise.
function Fs.mkdtemp(prefix: string): string | nil, string
  local base = Env.get_or("TMPDIR", "/tmp")
  local template = base .. "/" .. prefix .. "XXXXXX"
  local path, trouble = sys.mkdtemp(template)
  if path == nil then
    return nil, template .. ": " .. trouble
  end
  return path, ""
end

--- A directory of this user's own at `path`, made 0700 when missing:
--- one that exists owned by another user, or writable by its group or
--- by others, is refused, since whatever such a directory holds could
--- have been put there by someone else.
local function private_dir(path: string): boolean, string
  local made, why, number = sys.mkdir(path, 0x1c0)
  if not made and number ~= sys.EEXIST then
    return false, path .. ": " .. why
  end
  local st, trouble = sys.stat(path)
  if st == nil then
    return false, path .. ": " .. trouble
  end
  if st.kind ~= "dir" then
    return false, path .. ": not a directory"
  end
  if st.uid ~= sys.getuid() then
    return false, path .. ": owned by another user"
  end
  if st.mode & 0x12 ~= 0 then
    return false, path .. ": writable by its group or others"
  end
  return true, ""
end

--- The base [`Fs.cache_dir`] puts `cosmic` under.
local function cache_base(environment?: {string:string}): string | nil, string
  local function get(name: string): string
    if environment ~= nil then
      return environment[name] or ""
    end
    return Env.get_or(name, "")
  end
  local base = get("XDG_CACHE_HOME")
  if base:sub(1, 1) ~= "/" then
    local home = get("HOME")
    if home:sub(1, 1) ~= "/" then
      return nil, "fs: no cache directory: neither XDG_CACHE_HOME nor HOME is an absolute path"
    end
    base = home .. "/.cache"
  end
  return base, ""
end

--- `$XDG_CACHE_HOME/cosmic/<tool>`, or `$HOME/.cache/cosmic/<tool>`
--- when `XDG_CACHE_HOME` is unset, empty or not absolute, created when
--- missing. What a tool keeps there it trusts on later runs, so there
--- is no shared fallback: with neither variable naming an absolute
--- path this is nil and an error, as it is when the base directory is
--- owned by another user (root aside), or `cosmic` or `cosmic/<tool>`
--- under it is owned by another user or writable by its group or by
--- others. The two are made 0700 when missing. `opts.environment` is
--- the variables to read, by default the process's own. With
--- `opts.make` false only the name is answered, from the environment
--- alone: nothing is made, looked at or checked, so the directory may
--- not be there.
function Fs.cache_dir(tool: string, opts?: Fs.CacheOptions): string | nil, string
  local environment = opts ~= nil and opts.environment or nil
  local base, base_trouble = cache_base(environment)
  if base == nil then
    return nil, base_trouble
  end
  local dir = base .. "/cosmic"
  if opts ~= nil and opts.make == false then
    return dir .. "/" .. tool, ""
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
    return nil, base .. ": owned by another user"
  end
  for _, path in ipairs({ dir, dir .. "/" .. tool }) do
    local ok, ptrouble = private_dir(path)
    if not ok then
      return nil, ptrouble
    end
  end
  return dir .. "/" .. tool, ""
end

--- Removes a name: the path operation corresponding to os.remove, or
--- `unlink`. A name that is already gone is not a failure.
function Fs.remove(path: string): boolean, string
  local gone, trouble, number = sys.unlink(path)
  if gone or number == sys.ENOENT or number == sys.ENOTDIR then
    return true, ""
  end
  return false, path .. ": " .. trouble
end

--- Removes a path and, when it is a directory, everything under it:
--- the `rm -rf` a scratch directory wants ([`Fs.scratch`] makes one). A link is removed, never
--- followed, so nothing outside `path` is touched -- not even by a
--- process that swaps an entry for a link while this walks, which is
--- removed with the rest: the walk is by descriptor, from each directory
--- to its entries. A path that is already gone is not a failure. A
--- directory that cannot be opened, or that something keeps filling,
--- fails the call, with what was removed gone.
function Fs.remove_tree(path: string): boolean, string
  local removed, trouble = sys.remove_tree(path)
  if not removed then return false, path .. ": " .. trouble end
  return true, ""
end

--- The names in a directory, sorted, without `.` and `..`.
local function sorted_names(entries: {string:Fs.Kind}): {string}
  local names: {string} = {}
  for name in pairs(entries) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- The entries of a directory, sorted, without `.` and `..`: `ls -A`, or
--- `readdir`.
function Fs.list(path: string): {string} | nil, string
  local entries, trouble = sys.readdir(path)
  if entries == nil then
    return nil, path .. ": " .. trouble
  end
  return sorted_names(entries), ""
end

--- The directories a following walk is inside, innermost first, each
--- by its device and inode.
local record Above
  key: string
  up: Above
end

--- A directory still to list, by its path relative to the root, and
--- the directories it is inside.
local record Pending
  relative: string
  above: Above
end

--- Both walks: [`Fs.walk`], and with `follow`, [`Fs.walk_following`].
local function walk(root: string, skip: function(string, string, Fs.Kind): boolean,
                    follow: boolean): {string} | nil, string
  local found: {string} = {}
  local pending: {Pending} = { { relative = "", above = nil } }
  while #pending > 0 do
    local next_one = table.remove(pending)
    local relative = next_one.relative
    local directory = relative == "" and root or (root .. "/" .. relative)
    local above = next_one.above
    local inside = true
    if follow then
      local st, stat_trouble = sys.stat(directory)
      if st == nil then
        return nil, directory .. ": " .. stat_trouble
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
      local listed, trouble = sys.readdir(directory)
      if listed == nil then
        return nil, directory .. ": " .. trouble
      end
      entries = listed
    end
    for _, name in ipairs(sorted_names(entries)) do
      local entry = relative == "" and name or (relative .. "/" .. name)
      local kind = entries[name]
      if skip == nil or not skip(entry, name, kind) then
        if kind == "link" and follow then
          local st, _ = sys.stat(directory .. "/" .. name)
          kind = st ~= nil and st.kind or "other"
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
  return found, ""
end

--- Every file under a root, as `find root -type f` lists them but
--- relative to `root`: no leading `/` or `./` (`a.txt`, `css/main.css`),
--- so `root .. "/" .. path` names the file. Only a regular file is
--- listed (`-type f`): a link is neither listed nor walked into,
--- whatever it leads to. The paths are sorted bytewise, whole.
--- `skip` is asked about each entry's relative path, its bare name
--- second, and what the listing says it is third, a [`Fs.Kind`] as
--- [`Fs.stat`]'s `kind` names it (`"file"`, `"dir"`, `"link"`,
--- `"socket"` and so on), and may refuse a whole directory. The
--- listing says what each entry is, so nothing here is stat'd.
function Fs.walk(root: string,
                 skip?: function(string, string, Fs.Kind): boolean): {string} | nil, string
  return walk(root, skip, false)
end

--- Every file under a root as [`Fs.walk`] lists them -- relative to
--- `root`, sorted, regular files alone -- but with each link taken for
--- what it leads to, as `find -L root -type f` lists them: a link to a
--- file is listed as a file, under the link's own path, and a
--- link to a directory is walked into. A link that leads nowhere (or to
--- a device, a socket or a pipe) is not listed. A directory already
--- being walked, reached again through a link (`loop -> .`), is not
--- walked a second time, so a loop ends the walk of that branch rather
--- than failing it. As with `find -L`, a file reached along several
--- paths (a diamond of links) is listed once per path, and a link to a
--- directory above the root is walked in full, but for the directories
--- the walk is already inside. `skip` is asked as [`Fs.walk`] asks it,
--- before a link is followed, so it is told `"link"` and may refuse
--- one. Each directory, and each link, is stat'd.
function Fs.walk_following(root: string,
                           skip?: function(string, string, Fs.Kind): boolean): {string} | nil, string
  return walk(root, skip, true)
end

local record Descriptor
  fd: integer
  metamethod __close: function(Descriptor)
end
local descriptor_mt: metatable<Descriptor> = {
  __close = function(self: Descriptor) local _, _ = sys.close(self.fd) end,
}

local scratch_mt: metatable<Fs.Scratch> = {
  __close = function(self: Fs.Scratch)
    local _, _ = Fs.remove_tree(self.path)
    local _, _ = sys.close(self.owner)
  end,
}

--- A fresh, empty, private directory under `parent`, which must exist,
--- and a `.scratch-gate` file there. The directory is removed, with its
--- contents, when the result's `<close>` variable ends its scope. A
--- process that dies first leaves it, and the next call under the same
--- `parent` removes it: a directory is swept only when its owner file
--- can be locked, which no live holder allows, so the directories of
--- other live processes, even in other namespaces or containers sharing
--- `parent`, are never touched. A name the sweep does not recognize, or
--- a directory with no owner file, is left alone. The directory holds
--- one file, `owner`, so work goes in a subdirectory of it.
---
--- The gate is locked by every call from before its sweep until the new
--- directory's owner is locked, so no sweep sees a directory whose owner
--- is not yet held. It is released before this returns, and the work in
--- the directory runs outside it. Use one `parent` for one kind of
--- scratch directory: calls under it sweep each other's.
function Fs.scratch(parent: string): Fs.Scratch | nil, string
  local fd, trouble = sys.open(parent .. "/.scratch-gate", sys.O_RDWR | sys.O_CREAT | sys.O_NOFOLLOW, 0x180)
  if fd == nil then return nil, parent .. ": " .. trouble end
  local opened: Descriptor = { fd = fd }
  local gate <close> = setmetatable(opened, descriptor_mt)
  local locked, lock_trouble = sys.flock(gate.fd, "exclusive", -1)
  if not locked then return nil, parent .. ": " .. lock_trouble end
  local names, list_trouble = Fs.list(parent)
  if names == nil then return nil, list_trouble end
  for _, name in ipairs(names) do
    -- PID-only names belong to old tools and say nothing about ownership
    -- across namespaces. Missing owner files are also left alone.
    if name:match("^%.scratch%.[%w]+$") then
      local path = parent .. "/" .. name
      local owner, _ = sys.open(path .. "/owner", sys.O_RDWR | sys.O_NOFOLLOW)
      if owner ~= nil then
        local descriptor: Descriptor = { fd = owner }
        local probe <close> = setmetatable(descriptor, descriptor_mt)
        local dead, _ = sys.flock(probe.fd, "exclusive", 0)
        if dead then local _, _ = Fs.remove_tree(path) end
      end
    end
  end
  local path, create_trouble = sys.mkdtemp(parent .. "/.scratch.XXXXXX")
  if path == nil then return nil, parent .. ": " .. create_trouble end
  local owner, owner_trouble = sys.open(path .. "/owner", sys.O_RDWR | sys.O_CREAT | sys.O_EXCL, 0x180)
  if owner == nil then
    local _, _ = Fs.remove_tree(path)
    return nil, path .. "/owner: " .. owner_trouble
  end
  local owned: Fs.Scratch = { path = path, owner = owner }
  local holding = setmetatable(owned, scratch_mt)
  local held, hold_trouble = sys.flock(owner, "exclusive", 0)
  if not held then
    local _cleanup <close> = holding
    return nil, path .. "/owner: " .. hold_trouble
  end
  return holding, ""
end

--- A path with no link and no `..` left in it: `realpath`.
function Fs.absolute(path: string): string | nil, string
  local resolved, trouble = sys.realpath(path)
  if resolved == nil then
    return nil, path .. ": " .. trouble
  end
  return resolved, ""
end

--- Moves a name, replacing the destination if it is there; this corresponds
--- to os.rename, or `mv -T` within one file system.
function Fs.rename(from: string, to: string): boolean, string
  local moved, trouble = sys.rename(from, to)
  if not moved then
    return false, from .. ": " .. trouble
  end
  return true, ""
end

--- Sets a path's permission bits, following a link to its target:
--- `chmod`. `mode` is the bits as an integer (0x1ed for 0755), setuid,
--- setgid and sticky included; one outside 0 to 0xfff raises, since
--- the kernel would silently drop the bits it does not hold.
--- `Fs.stat(path).mode & 0xfff` reads them back.
function Fs.chmod(path: string, mode: integer): boolean, string
  if mode < 0 or mode > 0xfff then
    local shown = (mode > 0 and math.tointeger(mode) ~= nil) and string.format("0x%x", mode) or
      tostring(mode)
    error("fs: mode " .. shown .. " is outside 0 to 0xfff", 2)
  end
  local changed, trouble = sys.chmod(path, mode)
  if not changed then
    return false, path .. ": " .. trouble
  end
  return true, ""
end

--- The Lua io module and io.open handles are unavailable. This opens a file
--- for reading and returns an integer descriptor instead. Most callers want
--- [`Fs.read`]; use Fs.take and Fs.close when a file must be read in pieces.
function Fs.open_read(path: string): integer | nil, string
  -- TODO: a descriptor a `<close>` variable can hold (a record with
  -- `__close` over the fd), here and in open_write, so a file read or
  -- written in pieces is closed on every way out of its block: callers
  -- write `local f <close> = assert(Fs.open_read(path))` and meet an
  -- integer, which `<close>` refuses.
  local fd, trouble = sys.open(path, sys.O_RDONLY)
  if fd == nil then
    return nil, path .. ": " .. trouble
  end
  return fd, ""
end

--- Opens a file for writing, creating it and emptying it, and returns an
--- integer descriptor rather than an io.open file handle. Use Fs.put and
--- Fs.close; Fs.write is safer when the whole replacement is available.
--- `mode` is the permission bits of a file this call creates, as an
--- integer (0x1a4 for 0644, the default), less the process's umask; an
--- existing file keeps its own.
function Fs.open_write(path: string, mode?: integer): integer | nil, string
  local flags = sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC
  local fd, trouble = sys.open(path, flags, mode or 0x1a4)
  if fd == nil then
    return nil, path .. ": " .. trouble
  end
  return fd, ""
end

--- Reads up to `count` bytes from a descriptor. This is the streaming byte
--- operation in place of io.read; an empty string is the end of the file.
function Fs.take(fd: integer, count: integer): string | nil, string
  local data, trouble = sys.read(fd, count)
  if data == nil then
    return nil, trouble
  end
  return data, ""
end

--- Closes a descriptor returned by Fs.open_read or Fs.open_write; it does not
--- accept a Lua io.close file handle.
function Fs.close(fd: integer): boolean, string
  local ok, trouble = sys.close(fd)
  if not ok then
    return false, trouble
  end
  return true, ""
end

--- Writes bytes to a descriptor, without a newline. Fs.stdout and Fs.stderr
--- are the standard-stream descriptors used instead of io.write/io.output.
function Fs.put(fd: integer, data: string): boolean, string
  return write_all(fd, data, "fs: ")
end

--- Creates a symbolic link at `path` pointing at `target`, which is
--- stored verbatim and never resolved: `ln -s target path`.
function Fs.symlink(target: string, path: string): boolean, string
  local made, trouble = sys.symlink(target, path)
  if not made then
    return false, path .. ": " .. trouble
  end
  return true, ""
end

--- The target of a symbolic link.
function Fs.readlink(path: string): string | nil, string
  local target, trouble = sys.readlink(path)
  if target == nil then
    return nil, path .. ": " .. trouble
  end
  return target, ""
end

--- Sets a path's modification time to `seconds` since the epoch and
--- `ns` nanoseconds after them (default 0), the shape a `Stat` reports
--- it in (`st.mtime`, `st.mtime_ns`), leaving its access time as it
--- is, as `touch -h -m -d` does. Changes the link itself, not its
--- target. `ns` outside [0, 1e9) raises.
function Fs.set_mtime(path: string, seconds: integer, ns?: integer): boolean, string
  if ns ~= nil and (ns < 0 or ns >= 1000000000) then
    error("fs: nanoseconds are outside [0, 1e9)", 2)
  end
  local set, trouble = sys.utimensat(path, nil, nil, seconds, ns)
  if not set then
    return false, path .. ": " .. trouble
  end
  return true, ""
end

--- Flushes a descriptor's data and metadata to storage.
function Fs.fsync(fd: integer): boolean, string
  local ok, trouble = sys.fsync(fd)
  if not ok then
    return false, trouble
  end
  return true, ""
end

--- Copies one regular file's bytes a chunk at a time, so a large file
--- is never held in memory whole.
local function copy_bytes(from: string, to: string): boolean, string
  -- A source swapped for a link, a named pipe or a terminal since its
  -- lstat is refused rather than followed, waited on for a writer, or
  -- taken as this process's terminal.
  local input, open_trouble = sys.open(from,
    sys.O_RDONLY | sys.O_NOFOLLOW | sys.O_NONBLOCK | sys.O_NOCTTY)
  if input == nil then return false, from .. ": " .. open_trouble end
  local st, stat_trouble = sys.fstat(input)
  if st == nil or st.kind ~= "file" then
    local _, _ = Fs.close(input)
    return false, from .. ": " .. (st == nil and stat_trouble or "no longer a regular file")
  end
  -- Exclusive: a name that appeared since the target was checked, a
  -- planted link included, is refused rather than written through.
  local output, create_trouble = sys.open(to,
    sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, 0x180)
  if output == nil then
    local _, _ = Fs.close(input)
    return false, to .. ": " .. create_trouble
  end
  local ok, trouble = true, ""
  while true do
    local chunk, read_trouble = Fs.take(input, 1 << 20)
    if chunk == nil then
      ok, trouble = false, from .. ": " .. read_trouble
      break
    end
    if chunk == "" then break end
    local put, put_trouble = Fs.put(output, chunk)
    if not put then
      ok, trouble = false, to .. ": " .. put_trouble
      break
    end
  end
  -- A read-only source has nothing to lose in closing.
  local _, _ = Fs.close(input)
  local closed, close_trouble = Fs.close(output)
  if not ok then return false, trouble end
  if not closed then return false, to .. ": " .. close_trouble end
  return true, ""
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
function Fs.copy_tree(from: string, to: string): boolean, string
  local present, present_trouble, number = sys.lstat(to)
  if present ~= nil then
    return false, to .. ": already exists"
  elseif number ~= sys.ENOENT then
    return false, to .. ": " .. present_trouble
  end
  local function copy(source: string, target: string): boolean, string
    local st, trouble = sys.lstat(source)
    if st == nil then return false, source .. ": " .. trouble end
    local permissions = st.mode & 0x3ff
    if st.kind == "link" then
      local target_of, link_trouble = Fs.readlink(source)
      if target_of == nil then return false, link_trouble end
      local linked, symlink_trouble = Fs.symlink(target_of, target)
      if not linked then return false, symlink_trouble end
    elseif st.kind == "file" then
      local copied, copy_trouble = copy_bytes(source, target)
      if not copied then return false, copy_trouble end
      local changed, chmod_trouble = Fs.chmod(target, permissions)
      if not changed then return false, chmod_trouble end
    elseif st.kind == "dir" then
      local entries, list_trouble = sys.readdir(source)
      if entries == nil then return false, source .. ": " .. list_trouble end
      local made, mkdir_trouble = sys.mkdir(target, 0x1c0)
      if not made then return false, target .. ": " .. mkdir_trouble end
      for _, name in ipairs(sorted_names(entries)) do
        local copied, why = copy(source .. "/" .. name, target .. "/" .. name)
        if not copied then return false, why end
      end
      -- The directory's own mode last, so a read-only one still took
      -- its entries.
      local changed, chmod_trouble = Fs.chmod(target, permissions)
      if not changed then return false, chmod_trouble end
    else
      return false, source .. ": not a file, directory or symbolic link"
    end
    local timed, time_trouble = sys.utimensat(target, st.atime, st.atime_ns,
      st.mtime, st.mtime_ns)
    if not timed then return false, target .. ": " .. time_trouble end
    return true, ""
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
    return path == "" and "." or "/"
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
--- with a reason when it is not.
function Fs.relative(path: string, directory: string): string | nil, string
  if not Fs.within(path, directory) then
    return nil, path .. ": not within " .. directory
  end
  local base = unslashed(directory)
  local from = #base + 1
  while path:byte(from) == 47 do from = from + 1 end
  local rest = unslashed(path:sub(from))
  if rest == "" then return ".", "" end
  return rest, ""
end

Fs.stdin = 0
Fs.stdout = 1
Fs.stderr = 2

return Fs
