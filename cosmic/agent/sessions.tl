--- @public
--- sessions.db: what `cosmic agent` keeps. As pi keeps a session file of
--- one entry a message, a session here is a row of `sessions` and a row
--- of `messages` for each message, the message as the API takes it, in
--- JSON, so a later command can go on with it (`--continue`,
--- `--session`). Each tool's whole output is a row of `outputs` too,
--- indexed for full-text search (FTS5, trigram), so the model reads a
--- short part of it and finds the rest, with its sql tool, when it
--- needs it.
---
--- cosmic agent keeps each conversation in sessions.db, in its data
--- directory ($XDG_DATA_HOME/cosmic/agent, or ~/.local/share/cosmic/agent), as
--- pi keeps a session file: every message as the API takes it, the
--- model's thinking and the tool results included.
---
---     sessions      id, cwd, started (Unix time), model (the last used),
---                   restarts and ended (of the last turn)
---     messages      session, seq (from 1), message (JSON)
---     outputs       id, session, tool, input (JSON), text (the whole
---                   output), is_error, call (the tool_use id), shown
---                   (what the model read, where less than text)
---     outputs_fts   FTS5 over outputs.text, trigram, for sql (but sql's own)
---     requests      each request to the API: when (started, Unix ms) and
---                   how long (ms); what was asked (model, effort,
---                   max_tokens, betas, system, shape: the rest of the
---                   body sent, tools and options, all but its messages;
---                   request_headers: as JSON, less any that may hold a
---                   credential; build: the cosmic that sent it); what
---                   came back (status, error, served: the model that
---                   answered, stop_reason, request_id, headers: the
---                   reply's, as JSON, less credentials, first_ms: how
---                   soon its content began, reply: the whole message,
---                   put back together from the stream, or the stream
---                   as it came where it could not be); and the usage (input_tokens,
---                   output_tokens, cache_read, cache_write_5m,
---                   cache_write_1h, context: their input sum, cost:
---                   USD at the list prices it knows, NULL for
---                   another model or a reply with no usage); after a
---                   fallback, the token counts are the attempt that
---                   answered, and cost sums every attempt at its own
---                   model's price (an upper bound: some declines before
---                   output are not billed), a compaction's included;
---                   cache_miss and cache_missed: why the cache missed
---                   against the reply before (as the reply's
---                   diagnostics name it: system_changed and the like)
---                   and how many tokens; where the API refuses the
---                   reply named, the request goes again naming none.
---                   On a request that compacted, the token counts are
---                   its final message's alone, cost the compaction's
---                   too (usage.iterations in reply); seq is the message
---                   its reply added
---     systems       each system prompt sent, once (requests.system)
---     shapes        each body sent less messages and system, once
---                   (requests.shape): a request's whole body is its
---                   shape, its system prompt, messages 1 to seq-1 and
---                   diagnostics naming the id of the reply before
---                   (null for none)
---     kept          session, key, value (JSON): what a snippet of the
---                   run tool kept for a later one (cosmic.agent.host's
---                   store), which a resumed session reads again; the
---                   sql tool reads every session's
---
--- A database of version 1 is made version 2 as it opens. There is no
--- way back: an older cosmic refuses a newer one's database.
---
--- Ask and chat go on with the newest session in the working directory
--- unless --new starts one; --session <id> goes on with any, and --fork
--- in a copy, with the model it used last unless --model names one.
--- `cosmic agent sessions` lists them. The file is 0600, and its directory
--- 0700: it holds what the tools read. Read it with sqlite3, and
--- delete it to forget every session.

local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local Failure = require("cosmic.failure")

