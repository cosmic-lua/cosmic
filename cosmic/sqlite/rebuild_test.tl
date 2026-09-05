#!/usr/bin/env cosmic
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local sqlite = require("cosmic.sqlite")

--- The temp path rebuild_atomic derives for `final_path` in THIS
--- process -- same formula the implementation uses, so a test can
--- assert on its litter without reaching into internals otherwise.
local function tmp_path_for(final_path: string): string
  return ("%s.tmp.%d"):format(final_path, proc.getpid())
end

local function db_path(): string
  local dir = check.must(fs.temp_dir())
  return fs.join(dir, "rebuild.db")
end

local function test_rebuild_atomic_populates_and_reopens()
  local path = db_path()
  local db = check.must(sqlite.rebuild_atomic(path, function(tmp_path: string): boolean, string
        local fresh = check.must(sqlite.open(tmp_path))
        assert(fresh:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
        assert(fresh:exec("INSERT INTO t (name) VALUES ('alice')"))
        return fresh:close()
      end))
  assert(fs.is_present(path), "the final file must exist")
  local row = check.must(db:query_one("SELECT name FROM t WHERE id = 1"))
  check.equal(row.name, "alice")
  assert(db:close())
  assert(fs.remove_all(fs.dirname(path)))
end

local function test_rebuild_atomic_leaves_no_temp_litter_on_success()
  local path = db_path()
  local db = check.must(sqlite.rebuild_atomic(path, function(tmp_path: string): boolean, string
        local fresh = check.must(sqlite.open(tmp_path))
        assert(fresh:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)"))
        return fresh:close()
      end))
  local tmp = tmp_path_for(path)
  assert(not fs.is_present(tmp), "the temp file must not survive a successful rebuild")
  assert(not fs.is_present(tmp .. "-wal"), "no stale -wal beside the renamed file's old name")
  assert(not fs.is_present(tmp .. "-shm"), "no stale -shm beside the renamed file's old name")
  assert(db:close())
  assert(fs.remove_all(fs.dirname(path)))
end

local function test_rebuild_atomic_discards_the_temp_file_on_fill_failure()
  local path = db_path()
  local db, err = sqlite.rebuild_atomic(path, function(_tmp_path: string): boolean, string
      return false, "populate failed on purpose"
    end)
  assert(db == nil, "a failing fill_fn must not produce a database")
  assert(err == "populate failed on purpose", "expected the fill_fn's own reason, got: " .. tostring(err))
  assert(not fs.is_present(path), "the final path must never be created")
  local tmp = tmp_path_for(path)
  assert(not fs.is_present(tmp), "the discarded temp file must be cleaned up")
  assert(not fs.is_present(tmp .. "-wal"))
  assert(not fs.is_present(tmp .. "-shm"))
  assert(fs.remove_all(fs.dirname(path)))
end

-- The genuine gotcha this wrapper exists to avoid: a leftover temp
-- file (and its sidecars) from a crashed prior attempt must not
-- survive into the fresh rebuild -- it is wiped before fill_fn ever
-- runs, so stale rows from the crashed attempt can never leak through.
local function test_rebuild_atomic_wipes_a_leftover_temp_file_first()
  local path = db_path()
  local tmp = tmp_path_for(path)
  assert(fs.make_dirs(fs.dirname(tmp)))
  assert(fs.write(tmp, "not a real sqlite file"))
  assert(fs.write(tmp .. "-wal", "stale wal litter"))
  assert(fs.write(tmp .. "-shm", "stale shm litter"))

  local db = check.must(sqlite.rebuild_atomic(path, function(tmp_path: string): boolean, string
        local fresh = check.must(sqlite.open(tmp_path))
        assert(fresh:exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"))
        assert(fresh:exec("INSERT INTO t (name) VALUES ('fresh')"))
        return fresh:close()
      end))
  local row = check.must(db:query_one("SELECT name FROM t WHERE id = 1"))
  check.equal(row.name, "fresh", "the leftover garbage must never survive into the rebuilt file")
  assert(db:close())
  assert(fs.remove_all(fs.dirname(path)))
end

local function test_rebuild_atomic_reopened_connection_is_wal()
  local path = db_path()
  local db = check.must(sqlite.rebuild_atomic(path, function(tmp_path: string): boolean, string
        local fresh = check.must(sqlite.open(tmp_path))
        assert(fresh:exec("CREATE TABLE t (id INTEGER PRIMARY KEY)"))
        return fresh:close()
      end))
  local row = check.must(db:query_one("PRAGMA journal_mode"))
  check.equal(tostring(row.journal_mode):lower(), "wal")
  assert(db:close())
  assert(fs.remove_all(fs.dirname(path)))
end
