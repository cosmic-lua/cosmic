--- Writing a compiled tree out as the shipped database.
---
--- `o/cosmic.db` is a projection of the working database: a fresh
--- schema attached in memory, filled in one transaction by queries
--- over rows the build already holds -- the images a boot put there,
--- this run's plan joined to the inputs and compiles it names, the
--- declarations a checker needs to build a tree against this one --
--- and produced by `VACUUM INTO`, so a second build of the same tree
--- is byte-identical.

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

--- What the shipped database is a function of: this run's plan with
--- each module's file, the declarations, the images, the fingerprints,
--- identities and host it carries, and the main module, as one hash. When it matches the one the last write left
--- in `meta` and the file is still there, the file already is the
--- projection of these rows, and nothing is written.
local signature_sql =
  "SELECT lower(hex(sha256(" ..
  "coalesce((SELECT group_concat(p.path || ' ' || p.key || ' ' || i.file, " ..
  "char(10) ORDER BY p.path) FROM plan p JOIN inputs i ON i.path = p.path " ..
  "WHERE i.kind <> 'decl'), '') || char(10) || " ..
  "coalesce((SELECT group_concat(path || ' ' || source_hash, char(10) " ..
  "ORDER BY path) FROM inputs WHERE kind = 'decl'), '') || char(10) || " ..
  "coalesce((SELECT group_concat(target || ' ' || hex(sha256), char(10) " ..
  "ORDER BY target) FROM images), '') || char(10) || " ..
  "coalesce((SELECT group_concat(key || ' ' || value, char(10) ORDER BY key) " ..
  "FROM meta WHERE key IN ('boot_hash', 'image_hash', 'host', 'host_image', " ..
  "'compiler', 'runtime')), '') || char(10) || ?1)))"

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
      "INSERT INTO out.decls (path, source) SELECT path, source FROM inputs " ..
      "WHERE kind = 'decl' ORDER BY path"
    statements[#statements + 1] =
      "INSERT INTO out.images (target, sha256, size, encoding, data) " ..
      "SELECT target, sha256, size, encoding, data FROM images ORDER BY target"
    for _, statement in ipairs(statements) do
      local ok, failure = db:exec(statement)
      if not ok then
        return false, failure
      end
    end
    local carried, meta_trouble = db:exec(
      "INSERT INTO out.meta (key, value) SELECT key, value FROM meta " ..
      "WHERE key IN ('boot_hash', 'image_hash', 'host', 'host_image', " ..
      "'compiler', 'runtime')")
    if not carried then
      return false, meta_trouble
    end
    return Sqlite.run(db,
      "INSERT INTO out.meta (key, value) VALUES ('main', ?1)",
      { text(result.main or "") })
  end)
  if not made then
    return false, refused
  end

  Fs.remove(path .. ".building")
  return Sqlite.run(db, "VACUUM out INTO ?1", { text(path .. ".building") })
end

--- Writes an already-compiled result into a fresh database and leaves
--- it at `out`, unless the file there already is that projection. This
--- ends the run's transaction first: SQLite attaches and vacuums
--- outside one only.
function writer.write_result(handle: work.Handle, out: string,
                             result: importer.Result): boolean, string
  local db = handle.db
  local committed, commit_trouble = work.commit(handle)
  if not committed then
    return false, commit_trouble
  end
  local identities, identity_trouble = work.identities(handle)
  if identities == nil then
    return false, identity_trouble
  end
  local signed, sign_trouble = Sqlite.rows(db, signature_sql,
    { text(result.main or "") })
  if signed == nil then
    return false, sign_trouble
  end
  local signature = signed[1][1]
  local last, last_trouble = Sqlite.rows(db,
    "SELECT value FROM meta WHERE key = 'projected'")
  if last == nil then
    return false, last_trouble
  end
  if #last > 0 and last[1][1] == signature and Fs.exists(out) then
    return true, ""
  end

  local attached, attach_trouble = db:exec("ATTACH ':memory:' AS out")
  if not attached then
    return false, attach_trouble
  end
  local projected, trouble = project(handle, out, result)
  db:exec("DETACH out")
  if not projected then
    return false, trouble
  end
  local renamed, rename_trouble = Fs.rename(out .. ".building", out)
  if not renamed then
    return false, rename_trouble
  end
  return Sqlite.run(db,
    "INSERT OR REPLACE INTO meta (key, value) VALUES ('projected', ?1)",
    { text(signature) })
end

return writer