local record Sessions
  --- One session, as `cosmic agent sessions` lists it.
  record Summary
    --- Its id.
    id: integer
    --- When it started, as UTC.
    started: string
    --- The model it used last.
    model: string
    --- How many messages it holds.
    messages: integer
    --- Its first prompt.
    first: string
    --- What its requests cost, in USD.
    cost: number
    --- The input tokens of its last request.
    context: integer
  end

  --- A session as it was left: its messages, the model it used last,
  --- how often its last turn was started again, and whether that turn
  --- ended for good (not to be resumed).
  record Loaded
    --- Its messages, in order.
    messages: {Json.Value}
    --- The model it used last.
    model: string
    --- How often its last turn was started again.
    restarts: integer
    --- Whether its last turn ended for good.
    ended: boolean
  end

  --- One tool call's output, as [`Sessions.output`] keeps it.
  record Output
    --- The tool that made it.
    tool: string
    --- The call's input, as JSON.
    input: string
    --- The whole output.
    text: string
    --- Whether it was an error.
    is_error: boolean
    --- The id of the tool_use block that called it.
    call?: string
  end

  --- One request to the Messages API, as [`Sessions.request`] keeps it.
  record Request
    --- The seq of the message the reply added, where it added one.
    mut seq?: integer
    --- When it was sent (Unix time, in milliseconds).
    mut started: integer
    --- How long it took, in milliseconds.
    mut ms: integer
    --- The model asked for.
    mut model: string
    --- The effort asked for.
    mut effort: string
    --- The most tokens asked for.
    mut max_tokens: integer
    --- The beta headers, joined by commas.
    mut betas: string
    --- The system prompt.
    mut system: string
    --- The final HTTP status, or 0 where none came.
    mut status: integer
    --- Why it failed, where it did.
    mut error?: string
    --- The model that served the reply.
    mut served?: string
    --- Why the reply stopped.
    mut stop_reason?: string
    --- The request-id header.
    mut request_id?: string
    --- The reply's headers, as JSON, less any that may hold a credential.
    mut headers: string
    --- The rest of the body sent, as JSON: all but its messages and system prompt.
    mut shape: string
    --- The build of cosmic that sent it.
    mut build?: string
    --- The headers sent, as JSON, less any that may hold a credential.
    mut request_headers?: string
    --- How long until the first of the reply's content came, in milliseconds.
    mut first_ms?: integer
    --- Input tokens, not read from or written to the cache.
    mut input_tokens?: integer
    --- Output tokens.
    mut output_tokens?: integer
    --- Input tokens read from the cache.
    mut cache_read?: integer
    --- Input tokens written to the 5-minute cache.
    mut cache_write_5m?: integer
    --- Input tokens written to the 1-hour cache.
    mut cache_write_1h?: integer
    --- What it cost, in USD, at the agent's prices: nil for a model it has none for.
    mut cost?: number
    --- The whole body of the reply.
    mut reply?: string
  end

  --- What answered a tool call, as the model read it.
  record Answer
    --- What the model read.
    text: string
    --- Whether it was an error.
    is_error: boolean
  end

end

--- What version 2 adds to version 1: the values a snippet keeps ([`Sessions.keep`]).
local KEPT <const> = [[
CREATE TABLE kept (session INTEGER NOT NULL REFERENCES sessions (id), key TEXT NOT NULL, value TEXT NOT NULL,
  PRIMARY KEY (session, key));
]]

