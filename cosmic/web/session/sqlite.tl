--- The SQLite store of [`cosmic.web.session`]: the data stays on the
--- server under an unguessable id, which makes a session revocable
--- (logout is real, [`destroy_subject`] ends every session of a user) and
--- keeps its size and its contents from the browser.
---
---     local db = assert(Sqlite.open("app.db", { writable = true }))
---     local store = assert(SessionSqlite.store(db))
---
--- The id is 256 random bits from the system's entropy source
--- ([`Rand.entropy`]), and the cookie holds only it: an unguessable id is
--- the credential, so there is nothing to sign. The table keeps the
--- SHA-256 of the id, so a copy of the database (a backup, an injection)
--- holds no live cookie.
---
--- **Sqlite blocks the thread.** A session query runs inside the handler's
--- task and no other connection is served meanwhile. A point lookup or
--- insert on a WAL database is microseconds, which a handler can afford; an
--- fsync on a slow disk, a lock held by another process (`busy_timeout`,
--- 250 ms here, is a blocking sleep of the whole server) or a large delete
--- is where it hurts. So the store reads only by primary key, writes only
--- when a request changed the session, bounds its sweep of expired rows,
--- and wants one handle for the app and, if another process writes the
--- file, the sessions in a file of their own. A save is one transaction
--- that never yields, so it is atomic against the other requests of this
--- process and two requests that change different keys both land.

-- TODO: once cosmic.poll or cosmic.web offers a blocking-call offload (a
-- worker thread or a task pool), run the session queries there instead of
-- on the serving thread.

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Rand = require("cosmic.rand")
local Session = require("cosmic.web.session")
local Sqlite = require("cosmic.sqlite")

local record SessionSqlite
  --- What [`SessionSqlite.store`] takes; every field is optional.
  record Options
    --- The table's name, a plain identifier ("web_sessions").
    table?: string
    --- The least seconds between two opportunistic sweeps of expired rows,
    --- run after a save (600).
    sweep_interval?: integer
    --- The most rows one sweep deletes (500).
    sweep_limit?: integer
    --- Set journal mode WAL, synchronous NORMAL and a 250 ms busy timeout
    --- on the handle (true); false leaves the connection as it is.
    configure?: boolean
  end

end

--- What a store made here remembers beside what [`Session.Store`] holds.
local record Backing
  db: Sqlite.Handle
  table: string
  sweep_interval: integer
  sweep_limit: integer
  swept: integer
end

--- The backing of each store made here, which goes with the store.
local backings: {Session.Store:Backing} = setmetatable({}, { __mode = "k" })

local function backing(store: Session.Store): Backing
  local found = backings[store]
  if found == nil then
    error("session: not a store made by SessionSqlite.store", 3)
  end
  return found
end

local ID_BYTES <const> = 32
--- The length of an id as text: 32 bytes in unpadded base64url.
local ID_CHARS <const> = 43

local function hash_of(id: string): Sqlite.Value
  return { blob = Hash.sha256(id) }
end

--- Whether `token` can be an id this store made.
local function is_id(token: string): boolean
  if #token ~= ID_CHARS then return false end
  local bytes, _ = Codec.unbase64url(token)
  return bytes ~= nil
end

--- Deletes up to `limit` rows that expired at or before `now`.
local function delete_expired(store: Backing, now: integer, limit: integer): integer | nil, string
  local ok, why = Sqlite.run(store.db, ("DELETE FROM %s WHERE id_hash IN (SELECT id_hash FROM %s WHERE expires <= ?1 LIMIT ?2)"):
      format(store.table, store.table), { { integer = now }, { integer = limit } })
  if not ok then return nil, "sessions: " .. why end
  return store.db:changes(), ""
end

