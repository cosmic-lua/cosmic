--- Writing a compiled tree out as the shipped database.
---
--- `o/cosmic.db` is a projection of the working database: a fresh
--- schema attached in memory, filled in one transaction by queries
--- over rows the build already holds -- the images a boot put there,
--- this run's plan joined to the inputs and compiles it names -- and
--- produced by `VACUUM INTO`, so a second build of the same tree is
--- byte-identical.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local importer = require("build.importer")
local schema = require("build.schema")
local work = require("build.work")

local record writer
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- The shipped modules: this run's plan joined to the inputs it named
--- and the compiles it found or made, with a test module's own test
--- names alongside.
local insert_modules =
  "INSERT INTO out.modules (path, file, kind, source_hash, key, source, " ..
  "lua, bytecode, tests) " ..
  "SELECT i.path, i.file, i.kind, CAST(i.source_hash AS BLOB), " ..
  "CAST(p.key AS BLOB), i.source, c.lua, c.bytecode, " ..
  "CASE WHEN i.kind = 'test' THEN coalesce((SELECT group_concat(name, " ..
  "char(10) ORDER BY ordinal) FROM tests t " ..
  "WHERE t.source_hash = i.source_hash), '') ELSE '' END " ..
  "FROM plan p JOIN inputs i ON i.path = p.path " ..
  "JOIN compiled c ON c.key = p.key ORDER BY p.path"

--- The import edges among shipped modules: what each planned module
--- requires, kept only where the name is itself a planned module.
local insert_imports =
  "INSERT OR IGNORE INTO out.imports (path, requires) " ..
  "SELECT p.path, r.name FROM plan p " ..
  "JOIN inputs i ON i.path = p.path " ..
  "JOIN requires r ON r.source_hash = i.source_hash " ..
  "WHERE r.name IN (SELECT path FROM plan) ORDER BY p.path, r.ordinal"

--- Fills the attached `out` schema and vacuums it into `path`.
local function project(handle: work.Handle, path: string,
                       result: importer.Result): boolean, string
  local db = handle.db
  for _, statement in ipairs(schema.settings("out.")) do
    local ok, failure = db:exec(statement)
    if not ok then
      return false, failure
    end
  end

  local made, refused = Sqlite.transact(db, function(): boolean, string
    local statements: {string} = {}
    for _, statement in ipairs(schema.create("out.")) do
      statements[#statements + 1] = statement
    end
    statements[#statements + 1] = insert_modules
    statements[#statements + 1] = insert_imports
    statements[#statements + 1] =
      "INSERT INTO out.images (target, sha256, size, encoding, data) " ..
      "SELECT target, sha256, size, encoding, data FROM images ORDER BY target"
    for _, statement in ipairs(statements) do
      local ok, failure = db:exec(statement)
      if not ok then
        return false, failure
      end
    end
    local meta: {{string}} = {
      { "boot_hash", result.boot_hash },
      { "main", result.main or "" },
    }
    for _, pair in ipairs(meta) do
      local ok, failure = Sqlite.run(db,
        "INSERT INTO out.meta (key, value) VALUES (?1, ?2)",
        { text(pair[1]), text(pair[2]) })
      if not ok then
        return false, failure
      end
    end
    return true, ""
  end)
  if not made then
    return false, refused
  end

  Fs.remove(path .. ".building")
  return Sqlite.run(db, "VACUUM out INTO ?1", { text(path .. ".building") })
end

--- Writes an already-compiled result into a fresh database and leaves
--- it at `out`.
function writer.write_result(handle: work.Handle, out: string,
                             result: importer.Result): boolean, string
  local attached, attach_trouble = handle.db:exec("ATTACH ':memory:' AS out")
  if not attached then
    return false, attach_trouble
  end
  local projected, trouble = project(handle, out, result)
  handle.db:exec("DETACH out")
  if not projected then
    return false, trouble
  end
  return Fs.rename(out .. ".building", out)
end

return writer
