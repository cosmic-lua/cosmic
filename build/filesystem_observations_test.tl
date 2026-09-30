--- What is left of the observation log (build.filesystem_observations):
--- its C resolution of a path, held to a Teal oracle, and the observed
--- VFS every [`cosmic.sqlite`] connection opens through.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local observations = require("build.filesystem_observations")
local type raw_observations = require("cosmic.internal.observations")

local type Searcher = function(string): any, any

--- The raw tables the store's searcher hands this module's loader
--- (core/store.c's `open_observations`).
local function raw_tables(): raw_observations
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("build.filesystem_observations")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_observations -- cast: the table core/store.c's open_observations makes
    end
  end
  error("build.filesystem_observations is handed no raw table")
end

--- While it is on, the syscall table's log keeps what each call it
--- observes was asked and answered, whoever made it -- a query, a
--- change of directory asked as a stat of where it goes, an open noted
--- before it acts -- with a path outside the tree resolved as the call
--- is made, until a drain hands it over; off, it keeps nothing.
local function test_the_log_keeps_what_its_calls_answered_until_drained(tmp: string)
  local log = raw_tables().syscalls
  local real = assert(sys.realpath(tmp))
  assert(Fs.write(real .. "/f", "x"))
  local _ = log.observed()
  log.resolving(real .. "/tree")
  log.observe(true)
  local st, _ = sys.stat(real .. "/f")
  local may, _ = sys.access(real .. "/f", sys.R_OK)
  local fd = assert(sys.open(real .. "/f", sys.O_RDONLY))
  local home = sys.getenv("HOME")
  log.observe(false)
  log.resolving(nil)
  assert(sys.close(fd))
  assert(st ~= nil and may)
  local calls = log.observed()
  local seen: {string:raw_observations.Call} = {}
  for _, call in ipairs(calls) do seen[call.call .. " " .. tostring(call.path)] = call end
  local stat = assert(seen["stat " .. real .. "/f"], "no stat")
  assert(stat.resolved == real .. "/f", tostring(stat.resolved))
  assert((stat[1] as sys.Stat).size == 1)
  assert(seen["open " .. real .. "/f"] ~= nil, "no open")
  local getenv = assert(seen["getenv HOME"], "no getenv")
  assert(getenv[1] == home)
  assert(#log.observed() == 0, "a drain kept what it handed over")
  local _ = sys.stat(real .. "/f")
  assert(#log.observed() == 0, "the log kept a call made while it was off")
end

--- While it is on, SQLite's record keeps each file a connection opens,
--- and hands over each one a connection already holds as it turns on,
--- but one excluded.
local function test_sqlite_s_record_keeps_what_it_opens_but_what_is_excluded(tmp: string)
  local sqlite = raw_tables().sqlite
  local real = assert(sys.realpath(tmp))
  local _ = sqlite.observed()
  local excluded = assert(Sqlite.open(real .. "/excluded.db", true))
  assert(excluded:exec("CREATE TABLE t (v TEXT)"))
  sqlite.exclude_held()
  local held = assert(Sqlite.open(real .. "/held.db", true))
  assert(held:exec("CREATE TABLE t (v TEXT)"))
  local handed, trouble = sqlite.observe(true)
  local opened = assert(Sqlite.open(real .. "/opened.db", true))
  assert(opened:exec("CREATE TABLE t (v TEXT)"))
  local _, _ = sqlite.observe(false)
  assert(handed, trouble)
  local kept: {string:boolean} = {}
  for _, path in ipairs(sqlite.observed()) do kept[path] = true end
  assert(kept[real .. "/held.db"] and kept[real .. "/opened.db"] and
    not kept[real .. "/excluded.db"])
  for _, db in ipairs({ excluded, held, opened }) do assert(db:close()) end
end

--- A connection [`cosmic.sqlite`] opens reads the clock through the VFS
--- that records its files, which passes the question to the default
--- one: `julianday('now')` answers rather than ending the process.
local function test_a_connection_tells_the_time()
  local memory = assert(Sqlite.memory())
  local rows = assert(Sqlite.text_rows(memory, "SELECT julianday('now') > 2460000"))
  assert(memory:close())
  assert(rows[1][1] == "1")
end

--- What a path resolves to, in Teal: the oracle [`observations.resolution`]
--- and the log's `resolve` of a link, which stops short of a link the
--- path ends in, must agree with.
local function resolved_before(path: string, link: boolean): string
  if path:sub(1, 1) ~= "/" then return "" end
  if link then
    local name = Fs.basename(path)
    local parent = Fs.dirname(path)
    if not (path:sub(-1) == "/" or name == "." or name == ".." or name == "" or
        parent == path) then
      local up = resolved_before(parent, false)
      if up == "" then return "" end
      return (up == "/" and "" or up) .. "/" .. name
    end
  end
  local missing: {string} = {}
  local at = path
  while true do
    local real, _ = sys.realpath(at)
    if real ~= nil then
      for i = #missing, 1, -1 do
        real = (real == "/" and "" or real) .. "/" .. missing[i]
      end
      return real
    end
    local parent = Fs.dirname(at)
    if parent == at then return "" end
    missing[#missing + 1] = Fs.basename(at)
    at = parent
  end
end

--- The log resolves a path as [`resolved_before`] does: through
--- links, a missing name and all after it as written, "." and ".."
--- included, each run of slashes as one, and a link it ends in followed
--- or not.
local function test_a_resolution_is_the_one_the_oracle_tells(tmp: string)
  local real = assert(sys.realpath(tmp))
  assert(Fs.mkdirs(real .. "/d/e"))
  assert(Fs.write(real .. "/d/f", "x"))
  assert(Fs.symlink(real .. "/d", real .. "/link"))
  assert(Fs.symlink("missing", real .. "/dangling"))
  local long = real .. "/" .. string.rep("n", 200)
  for _ = 1, 25 do long = long .. "/" .. string.rep("n", 200) end
  local paths: {string} = { "/", "//", "", "relative/path", "/nowhere/at/all", tmp,
    tmp .. "/", tmp .. "//d///f", real .. "/link", real .. "/link/", real .. "/link/.",
    real .. "/link/..", real .. "/link/e/../f", real .. "/missing/../d/f", real .. "/d/f/",
    real .. "/d/f/g", real .. "/dangling", real .. "/dangling/x", real .. "/./d/./e",
    real .. "/link//", long, long .. "/../f" }
  for _, path in ipairs(paths) do
    for _, link in ipairs({ false, true }) do
      local told = link and raw_tables().syscalls.resolve(path, true) or
        observations.resolution(path)
      local want = resolved_before(path, link)
      assert(told == want, (link and "link " or "") .. path:sub(1, 80) .. ": " ..
        told:sub(1, 80) .. " ~= " .. want:sub(1, 80))
    end
  end
end
