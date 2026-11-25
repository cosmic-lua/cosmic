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
  assert(version:integer(1) == 2)
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

--- A database of version 1 gains the table kept, its sessions as they were.
local function test_a_version_1_database_gains_what_version_2_adds(tmp: string)
  local path = tmp .. "/old.db"
  local db = assert(Sessions.open(path))
  local id = assert(Sessions.start(db, "/", "m", 0))
  assert(db:exec("DROP TABLE kept; PRAGMA user_version = 1"))
  assert(db:close())
  local again = assert(Sessions.open(path))
  assert(assert(assert(again:rows("PRAGMA user_version"))[1]):integer(1) == 2)
  assert(assert(Sessions.load(again, id)).model == "m")
  assert(Sessions.keep(again, id, "k", "1"))
  assert(again:close())
end

--- What a session keeps under a key is its own, in place of what was there, let go with no value, and held to 256KB a
--- key and 1MB a session.
local function test_a_fork_holds_all_its_session_kept()
  local db = assert(Sessions.open(":memory:"))
  local a = assert(Sessions.start(db, "/a", "m", 0))
  assert(Sessions.add(db, a, { role = "user", content = "hi" }, "m"))
  assert(Sessions.output(db, a, { tool = "run", input = "{}", text = "out", is_error = false, call = "c1" }))
  assert(Sessions.keep(db, a, "k", "[1]"))
  assert(Sessions.mark(db, a, 0, false))
  local b = assert(Sessions.fork(db, a, "/b", "n", 1))
  local loaded = assert(Sessions.load(db, b))
  assert(#loaded.messages == 1 and loaded.model == "n" and not loaded.ended)
  local answer = assert(Sessions.answer(db, b, "c1"))
  assert(answer.text == "out" and not answer.is_error)
  assert(Sessions.kept(db, b, "k") == "[1]")
  -- The fork's own changes stay in the fork.
  assert(Sessions.keep(db, b, "k", "[2]"))
  assert(Sessions.kept(db, a, "k") == "[1]")
  local none, none_why = Sessions.fork(db, 999, "/c", "m", 2)
  assert(none == nil and none_why:find("no session 999", 1, true) ~= nil, none_why)
end

local function test_a_session_keeps_values_by_key_within_its_limits()
  local db = assert(Sessions.open(":memory:"))
  local a = assert(Sessions.start(db, "/", "m", 0))
  local b = assert(Sessions.start(db, "/", "m", 0))
  assert(Sessions.keep(db, a, "k", "[1]") and Sessions.keep(db, a, "k", "[2]") and Sessions.keep(db, b, "k", "3"))
  assert(Sessions.kept(db, a, "k") == "[2]" and Sessions.kept(db, b, "k") == "3")
  local none, none_why = Sessions.kept(db, a, "other")
  assert(none == nil and none_why == "")
  assert(Sessions.keep(db, a, "k"))
  assert(Sessions.kept(db, a, "k") == nil)
  local big, big_why = Sessions.keep(db, a, "big", string.rep("x", 256 * 1024 + 1))
  assert(not big and big_why:find("more than the 256KB a key holds", 1, true) ~= nil, big_why)
  local chunk = string.rep("y", 200 * 1024)
  for i = 1, 5 do assert(Sessions.keep(db, a, "part" .. tostring(i), chunk)) end
  local over, over_why = Sessions.keep(db, a, "part6", chunk)
  assert(not over and over_why:find("past the 1MB it may keep", 1, true) ~= nil, over_why)
  assert(Sessions.kept(db, a, "part6") == nil)
  -- Put again in place of itself, a value counts once.
  assert(Sessions.keep(db, a, "part5", chunk))
  -- Keys count too: what is left is less than a value of its size, once its key is counted.
  local left = 1024 * 1024 - 5 * (#"part1" + #chunk)
  local keyed, keyed_why = Sessions.keep(db, a, "x", string.rep("z", left))
  assert(not keyed and keyed_why:find("past the 1MB", 1, true) ~= nil, keyed_why)
  assert(Sessions.keep(db, a, "x", string.rep("z", left - 1)))
  assert(db:close())
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
