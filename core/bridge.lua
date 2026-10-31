-- The bridge is the only Lua the tree writes by hand rather than compiling from Teal, because it is what makes Teal
-- available. A boot (`cosmic-core --boot <root> ...`, core/boot.c) loads it from the tree it boots and runs it with that
-- root. It builds, over the syscall table, the compiler a boot needs in two stages, and then the searcher that answers
-- `require` for the build's code from that compiler:
--
--   * The SEED is a directory holding the Lua the pinned release wrote for the files of [`build/seed.txt`] (build.zig's
--     `seedCompiler`), each as `<basename>.lua`: build/seed.tl and the files it requires. Stage one loads it, every
--     module by the name its path gives, in an environment of its own.
--   * Stage one compiles the same files again, from the tree, to stage two, which the bridge compares with the seed. The
--     tool never depends on the pin's emitter: it is the tree's own generator applied to the tree's own source. A file
--     whose Lua stage two writes otherwise than the seed does must be named in `lang/SEED_DIFFERS`, one path a line (a
--     change to what the generator writes adds it; the move of ci/cosmic-driver.pin to a release carrying the change
--     removes it). A seed that `COSMIC_BOOTSTRAP` names instead of the pin is not held to a listed file that does not
--     differ (the boot of the tree by its own tool); the pinned seed is.
--   * Stage two is loaded the same way, as [`build.seed`]: its `program(root, declared)` is a build of the new checker over
--     the tree, and the searcher answers `build.*` and the rest up to [`build.boot`] with the Lua it writes, a module at
--     a time. Type errors are not refused (the tree's checks hold the code to its ceilings); a syntax error and a
--     construct the generator does not write are.
--
-- The compiles are kept in the file every checkout shares where the cache is on, in a table of its own, `bridge_v2`
-- (build/cache_formats.tl lists the tables the file holds):
--
--   * `compiler`: stage two's Lua for the seed's files, keyed by the digests of the seed's Lua, of the files' sources,
--     of the seed list and of this file.
--   * `modules`: the Lua of every module loaded up to [`build.boot`], keyed by the compiler's key and the digest of
--     every `.tl` and `.h` under the root (`manifest`). A row is kept only if the tree is, after the load, the tree the
--     key names.
--
-- A row also holds the digest of the declarations it was made with, which `declare` has to reproduce before a module is
-- taken from it. A row's Lua runs, so the file is trusted only as [`Fs.cache_dir`] and [`shared_compiles.open`] trust
-- theirs: owned by this user and writable by no one else, as is its directory, and the file never a link. A row whose
-- digest fails is a miss and is deleted. Every other failure to read or write the file is a miss too, and says nothing.
--
-- TODO: keep each module's compile apart, keyed by that module's source and its own closure's, so an edit to one `.tl`
-- compiles only the modules that reach it: today any change to a `.tl` or `.h` under the root makes every module here
-- compile again. Waits on the program telling a module's closure before it is compiled.
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

local hash = require('cosmic.internal.hash')
local sqlite = require('cosmic.internal.sqlite')

-- Names the row digests and the keys, so a change to what a row holds
-- or how it is keyed makes every earlier row a miss.
local format = 'bridge-v2'

-- How many rows of each kind the file keeps, the most lately used first:
-- a few whole states of the tree.
local kept_rows = 16

-- How long a statement waits on another run's lock, in nanoseconds, and
-- how long the switch to write-ahead mode is retried.
local wait_ns = 2 * 1000000000
local wal_wait_ns = 3 * 1000000000

-- The statements that make the table.
--
-- build/cache_formats.tl holds the same statements.
local schema = {
  'CREATE TABLE IF NOT EXISTS bridge_v2 (key TEXT PRIMARY KEY, ' ..
    'kind TEXT NOT NULL, declared TEXT NOT NULL, payload BLOB NOT NULL, ' ..
    'digest TEXT NOT NULL, size INTEGER NOT NULL, used_ns INTEGER NOT NULL)',
  'CREATE INDEX IF NOT EXISTS bridge_v2_by_use ON bridge_v2 (used_ns)',
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
    'FROM bridge_v2 WHERE key = ?1 AND kind = ?2')
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
      run(db, 'UPDATE bridge_v2 SET used_ns = ?1 WHERE key = ?2',
        clock(sys.CLOCK_REALTIME), key)
    else
      run(db, 'DELETE FROM bridge_v2 WHERE key = ?1 AND digest = ?2', key, found.digest)
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
      kept = run(db, 'INSERT OR REPLACE INTO bridge_v2 (key, kind, declared, payload, ' ..
          'digest, size, used_ns) VALUES (?1, ?2, ?3, deflate(?4), ?5, ?6, ?7)',
        key, kind, declared, { payload }, row_digest(key, declared, payload), #payload,
        clock(sys.CLOCK_REALTIME)) and
        run(db, 'DELETE FROM bridge_v2 WHERE kind = ?1 AND key NOT IN (SELECT key ' ..
          'FROM bridge_v2 WHERE kind = ?1 ORDER BY used_ns DESC, key LIMIT ?2)',
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

-- The records of a payload by name, or nil for one `pack_records`
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


-- Timing and memory of a boot, when `COSMIC_BRIDGE_TRACE` is set: one line on standard error for each step.
local tracing = (sys.getenv('COSMIC_BRIDGE_TRACE') or '') ~= ''
local trace_started = sys.clock_gettime(sys.CLOCK_MONOTONIC) or 0

-- The peak size of the process in MB, where the system says (Linux does, in /proc), else 0.
local function peak_megabytes()
  local text = read_all('/proc/self/status')
  local kilobytes = text and text:match('VmHWM:%s*(%d+)')
  return kilobytes and tonumber(kilobytes) / 1024 or 0
end

local function trace(message)
  if not tracing then return end
  local now = sys.clock_gettime(sys.CLOCK_MONOTONIC) or 0
  sys.write(2, string.format('bridge: %6.2f s  heap %7.1f MB  peak %7.1f MB  %s\n',
    (now - trace_started) / 1e9, collectgarbage('count') / 1024, peak_megabytes(), message))
end

-- The directory `COSMIC_BRIDGE_DUMP` names, where every module the program compiles is written as `<module>.lua`, for a
-- comparison with the Lua another compile wrote of the same module.
local dump_directory = sys.getenv('COSMIC_BRIDGE_DUMP') or ''

local function dump(name, code)
  if dump_directory == '' then return end
  local fd = sys.open(dump_directory .. '/' .. name .. '.lua', sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC, 420)
  if not fd then return end
  sys.write(fd, code)
  sys.close(fd)
end

-- The file of this bridge below the root, which the keys digest: it decides what is kept and how the stages run.
local self_file = 'core/bridge.lua'

-- Where the seed list and the declared differences are, below the root.
local seed_list_file = 'build/seed.txt'
local seed_differs_file = 'lang/SEED_DIFFERS'

-- The module a path below the root is: [`lang/ast.tl`] is [`lang.ast`], `a/init.tl` is `a`.
local function module_of(relative)
  local stem = relative:gsub('%.d%.tl$', ''):gsub('%.tl$', ''):gsub('/init$', '')
  return (stem:gsub('/', '.'))
end

-- The lines of the seed list, in order, as paths below the root; or nil and why.
local function read_seed_list()
  local path = root .. '/' .. seed_list_file
  local text, err = read_all(path)
  if not text then return nil, path .. ': ' .. tostring(err) end
  local list, seen = {}, {}
  for line in text:gmatch('[^\n]+') do
    local relative = line:match('^%s*(.-)%s*$')
    if relative ~= '' then
      if not relative:match('%.tl$') or relative:match('%.d%.tl$') or relative:find('^/') or
          relative:find('%.%.') then
        return nil, path .. ': ' .. relative .. ' is no .tl file below the root'
      end
      local stem = relative:match('([^/]*)%.tl$')
      if seen[stem] then
        return nil, path .. ': ' .. relative .. ' and ' .. seen[stem] ..
          ' are both written as ' .. stem .. '.lua'
      end
      seen[stem] = relative
      list[#list + 1] = relative
    end
  end
  if #list == 0 then return nil, path .. ': it names no file' end
  return list
end

-- The files `lang/SEED_DIFFERS` lists, as a set, and whether the file is there. One source path a line.
local function seed_differs_declared()
  local declared = {}
  local text = read_all(root .. '/' .. seed_differs_file)
  for line in (text or ''):gmatch('[^\n]+') do
    local name = line:match('^%s*(.-)%s*$')
    if name ~= '' then declared[name] = true end
  end
  return declared, text ~= nil
end

-- The pure libraries, read straight out of the global table. A name the code does not find is nil, which is what plain
-- Lua does.
local function environment_with(require_function)
  return setmetatable({ require = require_function },
    { __index = function(_, name) return rawget(_G, name) end })
end

-- A `require` over `codes`, a table from module name to `{ file, code }`: a module in it is loaded once, in an
-- environment whose `require` is this one, and any other is the process's own (the bindings of C). The chunk is
-- called with the module's name and file, as `require` calls one. `label` names whose Lua it is, for a failure.
local function requirer(codes, label)
  local loaded = {}
  local env
  local function require_module(name)
    local held = loaded[name]
    if held ~= nil then return held end
    local record = codes[name]
    if not record then return require(name) end
    local chunk, err = load(record.code, '@' .. record.file, 't', env)
    if not chunk then error(label .. ': ' .. err, 0) end
    local result = chunk(name, record.file)
    if result == nil then result = true end
    loaded[name] = result
    return result
  end
  env = environment_with(require_module)
  return require_module
end

-- The complaint of a compile of one file, a line for each syntax error and for the generator's refusal.
local function complain(file, result)
  local lines = {}
  for _, e in ipairs(result.syntax_errors or {}) do
    lines[#lines + 1] = string.format('%s:%d:%d: syntax error: %s', file, e.y or 0, e.x or 0, e.msg)
  end
  if (result.trouble or '') ~= '' then
    lines[#lines + 1] = file .. ': the generator wrote no Lua: ' .. result.trouble
  end
  return table.concat(lines, '\n')
end

-- The key of the compiler's row and the base of the modules' rows: the digests of the seed's Lua and of the sources of
-- each file of `list` (`seed` and `sources`, by path), each with its path and in the order of the list, and of this file. The seed's Lua is what
-- stage one runs, so the key names the compiler that made the row, not the release it came from. Nil when one cannot
-- be read or when the cache is off.
--
-- TODO: digest the text of this file that core/boot.c loaded, not a second read of it: an edit between the two keys
-- rows to a file that is not the one running. Waits on core/boot.c handing the bridge the bytes it loaded.
local function make_compiler_key(list, seed, sources, variables)
  if not location(variables) then
    return nil
  end
  local bridge = file_digest(root .. '/' .. self_file)
  if not bridge then return nil end
  local parts = {}
  for index, relative in ipairs(list) do
    parts[index] = sha256(relative .. '\0' .. seed[relative]) .. sha256(sources[relative])
  end
  return hex(sha256(format .. '\ncompiler\n' .. table.concat(parts) .. bridge))
end

-- Set by `bootstrap` for `searcher_for`, which keys its modules by it.
local compiler_key = nil

-- Modules handed in as text, never written anywhere: the declarations boot generates with build.gen_syscalls (the
-- syscall table's and the raw process table's) before the bridge checks any module, and which every module that
-- requires one is checked against. The program reads this table when a module is asked for.
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

-- The names of the files whose Lua differs between `a` and `b`, both by path, in the order of `list`.
local function differing(list, a, b)
  local out = {}
  for _, relative in ipairs(list) do
    if a[relative] ~= b[relative] then out[#out + 1] = relative end
  end
  return out
end

-- The file names a source path a line ([`lang/codegen.tl`]); build/lang_proof.tl, which holds the same file to the proof of lang/, reads
-- that spelling and its older bare output names (`codegen.lua`) both.

-- Holds the files whose Lua stage two writes otherwise than the seed does to `lang/SEED_DIFFERS`, both ways. Raises
-- the complaint, naming the files, for a seed that miscompiles or a change to the generator the file does not declare,
-- for a file it lists that does not differ, for a name that is no file of the seed list and for an empty file.
--
-- A seed that `COSMIC_BOOTSTRAP` names is not the pinned release, and a file the list holds that does not differ is not
-- refused then: the tree's own tool as the seed compiles every file as stage two does, so no entry can differ, while
-- the boot with the pin still refuses a stale entry and so takes it out at the pin move. A difference the list does
-- not hold is refused for any seed: the tool can be older than the tree's generator, and the entry is still due.
local function hold_to_declared(list, seed, stage_two, seed_dir, variables)
  local differ = {}
  for _, relative in ipairs(differing(list, stage_two, seed)) do differ[relative] = true end
  local listed_files, present = seed_differs_declared()
  local function joined(set)
    local names = {}
    for name in pairs(set) do names[#names + 1] = name end
    table.sort(names)
    return table.concat(names, ', ')
  end
  local written = {}
  for _, relative in ipairs(list) do written[relative] = true end
  for name in pairs(listed_files) do
    if not written[name] then
      error(name .. ' names no file of ' .. seed_list_file .. ': list the path of a source, ' ..
        'e.g. lang/codegen.tl (' .. seed_differs_file .. ')', 0)
    end
  end
  local undeclared, stale = {}, {}
  for name in pairs(differ) do
    if not listed_files[name] then undeclared[name] = true end
  end
  if variable(variables, 'COSMIC_BOOTSTRAP') == '' then
    for name in pairs(listed_files) do
      if not differ[name] then stale[name] = true end
    end
  end
  if next(undeclared) then
    error('the seed in ' .. seed_dir .. ' differs from the build compiled by itself in ' .. joined(undeclared) ..
      ': a seed that miscompiles, or a change to what the generator writes, which ' .. seed_differs_file ..
      ' declares (one source path a line) until ci/cosmic-driver.pin names a release that carries it', 0)
  elseif next(stale) then
    error(seed_differs_file .. ' declares that the seed in ' .. seed_dir .. ' differs in ' .. joined(stale) ..
      ', and it does not: remove that from the file, and the file once it names nothing', 0)
  elseif present and not next(listed_files) then
    error(seed_differs_file .. ' names no file: remove it', 0)
  end
end

-- The compiler a boot builds the tool with: [`build/seed.tl`], the file at `entry`, and the files it requires, listed in
-- [`build/seed.txt`], in two stages (see the top of this file). `seed_dir` is the directory of the seed (build.zig's seed
-- step). Answers the module stage two makes of the entry, which has `compile` and `program` ([`build.seed`]).
--
-- Only a syntax error or a refusal of the generator stops stage one. The files do not obey the rules the new checker
-- holds a program to when they are compiled without the standard library's declarations, which the seed is not given.
local function bootstrap(seed_dir, entry, variables)
  local prefix = root .. '/'
  if entry:sub(1, #prefix) ~= prefix then
    error(entry .. ' is not below the root ' .. root, 0)
  end
  local entry_relative = entry:sub(#prefix + 1)
  local list, list_err = read_seed_list()
  if not list then error(list_err, 0) end
  local listed = false
  for _, relative in ipairs(list) do listed = listed or relative == entry_relative end
  if not listed then error(entry_relative .. ' is not in ' .. seed_list_file, 0) end
  local sources, seed = {}, {}
  for _, relative in ipairs(list) do
    local text, err = read_all(root .. '/' .. relative)
    if not text then error(relative .. ': ' .. tostring(err), 0) end
    sources[relative] = text
    local path = seed_dir .. '/' .. relative:match('([^/]*)%.tl$') .. '.lua'
    local lua, lua_err = read_all(path)
    if not lua then
      error(path .. ': ' .. tostring(lua_err) .. ' (the seed step of build.zig writes it)', 0)
    end
    seed[relative] = lua
  end
  trace('read the seed list: ' .. #list .. ' files')

  compiler_key = make_compiler_key(list, seed, sources, variables)
  local stage_two
  if compiler_key then
    local cached = cache_file(variables, false)
    local row = cached and look(cached, 'compiler', compiler_key)
    local records = row and unpack_records(row.payload)
    if records then
      stage_two = {}
      for _, relative in ipairs(list) do
        stage_two[relative] = records[relative] and records[relative].code
        if not stage_two[relative] then stage_two = nil; break end
      end
    end
  end
  if stage_two then
    trace('stage two: taken from the cache')
  else
    -- Stage one: the seed, each file a module by the name its path gives.
    local codes = {}
    for _, relative in ipairs(list) do
      codes[module_of(relative)] = { file = relative, code = seed[relative] }
    end
    local stage_one = requirer(codes, 'the seed in ' .. seed_dir)(module_of(entry_relative))
    if type(stage_one) ~= 'table' or type(stage_one.compile) ~= 'function' then
      error(entry_relative .. ' in the seed in ' .. seed_dir .. ' has no `compile`', 0)
    end
    trace('stage one: loaded')
    local files = {}
    for index, relative in ipairs(list) do
      files[index] = { path = relative, relative = relative, text = sources[relative], declaration = false }
    end
    local results = stage_one.compile(files)
    stage_two = {}
    local refused = {}
    for index, relative in ipairs(list) do
      local result = results[index]
      if not result or not result.code then
        refused[#refused + 1] = complain(relative, result or {})
      else
        stage_two[relative] = result.code
      end
    end
    if #refused > 0 then
      error('the new checker, compiled from the seed in ' .. seed_dir .. ', refused its own source\n' ..
        table.concat(refused, '\n'), 0)
    end
    trace('stage two: compiled by stage one')
    local made = compiler_key and cache_file(variables, true)
    if made then
      local records = {}
      for index, relative in ipairs(list) do
        records[index] = { name = relative, file = relative, code = stage_two[relative] }
      end
      keep(made, 'compiler', compiler_key, '', pack_records(records))
    end
  end
  hold_to_declared(list, seed, stage_two, seed_dir, variables)

  local codes = {}
  for _, relative in ipairs(list) do
    codes[module_of(relative)] = { file = relative, code = stage_two[relative] }
  end
  local program = requirer(codes, 'the new checker')(module_of(entry_relative))
  if type(program) ~= 'table' or type(program.program) ~= 'function' then
    error(entry_relative .. ' compiled by itself has no `program`', 0)
  end
  trace('stage two: loaded')
  return program
end

-- `stage_two`, the entry that `bootstrap` answered, makes the searcher for `require`: every module loaded is answered
-- from the `modules` row where one stands (see the top of this file), without reading or compiling it. Otherwise it is
-- compiled, and what is compiled up to the loading of [`build.boot`] -- the whole of its closure, which it requires at
-- its top -- is kept as the row. A module loaded after that is compiled and not kept.
--
-- `variables`, when given, is the variables `COSMIC_BUILD_CACHE`, `XDG_CACHE_HOME` and `HOME` are read from, in place
-- of the process's own.
local function searcher_for(stage_two, variables)
  local looked = false
  local key = nil          -- of the row, when the cache is on for this tree
  local tree = nil         -- the manifest's digest of the tree the key names
  local from = nil         -- the records of the row hit, by name
  local from_declared = ''
  local rewrite = false    -- the row hit disagreed with `declare`
  local sealed = false
  local made = {}          -- every module answered, in order
  local program = nil      -- made when a module is not in the row
  local compiled, compile_ns = 0, 0

  local function look_up()
    looked = true
    if not compiler_key then return end
    local digest = manifest(root)
    if not digest then return end
    tree = digest
    key = hex(sha256(format .. '\nmodules\n' .. compiler_key .. digest))
    local file = cache_file(variables, false)
    local row = file and look(file, 'modules', key)
    local records = row and unpack_records(row.payload)
    if records then
      from, from_declared = records, row.declared
    end
  end

  -- Whether the declarations `declare` has been given are those the row was made with. None given yet is a yes: a
  -- module loaded before the first ([`build.gen_syscalls`]) imports none.
  local checked_version, checked = 0, true
  local function declared_agree()
    if declared_version ~= checked_version then
      checked_version = declared_version
      checked = declared_digest() == from_declared
    end
    return checked
  end

  -- Writes the row once [`build.boot`] has loaded, unless it was hit or the tree is no longer the one the key names.
  local function seal()
    if sealed then return end
    sealed = true
    trace(string.format('build.boot loaded: %d modules compiled in %.2f s', compiled, compile_ns / 1e9))
    if key and (not from or rewrite) and manifest(root) == tree then
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
      chunk, err = load(record.code, '@' .. name, 't', _G)
      if not chunk then error(record.file .. ': ' .. err, 0) end
      file = root .. '/' .. record.file
      remember(name, record.file, record.code)
    else
      program = program or stage_two.program(root, declared)
      local started = sys.clock_gettime(sys.CLOCK_MONOTONIC) or 0
      local module, trouble = program.module(name)
      compile_ns = compile_ns + ((sys.clock_gettime(sys.CLOCK_MONOTONIC) or 0) - started)
      if not module then
        if (trouble or '') ~= '' then
          error(trouble, 0)
        end
        return "\n\tno source for '" .. name .. "' below " .. root
      end
      compiled = compiled + 1
      file = root .. '/' .. module.file
      local err
      chunk, err = load(module.code, '@' .. name, 't', _G)
      if not chunk then error(module.file .. ': ' .. err, 0) end
      dump(name, module.code)
      remember(name, module.file, module.code)
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

return { searcher_for = searcher_for, declare = declare, bootstrap = bootstrap, schema = schema,
         module_of = module_of }
