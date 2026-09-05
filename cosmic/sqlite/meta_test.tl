#!/usr/bin/env cosmic
local check = require("cosmic.check")
local sqlite = require("cosmic.sqlite")

local function open_with_meta_table(): sqlite.Database
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("CREATE TABLE cosmic_meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)"))
  return db
end

local function test_schema_fingerprint_is_stable_for_the_same_schema()
  local a = check.must(sqlite.open(":memory:"))
  assert(a:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  local b = check.must(sqlite.open(":memory:"))
  assert(b:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  local fp_a = check.must(sqlite.schema_fingerprint(a))
  local fp_b = check.must(sqlite.schema_fingerprint(b))
  check.equal(fp_a, fp_b, "identical schema should fingerprint identically")
  assert(a:close())
  assert(b:close())
end

local function test_schema_fingerprint_changes_with_the_schema()
  local a = check.must(sqlite.open(":memory:"))
  assert(a:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
  local fp_before = check.must(sqlite.schema_fingerprint(a))
  assert(a:exec("CREATE TABLE u (id INTEGER PRIMARY KEY)"))
  local fp_after = check.must(sqlite.schema_fingerprint(a))
  check.not_equal(fp_after, fp_before, "an added table must change the fingerprint")
  assert(a:close())
end

local function test_schema_fingerprint_of_an_empty_database_is_stable()
  local a = check.must(sqlite.open(":memory:"))
  local b = check.must(sqlite.open(":memory:"))
  check.equal(check.must(sqlite.schema_fingerprint(a)), check.must(sqlite.schema_fingerprint(b)))
  assert(a:close())
  assert(b:close())
end

local function test_meta_get_set_roundtrip()
  local db = open_with_meta_table()
  assert(sqlite.meta_set(db, "refs_digest", "abc123"))
  check.equal(check.must(sqlite.meta_get(db, "refs_digest")), "abc123")
  assert(db:close())
end

local function test_meta_set_overwrites_an_existing_key()
  local db = open_with_meta_table()
  assert(sqlite.meta_set(db, "k", "first"))
  assert(sqlite.meta_set(db, "k", "second"))
  check.equal(check.must(sqlite.meta_get(db, "k")), "second")
  assert(db:close())
end

local function test_meta_get_of_a_missing_key_is_not_a_failure()
  local db = open_with_meta_table()
  local v, err = sqlite.meta_get(db, "never-set")
  check.equal(v, nil, "absent key")
  check.equal(err, nil, "an ordinary miss is not a failure")
  assert(db:close())
end

local function test_meta_get_on_a_missing_table_is_a_real_failure()
  -- No cosmic_meta table created here -- distinct from the "key
  -- absent" case above, which needs the table to exist.
  local db = check.must(sqlite.open(":memory:"))
  local v, err = sqlite.meta_get(db, "k")
  check.equal(v, nil)
  assert(err ~= nil and err:find("no such table", 1, true),
    "expected a real query failure, got: " .. tostring(err))
  assert(db:close())
end

local function test_db_user_version_defaults_to_zero()
  local db = check.must(sqlite.open(":memory:"))
  check.equal(check.must(sqlite.db_user_version(db)), 0)
  assert(db:close())
end

local function test_db_user_version_reflects_what_was_set()
  local db = check.must(sqlite.open(":memory:"))
  assert(db:exec("PRAGMA user_version = 7"))
  check.equal(check.must(sqlite.db_user_version(db)), 7)
  assert(db:close())
end
