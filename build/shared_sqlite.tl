--- What the caches every checkout shares -- the compiles and parses
--- (`build.shared_compiles`) and the verdicts (`build.shared_verdicts`)
--- -- do alike with their SQLite file: open it in write-ahead mode with a
--- busy timeout, tell a busy answer from a broken file, and move a
--- broken file aside so the next run starts a fresh one.
---
--- It is a module of the test harness, through build.shared_verdicts,
--- so an edit to it is acknowledged in build/harness_epoch.tl; its
--- clock is the raw binding's, since the harness reaches no cosmic.time.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local sys = require("cosmic.sys")

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
    if entry:sub(1, #name + 9) == name .. ".corrupt-" then
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
--- answers "database is locked" at once and calls no busy handler. So a
--- locked answer is tried again, up to `wait_ms`; once the other's
--- switch is written, this one reads the header and has nothing to
--- write.
local function to_wal(db: Sqlite.Handle, wait_ms: integer): boolean, string
  local waited_ms = 0
  while true do
    local rows, trouble = Sqlite.text_rows(db, "PRAGMA journal_mode = WAL")
    if rows ~= nil then return true, "" end
    if not busy(trouble) or waited_ms >= wait_ms then return false, trouble end
    local _, _ = sys.nanosleep(10 * 1000000)
    waited_ms = waited_ms + 10
  end
end

--- Opens the cache at `path`, which the caller has made ready (its
--- directory, and whatever it holds of the file's mode), waiting up to
--- `wait_ms` (ten seconds when nil) on another run's lock,
--- in write-ahead mode, and `prepare`d: the caller's tables made or
--- checked. Answers the handle, or nil and why, prefixed with `path`,
--- having closed what it opened.
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
  local timed, time_trouble = db:exec("PRAGMA busy_timeout = " .. wait_ms)
  if not timed then return fail(time_trouble) end
  local journal, journal_trouble = to_wal(db, wait_ms)
  if not journal then return fail(journal_trouble) end
  local prepared, prepare_trouble = prepare(db)
  if not prepared then return fail(prepare_trouble) end
  return db, ""
end

return shared_sqlite