--- Deletes up to `limit` (the store's `sweep_limit` by default) expired
--- sessions, for a lifespan task that sweeps on a timer; a save sweeps on
--- its own every `sweep_interval`. Answers how many it deleted.
--- @param store Session.Store The store
--- @param now integer The time in seconds since the epoch
--- @param limit integer | nil The most rows
--- @return integer | nil The count
--- @return string Why none, or ""
function SessionSqlite.sweep(store: Session.Store, now: integer, limit?: integer): integer | nil, string
  local b = backing(store)
  return delete_expired(b, now, limit or b.sweep_limit)
end

--- Revokes every session bound to `subject` (see [`Handle:bind_subject`]):
--- "sign out everywhere", for a password change. Answers how many.
--- @param store Session.Store The store
--- @param subject string The user key given to `bind_subject`
--- @return integer | nil The count
--- @return string Why none, or ""
function SessionSqlite.destroy_subject(store: Session.Store, subject: string): integer | nil, string
  local b = backing(store)
  local ok, why = Sqlite.run(b.db, ("DELETE FROM %s WHERE subject = ?1"):format(b.table),
    { { text = subject } })
  if not ok then return nil, "sessions: " .. why end
  return b.db:changes(), ""
end

--- Runs `work` in a transaction that begins IMMEDIATE and commits when it
--- answers true, as [`Sqlite.transact`] does, which begins deferred and has no
--- option for this. When `work` answers false or raises, it rolls back.
--- TODO: once Sqlite.transact takes a begin mode, use it.
local function immediate(db: Sqlite.Handle, work: function(): boolean, string): boolean, string
  local began, begin_why = Sqlite.run(db, "BEGIN IMMEDIATE")
  if not began then return false, begin_why end
  local ran, ok, why = pcall(work)
  if not ran then
    local _, _ = Sqlite.run(db, "ROLLBACK")
    error(ok, 0)
  end
  if not ok then
    local _, _ = Sqlite.run(db, "ROLLBACK")
    return false, why
  end
  local committed, commit_why = Sqlite.run(db, "COMMIT")
  if not committed then
    local _, _ = Sqlite.run(db, "ROLLBACK")
    return false, commit_why
  end
  return true, ""
end

--- A new id.
local function new_id(): string | nil, string
  local bytes, why = Rand.entropy(ID_BYTES)
  if bytes == nil then return nil, "no entropy for a session id: " .. why end
  return Codec.base64url(bytes), ""
end

--- The row for `token` that has not expired, or nil.
local function find(store: Backing, token: string, now: integer): Sqlite.Row | nil, string
  if not is_id(token) then return nil, "" end
  local rows, why = Sqlite.rows(store.db,
    ("SELECT data, created, expires, subject FROM %s WHERE id_hash = ?1 AND expires > ?2"):
      format(store.table), { hash_of(token), { integer = now } })
  if rows == nil then return nil, "sessions: " .. why end
  return rows[1], ""
end

--- The values a row's JSON holds; nil for text that is not an object.
local function values_of(text: string): {string:any} | nil
  local value, _ = Json.decode(text, { max_depth = Session.MAX_DEPTH })
  if value is {string:any} then return value end
  return nil
end

local function load_session(self: Session.Store, token: string, now: integer, _cookie: string): Session.Data | nil, string
  local store = backing(self)
  local row, why = find(store, token, now)
  if row == nil then return nil, why end
  local values = values_of(assert(row[1].text))
  if values == nil then return nil, "" end
  return { values = values, created = row[2].integer, expires = row[3].integer }, ""
end

--- Applies `changes` to `values`.
local function apply(values: {string:any}, changes: Session.Changes): {string:any}
  local out: {string:any} = {}
  if not changes.cleared then
    for key, value in pairs(values) do out[key] = value end
  end
  for key, value in pairs(changes.set) do out[key] = value end
  for _, key in ipairs(changes.removed) do out[key] = nil end
  return out
end

local function save_session(self: Session.Store, previous: string, data: Session.Data,
                            changes: Session.Changes, now: integer, _cookie: string): string | nil, string
  local store = backing(self)
  local token = previous
  local failure: string | nil = nil
  -- No yield between the first read and the commit: another request of
  -- this process cannot interleave, and another process meets SQLite's lock.
  -- The transaction begins IMMEDIATE, taking the write lock before the read:
  -- a deferred one that read, then found another process had written,
  -- would fail its write at once with SQLITE_BUSY_SNAPSHOT, which the busy
  -- timeout does not wait out; waiting for the lock first is the busy
  -- timeout's case.
  local ok, why = immediate(store.db, function(): boolean, string
    local row, find_why = find(store, previous, now)
    if row == nil and find_why ~= "" then return false, find_why end
    -- A session revoked while this request ran is not revived with what
    -- the request saw: only what it changed is kept.
    local base: {string:any} = {}
    local created = data.created
    local subject = changes.subject
    if row ~= nil then
      base = values_of(assert(row[1].text)) or {}
      if not changes.regenerated then created = row[2].integer end
      if subject == nil and row[4].kind == "text" then subject = row[4].text end
    end
    local text, encode_why = Json.encode(apply(base, changes), { max_depth = Session.MAX_DEPTH })
    if text == nil then return false, "cannot encode the session: " .. encode_why end
    local subject_value: Sqlite.Value = subject ~= nil and { text = subject } or {}
    if row ~= nil and not changes.regenerated then
      return Sqlite.run(store.db,
        ("UPDATE %s SET data = ?2, subject = ?3, touched = ?4, expires = ?5 WHERE id_hash = ?1"):
          format(store.table),
        { hash_of(previous), { text = text }, subject_value, { integer = now }, { integer = data.expires } })
    end
    local id, id_why = new_id()
    if id == nil then return false, id_why end
    token = id
    if row ~= nil then
      local gone, gone_why = Sqlite.run(store.db, ("DELETE FROM %s WHERE id_hash = ?1"):format(store.table),
        { hash_of(previous) })
      if not gone then return false, gone_why end
    end
    return Sqlite.run(store.db,
      ("INSERT INTO %s (id_hash, data, subject, created, touched, expires) VALUES (?1, ?2, ?3, ?4, ?5, ?6)"):
        format(store.table),
      { hash_of(id), { text = text }, subject_value, { integer = created }, { integer = now },
        { integer = data.expires } })
  end)
  if not ok then failure = why end
  if failure ~= nil then return nil, "sessions: " .. failure end
  if now - store.swept >= store.sweep_interval then
    store.swept = now
    -- A failed sweep costs a later one, not this request.
    local _, _ = delete_expired(store, now, store.sweep_limit)
  end
  return token, ""
end

local function destroy_session(self: Session.Store, token: string): boolean, string
  local store = backing(self)
  if not is_id(token) then return true, "" end
  local ok, why = Sqlite.run(store.db, ("DELETE FROM %s WHERE id_hash = ?1"):format(store.table),
    { hash_of(token) })
  if not ok then return false, "sessions: " .. why end
  return true, ""
end

--- Opens the table (created if missing) on `db`, a writable handle, and
--- sets WAL, `synchronous=NORMAL` and a 250 ms busy timeout unless
--- `configure` is false. Nil and why when the table cannot be made. Raises
--- for a table name that is not a plain identifier, which is put in SQL.
--- @param db Sqlite.Handle The database
--- @param opts SessionSqlite.Options | nil The table and sweep
--- @return Session.Store | nil The store
--- @return string Why none, or ""
function SessionSqlite.store(db: Sqlite.Handle, opts?: SessionSqlite.Options): Session.Store | nil, string
  local o: SessionSqlite.Options = opts or {}
  local name = o.table or "web_sessions"
  if name:match("^[A-Za-z_][A-Za-z0-9_]*$") == nil then
    error("session: the table name must be an identifier (letters, digits, '_')", 2)
  end
  if o.configure ~= false then
    -- The mode answers a row; a memory database stays as it is.
    local rows, mode_why = Sqlite.rows(db, "PRAGMA journal_mode=WAL")
    if rows == nil then return nil, "sessions: " .. mode_why end
    local ok, why = db:exec("PRAGMA synchronous=NORMAL")
    if not ok then return nil, "sessions: " .. why end
    db:busy_timeout(Clock.ms(250))
  end
  local ok, why = db:exec(([[
CREATE TABLE IF NOT EXISTS %s (
  id_hash BLOB PRIMARY KEY,
  data TEXT NOT NULL,
  subject TEXT,
  created INTEGER NOT NULL,
  touched INTEGER NOT NULL,
  expires INTEGER NOT NULL
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS %s_expires ON %s (expires);
CREATE INDEX IF NOT EXISTS %s_subject ON %s (subject) WHERE subject IS NOT NULL;]]):
      format(name, name, name, name, name))
  if not ok then return nil, "sessions: " .. why end
  local store: Session.Store = {
    load = load_session, save = save_session, destroy = destroy_session, revocable = true,
  }
  backings[store] = { db = db, table = name, sweep_interval = o.sweep_interval or 600,
    sweep_limit = o.sweep_limit or 500, swept = 0 }
  return store, ""
end

return SessionSqlite
