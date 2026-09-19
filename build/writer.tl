--- Writing a compiled tree out as the shipped database.
---
--- `o/cosmic.db` is a projection of the working database: a fresh
--- schema attached in memory, filled in one transaction from rows the
--- build already holds -- the images and the compiler a boot put
--- there, the modules this run compiled -- and produced by `VACUUM
--- INTO`, so a second build of the same tree is byte-identical.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local importer = require("build.importer")
local schema = require("build.schema")
local work = require("build.work")

local type Module = importer.Module

local record writer
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- The vendored compiler, as the module row a binary carries so it can
--- build a tree of its own. Its Lua is its source; only the bytecode
--- is made here. Nil when the working database holds no compiler, as
--- a project's does not.
local function compiler_module(handle: work.Handle,
                               boot_hash: string): Module | nil, string
  local rows, trouble = Sqlite.rows(handle.db,
    "SELECT file, source, source_hash FROM inputs WHERE kind = 'vendor'")
  if rows == nil then
    return nil, trouble
  end
  if #rows == 0 then
    return nil, ""
  end
  local file, source, source_hash = rows[1][1], rows[1][2], rows[1][3]
  local chunk, load_trouble = load(source, "@vendor.tl", "t")
  if chunk == nil then
    return nil, "the vendored compiler would not load: " .. tostring(load_trouble)
  end
  return {
    path = "vendor.tl",
    file = file,
    kind = "vendor",
    source = source,
    source_hash = source_hash,
    requires = {},
    tests = {},
    has_top_level_return = false,
    generated = false,
    key = Hash.hex_sha256(source .. "\n" .. boot_hash),
    lua = source,
    bytecode = string.dump(chunk, false),
  }
end

local function insert_modules(db: Sqlite.Handle, modules: {Module}): boolean, string
  local statement, trouble = db:prepare(
    "INSERT INTO out.modules (path, file, kind, source_hash, key, source, " ..
    "lua, bytecode, tests) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)")
  if statement == nil then
    return false, trouble
  end
  for _, m in ipairs(modules) do
    statement:bind_text(1, m.path)
    statement:bind_text(2, m.file)
    statement:bind_text(3, m.kind)
    statement:bind_blob(4, m.source_hash)
    statement:bind_blob(5, m.key)
    statement:bind_text(6, m.source)
    statement:bind_text(7, m.lua)
    statement:bind_blob(8, m.bytecode)
    statement:bind_text(9, table.concat(m.tests, "\n"))
    local state, failure = statement:step()
    if state == nil then
      statement:finalize()
      return false, m.path .. ": " .. failure
    end
    statement:reset()
  end
  statement:finalize()
  return true, ""
end

local function insert_imports(db: Sqlite.Handle, modules: {Module}): boolean, string
  local known: {string:boolean} = {}
  for _, m in ipairs(modules) do
    known[m.path] = true
  end
  for _, m in ipairs(modules) do
    for _, name in ipairs(m.requires) do
      if known[name] then
        local ok, trouble = Sqlite.run(db,
          "INSERT OR IGNORE INTO out.imports (path, requires) VALUES (?1, ?2)",
          { text(m.path), text(name) })
        if not ok then
          return false, trouble
        end
      end
    end
  end
  return true, ""
end

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

  local compiler, compiler_trouble = compiler_module(handle, result.boot_hash)
  if compiler == nil and compiler_trouble ~= "" then
    return false, compiler_trouble
  end
  local modules: {Module} = {}
  for _, m in ipairs(result.modules) do
    modules[#modules + 1] = m
  end
  if compiler ~= nil then
    modules[#modules + 1] = compiler
  end

  local made, refused = Sqlite.transact(db, function(): boolean, string
    for _, statement in ipairs(schema.create("out.")) do
      local ok, failure = db:exec(statement)
      if not ok then
        return false, failure
      end
    end
    local stored, module_trouble = insert_modules(db, modules)
    if not stored then
      return false, module_trouble
    end
    local edged, import_trouble = insert_imports(db, modules)
    if not edged then
      return false, import_trouble
    end
    local carried, image_trouble = db:exec(
      "INSERT INTO out.images (target, sha256, size, encoding, data) " ..
      "SELECT target, sha256, size, encoding, data FROM images ORDER BY target")
    if not carried then
      return false, image_trouble
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
