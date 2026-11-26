--- [`ChecksSeal.seal`] over memos of the shape build/check_memo.tl shares.
local ChecksSeal = require("cosmic_ci.checks_seal")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

local CREATE <const> = "CREATE TABLE check_memo_v1 (code TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, " ..
  "value TEXT NOT NULL, used_ns INTEGER NOT NULL, PRIMARY KEY (code, kind, key)) WITHOUT ROWID"

--- A memo at `path` in write-ahead mode whose rows, used at the seconds `used`, are all in its `-wal` file: copied
--- while the run that wrote them still had it open, as a run of `cosmic fix` leaves it.
local function memo_in_wal(path: string, used: {integer})
  local live = path .. ".live"
  local db = assert(Sqlite.open(live, { writable = true }))
  assert(db:exec("PRAGMA journal_mode = WAL"))
  assert(db:exec("PRAGMA wal_autocheckpoint = 0"))
  assert(db:exec(CREATE))
  for i, seconds in ipairs(used) do
    assert(db:run("INSERT INTO check_memo_v1 VALUES ('c', 'checked', ?1, 'v', ?2)",
      { { text = "k" .. tostring(i) }, { integer = seconds * 1000000000 } }))
  end
  assert(Fs.write(path, (assert(Fs.read(live)))))
  assert(Fs.write(path .. "-wal", (assert(Fs.read(live .. "-wal")))))
  assert(db:close())
end

local function keys(path: string): string
  local db = assert(Sqlite.open(path))
  local out: mut {string} = {}
  for _, row in ipairs((assert(db:rows("SELECT key FROM check_memo_v1 ORDER BY key")))) do
    out[#out + 1] = row:text(1)
  end
  assert(db:close())
  return table.concat(out, " ")
end

--- The rows in the write-ahead log are in the file itself once sealed, which a copy of the file alone holds; the
--- rows used before SINCE are gone.
local function test_a_sealed_memo_is_whole_in_its_file(tmp: string)
  local path = tmp .. "/checks.db"
  memo_in_wal(path, { 100, 200, 300 })
  local said = ChecksSeal.seal(path, 200)
  assert(said.code == 0 and said.err == "", said.out .. said.err)
  assert(said.out:find("2 rows", 1, true) ~= nil, said.out)
  local wal, _ = Fs.stat(path .. "-wal")
  assert(wal == nil or wal.size == 0, "the write-ahead log is left beside the file")
  assert(Fs.write(tmp .. "/copy.db", (assert(Fs.read(path)))))
  assert(keys(tmp .. "/copy.db") == "k2 k3", keys(tmp .. "/copy.db"))
  -- With no SINCE every row stays.
  memo_in_wal(tmp .. "/all.db", { 100, 200 })
  assert(ChecksSeal.seal(tmp .. "/all.db").code == 0)
  assert(keys(tmp .. "/all.db") == "k1 k2")
end

--- A file that is no memo, one with no row the run used, and one that is not there are refused; a path that is not
--- absolute is a mistake of the step.
local function test_what_is_no_memo_is_refused(tmp: string)
  assert(ChecksSeal.seal(tmp .. "/none.db").code == 1)
  local other = tmp .. "/other.db"
  local db = assert(Sqlite.open(other, { writable = true }))
  assert(db:exec("CREATE TABLE elsewhere (a TEXT)"))
  assert(db:close())
  local said = ChecksSeal.seal(other)
  assert(said.code == 1 and said.err:find("no table check_memo_v1", 1, true) ~= nil, said.err)
  memo_in_wal(tmp .. "/old.db", { 100 })
  said = ChecksSeal.seal(tmp .. "/old.db", 200)
  assert(said.code == 1 and said.err:find("no row", 1, true) ~= nil, said.err)
  assert(Fs.write(tmp .. "/text.db", "not a database"))
  assert(ChecksSeal.seal(tmp .. "/text.db").code == 1)
  assert(ChecksSeal.seal("checks.db").code == 2)
end
