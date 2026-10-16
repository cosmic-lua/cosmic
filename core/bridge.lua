-- The bridge: the only Lua the tree writes by hand rather than compiling from Teal,
-- because it is what makes Teal available. It builds the handful of
-- things the checker ([`checker/tl.tl`], whose Lua the seed supplies)
-- reaches for outside the pure libraries -- `io.open` and the handle it
-- returns, `io.stderr`, `io.type`, `os.getenv`, `package.path` and
-- `package.searchers` -- over the syscall table, so the compiler runs
-- unpatched and never observes that those names are gone. It also holds
-- the modules that exist before any file does, the declarations boot
-- derives from a header (the syscall table's and the raw process table's),
-- and serves them to the checker from memory.
--
-- A boot (`cosmic-core --boot <root> ...`, core/boot.c) loads it from
-- the tree it boots, as it loads the seed's compiler, and runs it with
-- that root; nothing else does. It is part of the core's image
-- fingerprint (build/work.tl), since what it sets the compiler to shapes
-- what a boot compiles. It takes the compiles it needs from the cache
-- every checkout shares where it can, which keeps a boot, and each
-- worker a boot starts, from compiling the same tree again.
local root = ...
local sys = require('cosmic.sys')

local function read_all(path)
  local fd, err = sys.open(path, sys.O_RDONLY)
  if not fd then return nil, err end
  local parts = {}
  while true do
    local chunk, rerr = sys.read(fd, 65536)
    if not chunk then sys.close(fd); return nil, rerr end
    if #chunk == 0 then break end
    parts[#parts + 1] = chunk
  end
  sys.close(fd)
  return table.concat(parts)
end

-- The compiles below are kept in the file every checkout shares,
-- `cache.db` ([`build.shared_compiles`]), in a table of its own,
-- `bridge_v1`. The Teal build keys a compile by its import graph, which
-- a parse of the tree finds, and by the compiler's identity
-- ([`build.compilation`]'s `dependency_keys`): neither exists before the
-- first module is compiled. So a row here is keyed by its inputs
-- themselves, whole or not at all:
--
--   * `compiler`: the Lua that stage one (the seed's) makes of the tree's
--     checker, [`checker/tl.tl`] and each other `checker/*.tl` beside it,
--     keyed by the digests of the seed's Lua, the checker's sources,
--     [`checker/stdlib.d.tl`] and this file.
--   * `modules`: the Lua of every module loaded up to [`build.boot`],
--     keyed by the compiler's key and the digest of every `.tl` and `.h`
--     under the root (`manifest`).
--
-- The manifest is every file a compile here can read. The searcher and
-- the compiler's own (`tl.path`, which only `TL_PATH` could widen)
-- resolve a module name to `<stem>.d.tl`, `<stem>/init.d.tl`,
-- `<stem>.tl` or `<stem>/init.tl` under the root, and the declarations
-- of `declare` are made from headers by [`build.gen_syscalls`], itself a
-- `.tl`. A file added, removed, moved or edited moves the key, so a row
-- never stands for a tree it was not made from. A tree the manifest
-- cannot vouch for (a link to a directory, a directory it cannot list,
-- `TL_PATH` set, even empty) is compiled and keeps nothing.
--
-- The manifest is taken when the first module loads and the modules are
-- read over the seconds after, so a file edited in between would make a
-- row hold code the key does not name. Every file a compile reads is
-- therefore digested as it is read, and the row is kept only if each
-- digest is the manifest's for that path. A file the compile reads that
-- the manifest omits (a `<stem>.lua`, which tl's search opens when
-- nothing else is there, and which a compile of a checked `.tl` never
-- ends up using) keeps the row from being written at all.
--
-- A row also holds the digest of the declarations it was made with,
-- which `declare` has to reproduce before a module is taken from it.
--
-- TODO: keep each module's compile apart, keyed by that module's source
-- and its own closure's, so an edit to one `.tl` compiles only the
-- modules that reach it: today any change to a `.tl` or `.h` under the
-- root makes every module here compile again (some 7 s), for a boot
-- and for the workers it starts. Waits on a way to know a module's
-- closure in plain Lua before compiling it, which the Teal build gets
-- from a parse of the tree ([`build.compilation`]'s `dependency_keys`);
-- recording the files each compile read, and checking their digests at
-- lookup, would give it here.
--
-- A row's Lua runs, so the file is trusted only as [`Fs.cache_dir`] and
-- [`shared_compiles.open`] trust theirs: owned by this user and writable by
-- no one else, as is its directory, and the file never a link. A row
-- whose digest fails is a miss and is deleted. Every other failure to
-- read or write the file is a miss too, and says nothing: the build
-- that follows opens the same file and reports it.
local hash = require('cosmic.internal.hash')
local sqlite = require('cosmic.internal.sqlite')

-- Names the row digests and the keys, so a change to what a row holds
-- or how it is keyed makes every earlier row a miss.
local format = 'bridge-v1'

-- How many rows of each kind the file keeps, the most lately used first:
-- a few whole states of the tree.
local kept_rows = 16

-- How long a statement waits on another run's lock, in nanoseconds, and
-- how long the switch to write-ahead mode is retried.
local wait_ns = 2 * 1000000000
local wal_wait_ns = 3 * 1000000000

-- The statements that make the table. build/cache_formats.tl holds the
-- same ones, and build/bridge_cache_test.tl holds the two to each other.
local schema = {
  'CREATE TABLE IF NOT EXISTS bridge_v1 (key TEXT PRIMARY KEY, ' ..
    'kind TEXT NOT NULL, declared TEXT NOT NULL, payload BLOB NOT NULL, ' ..
    'digest TEXT NOT NULL, size INTEGER NOT NULL, used_ns INTEGER NOT NULL)',
  'CREATE INDEX IF NOT EXISTS bridge_v1_by_use ON bridge_v1 (used_ns)',
}

local function hex(raw)
  return (raw:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

local function sha256(data) return hash.digest('sha256', data) end

-- The raw sha256 of the file at `path`, or nil.
local function file_digest(path)
  local fd = sys.open(path, sys.O_RDONLY)
  if not fd then return nil end
  local hasher = hash.hasher('sha256')
  while true do
    local chunk = sys.read(fd, 1 << 20)
    if not chunk then sys.close(fd); return nil end
    if #chunk == 0 then break end
    hasher:update(chunk)
  end
  sys.close(fd)
  return (hasher:digest())
end

-- The raw sha256 over the path and contents of every `.tl` and `.h`
-- file under `dir`, in name order, and the digest of each by its path
-- under `dir`; or nil where the walk cannot vouch for the tree. `.git`
-- holds none and is not entered.
local function manifest(dir)
  local hasher = hash.hasher('sha256')
  local digests = {}
  local function visit(path, relative)
    local entries = sys.readdir(path)
    if not entries then return false end
    local names = {}
    for name in pairs(entries) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local kind = entries[name]
      local full = path .. '/' .. name
      if kind == 'link' then
        local st = sys.stat(full)
        -- A dangling link resolves nothing. A link to a directory is a
        -- tree the walk does not enter.
        if st and st.kind == 'dir' then return false end
        kind = st and st.kind or nil
      end
      if kind == 'dir' then
        if name ~= '.git' and not visit(full, relative .. name .. '/') then
          return false
        end
      elseif kind == 'file' and (name:sub(-3) == '.tl' or name:sub(-2) == '.h') then
        local digest = file_digest(full)
        if not digest then return false end
        digests[relative .. name] = digest
        hasher:update(relative .. name .. '\0' .. digest)
      end
    end
    return true
  end
  if not visit(dir, '') then return nil end
  return (hasher:digest()), digests
end

-- Whether `name` is set at all, empty or not: the checker takes `TL_PATH`
-- from `os.getenv` and an empty one is a path.
local function is_set(variables, name)
  if variables then return variables[name] ~= nil end
  return sys.getenv(name) ~= nil
end

local function variable(variables, name)
  if variables then return variables[name] or '' end
  return sys.getenv(name) or ''
end

-- Where the cache file is, as [`build.shared_compiles`] places it: the
-- absolute path `COSMIC_BUILD_CACHE` names, else `build/cache.db` in
-- `$XDG_CACHE_HOME/cosmic` or `$HOME/.cache/cosmic`. Answers the path
-- and, for the default, the base directory above `cosmic`; nil when
-- the cache is off (`0`) or has no place.
local function location(variables)
  local named = variable(variables, 'COSMIC_BUILD_CACHE')
  if named == '0' then return nil end
  if named ~= '' then
    if named:sub(1, 1) ~= '/' then return nil end
    return named, nil
  end
  local base = variable(variables, 'XDG_CACHE_HOME')
  if base:sub(1, 1) ~= '/' then
    local home = variable(variables, 'HOME')
    if home:sub(1, 1) ~= '/' then return nil end
    base = home .. '/.cache'
  end
  return base .. '/cosmic/build/cache.db', base
end

-- Whether `path` is a `kind` ("dir" or "file") of this user's that no
-- one else can write. A directory is taken through a link, as
-- [`Fs.cache_dir`] takes it; a file never is.
local function private(path, kind)
  local st
  if kind == 'file' then st = sys.lstat(path) else st = sys.stat(path) end
  return st ~= nil and st.kind == kind and st.uid == sys.getuid() and
    st.mode & 0x12 == 0
end

local function make_dirs(path)
  local st = sys.stat(path)
  if st then return st.kind == 'dir' end
  local parent = path:match('^(.*)/[^/]+$')
  if parent and parent ~= '' and not make_dirs(parent) then return false end
  local made, _, errno = sys.mkdir(path, 0x1ff)
  if made then return true end
  if errno ~= sys.EEXIST then return false end
  st = sys.stat(path)
  return st ~= nil and st.kind == 'dir'
end

-- The cache file's path once it and its directories pass the checks
-- above, or nil. With `create` the directories (0700) and the file
-- (0600, made before SQLite opens it, whoever else is making it) are
-- made first, as [`shared_compiles.open`] does.
local function cache_file(variables, create)
  local path, base = location(variables)
  if not path then return nil end
  local dir = path:match('^(.*)/[^/]+$')
  if dir == '' then dir = '/' end
  if base then
    if create and not make_dirs(base) then return nil end
    local st = sys.stat(base)
    if not st or (st.uid ~= sys.getuid() and st.uid ~= 0) then return nil end
    for _, held in ipairs({ base .. '/cosmic', dir }) do
      if create then sys.mkdir(held, 0x1c0) end
      if not private(held, 'dir') then return nil end
    end
  else
    if create then
      local parent = dir:match('^(.*)/[^/]+$')
      if parent and parent ~= '' and not make_dirs(parent) then return nil end
      sys.mkdir(dir, 0x1c0)
    end
    if not private(dir, 'dir') then return nil end
  end
  if create then
    local fd, _, errno = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, 0x180)
    if fd then
      sys.close(fd)
    elseif errno ~= sys.EEXIST then
      return nil
    end
  end
  if not private(path, 'file') then return nil end
  return path
end

-- Runs one statement with `...` bound in order (a string as text, an
-- integer as an integer, a one-slot table as a blob), answering
-- whether it ran.
local function run(db, sql, ...)
  local statement = db:prepare(sql)
  if not statement then return false end
  for index, value in ipairs({ ... }) do
    local bound
    if type(value) == 'table' then
      bound = statement:bind_blob(index, value[1])
    elseif math.type(value) == 'integer' then
      bound = statement:bind_integer(index, value)
    else
      bound = statement:bind_text(index, value)
    end
    if not bound then statement:finalize(); return false end
  end
  local stepped = statement:step()
  statement:finalize()
  return stepped == 'done' or stepped == 'row'
end

local function clock(which)
  return sys.clock_gettime(which) or 0
end

-- Puts `db` in write-ahead mode so a run's reads never wait on
-- another's write, retrying while another run holds the file, as
-- [`build.shared_sqlite`] does.
local function to_wal(db)
  db:busy_timeout(0)
  local deadline = clock(sys.CLOCK_MONOTONIC) + wal_wait_ns
  while true do
    local statement = db:prepare('PRAGMA journal_mode = WAL')
    local mode = statement and statement:step() == 'row' and statement:bytes(0)
    if statement then statement:finalize() end
    if mode == 'wal' then break end
    if mode or clock(sys.CLOCK_MONOTONIC) >= deadline then return false end
    sys.nanosleep(10000000)
  end
  db:busy_timeout(wait_ns)
  return true
end

-- The digest a row carries: of its key, its declarations' digest and
-- its payload, so a row moved under another key fails it.
local function row_digest(key, declared, payload)
  return hex(sha256(format .. '\n' .. key .. '\n' .. declared .. '\n' .. payload))
end

-- The row of `kind` under `key` in the cache file `path`, as `declared`
-- and `payload`, or nil. A row whose digest fails is deleted.
local function look(path, kind, key)
  local db = sqlite.open(path, true, false, false)
  if not db then return nil end
  db:busy_timeout(wait_ns)
  local found
  local statement = db:prepare('SELECT declared, inflate(payload), digest ' ..
    'FROM bridge_v1 WHERE key = ?1 AND kind = ?2')
  if statement then
    if statement:bind_text(1, key) and statement:bind_text(2, kind) and
        statement:step() == 'row' then
      found = { declared = statement:bytes(0), payload = statement:bytes(1),
        digest = statement:bytes(2) }
    end
    statement:finalize()
  end
  local row
  if found then
    if found.digest == row_digest(key, found.declared, found.payload) then
      row = found
      -- Stamped on every hit, so the rows kept are those lately used
      -- and not only those lately made; a run that cannot take the
      -- lock at once goes without.
      db:busy_timeout(0)
      run(db, 'UPDATE bridge_v1 SET used_ns = ?1 WHERE key = ?2',
        clock(sys.CLOCK_REALTIME), key)
    else
      run(db, 'DELETE FROM bridge_v1 WHERE key = ?1 AND digest = ?2', key, found.digest)
    end
  end
  db:close()
  return row
end

-- Keeps `payload` as the row of `kind` under `key`, in one transaction:
-- a reader sees a whole row or none, and another run writing the same
-- key writes the same bytes. Then drops all but the newest `kept_rows`
-- of the kind. Answers whether it was kept.
local function keep(path, kind, key, declared, payload)
  local db = sqlite.open(path, true, false, false)
  if not db then return false end
  local kept = false
  if to_wal(db) then
    local ready = true
    for _, statement in ipairs(schema) do
      ready = ready and db:exec(statement)
    end
    if ready and db:exec('BEGIN IMMEDIATE') then
      kept = run(db, 'INSERT OR REPLACE INTO bridge_v1 (key, kind, declared, payload, ' ..
          'digest, size, used_ns) VALUES (?1, ?2, ?3, deflate(?4), ?5, ?6, ?7)',
        key, kind, declared, { payload }, row_digest(key, declared, payload), #payload,
        clock(sys.CLOCK_REALTIME)) and
        run(db, 'DELETE FROM bridge_v1 WHERE kind = ?1 AND key NOT IN (SELECT key ' ..
          'FROM bridge_v1 WHERE kind = ?1 ORDER BY used_ns DESC, key LIMIT ?2)',
          kind, kept_rows)
      if kept then kept = db:exec('COMMIT') end
      if not kept then db:exec('ROLLBACK') end
    end
  end
  db:close()
  return kept
end

-- Records `{ name, file, code }` in a payload and back: the Lua of a
-- module, and the file under the root it was compiled from.
local function pack_records(records)
  local parts = {}
  for index, record in ipairs(records) do
    parts[index] = string.pack('<s4s4s4', record.name, record.file, record.code)
  end
  return table.concat(parts)
end

-- The records of a payload by name, or nil for one [`pack_records`]
-- never wrote.
local function unpack_records(payload)
  local ok, records = pcall(function()
    local out, at = {}, 1
    while at <= #payload do
      local name, file, code
      name, file, code, at = string.unpack('<s4s4s4', payload, at)
      out[name] = { file = file, code = code }
    end
    return out
  end)
  if ok then return records end
  return nil
end

-- The key of the compiler's row and the base of the modules' rows: the
-- digests of the Lua of the seed (`seed`, by name, `tl` for the entry),
-- of `source` (the checker's `tl.tl`), of each of `parts` (the checker's
-- other files, in name order), of `declarations` (its `stdlib.d.tl`) and
-- of this file, which sets the compiler's defaults and decides what is
-- kept. The seed's Lua is what stage one runs, so the key names the
-- compiler that made the row, not the release it came from.
-- Nil when one cannot be read, when the cache is off, or when `TL_PATH`
-- is set, which changes where the compiler looks for modules.
--
-- TODO: digest the text of this file that core/boot.c loaded, not a
-- second read of it: an edit between the two keys rows to a file that is
-- not the one running. Waits on core/boot.c handing the bridge the bytes
-- it loaded (`slurp` already reads them whole).
local function make_compiler_key(seed, source, parts, declarations, variables)
  if is_set(variables, 'TL_PATH') or not location(variables) then
    return nil
  end
  local bridge = file_digest(root .. '/core/bridge.lua')
  if not bridge then return nil end
  local seeds = {}
  for _, name in ipairs({ 'checker_wrapper', 'tl' }) do
    seeds[#seeds + 1] = sha256(name .. '\0' .. seed[name])
  end
  for _, part in ipairs(parts) do
    seeds[#seeds + 1] = sha256(part.name .. '\0' .. seed[part.name])
  end
  local sources = {}
  for index, part in ipairs(parts) do
    sources[index] = sha256(part.name .. '\0' .. part.source)
  end
  return hex(sha256(format .. '\ncompiler\n' .. table.concat(seeds) ..
    sha256(source) .. table.concat(sources) .. sha256(declarations) .. bridge))
end

-- Set by `bootstrap` for [`searcher_for`], which keys its modules by it.
local compiler_key = nil

-- The digest of each file under the root that a compile has read, by
-- its path as read, and whether any was read twice as different bytes.
local reads = {}
local torn_reads = false

-- The paths a compile tried to read and could not. A file the manifest
-- lists that was missing then was there when the key was made, and
-- would have been read, or taken first, had it been there now.
local failed_reads = {}

local function note_read(path, text)
  local digest = sha256(text)
  if reads[path] ~= nil and reads[path] ~= digest then torn_reads = true end
  reads[path] = digest
end

local function note_failed(path)
  failed_reads[#failed_reads + 1] = path
end

local function text_handle(text)
  local h = { is_boot_handle = true }
  function h:read() return text end
  function h:close() return true end
  return h
end

local function make_handle(fd)
  local h = { is_boot_handle = true }
  function h:read(what)
    if what ~= '*a' and what ~= 'a' then
      error('the boot handle reads whole files only')
    end
    local parts = {}
    while true do
      local chunk, err = sys.read(fd, 65536)
      if not chunk then return nil, err end
      if #chunk == 0 then break end
      parts[#parts + 1] = chunk
    end
    return table.concat(parts)
  end
  function h:write(...)
    local n = select('#', ...)
    for i = 1, n do
      local data = tostring((select(i, ...)))
      local at = 1
      while at <= #data do
        local put, err = sys.write(fd, data:sub(at))
        if not put then return nil, err end
        at = at + put
      end
    end
    return self
  end
  function h:flush() return self end
  function h:close() return sys.close(fd) end
  return h
end

local shim_io = {
  stdout = make_handle(1),
  stderr = make_handle(2),
  type = function(value)
    if type(value) == 'table' and value.is_boot_handle then
      return 'file'
    end
    return nil
  end,
  open = function(path, mode)
    if mode and mode:find('w') then
      local fd, err = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC)
      if not fd then return nil, err end
      return make_handle(fd)
    end
    -- Read whole, which is all the handle offers, so what the compiler
    -- sees is what [`note_read`] digested.
    local text, err = read_all(path)
    if not text then
      note_failed(path)
      return nil, err
    end
    note_read(path, text)
    return text_handle(text)
  end,
}

-- The pure libraries, read straight out of the global table. The
-- hint a removed name raises is for a program someone wrote; the
-- compiler is not one, and a name it does not find is nil, which
-- is what plain Lua does.
local environment = setmetatable({
  io = shim_io,
  os = { getenv = sys.getenv },
  package = { path = '', searchers = {}, loaded = {} },
}, { __index = function(_, name) return rawget(_G, name) end })

local function complain(file, result)
  local lines = {}
  local function gather(kind, list)
    for _, e in ipairs(list or {}) do
      lines[#lines + 1] = string.format('%s:%d:%d: %s: %s',
        e.filename or file, e.y or 0, e.x or 0, kind, e.msg)
    end
  end
  gather('syntax error', result and result.syntax_errors)
  gather('type error', result and result.type_errors)
  gather('warning', result and result.warnings)
  return table.concat(lines, '\n')
end

-- Modules handed in as text, never written anywhere: the declarations
-- boot generates with build.gen_syscalls (the syscall table's and the
-- raw process table's) before the bridge checks any module, and which
-- every module that requires one is checked against.
local declared = {}
local declared_count = 0
local declared_version = 0

local function declare(name, text)
  if declared[name] == nil then declared_count = declared_count + 1 end
  declared_version = declared_version + 1
  declared[name] = text
end

-- The digest of the declarations made so far, by name.
local function declared_digest()
  local names = {}
  for name in pairs(declared) do names[#names + 1] = name end
  table.sort(names)
  local hasher = hash.hasher('sha256')
  for _, name in ipairs(names) do
    local text = declared[name]
    hasher:update(#name .. ':' .. name .. #text .. ':' .. text)
  end
  return hex((hasher:digest()))
end

-- `variables`, when given, is the variables `COSMIC_BUILD_CACHE`,
-- `XDG_CACHE_HOME`, `HOME` and `TL_PATH` are read from, in place of the
-- process's own.
--
-- Every module loaded is answered from the `modules` row where one
-- stands (see the comment on the cache above), without reading or
-- compiling it. Otherwise it is compiled, and what is compiled up to the
-- loading of [`build.boot`] -- the whole of its closure, which it requires
-- at its top -- is kept as the row. A module loaded after that is
-- compiled and not kept.
local function searcher_for(tl, variables)
  tl.path = root .. '/?.lua;' .. root .. '/?/init.lua'
  local disk_search = tl.search_module
  tl.search_module = function(name, search_all)
    local text = declared[name]
    if text then
      local stem = name:gsub('%.', '/')
      return root .. '/' .. stem .. '.d.tl', text_handle(text)
    end
    return disk_search(name, search_all)
  end
  local env = assert(tl.new_env({ defaults = {
    feat_lax = 'off', gen_compat = 'off', gen_target = '5.4',
  } }))

  local looked = false
  local key = nil          -- of the row, when the cache is on for this tree
  local from = nil         -- the records of the row hit, by name
  local from_declared = ''
  local rewrite = false    -- the row hit disagreed with `declare`
  local sealed = false
  local tree_files = nil   -- the manifest's digest of each file, by path
  local made = {}          -- every module answered, in order

  local function look_up()
    looked = true
    if not compiler_key then return end
    local tree, files = manifest(root)
    if not tree then return end
    tree_files = files
    key = hex(sha256(format .. '\nmodules\n' .. compiler_key .. tree))
    local file = cache_file(variables, false)
    local row = file and look(file, 'modules', key)
    local records = row and unpack_records(row.payload)
    if records then
      from, from_declared = records, row.declared
    end
  end

  -- Whether the declarations `declare` has been given are those the row
  -- was made with. None given yet is a yes: a module loaded before the
  -- first ([`build.gen_syscalls`]) imports none.
  local checked_version, checked = 0, true
  local function declared_agree()
    if declared_version ~= checked_version then
      checked_version = declared_version
      checked = declared_digest() == from_declared
    end
    return checked
  end

  -- Whether every file the compiles read was, byte for byte, the file
  -- the key names.
  local function read_what_the_key_names()
    if torn_reads then return false end
    local prefix = root .. '/'
    for path, digest in pairs(reads) do
      if path:sub(1, #prefix) ~= prefix or tree_files[path:sub(#prefix + 1)] ~= digest then
        return false
      end
    end
    for _, path in ipairs(failed_reads) do
      if path:sub(1, #prefix) == prefix and tree_files[path:sub(#prefix + 1)] ~= nil then
        return false
      end
    end
    return true
  end

  -- Writes the row once [`build.boot`] has loaded, unless it was hit or
  -- some file changed after the key was made.
  local function seal()
    if sealed then return end
    sealed = true
    if key and (not from or rewrite) and read_what_the_key_names() then
      local file = cache_file(variables, true)
      if file then
        keep(file, 'modules', key, declared_digest(), pack_records(made))
      end
    end
    made = nil
  end

  local function remember(name, file, code)
    if not sealed then made[#made + 1] = { name = name, file = file, code = code } end
  end

  return function(name)
    if not looked then look_up() end
    local record = from and from[name]
    if record and declared_count > 0 and not declared_agree() then
      from, record, rewrite = nil, nil, true
    end
    local chunk, file
    if record then
      local err
      chunk, err = load(record.code, '@' .. name, 't')
      if not chunk then error(record.file .. ': ' .. err, 0) end
      file = root .. '/' .. record.file
      remember(name, record.file, record.code)
    else
      local stem = root .. '/' .. name:gsub('%.', '/')
      local relative = name:gsub('%.', '/') .. '.tl'
      file = stem .. '.tl'
      local source = read_all(file)
      if not source then note_failed(file) end
      if not source then
        local dir_file = stem .. '/init.tl'
        source = read_all(dir_file)
        if not source then
          note_failed(dir_file)
          return "\n\tno file '" .. file .. "'" ..
            "\n\tno file '" .. dir_file .. "'"
        end
        file = dir_file
        relative = name:gsub('%.', '/') .. '/init.tl'
      end
      note_read(file, source)
      local code, result = tl.gen(source, env, nil, 'tl')
      local trouble = complain(file, result)
      if not code or trouble ~= '' then
        error(file .. ': the compiler refused it\n' .. trouble, 0)
      end
      local err
      chunk, err = load(code, '@' .. name, 't')
      if not chunk then error(file .. ': ' .. err, 0) end
      remember(name, relative, code)
    end
    if name == 'build.boot' then
      local loader = chunk
      chunk = function(...)
        local results = table.pack(loader(...))
        seal()
        return table.unpack(results, 1, results.n)
      end
    end
    return chunk, file
  end
end

-- The checker's files other than its entry, `file`: every `<identifier>.tl`
-- beside it (not a declaration file, nor an editor's leftover), in name order, as
-- `{ name, file, source }`, the `name` a `require` in the entry spells
-- (`checker.flow` for [`checker/flow.tl`]) and `file` its path under the root.
-- Answers nil and why when the directory cannot be read.
local function checker_parts(file)
  local directory, entry = file:match('^(.*)/([^/]*)$')
  directory = directory or '.'
  entry = entry or file
  local base = directory:match('([^/]*)$')
  local names, err = sys.readdir(directory)
  if not names then return nil, directory .. ': ' .. tostring(err) end
  local list = {}
  for name in pairs(names) do list[#list + 1] = name end
  table.sort(list)
  local parts = {}
  for _, name in ipairs(list) do
    if name ~= entry and name:match('^[%a_][%w_]*%.tl$') then
      local path = directory .. '/' .. name
      local source, read_err = read_all(path)
      if not source then return nil, path .. ': ' .. tostring(read_err) end
      parts[#parts + 1] = { name = base .. '.' .. name:sub(1, -4),
        file = base .. '/' .. name, path = path, source = source }
    end
  end
  return parts
end

-- What a seed directory holds, read: the Lua `cosmic compile` wrote for
-- the checker's entry and for each of `parts`, by the name `parts` and the
-- bootstrap use (`tl` for the entry), and for [`build/checker_wrapper.tl`],
-- `checker_wrapper`. Answers nil and why when one cannot be read.
local function read_seed(seed_dir, parts)
  local seed = {}
  local names = { { 'tl', 'tl' }, { 'checker_wrapper', 'checker_wrapper' } }
  for _, part in ipairs(parts) do
    names[#names + 1] = { part.name, part.name:match('([^.]*)$') }
  end
  for _, name in ipairs(names) do
    local path = seed_dir .. '/' .. name[2] .. '.lua'
    local text, err = read_all(path)
    if not text then
      return nil, path .. ': ' .. tostring(err) .. ' (the seed step of build.zig writes it)'
    end
    seed[name[1]] = text
  end
  return seed
end

-- The wrapper that joins the checker's parts into the Lua the tool
-- carries: [`build/checker_wrapper.tl`], which the seed compiled to the
-- Lua in `text`. Its `wrapped(code, declarations, modules)` is the one
-- copy of that logic: the first stage is wrapped by it, so is the second,
-- and so is the compiler build/compiler_test.tl builds.
local function load_wrapper(text)
  local chunk, load_err = load(text, '@build/checker_wrapper.tl', 't')
  if not chunk then error('the seed\'s checker_wrapper: ' .. load_err, 0) end
  local wrapper = chunk()
  if type(wrapper) ~= 'table' or type(wrapper.wrapped) ~= 'function' then
    error('the seed\'s checker_wrapper returned no `wrapped`', 0)
  end
  return wrapper.wrapped
end

-- The seed's output files that the tree declares differ from what the
-- checker compiles itself to, as a set by file name: the lines of
-- `checker/SEED_DIFFERS`, which a change to what the generator writes adds
-- (naming the files whose Lua it changes) and a move of
-- ci/cosmic-driver.pin to a release carrying that change removes
-- (doc/contributing.md). Empty when the file is absent.
local function seed_differs_declared()
  local declared = {}
  local text = read_all(root .. '/checker/SEED_DIFFERS')
  for line in (text or ''):gmatch('[^\n]+') do
    local name = line:match('^%s*(.-)%s*$')
    if name ~= '' then declared[name] = true end
  end
  return declared, text ~= nil
end

-- The compiler the tree is built with and the tool carries: the tree's
-- own checker, the Teal file at `file` (checker/tl.tl) and the Teal files
-- beside it, in two stages. The seed is the Lua that the pinned release
-- wrote for them (`seed_dir`, build.zig's seed step); wrapped as the tool
-- carries it and loaded in the compiler's environment, it is stage one,
-- and stage one compiles the same files again to stage two, which is
-- what the tool carries and runs. Stage two is the tree's own generator
-- applied to the tree's own source, whatever generator wrote the seed,
-- so the carried compiler never depends on the pin's emitter, and the
-- compiler compiles itself to the same Lua (build/compiler_test.tl).
-- Answers the compiler and the Lua it was compiled to.
--
-- Stage one equals stage two when the generator writes what the pinned
-- release's does, which is checked here, since only a boot holds a seed
-- made from the files it compiles: a seed that miscompiles, or a
-- generator changed without `checker/SEED_DIFFERS` saying so, fails the
-- boot naming the files; so does that file once the two agree.
--
-- The entry requires the other files by name (`require("checker.flow")`),
-- which stage one finds as text, never on disk, and each compiles to a
-- chunk of its own with the locals of its own. They ride in the Lua the
-- entry is carried in, where the entry's `require` finds them.
--
-- The Lua standard library's declarations, `stdlib.d.tl` beside `file`,
-- ride in that Lua as well: it starts with `local stdlib = "<their text>"`
-- on its first line, the local the checker's `stdlib` is.
--
-- What stage one makes of the checker is kept in the cache
-- (`compiler_key`); the first line is put in front of it either way.
local function bootstrap(seed_dir, file, variables)
  local source, err = read_all(file)
  if not source then error(file .. ': ' .. tostring(err), 0) end
  local directory = file:match('^(.*)/[^/]*$') or '.'
  local declarations_file = directory .. '/stdlib.d.tl'
  local declarations, declarations_err = read_all(declarations_file)
  if not declarations then
    error(declarations_file .. ': ' .. tostring(declarations_err), 0)
  end
  local parts, parts_err = checker_parts(file)
  if not parts then error(parts_err, 0) end
  local seed, seed_err = read_seed(seed_dir, parts)
  if not seed then error(seed_err, 0) end
  local wrapped = load_wrapper(seed.checker_wrapper)
  local function carried(code)
    local modules = {}
    for index, part in ipairs(parts) do
      modules[index] = { part.name, part.code, part.file }
    end
    return wrapped(code, declarations, modules)
  end
  compiler_key = make_compiler_key(seed, source, parts, declarations, variables)
  local code
  if compiler_key then
    local cached = cache_file(variables, false)
    local row = cached and look(cached, 'compiler', compiler_key)
    local records = row and unpack_records(row.payload)
    code = records and records.tl and records.tl.code
    for _, part in ipairs(parts) do
      part.code = records and records[part.name] and records[part.name].code
      if not part.code then code = nil end
    end
  end
  if not code then
    -- Stage one: the seed, wrapped as the tool carries a compiler.
    for _, part in ipairs(parts) do part.code = seed[part.name] end
    local first_chunk, first_err = load(carried(seed.tl), '@seed.tl', 't', environment)
    if not first_chunk then error(seed_dir .. ': ' .. first_err, 0) end
    local stage1 = first_chunk()
    stage1.path = ''
    -- Only a syntax error stops it: the checker's source does not obey
    -- the rules the checker holds a program to, and build/compiler_test.tl
    -- pins its type errors.
    local function compile(path, text)
      local env = assert(stage1.new_env({ defaults = {
        feat_lax = 'off', gen_compat = 'off', gen_target = '5.4',
      } }))
      local made, result = stage1.gen(text, env, nil, 'tl')
      local syntax = result and result.syntax_errors or {}
      if #syntax > 0 or not made then
        error(path .. ': the checker, compiled from the seed in ' .. seed_dir ..
          ', refused it\n' .. complain(path, { syntax_errors = syntax }), 0)
      end
      return made
    end
    -- The entry's `require` of a part is answered with the part's text.
    local by_name = {}
    for _, part in ipairs(parts) do by_name[part.name] = part end
    local disk_search = stage1.search_module
    stage1.search_module = function(name, search_all)
      local part = by_name[name]
      if part then return part.path, text_handle(part.source) end
      return disk_search(name, search_all)
    end
    local compiled, failure = pcall(function()
      code = compile(file, source)
      for _, part in ipairs(parts) do part.code = compile(part.path, part.source) end
    end)
    stage1.search_module = disk_search
    if not compiled then error(failure, 0) end
    local made = compiler_key and cache_file(variables, true)
    if made then
      local records = { { name = 'tl', file = 'checker/tl.tl', code = code } }
      for _, part in ipairs(parts) do
        records[#records + 1] = { name = part.name, file = part.file, code = part.code }
      end
      keep(made, 'compiler', compiler_key, '', pack_records(records))
    end
  end
  local differ = {}
  if code ~= seed.tl then differ['tl.lua'] = true end
  for _, part in ipairs(parts) do
    if part.code ~= seed[part.name] then
      differ[part.name:match('([^.]*)$') .. '.lua'] = true
    end
  end
  local declared, present = seed_differs_declared()
  local function listed(set)
    local names = {}
    for name in pairs(set) do names[#names + 1] = name end
    table.sort(names)
    return table.concat(names, ', ')
  end
  -- The names the seed writes: an entry is one of them, bare.
  local written = { ['tl.lua'] = true }
  for _, part in ipairs(parts) do written[part.name:match('([^.]*)$') .. '.lua'] = true end
  for name in pairs(declared) do
    if not written[name] then
      error(name .. ' names no file the seed writes: list bare output names, ' ..
        'e.g. tl.lua (checker/SEED_DIFFERS)', 0)
    end
  end
  local undeclared, stale = {}, {}
  for name in pairs(differ) do
    if not declared[name] then undeclared[name] = true end
  end
  for name in pairs(declared) do
    if not differ[name] then stale[name] = true end
  end
  if next(undeclared) then
    error('the seed in ' .. seed_dir .. ' differs from the checker compiled by ' ..
      'itself in ' .. listed(undeclared) .. ': a seed that miscompiles, or a ' ..
      'change to what the generator writes, which checker/SEED_DIFFERS declares ' ..
      '(one file name a line) until ci/cosmic-driver.pin names a release that ' ..
      'carries it', 0)
  elseif next(stale) then
    error('checker/SEED_DIFFERS declares that the seed in ' .. seed_dir ..
      ' differs in ' .. listed(stale) .. ', and it does not: remove ' ..
      'that from the file, and the file once it names nothing', 0)
  elseif present and not next(declared) then
    error('checker/SEED_DIFFERS names no file: remove it', 0)
  end
  local chunk, load_err = load(carried(code), '@vendor.tl', 't', environment)
  if not chunk then error(file .. ': ' .. load_err, 0) end
  return chunk(), carried(code)
end

return { environment = environment, searcher_for = searcher_for,
         declare = declare, bootstrap = bootstrap, schema = schema }