--- The schema, one step a version ([`Sqlite.Handle.migrate`]).
local SCHEMA <const> = [[
CREATE TABLE sessions (id INTEGER PRIMARY KEY, cwd TEXT NOT NULL, started INTEGER NOT NULL,
  model TEXT NOT NULL, restarts INTEGER NOT NULL DEFAULT 0, ended INTEGER NOT NULL DEFAULT 1);
CREATE TABLE messages (session INTEGER NOT NULL REFERENCES sessions (id), seq INTEGER NOT NULL,
  message TEXT NOT NULL, PRIMARY KEY (session, seq));
CREATE TABLE outputs (id INTEGER PRIMARY KEY, session INTEGER NOT NULL REFERENCES sessions (id),
  tool TEXT NOT NULL, input TEXT NOT NULL, text TEXT NOT NULL, is_error INTEGER NOT NULL, call TEXT,
  shown TEXT);
CREATE INDEX outputs_by_call ON outputs (session, call);
CREATE VIRTUAL TABLE outputs_fts USING fts5(text, content = 'outputs', content_rowid = 'id',
  tokenize = 'trigram');
CREATE TRIGGER outputs_indexed AFTER INSERT ON outputs WHEN new.tool <> 'sql' BEGIN
  INSERT INTO outputs_fts (rowid, text) VALUES (new.id, new.text);
END;
CREATE TABLE systems (id INTEGER PRIMARY KEY, digest BLOB NOT NULL UNIQUE, text TEXT NOT NULL);
CREATE TABLE requests (id INTEGER PRIMARY KEY, session INTEGER NOT NULL REFERENCES sessions (id), seq INTEGER,
  started INTEGER NOT NULL, ms INTEGER NOT NULL, model TEXT NOT NULL, effort TEXT NOT NULL,
  max_tokens INTEGER NOT NULL, betas TEXT NOT NULL, system INTEGER NOT NULL REFERENCES systems (id),
  status INTEGER NOT NULL, error TEXT, served TEXT, stop_reason TEXT, request_id TEXT, headers TEXT NOT NULL,
  input_tokens INTEGER, output_tokens INTEGER, cache_read INTEGER, cache_write_5m INTEGER,
  cache_write_1h INTEGER, context INTEGER GENERATED ALWAYS AS
    (input_tokens + cache_read + cache_write_5m + cache_write_1h) VIRTUAL,
  cost REAL, reply TEXT, shape INTEGER REFERENCES shapes (id), build TEXT, request_headers TEXT,
  first_ms INTEGER,
  cache_miss TEXT GENERATED ALWAYS AS
    (CASE WHEN json_valid(reply) THEN reply ->> '$.diagnostics.cache_miss_reason.type' END) VIRTUAL,
  cache_missed INTEGER GENERATED ALWAYS AS
    (CASE WHEN json_valid(reply) THEN reply ->> '$.diagnostics.cache_miss_reason.cache_missed_input_tokens' END) VIRTUAL);
CREATE INDEX requests_by_session ON requests (session, id);
CREATE TABLE shapes (id INTEGER PRIMARY KEY, digest BLOB NOT NULL UNIQUE, body TEXT NOT NULL);
]]

--- The id of the last reply kept for session `id`, which the next
--- request names for its cache diagnosis; nil where there is none. A
--- warm request's (max_tokens 0) is not one: the next names the reply before it.
function Sessions.last_reply(db: Sqlite.Handle, id: integer): string?
  local rows, _ = db:rows([[SELECT reply ->> '$.id' AS reply_id FROM requests
    WHERE session = ?1 AND status = 200 AND max_tokens > 0 AND json_valid(reply) ORDER BY id DESC LIMIT 1]], { { integer = id } })
  local row = (rows or {})[1]
  if row == nil or row:is_null(1) then return nil end
  return row:text(1)
end

--- The database at `path`, made where there is none: its owner's alone
--- (the file 0600, a directory made for it 0700), its schema brought up
--- to date ([`Sqlite.Handle.migrate`]: two runs that make it at once take
--- turns); a newer program's, or another program's, is refused. `:memory:` is a database of the run alone. Nil
--- and why.
function Sessions.open(path: string): Sqlite.Handle?, string
  local file = path ~= ":memory:"
  if file then
    local made, made_why = Fs.mkdirs(Fs.dirname(path), 0x1c0)
    if not made then return nil, "sessions: " .. tostring(made_why) end
  end
  local opened, why = Sqlite.open(path, { writable = true, create = true })
  if opened == nil then return nil, "sessions: " .. path .. ": " .. tostring(why) end
  local db = opened
  local function refused(trouble: string): nil, string
    local _, _ = db:close()
    return nil, "sessions: " .. path .. ": " .. trouble
  end
  if file then
    local held, held_why = Fs.chmod(path, 0x180)
    if not held then return refused(tostring(held_why)) end
  end
  -- In one IMMEDIATE transaction: another run that opened it at once
  -- waits for the lock, then finds the schema made.
  local migrated, migrate_why = db:migrate({ SCHEMA, KEPT })
  if migrated == nil then return refused(tostring(migrate_why)) end
  -- WAL lets a reader (the sql tool, sqlite3) in beside a writer, once the
  -- file is known to be ours; a database busy past the wait may refuse the
  -- switch, which is no reason to fail.
  local _, _ = db:wal()
  return db, ""
end

--- A new session in `cwd` with `model`, begun at `seconds` (Unix time):
--- its id, or nil and why.
function Sessions.start(db: Sqlite.Handle, cwd: string, model: string, seconds: integer): integer?, string
  local ok, why = db:run("INSERT INTO sessions (cwd, started, model) VALUES (?1, ?2, ?3)",
    { { text = cwd }, { integer = seconds }, { text = model } })
  if not ok then return nil, tostring(why) end
  return db:last_insert_rowid(), ""
