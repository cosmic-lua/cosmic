--- The parts of the proof that the tool can be bootstrapped from the new checker's seed ([`build.seed_proof`]) that need no
--- boot: what it carries into the translated tree, and how it compares the bridge's Lua with the pipeline's.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local SeedProof = require("build.seed_proof")

--- The real seed booting a tree (compiling its 30 files twice, then the closure of build.boot) takes some 15 seconds, more than
--- a test of the suite may: `bin/cosmic build/seed_proof_main.tl prove <dir>` runs it, and build/bridge_new_test.tl holds the
--- bridge's stages and the names of lang/SEED_DIFFERS on a seed of two stand-in files.
---
-- TODO: run `prove` in CI's rehearsal job beside the proof of lang/ (ci/cosmic_ci/orchestration.tl), so the real seed is booted
-- on every change, once the switch makes the rehearsal job a required one (doc/plans/strict-teal.md, "the switch").

--- The translated tree has no lang/SEED_DIFFERS of its own: the proof carries the checkout's, so that a seed the pin lags
--- behind the generator by is excused in the boot as it is in step 2.
local function test_the_proof_carries_the_seed_list_the_declared_differences_and_the_headers(tmp: string)
  assert(Fs.mkdirs(tmp .. "/root/lang"))
  assert(Fs.mkdirs(tmp .. "/root/core"))
  assert(Fs.mkdirs(tmp .. "/root/build"))
  assert(Fs.write(tmp .. "/root/lang/SEED_DIFFERS", "lang/truthy.tl\n"))
  assert(Fs.write(tmp .. "/root/build/seed.txt", "build/seed.tl\n"))
  assert(Fs.write(tmp .. "/root/core/syscalls.h", "/* header */\n"))
  assert(Fs.write(tmp .. "/root/core/bridge.lua", "-- not carried\n"))
  assert(SeedProof.carry(tmp .. "/root", tmp .. "/tree"))
  assert(Fs.read(tmp .. "/tree/lang/SEED_DIFFERS") == "lang/truthy.tl\n")
  assert(Fs.read(tmp .. "/tree/build/seed.txt") == "build/seed.tl\n")
  assert(Fs.read(tmp .. "/tree/core/syscalls.h") == "/* header */\n")
  assert(Fs.exists(tmp .. "/tree/core/bridge.lua") ~= true)
  -- Without a declared difference there is no file to carry, and the carry says nothing of it.
  assert(Fs.remove(tmp .. "/root/lang/SEED_DIFFERS"))
  assert(SeedProof.carry(tmp .. "/root", tmp .. "/tree2"))
  assert(Fs.exists(tmp .. "/tree2/lang/SEED_DIFFERS") ~= true)
end

local function test_the_lua_the_bridge_dumps_is_compared_with_the_pipelines(tmp: string)
  local db = assert(Sqlite.open(tmp .. "/cache.db", { writable = true, create = true }))
  assert(Sqlite.run(db, "CREATE TABLE compiled_v2 (key TEXT PRIMARY KEY, lua BLOB NOT NULL)"))
  assert(Sqlite.run(db, "INSERT INTO compiled_v2 VALUES ('a', deflate('return 1\n'))"))
  assert(db:close())
  assert(Fs.mkdirs(tmp .. "/dump"))
  assert(Fs.write(tmp .. "/dump/a.lua", "return 1\n"))
  assert(Fs.write(tmp .. "/dump/b.lua", "return 2\n"))
  local compared = assert(SeedProof.unequal(tmp .. "/dump", tmp .. "/cache.db"))
  assert(compared.held == 2 and #compared.differ == 1 and compared.differ[1] == "b.lua")
end
