--- Proves the portable writer's deterministic byte layout before any product
--- build path consumes it. The production C decoder is exercised separately
--- by test/portable/format_test.c against these same writer bytes.

local Hash = require("cosmic.hash")
local artifact = require("build.artifact")

local records = table.concat({
  "1\t1\trelease\tx86\tLinux\tx86_64",
  "2\t1\trelease\tarm\tLinux\taarch64",
  "3\t1\trelease\tmac\tDarwin\tarm64",
}, "\n") .. "\n"

local cores: {string:string} = {
  x86 = "ELF-x86\0CosmicM1-in-core",
  arm = "ELF-arm-contents",
  mac = "MACHO-signed-core-contents",
}

local function occurrences(haystack: string, needle: string): integer
  local count = 0
  local at = 1
  while true do
    local found = haystack:find(needle, at, true)
    if found == nil then return count end
    count = count + 1
    at = found + #needle
  end
end

local function test_prefix_is_deterministic_and_holds_each_exact_core_once()
  local one = assert(artifact.prefix(records, cores))
  local two = assert(artifact.prefix(records, cores))
  assert(one == two)
  assert(#one % 4096 == 0)
  assert(one:sub(1, 10) == "#!/bin/sh\n")
  for name, image in pairs(cores) do
    assert(occurrences(one, image) == 1, name .. " core is not present once")
    assert(one:find(Hash.hex_sha256(image), 1, true) ~= nil,
      name .. " digest is absent from the generated shell arm")
  end
end

local function test_manifest_ranges_name_the_exact_core_bytes()
  local prefix = assert(artifact.prefix(records, cores))
  local manifest_at = #prefix - 4096 + 1
  assert(prefix:sub(manifest_at, manifest_at + 7) == "CosmicM1")
  local version, encoded, prefix_length, count, entry_size, at =
    string.unpack(">I4I4I8I4I4", prefix, manifest_at + 8)
  assert(version == 1 and encoded == 4096 and prefix_length == #prefix)
  assert(count == 3 and entry_size == 56)
  local names = { "x86", "arm", "mac" }
  for i = 1, count do
    local target: integer
    local configuration: integer
    local offset: integer
    local length: integer
    target, configuration, offset, length, at =
      string.unpack(">I4I4I8I8", prefix, at)
    local digest = prefix:sub(at, at + 31)
    at = at + 32
    local image = cores[names[i]] as string
    assert(target == i and configuration == 1)
    assert(length == #image)
    assert(prefix:sub(offset + 1, offset + length) == image)
    assert(digest == Hash.sha256(image))
  end
  assert(prefix:sub(at, at + 31) == string.rep("\0", 32),
    "unused manifest bytes are zero")
end

local function test_programs_share_the_prefix_and_have_distinct_suffixes()
  local prefix = assert(artifact.prefix(records, cores))
  local db_one = "SQLite format 3\0one database"
  local db_two = "SQLite format 3\0two database"
  local one = assert(artifact.program(prefix, db_one))
  local two = assert(artifact.program(prefix, db_two))
  assert(one:sub(1, #prefix) == prefix and two:sub(1, #prefix) == prefix)
  assert(one:sub(#prefix + 1) ~= two:sub(#prefix + 1))
  assert(one:sub(-48, -41) == "CosmicT1")
  local version, length, manifest_offset, manifest_length,
    database_offset, database_length = string.unpack(">I4I4I8I8I8I8", one, #one - 39)
  assert(version == 1 and length == 48)
  assert(manifest_offset == #prefix - 4096 and manifest_length == 4096)
  assert(database_offset == #prefix and database_length == #db_one)
end

local function test_writer_rejects_ambiguous_or_incomplete_inputs()
  local missing, trouble = artifact.prefix(records, { x86 = cores.x86 })
  assert(missing == nil and trouble:find("no raw core", 1, true) ~= nil)
  local duplicate = records .. "1\t1\trelease\tother\tOther\tarch\n"
  local bad, duplicate_trouble = artifact.prefix(duplicate, {
    x86 = cores.x86, arm = cores.arm, mac = cores.mac, other = "core",
  })
  assert(bad == nil and duplicate_trouble:find("duplicate", 1, true) ~= nil)
  local program, database_trouble = artifact.program(
    assert(artifact.prefix(records, cores)), "not sqlite")
  assert(program == nil and database_trouble:find("SQLite", 1, true) ~= nil)
end

local function test_checked_manifest_keeps_release_entries_but_selects_checked()
  local checked_records = records ..
    "1\t2\tsanitized\tsanitized-x86\tLinux\tx86_64\n"
  local checked_cores: {string:string} = {
    x86 = cores.x86,
    arm = cores.arm,
    mac = cores.mac,
    ["sanitized-x86"] = "ELF-checked-x86-contents",
  }
  local prefix = assert(artifact.prefix(checked_records, checked_cores, 2))
  assert(prefix:find("cosmic_configuration_id=2", 1, true) ~= nil)
  assert(prefix:find("cosmic_configuration_id=1", 1, true) == nil)
  local manifest_at = #prefix - 4096 + 1
  local _, _, _, count = string.unpack(">I4I4I8I4", prefix,
    manifest_at + 8)
  assert(count == 4)
  for _, image in pairs(checked_cores) do
    assert(occurrences(prefix, image) == 1)
  end

  local absent, absent_trouble = artifact.prefix(records, cores, 2)
  assert(absent == nil and
    absent_trouble:find("has no generated", 1, true) ~= nil)
  local duplicate_system = checked_records ..
    "2\t2\tsanitized\tsanitized-arm\tLinux\tx86_64\n"
  checked_cores["sanitized-arm"] = "ELF-other-checked-contents"
  local ambiguous, ambiguous_trouble =
    artifact.prefix(duplicate_system, checked_cores, 2)
  assert(ambiguous == nil and
    ambiguous_trouble:find("duplicate generated uname", 1, true) ~= nil)
end

--- A portable and a host program alike split at their database, and
--- rejoin to the same bytes, or around a new database to what the
--- writer would have written with it.
local function test_split_finds_the_database_either_writer_appended()
  local prefix = assert(artifact.prefix(records, cores))
  local one = "SQLite format 3\0one"
  local two = "SQLite format 3\0the second, longer"
  local portable = assert(artifact.program(prefix, one))
  local host = assert(artifact.host_program({ bytes = cores.x86, digest = Hash.sha256(cores.x86),
    target_id = 1, configuration_id = 1 }, one))
  for bytes, is_host in pairs({ [portable] = false, [host] = true }) do
    local parts = assert(artifact.split(bytes))
    assert(parts.database == one)
    assert(parts.host == is_host)
    assert(artifact.rejoin(parts, one) == bytes)
    local swapped = assert(artifact.rejoin(parts, two))
    local again = assert(artifact.split(swapped))
    assert(again.database == two and again.head == parts.head and again.host == is_host)
  end
  assert(artifact.rejoin(assert(artifact.split(portable)), two) == artifact.program(prefix, two))
end

--- A trailer whose fields do not fit the file is refused, never read
--- past.
local function test_split_refuses_a_trailer_that_does_not_fit()
  local prefix = assert(artifact.prefix(records, cores))
  local program = assert(artifact.program(prefix, "SQLite format 3\0db"))
  local refused: {string} = {
    "",
    program:sub(2),
    program .. "x",
    program:sub(1, -49) .. "CosmicX1" .. program:sub(-40),
    -- The database's length one longer than the file holds.
    program:sub(1, -9) .. string.pack(">I8", 19),
    -- One too long for any integer, which reads negative.
    program:sub(1, -9) .. string.pack(">I8", -1),
  }
  for i, bytes in ipairs(refused) do
    local parts, trouble = artifact.split(bytes)
    assert(parts == nil and trouble ~= "", "case " .. i)
  end
  local not_sqlite = assert(artifact.split(program))
  local joined, trouble = artifact.rejoin(not_sqlite, "not sqlite")
  assert(joined == nil and trouble:find("SQLite", 1, true), trouble)
end