end

--- A new session in `cwd` with `model`, begun at `seconds` (Unix time), that holds all session `from` kept: its
--- messages, its tools' outputs (so a turn it left unfinished settles as it would), the values its snippets kept, and
--- whether its last turn ended; its id, or nil and why. All or none, in one transaction.
function Sessions.fork(db: Sqlite.Handle, from: integer, cwd: string, model: string, seconds: integer): integer?, string
  local made: integer? = nil
  local transacted, transact_why = db:transact(function(): (true) | (false, Failure)
    local ok, why = db:run([[INSERT INTO sessions (cwd, started, model, ended)
      SELECT ?2, ?3, ?4, ended FROM sessions WHERE id = ?1]],
      { { integer = from }, { text = cwd }, { integer = seconds }, { text = model } })
    if not ok then return false, why end
    local id = db:last_insert_rowid()
    made = id
    for _, copy in ipairs({
        "INSERT INTO messages (session, seq, message) SELECT ?2, seq, message FROM messages WHERE session = ?1",
        "INSERT INTO outputs (session, tool, input, text, is_error, call, shown) " ..
          "SELECT ?2, tool, input, text, is_error, call, shown FROM outputs WHERE session = ?1 ORDER BY id",
        "INSERT INTO kept (session, key, value) SELECT ?2, key, value FROM kept WHERE session = ?1" }) do
      local copied, copy_why = db:run(copy, { { integer = from }, { integer = id } })
      if not copied then return false, copy_why end
    end
    return true
  end)
  if not transacted then return nil, tostring(transact_why) end
  return made, ""
end

--- Keeps `message` as the next of session `id`, and `model` as the
--- session's last, in one transaction.
function Sessions.add(db: Sqlite.Handle, id: integer, message: Json.Value, model: string): boolean, string
  local text, why = Json.encode(message)
  if text == nil then return false, tostring(why) end
  local transacted, transact_why = db:transact(function(): (true) | (false, Failure)
    local ok, run_why = db:run([[INSERT INTO messages (session, seq, message)
      SELECT ?1, coalesce(max(seq), 0) + 1, ?2 FROM messages WHERE session = ?1]],
      { { integer = id }, { text = text } })
    if not ok then return false, run_why end
    return db:run("UPDATE sessions SET model = ?2 WHERE id = ?1", { { integer = id }, { text = model } })
  end)
  if not transacted then return false, tostring(transact_why) end
  return true, ""
end

--- The newest session in `cwd` that holds a message, or nil where it
--- has none (why is "" then).
function Sessions.latest(db: Sqlite.Handle, cwd: string): integer?, string
  local rows, why = db:rows([[SELECT id FROM sessions s WHERE cwd = ?1
    AND EXISTS (SELECT 1 FROM messages m WHERE m.session = s.id) ORDER BY id DESC LIMIT 1]], { { text = cwd } })
  if rows == nil then return nil, tostring(why) end
  local row = rows[1]
  if row == nil then return nil, "" end
  return row:integer(1), ""
end

--- Session `id`, its messages in order: or nil and why, where there is
--- no such session.
function Sessions.load(db: Sqlite.Handle, id: integer): Sessions.Loaded?, string
  local found, why = db:rows("SELECT model, restarts, ended FROM sessions WHERE id = ?1",
    { { integer = id } })
  if found == nil then return nil, tostring(why) end
  local row = found[1]
  if row == nil then return nil, "no session " .. tostring(id) end
  local texts, rows_why = db:map("SELECT message FROM messages WHERE session = ?1 ORDER BY seq",
    { { integer = id } }, function(r: Sqlite.Row): string return r:text(1) end)
  if texts == nil then return nil, tostring(rows_why) end
  local out: mut {Json.Value} = {}
  for _, t in ipairs(texts) do
    local m, bad = Json.decode(t, { null_value = Json.null })
    if m == nil then return nil, "session " .. tostring(id) .. ": " .. tostring(bad) end
    out[#out + 1] = m
  end
  return { messages = out, model = row:text(1), restarts = row:integer(2), ended = row:integer(3) ~= 0 }, ""
end

--- Keeps the whole output of a tool's call in session `id`: its id,
--- or nil and why.
function Sessions.output(db: Sqlite.Handle, id: integer, o: Sessions.Output): integer?, string
  local call: Sqlite.Value = if o.call ~= nil then { text = o.call } else {} end
  local ok, why = db:run([[INSERT INTO outputs (session, tool, input, text, is_error, call)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6)]], { { integer = id }, { text = o.tool }, { text = o.input }, { text = o.text },
      { integer = if o.is_error then 1 else 0 end }, call })
  if not ok then return nil, tostring(why) end
  return db:last_insert_rowid(), ""
