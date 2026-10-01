--- What the caches every checkout shares -- the compiles and parses
--- ([`build.shared_compiles`]) and the verdicts ([`build.shared_verdicts`])
--- -- do alike with their SQLite file: open it in write-ahead mode with a
--- busy timeout, tell a busy answer from a broken file, and move a
--- broken file aside so the next run starts a fresh one.
---
--- It is a module of the test harness, through build.shared_verdicts:
--- an edit to it is acknowledged in build/harness_epoch.tl, and a
--- change to that file makes the merge queue run every test (`--all`),
--- which is what sharing it with the compile cache costs. Its clock is the raw binding's,
--- since the harness reaches no cosmic.time.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")
local String = require("cosmic.string")

local record shared_sqlite
end

--- How long a statement waits on another run's lock, in milliseconds:
--- each cache's transactions are short.
local busy_ms <const> = 10000

--- Whether `trouble`, from a statement on a cache, says another
--- connection holds a lock the statement needs, rather than anything
--- of the file. Read as `corrupt` reads its own: SQLite answers its
--- reason only as text.
local function busy(trouble: string): boolean
  return trouble:find("locked", 1, true) ~= nil or trouble:find("busy", 1, true) ~= nil
end

--- Whether `trouble`, from a query of a cache, says the file itself is
--- broken, rather than, say, busy.
function shared_sqlite.corrupt(trouble: string): boolean
  return trouble:find("malformed", 1, true) ~= nil or
    trouble:find("not a database", 1, true) ~= nil
end

--- Moves a broken cache aside, write-ahead log and all, to
--- `<path>.corrupt-<now_ns>`, so the next run starts a fresh cache
--- rather than meeting it again. The log and its index move first, so
--- no one opening the path meanwhile finds the old log beside a new
--- file. Any earlier set-aside file is removed, so at most one is kept.
--- Answers where it went, or nil and why.
function shared_sqlite.set_aside(path: string, now_ns: integer): string | nil, string
  local dir, name = Fs.dirname(path), Fs.basename(path)
  local listed, _ = Fs.list(dir)
  for _, entry in ipairs(listed or {}) do
    if String.starts_with(entry, name .. ".corrupt-") then
      local _, _ = Fs.remove(dir .. "/" .. entry)
    end
  end
  local aside = path .. ".corrupt-" .. tostring(now_ns)
  for _, suffix in ipairs({ "-wal", "-shm" }) do
    local there, _ = Fs.stat(path .. suffix)
    if there ~= nil then
      local _, _ = Fs.rename(path .. suffix, aside .. suffix)
    end
  end
  local moved_file, trouble = Fs.rename(path, aside)
  if not moved_file then return nil, trouble end
  return aside, ""
end

--- Puts `db` in write-ahead mode, so a run's reads never wait on
--- another's write. The switch is one statement that reads the file's
--- header, then writes it. When another connection holds the write lock
--- between those two, as two runs meeting a fresh cache do, SQLite
--- answers "database is locked" at once and calls no busy handler; when
--- another holds the file whole, the busy handler would wait out the
--- busy timeout on each try. So the switch runs with no busy timeout,
--- and a locked answer is tried again every ten milliseconds until
--- `wait_ms` have passed since the first try, on the monotonic clock;
--- once the other's switch is written, this one reads the header and
--- has nothing to write. Any mode but "wal" answered is a failure.
local function to_wal(db: Sqlite.Handle, wait_ms: integer): boolean, string
  local started, clock_trouble = sys.clock_gettime(sys.CLOCK_MONOTONIC)
  if started == nil then return false, clock_trouble end
  local deadline = started + wait_ms * 1000000
  while true do
    local rows, trouble = Sqlite.text_rows(db, "PRAGMA journal_mode = WAL")
    if rows ~= nil then
      local mode = rows[1] ~= nil and rows[1][1] or ""
      if mode ~= "wal" then return false, "journal mode is " .. mode .. ", not wal" end
      return true, ""
    end
    if not busy(trouble) then return false, trouble end
    local now, now_trouble = sys.clock_gettime(sys.CLOCK_MONOTONIC)
    if now == nil then return false, now_trouble end
    if now >= deadline then return false, trouble end
    local _, _ = sys.nanosleep(math.min(10 * 1000000, deadline - now))
  end
end

--- Opens the cache at `path`, which the caller has made ready (its
--- directory, and whatever it holds of the file's mode), in write-ahead
--- mode ([`to_wal`], which waits up to `wait_ms` in all on another run's
--- lock), then `prepare`d, the caller's tables made or checked, under a
--- busy timeout of `wait_ms` a statement. `wait_ms` is ten seconds when
--- nil. Answers the handle, or nil and why, prefixed with `path`, having
--- closed what it opened.
function shared_sqlite.open(path: string, prepare: function(Sqlite.Handle): (boolean, string),
                            wait_ms?: integer): Sqlite.Handle | nil, string
  wait_ms = wait_ms or busy_ms
  local opened, trouble = Sqlite.open(path, true)
  if opened == nil then return nil, path .. ": " .. trouble end
  local db: Sqlite.Handle = opened
  local function fail(why: string): Sqlite.Handle | nil, string
    local _, _ = db:close()
    return nil, path .. ": " .. why
  end
  local untimed, untimed_trouble = db:exec("PRAGMA busy_timeout = 0")
  if not untimed then return fail(untimed_trouble) end
  local journal, journal_trouble = to_wal(db, wait_ms)
  if not journal then return fail(journal_trouble) end
  local timed, time_trouble = db:exec("PRAGMA busy_timeout = " .. wait_ms)
  if not timed then return fail(time_trouble) end
  local prepared, prepare_trouble = prepare(db)
  if not prepared then return fail(prepare_trouble) end
  return db, ""
end

return shared_sqlite
