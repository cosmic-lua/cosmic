--- Building a project into executables: one file each, the host's core
--- image with a database behind it that holds the project's modules,
--- the standard library, the error catalog, and the name of the main
--- module, so it runs on its own with no `cosmic` beside it.
---
--- A binary is a directory under `cmd/`: `cmd/<name>/main.tl` compiles
--- as `kind = "main"`, and `cosmic build` writes `o/bin/<name>` for
--- each one the tree holds, after building the tree as `cosmic test`
--- does; a tree with no `cmd/` builds and writes nothing. The project's
--- own projection, `o/cosmic.db`,
--- carries the project and nothing of cosmic's; what the standard
--- library needs at run time is read out of the running binary's own
--- database, by handle, so no format of the executable is parsed here.
---
--- cosmic's own tree is not embedded this way: `bin/zig build boot`
--- builds the tool, and carries the three images and the compiler that
--- a program of its own never needs.

local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Time = require("cosmic.time")
local attach = require("build.attach")
local importer = require("build.importer")
local schema = require("build.schema")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")

local record embed
end

local function report(line: string)
  Fs.put(Fs.stdout, line .. "\n")
end

local function complain(line: string)
  Fs.put(Fs.stderr, "cosmic: " .. line .. "\n")
end

local function elapsed_ms(started: integer): integer
  local now = Time.monotonic_ns() or started
  return (now - started) // 1000000
end

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- One column of the row a statement is standing on, bound as what it
--- was: a blob stays a blob, a null stays a null.
local function value_at(statement: Sqlite.Statement, index: integer): Sqlite.Value
  local kind = statement:kind(index)
  if kind == "null" then
    return {}
  end
  if kind == "blob" then
    return { blob = statement:bytes(index) }
  end
  if kind == "integer" then
    return { integer = math.tointeger(tonumber(statement:bytes(index))) or 0 }
  end
  if kind == "number" then
    return { number = tonumber(statement:bytes(index)) or 0 }
  end
  return text(statement:bytes(index))
end

--- Copies every row `sql` yields from one database into a table of
--- another, column for column, each value bound as the kind it was
--- read as. `columns` names the destination columns in `sql`'s order.
local function copy_rows(from: Sqlite.Handle, into: Sqlite.Handle,
                         table_name: string, columns: {string},
                         sql: string, values?: {Sqlite.Value}): boolean, string
  local statement, trouble = from:prepare(sql)
  if statement == nil then
    return false, table_name .. ": " .. trouble
  end
  for index, value in ipairs(values or {}) do
    local bound, bind_trouble: boolean, string
    if value.text ~= nil then
      bound, bind_trouble = statement:bind_text(index, value.text)
    else
      bound, bind_trouble = statement:bind_null(index)
    end
    if not bound then
      statement:finalize()
      return false, table_name .. ": " .. bind_trouble
    end
  end
  local slots: {string} = {}
  for index = 1, #columns do
    slots[index] = "?" .. index
  end
  local insert = "INSERT OR IGNORE INTO " .. table_name .. " (" ..
    table.concat(columns, ", ") .. ") VALUES (" .. table.concat(slots, ", ") .. ")"
  while true do
    local state, step_trouble = statement:step()
    if state == nil then
      statement:finalize()
      return false, table_name .. ": " .. step_trouble
    end
    if state == "done" then
      break
    end
    local row: {Sqlite.Value} = {}
    for index = 1, #columns do
      row[index] = value_at(statement, index - 1)
    end
    local ok, insert_trouble = Sqlite.run(into, insert, row)
    if not ok then
      statement:finalize()
      return false, table_name .. ": " .. insert_trouble
    end
  end
  statement:finalize()
  return true, ""
end

local module_columns = { "path", "file", "kind", "source_hash", "key",
                         "source", "lua", "bytecode", "tests" }
local catalog_columns = { "kind", "module", "symbol", "message", "text",
                          "file", "line" }

--- The `<name>` of `cmd/<name>/main.tl`, from its import path.
local function name_of(main: string): string | nil
  return main:match("^cmd%.([^%.]+)%.main$")
end

