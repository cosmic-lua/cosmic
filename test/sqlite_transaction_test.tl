local Sqlite = require("cosmic.sqlite")
local Failure = require("cosmic.failure")

local function test_exception_rolls_back_and_preserves_error()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (value TEXT)"))
  local marker = { message = "callback failed" }
  local called, failure = pcall(function()
    local _, _ = db:transact(function(): (true) | (false, Failure)
      assert(db:exec("INSERT INTO items VALUES ('discard')"))
      error(marker)
    end)
  end)
  assert(not called and failure == marker)
  local rows = assert(db:rows("SELECT value FROM items"))
  assert(#rows == 0)
  assert(db:transact(function(): (true) | (false, Failure)
    return db:run("INSERT INTO items VALUES ('keep')")
  end))
  rows = assert(db:rows("SELECT value FROM items"))
  assert(#rows == 1 and rows[1]:text(1) == "keep")
  local _, _ = db:close()
end

local function test_false_callback_rolls_back_with_reason()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (value TEXT)"))
  local ok, why = db:transact(function(): (true) | (false, Failure)
    assert(db:exec("INSERT INTO items VALUES ('discard')"))
    return false, Failure.new("declined")
  end)
  assert(not ok and why.message == "declined")
  local rows = assert(db:rows("SELECT value FROM items"))
  assert(#rows == 0)
  assert(db:exec("BEGIN; ROLLBACK"))
  local _, _ = db:close()
end

local function test_commit_failure_rolls_back()
  local db = assert(Sqlite.memory())
  assert(db:exec("PRAGMA foreign_keys = ON"))
  assert(db:exec("CREATE TABLE parent (id INTEGER PRIMARY KEY)"))
  assert(db:exec("CREATE TABLE child (parent_id INTEGER REFERENCES parent(id) " ..
      "DEFERRABLE INITIALLY DEFERRED)"))
  local ok, why = db:transact(function(): (true) | (false, Failure)
    return db:run("INSERT INTO child VALUES (1)")
  end)
  assert(not ok and tostring(why):find("FOREIGN KEY", 1, true) ~= nil)
  local rows = assert(db:rows("SELECT parent_id FROM child"))
  assert(#rows == 0)
  assert(db:exec("BEGIN; ROLLBACK"))
  local _, _ = db:close()
end

--- A transact inside another nests as a savepoint: its failure rolls back its own work alone, and its work commits
--- with the outer transaction.
local function test_a_nested_transact_is_a_savepoint()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE items (value TEXT)"))
  assert(db:transact(function(): (true) | (false, Failure)
    assert(db:run("INSERT INTO items VALUES ('outer')"))
    local inner, inner_why = db:transact(function(): (true) | (false, Failure)
      assert(db:run("INSERT INTO items VALUES ('declined')"))
      return false, Failure.new("declined")
    end)
    assert(not inner and inner_why.message == "declined")
    local raised, _ = pcall(function()
      local _, _ = db:transact(function(): (true) | (false, Failure)
        assert(db:run("INSERT INTO items VALUES ('raised')"))
        error("boom")
      end)
    end)
    assert(not raised)
    return db:transact(function(): (true) | (false, Failure)
      return db:run("INSERT INTO items VALUES ('kept')")
    end)
  end))
  local rows = assert(db:rows("SELECT value FROM items ORDER BY rowid"))
  assert(#rows == 2 and assert(rows[1]):text(1) == "outer" and assert(rows[2]):text(1) == "kept", tostring(#rows))
  -- After a BEGIN of the caller's own, transact nests too, and the caller's ROLLBACK undoes it.
  assert(db:exec("BEGIN"))
  assert(db:transact(function(): (true) | (false, Failure)
    return db:run("INSERT INTO items VALUES ('undone')")
  end))
  assert(db:exec("ROLLBACK"))
  assert(#assert(db:rows("SELECT value FROM items")) == 2)
  assert(db:close())
end

--- On a writable handle transact begins IMMEDIATE: it holds the write lock before the work writes, so another writer
--- waits for it rather than meeting a snapshot it would have to give up.
local function test_a_writable_transact_takes_the_write_lock_at_once(tmp: string)
  local path = tmp .. "/locks.db"
  local a = assert(Sqlite.open(path, { writable = true }))
  assert(a:exec("PRAGMA journal_mode = WAL; CREATE TABLE t (n INTEGER)"))
  local b = assert(Sqlite.open(path, { writable = true }))
  b:busy_timeout(0)
  assert(a:transact(function(): (true) | (false, Failure)
    local rows, why = b:rows("SELECT count(*) FROM t")
    assert(rows ~= nil, tostring(why))
    local begun, begun_why = b:exec("BEGIN IMMEDIATE")
    assert(not begun and begun_why.code == Sqlite.BUSY, "the write lock was free")
    return true
  end))
  assert(b:exec("BEGIN IMMEDIATE; COMMIT"))
  assert(b:close())
  assert(a:close())
end

--- On a read-only handle transact begins DEFERRED, so a read of several statements sees one snapshot.
local function test_a_read_only_transact_reads_one_snapshot(tmp: string)
  local path = tmp .. "/snap.db"
  local w = assert(Sqlite.open(path, { writable = true }))
  assert(w:exec("PRAGMA journal_mode = WAL; CREATE TABLE t (n INTEGER); INSERT INTO t VALUES (1)"))
  local r = assert(Sqlite.open(path))
  assert(r:transact(function(): (true) | (false, Failure)
    assert(assert(assert(r:rows("SELECT count(*) FROM t"))[1]):integer(1) == 1)
    assert(w:run("INSERT INTO t VALUES (2)"))
    assert(assert(assert(r:rows("SELECT count(*) FROM t"))[1]):integer(1) == 1)
    return true
  end))
  assert(assert(assert(r:rows("SELECT count(*) FROM t"))[1]):integer(1) == 2)
  -- `begin` names another mode.
  assert(w:transact(function(): (true) | (false, Failure)
    return w:run("INSERT INTO t VALUES (3)")
  end, "exclusive"))
  assert(r:close())
  assert(w:close())
end

--- A failure that rolls back the whole transaction inside a nested call raises, so the caller's work stops before
--- what it writes after commits on its own.
local function test_a_nested_failure_that_ends_the_outer_transaction_raises()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (n INTEGER PRIMARY KEY)"))
  local after = false
  local called, why = pcall(function()
    local _, _ = db:transact(function(): (true) | (false, Failure)
      assert(db:run("INSERT INTO t VALUES (1)"))
      local _, _ = db:transact(function(): (true) | (false, Failure)
        return db:run("INSERT OR ROLLBACK INTO t VALUES (1)")
      end)
      after = true
      return db:run("INSERT INTO t VALUES (2)")
    end)
  end)
  assert(not called and tostring(why):find("the transaction around this one ended inside it", 1, true) ~= nil,
    tostring(why))
  assert(tostring(why):find("UNIQUE", 1, true) ~= nil, tostring(why))
  assert(not after and not db:in_transaction())
  assert(#assert(db:rows("SELECT n FROM t")) == 0)
  assert(db:close())
end

--- Work that commits its own transaction fails; nested, it raises.
local function test_work_that_ends_its_transaction_is_refused()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (n INTEGER)"))
  local ok, why = db:transact(function(): (true) | (false, Failure)
    assert(db:run("INSERT INTO t VALUES (1)"))
    return db:exec("COMMIT")
  end)
  assert(not ok and tostring(why):find("COMMIT or ROLLBACK of its own", 1, true) ~= nil, tostring(why))
  local called, raised = pcall(function()
    local _, _ = db:transact(function(): (true) | (false, Failure)
      return db:transact(function(): (true) | (false, Failure)
        return db:exec("ROLLBACK")
      end)
    end)
  end)
  assert(not called and tostring(raised):find("the transaction around this one ended inside it", 1, true) ~= nil,
    tostring(raised))
  assert(not db:in_transaction())
  assert(db:close())
end

--- Savepoints nest three deep under one name: each failure rolls back its own level alone.
local function test_savepoints_nest_three_deep()
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE TABLE t (n INTEGER)"))
  assert(db:transact(function(): (true) | (false, Failure)
    assert(db:run("INSERT INTO t VALUES (1)"))
    assert(db:transact(function(): (true) | (false, Failure)
      assert(db:run("INSERT INTO t VALUES (2)"))
      local ok, _ = db:transact(function(): (true) | (false, Failure)
        assert(db:run("INSERT INTO t VALUES (3)"))
        return false, Failure.new("not this one")
      end)
      assert(not ok)
      return true
    end))
    return true
  end))
  local rows = assert(db:rows("SELECT group_concat(n) FROM t"))
  assert(assert(rows[1]):text(1) == "1,2", assert(rows[1]):text(1))
  assert(db:close())
end

--- A begin that cannot take the write lock returns busy, with nothing run; a mode transact does not know raises.
local function test_a_busy_begin_runs_no_work_and_an_unknown_mode_raises(tmp: string)
  local path = tmp .. "/busy.db"
  local a = assert(Sqlite.open(path, { writable = true }))
  assert(a:exec("CREATE TABLE t (n INTEGER)"))
  local b = assert(Sqlite.open(path, { writable = true }))
  b:busy_timeout(0)
  assert(a:exec("BEGIN IMMEDIATE"))
  local ran = false
  local ok, why = b:transact(function(): (true) | (false, Failure)
    ran = true
    return true
  end)
  assert(not ok and why.code == Sqlite.BUSY and not ran, tostring(why))
  assert(a:exec("COMMIT"))
  -- From Lua, which no enum holds to the three modes.
  local untyped = assert(load("local b = ...; return b:transact(function() return true end, 'now; DROP TABLE t')"))
  local called, raised = pcall(function() local _ = untyped(b) end)
  assert(not called and tostring(raised):find("transact begins", 1, true) ~= nil, tostring(raised))
  assert(b:close())
  assert(a:close())
end

--- `in_transaction` follows BEGIN and COMMIT, and a SAVEPOINT outside one; `read_only` is the main database's.
local function test_in_transaction_and_read_only(tmp: string)
  local path = tmp .. "/flags.db"
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE t (n INTEGER)"))
  local raw = db.connection
  assert(not raw:in_transaction() and not raw:read_only())
  assert(db:exec("BEGIN"))
  assert(raw:in_transaction())
  assert(db:exec("COMMIT; SAVEPOINT s"))
  assert(raw:in_transaction())
  assert(db:exec("RELEASE s"))
  assert(not raw:in_transaction())
  local reader = assert(Sqlite.open(path))
  assert(reader.connection:read_only())
  local frozen = assert(Sqlite.open(path, { immutable = true }))
  assert(frozen.connection:read_only())
  assert(frozen:close())
  assert(reader:close())
  assert(db:close())
end