end

--- Keeps `text` as what the model read of output `id`, where that is
--- less than the whole.
function Sessions.shown(db: Sqlite.Handle, id: integer, text: string): boolean, string
  local answered, answer_why = db:run("UPDATE outputs SET shown = ?2 WHERE id = ?1", { { integer = id }, { text = text } })
  if not answered then return false, tostring(answer_why) end
  return answered, ""
end

--- The most bytes of a value's JSON one key of [`Sessions.keep`] holds.
local KEPT_BYTES <const> = 256 * 1024

--- The most bytes of JSON a session keeps under all its keys.
local SESSION_KEPT_BYTES <const> = 1024 * 1024

--- Keeps `value`, JSON text, under `key` for session `id`, in place of what was kept there; nil `value` lets the key
--- go. A value past 256KB, or one that would take what the session keeps, its keys and values, past 1MB, is refused.
function Sessions.keep(db: Sqlite.Handle, id: integer, key: string, value?: string): boolean, string
  if value == nil then
    local gone, gone_why = db:run("DELETE FROM kept WHERE session = ?1 AND key = ?2", { { integer = id }, { text = key } })
    if not gone then return false, tostring(gone_why) end
    return true, ""
  end
  if #value > KEPT_BYTES then
    return false, "the value is " .. String.counted(#value, "byte") .. " of JSON, more than the 256KB a key holds"
  end
  -- One statement, so that two agents on one session cannot both pass the check: it puts the row only where the keys
  -- and values the session keeps beside it, and this one, are within what a session keeps.
  local put, put_why = db:run("INSERT INTO kept (session, key, value) SELECT ?1, ?2, ?3 WHERE " ..
      "(SELECT coalesce(sum(length(CAST(key AS BLOB)) + length(CAST(value AS BLOB))), 0) FROM kept " ..
      "WHERE session = ?1 AND key <> ?2) + ?4 <= ?5 " ..
      "ON CONFLICT (session, key) DO UPDATE SET value = excluded.value", { { integer = id }, { text = key },
        { text = value }, { integer = #key + #value }, { integer = SESSION_KEPT_BYTES } })
  if not put then return false, tostring(put_why) end
  if db:changes() == 0 then
    return false, "this value would take what the session keeps (its keys and values) past the 1MB it may keep"
  end
  return true, ""
end

--- The JSON text kept under `key` for session `id` ([`Sessions.keep`]): nil where none is (why is "" then).
function Sessions.kept(db: Sqlite.Handle, id: integer, key: string): string?, string
  local rows, why = db:rows("SELECT value FROM kept WHERE session = ?1 AND key = ?2", { { integer = id }, { text = key } })
  if rows == nil then return nil, tostring(why) end
  local row = rows[1]
  if row == nil then return nil, "" end
  return row:text(1), ""
end

--- What answered the tool call `call` in session `id`, as the model
--- read it: nil where nothing did (why is "" then).
function Sessions.answer(db: Sqlite.Handle, id: integer, call: string): Sessions.Answer?, string
  local found, why = db:map([[SELECT coalesce(shown, text), is_error FROM outputs
    WHERE session = ?1 AND call = ?2 ORDER BY id DESC LIMIT 1]], { { integer = id }, { text = call } },
    function(r: Sqlite.Row): Sessions.Answer
      return { text = r:text(1), is_error = r:integer(2) ~= 0 }
    end)
  if found == nil then return nil, tostring(why) end
  return found[1], ""
end

local function int(v?: integer): Sqlite.Value
  if v == nil then return {} end
  return { integer = v }
end

local function str(v?: string): Sqlite.Value
  if v == nil then return {} end
  return { text = v }
end

--- Keeps request `r` of session `id`, its system prompt once: the
--- request's id, or nil and why.
function Sessions.request(db: Sqlite.Handle, id: integer, r: Sessions.Request): integer?, string
  local made: integer? = nil
  local ok, why = db:transact(function(): (true) | (false, Failure)
    local kept, kept_why = db:run("INSERT OR IGNORE INTO systems (digest, text) VALUES (digest('sha256', ?1), ?1)",
      { { text = r.system } })
    if not kept then return false, kept_why end
    local shaped, shaped_why = db:run("INSERT OR IGNORE INTO shapes (digest, body) VALUES (digest('sha256', ?1), ?1)",
      { { text = r.shape } })
    if not shaped then return false, shaped_why end
    local cost: Sqlite.Value = if r.cost ~= nil then { number = r.cost } else {} end
    local run, run_why = db:run([[INSERT INTO requests (session, seq, started, ms, model, effort, max_tokens,
        betas, system, status, error, served, stop_reason, request_id, headers, input_tokens, output_tokens,
        cache_read, cache_write_5m, cache_write_1h, cost, reply, shape, build, request_headers, first_ms)
      SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, id, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21,
        (SELECT id FROM shapes WHERE digest = digest('sha256', ?23)), ?24, ?25, ?26
      FROM systems WHERE digest = digest('sha256', ?22)]],
      { { integer = id }, int(r.seq), { integer = r.started }, { integer = r.ms }, { text = r.model },
        { text = r.effort }, { integer = r.max_tokens }, { text = r.betas }, { integer = r.status }, str(r.error),
        str(r.served), str(r.stop_reason), str(r.request_id), { text = r.headers }, int(r.input_tokens),
        int(r.output_tokens), int(r.cache_read), int(r.cache_write_5m), int(r.cache_write_1h), cost, str(r.reply),
        { text = r.system }, { text = r.shape }, str(r.build), str(r.request_headers), int(r.first_ms) })
    if not run then return false, run_why end
    made = db:last_insert_rowid()
    return true
  end)
  if not ok or made == nil then return nil, tostring(why) end
  return made, ""
end

--- Keeps how often session `id`'s last turn was started again, and
--- whether it ended for good.
function Sessions.mark(db: Sqlite.Handle, id: integer, restarts: integer, ended: boolean): boolean, string
  local answered, answer_why = db:run("UPDATE sessions SET restarts = ?2, ended = ?3 WHERE id = ?1",
    { { integer = id }, { integer = restarts }, { integer = if ended then 1 else 0 end } })
  if not answered then return false, tostring(answer_why) end
  return answered, ""
end

--- The words of a user's message: its text, or "" where it is tool results.
local function words(text: string): string
  local m, _ = Json.decode_object(text)
  local content = m and m["content"]
  if content is string then return content end
  -- A prompt with a budget is a list of blocks: the first holds the words.
  local first = Json.object_of((Json.array_of(content) or {})[1])
  local said = first and first["text"]
  if said is string then return said end
  return ""
end

--- The newest `n` sessions in `cwd`, newest first.
function Sessions.list(db: Sqlite.Handle, cwd: string, n: integer): {Sessions.Summary}?, string
  local answered, answer_why = db:map([[SELECT s.id, datetime(s.started, 'unixepoch', 'localtime'), s.model,
      (SELECT count(*) FROM messages m WHERE m.session = s.id),
      coalesce((SELECT message FROM messages m WHERE m.session = s.id AND m.seq = 1), '{}'),
      coalesce((SELECT sum(cost) FROM requests r WHERE r.session = s.id), 0.0),
      coalesce((SELECT context FROM requests r WHERE r.session = s.id AND context IS NOT NULL
        ORDER BY id DESC LIMIT 1), 0)
    FROM sessions s WHERE s.cwd = ?1 ORDER BY s.id DESC LIMIT ?2]],
    { { text = cwd }, { integer = n } }, function(r: Sqlite.Row): Sessions.Summary
      return { id = r:integer(1), started = r:text(2), model = r:text(3), messages = r:integer(4),
        first = words(r:text(5)), cost = r:number(6), context = r:integer(7) }
    end)
  if not answered then return nil, tostring(answer_why) end
  return answered, ""
end

return Sessions
