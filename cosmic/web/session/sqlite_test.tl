local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Session = require("cosmic.web.session")
local SessionSqlite = require("cosmic.web.session.sqlite")
local Sqlite = require("cosmic.sqlite")
local Web = require("cosmic.web")

--- A client acting as a browser on an https page, which sends the Secure
--- session cookie back.
local function browser(app: Web.App): Web.TestClient
  local client = Web.test_client(app)
  client.scheme = "https"
  return client
end

local function open(opts?: SessionSqlite.Options): Session.Store, Sqlite.Handle
  local db = assert(Sqlite.memory())
  return assert(SessionSqlite.store(db, opts)), db
end

local function fresh(values: mut {string: Json.Value}, expires?: integer): Session.Data
  return { values = values, created = 100, expires = expires or 1000 }
end

local function changed(set: mut {string: Json.Value}): Session.Changes
  return { set = set, removed = {} }
end

--- Saves a new session holding `values` at time 100 and returns its id.
local function create(store: Session.Store, values: mut {string: Json.Value}, expires?: integer): string
  return (assert(store:save("", fresh(values, expires), changed(values), 100, "session")))
end

local function count(db: Sqlite.Handle): integer
  local rows = assert(db:rows("SELECT count(*) FROM web_sessions"))
  local row = assert(rows[1], "a count query answers one row")
  return row:integer(1)
end

