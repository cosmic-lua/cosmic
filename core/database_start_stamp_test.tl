--- The stamp a `--database` start of a cached core leaves beside it
--- (core/startup.c's `stamp_write`), which spares a later start the core's
--- hash; the start itself is core/database_start_test.tl's.
---
--- TODO: run this off Linux too, or say why it cannot, once someone decides
--- whether a stamp means anything for a macOS core: the module requires
--- Linux, a guard that came with no reason.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local database_start_fixture = require("build.database_start_fixture")

--- The core is started past its launcher.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  requires = { "os:linux" },
}

local core_digest = database_start_fixture.core_digest
local core_or_skip = database_start_fixture.core_or_skip
local run = database_start_fixture.run
local info_database = database_start_fixture.info_database

--- A core run from a cache entry -- a name that holds its target, its
--- configuration, its length and its digest -- is hashed once: the stamp
--- the first start leaves beside it (core/startup.c's `stamp_write`) says
--- it was, and a start that finds the stamp holding does not hash it
--- again. A write to the entry in place, which keeps its inode and size
--- and moves its times, makes the stamp stale, so the next start hashes it
--- and finds the database was not written for these bytes.
local function test_a_core_a_stamp_vouches_for_is_not_hashed_again_until_it_is_written(tmp: string)
  local core = core_or_skip()
  local prefix = Fs.basename(core):match("^(core%-%d+%-%d+%-)%d+%-%x+$")
  if prefix == nil then
    Test.skip("the core " .. core .. " is not named as a cached core is")
    return
  end
  local bytes = assert(Fs.read(core))
  local digest = core_digest()
  local directory = tmp .. "/cores"
  assert(Fs.mkdirs(directory))
  local copy = directory .. "/" .. prefix .. tostring(#bytes) .. "-" .. digest
  assert(Fs.write(copy, bytes))
  assert(Fs.chmod(copy, (assert(tonumber("755", 8), "755 is octal"))))
  local path = info_database(tmp)
  local stamp = directory .. "/.verified-" .. Fs.basename(copy)
  -- A stamp is written only once a second has passed since the entry changed.
  local _, _ = Clock.sleep(Clock.ms(1100))
  assert(not assert(Fs.status(stamp)).exists, "a stamp before any start")
  local first = run({ copy, "--database", path })
  assert(first.ok, "exit " .. tostring(first.code) .. ": " .. tostring(first.stderr))
  assert(assert(Fs.status(stamp)).exists, "the first start left no stamp")
  local second = run({ copy, "--database", path })
  assert(second.ok, "exit " .. tostring(second.code) .. ": " .. tostring(second.stderr))
  -- Written in place, a second or more after the stamp: the same inode and
  -- size, other times. The last byte is no part of what the core runs.
  local _, _ = Clock.sleep(Clock.ms(1100))
  local fd = assert(sys.open(copy, sys.O_RDWR))
  local last = assert(sys.lseek(fd, -1, sys.SEEK_END))
  local old = assert(sys.read(fd, 1))
  assert(sys.lseek(fd, last, sys.SEEK_SET))
  assert(sys.write(fd, string.char((assert(old:byte(), "a byte was read")) ~ 1)))
  assert(sys.close(fd))
  local third = run({ copy, "--database", path })
  assert(third.code == 2 and (assert(third.stderr)):find("another core", 1, true) ~= nil,
    "exit " .. tostring(third.code) .. ": " .. tostring(third.stderr))
end
