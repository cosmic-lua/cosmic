--- Building a project into portable executables: one file each, the retained
--- multi-core prefix with a database behind it that holds the project's modules
--- but not its tests or examples, the standard library, the error catalog, the
--- bill of materials, and the name of the main module, so it runs on its own
--- with no `cosmic` beside it.
---
--- A binary is a directory under `cmd/`: `cmd/<name>/main.tl` compiles
--- as `kind = "main"`, and `cosmic build` writes `bin/<name>` in its build directory for
--- each one the tree holds, after building the tree as `cosmic test`
--- does; a tree with no `cmd/` builds and writes nothing. The project's
--- own projection, `cosmic.db`, carries the project and nothing of
--- cosmic's; what the standard library needs at run time is read out of
--- the running binary's own database, by handle, so no format of the
--- executable is parsed here.
---
--- cosmic's own tree is not embedded this way: `bin/zig build boot`
--- builds the tool.

local build_paths = require("build.paths")
local Cli = require("cosmic.cli")
local Clock = require("cosmic.clock")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local clock = require("build.clock")
local artifact = require("build.artifact")
local type raw_store = require("cosmic.internal.store")
local GrammarMode = require("build.grammar_mode")
local importer = require("build.importer")
local exit_status = require("build.exit_status")
local shared_compiles = require("build.shared_compiles")
local narrow = require("build.narrow")
local schema = require("build.schema")
local tree = require("build.tree")
local work = require("build.work")
local writer = require("build.writer")

local logger = require("build.logger")
local log = logger.log
local bind = require("build.bind")
local verb_spec = require("build.verb_spec")

local record embed
  --- The verb's registration: see build/verb_spec.tl.
  mut spec: verb_spec.Spec

  --- What [`embed.tree`] tells of a build beyond the programs it wrote.
  record Report
    --- One line per program the build did not make, saying why, with the first line of each diagnostic that holds it out.
    unbuilt: mut {string}
    --- One line per executable removed because its program was not made, in the build directory or `--out`.
    removed: mut {string}
    --- The messages of the modules the checker refused, "" for a tree that compiled whole.
    mut refusal: string
  end
end

local text = bind.text

--- A row of the `meta` table a program's database carries.
local record MetaRow
  key: string
  value: string
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
    return { integer = statement:integer(index) }
  end
  if kind == "number" then
    return { number = statement:number(index) }
  end
  return text(statement:bytes(index))
end

--- Copies every row `sql` yields from one database into a table of
--- another, column for column, each value bound as the kind it was
--- read as. `columns` names the destination columns in `sql`'s order.
local function copy_rows(from: Sqlite.Handle, into: Sqlite.Handle,
                         table_name: string, columns: {string},
                         sql: string): boolean, string
  local statement, trouble = from:prepare(sql)
  if statement == nil then
    return false, table_name .. ": " .. trouble
  end
  local slots: mut {string} = {}
  for index = 1, #columns do
    slots[index] = "?" .. tostring(index)
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
    local row: mut {Sqlite.Value} = {}
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
  "bytecode", "tests", "source" }
local module_column_list = table.concat(module_columns, ", ")
local catalog_columns = { "kind", "module", "symbol", "message", "text",
  "file", "line" }

--- The `<name>` of `cmd/<name>/main.tl`, from its import path.
local function name_of(main: string): string?
  return main:match("^cmd%.([^%.]+)%.main$")
end

-- TODO: build the missing cores on demand (`bin/zig build cores`, once) in
-- place of refusing; it waits on the tool knowing the checkout it was
-- booted from, which its database does not record, so that a project's
-- `cosmic build` can find the tree to run zig in.

--- The prefix a portable program is made of: the running tool's own, which
--- carries a core for every target it runs on. A tool booted for the host's
--- alone (`bin/zig build boot` without `-Dboot-cores=all`) carries a
--- placeholder for each other target's ([`artifact.placeholder`]), and has no
--- such prefix to give: a program made of it would run on this host only, and
--- say nothing of it, so it refuses and names the boot that renews it.
--- `--host` needs no other core.
--- @param prefix what [`artifact.trusted_prefix`] answered, or nil
--- @param trouble and why not, where it answered none
function embed.portable_prefix(prefix: string?, trouble: string): string?, string
  if prefix == nil then return nil, trouble end
  if artifact.host_only(prefix) then
    return nil, "this tool carries the host's core alone, so a portable program made " ..
      "of it would run nowhere else; run bin/zig build boot -Dboot-cores=all in " ..
      "cosmic's checkout to carry every core, or build with --host for this host"
  end
  return prefix, ""
