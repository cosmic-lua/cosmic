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
--- Each session also has a public id, 96 random bits that are not a
--- credential and that a regeneration keeps, so an app can list the
--- sessions it holds ([`SessionSqlite.list`]) and end one by it
--- ([`SessionSqlite.destroy_id`]) without ever showing a cookie: a page of
--- "your devices" with a label each ([`Handle:label`]) and when and from
--- where each was last seen. Last-seen is noted only with
--- `seen_interval`, at most once per interval for a session, after a
--- request that read or saved it.
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
--- @public

-- TODO: once cosmic.poll or cosmic.web offers a blocking-call offload (a
-- worker thread or a task pool), run the session queries there instead of
-- on the serving thread.

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Failure = require("cosmic.failure")
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
    --- The least seconds between two notes of a session as seen, its time
    --- and its client address, which [`SessionSqlite.list`] shows (none:
    --- not noted). Each note is a write, so a client that polls every
    --- second costs one write per interval, not per request.
    seen_interval?: integer
  end

  --- A session as [`SessionSqlite.list`] shows it: never its token.
  record Info
    --- The public id, for [`SessionSqlite.destroy_id`]: not a credential.
    id: string
    --- The user it is bound to ([`Handle:bind_subject`]), or nil.
    subject?: string
    --- Its label ([`Handle:label`]), or nil.
    label?: string
    --- When it began, in seconds since the epoch.
    created: integer
    --- When it ends, in seconds since the epoch.
    expires: integer
    --- When it was last seen, in seconds since the epoch; nil where it
    --- never was (`seen_interval` unset).
    seen_at?: integer
    --- The client address it was last seen from; nil where it never was
    --- seen, "" where the address was not known.
    seen_from?: string
  end

  --- What [`SessionSqlite.list`] takes; every field is optional.
  record ListOptions
    --- Only the sessions bound to this user.
    subject?: string
    --- The most sessions answered (100).
    limit?: integer
  end

end

--- What a store made here remembers beside what [`Session.Store`] holds.
local record Backing
  db: Sqlite.Handle
  table: string
  sweep_interval: integer
  sweep_limit: integer
  seen_interval?: integer
  mut swept: integer
end

--- The backing of each store made here, which goes with the store.
local backings: mut {Session.Store:Backing} = setmetatable({}, { __mode = "k" })

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
--- The bytes of a public id, 16 characters in base64url.
local PUBLIC_BYTES <const> = 12

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
local function delete_expired(store: Backing, now: integer, limit: integer): integer?, string
  local ok, why = store.db:run(("DELETE FROM %s WHERE id_hash IN (SELECT id_hash FROM %s WHERE expires <= ?1 LIMIT ?2)"):
      format(store.table, store.table), { { integer = now }, { integer = limit } })
  if not ok then return nil, "sessions: " .. tostring(why) end
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
function SessionSqlite.sweep(store: Session.Store, now: integer, limit?: integer): integer?, string
  local b = backing(store)
  return delete_expired(b, now, limit or b.sweep_limit)
end

--- Revokes every session bound to `subject` (see [`Handle:bind_subject`]):
--- "sign out everywhere", for a password change. Answers how many.
--- @param store Session.Store The store
--- @param subject string The user key given to `bind_subject`
--- @return integer | nil The count
--- @return string Why none, or ""
function SessionSqlite.destroy_subject(store: Session.Store, subject: string): integer?, string
  local b = backing(store)
  local ok, why = b.db:run(("DELETE FROM %s WHERE subject = ?1"):format(b.table),
    { { text = subject } })
  if not ok then return nil, "sessions: " .. tostring(why) end
  return b.db:changes(), ""
end

--- Runs `work` in a transaction that begins IMMEDIATE and commits when it
--- returns true ([`Sqlite.Handle.transact`]). When `work` returns false or
--- raises, it rolls back. Called inside a transaction the caller opened on
--- the same handle, it is a savepoint of that one, and holds only the
--- locks the caller's own `BEGIN` took.
local function immediate(db: Sqlite.Handle, work: function(): boolean, string): boolean, string
  local ok, why = db:transact(function(): (true) | (false, Failure)
    local done, trouble = work()
    if done then return true end
    assert(trouble, "session: a transaction that answers false says why")
    return false, Failure.new(trouble)
  end, "immediate")
  if not ok then return false, tostring(why) end
  return true, ""
end

