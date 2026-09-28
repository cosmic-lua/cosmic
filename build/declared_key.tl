--- A sandboxed test's verdict key: a digest of what the test was given
--- (`build.test_sandbox`), computed before it runs, from its declared
--- inputs alone (`build.test_inputs`), rather than of what it was seen
--- to read, and a verdict under it stands with no observation to replay.
---
--- A sandboxed worker reads its declared inputs, and besides them what
--- every worker is given (build.confine's `worker_unveil`): /proc, the
--- devices every program takes for granted (/dev/null, /dev/zero,
--- /dev/urandom), the program's core -- and the program itself only
--- where its module declares `tool` -- and a store at
--- o/cosmic.db, held as below -- and the system's own paths (/usr,
--- /bin, /lib, /etc and the like) only where its module declares
--- `system`; and it runs as whoever runs the tests, with their
--- capabilities. The key holds the rest by the host's identity
--- (`host_identity`), the system's where the module declares `system`
--- (`system_identity`), and the runtime's, not by their contents: what
--- is left out is in the TODOs on each. It may not run this program
--- unless it declares `tool` (build.confine's `forbid_running`), which
--- runs the tool's own modules, which no key of the test holds but
--- o/bin's.
---
--- The key is the digest of
---
--- - the test: its module's path and its name (`id`);
--- - `version`, which names how the rest are computed;
--- - the test harness every worker runs, as the running binary carries
---   it (`harness`): each module a worker loads besides its test's
---   closure (`build.test_worker`'s `worker.loads`), the plan of its
---   sandbox's maker (`build.test`'s `harness_own`), and the code that
---   makes a key and looks a verdict up under one (`build.test`'s
---   `key_code`: build.test, and this module's closure and
---   build.shared_verdicts'), each by its source and its bytecode --
---   COSMIC_TEST_HARNESS_SALT, for a test alone, stands in for a change
---   to it;
--- - what runs it: the runtime identity -- the core's digest, its
---   platform and configuration, and the Teal and Lua pins -- the
---   digest of the binary's data tables and the `sandboxed` mark
---   (`runtime`); and, where an artifact runs it (o/bin/cosmic, or a
---   portable cosmic), what runs that core (`launcher_identity`);
--- - the host it runs on (`host_identity`): its kernel and processor,
---   the user and capabilities the tests run with, which /proc a
---   sandbox gets and what the host says of itself; and, only for a
---   module that declares `system`, or a `host` directory, which is
---   keyed by its name alone (`host`), what the host has installed
---   (`system_identity`): its packages and the system it says it is;
--- - the module's graph key (`build.positions`' `graph_key`), over its
---   import graph's kinds and sources, the standard library's included;
--- - the compiler's identity (`build.work`'s `Identities`), as the
---   running tool names it, only where the module's import closure holds
---   a module that reads it (`compiler_readers`), which a worker's
---   `Store.meta` answers from the tool's own database --
---   COSMIC_TEST_COMPILER_SALT, for a test alone, stands in for a
---   compiler of another identity that makes the same bytecode;
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
---   projection's place; and each `host` path -- one a variable names
---   (`$NAME/path`) by that spelling and by all it holds, as a path of
---   the tree is, not by where the variable says it is;
--- - the environment its worker is given (`test_sandbox.environment`):
---   the pinned variables and the declared ones, all of them for `"*"`
---   -- a value where a variable a `host` path names says, or beneath
---   it, by that variable's name.
---
--- The compiler is held by what it made, not by its identity. Its
--- identity digests every module a compile or a parse runs to decide
--- what it stores (`build.work`'s `compiler_identity`), most of whose
--- edits change nothing it makes (a refactor, a comment, a faster
--- path): holding it would run every test again for an edit to any of
--- them. What a worker runs of the
--- compiler's making is the bytecode of its closure's modules, which
--- its store holds by address (`build.closure_store`'s `address`,
--- over each module's bytecode and the rows a store carries of it) or
--- the projection by its contents, and the harness's -- cosmic's own
--- main, which every worker runs first, among it -- which `harness`
--- holds by bytecode; the compiler Teal itself compiles to
--- (`vendor.tl`) is carried beside build.teal, the one module that
--- loads it, by its bytecode too. Whether a module compiles at all is
--- no verdict of a test: a build that refuses one runs none. So what a
--- worker runs of the tree is keyed exactly when it is of its closure
--- or of the harness, and `build.test_worker`'s `judge` fails a test
--- whose worker loaded a module the tool carries that is of neither --
--- a top-level require added to build.test_worker, a lazy one a worker
--- reaches -- naming it. The harness is what a worker loads, not
--- every module its modules require: a `local type` require is erased
--- by Teal and loads nothing, and what an imported type does at run
--- time (an `is` against a record's `where`, an enum's membership) is
--- compiled into the importer's bytecode, which `harness` holds.
---
--- The code that computes a key is held too, by its source and
--- bytecode as the rest of the harness is: a version of it that maps a
--- test's inputs to the key another version computes for other inputs
--- -- a digest that misses a rewrite of the same size and times -- keeps
--- its verdict under that key, in o/build.db and in the verdicts every
--- checkout shares, where it would stand after the fix. So each version
--- of build.test, of this module and what it requires, and of
--- build.shared_verdicts keys apart, and any edit to one of them, a
--- comment's or a doc's too, runs every sandboxed test again: holding
--- it by what Lua runs of it instead would take a walk of Lua's dump
--- format by hand, more code to trust where a mistake leaves wrong
--- verdicts standing. That holds what build.test decides of a
--- worker's holds as well -- the names of the tree's modules and
--- declarations a `require` or a lookup in the store refuses -- which
--- it hands a worker and no other part of a key names. It would be
--- unsound to read the compiler's identity by any means but
--- `Store.meta`'s `compiler` and `compiled_by`, held as above.
---
--- The host caches it declares are not: they are content-addressed,
--- and never change a result (`build.caches`). Nor are the variables
--- the runner adds to start a worker at all (`Proc.relaunch`'s, and
--- COSMIC_COVERAGE_STARTUP): they name where the core is and which
--- descriptors it is handed, which the runtime identity holds already,
--- and would name where this host keeps its cache in every key. A test
--- that declares `network` beyond loopback hosts has no key that holds
--- what it reached, and always runs; nor does one that reads a declared
--- directory holding a link that leads out of the tree, which a sandbox
--- follows to what the key would not hold.
---
--- Nothing in a key names where the tree is -- a path of it is keyed by
--- its name there, and a variable's value, each of its `:`-separated
--- parts, by `tree_name` -- so another checkout of the same
--- content reaches the same key, and a verdict is shared by it alone
--- (`build.shared_verdicts`).
---
--- Files are hashed once a run, and a file whose `lstat` says the same
--- as when a run last hashed it is not read at all: `Digests` remembers
--- each hash by what `lstat` said of the file, its change time included,
--- and o/build.db keeps them from run to run.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local artifact = require("build.artifact")
local confine = require("build.confine")
local test_inputs = require("build.test_inputs")

local record declared_key
  compiler_readers: {string}

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
    --- The module's `graph_key` (`build.positions`): its key less the
    --- compiler.
    module_key: string
    runtime: string
    --- The compiler's identity as the running tool's `meta` names it --
    --- its `compiler` and `compiled_by` -- where the module's closure
    --- reads it (`reads_compiler`), and "" elsewhere.
    compiler: string
    --- The test harness a worker runs, as the running binary carries it
    --- (`harness`): every worker runs it, the tree's or not.
    harness: string
    --- The program a test that runs this program runs
    --- (`program_identity`): o/bin/cosmic, or o/sanitized's, or a
    --- portable cosmic, whichever is running.
    program: string
    --- The host's identity (`host_identity`), which every key holds.
    host: string
    --- What the host has installed (`system_identity`), which only the
    --- key of a module that declares `system`, or a `host` directory,
    --- holds; nil for none.
    system: string
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
    --- `store` (`build.closure_store`'s `address`), or nil where it is
    --- given the whole projection, keyed by its contents.
    closure_store: string
  end

  --- Where `host_identity` and `system_identity` look, for a test: each
  --- a path, but `sysname`, `machine`, `own_proc`, whether a sandbox gets
  --- a /proc of its own, `host_id`, the value of `host_variable`,
  --- `system_id`, the value of `system_variable`, and `uid`.
  record HostSources
    packages: {string}
    --- The system the host says it is, then its kernel's release and
    --- version: `system_identity` reads the first, `host_identity` the
    --- other two. Where it is nil, `system_sources(sysname)`.
    system: {string}
    --- The kernel `uname` names, which chooses where `system` looks
    --- when it is nil (`system_sources`).
    sysname: string
    system_id: string
    status: string
    cpuinfo: string
    --- The machine whose features `cpuinfo` keys (`dispatched`).
    machine: string
    own_proc: boolean
    host_id: string
    uid: integer
  end
end

--- One framed contribution to a verdict key.
function declared_key.key_part(kind: string, path: string, answer: string): string
  return kind .. " " .. Codec.hex(path) .. " " .. Codec.hex(answer)
end

--- What names the tree's own root in `tree_name`: a NUL, which no
--- path holds, so no path outside the tree is ever named as one inside.
local tree_marker <const> = "\0tree"

--- A path as a key names it, the same in every checkout of one tree:
--- one under `tree` -- as written, not climbing with ".." -- by its name
--- below it after a marker no path holds, and any other as it is. The
--- tree's own location is no input to what a test does there, so two
--- checkouts of the same content key the same read alike.
---
--- That is a rule, not an accident of keying: a test may not turn on
--- where the tree is -- a path length limit, a name it prints and
--- compares. The answers that name it which a capture observes (the
--- working directory, a realpath, a readlink, a path under the tree
--- read or given) are keyed by `tree_name` in the shared key and whole
--- only in a checkout's own; one it does not (the artifact path
--- `Proc.relaunch` and the process table's `relaunch` answer) is keyed
--- nowhere. The same rule holds of where the running program is: what
--- `Proc.executable` answered is keyed nowhere (`program_answer`), only
--- that it answered. Nothing here can see a test break either rule;
--- CI enforces both by moving its checkout, and the tool it runs,
--- o/bin/cosmic, with it, to a path the commit and the leg choose, a
--- new one each commit (.github/scripts/place-tree.sh). That catches a
--- test that breaks one only on a run that runs the test: every run
--- while CI stands only on what it runs itself, and once it stands on
--- shared verdicts, only a run where the test's key changed.
function declared_key.tree_name(path: string, tree: string): string
  if ("/" .. path .. "/"):find("/%.%./") ~= nil then return path end
  local rest, _ = Fs.relative(path, tree)
  if rest == nil then return path end
  if rest == "." then return tree_marker end
  return tree_marker .. "/" .. rest
end

--- What every key begins with, which names how its parts are computed:
--- bumped by hand for a fix to how one is computed by code no key
--- holds by its code -- the build's, which computes a module's graph
--- key (`build.importer`) -- which would otherwise leave standing a
--- verdict kept under a key computed wrong. A change to this code moves
--- every key by itself: it is held by its source and bytecode (above).
--- build/declared_key_pins_test.tl pins that graph key over a fixed
--- tree, and fails, naming this, when an edit moves it.
local version <const> = "declared-3"

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
--- every file the tool's trees hold but their tests, and
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
--- keys the same, though `tree_wide_meta` moved every byte of its
--- database's meta: `projected` moves with an edit to a test, which no
--- binary carries, though a test is no part of `boot_hash` and so
--- rebuilds no tool; a boot writes one anyway.
--- What reads those rows, and why none can turn a verdict:
---
--- - `boot_hash`: build.reboot compares it with the fingerprint of the
---   tree a run is in -- cosmic's own tree only (`build.tree`'s
---   `is_own`) -- which is the running tool's own tree at test time,
---   since a run rebuilds a stale tool before it tests, or refuses; a
---   fixture's tree is a test's own, whose fingerprint matches only a
---   tree holding every file of the tool's trees, each of which that
---   test would declare, and each keyed by it. build.writer's `running`
---   and build.importer's `receivers_identity` and `running_analyzer`
---   ask the same question of the tree, or only whether there is one;
---   `analyzer_identity` and `receivers_identity` name the binary by it
---   only where it carries no source for its analyzer, which a built
---   binary does; the value names a cache entry (build.standalone's
---   `cached_path`), and the bill of materials' version (build.bom),
---   which only moves a name; and an unsandboxed verdict's identity
---   (build.test's `identity_of`), which a sandboxed key is not.
--- - `projected`: build.writer reads it from a projection it wrote, to
---   skip writing the same one again, never from a binary.
---
--- And every sandboxed worker runs this same binary, whether its test
--- declares `tool` or not; one that declares neither `tool` nor `store`
--- reads through `Store.meta` only the rows its key holds, and
--- `boot_hash` (`build.test_worker`'s `held_meta`), while one that
--- declares either has these same rows in reach, which its key holds
--- by the program's image and the rows it carries, but for these.
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
--- it resolves nowhere. `bounds`, where given, stand for the tree: the
--- host path a variable names and where it resolves, all of which a
--- sandbox gives and a key holds.
local function leads_out(digests: declared_key.Digests, path: string,
                         directory: string, bounds?: {string}): string | nil
  local within = bounds or { digests.root, digests.real_root }
  local what = bounds ~= nil and within[1] or "the tree"
  local function inside(candidate: string): boolean
    for _, bound in ipairs(within) do
      if Fs.within(candidate, bound) then return true end
    end
    return false
  end
  local real, _ = sys.realpath(path)
  if real ~= nil then
    if inside(real) then return nil end
    return path .. " leads out of " .. what .. ", to " .. real
  end
  local target, _ = sys.readlink(path)
  if target == nil then return nil end
  local lexical = test_inputs.plain(target:sub(1, 1) == "/" and target or
    (directory .. "/" .. target))
  if inside(lexical) then return nil end
  return path .. " leads out of " .. what .. ", to " .. target
end

--- What `path` holds, followed where it is a link, as a sandbox binds
--- it: an entry's answer, or for a directory "dir" and the digest of
--- every entry beneath it, links unfollowed, in name order -- each by
--- its name beneath `path`, what it is and what it holds; each file as
--- a `program` where `programs` says to. A link is judged against
--- `bounds` (`leads_out`), the tree where nil.
local function tree(digests: declared_key.Digests, path: string, programs?: boolean,
                    bounds?: {string}): string
  local tag = (programs and "p\0" or bounds ~= nil and "v\0" or "t\0") .. path
  return once(digests, tag, function(): string
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
        if what == "link" and refused == nil then
          refused = leads_out(digests, here, directory, bounds)
        end
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

--- The digest of what a test of `spec` is given, but for its name, or
--- "refused " and why there is none.
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
  return Hash.hex_sha256(version .. "\n" .. declared_key.key_part("i", spec.id, "") .. "\n" ..
    inputs), ""
end

--- A variable's value as a key holds it: each of its `:`-separated
--- parts that is a path of the tree by its name there
--- (`tree_name`), as PATH's are, and each that is where a
--- variable a `host` path of `effective` names says, or beneath it, by
--- that variable's name (`test_inputs.spelling`): what is there is
--- keyed by its contents, and its place is no more an input than the
--- tree's.
local function held_value(value: string, root: string,
                          effective: test_inputs.Effective): string
  local parts: {string} = {}
  for part in (value .. ":"):gmatch("([^:]*):") do
    local held = declared_key.tree_name(part, root)
    if held == part and part:sub(1, 1) == "/" then
      held = test_inputs.spelling(effective, test_inputs.plain(part), true)
      if held == test_inputs.plain(part) then held = part end
    end
    parts[#parts + 1] = held
  end
  return table.concat(parts, ":")
end

--- What `spec`'s test is given, but for its name, as the lines whose
--- digest its key holds (`compute`) -- each a `key_part`, which frames
--- what it names so that no two specs spell one -- or nil and why there
--- is none: a declared directory holds a link out of the tree
--- (`leads_out`). build/declared_key_fuzz_test.tl holds distinct specs
--- to distinct preimages, and build/declared_key_test.tl holds every
--- field of a `Spec` to moving the key `compute` makes of it.
function declared_key.preimage(digests: declared_key.Digests,
                               spec: declared_key.Spec): string | nil, string
  local part = declared_key.key_part
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
    if answer:sub(1, 8) == "refused " then return nil, answer:sub(9) end
    lines[#lines + 1] = part("tool", "o/bin", answer)
    -- And what actually runs, which need not be o/bin/cosmic.
    lines[#lines + 1] = part("program", spec.program or "", "")
  end
  -- The store its worker is given at o/cosmic.db: the whole projection,
  -- by its contents, where the module declares `store`; else the store
  -- of its closure, by its address, which is a digest of all its bytes
  -- follow from -- so neither an edit to a module outside the closure
  -- nor adding or removing one moves it (`build.closure_store`'s
  -- `address`). The names of the tree's modules a worker
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
      if answer:sub(1, 8) == "refused " then return nil, answer:sub(9) end
      lines[#lines + 1] = part("r", plain, answer)
    end
  end
  local hosts: {string} = {}
  for _, path in ipairs(effective.host) do hosts[#hosts + 1] = test_inputs.plain(path) end
  -- Each in order of its line's name: one a variable names by its
  -- spelling, so where the variables say moves no line.
  local function named(path: string): string
    local declared = (effective.spelled or {})[path]
    return declared ~= nil and ("v\0" .. declared) or ("h\0" .. path)
  end
  table.sort(hosts, function(a: string, b: string): boolean return named(a) < named(b) end)
  -- What the host has installed, for a module given the system's paths,
  -- and for one given a directory of the host's, which `host` keys by
  -- its name alone: the package database stands for what either holds.
  -- /proc and /dev are no package's: every worker is given them.
  local installed = effective.system
  local spelled = effective.spelled or {}
  for _, path in ipairs(hosts) do
    if not seen[path] then
      seen[path] = true
      local declared = spelled[path]
      if declared ~= nil then
        -- One a variable names, by the name the module declares it by
        -- and by what it holds, all of it, as a path of the tree is: not
        -- by where the variable says it is, which another run may say
        -- elsewhere.
        local real, _ = sys.realpath(path)
        local answer = tree(digests, path, false, { path, real or path })
        if answer:sub(1, 8) == "refused " then return nil, answer:sub(9) end
        lines[#lines + 1] = part("v", declared, answer)
      else
        local answer = host(digests, path)
        if answer == "dir" and not confine.in_runtime(path) then installed = true end
        lines[#lines + 1] = part("h", path, answer)
      end
    end
  end
  if installed then lines[#lines + 1] = part("system", spec.system or "", "") end
  local names: {string} = {}
  for name in pairs(spec.environment) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    lines[#lines + 1] = part("e", name, held_value(spec.environment[name], digests.root,
      effective))
  end
  return table.concat(lines, "\n"), ""
end

inputs_of = function(digests: declared_key.Digests, spec: declared_key.Spec): string
  local preimage, why = declared_key.preimage(digests, spec)
  if preimage == nil then return "refused " .. why end
  return Hash.hex_sha256(preimage)
end

--- The processor's features a core running on `machine` chooses code
--- by, which is all a key holds of what /proc/cpuinfo lists:
--- `host_identity` says which code reads each, and
--- build/dispatched_features_test.tl holds the vendored sites to this.
--- A machine not named here, whose cores no audit has read, keys its
--- whole list.
local dispatched: {string:{string:boolean}} = {
  x86_64 = { aes = true, pclmulqdq = true, ssse3 = true, sse4_1 = true },
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

--- Where `host_identity` and `system_identity` read the system the
--- host says it is, and its kernel's release and version (`HostSources`'
--- `system`).
local default_system: {string} = { "/etc/os-release", "/proc/sys/kernel/osrelease",
  "/proc/sys/kernel/version" }

--- The same on macOS, where there is no /proc and no /etc/os-release:
--- the system volume's SystemVersion.plist for the system it says it is
--- and for its kernel alike, and no third. Its ProductBuildVersion names
--- the whole sealed system volume -- the kernel, /System, /usr/bin and
--- /bin among it -- which System Integrity Protection keeps as built,
--- so it names everything there a worker can read.
-- TODO: read the OS cryptex's SystemVersion.plist too
-- (/System/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist),
-- beside this one, in .github/scripts/host-features.sh alike: a Rapid
-- Security Response updates the cryptex, not the sealed volume, and
-- names itself only there (ProductVersionExtra), so today a host
-- before one and after it key alike.
local darwin_system: {string} = { "/System/Library/CoreServices/SystemVersion.plist",
  "/System/Library/CoreServices/SystemVersion.plist", "" }

--- Where `host_identity`, `system_identity` and `host_features` read
--- the system the host says it is and its kernel's release and version
--- (`HostSources`' `system`) on a host whose kernel `uname` names
--- `sysname`: `darwin_system` on "Darwin", and /etc/os-release and
--- /proc's elsewhere.
function declared_key.system_sources(sysname: string): {string}
  local chosen = sysname == "Darwin" and darwin_system or default_system
  local out: {string} = {}
  for i, path in ipairs(chosen) do out[i] = path end
  return out
end

--- `from`'s `system`, or, where it names none, this host's, or the one
--- whose kernel its `sysname` names (`system_sources`).
local function system_of(from: declared_key.HostSources): {string}
  if from.system ~= nil then return from.system end
  local sysname = from.sysname
  if sysname == nil then
    local names, _ = sys.uname()
    sysname = names ~= nil and names.sysname or ""
  end
  return declared_key.system_sources(sysname)
end

--- The variable a host names more of itself in than `host_identity`
--- finds there: CI's legs, the container they run in -- its image, the
--- seccomp profile and options it is started with, the container
--- engine's version -- which no file inside it tells.
local host_variable <const> = "COSMIC_HOST_ID"

--- The variable a host names what it has installed in beyond what
--- `system_identity` finds in its files: on macOS, where there is no
--- package database, what the sealed system volume does not hold --
--- Xcode and its command line tools, whose shims /usr/bin's git, make
--- and cc are, and /opt/homebrew and /usr/local -- as CI's macOS leg
--- names its runner image there. Only `system_identity` reads it, so
--- only a module given the system's paths is keyed by it.
local system_variable <const> = "COSMIC_SYSTEM_ID"

--- What of this host every sandboxed worker runs on, whatever its
--- module declares, as every key holds it -- each part because it
--- decides what the core does, or what a sandbox lets a worker do:
---
--- - its kernel's release and version (/proc/sys/kernel/osrelease and
---   version; on macOS, the system volume's SystemVersion.plist, which
---   names its build, `darwin_system`): the syscalls the core makes, and
---   what a sandbox is (namespaces, Landlock's ABI, whether a procfs may
---   be mounted), are the kernel's;
--- - its name and machine (`uname`): the core a run selects;
--- - the processor's features a core chooses code by (/proc/cpuinfo's
---   flags, each once, `dispatched`);
--- - the user, groups and capabilities this process -- and so every
---   worker -- runs with, and whether no_new_privs and a seccomp filter
---   hold it (/proc/self/status): whether a file's permissions refuse a
---   read, whether a sandbox may map ids or nest another, and which
---   calls a filter refuses are theirs;
--- - whether a sandbox gets a /proc of its own
---   (`confine.own_proc_given`), which a test of the sandbox
---   expects different things of; and
--- - what the host says of itself besides (`host_variable`): CI names
---   the container's seccomp profile and engine there, which decide
---   what a sandbox may do, beside its image.
---
--- What the host has installed -- its packages and the system it says
--- it is -- is `system_identity`'s, which only the key of a module given
--- the system's paths holds: a worker that is not given them reads
--- nothing of them. Worked out once a run. `sources` moves where it
--- looks, for a test; a field it leaves nil is this host's own. Of
--- these, what differs between runners of one CI leg -- the processor's
--- features and the kernel -- names the leg's verdict cache too
--- (`host_features`, .github/scripts/host-features.sh): a change to how
--- either is keyed changes both, and the script.
-- TODO: key the image apart from the seccomp profile and the engine, in
-- `system_identity`, once ci.yml names them in variables of their own
-- (with the verdict caches' naming, which a later change reconsiders):
-- today COSMIC_HOST_ID holds all three, and every key holds it, so
-- CI's legs of two images share no verdict that turns on neither.
-- TODO: key the kernel by what a test can tell of it -- its series and
-- the features the core probes (Landlock's ABI, whether a user
-- namespace may mount a procfs) -- rather than its release and build
-- string whole, once the core reports what it found (a `cosmic.sys`
-- table of the probes' answers): today every kernel update splits
-- every verdict, though almost none turns on it.
-- TODO: key whether a new network namespace gets IPv6 -- /proc/sys/net/ipv6
-- there at all (ipv6.disable=1 at boot), net.ipv6.conf.all.disable_ipv6
-- and net.core.devconf_inherit_init_net -- which the kernel's release
-- alone does not say: a test that declares `::1` runs offline
-- (`test_inputs.offline`), where `::1` is there or not by them. No test
-- declares `::1` today, so no verdict stands on it yet.
-- TODO: key the groups this process runs with where there is no
-- /proc/self/status (macOS), once cosmic.sys carries getgid and
-- getgroups: today a macOS key holds the uid alone, so a verdict
-- reached as a member of a group stands for a user not in it.
function declared_key.host_identity(digests: declared_key.Digests,
                                    sources?: declared_key.HostSources): string
  local started = Time.monotonic_ns()
  local from: declared_key.HostSources = sources or {}
  local lines: {string} = {}
  local system = system_of(from)
  for i = 2, 3 do
    -- None ("", macOS's version) is read as nothing, not as the
    -- working directory "" would open.
    if system[i] ~= "" then
      local text, _ = Fs.read(system[i] or "")
      lines[#lines + 1] = tostring(system[i]) .. " " .. (text or "missing")
    end
  end
  local names, _ = sys.uname()
  if names ~= nil then lines[#lines + 1] = "uname " .. names.sysname .. " " .. names.machine end
  -- Each distinct feature once, sorted: every processor lists them.
  -- Only those the code a test runs chooses code by (`dispatched`),
  -- which an audit of the vendored C and the disassembled cores found:
  -- mbedtls's aesni.c (`aes`, `pclmulqdq`) and aesce.c (`asimd`, `aes`,
  -- `pmull`); xz's crc_x86_clmul.h (`pclmulqdq`, `ssse3`, `sse4_1`) and
  -- crc32_arm64.h (`crc32`). No Linux core links a libm that
  -- dispatches: every one, the checked core too, is static musl, and
  -- the libm zig and musl carry chooses no code by the processor. A
  -- checked core that linked a glibc host's libm keyed `fma`, `avx2`
  -- and `fma4`, which chose its pow, asin, acos and atan2's variants;
  -- none of its verdicts can stand for another core, since every key
  -- holds the core's digest (`runtime`). Nothing else the core carries
  -- dispatches, nor does its build, so the
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
  if own == nil then own = confine.own_proc_given() end
  lines[#lines + 1] = "own proc " .. tostring(own)
  local host_id = from.host_id
  if host_id == nil then host_id = sys.getenv(host_variable) or "" end
  lines[#lines + 1] = "host " .. host_id
  digests.spent_ns = digests.spent_ns + (Time.monotonic_ns() - started)
  return Hash.hex_sha256(table.concat(lines, "\n"))
end

--- What the host has installed, as the key of a module given the
--- system's paths (`Test.needs`'s `system`) holds it: the database of
--- the packages it has installed (`package_databases`), by contents,
--- where there is one, hashed only when its `lstat` moves; the system
--- it says it is (/etc/os-release; on macOS, the system volume's
--- SystemVersion.plist, `darwin_system`); and what it names of itself
--- besides (`system_variable`). `sources` moves where it looks
--- (`packages`, `system`'s first path, `system_id`), for a test.
-- TODO: key what a package database does not say: a file under /usr,
-- /etc or /lib changed by hand or by a tool other than the package
-- manager, a package installed from source into /usr/local, and a
-- container image's own layers where no `host_variable` names the
-- image. Wants a walk of the system's paths cheap enough to take every
-- run (/usr's stamps take half a second). Nor is the clock keyed: a
-- test whose verdict turns on the date stands on one reached another
-- day, which only a forced run (CI's scheduled one) catches.
-- TODO: key what a developer's Mac has installed beyond the sealed
-- system volume -- Xcode or its command line tools, /opt/homebrew,
-- /usr/local, the programs a test finds on PATH there -- where no
-- COSMIC_SYSTEM_ID names it, as CI's macOS leg names its image: wants
-- a digest of each cheap enough to take every run (Xcode's version,
-- Homebrew's installed list). Today such a Mac keys a `system` module
-- by the OS build alone, so a verdict stands across an update of them.
function declared_key.system_identity(digests: declared_key.Digests,
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
  local release = system_of(from)[1]
  if release ~= nil then
    local text, _ = Fs.read(release)
    lines[#lines + 1] = release .. " " .. (text or "missing")
  end
  local system_id = from.system_id
  if system_id == nil then system_id = sys.getenv(system_variable) or "" end
  lines[#lines + 1] = "system " .. system_id
  digests.spent_ns = digests.spent_ns + (Time.monotonic_ns() - started)
  return Hash.hex_sha256(table.concat(lines, "\n"))
end

--- What of `host_identity` differs between runners of one CI leg, as
--- the first 16 hex digits of a sha256: the processor's features, a
--- line each (`features`), then the kernel's release and version as
--- their files hold them, a missing one as empty -- on macOS, the
--- system volume's SystemVersion.plist, and nothing (`darwin_system`).
--- It is what .github/scripts/host-features.sh prints, which names a
--- leg's verdict cache, so a run restores one whose keys its host
--- reaches. `sources` moves where it looks (`cpuinfo`, `machine`,
--- `sysname`, and `system`'s second and third paths), for a test.
function declared_key.host_features(sources?: declared_key.HostSources): string
  local from: declared_key.HostSources = sources or {}
  local system = system_of(from)
  local parts: {string} = {}
  for _, flag in ipairs(features(from.cpuinfo, from.machine)) do
    parts[#parts + 1] = flag .. "\n"
  end
  for i = 2, 3 do
    -- None ("", macOS's version) is read as nothing, as in `host_identity`.
    local text: string = nil
    if (system[i] or "") ~= "" then
      local read, _ = Fs.read(system[i])
      text = read
    end
    parts[#parts + 1] = text or ""
  end
  return Hash.hex_sha256(table.concat(parts)):sub(1, 16)
end

--- The test harness every worker runs, as a digest: each module of
--- `names` by name and what it is, from `sources` (what each module
--- is, by name: `build.test` gives its source's hash and its
--- bytecode's, so what the compiler made of it moves it as its source
--- does), as the running binary's own database holds them. Nothing
--- they require is walked: `names` is what a worker runs, which
--- `build.test_worker`'s `judge` holds it to. A module no source
--- names is left out.
function declared_key.harness(names: {string}, sources: {string:string}): string
  local seen: {string:boolean} = {}
  local lines: {string} = {}
  for _, name in ipairs(names) do
    if sources[name] ~= nil and not seen[name] then
      seen[name] = true
      lines[#lines + 1] = name .. " " .. sources[name]
    end
  end
  table.sort(lines)
  return Hash.hex_sha256(table.concat(lines, "\n"))
end

--- What this very program is, for a test that runs it: each of `paths`
--- (build.confine's `itself()`: the program and its core) by what it runs
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

--- The modules of the tree that read the compiler's identity
--- (`Store.meta`'s `compiler` or `compiled_by`), which a closure store
--- does not carry: a worker's reads of it are answered from the running
--- tool's own `meta`, so a test whose closure holds one of them is keyed
--- by the tool's (`Spec.compiler`). build/compiler_readers_test.tl fails
--- when a module of the tree reads it and is not named here.
declared_key.compiler_readers = {
  "build.dispatch", "build.embed", "build.fix.spill", "build.importer", "build.reboot",
  "build.store_meta_readers_test", "build.test", "core.allocation_test", "cosmic.store_test",
  "doc.guides.portable-runtime",
}

--- Whether an import closure, the names of its modules, holds a module
--- that reads the compiler's identity (`compiler_readers`).
function declared_key.reads_compiler(closure: {string}): boolean
  local readers: {string:boolean} = {}
  for _, name in ipairs(declared_key.compiler_readers) do readers[name] = true end
  for _, name in ipairs(closure) do
    if readers[name] then return true end
  end
  return false
end

--- Whether a test of `effective` has a key at all: one that reaches the
--- network does not, whatever it reached being no input a key holds --
--- but for one that declares only loopback hosts, whose worker the
--- sandbox keeps offline, where they reach nothing past it: the answer
--- is `test_inputs.offline`'s, which `build.test_sandbox`'s `plan`
--- takes too.
function declared_key.keyable(effective: test_inputs.Effective): boolean
  return test_inputs.offline(effective)
end

return declared_key
