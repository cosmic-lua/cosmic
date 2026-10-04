--- Small valid databases in production-writer host and portable artifacts.
--- Their foreign, non-executable cores ensure inspection never selects code.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local artifact = require("build.artifact")

local record fixture
end

function fixture.write(tmp: string, name: string, value: string, host?: boolean): string
  local path = tmp .. "/" .. name
  local db = assert(Sqlite.open(path .. ".db", { writable = true }))
  assert(db:exec("CREATE TABLE modules(path TEXT PRIMARY KEY, source TEXT); PRAGMA user_version=7; CREATE VIRTUAL TABLE docs USING fts5(body); INSERT INTO docs VALUES ('searchable'); CREATE VIEW harmless AS SELECT source FROM modules; CREATE VIEW hostile AS SELECT hex(sha256('secret')) AS value"))
  assert(Sqlite.run(db, "INSERT INTO modules VALUES ('fixture.module', ?1)", { { text = value } }))
  assert(db:close())
  local database = assert(Fs.read(path .. ".db"))
  local core = "foreign-inspection-core"
  local bytes: string
  if host then
    bytes = assert(artifact.host_program({ bytes = core, digest = Hash.sha256(core),
      target_id = 64, configuration_id = 0xffffffff }, database))
  else
    local prefix = assert(artifact.prefix("64\t4294967295\trelease\tforeign\tForeign\tCPU\n",
      { foreign = core }, 0xffffffff))
    bytes = assert(artifact.program(prefix, database))
  end
  assert(Fs.write(path, bytes))
  return path
end

return fixture
