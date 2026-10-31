--- The one row of a tool's database that names the tree it was built from (`built_from`, in `meta`), read and
--- rewritten in an artifact (a portable or a host program). A tool records the root of the checkout a boot or a
--- rebuild built it from; a release is built from no checkout, so it carries none ([`cosmic_ci.prerelease`]).
--- This project cannot require build/artifact.tl, so the artifact is read apart at its trailer here.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")

--- An artifact read apart: everything ahead of its database (`head`), the trailer's fields, and the database.
local record Apart
  head: string
  magic: string
  version: integer
  length: integer
  manifest_offset: integer
  manifest_length: integer
  database: string
end

local record ArtifactRow
  type Apart = Apart
end

local trailer_length <const> = 48

--- `bytes`, an artifact, read apart at its trailer. Raises where it is none.
function ArtifactRow.apart(bytes: string): Apart
  local at = #bytes - trailer_length + 1
  local magic = bytes:sub(at, at + 7)
  assert(magic == "CosmicT1" or magic == "CosmicH1", "no artifact trailer")
  local version, length, manifest_offset, manifest_length, database_offset, database_length =
    string.unpack(">I4I4I8I8I8I8", bytes, at + 8)
  assert(length == trailer_length and database_offset + database_length == #bytes - trailer_length,
    "the artifact trailer's ranges do not fit the file")
  return { head = bytes:sub(1, database_offset), magic = magic, version = version, length = length,
    manifest_offset = manifest_offset, manifest_length = manifest_length,
    database = bytes:sub(database_offset + 1, database_offset + database_length) }
end

--- The `meta` rows of the database `bytes` carries, by key. `scratch` is a path to write it at while it is read.
function ArtifactRow.meta(bytes: string, scratch: string): {string:string}
  assert(Fs.write(scratch, ArtifactRow.apart(bytes).database))
  local db = assert(Sqlite.open(scratch))
  local rows = assert(Sqlite.text_rows(db, "SELECT key, value FROM meta"))
  local out: mut {string:string} = {}
  for _, row in ipairs(rows) do out[row:text(1)] = row:text(2) end
  assert(db:close())
  assert(Fs.remove(scratch))
  return out
end

--- `bytes`, an artifact, with the database's `built_from` row set to `built_from`, or removed where that is nil,
--- and everything else as it was. The database is vacuumed, as the writer leaves it, so what two tools built from
--- different paths differ in is that row alone: with the row removed they are the same bytes.
--- `scratch` is a path to write the database at while it is rewritten.
function ArtifactRow.with(bytes: string, scratch: string, built_from: string?): string
  local parts = ArtifactRow.apart(bytes)
  assert(Fs.write(scratch, parts.database))
  local db = assert(Sqlite.open(scratch, { writable = true }))
  if built_from == nil then
    assert(Sqlite.run(db, "DELETE FROM meta WHERE key = 'built_from'"))
  else
    assert(Sqlite.run(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('built_from', ?1)",
      { { text = built_from } }))
  end
  assert(Sqlite.run(db, "VACUUM"))
  assert(db:close())
  local database = assert(Fs.read(scratch))
  assert(Fs.remove(scratch))
  local trailer = parts.magic .. string.pack(">I4I4I8I8I8I8", parts.version, parts.length,
    parts.manifest_offset, parts.manifest_length, #parts.head, #database)
  return parts.head .. database .. trailer
end

return ArtifactRow
