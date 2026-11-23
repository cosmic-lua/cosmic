--- sessions.db: made with its schema and its owner's alone, refused when
--- it is another version or another program's, and what a request keeps.

local Fs = require("cosmic.fs")
local Sessions = require("cosmic.agent.sessions")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

Test.policy{}

local function test_a_database_is_made_with_its_schema(tmp: string)
  local path = tmp .. "/data/sessions.db"
  local db = assert(Sessions.open(path))
  local version = assert(assert(db:rows("PRAGMA user_version"))[1])
  assert(version:integer(1) == 1)
  assert(assert(Fs.stat(path)).mode & 0x1ff == 0x180)
  assert(assert(Fs.stat(tmp .. "/data")).mode & 0x1ff == 0x1c0)
  assert(db:close())
  -- Opened again, as it is.
  local again = assert(Sessions.open(path))
  local id = assert(Sessions.start(again, "/", "m", 0))
  assert(assert(Sessions.load(again, id)).model == "m")
  assert(again:close())
end

local function test_another_version_or_program_is_refused(tmp: string)
  local other = assert(Sqlite.open(tmp .. "/other.db", { writable = true, create = true }))
  assert(other:exec("CREATE TABLE notes (text TEXT)"))
  assert(other:close())
  local db, why = Sessions.open(tmp .. "/other.db")
  assert(db == nil and why:find("another program's database", 1, true) ~= nil, why)
  local later = assert(Sqlite.open(tmp .. "/later.db", { writable = true, create = true }))
  assert(later:exec("PRAGMA user_version = 99"))
  assert(later:close())
  db, why = Sessions.open(tmp .. "/later.db")
  assert(db == nil and why:find("version 99", 1, true) ~= nil, why)
end

local function test_a_request_keeps_its_shape_build_and_cache_miss()
  local db = assert(Sessions.open(":memory:"))
  local id = assert(Sessions.start(db, "/", "m", 0))
  assert(Sessions.request(db, id, { started = 0, ms = 0, model = "m", effort = "low", max_tokens = 1, betas = "",
    system = "s", status = 200, headers = "{}", shape = '{"a":1}', build = "b" }))
  local stored = assert(db:rows("SELECT (SELECT body FROM shapes WHERE id = shape), build FROM requests"))
  assert(assert(stored[1]):text(1) == '{"a":1}' and assert(stored[1]):text(2) == "b")
  -- Why the cache missed is read from the reply; a reply not JSON reads as none.
  assert(Sessions.request(db, id, { started = 0, ms = 0, model = "m", effort = "low", max_tokens = 1, betas = "",
    system = "s", status = 200, headers = "{}", shape = "{}", reply = 'data: {"cut' }))
  assert(Sessions.request(db, id, { started = 0, ms = 0, model = "m", effort = "low", max_tokens = 1, betas = "",
    system = "s", status = 200, headers = "{}", shape = "{}",
    reply = '{"id":"msg_9","diagnostics":{"cache_miss_reason":{"type":"tools_changed","cache_missed_input_tokens":5}}}' }))
  local misses = assert(db:rows("SELECT cache_miss, cache_missed FROM requests ORDER BY id"))
  assert(#misses == 3 and assert(misses[2]):is_null(1) and assert(misses[3]):text(1) == "tools_changed")
  assert(assert(misses[3]):integer(2) == 5)
  assert(Sessions.last_reply(db, id) == "msg_9")
  assert(db:close())
end
