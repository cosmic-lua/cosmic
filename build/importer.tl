--- The tree, read by position into a database.
---
--- A source's path relative to the root is its import path, so nothing
--- lists what a module is: `cosmic/fs.tl` is `cosmic.fs`. A `*.d.tl`
--- declares a module the core provides and holds no code, so it is read
--- for its type and never stored.
---
--- A module's key is the content hash of its source, the keys of
--- everything it imports, and the hash of the tool that compiled it. An
--- unchanged key is a stat; a changed one recompiles what depended on
--- it.

local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local positions = require("build.positions")
local schema = require("build.schema")
local type compiler = require("build.compiler")

local type Module = positions.Module

local record importer
  Module: Module

  record Result
    modules: {Module}
    boot_hash: string
    entry: string | nil
  end
end

--- Whether `root` is cosmic's own tree, structurally: `core/` and
--- `build/` both exist, and `build/` holds the importer itself rather
--- than just a directory of that name. `cosmic.*` is reserved to this
--- one tree; nothing else may claim it, by directory or by import path.
--- Exposed so a caller can gate other cosmic's-own-tree behavior on the
--- same test the importer itself uses.
function importer.is_own_tree(root: string): boolean
  return Fs.is_dir(root .. "/core") and Fs.is_dir(root .. "/build") and
    Fs.exists(root .. "/build/importer.tl") and
    not Fs.is_dir(root .. "/build/importer.tl")
end

--- The bytecode header every target must agree on. One column of
--- bytecode serves all three because they are all little-endian and
--- 64-bit; this is what says so out loud, so a target whose sizes or
--- byte order differ fails the build rather than a launch.
---
--- The bytes are the signature, the version and format, the data check,
--- and the size and value of an int, an instruction, an integer and a
--- number.
local bytecode_header =
  "\27LuaU\0\25\147\13\10\26\10" ..
  "\4\136\169\255\255" ..
  "\4\120\86\52\18" ..
  "\8\136\169\255\255\255\255\255\255" ..
  "\8\0\0\0\0\0\40\119\192"

--- What is never a module: the build's own output, the upstream
--- sources and the records that patch them, prose, and anything
--- hidden.
local not_source: {string:boolean} = {
  ["o"] = true,
  ["vendor"] = true,
  ["patches"] = true,
  ["doc"] = true,
  ["bin"] = true,
}

local function skip(entry: string): boolean
  local first = entry:match("^([^/]+)") or entry
  if not_source[first] then
    return true
  end
  local name = entry:match("([^/]+)$") or entry
  return name:sub(1, 1) == "."
end

local function import_path(file: string): string
  return (file:gsub("%.tl$", ""):gsub("/", "."))
end

local function is_source(file: string): boolean
  return file:sub(-3) == ".tl" and file:sub(-5) ~= ".d.tl"
end

local function kind_of(file: string): string
  if file:match("_test%.tl$") ~= nil then
    return "test"
  end
  if file:match("_example%.tl$") ~= nil then
    return "example"
  end
  if file:match("^cmd/[^/]+/main%.tl$") ~= nil then
    return "entry"
  end
  return "module"
end