--- A new id.
local function new_id(): string?, string
  local bytes, why = Rand.entropy(ID_BYTES)
  if bytes == nil then return nil, "no entropy for a session id: " .. why end
  return Codec.base64url(bytes), ""
end

--- A new public id.
local function new_public_id(): string?, string
  local bytes, why = Rand.entropy(PUBLIC_BYTES)
  if bytes == nil then return nil, "no entropy for a session's public id: " .. why end
  return Codec.base64url(bytes), ""
end

--- The columns a row is read with, in the order [`find`] answers them.
local COLUMNS <const> = "data, created, expires, subject, label, seen_at, seen_from, public_id"

--- The row for `token` that has not expired, or nil.
local function find(store: Backing, token: string, now: integer): Sqlite.Row?, string
  if not is_id(token) then return nil, "" end
  local rows, why = store.db:rows(
    ("SELECT %s FROM %s WHERE id_hash = ?1 AND expires > ?2"):
      format(COLUMNS, store.table), { hash_of(token), { integer = now } })
  if rows == nil then return nil, "sessions: " .. tostring(why) end
  return rows[1], ""
end

--- The values a row's JSON holds; nil for text that is not an object.
local function values_of(text: string): mut {string: Json.Value}?
  local value, _ = Json.decode_object(text, { max_depth = Session.MAX_DEPTH, null_value = Json.null })
  if value == nil then return nil end
  local out: mut {string: Json.Value} = {}
  for key, entry in pairs(value) do out[key] = entry end
  return out
end

local function load_session(self: Session.Store, token: string, now: integer, _cookie: string): Session.Data?, string
  local store = backing(self)
  local row, why = find(store, token, now)
  if row == nil then return nil, why end
  local values = values_of(row:text(1))
  if values == nil then return nil, "" end
  local seen_at: integer? = if row:kind(6) == "integer" then row:integer(6) else nil end
  return { values = values, created = row:integer(2), expires = row:integer(3), seen_at = seen_at }, ""
end

--- The text in column `i` of `row`, or nil where it is NULL.
local function text_or_nil(row: Sqlite.Row, i: integer): string?
  if row:kind(i) == "text" then return row:text(i) end
  return nil
end

--- `text` as a value to bind, NULL for nil.
local function text_value(text: string?): Sqlite.Value
  if text ~= nil then return { text = text } end
  return {}
end

--- `n` as a value to bind, NULL for nil.
local function integer_value(n: integer?): Sqlite.Value
  if n ~= nil then return { integer = n } end
  return {}
end

--- Applies `changes` to `values`.
local function apply(values: {string: Json.Value}, changes: Session.Changes): {string: Json.Value}
  local out: mut {string: Json.Value} = {}
  if changes.cleared ~= true then
    for key, value in pairs(values) do out[key] = value end
  end
  for key, value in pairs(changes.set) do out[key] = value end
  for _, key in ipairs(changes.removed) do out[key] = nil end
  return out
end

