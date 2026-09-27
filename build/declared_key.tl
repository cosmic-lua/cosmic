--- A sandboxed test's verdict key: a digest of what the test was given
--- (`build.test_sandbox`), computed before it runs, from its declared
--- inputs alone (`build.test_inputs`), rather than of what it was seen
--- to read, and a verdict under it stands with no observation to replay.
---
--- A sandboxed worker reads its declared inputs, and besides them what
--- every worker is given (`observations.worker_unveil`): the system's
--- own paths (/usr, /bin, /lib, /etc and the like), /dev, /proc, the
--- program and its core, and a store at o/cosmic.db, held as below;
--- and it runs as whoever runs the tests, with their capabilities. The
--- key holds the rest by the host's identity (`host_identity`) and the
--- runtime's, not by their contents: what is left out is in the TODOs
--- on `host_identity`. It may not run this program unless it declares
--- `tool` (`observations.forbid_running`), which runs the tool's own
--- modules, which no key of the test holds but o/bin's.
---
--- The key is the digest of
---
--- - the test: its module's path and its name (`id`);
--- - the test harness every worker runs, as the running binary carries
---   it (`harness`, and `build.test`'s `harness_roots`) --
---   COSMIC_TEST_HARNESS_SALT, for a test alone, stands in for a change
---   to it;
--- - what runs it: the runtime identity -- the core's digest, its
---   platform and configuration, and the Teal and Lua pins -- the
---   digest of the binary's data tables and the `sandboxed` mark
---   (`runtime`), and the compiler (`compiler`, `build.work`'s
---   `Identities`), which compiled every module of the closure and is
---   what build.teal loads as bytecode; and, where an artifact runs it
---   (o/bin/cosmic, or a portable cosmic), what runs that core
---   (`launcher_identity`);
--- - the host it runs on (`host_identity`): its packages, its system and
---   kernel, the user and capabilities the tests run with, and which
---   /proc a sandbox gets;
--- - the module's key (`build.importer`), over its import graph's
---   sources, the standard library's included, and the compiler;
--- - the declaration itself, as `test_inputs.canonical` spells it;
--- - the contents of every input it declares or is given by default:
---   each file of its import closure; each path of the tree it `reads`
---   and the fuzz corpora, a file by its contents and a directory by
---   its listing and every entry's contents beneath it; o/bin when it
---   declares `tool`, each program in it -- and the program that runs
---   it (`program_identity`) -- by its image and the rows it carries,
---   but for those every edit of the tree moves (`program`); the
---   projection, o/cosmic.db, when it declares `store`, and else the
---   address of the store of its closure it is given there in the
---   projection's place; and each `host` path;
--- - the environment its worker is given (`test_sandbox.environment`):
---   the pinned variables and the declared ones, all of them for `"*"`.
---
--- The host caches it declares are not: they are content-addressed,
--- and never change a result (`build.caches`). Nor are the variables
--- the runner adds to start a worker at all (`Proc.relaunch`'s, and
--- COSMIC_COVERAGE_STARTUP): they name where the core is and which
--- descriptors it is handed, which the runtime identity holds already,
--- and would name where this host keeps its cache in every key. A test
--- that declares `network` beyond loopback hosts has no key that holds
--- what it reached, and always runs; nor does one that reads a declared directory holding a
--- link that leads out of the tree, which a sandbox follows to what
--- the key would not hold.
---
--- Nothing in a key names where the tree is -- a path of it is keyed by
--- its name there, and a variable's value, each of its `:`-separated
--- parts, by `observations.tree_name` -- so another checkout of the same
--- content reaches the same key, and a verdict is shared by it alone
--- (`build.shared_verdicts`).
---
--- Files are hashed once a run, and a file whose `lstat` says the same
--- as when a run last hashed it is not read at all: `Digests` remembers
--- each hash by what `lstat` said of the file, its change time included,
--- and o/build.db keeps them from run to run.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local artifact = require("build.artifact")
local observations = require("build.filesystem_observations")
local test_inputs = require("build.test_inputs")

local record declared_key
  --- What a run knows of the files it keys, kept for the run.
  record Digests
    root: string
    --- `root` with its links resolved.
    real_root: string
    --- Each file's hash by its absolute path, with what `lstat` said of
    --- it when it was hashed: `signature` .. "\0" .. hex sha256.
    hashed: {string:string}
    --- The paths of `hashed` this run looked up, which `kept` answers.
    used: {string:boolean}
    --- Each program's key (`program`) too fresh to keep in `hashed`, as
    --- `hashed` holds it, for this run alone.
    this_run: {string:string}
    --- While set, each answer by what asked for it: the whole
    --- selection of a run keys its tests before any of them starts, so
    --- one answer serves them all. Nil after, when each asks again.
    snapshot: {string:string}
    --- How many files were read to be hashed, and the time spent keying.
    read: integer
    spent_ns: integer
  end

  --- What one test's key is made of.
  record Spec
    id: string
    --- What names the tests whose specs are the same but for `id`:
    --- their module's path.
    group: string
    module_key: string
    runtime: string
    compiler: string
    --- The test harness a worker runs, as the running binary carries it
    --- (`harness`): every worker runs it, the tree's or not.
    harness: string
    --- The program a test that runs this program runs
    --- (`program_identity`): o/bin/cosmic, or o/sanitized's, or a
    --- portable cosmic, whichever is running.
    program: string
    --- The host's identity (`host_identity`).
    host: string
    --- Where an artifact runs the tests (Store.meta's
    --- `runtime_context` "portable-v1": o/bin/cosmic, or a portable
    --- cosmic), what runs its core (`launcher_identity`); nil where a
    --- host program does, whose core is all there is ahead of its
    --- database.
    launcher: string
    --- The module's declaration, as `test_inputs.canonical` spells it.
    declaration: string
    effective: test_inputs.Effective
    --- The environment its worker is given.
    environment: {string:string}
    --- Whether its worker may run this program though its module does
    --- not declare `tool` (`build.test`'s `can_forbid`): o/bin is keyed
    --- as if it did.
    runs_tool: boolean
    --- The address of the store of its module's import closure its
    --- worker is given at o/cosmic.db where its module does not declare
    --- `store` (`build.writer`'s `closure_address`), or nil where it is
    --- given the whole projection, keyed by its contents.
    closure_store: string
  end

  --- Where `host_identity` looks, for a test: each a path, but
  --- `machine`, `own_proc`, whether a sandbox gets a /proc of its own,
  --- `host_id`, the value of `host_variable`, and `uid`.
  record HostSources
    packages: {string}
    system: {string}
    status: string
    cpuinfo: string
    --- The machine whose features `cpuinfo` keys (`dispatched`).
    machine: string
    own_proc: boolean
    host_id: string
    uid: integer
  end
end

--- A file modified this recently may be modified again within the same
--- timestamp tick, which `lstat` would not tell: hashed again rather
--- than remembered, as `build.work` stages it.
local settle_ns <const> = 2 * 1000 * 1000 * 1000

--- What `lstat` says of a file that its hash is remembered by: its
--- size, modification and change times, inode and device. The change
--- time is what no write can set back, as `touch -r` or `cp -p` sets
--- the modification time back over a rewrite of the same size.
local function signature(st: sys.Stat): string
  return tostring(st.size) .. " " .. tostring(st.mtime * 1000000000 + st.mtime_ns) .. " " ..
    tostring(st.ctime * 1000000000 + st.ctime_ns) .. " " .. tostring(st.ino) .. " " ..
    tostring(st.dev)
end

--- A run's digests of the tree at `root`, seeded with `remembered`, what
--- `kept` answered in an earlier run -- absolute path, what `lstat` said,
--- sha256.
-- The build's staged hashes are not taken: its stage keeps no change
-- time, so a file rewritten in place with its modification time set
-- back would answer the hash it had before.
function declared_key.digests(root: string, remembered?: {{string}}): declared_key.Digests
  local hashed: {string:string} = {}
  for _, row in ipairs(remembered or {}) do hashed[row[1]] = row[2] .. "\0" .. row[3] end
  local real, _ = sys.realpath(root)
  return { root = root, real_root = real or root, hashed = hashed, used = {}, this_run = {},
    read = 0, spent_ns = 0 }
end

--- What of `digests` a later run is to remember, as `digests` takes it:
--- each file this run looked up whose hash it holds, by path, sorted.
function declared_key.kept(digests: declared_key.Digests): {{string}}
  local out: {{string}} = {}
  for path in pairs(digests.used) do
    local was = digests.hashed[path]
    local said, hash = (was or ""):match("^([^\0]*)\0(%x+)$")
    if said ~= nil then out[#out + 1] = { path, said, hash } end
  end
  table.sort(out, function(a: {string}, b: {string}): boolean return a[1] < b[1] end)
  return out
end

--- Starts answering each question once, for a selection of a run.
function declared_key.freeze(digests: declared_key.Digests)
  digests.snapshot = {}
end

--- Stops: from here each question is asked of the tree again.
function declared_key.thaw(digests: declared_key.Digests)
  digests.snapshot = nil
end

--- The hex sha256 of the regular file at `path`, which `st` describes,
--- from `digests` where it was hashed at the same `lstat`.
local function contents(digests: declared_key.Digests, path: string, st: sys.Stat): string
  local said = signature(st)
  digests.used[path] = true
  local was = digests.hashed[path]
  if was ~= nil and was:sub(1, #said + 1) == said .. "\0" then return was:sub(#said + 2) end
  local data, _ = Fs.read(path)
  digests.read = digests.read + 1
  if data == nil then return "unreadable" end
  local hash = Hash.hex_sha256(data)
  if st.mtime * 1000000000 + st.mtime_ns < Time.now_ns() - settle_ns then
    digests.hashed[path] = said .. "\0" .. hash
  end
  return hash
end

--- The rows of a carried database that move with the whole tree, not
--- with what the program carrying it does: `boot_hash`, a digest of
--- every file the tool's trees hold, its tests' included, and
--- `projected`, the signature of the whole projection it was written
--- from. What reads them at run time compares them with a value the
--- same binary carries, or with a tree's own fingerprint, which at test
--- time is the tree the binary was built from (a stale tool rebuilds
--- before it tests, or refuses) and in a fixture is a tree of the
--- test's own; or names a cache entry by them, or prints them -- none
--- turns a verdict (see `program`).
local tree_wide_meta <const> = "('boot_hash', 'projected')"

--- The digest of every row the SQLite database `database` holds, and
--- its schema, but for `tree_wide_meta`: each table's rows in order of
--- their quoted values, so the digest turns on what the rows are, not on
--- the pages they were written to. A virtual table is left to the shadow
--- tables that hold its rows. Nil and why where it cannot be read.
local function carried_digest(database: string): string | nil, string
  -- TODO: read the database in place, through a VFS over a range of a
  -- file other than the running artifact's, once cosmic.sqlite opens
  -- one (core/vfs.c opens the running artifact's alone): today it is
  -- copied out to a scratch file, as build.refresh does.
  local scratch, scratch_trouble = Fs.mkdtemp("cosmic-program-")
  if scratch == nil then return nil, scratch_trouble end
  local path = scratch .. "/carried.db"
  local answer: string = nil
  local trouble = ""
  local written, write_trouble = Fs.write(path, database)
  if not written then
    trouble = write_trouble
  else
    local db, open_trouble = Sqlite.open(path, false)
    if db == nil then
      trouble = open_trouble
    else
      local lines: {string} = {}
      local schema, schema_trouble = Sqlite.text_rows(db,
        "SELECT type, name, coalesce(sql, '') FROM sqlite_schema ORDER BY type, name")
      if schema == nil then trouble = schema_trouble end
      for _, row in ipairs(schema or {}) do
        lines[#lines + 1] = row[1] .. " " .. row[2] .. " " .. row[3]
        if row[1] == "table" and row[2]:sub(1, 7) ~= "sqlite_" and
            row[3]:upper():sub(1, 20) ~= "CREATE VIRTUAL TABLE" then
          local quoted = row[2]:gsub('"', '""')
          local columns, columns_trouble = Sqlite.text_rows(db,
            "SELECT name FROM pragma_table_info(?1) ORDER BY cid", { { text = row[2] } })
          if columns == nil then
            trouble = columns_trouble
            break
          end
          -- Each value by its type and its bytes: quote() ends a text
          -- at its first NUL, which a blob's hex does not.
          local parts: {string} = {}
          -- And a rowid table's rowids, which a read in no other order
          -- (ca_roots', zoneinfo's) turns on.
          if not row[3]:upper():find("WITHOUT%s+ROWID") then parts[1] = "quote(rowid)" end
          for _, column in ipairs(columns) do
            local named = '"' .. column[1]:gsub('"', '""') .. '"'
            parts[#parts + 1] = "typeof(" .. named .. ") || ':' || quote(CASE WHEN typeof(" ..
              named .. ") = 'text' THEN CAST(" .. named .. " AS BLOB) ELSE " .. named .. " END)"
          end
          local where = row[2] == "meta" and (" WHERE key NOT IN " .. tree_wide_meta) or ""
          local digest, digest_trouble = Sqlite.text_rows(db,
            "SELECT lower(hex(sha256(coalesce(group_concat(r, char(10) ORDER BY r), '')))) " ..
            "FROM (SELECT " .. table.concat(parts, " || ',' || ") .. ' AS r FROM "' ..
            quoted .. '"' .. where .. ")")
          if digest == nil then
            trouble = digest_trouble
            break
          end
          lines[#lines + 1] = "rows " .. row[2] .. " " .. digest[1][1]
        end
      end
      local _, _ = db:close()
      if trouble == "" then answer = Hash.hex_sha256(table.concat(lines, "\n")) end
    end
  end
  local _, _ = Fs.remove_tree(scratch)
  if answer == nil then return nil, trouble end
  return answer, ""
end

--- The digest `compute` makes of the regular file `name` names after
--- its first NUL, which `st` describes, remembered in `digests` under
--- `name` by what `lstat` said, as `contents` remembers a file's hash.
local function remembered(digests: declared_key.Digests, name: string, st: sys.Stat,
                          compute: function(data: string): string): string
  local said = signature(st)
  digests.used[name] = true
  local was = digests.hashed[name] or digests.this_run[name]
  if was ~= nil and was:sub(1, #said + 1) == said .. "\0" then return was:sub(#said + 2) end
  local data, _ = Fs.read(name:match("^[^\0]*\0(.*)$"))
  digests.read = digests.read + 1
  if data == nil then return "unreadable" end
  local hash = compute(data)
  if st.mtime * 1000000000 + st.mtime_ns < Time.now_ns() - settle_ns then
    digests.hashed[name] = said .. "\0" .. hash
  else
    -- Too fresh to keep for a later run, but a program just rebuilt is
    -- keyed again as each test ends: this run takes it again by the
    -- same `lstat`, a rebuild publishing a new file, not a rewrite.
    digests.this_run[name] = said .. "\0" .. hash
  end
  return hash
end

--- What the regular file at `path`, which `st` describes, runs as, for
--- a key: where it is an artifact (`artifact.split`), the digest of
--- everything ahead of its database -- the launcher, the cores and
--- their manifest -- whether it is a host program, and the rows it
--- carries (`carried_digest`), which is all a run of it can turn on;
--- else the digest of its contents. Remembered in `digests` as a file's
--- hash is, under a name of its own.
---
--- So a program rebuilt from a tree whose edit moved nothing it carries
--- -- a comment in a test, which no binary carries -- keys the same,
--- though `tree_wide_meta` moved every byte of its database's meta.
--- What reads those rows, and why none can turn a verdict:
---
--- - `boot_hash`: build.reboot compares it with the fingerprint of the
---   tree a run is in -- cosmic's own tree only (`build.tree`'s
---   `is_own`) -- which is the running tool's own tree at test time,
---   since a run rebuilds a stale tool before it tests, or refuses; a
---   fixture's tree is a test's own, whose fingerprint matches only a
---   tree holding every file of the tool's trees, each of which that
---   test would declare, and each keyed by it. build.writer's `running`
---   and build.importer's `receivers_identity` ask the same question of
---   the tree, or only whether there is one; `analyzer_identity` and
---   `receivers_identity` name the binary by it only where it carries
---   no source for its analyzer, which a built binary does; the value
---   names a cache entry (build.standalone's `cached_path`), and the
---   bill of materials' version (build.bom), which only moves a name;
---   and an unsandboxed verdict's identity (build.test's `identity_of`),
---   which a sandboxed key is not.
--- - `projected`: build.writer reads it from a projection it wrote, to
---   skip writing the same one again, never from a binary.
---
--- And every sandboxed worker runs this same binary, with these same
--- rows in reach of `Store.meta`, whether its test declares `tool` or
--- not, and no key of one that does not has ever held them.
local function program(digests: declared_key.Digests, path: string, st: sys.Stat): string
  return remembered(digests, "program\0" .. path, st, function(data: string): string
    local split, _ = artifact.split(data)
    if split == nil then return Hash.hex_sha256("file\n" .. data) end
    local carried, _ = carried_digest(split.database)
    -- Unreadable, it is keyed by its bytes alone, as any other file --
    -- not by why, which may name a scratch path no other run shares.
    return Hash.hex_sha256(carried ~= nil and ("artifact\n" .. tostring(split.host) .. "\n" ..
      Hash.hex_sha256(split.head) .. "\n" .. carried) or ("unread\n" .. data))
  end)
end

--- What of the artifact at `path` runs every test of a run it starts,
--- whether the test runs the program or not: everything ahead of its
--- database -- the launcher that selects and checks a core, the cores
--- and their manifest -- and whether it is a host program, as a digest;
--- its contents' where it is no artifact, "missing" where it is not a
--- regular file. Remembered in `digests` as `program` is. The runtime
--- identity (`Spec.runtime`) holds the core a run selects, but not what
--- selected it: a key of a run an artifact starts holds this too
--- (`Spec.launcher`).
function declared_key.launcher_identity(digests: declared_key.Digests, path: string): string
  local st, _ = sys.stat(path)
  if st == nil or st.kind ~= "file" then return "missing" end
  return remembered(digests, "launcher\0" .. path, st, function(data: string): string
    local split, _ = artifact.split(data)
    if split == nil then return Hash.hex_sha256("file\n" .. data) end
    return Hash.hex_sha256("head\n" .. tostring(split.host) .. "\n" .. split.head)
  end)
end

--- What one entry is, for its line in a key: "missing", "file" and its
--- contents' hash -- "file+x" when anyone may run it -- "link" and its
--- target, unfollowed, "dir" or "other". `follow` describes what a link
--- at `path` itself leads to, as a bind of it does. A file is keyed as
--- a `program` where `programs` says to.
local function entry(digests: declared_key.Digests, path: string, follow: boolean,
                     programs?: boolean): string, string
  local st, _ = (follow and sys.stat or sys.lstat)(path)
  if st == nil then return "missing", "missing" end
  if st.kind == "file" then
    local runnable = st.mode & 73 ~= 0 -- 0o111
    return "file", (runnable and "file+x " or "file ") ..
      (programs and ("program " .. program(digests, path, st)) or contents(digests, path, st))
  elseif st.kind == "link" then
    local target, _ = sys.readlink(path)
    return "link", "link " .. (target or "unreadable")
  elseif st.kind == "dir" then
    return "dir", "dir"
  end
  return "other", "other"
end

--- Remembered in `digests.snapshot`, while there is one, under `tag`.
local function once(digests: declared_key.Digests, tag: string,
                    compute: function(): string): string
  local snapshot = digests.snapshot
  if snapshot == nil then return compute() end
  local answer = snapshot[tag]
  if answer == nil then
    answer = compute()
    snapshot[tag] = answer
  end
  return answer
end

--- Why the link at `path`, in `directory`, leads where a key does not
--- follow it -- out of the tree, where a sandbox finds what it leads to
--- if it was given that too (the system's own paths among them) -- or
--- nil: one that leads within the tree is keyed by where it leads, as
--- what is there is keyed where it is given, and is nothing where it is
--- not. Judged by where it resolves, and by its target as written where
--- it resolves nowhere.
local function leads_out(digests: declared_key.Digests, path: string,
                         directory: string): string | nil
  local real, _ = sys.realpath(path)
  if real ~= nil then
    if Fs.within(real, digests.real_root) then return nil end
    return path .. " leads out of the tree, to " .. real
  end
  local target, _ = sys.readlink(path)
  if target == nil then return nil end
  local lexical = test_inputs.plain(target:sub(1, 1) == "/" and target or
    (directory .. "/" .. target))
  if Fs.within(lexical, digests.root) or Fs.within(lexical, digests.real_root) then return nil end
  return path .. " leads out of the tree, to " .. target
end

--- What `path` holds, followed where it is a link, as a sandbox binds
--- it: an entry's answer, or for a directory "dir" and the digest of
--- every entry beneath it, links unfollowed, in name order -- each by
--- its name beneath `path`, what it is and what it holds; each file as
--- a `program` where `programs` says to.
local function tree(digests: declared_key.Digests, path: string, programs?: boolean): string
  return once(digests, (programs and "p\0" or "t\0") .. path, function(): string
    local kind, answer = entry(digests, path, true, programs)
    if kind ~= "dir" then return answer end
    local lines: {string} = {}
    local refused: string = nil
    local function walk(directory: string, prefix: string, depth: integer)
      local listed, trouble = sys.readdir(directory)
      if listed == nil then
        lines[#lines + 1] = prefix .. "\0unlisted " .. trouble
        return
      end
      local names: {string} = {}
      for name in pairs(listed) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do
        local here = directory .. "/" .. name
        local named = prefix == "" and name or (prefix .. "/" .. name)
        local what, said = entry(digests, here, false, programs)
        lines[#lines + 1] = named .. "\0" .. said
        if what == "link" and refused == nil then refused = leads_out(digests, here, directory) end
        if said == "dir" then
          -- Deeper than a walk goes is keyed as what could not be seen.
          if depth >= 128 then
            lines[#lines + 1] = named .. "\0too deep"
          else
            walk(here, named, depth + 1)
          end
        end
      end
    end
    walk(path, "", 0)
    if refused ~= nil then return "refused " .. refused end
    return "dir " .. Hash.hex_sha256(table.concat(lines, "\n"))
  end)
end

--- What a path outside the tree holds, as a key keeps it: a file by its
--- contents, and anything else by what it is.
-- TODO: key a host directory by what it holds -- /usr's entries' stamps
-- take half a second to walk, every run -- once something cheaper
-- answers for it (a package database's stamp, or a digest the host
-- keeps): today a directory is keyed by its name alone, and a verdict
-- stands across an update of what it holds, as it does across one of
-- the kernel.
local function host(digests: declared_key.Digests, path: string): string
  return once(digests, "h\0" .. path, function(): string
    local _, answer = entry(digests, path, true)
    return answer
  end)
end

--- `relative`, a path of the tree as a declaration names it, as
--- `test_inputs.plain` spells it, and where it is under the tree: ""
--- for one that names no place in it, which a sandbox does not give
--- either.
local function of_tree(digests: declared_key.Digests, relative: string): string, string
  local plain = test_inputs.plain(relative)
  if plain == "." then return plain, digests.root end
  if plain:sub(1, 1) == "/" or plain == ".." or plain:sub(1, 3) == "../" then return plain, "" end
  return plain, digests.root .. "/" .. plain
end

--- The digest of what a test of `spec` is given, but for its name.
local inputs_of: function(declared_key.Digests, declared_key.Spec): string

--- The key of the test `spec` describes, over what `digests` finds now,
--- or nil and why there is none: a declared directory holds a link out
--- of the tree (`leads_out`).
function declared_key.compute(digests: declared_key.Digests,
                              spec: declared_key.Spec): string | nil, string
  local started = Time.monotonic_ns()
  -- All but the test's name is its module's, and the same for each of
  -- its tests: digested once, while a snapshot holds.
  local inputs = once(digests, "m\0" .. spec.group, function(): string
    return inputs_of(digests, spec)
  end)
  digests.spent_ns = digests.spent_ns + (Time.monotonic_ns() - started)
  if inputs:sub(1, 8) == "refused " then return nil, inputs:sub(9) end
  return Hash.hex_sha256("declared-3\n" .. observations.key_part("i", spec.id, "") .. "\n" ..
    inputs), ""
end

--- A variable's value as a key holds it: each of its `:`-separated
--- parts that is a path of the tree by its name there
--- (`observations.tree_name`), as PATH's are.
local function held_value(value: string, root: string): string
  local parts: {string} = {}
  for part in (value .. ":"):gmatch("([^:]*):") do
    parts[#parts + 1] = observations.tree_name(part, root)
  end
  return table.concat(parts, ":")
end

--- The digest of what `spec`'s test is given, but for its name.
inputs_of = function(digests: declared_key.Digests, spec: declared_key.Spec): string
  local part = observations.key_part
  local effective = spec.effective
  local lines: {string} = {
    part("m", spec.module_key, ""),
    part("runtime", spec.runtime, ""),
    part("compiler", spec.compiler, ""),
    part("harness", spec.harness or "", ""),
    part("host", spec.host, ""),
    part("declaration", spec.declaration, ""),
  }
  if spec.launcher ~= nil then lines[#lines + 1] = part("launcher", spec.launcher, "") end
  local files: {string} = {}
  for file in pairs(effective.files) do files[#files + 1] = file end
  table.sort(files)
  for _, file in ipairs(files) do
    local plain, path = of_tree(digests, file)
    local answer = path ~= "" and once(digests, "f\0" .. path, function(): string
      local _, said = entry(digests, path, true)
      return said
    end) or "outside"
    lines[#lines + 1] = part("f", plain, answer)
  end
  local reads: {string} = {}
  for _, read in ipairs(effective.reads) do reads[#reads + 1] = read end
  if effective.tool or spec.runs_tool then
    -- o/bin, as its sandbox gives it, each program in it by what it
    -- runs as rather than its bytes (`program`): a rebuild that moved
    -- only what the whole tree's edits move leaves it.
    local _, bin = of_tree(digests, "o/bin")
    local answer = tree(digests, bin, true)
    if answer:sub(1, 8) == "refused " then return answer end
    lines[#lines + 1] = part("tool", "o/bin", answer)
    -- And what actually runs, which need not be o/bin/cosmic.
    lines[#lines + 1] = part("program", spec.program or "", "")
  end
  -- The store its worker is given at o/cosmic.db: the whole projection,
  -- by its contents, where the module declares `store`; else the store
  -- of its closure, by its address, which is a digest of all its bytes
  -- follow from -- so neither an edit to a module outside the closure
  -- nor adding or removing one moves it (`build.writer`'s
  -- `closure_address`). The names of the tree's modules a worker
  -- refuses a `require` of are no part of it: a name there only turns
  -- such a `require` into a refusal, never into a load.
  if effective.store then
    reads[#reads + 1] = "o/cosmic.db"
  elseif spec.closure_store ~= nil then
    lines[#lines + 1] = part("store", spec.closure_store, "")
  end
  table.sort(reads)
  local seen: {string:boolean} = {}
  for _, read in ipairs(reads) do
    local plain, path = of_tree(digests, read)
    if not seen[plain] then
      seen[plain] = true
      local answer = path ~= "" and tree(digests, path) or "outside"
      if answer:sub(1, 8) == "refused " then return answer end
      lines[#lines + 1] = part("r", plain, answer)
    end
  end
  local hosts: {string} = {}
  for _, path in ipairs(effective.host) do hosts[#hosts + 1] = test_inputs.plain(path) end
  table.sort(hosts)
  for _, path in ipairs(hosts) do
    if not seen[path] then
      seen[path] = true
      lines[#lines + 1] = part("h", path, host(digests, path))
    end
  end
  local names: {string} = {}
  for name in pairs(spec.environment) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    lines[#lines + 1] = part("e", name, held_value(spec.environment[name], digests.root))
  end
  return Hash.hex_sha256(table.concat(lines, "\n"))
end

--- The processor's features a core running on `machine` chooses code
--- by, which is all a key holds of what /proc/cpuinfo lists:
--- `host_identity` says which code reads each, and
--- build/dispatched_features_test.tl holds the vendored sites to this.
--- A machine not named here, whose cores no audit has read, keys its
--- whole list.
local dispatched: {string:{string:boolean}} = {
  x86_64 = { aes = true, pclmulqdq = true, ssse3 = true, sse4_1 = true, fma = true,
    avx2 = true, fma4 = true },
  aarch64 = { asimd = true, aes = true, pmull = true, crc32 = true },
}

--- The features a core on `machine` chooses code by (`dispatched`), in
--- byte order, or nil for a machine no audit has read, whose key holds
--- every feature; with no `machine`, the machines audited, in byte
--- order.
function declared_key.dispatched(machine?: string): {string}
  local kept: {string:boolean} = {}
  if machine == nil then
    for name in pairs(dispatched) do kept[name] = true end
  else
    kept = dispatched[machine]
    if kept == nil then return nil end
  end
  local sorted: {string} = {}
  for flag in pairs(kept) do sorted[#sorted + 1] = flag end
  table.sort(sorted)
  return sorted
end

--- The processor's features `cpuinfo` (/proc/cpuinfo by default) lists
--- -- "flags" on x86, "Features" on arm -- each once, in byte order,
--- less those a core on `machine` (this host's, by default) chooses no
--- code by (`dispatched`).
local function features(cpuinfo?: string, machine?: string): {string}
  local text, _ = Fs.read(cpuinfo or "/proc/cpuinfo")
  local seen: {string:boolean} = {}
  for line in (text or ""):gmatch("[^\n]+") do
    local listed = line:match("^flags%s*:%s*(.*)$") or line:match("^Features%s*:%s*(.*)$")
    for flag in (listed or ""):gmatch("%S+") do seen[flag] = true end
  end
  if machine == nil then
    local names, _ = sys.uname()
    machine = names ~= nil and names.machine or nil
  end
  local kept = machine ~= nil and dispatched[machine] or nil
  local sorted: {string} = {}
  for flag in pairs(seen) do
    if kept == nil or kept[flag] then sorted[#sorted + 1] = flag end
  end
  table.sort(sorted)
  return sorted
end

--- The files that say which packages this host has installed: dpkg's,
--- apk's and rpm's databases, where each keeps them.
local package_databases: {string} = {
  "/var/lib/dpkg/status", "/lib/apk/db/installed", "/var/lib/rpm/rpmdb.sqlite",
  "/usr/lib/sysimage/rpm/rpmdb.sqlite", "/var/lib/rpm/Packages",
}

--- The variable a host names more of itself in than `host_identity`
--- finds there: CI's legs, the container they run in -- its image, the
--- seccomp profile and options it is started with, the container
--- engine's version -- which no file inside it tells.
local host_variable <const> = "COSMIC_HOST_ID"

--- What of this host every sandboxed worker is given without declaring
--- it, as a key holds it: the database of the packages it has installed
--- (`package_databases`), by contents, where there is one; the system it
--- says it is (/etc/os-release) and its kernel's release and version;
--- its name and machine; the processor's features a core chooses code
--- by (/proc/cpuinfo's flags, each once, `dispatched`); the user,
--- groups and capabilities this process -- and so every worker -- runs
--- with, and whether no_new_privs and a seccomp filter hold it
--- (/proc/self/status); whether a sandbox gets a /proc of its own
--- (`observations.own_proc_given`); and what the host says of itself
--- besides (`host_variable`). Worked out once a run; the
--- package database is hashed only when its `lstat` moves. `sources`
--- moves where it looks, for a test; a field it leaves nil is this
--- host's own. Of these, what differs between runners of one CI leg --
--- the processor's features and the kernel -- names the leg's verdict
--- cache too (`host_features`, .github/scripts/host-features.sh): a
--- change to how either is keyed changes both, and the script.
-- TODO: key what a package database does not say: a file under /usr,
-- /etc or /lib changed by hand or by a tool other than the package
-- manager, a package installed from source into /usr/local, and a
-- container image's own layers where no `host_variable` names the
-- image. Wants a walk of the system's paths cheap enough to take every
-- run (/usr's stamps take half a second). Nor is the clock keyed: a
-- test whose verdict turns on the date stands on one reached another
-- day, which only a forced run (CI's scheduled one) catches.
function declared_key.host_identity(digests: declared_key.Digests,
                                    sources?: declared_key.HostSources): string
  local started = Time.monotonic_ns()
  local from: declared_key.HostSources = sources or {}
  local lines: {string} = {}
  for _, path in ipairs(from.packages or package_databases) do
    local st, _ = sys.stat(path)
    if st ~= nil and st.kind == "file" then
      lines[#lines + 1] = "packages " .. path .. " " .. contents(digests, path, st)
      break
    end
  end
  for _, path in ipairs(from.system or { "/etc/os-release", "/proc/sys/kernel/osrelease",
                                         "/proc/sys/kernel/version" }) do
    local text, _ = Fs.read(path)
    lines[#lines + 1] = path .. " " .. (text or "missing")
  end
  local names, _ = sys.uname()
  if names ~= nil then lines[#lines + 1] = "uname " .. names.sysname .. " " .. names.machine end
  -- Each distinct feature once, sorted: every processor lists them.
  -- Only those the code a test runs chooses code by (`dispatched`),
  -- which an audit of the vendored C and the disassembled cores found:
  -- mbedtls's aesni.c (`aes`, `pclmulqdq`) and aesce.c (`asimd`, `aes`,
  -- `pmull`); xz's crc_x86_clmul.h (`pclmulqdq`, `ssse3`, `sse4_1`) and
  -- crc32_arm64.h (`crc32`); and, for the checked core, which links
  -- glibc's libm where it is built on a glibc host, its pow, asin, acos
  -- and atan2, whose FMA variants (`fma` with `avx2`, else `fma4` for
  -- asin, acos and atan2) round a last bit otherwise. The other libm
  -- functions it imports, frexp and ldexp, have no variants, and
  -- atan2's `avx` one only re-encodes SSE and changes no result, so
  -- `avx` is not keyed. No grep finds glibc's choices, which are in the
  -- host's libm, not the tree: this comment is their record. Nothing
  -- else the core carries dispatches, nor does its build, so the
  -- processor's model and microcode, which choose no code, are not
  -- keyed either. The whole list split GitHub's hosted runners of one
  -- leg on flags nothing reads (avx512*, a hypervisor's bits,
  -- md_clear), each split a verdict not shared. A vendored library that
  -- comes to dispatch on another feature adds it to `dispatched` and to
  -- .github/scripts/host-features.sh alike.
  lines[#lines + 1] = "cpu " .. table.concat(features(from.cpuinfo, from.machine), " ")
  lines[#lines + 1] = "uid " .. tostring(from.uid or sys.getuid())
  local status, _ = Fs.read(from.status or "/proc/self/status")
  for line in (status or ""):gmatch("[^\n]+") do
    local name = line:match("^(%a+):")
    if name == "Uid" or name == "Gid" or name == "Groups" or (name ~= nil and
        name:sub(1, 3) == "Cap") or name == "NoNewPrivs" or name == "Seccomp" then
      lines[#lines + 1] = line
    end
  end
  local own = from.own_proc
  if own == nil then own = observations.own_proc_given() end
  lines[#lines + 1] = "own proc " .. tostring(own)
  local host_id = from.host_id
  if host_id == nil then host_id = sys.getenv(host_variable) or "" end
  lines[#lines + 1] = "host " .. host_id
  digests.spent_ns = digests.spent_ns + (Time.monotonic_ns() - started)
  return Hash.hex_sha256(table.concat(lines, "\n"))
end

--- What of `host_identity` differs between runners of one CI leg, as
--- the first 16 hex digits of a sha256: the processor's features, a
--- line each (`features`), then the kernel's release and version as
--- their files hold them, a missing one as empty. It is what
--- .github/scripts/host-features.sh prints, which names a Linux leg's
--- verdict cache, so a run restores one whose keys its host reaches.
--- `sources` moves where it looks (`cpuinfo`, `machine`, and
--- `system`'s second and third paths), for a test.
function declared_key.host_features(sources?: declared_key.HostSources): string
  local from: declared_key.HostSources = sources or {}
  local system = from.system or { "/etc/os-release", "/proc/sys/kernel/osrelease",
                                  "/proc/sys/kernel/version" }
  local parts: {string} = {}
  for _, flag in ipairs(features(from.cpuinfo, from.machine)) do
    parts[#parts + 1] = flag .. "\n"
  end
  for i = 2, 3 do
    local text, _ = Fs.read(system[i])
    parts[#parts + 1] = text or ""
  end
  return Hash.hex_sha256(table.concat(parts)):sub(1, 16)
end

--- The test harness every worker runs, as a digest: each module the
--- modules `roots` require, directly or not, and themselves, and each of
--- `own` alone -- one whose requires are the runner's, not a worker's --
--- by name and source hash, from `sources` (source hash by module name)
--- and `imports` (the names each requires), as the running binary's own
--- database holds them. A module no source names is left out.
function declared_key.harness(roots: {string}, sources: {string:string},
                              imports: {string:{string}}, own?: {string}): string
  local seen: {string:boolean} = {}
  local lines: {string} = {}
  local stack: {string} = {}
  for _, name in ipairs(own or {}) do
    if sources[name] ~= nil and not seen[name] then
      seen[name] = true
      lines[#lines + 1] = name .. " " .. sources[name]
    end
  end
  for _, root in ipairs(roots) do stack[#stack + 1] = root end
  local walked: {string:boolean} = {}
  while #stack > 0 do
    local name = table.remove(stack)
    if not walked[name] and sources[name] ~= nil then
      walked[name] = true
      if not seen[name] then
        seen[name] = true
        lines[#lines + 1] = name .. " " .. sources[name]
      end
      for _, required in ipairs(imports[name] or {}) do stack[#stack + 1] = required end
    end
  end
  table.sort(lines)
  return Hash.hex_sha256(table.concat(lines, "\n"))
end

--- What this very program is, for a test that runs it: each of `paths`
--- (`observations.itself()`: the program and its core) by what it runs
--- as (`program`) -- an artifact by its image and the rows it carries,
--- anything else by contents -- worked out only when its `lstat` moves.
--- The stamp that says a core was verified (`.verified-<core>`) is left
--- out: it is there or not by whether a run has verified the core yet,
--- not by what runs.
function declared_key.program_identity(digests: declared_key.Digests, paths: {string}): string
  local lines: {string} = {}
  for _, path in ipairs(paths) do
    if path:match("/%.verified%-[^/]*$") ~= nil then goto continue end
    local st, _ = sys.stat(path)
    lines[#lines + 1] = (st ~= nil and st.kind == "file") and program(digests, path, st) or
      "missing"
    ::continue::
  end
  return Hash.hex_sha256(table.concat(lines, "\n"))
end

--- Whether a test of `effective` has a key at all: one that reaches the
--- network does not, whatever it reached being no input a key holds --
--- but for one that declares only loopback hosts
--- (`test_inputs.loopback_only`), whose worker the sandbox keeps offline
--- (`build.test_sandbox`'s `plan`), where they reach nothing past it.
function declared_key.keyable(effective: test_inputs.Effective): boolean
  return next(effective.network) == nil or test_inputs.loopback_only(effective)
end

return declared_key
