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

local function integer(value: integer): Sqlite.Value
  return { integer = value }
end

local null: Sqlite.Value = {}

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

--- The catalog entries `build.positions.catalog_of` found while parsing
--- each planned module: every `return nil, ...` whose enclosing
--- function's own comments named guidance for it. `id` is left for
--- SQLite to assign, in this SELECT's own deterministic order -- the
--- hand-authored rows below claim the low ids first, so this always
--- continues after them the same way on every build.
local insert_catalog_extracted =
  "INSERT INTO out.catalog (kind, module, symbol, message, text, file, " ..
  "line) SELECT 'error', p.path, c.symbol, c.message, c.guidance, " ..
  "i.file, c.line FROM plan p JOIN inputs i ON i.path = p.path " ..
  "JOIN catalog c ON c.source_hash = i.source_hash " ..
  "ORDER BY p.path, c.ordinal"

--- One hand-authored catalog row: a name or a `strerror()` message the
--- catalog matches on, the guidance already known for it, and where it
--- comes from.
local record CatalogSeedRow
  symbol: string
  message: string
  hint: string
  file: string
  line: integer
end

--- Hand-authored catalog rows, seeded ahead of the extracted ones:
--- `core/surface.c`'s five replacement hints (its C source is not
--- walked by `build.positions`'s Teal-only extractor), and guidance for
--- the handful of `strerror()` messages cosmic's own syscalls can
--- plausibly raise -- `core/fail.h`'s `cosmic_fail` returns `nil,
--- strerror(errno), errno`, and a stdlib wrapper like `cosmic/fs.tl`'s
--- `path .. ": " .. trouble` stitches that literal text straight into
--- what a program sees, so it is exactly as matchable as an authored
--- message. `message` carries no symbol; `core_fail(errno name)` names
--- where each guidance's `strerror()` string comes from instead.
local catalog_seed: {CatalogSeedRow} = {
  { symbol = "io",
    message = "",
    hint = "io is not available: files are cosmic.fs, and the standard " ..
           "streams are cosmic.fs.stdout, .stderr and .stdin",
    file = "core/surface.c", line = 21 },
  { symbol = "os",
    message = "",
    hint = "os is not available: time is cosmic.time, the environment " ..
           "is cosmic.env, and processes are cosmic.proc",
    file = "core/surface.c", line = 23 },
  { symbol = "debug",
    message = "",
    hint = "debug is not available: a traceback is cosmic.errors.trace",
    file = "core/surface.c", line = 25 },
  { symbol = "dofile",
    message = "",
    hint = "dofile is not available: a module comes from require, and " ..
           "a file's bytes come from cosmic.fs.read",
    file = "core/surface.c", line = 26 },
  { symbol = "loadfile",
    message = "",
    hint = "loadfile is not available: a module comes from require, " ..
           "and a file's bytes come from cosmic.fs.read",
    file = "core/surface.c", line = 28 },
  { symbol = "ENOENT",
    message = "No such file or directory",
    hint = "the path does not exist -- check it is spelled right, and " ..
           "that every parent directory already exists; cosmic.fs " ..
           "creates no parent directories on its own",
    file = "core/fail.h", line = 0 },
  { symbol = "EACCES",
    message = "Permission denied",
    hint = "the process does not have permission for this path -- " ..
           "check its ownership and mode, cosmic.fs.stat's own fields",
    file = "core/fail.h", line = 0 },
  { symbol = "EEXIST",
    message = "File exists",
    hint = "something is already at this path -- cosmic.fs.remove it " ..
           "first, or use a call that tolerates an existing target",
    file = "core/fail.h", line = 0 },
  { symbol = "ENOTDIR",
    message = "Not a directory",
    hint = "a path segment that should be a directory is a plain file " ..
           "instead -- check every component up to the last",
    file = "core/fail.h", line = 0 },
  { symbol = "EISDIR",
    message = "Is a directory",
    hint = "the path names a directory where a file was expected -- " ..
           "reading or writing needs a file path, not a directory",
    file = "core/fail.h", line = 0 },
  { symbol = "ENOSPC",
    message = "No space left on device",
    hint = "the filesystem holding this path is full",
    file = "core/fail.h", line = 0 },
  { symbol = "EMFILE",
    message = "Too many open files",
    hint = "this process already has too many files open -- close ones " ..
           "no longer needed before opening more",
    file = "core/fail.h", line = 0 },
}

--- Rebuilds `catalog_fts`'s index from `catalog`'s current rows: the
--- documented way to bulk-load an external-content FTS5 table without
--- keeping the two in sync through triggers a read-only, write-once
--- database has no use for.
local rebuild_catalog_fts =
  "INSERT INTO out.catalog_fts(catalog_fts) VALUES ('rebuild')"

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
    for id, row in ipairs(catalog_seed) do
      local module = row.file == "core/surface.c" and "(global)" or "(errno)"
      local message = #row.message > 0 and text(row.message) or null
      local ok, failure = Sqlite.run(db,
        "INSERT INTO out.catalog (id, kind, module, symbol, message, " ..
        "text, file, line) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        { integer(id), text("error"), text(module), text(row.symbol),
          message, text(row.hint), text(row.file), integer(row.line) })
      if not ok then
        return false, failure
      end
    end
    local extracted, extracted_trouble = db:exec(insert_catalog_extracted)
    if not extracted then
      return false, extracted_trouble
    end
    local rebuilt, rebuild_trouble = db:exec(rebuild_catalog_fts)
    if not rebuilt then
      return false, rebuild_trouble
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