local function save_session(self: Session.Store, previous: string, data: Session.Data,
                            changes: Session.Changes, now: integer, _cookie: string): string?, string
  local store = backing(self)
  -- The id the session is saved under when it was given a new one.
  local minted: mut {string} = {}
  local failure: string? = nil
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
    local base: {string: Json.Value} = {}
    local created = data.created
    local subject = changes.subject
    local label = changes.label
    local seen_at: integer? = nil
    local seen_from: string? = nil
    local public_id: string? = nil
    if row ~= nil then
      base = values_of(row:text(1)) or {}
      if changes.regenerated ~= true then created = row:integer(2) end
      if subject == nil then subject = text_or_nil(row, 4) end
      if label == nil then label = text_or_nil(row, 5) end
      if row:kind(6) == "integer" then seen_at = row:integer(6) end
      seen_from = text_or_nil(row, 7)
      public_id = text_or_nil(row, 8)
    end
    if label == "" then label = nil end
    local text, encode_why = Json.encode(apply(base, changes), { max_depth = Session.MAX_DEPTH })
    if text == nil then return false, "cannot encode the session: " .. tostring(encode_why) end
    -- A row without a public id was written by an earlier version running
    -- beside this one after the migration: it gets one at its next save.
    if public_id == nil then
      local fresh, public_why = new_public_id()
      if fresh == nil then return false, public_why end
      public_id = fresh
    end
    if row ~= nil and changes.regenerated ~= true then
      local answered, answer_why = store.db:run(
        ("UPDATE %s SET data = ?2, subject = ?3, touched = ?4, expires = ?5, label = ?6, public_id = ?7 " ..
          "WHERE id_hash = ?1"):format(store.table),
        { hash_of(previous), { text = text }, text_value(subject), { integer = now }, { integer = data.expires },
          text_value(label), { text = public_id } })
      if not answered then return false, tostring(answer_why) end
      return answered, ""
    end
    local id, id_why = new_id()
    if id == nil then return false, id_why end
    minted[1] = id
    if row ~= nil then
      local gone, gone_why = store.db:run(("DELETE FROM %s WHERE id_hash = ?1"):format(store.table),
        { hash_of(previous) })
      if not gone then return false, tostring(gone_why) end
    end
    -- A regenerated session keeps its public id, label and last-seen: it
    -- is the same session under a new credential.
    local answered, answer_why = store.db:run(
      ("INSERT INTO %s (id_hash, data, subject, created, touched, expires, label, seen_at, seen_from, public_id) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)"):format(store.table),
      { hash_of(id), { text = text }, text_value(subject), { integer = created }, { integer = now },
        { integer = data.expires }, text_value(label), integer_value(seen_at), text_value(seen_from),
        { text = public_id } })
    if not answered then return false, tostring(answer_why) end
    return answered, ""
  end)
  if not ok then failure = why end
  if failure ~= nil then return nil, "sessions: " .. failure end
  if now - store.swept >= store.sweep_interval then
    store.swept = now
    -- A failed sweep costs a later one, not this request.
    local _, _ = delete_expired(store, now, store.sweep_limit)
  end
  return minted[1] or previous, ""
end

local function destroy_session(self: Session.Store, token: string): boolean, string
  local store = backing(self)
  if not is_id(token) then return true, "" end
  local ok, why = store.db:run(("DELETE FROM %s WHERE id_hash = ?1"):format(store.table),
    { hash_of(token) })
  if not ok then return false, "sessions: " .. tostring(why) end
  return true, ""
end

local function seen_session(self: Session.Store, token: string, data: Session.Data, now: integer, from: string)
  local store = backing(self)
  local interval = store.seen_interval
  if interval == nil or not is_id(token) then return end
  local last = data.seen_at
  if last ~= nil and now - last < interval then return end
  -- The guard keeps two requests that loaded the same old note from both
  -- writing; a failure costs the note, not the request.
  local _, _ = store.db:run(
    ("UPDATE %s SET seen_at = ?2, seen_from = ?3 WHERE id_hash = ?1 AND (seen_at IS NULL OR seen_at <= ?4)"):
      format(store.table), { hash_of(token), { integer = now }, { text = from }, { integer = now - interval } })
end

--- The info of the session in `row`, read with [`INFO_COLUMNS`].
local function info_of(row: Sqlite.Row): SessionSqlite.Info
  local seen_at: integer? = if row:kind(6) == "integer" then row:integer(6) else nil end
  return { id = row:text(1), subject = text_or_nil(row, 2), label = text_or_nil(row, 3), created = row:integer(4),
    expires = row:integer(5), seen_at = seen_at, seen_from = text_or_nil(row, 7) }
end

--- The columns [`info_of`] reads, in its order.
local INFO_COLUMNS <const> = "public_id, subject, label, created, expires, seen_at, seen_from"

