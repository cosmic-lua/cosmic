local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Session = require("cosmic.web.session")
local SessionSqlite = require("cosmic.web.session.sqlite")
local Sqlite = require("cosmic.sqlite")

local function open(opts?: SessionSqlite.Options): Session.Store, Sqlite.Handle
  local db = assert(Sqlite.memory())
  return assert(SessionSqlite.store(db, opts)), db
end

local function fresh(values: {string:any}, expires?: integer): Session.Data
  return { values = values, created = 100, expires = expires or 1000 }
end

local function changed(set: {string:any}): Session.Changes
  return { set = set, removed = {} }
end

--- Saves a new session holding `values` at time 100 and answers its id.
local function create(store: Session.Store, values: {string:any}, expires?: integer): string
  return (assert(store:save("", fresh(values, expires), changed(values), 100, "session")))
end

local function count(db: Sqlite.Handle): integer
  local rows = assert(Sqlite.rows(db, "SELECT count(*) FROM web_sessions"))
  local row = assert(rows[1], "a count query answers one row")
  return row:integer(1)
end

local function test_a_new_session_gets_a_256_bit_id_and_the_table_holds_only_its_hash()
  local store, db = open()
  local id = create(store, { user = "ada" })
  assert(#id == 43 and Codec.unbase64url(id) ~= nil and #assert(Codec.unbase64url(id)) == 32)
  local rows = assert(Sqlite.rows(db, "SELECT id_hash, data FROM web_sessions"))
  assert(#rows == 1 and rows[1]:blob(1) == Hash.sha256(id))
  local rows_1 = assert(rows[1], "expected rows[1]")
  assert(rows_1:text(2):find("ada", 1, true))
  local seen = assert(Sqlite.rows(db, "SELECT count(*) FROM web_sessions WHERE id_hash = ?1 OR data = ?2",
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
  assert(got.values.user == "ada" and got.values.n == 3 and got.created == 100 and got.expires == 1000)
  local missing, why = store:load(("A"):rep(43), 500, "session")
  assert(missing == nil and why == "")
  assert(store:load("short", 500, "session") == nil and store:load("", 500, "session") == nil)
  assert(store:load(id:sub(1, 42) .. "!", 500, "session") == nil)
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
  first.values.a = "from first"
  second.values.b = "from second"
  assert(store:save(id, first, changed({ a = "from first" }), 500, "session") == id)
  assert(store:save(id, second, changed({ b = "from second" }), 501, "session") == id)
  local merged = assert(store:load(id, 502, "session"))
  assert(merged.values.base == 1 and merged.values.a == "from first" and merged.values.b == "from second")
end

local function test_removed_keys_and_clear_are_applied_to_what_is_stored()
  local store = open()
  local id = create(store, { keep = 1, drop = 2, other = 3 })
  local seen = assert(store:load(id, 500, "session"))
  assert(store:save(id, seen, { set = {}, removed = { "drop" } }, 500, "session"))
  local after = assert(store:load(id, 501, "session"))
  assert(after.values.drop == nil and after.values.keep == 1)
  assert(store:save(id, seen, { set = { fresh = true }, removed = {}, cleared = true }, 502, "session"))
  local cleared = assert(store:load(id, 503, "session"))
  assert(cleared.values.keep == nil and cleared.values.fresh == true)
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
  assert(got.values.user == "ada" and got.created == 500)
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
  assert(got.values.theme == "dark" and got.values.user == nil and got.values.secret == nil)
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
  local rows = assert(Sqlite.rows(db, "SELECT count(*) FROM my_sessions"))
  local rows_1 = assert(rows[1], "expected rows[1]")
  assert(rows_1:integer(1) == 1 and store:load(id, 200, "session") ~= nil)
end

local function test_a_store_function_refuses_a_store_not_made_here()
  local ok, why = pcall(SessionSqlite.sweep, { revocable = true } as Session.Store, 100)
  assert(not ok and tostring(why):find("not a store made by SessionSqlite.store", 1, true) ~= nil)
end

local function nest(levels: integer): any
  local value: any = 1
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
  assert(assert(store:load(id, 502, "session")).values.deep ~= nil)
end