local function test_a_new_session_gets_a_256_bit_id_and_the_table_holds_only_its_hash()
  local store, db = open()
  local id = create(store, { user = "ada" })
  assert(#id == 43 and #assert(Codec.unbase64url(id)) == 32)
  local rows = assert(db:rows("SELECT id_hash, data FROM web_sessions"))
  assert(#rows == 1 and rows[1]:blob(1) == Hash.sha256(id))
  local rows_1 = assert(rows[1], "expected rows[1]")
  assert(rows_1:text(2):find("ada", 1, true))
  local seen = assert(db:rows("SELECT count(*) FROM web_sessions WHERE id_hash = ?1 OR data = ?2",
    { { blob = id }, { text = id } }))
  local seen_1 = assert(seen[1], "expected seen[1]")
  assert(seen_1:integer(1) == 0, "the id itself is nowhere in the table")
  assert(create(store, { user = "ada" }) ~= id, "ids differ")
  assert(store.revocable)
end

local function test_load_answers_the_data_and_nothing_for_unknown_or_malformed_ids()
  local store = open()
  local id = create(store, { user = "ada", n = 3 })
  local got = assert(store:load(id, 500, "session"))
  assert(got.values["user"] == "ada" and got.values["n"] == 3 and got.created == 100 and got.expires == 1000)
  local missing, why = store:load(("A"):rep(43), 500, "session")
  assert(missing == nil and why == "")
  assert(store:load("short", 500, "session") == nil and store:load("", 500, "session") == nil)
  assert(store:load(id:sub(1, 42) .. "!", 500, "session") == nil)
end

--- A [`Json.null`] the session saved, in an array and in an object, nested too, loads back as [`Json.null`]: a session the
--- server wrote is never refused for what it holds.
local function test_a_null_inside_an_array_or_an_object_loads_back_as_null()
  local store = open()
  local saved: mut {string: Json.Value} = { list = { 1, Json.null, 3 }, obj = { a = Json.null, b = 1 },
    nested = { { x = { Json.null } }, { 1, { 2 } } } }
  local got = assert(store:load(create(store, saved), 500, "session"))
  assert(assert(Json.encode(got.values)) == '{"list":[1,null,3],"nested":[{"x":[null]},[1,[2]]],"obj":{"a":null,"b":1}}')
  local a, _ = Json.get(got.values, { "obj", "a" })
  assert(got.values["obj"] ~= nil and a == Json.null)
end

local function test_a_session_past_its_expiry_is_as_good_as_absent()
  local store = open()
  local id = create(store, { user = "ada" }, 1000)
  assert(store:load(id, 999, "session") ~= nil)
  assert(store:load(id, 1000, "session") == nil)
end

local function test_two_requests_that_changed_different_keys_both_land()
  local store = open()
  local id = create(store, { base = 1 })
  local first = assert(store:load(id, 500, "session"))
  local second = assert(store:load(id, 500, "session"))
  first.values["a"] = "from first"
  second.values["b"] = "from second"
  assert(store:save(id, first, changed({ a = "from first" }), 500, "session") == id)
  assert(store:save(id, second, changed({ b = "from second" }), 501, "session") == id)
  local merged = assert(store:load(id, 502, "session"))
  assert(merged.values["base"] == 1 and merged.values["a"] == "from first" and merged.values["b"] == "from second")
end

local function test_removed_keys_and_clear_are_applied_to_what_is_stored()
  local store = open()
  local id = create(store, { keep = 1, drop = 2, other = 3 })
  local seen = assert(store:load(id, 500, "session"))
  assert(store:save(id, seen, { set = {}, removed = { "drop" } }, 500, "session"))
  local after = assert(store:load(id, 501, "session"))
  assert(after.values["drop"] == nil and after.values["keep"] == 1)
  assert(store:save(id, seen, { set = { fresh = true }, removed = {}, cleared = true }, 502, "session"))
  local cleared = assert(store:load(id, 503, "session"))
  assert(cleared.values["keep"] == nil and cleared.values["fresh"] == true)
end

local function test_regenerate_changes_the_id_keeps_the_data_and_removes_the_old_row()
  local store, db = open()
  local id = create(store, { user = "ada" })
  local data = assert(store:load(id, 500, "session"))
  data.created = 500
  local renewed = assert(store:save(id, data, { set = {}, removed = {}, regenerated = true }, 500, "session"))
  assert(renewed ~= id and #renewed == 43)
  assert(store:load(id, 501, "session") == nil, "the old id is revoked")
  local got = assert(store:load(renewed, 501, "session"))
  assert(got.values["user"] == "ada" and got.created == 500)
  assert(count(db) == 1)
end

local function test_a_session_revoked_during_a_request_is_not_revived_with_what_it_saw()
  local store = open()
  local id = create(store, { user = "ada", secret = "s" })
  local seen = assert(store:load(id, 500, "session"))
  assert(store:destroy(id))
  local token = assert(store:save(id, seen, changed({ theme = "dark" }), 501, "session"))
  assert(token ~= id)
  local got = assert(store:load(token, 502, "session"))
  assert(got.values["theme"] == "dark" and got.values["user"] == nil and got.values["secret"] == nil)
end

local function test_destroy_revokes_one_id_and_ignores_junk()
  local store, db = open()
  local id = create(store, { a = 1 })
  local other = create(store, { b = 2 })
  assert(store:destroy(id) and store:destroy("junk"))
  assert(store:load(id, 500, "session") == nil and store:load(other, 500, "session") ~= nil)
  assert(count(db) == 1)
end

local function test_destroy_subject_signs_a_user_out_everywhere()
  local store, db = open()
  local mine: mut {string} = {}
  for i = 1, 3 do
    local id = create(store, { n = i })
    local data = assert(store:load(id, 500, "session"))
    assert(store:save(id, data, { set = {}, removed = {}, subject = "ada" }, 500, "session"))
    mine[i] = id
  end
  local theirs = create(store, { n = 9 })
  local bound = assert(store:save(theirs, assert(store:load(theirs, 500, "session")),
    { set = {}, removed = {}, subject = "grace" }, 500, "session"))
  local anonymous = create(store, { n = 0 })
  assert(SessionSqlite.destroy_subject(store, "ada") == 3)
  for _, id in ipairs(mine) do assert(store:load(id, 501, "session") == nil) end
  assert(store:load(bound, 501, "session") ~= nil and store:load(anonymous, 501, "session") ~= nil)
  assert(SessionSqlite.destroy_subject(store, "ada") == 0)
  assert(count(db) == 2)
end

local function test_the_subject_survives_later_saves_and_a_regeneration()
  local store = open()
  local id = create(store, { a = 1 })
  assert(store:save(id, assert(store:load(id, 500, "session")),
    { set = {}, removed = {}, subject = "ada" }, 500, "session"))
  local renewed = assert(store:save(id, assert(store:load(id, 501, "session")),
    { set = { b = 2 }, removed = {}, regenerated = true }, 501, "session"))
  assert(SessionSqlite.destroy_subject(store, "ada") == 1)
  assert(store:load(renewed, 502, "session") == nil)
end

local function test_sweep_deletes_expired_rows_in_bounded_batches()
  local store, db = open({ sweep_interval = 1000000 })
  for _ = 1, 5 do create(store, { a = 1 }, 200) end
  local live = create(store, { a = 1 }, 5000)
  assert(count(db) == 6)
  assert(SessionSqlite.sweep(store, 100, 2) == 0, "nothing has expired yet")
  assert(SessionSqlite.sweep(store, 300, 2) == 2)
  assert(SessionSqlite.sweep(store, 300, 2) == 2)
  assert(SessionSqlite.sweep(store, 300) == 1)
  assert(count(db) == 1 and store:load(live, 300, "session") ~= nil)
end

local function test_a_save_sweeps_expired_rows_at_most_once_per_interval()
  local store, db = open({ sweep_interval = 600, sweep_limit = 10 })
  for _ = 1, 3 do create(store, { a = 1 }, 150) end
  assert(count(db) == 3, "saves at time 100 found nothing expired")
  assert(store:save("", fresh({}, 9000), changed({}), 1200, "session"))
  assert(count(db) == 1, "the first save past expiry swept the three")
  for _ = 1, 2 do
    assert(store:save("", fresh({}, 1210), changed({}), 1205, "session"))
  end
  assert(store:save("", fresh({}, 9000), changed({}), 1300, "session"))
  assert(count(db) == 4, "no second sweep within the interval")
end

local function test_a_table_name_that_is_not_an_identifier_is_refused_and_a_name_is_used()
  local db = assert(Sqlite.memory())
  local ok, why = pcall(SessionSqlite.store, db, { table = "x; DROP TABLE y" })
  assert(not ok and tostring(why):find("identifier", 1, true) ~= nil)
  local store = assert(SessionSqlite.store(db, { table = "my_sessions" }))
  local id = assert(store:save("", fresh({}), changed({ a = 1 }), 100, "session"))
  local rows = assert(db:rows("SELECT count(*) FROM my_sessions"))
  local rows_1 = assert(rows[1], "expected rows[1]")
  assert(rows_1:integer(1) == 1 and store:load(id, 200, "session") ~= nil)
end

local function test_a_store_function_refuses_a_store_not_made_here()
  local ok, why = pcall(SessionSqlite.sweep, { revocable = true } as Session.Store, 100) -- checked: cast_refused
  assert(not ok and tostring(why):find("not a store made by SessionSqlite.store", 1, true) ~= nil)
end

local function nest(levels: integer): Json.Value
  local value: Json.Value = 1
  for _ = 1, levels do value = { value } end
  return value
end

local function test_save_refuses_what_load_cannot_read_and_leaves_no_transaction_open()
  local store = open()
  local id = create(store, { base = 1 })
  local data = assert(store:load(id, 500, "session"))
  local deep = nest(Session.MAX_DEPTH)
  local token, why = store:save(id, data, changed({ deep = deep }), 500, "session")
  assert(token == nil and why:find("cannot encode", 1, true) ~= nil, why)
  local fine = nest(Session.MAX_DEPTH - 1)
  assert(store:save(id, data, changed({ deep = fine }), 501, "session") == id, "the failed save rolled back")
  assert(assert(store:load(id, 502, "session")).values["deep"] ~= nil)
end

--- Binds the session `id` to `subject` and labels it, at time 500.
local function bind(store: Session.Store, id: string, subject?: string, label?: string)
  assert(store:save(id, assert(store:load(id, 500, "session")),
    { set = {}, removed = {}, subject = subject, label = label }, 500, "session") == id)
end

local function test_list_answers_live_sessions_with_public_ids_and_never_a_token()
  local store, db = open()
  local ada = create(store, { user = "ada" })
  bind(store, ada, "ada", "M's iPad")
  local anonymous = create(store, { n = 1 })
  local _ = create(store, { n = 2 }, 400)
  local listed = assert(SessionSqlite.list(store, 450))
  assert(#listed == 2, "the expired one is not listed")
  local by_label: mut {string: SessionSqlite.Info} = {}
  for _, info in ipairs(listed) do
    assert(#info.id == 16 and info.id ~= ada and info.id ~= anonymous)
    assert(info.created == 100 and info.expires == 1000 and info.seen_at == nil and info.seen_from == nil)
    by_label[info.label or ""] = info
  end
  local ipad = assert(by_label["M's iPad"])
  assert(ipad.subject == "ada" and assert(by_label[""]).subject == nil)
  local fields: mut {string} = {}
  for _, info in ipairs(listed) do
    for _, field in ipairs({ info.id, info.subject or "", info.label or "", info.seen_from or "" }) do
      fields[#fields + 1] = field
    end
  end
  local text = table.concat(fields, " ")
  for _, token in ipairs({ ada, anonymous }) do
    local hash = Hash.sha256(token)
    assert(text:find(token, 1, true) == nil, "a listing holds no token")
    assert(text:find(hash, 1, true) == nil and text:find(Codec.base64url(hash), 1, true) == nil)
  end
  local mine = assert(SessionSqlite.list(store, 450, { subject = "ada" }))
  assert(#mine == 1 and assert(mine[1]).id == ipad.id)
  assert(#assert(SessionSqlite.list(store, 450, { subject = "grace" })) == 0)
  assert(#assert(SessionSqlite.list(store, 450, { limit = 1 })) == 1)
  assert(assert(SessionSqlite.info(store, ada, 450)).id == ipad.id)
  assert(SessionSqlite.info(store, "junk", 450) == nil and SessionSqlite.info(store, ada, 1000) == nil)
  assert(count(db) == 3)
end

--- Notes the session `token` seen at `now` from `from`, as the middleware does.
local function note(store: Session.Store, token: string, now: integer, from: string)
  local seen = assert(store.seen, "the store notes sightings")
  seen(store, token, assert(store:load(token, now, "session")), now, from)
end

local function test_list_puts_the_session_seen_last_first_and_one_never_seen_by_when_it_began()
  local store, db = open({ seen_interval = 60 })
  local ids: mut {string} = {}
  for i = 1, 3 do
    ids[i] = assert(store:save("", { values = {}, created = 100 * i, expires = 5000 }, changed({ n = i }),
      100 * i, "session"))
  end
  -- The first, begun earliest, was seen last; the other two never were.
  note(store, assert(ids[1]), 700, "10.0.0.1")
  local order: mut {string} = {}
  for _, info in ipairs((assert(SessionSqlite.list(store, 800)))) do
    local rows = assert(db:rows("SELECT data FROM web_sessions WHERE public_id = ?1", { { text = info.id } }))
    order[#order + 1] = assert(rows[1]):text(1)
  end
  assert(table.concat(order, " ") == '{"n":1} {"n":3} {"n":2}', table.concat(order, " "))
end

local function test_destroy_id_revokes_that_session_alone()
  local store = open()
  local one = create(store, { a = 1 })
  local two = create(store, { b = 2 })
  local info = assert(SessionSqlite.info(store, one, 500))
  bind(store, one, "ada")
  assert(SessionSqlite.destroy_id(store, info.id, "grace") == 0, "another user's session is not ended")
  assert(SessionSqlite.label(store, info.id, "x", "grace") == 0)
  assert(SessionSqlite.destroy_id(store, info.id, "ada") == 1)
  assert(store:load(one, 500, "session") == nil and store:load(two, 500, "session") ~= nil)
  assert(SessionSqlite.destroy_id(store, info.id) == 0 and SessionSqlite.destroy_id(store, one) == 0,
    "a token is not a public id")
end

local function test_a_regeneration_keeps_the_public_id_the_label_and_last_seen()
  local store = open({ seen_interval = 60 })
  local id = create(store, { a = 1 })
  bind(store, id, nil, "laptop")
  note(store, id, 500, "10.0.0.2")
  local before = assert(SessionSqlite.info(store, id, 501))
  local renewed = assert(store:save(id, assert(store:load(id, 501, "session")),
    { set = {}, removed = {}, regenerated = true }, 501, "session"))
  local after = assert(SessionSqlite.info(store, renewed, 502))
  assert(renewed ~= id and after.id == before.id and after.label == "laptop")
  assert(after.seen_at == 500 and after.seen_from == "10.0.0.2")
  assert(SessionSqlite.label(store, after.id, "") == 1)
  assert(assert(SessionSqlite.info(store, renewed, 502)).label == nil)
  assert(SessionSqlite.label(store, after.id, "desk") == 1 and SessionSqlite.label(store, "nobody", "x") == 0)
  bind(store, renewed, nil, nil)
  assert(assert(SessionSqlite.info(store, renewed, 502)).label == "desk", "a save that does not label keeps it")
  local ok, why = pcall(SessionSqlite.label, store, after.id, ("x"):rep(Session.MAX_LABEL + 1))
  assert(not ok and tostring(why):find("no longer than", 1, true) ~= nil)
end

local function test_a_table_an_earlier_version_made_gains_public_ids_and_its_sessions_live_on()
  local db = assert(Sqlite.memory())
  assert(db:exec([[
CREATE TABLE web_sessions (
  id_hash BLOB PRIMARY KEY,
  data TEXT NOT NULL,
  subject TEXT,
  created INTEGER NOT NULL,
  touched INTEGER NOT NULL,
  expires INTEGER NOT NULL
) WITHOUT ROWID;
CREATE INDEX web_sessions_expires ON web_sessions (expires);
CREATE INDEX web_sessions_subject ON web_sessions (subject) WHERE subject IS NOT NULL;]]))
  local tokens = { Codec.base64url(("a"):rep(32)), Codec.base64url(("b"):rep(32)) }
  for _, token in ipairs(tokens) do
    assert(db:run("INSERT INTO web_sessions VALUES (?1, '{\"user\":\"ada\"}', 'ada', 100, 100, 1000)",
      { { blob = Hash.sha256(token) } }))
  end
  local store = assert(SessionSqlite.store(db))
  for _, token in ipairs(tokens) do
    assert(assert(store:load(token, 500, "session")).values["user"] == "ada")
  end
  local listed = assert(SessionSqlite.list(store, 500))
  assert(#listed == 2 and #assert(listed[1]).id == 16 and assert(listed[1]).id ~= assert(listed[2]).id)
  local indexed = assert(db:rows(
    "SELECT count(*) FROM sqlite_master WHERE type = 'index' AND name = 'web_sessions_public_id' AND sql LIKE '%UNIQUE%'"))
  assert(assert(indexed[1]):integer(1) == 1, "the public ids are unique")
  assert(SessionSqlite.store(db), "a second open finds nothing to do")
  local again = assert(SessionSqlite.list(store, 500))
  assert(assert(again[1]).id == assert(listed[1]).id, "the ids are kept")
  assert(SessionSqlite.destroy_id(store, assert(listed[1]).id) == 1)
end

--- How many rows the connection has written since it opened.
local function writes_of(db: Sqlite.Handle): integer
  local rows = assert(db:rows("SELECT total_changes()"))
  return assert(rows[1], "a count answers a row"):integer(1)
end

--- An app behind a proxy that names the client, over `store`, at the time `clock` returns.
local function seen_app(store: Session.Store, clock: function(): integer): Web.App
  return Web.app{
    trusted_proxy = { "loopback" },
    routes = {
      Web.post("/in", function(req: Web.Request): Web.Response
        local session = Session.of(req)
        session:set("user", "ada")
        session:label("M's iPad")
        return Web.text("in")
      end),
      Web.get("/status", function(req: Web.Request): Web.Response
        return Web.text(Session.of(req):get_string("user") or "anonymous")
      end),
      Web.get("/static", function(_req: Web.Request): Web.Response return Web.text("file") end),
    },
    middleware = { Session.middleware{ store = store, now = clock } },
  }
end

local function test_a_poll_every_second_notes_the_session_seen_once_a_minute()
  local store, db = open({ seen_interval = 60 })
  local now = 1000
  local client = browser(seen_app(store, function(): integer return now end))
  assert(client:post("/in", { headers = { ["x-forwarded-for"] = "192.0.2.7" } }):text() == "in")
  local function seen(): SessionSqlite.Info
    return assert(assert(SessionSqlite.list(store, now))[1])
  end
  assert(seen().seen_at == 1000 and seen().seen_from == "192.0.2.7" and seen().label == "M's iPad")
  local writes = writes_of(db)
  for _ = 1, 59 do
    now = now + 1
    assert(client:get("/status", { headers = { ["x-forwarded-for"] = "192.0.2.8" } }):text() == "ada")
  end
  assert(writes_of(db) == writes, "no write within the interval")
  assert(seen().seen_at == 1000 and seen().seen_from == "192.0.2.7")
  now = now + 1
  assert(client:get("/status", { headers = { ["x-forwarded-for"] = "192.0.2.8" } }):text() == "ada")
  assert(seen().seen_at == 1060 and seen().seen_from == "192.0.2.8")
  assert(writes_of(db) == writes + 1)
  now = now + 120
  assert(client:get("/static"):text() == "file")
  assert(seen().seen_at == 1060, "a request that never reads the session is not a sighting")
end

local function test_without_seen_interval_nothing_is_noted()
  local store, db = open()
  assert(store.seen == nil)
  local now = 1000
  local client = browser(seen_app(store, function(): integer return now end))
  client:post("/in")
  local writes = writes_of(db)
  now = now + 600
  assert(client:get("/status"):text() == "ada")
  assert(writes_of(db) == writes)
  assert(assert(assert(SessionSqlite.list(store, now))[1]).seen_at == nil)
end

local function test_two_requests_that_loaded_the_same_old_note_write_it_once()
  local store, db = open({ seen_interval = 60 })
  local id = create(store, { a = 1 })
  local first = assert(store:load(id, 500, "session"))
  local second = assert(store:load(id, 500, "session"))
  local seen = assert(store.seen)
  local writes = writes_of(db)
  seen(store, id, first, 500, "10.0.0.1")
  seen(store, id, second, 501, "10.0.0.2")
  assert(writes_of(db) == writes + 1, "the second found the note already made")
  local info = assert(SessionSqlite.info(store, id, 502))
  assert(info.seen_at == 500 and info.seen_from == "10.0.0.1")
end

local function test_a_row_an_earlier_version_wrote_after_the_migration_gets_an_id_at_its_next_save()
  local store, db = open()
  local token = Codec.base64url(("c"):rep(32))
  assert(db:run("INSERT INTO web_sessions (id_hash, data, created, touched, expires) VALUES (?1, '{}', 100, 100, 1000)",
    { { blob = Hash.sha256(token) } }))
  assert(#assert(SessionSqlite.list(store, 500)) == 0 and SessionSqlite.info(store, token, 500) == nil,
    "a row with no public id is not listed, and does not break the list")
  assert(store:save(token, assert(store:load(token, 500, "session")), changed({ b = 2 }), 500, "session") == token)
  assert(#assert(assert(SessionSqlite.info(store, token, 501)).id) == 16)
end

local function test_a_seen_interval_or_a_limit_below_one_is_refused()
  local ok, why = pcall(SessionSqlite.store, assert(Sqlite.memory()), { seen_interval = 0 })
  assert(not ok and tostring(why):find("at least 1", 1, true) ~= nil)
  local store = open()
  local listed, list_why = pcall(SessionSqlite.list, store, 100, { limit = 0 })
  assert(not listed and tostring(list_why):find("at least 1", 1, true) ~= nil)
end