--- The sessions that have not expired at `now`, all or one user's: the
--- one seen last first (one never seen by when it began), at most `limit`.
--- Never a token: each has its public id, for [`SessionSqlite.destroy_id`].
--- The query reads every live row (or every one of the user's), which a
--- list page can afford and a request on every page should not.
--- @param store Session.Store The store
--- @param now integer The time in seconds since the epoch
--- @param opts SessionSqlite.ListOptions | nil The user and the limit
--- @return {SessionSqlite.Info} | nil The sessions
--- @return string Why none, or ""
function SessionSqlite.list(store: Session.Store, now: integer, opts?: SessionSqlite.ListOptions): {SessionSqlite.Info}?, string
  local b = backing(store)
  local o: SessionSqlite.ListOptions = opts or {}
  local params: mut {Sqlite.Value} = { { integer = now } }
  -- A row an earlier version wrote after the migration has no public id
  -- until its next save, and cannot be shown or ended by one.
  local where = "expires > ?1 AND public_id IS NOT NULL"
  local subject = o.subject
  if subject ~= nil then
    params[#params + 1] = { text = subject }
    where = where .. " AND subject = ?2"
  end
  local limit = o.limit or 100
  if limit < 1 then error("session: limit is a number of sessions, at least 1", 2) end
  params[#params + 1] = { integer = limit }
  local rows, why = b.db:rows(
    ("SELECT %s FROM %s WHERE %s ORDER BY coalesce(seen_at, created) DESC, created DESC, public_id LIMIT ?%d"):
      format(INFO_COLUMNS, b.table, where, #params), params)
  if rows == nil then return nil, "sessions: " .. tostring(why) end
  local out: mut {SessionSqlite.Info} = {}
  for _, row in ipairs(rows) do out[#out + 1] = info_of(row) end
  return out, ""
end

--- The info of the session `token` names, as [`SessionSqlite.list`] shows it,
--- so a page can mark the request's own session (`token` from
--- [`Handle:id`]); nil and "" where it names none that is live.
--- @param store Session.Store The store
--- @param token string The session's token
--- @param now integer The time in seconds since the epoch
--- @return SessionSqlite.Info | nil The session
--- @return string Why none, or ""
function SessionSqlite.info(store: Session.Store, token: string, now: integer): SessionSqlite.Info?, string
  local b = backing(store)
  if not is_id(token) then return nil, "" end
  local rows, why = b.db:rows(("SELECT %s FROM %s WHERE id_hash = ?1 AND expires > ?2 AND public_id IS NOT NULL"):
      format(INFO_COLUMNS, b.table), { hash_of(token), { integer = now } })
  if rows == nil then return nil, "sessions: " .. tostring(why) end
  local row = rows[1]
  if row == nil then return nil, "" end
  return info_of(row), ""
end

--- `sql` and `params` narrowed to the sessions of `subject`, where given.
local function scoped(sql: string, params: {Sqlite.Value}, subject?: string): string, {Sqlite.Value}
  if subject == nil then return sql, params end
  local out: mut {Sqlite.Value} = {}
  for _, value in ipairs(params) do out[#out + 1] = value end
  out[#out + 1] = { text = subject }
  return ("%s AND subject = ?%d"):format(sql, #out), out
end

--- Revokes the session whose public id is `id` (from [`SessionSqlite.list`]):
--- "forget this device". Answers how many, 0 or 1. An app checks that the
--- user may end that session first, as the id is shown, not secret, or
--- passes `subject`, which ends it only where it is that user's.
--- @param store Session.Store The store
--- @param id string The public id
--- @param subject string | nil Only a session bound to this user
--- @return integer | nil The count
--- @return string Why none, or ""
function SessionSqlite.destroy_id(store: Session.Store, id: string, subject?: string): integer?, string
  local b = backing(store)
  local sql, params = scoped(("DELETE FROM %s WHERE public_id = ?1"):format(b.table), { { text = id } }, subject)
  local ok, why = b.db:run(sql, params)
  if not ok then return nil, "sessions: " .. tostring(why) end
  return b.db:changes(), ""
end

--- Gives the session whose public id is `id` the label `text`, or removes
--- it with "": renaming a device from a list. Answers how many, 0 or 1.
--- Raises for a label [`Handle:label`] refuses. With `subject`, only a
--- session bound to that user.
--- @param store Session.Store The store
--- @param id string The public id
--- @param text string The label
--- @param subject string | nil Only a session bound to this user
--- @return integer | nil The count
--- @return string Why none, or ""
function SessionSqlite.label(store: Session.Store, id: string, text: string, subject?: string): integer?, string
  local b = backing(store)
  if type(text) ~= "string" or #text > Session.MAX_LABEL or not utf8.len(text) then
    error("session: a label is UTF-8 text no longer than Session.MAX_LABEL (" .. tostring(Session.MAX_LABEL) .. ")", 2)
  end
  local sql, params = scoped(("UPDATE %s SET label = ?2 WHERE public_id = ?1"):format(b.table),
    { { text = id }, text_value(if text == "" then nil else text end) }, subject)
  local ok, why = b.db:run(sql, params)
  if not ok then return nil, "sessions: " .. tostring(why) end
  return b.db:changes(), ""
end

--- The columns a table made before public ids and last-seen lacks, with
--- their types: [`migrate`] adds them.
local ADDED <const>: {{string}} = {
  { "label", "TEXT" }, { "seen_at", "INTEGER" }, { "seen_from", "TEXT" }, { "public_id", "TEXT" },
}

--- Makes the table, or brings one an earlier version made up to date:
--- adds the columns it lacks, gives each row without one a public id and
--- indexes them. Inside one IMMEDIATE transaction, so two processes that
--- open the file at once do not both alter it.
local function migrate(db: Sqlite.Handle, name: string): boolean, string
  return immediate(db, function(): boolean, string
    local ok, why = db:exec(([[
CREATE TABLE IF NOT EXISTS %s (
  id_hash BLOB PRIMARY KEY,
  data TEXT NOT NULL,
  subject TEXT,
  created INTEGER NOT NULL,
  touched INTEGER NOT NULL,
  expires INTEGER NOT NULL,
  label TEXT,
  seen_at INTEGER,
  seen_from TEXT,
  public_id TEXT
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS %s_expires ON %s (expires);
CREATE INDEX IF NOT EXISTS %s_subject ON %s (subject) WHERE subject IS NOT NULL;]]):
        format(name, name, name, name, name))
    if not ok then return false, tostring(why) end
    local columns, columns_why = db:rows(("PRAGMA table_info(%s)"):format(name))
    if columns == nil then return false, tostring(columns_why) end
    local have: mut {string: boolean} = {}
    for _, column in ipairs(columns) do have[column:text(2)] = true end
    for _, added in ipairs(ADDED) do
      local column, kind = assert(added[1]), assert(added[2])
      if have[column] == nil then
        local altered, alter_why = db:exec(("ALTER TABLE %s ADD COLUMN %s %s"):format(name, column, kind))
        if not altered then return false, tostring(alter_why) end
      end
    end
    local bare, bare_why = db:rows(("SELECT id_hash FROM %s WHERE public_id IS NULL"):format(name))
    if bare == nil then return false, tostring(bare_why) end
    for _, row in ipairs(bare) do
      local public_id, public_why = new_public_id()
      if public_id == nil then return false, public_why end
      local set, set_why = db:run(("UPDATE %s SET public_id = ?2 WHERE id_hash = ?1"):format(name),
        { { blob = row:blob(1) }, { text = public_id } })
      if not set then return false, tostring(set_why) end
    end
    local done, done_why = db:exec(("CREATE UNIQUE INDEX IF NOT EXISTS %s_public_id ON %s (public_id)"):format(name, name))
    if not done then return false, tostring(done_why) end
    return true, ""
  end)
end

--- Opens the table (created if missing) on `db`, a writable handle, and
--- sets WAL, `synchronous=NORMAL` and a 250 ms busy timeout unless
--- `configure` is false. A table an earlier version made gains the
--- columns of public ids, labels and last-seen, and each of its sessions
--- a public id, once, at the first open. Nil and why when the table
--- cannot be made. Raises for a table name that is not a plain
--- identifier, which is put in SQL.
--- @param db Sqlite.Handle The database
--- @param opts SessionSqlite.Options | nil The table and sweep
--- @return Session.Store | nil The store
--- @return string Why none, or ""
function SessionSqlite.store(db: Sqlite.Handle, opts?: SessionSqlite.Options): Session.Store?, string
  local o: SessionSqlite.Options = opts or {}
  local name = o.table or "web_sessions"
  if name:match("^[A-Za-z_][A-Za-z0-9_]*$") == nil then
    error("session: the table name must be an identifier (letters, digits, '_')", 2)
  end
  if o.configure ~= false then
    -- A memory database stays as it is.
    local switched, mode_why = db:wal()
    if not switched then return nil, "sessions: " .. tostring(mode_why) end
    local ok, why = db:exec("PRAGMA synchronous=NORMAL")
    if not ok then return nil, "sessions: " .. tostring(why) end
    db:busy_timeout(Clock.ms(250))
  end
  local seen_interval = o.seen_interval
  if seen_interval ~= nil and seen_interval < 1 then
    error("session: seen_interval is a number of seconds, at least 1", 2)
  end
  local ok, why = migrate(db, name)
  if not ok then return nil, "sessions: " .. why end
  local store: Session.Store = {
    load = load_session, save = save_session, destroy = destroy_session, revocable = true,
    seen = if seen_interval ~= nil then seen_session else nil end,
  }
  backings[store] = { db = db, table = name, sweep_interval = o.sweep_interval or 600,
    sweep_limit = o.sweep_limit or 500, seen_interval = seen_interval, swept = 0 }
  return store, ""
end

return SessionSqlite