--- What the binary's own database holds for one target's core image.
local function image_of(binary: Sqlite.Handle, target: string): string | nil, string
  local rows, trouble = Sqlite.text_rows(binary,
    "SELECT size, data FROM images WHERE target = ?1", { text(target) })
  if rows == nil then
    return nil, trouble
  end
  if #rows == 0 then
    return nil, "this binary carries no image for " .. target
  end
  local size = math.tointeger(tonumber(rows[1][1])) or 0
  local image, inflate_trouble = Compress.inflate(rows[1][2], size)
  if image == nil then
    return nil, target .. ": " .. inflate_trouble
  end
  return image
end

--- The database one executable carries, as bytes: the project's own
--- projection at `project` joined with what the running binary holds
--- that a program needs at run time -- every `cosmic.*` module, every
--- declaration, the error catalog -- and `main` naming the module the
--- executable runs. Written beside the projection, then vacuumed, so
--- the bytes are a function of the two databases and nothing else.
function embed.database(project: string, main: string): string | nil, string
  local databases = Store.databases()
  local binary = databases[#databases]
  if binary == nil then
    return nil, "no database is attached to this binary"
  end
  local building = project .. ".embed"
  Fs.remove(building)
  Fs.remove(building .. ".vacuumed")
  local out, open_trouble = Sqlite.open(building, true)
  if out == nil then
    return nil, building .. ": " .. open_trouble
  end
  local statements: {string} = {}
  for _, statement in ipairs(schema.settings("")) do
    statements[#statements + 1] = statement
  end
  for _, statement in ipairs(schema.create("")) do
    statements[#statements + 1] = statement
  end
  for _, statement in ipairs(statements) do
    local ok, failure = out:exec(statement)
    if not ok then
      out:close()
      return nil, failure
    end
  end

  local made, trouble = Sqlite.transact(out, function(): boolean, string
    -- The standard library first, so a project's row never stands in
    -- for a `cosmic.*` module; then the project, whole.
    local copied, copy_trouble = copy_rows(binary, out, "modules",
      module_columns,
      "SELECT path, file, kind, source_hash, key, source, lua, bytecode, " ..
      "tests FROM modules WHERE kind = 'module' AND path LIKE 'cosmic.%' " ..
      "ORDER BY path")
    if not copied then
      return false, copy_trouble
    end
    copied, copy_trouble = copy_rows(binary, out, "imports",
      { "path", "requires" },
      "SELECT path, requires FROM imports WHERE path LIKE 'cosmic.%' " ..
      "ORDER BY path, requires")
    if not copied then
      return false, copy_trouble
    end
    copied, copy_trouble = copy_rows(binary, out, "decls",
      { "path", "source" }, "SELECT path, source FROM decls ORDER BY path")
    if not copied then
      return false, copy_trouble
    end
    -- The guidance a program's own errors can match: the standard
    -- library's own extracted rows. It never runs the build, so a row
    -- about the build could only ever match by accident.
    copied, copy_trouble = copy_rows(binary, out, "catalog", catalog_columns,
      "SELECT kind, module, symbol, message, text, file, line FROM catalog " ..
      "WHERE module LIKE 'cosmic.%' ORDER BY id")
    if not copied then
      return false, copy_trouble
    end
    local attached, attach_trouble = Sqlite.run(out,
      "ATTACH DATABASE ?1 AS project", { text(project) })
    if not attached then
      return false, attach_trouble
    end
    for _, statement in ipairs({
      "INSERT OR IGNORE INTO modules SELECT * FROM project.modules " ..
        "ORDER BY path",
      "INSERT OR IGNORE INTO imports SELECT * FROM project.imports " ..
        "ORDER BY path, requires",
      "INSERT INTO catalog (kind, module, symbol, message, text, file, " ..
        "line) SELECT kind, module, symbol, message, text, file, line " ..
        "FROM project.catalog ORDER BY id",
      "INSERT INTO docs_fts(docs_fts) VALUES ('rebuild')",
      "INSERT INTO catalog_fts(catalog_fts) VALUES ('rebuild')",
      "INSERT INTO examples_fts(examples_fts) VALUES ('rebuild')",
    }) do
      local ok, failure = out:exec(statement)
      if not ok then
        return false, failure
      end
    end
    local meta: {{string}} = {
      { "host", Store.meta("host") or "" },
      { "compiler", Store.meta("compiler") or "" },
      { "runtime", Store.meta("runtime") or "" },
      { "main", main },
    }
    for _, pair in ipairs(meta) do
      local ok, failure = Sqlite.run(out,
        "INSERT INTO meta (key, value) VALUES (?1, ?2)",
        { text(pair[1]), text(pair[2]) })
      if not ok then
        return false, failure
      end
    end
    return true, ""
  end)
  if not made then
    out:close()
    return nil, trouble
  end
  out:exec("DETACH DATABASE project")
  local vacuumed, vacuum_trouble = Sqlite.run(out, "VACUUM INTO ?1",
    { text(building .. ".vacuumed") })
  out:close()
  if not vacuumed then
    return nil, vacuum_trouble
  end
  local bytes, read_trouble = Fs.read(building .. ".vacuumed")
  Fs.remove(building)
  Fs.remove(building .. ".vacuumed")
  if bytes == nil then
    return nil, read_trouble
  end
  return bytes
end

--- Builds the tree at `root` and writes `root/o/bin/<name>` for every
--- `cmd/<name>/main.tl` it holds, for the target this binary runs on.
--- Returns the names written, none for a tree with no `cmd/`.
function embed.tree(root: string): {string} | nil, string
  if importer.is_own_tree(root) then
    return nil, "this is cosmic's own tree, which bin/zig build boot builds"
  end
  local host = Store.meta("host")
  if host == nil then
    return nil, "this binary names no host target"
  end
  local started = Time.monotonic_ns() or 0
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    work.close(handle)
    return nil, stage_trouble
  end
  local built, load_trouble = teal.load()
  if built == nil then
    work.close(handle)
    return nil, load_trouble
  end
  local env, env_trouble = teal.environment_for(built, handle)
  if env == nil then
    work.close(handle)
    return nil, env_trouble
  end
  local project = root .. "/o/cosmic.db"
  local result, compile_trouble =
    importer.compile(handle, built, env, Store.meta("compiler") or "")
  if result == nil then
    work.record(handle, elapsed_ms(started), staged, 0, 0, "FAIL")
    work.close(handle)
    return nil, compile_trouble
  end
  local written, write_trouble = writer.write_result(handle, project, result)
  work.record(handle, elapsed_ms(started), staged, result.compiled,
    result.cached, written and "PASS" or "FAIL")
  work.close(handle)
  if not written then
    return nil, write_trouble
  end

  local mains: {string} = {}
  for _, m in ipairs(result.modules) do
    if m.kind == "main" then
      mains[#mains + 1] = m.path
    end
  end
  table.sort(mains)
  if #mains == 0 then
    return {}
  end

  local databases = Store.databases()
  local image, image_trouble = image_of(databases[#databases], host)
  if image == nil then
    return nil, image_trouble
  end
  local made, mkdir_trouble = Fs.mkdirs(root .. "/o/bin")
  if not made then
    return nil, mkdir_trouble
  end
  local names: {string} = {}
  for _, main in ipairs(mains) do
    local name = name_of(main)
    if name == nil then
      return nil, main .. " is not a cmd/<name>/main.tl"
    end
    local database, database_trouble = embed.database(project, main)
    if database == nil then
      return nil, name .. ": " .. database_trouble
    end
    local out = root .. "/o/bin/" .. name
    local attached, attach_trouble = attach.write(out, host, image, database)
    if not attached then
      return nil, out .. ": " .. attach_trouble
    end
    names[#names + 1] = name
  end
  return names
end

--- `cosmic build`: the tree in the working directory, and its
--- executables under `o/bin/`. Ends in a verdict line that names what
--- was written, or says why nothing was.
function embed.run(): integer
  local started = Time.monotonic_ns() or 0
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    complain(root_trouble)
    report("build: FAIL")
    return 1
  end
  local names, trouble = embed.tree(root)
  if names == nil then
    complain(trouble)
    report("build: FAIL")
    return 1
  end
  local outputs: {string} = {}
  for _, name in ipairs(names) do
    outputs[#outputs + 1] = "o/bin/" .. name
  end
  local wrote = #outputs > 0 and table.concat(outputs, ", ") or
    "no executable: no cmd/<name>/main.tl in the tree"
  report("build: PASS (" .. wrote .. ", " .. elapsed_ms(started) .. " ms)")
  return 0
end

return embed
