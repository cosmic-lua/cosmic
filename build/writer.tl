--- Writing a compiled tree into a fresh database.
---
--- `build.importer` turns the tree into Lua and bytecode; this turns
--- that result into the database file `require` reads at run time. The
--- two are split so a caller that needs the compiled modules for
--- itself, such as the test runner, gets them from one compile rather
--- than paying for the second one `write` alone would otherwise run.

local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local importer = require("build.importer")
local schema = require("build.schema")
local work = require("build.work")
local type compiler = require("build.compiler")

local type Module = importer.Module

local record writer
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

local function blob(value: string): Sqlite.Value
  return { blob = value }
end

local function insert_modules(handle: Sqlite.Handle, modules: {Module}): boolean, string
  local statement, trouble = handle:prepare(
    "INSERT INTO modules (path, file, kind, source_hash, key, source, lua, " ..
    "bytecode, tests, decl) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, NULL)")
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

local function insert_imports(handle: Sqlite.Handle, modules: {Module}): boolean, string
  local known: {string:boolean} = {}
  for _, m in ipairs(modules) do
    known[m.path] = true
  end
  for _, m in ipairs(modules) do
    for _, name in ipairs(m.requires) do
      if known[name] then
        local ok, trouble = Sqlite.run(handle,
          "INSERT OR IGNORE INTO imports (path, requires) VALUES (?1, ?2)",
          { text(m.path), text(name) })
        if not ok then
          return false, trouble
        end
      end
    end
  end
  return true, ""
end

--- Writes an already-compiled result into a fresh database and leaves
--- it at `out`.
--- @param images the core image for each target, by target name
--- @param teal_source the vendored compiler, which a binary must carry
---   so it can build a tree of its own; nil when building a project
---   with a binary that already has one
function writer.write_result(out: string, result: importer.Result,
                             images: {string:string},
                             teal_source: string | nil): boolean, string
  if teal_source ~= nil then
    local chunk, load_trouble = load(teal_source, "@vendor.tl", "t")
    if chunk == nil then
      return false, "the vendored compiler would not load: " ..
        tostring(load_trouble)
    end
    result.modules[#result.modules + 1] = {
      path = "vendor.tl",
      file = "o/vendor/tl/tl.lua",
      kind = "vendor",
      source = teal_source,
      source_hash = Hash.hex_sha256(teal_source),
      requires = {},
      tests = {},
      key = Hash.hex_sha256(teal_source .. "\n" .. result.boot_hash),
      lua = teal_source,
      bytecode = string.dump(chunk, false),
    }
  end

  local handle, why = Sqlite.memory()
  if handle == nil then
    return false, why
  end

  for _, statement in ipairs(schema.settings) do
    local ok, failure = handle:exec(statement)
    if not ok then
      handle:close()
      return false, failure
    end
  end

  local made, refused = Sqlite.transact(handle, function(): boolean, string
    for _, statement in ipairs(schema.tables) do
      local ok, failure = handle:exec(statement)
      if not ok then
        return false, failure
      end
    end

    local stored, module_trouble = insert_modules(handle, result.modules)
    if not stored then
      return false, module_trouble
    end
    local edged, import_trouble = insert_imports(handle, result.modules)
    if not edged then
      return false, import_trouble
    end

    local targets: {string} = {}
    for target in pairs(images) do
      targets[#targets + 1] = target
    end
    table.sort(targets)
    for _, target in ipairs(targets) do
      local image = images[target]
      local packed, deflate_trouble = Compress.deflate(image)
      if packed == nil then
        return false, target .. ": " .. deflate_trouble
      end
      local ok, failure = Sqlite.run(handle,
        "INSERT INTO images (target, sha256, size, encoding, data) " ..
        "VALUES (?1, ?2, ?3, 'deflate', ?4)",
        { text(target), blob(Hash.sha256(image)), { integer = #image },
          blob(packed) })
      if not ok then
        return false, failure
      end
    end

    local meta: {{string}} = {
      { "boot_hash", result.boot_hash },
      { "main", result.main or "" },
    }
    for _, pair in ipairs(meta) do
      local ok, failure = Sqlite.run(handle,
        "INSERT INTO meta (key, value) VALUES (?1, ?2)",
        { text(pair[1]), text(pair[2]) })
      if not ok then
        return false, failure
      end
    end
    return true, ""
  end)
  if not made then
    handle:close()
    return false, refused
  end

  Fs.remove(out .. ".building")
  local vacuumed, vacuum_trouble = Sqlite.run(handle,
    "VACUUM INTO ?1", { text(out .. ".building") })
  handle:close()
  if not vacuumed then
    return false, vacuum_trouble
  end

  return Fs.rename(out .. ".building", out)
end

--- Compiles the whole staged tree and writes the result into a fresh
--- database at `out`.
--- @param images the core image for each target, by target name
--- @param teal_source the vendored compiler, which a binary must carry
---   so it can build a tree of its own; nil when building a project
---   with a binary that already has one
function writer.write(handle: work.Handle, out: string, built: compiler,
                      env: compiler.Env, boot_hash: string,
                      images: {string:string},
                      teal_source: string | nil): boolean, string
  local result, trouble = importer.compile(handle, built, env, boot_hash)
  if result == nil then
    return false, trouble
  end
  return writer.write_result(out, result, images, teal_source)
end

return writer
