--- [`cosmic.fake`]: what a fake is built of, and a build that fails.
--- What a fake of a main runs and reads is build/fake_main_test.tl's,
--- whose main is a module of the tree.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Fake = require("cosmic.fake")
local artifact = require("build.artifact")

--- A build that cannot be written says why.
local function test_a_failed_build_says_why(tmp: string)
  local dir = tmp .. "/fake"
  assert(Fs.write(dir, "a file where its directory would be\n"))
  local program, trouble = Fake.build(dir, Fake.REPLY)
  assert(program == nil, program)
  assert(tostring(trouble):find(dir, 1, true), tostring(trouble))
end

--- The fake is a host program, sealed as [`Store.seal`] seals one,
--- whose main is the one it was built of: it carries no `build.*` row at
--- all, nor the time zones or CA roots its closure would call for, and
--- does carry what the core itself requires of a program
--- ([`cosmic.errors`]), but not [`cosmic.removed`], which only words a
--- refusal of a removed global its main never reaches for.
local function test_the_fake_carries_its_main_and_little_else(tmp: string)
  local parts = assert(artifact.split((assert(Fs.read((assert(Fake.build(tmp .. "/fake", Fake.REPLY))))))))
  assert(parts.host)
  local path = tmp .. "/carried.db"
  assert(Fs.write(path, parts.database))
  local db = assert(Sqlite.open(path))
  local function one(sql: string): string
    local rows = assert(db:text_rows(sql))
    return rows[1] and rows[1]:text(1) or ""
  end
  assert(one("SELECT value FROM meta WHERE key = 'main'") == Fake.REPLY)
  assert(one("SELECT count(*) FROM modules WHERE path LIKE 'build.%'") == "0")
  assert(one("SELECT count(*) FROM modules WHERE path IN " ..
      "('cosmic.errors', 'cosmic.json')") == "2")
  assert(one("SELECT count(*) FROM modules WHERE path = 'cosmic.removed'") == "0")
  assert(one("SELECT count(*) FROM zoneinfo") == "0")
  assert(one("SELECT count(*) FROM ca_roots") == "0")
  assert(one("SELECT value FROM meta WHERE key = 'runtime_basis'") ~= "")
  assert(db:close())
end

--- The dependency traversal's order is deterministic even though it
--- is not path order: rowids must not move a repeated build's bytes.
local function test_the_fake_is_reproducible(tmp: string)
  local one = assert(Fs.read((assert(Fake.build(tmp .. "/one", Fake.REPLY)))))
  local two = assert(Fs.read((assert(Fake.build(tmp .. "/two", Fake.REPLY)))))
  assert(one == two, "repeating the fake build changed its bytes")
end
