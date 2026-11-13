--- [`test_key.program_database`]: the database a run seals its workers'
--- databases from is read by its range of the program's file.

local Fs = require("cosmic.fs")
local test_key = require("build.test_key")

--- A program whose head is `head_bytes` long ahead of `database`, as a
--- portable program's trailer and manifest lay one out.
local function program_of(head_bytes: integer, database: string): string
  local manifest = "CosmicM1" .. string.pack(">I4I4I8", 2, 4096, head_bytes)
  manifest = manifest .. string.rep("\0", 4096 - #manifest)
  local head = string.rep("c", head_bytes - 4096) .. manifest
  local trailer = "CosmicT1" .. string.pack(">I4I4I8I8I8I8", 2, 48, head_bytes - 4096, 4096, head_bytes, #database)
  return head .. database .. trailer
end

--- Every run that seals takes the program's database from its file, which
--- is mostly launcher and cores: it reads the database and the few bytes
--- that say where it is, and nothing ahead of the manifest. Read whole to
--- be cut, the 4 MB ahead of the database here would be read too.
local function test_the_programs_database_is_read_without_what_is_ahead_of_it(tmp: string)
  local database = "SQLite format 3\0" .. string.rep("row", 1000)
  local ahead <const> = 4 * 1024 * 1024
  local file = tmp .. "/program"
  assert(Fs.write(file, program_of(ahead, database)))
  local read, least = 0, ahead
  local carried = assert(test_key.program_database(file, function(offset: integer, length: integer)
    read = read + length
    if offset < least then least = offset end
  end))
  assert(carried.database == database and carried.offset == ahead and not carried.host)
  -- The trailer, the manifest's head and the database.
  assert(read == #database + 48 + 24, "it read " .. tostring(read) .. " bytes for a database of " .. tostring(#database))
  assert(least == ahead - 4096, "it read from " .. tostring(least) .. ", ahead of the manifest")
end

--- A file that is no artifact, or is not there, is refused with why.
local function test_a_file_that_is_no_artifact_is_refused(tmp: string)
  assert(Fs.write(tmp .. "/short", "x"))
  local short, short_trouble = test_key.program_database(tmp .. "/short")
  assert(short == nil and short_trouble:find("too short for an artifact trailer", 1, true) ~= nil, short_trouble)
  assert(Fs.write(tmp .. "/other", string.rep("x", 8192)))
  local other, other_trouble = test_key.program_database(tmp .. "/other")
  assert(other == nil and other_trouble:find("no artifact trailer", 1, true) ~= nil, other_trouble)
  local absent, absent_trouble = test_key.program_database(tmp .. "/absent")
  assert(absent == nil and absent_trouble ~= "", absent_trouble)
end