end

--- The database one executable carries, as bytes: the project's own
--- projection at `project` joined with what the running binary holds
--- that a program needs at run time -- every `cosmic.*` module, every
--- declaration, the error catalog, the time zones -- the bill of
--- materials it ships under, and `main` naming the module the
--- executable runs. Written beside the projection, then vacuumed, so
--- the bytes are a function of the two databases and nothing else.
--- `roots`, when given, is recorded as the roots a request that names
--- none trusts ("minimal" or "mozilla", [`Http.default_roots`]); every
--- root the binary carries goes along either way.
function embed.database(project: string, main: string, roots?: string): string?, string
  local databases = Store.databases()
  local binary = databases[#databases]
  if binary == nil then
    return nil, "the running artifact has no database"
  end
  local runtime_basis = Store.meta("runtime_basis")
  if runtime_basis == nil or runtime_basis == "" then
    return nil, "the running binary names no runtime basis"
  end
  local basis: string = runtime_basis
  local building = project .. ".embed"
  local _, _ = Fs.remove(building)
  local _, _ = Fs.remove(building .. ".vacuumed")
  local out, open_trouble = Sqlite.open(building, { writable = true })
  if out == nil then
    return nil, building .. ": " .. open_trouble
  end
  local statements: mut {string} = {}
  for _, statement in ipairs(schema.settings("")) do
    statements[#statements + 1] = statement
  end
  for _, statement in ipairs(schema.create("")) do
    statements[#statements + 1] = statement
  end
  for _, statement in ipairs(statements) do
    local ok, failure = out:exec(statement)
    if not ok then
      local _, _ = out:close()
      return nil, failure
    end
  end

  local made, trouble = Sqlite.transact(out, function(): boolean, string
    -- The standard library first, so a project's row never stands in
    -- for a `cosmic.*` module; then the project's own modules.
    local copied, copy_trouble = copy_rows(binary, out, "modules",
      module_columns,
      "SELECT " .. module_column_list .. " FROM modules WHERE kind = " ..
        "'module' AND path LIKE 'cosmic.%' ORDER BY path")
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
    -- A binary written before `decl_imports` existed has no such table,
    -- and one written by a tool that lacked the rows has an empty one:
    -- the project's own rows fill in below for any module it holds
    -- byte for byte.
    local has_edges, edges_trouble = Sqlite.text_rows(binary,
      "SELECT 1 FROM sqlite_master WHERE name = 'decl_imports'")
    if has_edges == nil then
      return false, edges_trouble
    end
    if #has_edges > 0 then
      copied, copy_trouble = copy_rows(binary, out, "decl_imports",
        { "path", "requires" },
        "SELECT path, requires FROM decl_imports WHERE path LIKE 'cosmic.%' " ..
          "ORDER BY path, requires")
      if not copied then
        return false, copy_trouble
      end
    end
    copied, copy_trouble = copy_rows(binary, out, "decls",
      { "path", "source" }, "SELECT path, source FROM decls ORDER BY path")
    if not copied then
      return false, copy_trouble
    end
    -- The time zones [`cosmic.time`] falls back on where the host has
    -- none of its own.
    copied, copy_trouble = copy_rows(binary, out, "zoneinfo",
      { "name", "data" }, "SELECT name, data FROM zoneinfo ORDER BY name")
    if not copied then
      return false, copy_trouble
    end
    -- The browser-side files [`cosmic.web`] serves under /_web/.
    -- TODO: carry them only for a project whose closure requires
    -- cosmic.web, as Store.seal does for the zones, once embed.database
    -- computes that closure.
    -- A binary written before `web_assets` existed has no such table:
    -- the program then carries none, and cosmic.web.htmx says to rebuild.
    local has_web, web_trouble = Sqlite.text_rows(binary,
      "SELECT 1 FROM sqlite_master WHERE name = 'web_assets'")
    if has_web == nil then
      return false, web_trouble
    end
    if #has_web > 0 then
      copied, copy_trouble = copy_rows(binary, out, "web_assets",
        { "name", "data", "sha256", "sha384", "version" },
        "SELECT name, data, sha256, sha384, version FROM web_assets ORDER BY name")
      if not copied then
        return false, copy_trouble
      end
    end
    -- The guidance a program's own errors can match: the standard
    -- library's own extracted rows. It never runs the build, so a row
    -- about the build could only ever match by accident. A row's text
    -- is NULL when it has none of its own: the docs are not carried, and
    -- [`Errors.guidance`] names the symbol for `cosmic docs` instead.
    copied, copy_trouble = copy_rows(binary, out, "catalog", catalog_columns,
      "SELECT kind, module, symbol, message, text, file, " ..
        "line FROM catalog WHERE module LIKE 'cosmic.%' ORDER BY id")
    if not copied then
      return false, copy_trouble
    end
    -- The bill of materials ([`build.bom`]): the program runs on the same
    -- cores, so it carries the same components and the notices their
    -- licenses ask to travel with a copy.
    -- TODO: name the project itself in it, as `cosmic bom` names cosmic,
    -- once a project declares a name and version a build can read.
    -- TODO: let `cosmic bom <executable>` print these rows: nothing a
    -- program carries prints them, so its notices travel only inside the
    -- database bytes. [`artifact.split`] finds a file's database from its
    -- trailer, as `cosmic refresh --binary` does: open that.
    copied, copy_trouble = copy_rows(binary, out, "components",
      { "name", "kind", "version", "license", "url", "sha256", "sha3_256", "patches" },
      "SELECT name, kind, version, license, url, sha256, sha3_256, patches " ..
        "FROM components ORDER BY name")
    if not copied then
      return false, copy_trouble
    end
    copied, copy_trouble = copy_rows(binary, out, "notices",
      { "component", "ordinal", "file", "text" },
      "SELECT component, ordinal, file, text FROM notices " ..
        "ORDER BY component, ordinal")
    if not copied then
      return false, copy_trouble
    end
    -- The CA roots ([`build.roots`]): core/http.c reads them out of the
    -- program's own database, so without them it trusts no server.
    copied, copy_trouble = copy_rows(binary, out, "ca_roots",
      { "sha256", "label", "der", "distrust_after" },
      "SELECT sha256, label, der, distrust_after FROM ca_roots ORDER BY sha256")
    if not copied then
      return false, copy_trouble
    end
    -- And the certificates OneCRL revokes ([`build.onecrl`]), which it
    -- refuses in a chain.
    copied, copy_trouble = copy_rows(binary, out, "ca_revoked", { "kind", "name", "value" },
      "SELECT kind, name, value FROM ca_revoked ORDER BY rowid")
    if not copied then
      return false, copy_trouble
    end
    local attached, attach_trouble = Sqlite.run(out,
      "ATTACH DATABASE ?1 AS project", { text(project) })
    if not attached then
      return false, attach_trouble
    end
    -- The project's own modules, but not its tests or examples: a
    -- program never runs those, and they are the project's to keep.
    -- A test or example file a carried module requires is carried
    -- anyway, since the program cannot load without it; its kind is
    -- only its file name. An import edge and a catalog row go with the
    -- module they are about.
    -- An edge exists for a `require` of a literal name, `pcall(require,
    -- "<name>")` included (build.syntax_node's requires), and the parser
    -- refuses a computed name, so every file a program loads is carried.
    local project_rows: mut {string} = {
      "WITH RECURSIVE carried(path) AS (" ..
        "SELECT path FROM project.modules " ..
        "WHERE kind NOT IN ('test', 'example') " ..
        "UNION SELECT i.requires FROM project.imports i " ..
        "JOIN carried c ON i.path = c.path) " ..
        "INSERT OR IGNORE INTO modules (" .. module_column_list .. ") " ..
        "SELECT " .. module_column_list .. " FROM project.modules " ..
        "WHERE path IN (SELECT path FROM carried) ORDER BY path",
      "INSERT OR IGNORE INTO imports SELECT * FROM project.imports " ..
        "WHERE path IN (SELECT path FROM main.modules) " ..
        "ORDER BY path, requires",
      "INSERT OR IGNORE INTO decl_imports SELECT d.path, d.requires " ..
        "FROM project.decl_imports d WHERE " ..
        "CASE WHEN EXISTS (SELECT 1 FROM main.decls x WHERE x.path = d.path) " ..
        "THEN EXISTS (SELECT 1 FROM main.decls x JOIN project.decls y " ..
        "ON y.path = x.path AND y.source = x.source WHERE x.path = d.path) " ..
        "ELSE EXISTS (SELECT 1 FROM main.modules m JOIN project.modules p " ..
        "ON p.path = m.path AND p.source_hash = m.source_hash " ..
        "WHERE m.path = d.path) END " ..
        "ORDER BY d.path, d.requires",
      "INSERT INTO catalog (kind, module, symbol, message, text, file, " ..
        "line) SELECT kind, module, symbol, message, " ..
        "text, file, line " ..
        "FROM project.catalog " ..
        "WHERE module IN (SELECT path FROM main.modules) ORDER BY id",
      -- The files under the project's `static/`, which [`cosmic.web.assets`]
      -- reads from the program's own database. Tests and examples are
      -- dropped; assets are not.
      "INSERT INTO payload (path, data, sha256, type, gzip, zstd) " ..
        "SELECT path, data, sha256, type, gzip, zstd FROM project.payload ORDER BY path",
    }
    for _, rebuild in ipairs(schema.rebuild("")) do project_rows[#project_rows + 1] = rebuild end
    for _, statement in ipairs(project_rows) do
      local ok, failure = out:exec(statement)
      if not ok then
        return false, failure
      end
    end
    local meta: {MetaRow} = {
      { key = "compiler", value = Store.meta("compiler") or "" },
      { key = "runtime_basis", value = basis },
      { key = "main", value = main },
    }
    for _, pair in ipairs(meta) do
      local ok, failure = Sqlite.run(out,
        "INSERT INTO meta (key, value) VALUES (?1, ?2)",
        { text(pair.key), text(pair.value) })
      if not ok then
        return false, failure
      end
    end
    if roots ~= nil then
      local ok, failure = Sqlite.run(out,
        "INSERT INTO meta (key, value) VALUES ('ca_roots_default', ?1)", { text(roots) })
      if not ok then
        return false, failure
      end
    end
    return true, ""
  end)
  if not made then
    local _, _ = out:close()
    return nil, trouble
  end
  local _, _ = out:exec("DETACH DATABASE project")
  local vacuumed, vacuum_trouble = Sqlite.run(out, "VACUUM INTO ?1",
    { text(building .. ".vacuumed") })
  local _, _ = out:close()
  if not vacuumed then
    return nil, vacuum_trouble
  end
  local bytes, read_trouble = Fs.read(building .. ".vacuumed")
  local _, _ = Fs.remove(building)
  local _, _ = Fs.remove(building .. ".vacuumed")
  if bytes == nil then
    return nil, read_trouble
  end
  return bytes, ""
end

--- A program of the staged tree: the import path of its `cmd/<name>/main.tl` and the file.
local record Program
  path: string
  file: string
end

--- The programs of the staged tree that `paths` choose: the import path of each `cmd/<name>/main.tl` and its file.
local function staged_programs(handle: work.Handle, paths: {string}): {Program}?, string
  local rows, trouble = Sqlite.text_rows(handle.db,
    "SELECT path, file FROM inputs WHERE kind = 'main' ORDER BY path")
  if rows == nil then return nil, trouble end
  local programs: mut {Program} = {}
  for _, row in ipairs(rows) do
    if narrow.holds(paths, row:text(2)) then
      programs[#programs + 1] = { path = row:text(1), file = row:text(2) }
    end
  end
  return programs, ""
end

--- Removes the executable of the program `name` from `bin` and from `out`, where there is one, and says so in `report`:
--- a program that was not made must not leave the one an earlier build made, which would run old code as if it were
--- this tree's.
local function withdraw(name: string, bin: string, out: string?, why: string, report?: embed.Report)
  local places: mut {string} = { bin .. "/" .. name }
  if out ~= nil then places[#places + 1] = out .. "/" .. name end
  for _, place in ipairs(places) do
    local stat, _ = Fs.stat(place)
    if stat ~= nil and stat.kind ~= "dir" then
      local gone, trouble = Fs.remove(place)
      if report ~= nil then
        report.removed[#report.removed + 1] = if gone
          then "removed " .. place .. ": " .. why .. ", and an earlier build's executable must not stand for it"
          else "could not remove " .. place .. " (" .. why .. "): " .. trouble end
      end
    end
  end
end

--- Builds the tree at `root` and writes `bin/<name>` in its build
--- directory ([`build.paths`]) for every `cmd/<name>/main.tl` it holds: a
--- portable program, or with `host` a host program -- this binary's own
--- core with the program's database appended, which the kernel runs
--- directly, with no launcher, only where this core runs. Returns the
--- names written, none for a tree with no `cmd/`.
---
--- A module the checker refuses, a test among them, does not stop the
--- programs whose own requires compile: they are written, and `report`
--- carries the refusals. A caller that gives no `report` is answered nil and
--- the refusals once the programs that could be are written, so a refusal is
--- never passed over. A program that is not written, refused or failed, has
--- the executable of an earlier build removed from `bin/` and from `out`.
--- @param under paths relative to `root` that narrow it to the programs
---   whose `main.tl` is under one; each must hold one. None, or nil, is
---   every program
--- @param grammar the checker that compiles the project: the one
---   `COSMIC_GRAMMAR` names where not given ([`build.grammar_mode`]). The
---   new checker ([`build.pipeline`]) holds a project to no ceiling, and a
---   project written in a form only the fork reads is refused with the new
---   checker's words and fix.
--- @param roots the roots its executables trust by default, as
---   `cosmic build --roots` names them ([`embed.database`]); nil records
---   none, which is "minimal"
--- @param carried the `built_from` the tool carries, as [`tree.standing`] takes it
--- @param outcome set to `refused` where a module of the tree does not compile
--- @param out a directory that exists, to which each executable is also written under its name
--- @param report filled with the refusals, the programs not made and the executables removed
function embed.tree(root: string, host?: boolean, under?: {string}, grammar?: GrammarMode.Mode,
                    roots?: string, carried?: string, outcome?: importer.Outcome, out?: string,
                    report?: embed.Report): {string}?, string
  local mode = grammar
  if mode == nil then
    local chosen, chosen_trouble = GrammarMode.mode()
    if chosen == nil then return nil, chosen_trouble end
    mode = chosen
  end
  local standing, standing_trouble = tree.standing(root, carried)
  if standing == nil then return nil, standing_trouble end
  if standing.own then
    return nil, "this is cosmic's own tree, which bin/zig build boot builds"
  end
  local started = Clock.monotonic_ns()
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, standing)
  if staged == nil then
    local _, _ = work.close(handle)
    return nil, stage_trouble
  end
  local project = build_paths.resolve(root).projection
  local bin = build_paths.resolve(root).bin
  local paths = under or {}
  local scope, scope_trouble = staged_programs(handle, paths)
  if scope == nil then
    local _, _ = work.close(handle)
    return nil, scope_trouble
  end
  --- Withdraws the executable of each program in `scope` but those `except` names.
  local function withdraw_all(why: string, except?: {string:boolean})
    for _, program in ipairs(scope) do
      local name = name_of(program.path)
      if name ~= nil and (except == nil or except[name] ~= true) then
        withdraw(name, bin, out, why, report)
      end
    end
  end
  -- The new checker reads the project in this process; its compile is keyed by the mode.
  local tool = GrammarMode.tool(Store.meta("compiler") or "", mode)
  local result, compile_trouble = importer.compile(handle, tool, false, shared_compiles.for_build(), nil, nil, outcome)
  if result == nil then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local _, _ = work.close(handle)
    withdraw_all("the tree did not build", nil)
    return nil, compile_trouble
  end
  -- A compile with the new checker goes on past a module it refuses, to name them all. A program whose requires all
  -- compiled is made of the modules that did, read from a projection file of its own, so that `cosmic db` and
  -- `docs` go on answering from the last tree that compiled whole.
  local refusal = ""
  local source = project
  if #result.refused > 0 then
    refusal = table.concat(result.refused, "\n")
    if outcome ~= nil then outcome.refused = true end
    source = project .. ".partial"
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, result.compiled, result.cached, "FAIL")
    local written, write_trouble = writer.write_result(handle, source, result)
    local _, _ = work.close(handle)
    if not written then
      withdraw_all("the tree did not build", nil)
      return nil, refusal .. "\n" .. write_trouble
    end
  else
    local written, write_trouble = writer.write_recorded(handle, project, result, started, staged)
    local _, _ = work.close(handle)
    if not written then
      withdraw_all("the tree did not build", nil)
      return nil, write_trouble
    end
  end
  --- Removes the partial projection, if this build made one.
  local function tidy()
    if source ~= project then local _, _ = Fs.remove(source) end
  end

  --- What the build answers once it made what it could.
  local function finished(names: {string}): {string}?, string
    if report ~= nil then
      report.refusal = refusal
    elseif refusal ~= "" then
      return nil, refusal
    end
    return names, ""
  end

  local compiled: mut {string:boolean} = {}
  for _, m in ipairs(result.modules) do
    compiled[m.path] = true
  end
  local mains: mut {string} = {}
  local made: mut {string:boolean} = {}
  for _, program in ipairs(scope) do
    local name = name_of(program.path)
    if compiled[program.path] == true then
      mains[#mains + 1] = program.path
      if name ~= nil then made[name] = true end
    elseif name ~= nil and report ~= nil then
      -- The first line of each diagnostic that holds the program out: its own, or those of the modules it rests on.
      local lines: mut {string} = {}
      for _, position in ipairs((result.refusal_roots or {})[program.file] or {}) do
        local message = result.refused[position]
        if message ~= nil then lines[#lines + 1] = message:match("^[^\n]*") or message end
      end
      local line = name .. " (" .. program.file .. ") was not built" ..
        (if #lines > 0 then ": " .. table.concat(lines, "; ") else "" end)
      report.unbuilt[#report.unbuilt + 1] = line
    end
  end
  table.sort(mains)
  for _, path in ipairs(paths) do
    local held = false
    for _, program in ipairs(scope) do
      if narrow.holds({ path }, program.file) then held = true end
    end
    if not held then
      tidy()
      return nil, "no cmd/<name>/main.tl under " .. path
    end
  end
  withdraw_all("its program was not built", made)
  if #mains == 0 then
    tidy()
    return finished({})
  end

  local prefix, core: string?, raw_store.Core?
  local source_trouble: string
  if host == true then
    core, source_trouble = artifact.trusted_core()
  else
    prefix, source_trouble = embed.portable_prefix(artifact.trusted_prefix())
  end
  if prefix == nil and core == nil then
    tidy()
    withdraw_all("the build could not make a program", nil)
    return nil, source_trouble
  end
  local made_dir, mkdir_trouble = Fs.mkdirs(bin)
  if not made_dir then
    tidy()
    withdraw_all("the build could not make a program", nil)
    return nil, mkdir_trouble
  end
  local names: mut {string} = {}
  --- Gives up on the program `name` and those after it, and answers `trouble`.
  local function failed(name: string, trouble: string): {string}?, string
    local kept: mut {string:boolean} = {}
    for _, built in ipairs(names) do kept[built] = true end
    tidy()
    withdraw_all("the build of " .. name .. " failed", kept)
    return nil, trouble
  end
  for _, main in ipairs(mains) do
    local name = name_of(main)
    if name == nil then
      return failed(main, main .. " is not a cmd/<name>/main.tl")
    end
    local database, database_trouble = embed.database(source, main, roots)
    if database == nil then
      return failed(name, name .. ": " .. database_trouble)
    end
    local target = bin .. "/" .. name
    local program, program_trouble: string?, string
    if core ~= nil then
      program, program_trouble = artifact.host_program(core, database)
    elseif prefix ~= nil then
      program, program_trouble = artifact.program(prefix, database)
    else
      return failed(name, source_trouble)
    end
    if program == nil then
      return failed(name, target .. ": " .. program_trouble)
    end
    local published, publish_trouble = Fs.write(target, program, 0x1ed)
    if not published then
      return failed(name, publish_trouble)
    end
    if out ~= nil then
      local copied, copy_trouble = Fs.write(out .. "/" .. name, program, 0x1ed)
      if not copied then
        return failed(name, copy_trouble)
      end
    end
    names[#names + 1] = name
  end
  tidy()
  return finished(names)
end

--- The directory `--out` names, made where it is not there, as an absolute path; or nil and why it will not do: a path
--- that is a file, or one that cannot be made.
local function out_directory(given: string): string?, string
  local there, there_trouble = Fs.exists(given)
  if there == nil then return nil, "--out " .. given .. ": " .. there_trouble end
  if there then
    local directory, _ = Fs.is_dir(given)
    if directory ~= true then
      return nil, "--out " .. given .. " is not a directory: it takes the directory to write the executables to"
    end
  else
    local made, made_trouble = Fs.mkdirs(given)
    if not made then
      return nil, "--out " .. given .. " cannot be created: " .. made_trouble
    end
  end
  local path, absolute_trouble = Fs.absolute(given)
  if path == nil then return nil, "--out " .. given .. ": " .. absolute_trouble end
  return path, ""
end

--- `cosmic build [--host] [--roots minimal|mozilla] [--out dir] [path...]`: the tree in the working directory,
--- and its executables in its build directory's `bin/` -- only those whose `main.tl` is
--- under one of the paths, when there are any -- and in `dir` when it is given. Prints each executable it
--- wrote on stdout, a path per line, for a caller to run; its summary on
--- stderr names them again, or says why nothing was written. A file the checker refuses, a test
--- among them, does not keep the programs that do not need it from being written: they are, the
--- refusals and the programs not made are named, the earlier executable of each such program is removed
--- (it would run old code), and the exit status is [`exit_status.uncompiled`].
local function run(argv: {string}): integer
  local started = Clock.monotonic_ns()
  local parsed, parse_trouble = Flags.parse(argv, 2, assert(Cli.verbs.build.spec))
  if parsed == nil then
    log:complain("build: " .. parse_trouble)
    return 2
  end
  local host = parsed.set["--host"] == true
  local roots = parsed.values["--roots"]
  if roots ~= nil and roots ~= "minimal" and roots ~= "mozilla" then
    log:complain("build: --roots takes minimal or mozilla, not " .. roots:sub(1, 40))
    return 2
  end
  local out: string? = nil
  local given = parsed.values["--out"]
  if given ~= nil then
    local directory, directory_trouble = out_directory(given)
    if directory == nil then
      log:complain("build: " .. directory_trouble)
      return 2
    end
    out = directory
  end
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain(root_trouble)
    return 1
  end
  local outcome: importer.Outcome = { refused = false }
  local report: embed.Report = { unbuilt = {}, removed = {}, refusal = "" }
  local names, trouble = embed.tree(root, host, narrow.paths(root, parsed.words), nil, roots, nil, outcome, out,
    report)
  if names == nil then
    log:complain(trouble)
    for _, line in ipairs(report.removed) do log:complain("build: " .. line) end
    return if outcome.refused then exit_status.uncompiled else 1 end
  end
  local refused = report.refusal ~= ""
  if refused then log:complain(report.refusal) end
  for _, line in ipairs(report.unbuilt) do log:complain("build: " .. line) end
  for _, line in ipairs(report.removed) do log:complain("build: " .. line) end
  local outputs: mut {string} = {}
  local bin = build_paths.resolve(root).bin
  for _, name in ipairs(names) do
    log:say(bin .. "/" .. name)
    outputs[#outputs + 1] = bin .. "/" .. name .. (if host then " (host)" else "" end) ..
      (if out ~= nil then " and " .. out .. "/" .. name else "" end)
  end
  local wrote = #outputs > 0 and table.concat(outputs, ", ") or
    "no executable: no cmd/<name>/main.tl in the tree"
  if refused then
    wrote = wrote .. ", but a file the checker refused" ..
      (if #report.unbuilt > 0 then " held out " .. tostring(#report.unbuilt) .. " program(s)" else "" end)
  end
  local _, _ = logger.summary("build", wrote .. ", " .. clock.took(started))
  return if refused then exit_status.uncompiled else 0 end
end

--- The `build` verb as [`build/verb_list.tl`] lists it.
embed.spec = {
  name = "build",
  guide = "none: builds a program for shipping, which doc/guides/portable-runtime.md covers; the quickstart does not",
  tests = { "build.embed_test", "build.embed_tool_test", "build.embed_portable_tool_test" },
  run = function(argv: {string}): integer return run(argv) end,
  bare = false,
  -- A build that wrote what it could and refused the rest ends in its summary, which names how many programs it held out.
  summarizes_failure = true,
  takes = "the files or directories to act on",
}

return embed