--- The modules another module names, in the order they appear.
local function requires_of(source: string): {string}
  local seen: {string:boolean} = {}
  local found: {string} = {}
  for name in source:gmatch('require%s*%(?%s*"([%w_%.]+)"') do
    if not seen[name] then
      seen[name] = true
      found[#found + 1] = name
    end
  end
  return found
end

--- Every source the tree holds, read and hashed. The root is the module
--- root, so a file's place in it is its import path.
--- @param self_tree whether `root` is cosmic's own tree, where the
---   `cosmic.` namespace is not reserved against the tree itself
local function collect(root: string, self_tree: boolean): {Module} | nil, string
  if not self_tree and Fs.is_dir(root .. "/cosmic") then
    return nil, "cosmic: the 'cosmic' directory is reserved to cosmic's own tree"
  end
  local out: {Module} = {}
  local files, trouble = Fs.walk(root, skip)
  if files == nil then
    return nil, trouble
  end
  for _, file in ipairs(files) do
    if is_source(file) then
      if not self_tree and (file == "cosmic" or file:sub(1, 7) == "cosmic/") then
        return nil, file .. ": the 'cosmic' directory is reserved to " ..
          "cosmic's own tree"
      end
      local source, failure = Fs.read(root .. "/" .. file)
      if source == nil then
        return nil, failure
      end
      out[#out + 1] = {
        path = import_path(file),
        file = file,
        kind = kind_of(file),
        source = source,
        source_hash = Hash.hex_sha256(source),
        requires = requires_of(source),
        key = "",
        lua = "",
        bytecode = "",
      }
    end
  end
  table.sort(out, function(a: Module, b: Module): boolean
    return a.path < b.path
  end)
  return out
end

--- The modules in an order where nothing is compiled before what it
--- imports. A cycle is reported rather than looped on.
local function ordered(modules: {Module}): {Module} | nil, string
  local by_path: {string:Module} = {}
  for _, m in ipairs(modules) do
    by_path[m.path] = m
  end

  local out: {Module} = {}
  local state: {string:string} = {}

  local visit: function(Module): boolean, string
  visit = function(m: Module): boolean, string
    if state[m.path] == "done" then
      return true, ""
    end
    if state[m.path] == "visiting" then
      return false, "a cycle of imports reaches " .. m.path
    end
    state[m.path] = "visiting"
    for _, name in ipairs(m.requires) do
      local other = by_path[name]
      if other ~= nil then
        local ok, trouble = visit(other)
        if not ok then
          return false, trouble
        end
      end
    end
    state[m.path] = "done"
    out[#out + 1] = m
    return true, ""
  end

  for _, m in ipairs(modules) do
    local ok, trouble = visit(m)
    if not ok then
      return nil, trouble
    end
  end
  return out
end

--- The hash of the tool itself, over the trees a build is made of. A
--- row compiled by an older importer is never mistaken for a current
--- one, because this is part of every key. A binary carries the number
--- it was built with, so a project reads it rather than computing one.
function importer.boot_hash(root: string): string | nil, string
  local parts: {string} = {}
  for _, tree in ipairs({ "build", "core" }) do
    local files, trouble = Fs.walk(root .. "/" .. tree)
    if files == nil then
      return nil, trouble
    end
    for _, relative in ipairs(files) do
      local data, failure = Fs.read(root .. "/" .. tree .. "/" .. relative)
      if data == nil then
        return nil, failure
      end
      parts[#parts + 1] = tree .. "/" .. relative .. " " .. Hash.hex_sha256(data)
    end
  end
  return Hash.hex_sha256(table.concat(parts, "\n"))
end

local function complain(file: string, result: compiler.Result): string
  local lines: {string} = {}
  for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
    for _, e in ipairs(group or {}) do
      local where = e.filename ~= "" and e.filename or file
      lines[#lines + 1] = where .. ":" .. e.y .. ":" .. e.x .. ": " .. e.msg
    end
  end
  return table.concat(lines, "\n")
end

--- Compiles every module, in import order, into Lua and bytecode.
--- @param root the tree to read
--- @param built the compiler, loaded and ready
--- @param env the checker's environment, already pointed at the tree
--- @param boot_hash what the tool doing the compiling hashes to
function importer.compile(root: string, built: compiler, env: compiler.Env,
                          boot_hash: string): importer.Result | nil, string
  local modules, trouble = collect(root, importer.is_own_tree(root))
  if modules == nil then
    return nil, trouble
  end
  local positioned, position_trouble = positions.check(modules)
  if not positioned then
    return nil, position_trouble
  end
  local order, why = ordered(modules)
  if order == nil then
    return nil, why
  end
  local keys: {string:string} = {}
  local entry: string | nil = nil

  for _, m in ipairs(order) do
    local closure: {string} = {}
    for _, name in ipairs(m.requires) do
      if keys[name] ~= nil then
        closure[#closure + 1] = name .. " " .. keys[name]
      end
    end
    table.sort(closure)
    m.key = Hash.hex_sha256(
      m.source_hash .. "\n" .. table.concat(closure, "\n") .. "\n" .. boot_hash)
    keys[m.path] = m.key

    local code, result = built.gen(m.source, env, nil, "tl")
    local refused = result ~= nil and complain(m.file, result) or ""
    if code == nil or refused ~= "" then
      return nil, m.file .. ": the compiler refused it\n" .. refused
    end
    m.lua = code

    local chunk, load_trouble = load(code, "@" .. m.path, "t")
    if chunk == nil then
      return nil, m.file .. ": " .. tostring(load_trouble)
    end
    m.bytecode = string.dump(chunk, false)
    if m.bytecode:sub(1, #bytecode_header) ~= bytecode_header then
      return nil, m.file .. ": this host dumps bytecode the three targets " ..
        "do not share"
    end

    if m.kind == "entry" then
      entry = m.path
    end
  end

  return { modules = order, boot_hash = boot_hash, entry = entry }
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
    "bytecode, decl) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL)")
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

--- Writes the whole tree into a fresh database and leaves it at `out`.
--- The database is built in memory in one transaction and the file is
--- produced by VACUUM INTO, so the bytes are a function of the tree.
--- @param images the core image for each target, by target name
--- @param teal_source the vendored compiler, which a binary must carry
---   so it can build a tree of its own; nil when building a project
---   with a binary that already has one
function importer.write(root: string, out: string, built: compiler,
                        env: compiler.Env, boot_hash: string,
                        images: {string:string},
                        teal_source: string | nil): boolean, string
  local result, trouble = importer.compile(root, built, env, boot_hash)
  if result == nil then
    return false, trouble
  end

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
      { "entry", result.entry or "" },
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

return importer
