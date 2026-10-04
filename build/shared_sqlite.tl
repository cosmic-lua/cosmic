--- What the caches every checkout shares -- the compiles and parses
--- ([`build.shared_compiles`]) and the verdicts ([`build.shared_verdicts`])
--- -- do alike with their SQLite file: open it in write-ahead mode with a
--- busy timeout and retry a busy answer within a bounded wait.
---
--- It is a module of the test harness, through build.shared_verdicts:
--- an edit to it is acknowledged in build/harness_epoch.tl, and a
--- change to that file makes the merge queue run every test (`--all`),
--- which is what sharing it with the compile cache costs. Its clock is the raw binding's,
--- since the harness reaches no cosmic.clock.

local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")

local text_rows_result <const> = Sqlite.text_rows_result

local record shared_sqlite
end

-- One millisecond in nanoseconds, which SQLite counts its busy timeout
-- in: cosmic.clock, whose `ms` and `ceil` this is, is no module the
-- harness may reach (build/harness_epoch.tl's `library`).
local MS <const> = 1000 * 1000

--- How long a statement waits on another run's lock, in nanoseconds:
--- each cache's transactions are short.
local busy_ns <const> = 10000 * MS

--- Puts `db` in write-ahead mode, so a run's reads never wait on
--- another's write. The switch is one statement that reads the file's
--- header, then writes it. When another connection holds the write lock
--- between those two, as two runs meeting a fresh cache do, SQLite
--- answers "database is locked" at once and calls no busy handler; when
--- another holds the file whole, the busy handler would wait out the
--- busy timeout on each try. So the switch runs with no busy timeout,
--- and a locked answer is tried again every ten milliseconds until
--- `wait_ns` have passed since the first try, on the monotonic clock;
--- once the other's switch is written, this one reads the header and
--- has nothing to write. A captured guard cancellation stops the retry;
--- SQLite can refuse a lock without calling that handler. Any mode but
--- "wal" answered is a failure.
local function to_wal(db: Sqlite.Handle, wait_ns: integer): boolean, string
  local started, clock_trouble = sys.clock_gettime(sys.CLOCK_MONOTONIC)
  if started == nil then return false, clock_trouble end
  local deadline = started + wait_ns
  while true do
    local result = text_rows_result(db, "PRAGMA journal_mode = WAL")
    if result.rows ~= nil then
      local mode = result.rows[1] ~= nil and result.rows[1][1] or ""
      if mode ~= "wal" then return false, "journal mode is " .. mode .. ", not wal" end
      return true, ""
    end
    if result.cancelled or (result.code ~= Sqlite.BUSY and result.code ~= Sqlite.LOCKED) then
      return false, result.reason
    end
    local now, now_trouble = sys.clock_gettime(sys.CLOCK_MONOTONIC)
    if now == nil then return false, now_trouble end
    if now >= deadline then return false, result.reason end
    local _, _ = sys.nanosleep(math.min(10 * MS, deadline - now))
  end
end

--- Opens the cache at `path`, which the caller has made ready (its
--- directory, and whatever it holds of the file's mode), in write-ahead
--- mode ([`to_wal`], which waits up to `wait_ns` in all on another run's
--- lock), then `prepare`d, the caller's tables made or checked, under a
--- busy timeout of `wait_ns` a statement, in whole milliseconds, rounded
--- up. `wait_ns` is ten seconds when nil. Answers the handle, or nil and why, prefixed with `path`, having
--- closed what it opened.
function shared_sqlite.open(path: string, prepare: function(Sqlite.Handle): (boolean, string),
                            wait_ns?: integer): Sqlite.Handle | nil, string
  wait_ns = wait_ns or busy_ns
  local opened, trouble = Sqlite.open(path, { writable = true })
  if opened == nil then return nil, path .. ": " .. trouble end
  local db: Sqlite.Handle = opened
  local function fail(why: string): Sqlite.Handle | nil, string
    local _, _ = db:close()
    return nil, path .. ": " .. why
  end
  db:busy_timeout(0)
  local journal, journal_trouble = to_wal(db, wait_ns)
  if not journal then return fail(journal_trouble) end
  local timed, time_trouble = db:exec("PRAGMA busy_timeout = " .. -(-wait_ns // MS))
  if not timed then return fail(time_trouble) end
  local prepared, prepare_trouble = prepare(db)
  if not prepared then return fail(prepare_trouble) end
  return db, ""
end

return shared_sqlite
