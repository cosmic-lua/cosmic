--- The semantic compile: module plans, dependency keys, acceptance,
--- generated Lua, bytecode and typed references. The importer owns cache
--- lookup, persistence and diagnostic presentation around these operations.

local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local analyzer = require("build.analyzer")
local ast = require("build.ast")
local contracts = require("build.contracts")
local receivers = require("build.receivers")
local shape_specs = require("build.shape_specs")
local bind = require("build.bind")
local type compiler = require("build.compiler")
local type module = require("build.module")
local type Module = module.Plan

local record compilation
  Module: Module
  --- What compiling one module makes.
  record Generated
    lua: string
    bytecode: string
    --- The record-field uses the checker's types resolved.
    references: {receivers.Reference}
    --- A contract refusal kept for this unjudged run alone.
    refused: boolean
  end
  --- A module's key and the graph digest less its own file and compiler.
  record Keys
    key: string
    graph: string
  end
end

local type Keys = compilation.Keys
local text = bind.text

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

--- What `test_inputs` holds, by source hash: each [`Test.policy`]
--- declaration, as the [`Test.Needs`] it stands for.
local function test_inputs_by_hash(db: Sqlite.Handle): {string:analyzer.Declared} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, field, value FROM test_inputs ORDER BY source_hash, ordinal")
  if rows == nil then
    return nil, trouble
  end
  local declared: {string:analyzer.Declared} = {}
  for _, row in ipairs(rows) do
    local hash, field, value = row[1], row[2], row[3]
    local one = declared[hash]
    if one == nil then
      one = { line = 0, reads = {}, host = {}, env = {}, network = {},
        tool = false, lua = false, nests = false, store = false,
        system = false, caches = {}, requires = {} }
      declared[hash] = one
    end
    if field == "line" then
      one.line = math.tointeger(tonumber(value)) or 0
    elseif field == "reads" then
      one.reads[#one.reads + 1] = value
    elseif field == "host" then
      one.host[#one.host + 1] = value
    elseif field == "env" then
      one.env[#one.env + 1] = value
    elseif field == "network" then
      one.network[#one.network + 1] = value
    elseif field == "tool" then
      one.tool = true
    elseif field == "lua" then
      one.lua = true
    elseif field == "nests" then
      one.nests = true
    elseif field == "noexec" then
      one.noexec = true
    elseif field == "store" then
      one.store = true
    elseif field == "system" then
      one.system = true
    elseif field == "caches" then
      one.caches[#one.caches + 1] = value
    elseif field == "requires" then
      one.requires[#one.requires + 1] = value
    end
  end
  return declared, ""
end

--- Every name a table keyed by source hash lists, in order, by hash.
local function names_by_hash(db: Sqlite.Handle,
                             table_name: string): {string:{string}} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT source_hash, name FROM " .. table_name ..
      " ORDER BY source_hash, ordinal")
  if rows == nil then
    return nil, trouble
  end
  local out: {string:{string}} = {}
  for _, row in ipairs(rows) do
    local list = out[row[1]]
    if list == nil then
      list = {}
      out[row[1]] = list
    end
    list[#list + 1] = row[2]
  end
  return out
end

local record Dependency
  kind: string
  source_hash: string
  requires: {string}
end

--- The names the standard-library module `name` requires, from the
--- `decl_imports` rows of the binary's own database, where
--- [`Store.source`] reads it. Nil when that database has no such rows
--- to read, as one written before the table existed.
local function embedded_edges(name: string): {string} | nil
  local databases = Store.databases()
  local rows, _ = Sqlite.text_rows(databases[#databases],
    "SELECT requires FROM decl_imports WHERE path = ?1 ORDER BY requires",
    { text(name) })
  if rows == nil or #rows == 0 then
    return nil
  end
  local out: {string} = {}
  for _, row in ipairs(rows) do
    if row[1] ~= "" then
      out[#out + 1] = row[1]
    end
  end
  return out
end

--- The identity of every source the checker can load from this tree.
--- A declaration wins over a source of the same name, just as
--- [`build.teal`]'s module search does. Embedded standard-library sources
--- are content-addressed when a project imports them. Each module's
--- [`Keys`], by path.
function compilation.dependency_keys(db: Sqlite.Handle, modules: {Module},
                                     built: compiler,
                                     tool: string): {string:Keys} | nil, string
  local requires, requires_trouble = names_by_hash(db, "requires")
  if requires == nil then
    return nil, requires_trouble
  end
  local dependencies: {string:Dependency} = {}
  local rows, rows_trouble = Sqlite.text_rows(db,
    "SELECT path, kind, source_hash FROM inputs WHERE kind <> 'vendor' " ..
      "ORDER BY path, kind = 'decl' DESC")
  if rows == nil then
    return nil, rows_trouble
  end
  for _, row in ipairs(rows) do
    if dependencies[row[1]] == nil then
      dependencies[row[1]] = {
        kind = row[2], source_hash = row[3],
        requires = requires[row[3]] or {},
      }
    end
  end
  -- A module's own compile is keyed from its implementation. Imports of
  -- that same path still resolve through `dependencies`, and therefore
  -- through its declaration when it has one.
  for _, m in ipairs(modules) do
    dependencies["\0" .. m.path] = {
      kind = m.kind, source_hash = m.source_hash, requires = m.requires,
    }
  end

  local resolve = function(slot: string, name: string): Dependency | nil, string
    local dependency = dependencies[slot]
    if dependency == nil then
      if name:sub(1, 7) ~= "cosmic." then
        return nil, ""
      end
      local source, source_trouble = Store.source(name)
      if source == nil then
        return nil, source_trouble
      end
      -- A database with no `decl_imports` rows to read -- one written
      -- before the table existed, or a sealed one, which carries no such
      -- table -- has its source parsed for them.
      -- TODO: drop this parse once a sealed database carries
      -- `decl_imports` (build/test.tl's `sealed_schema` and `sealed_fill`,
      -- and Store.seal): a test worker that builds a project on one
      -- reaches it.
      local embedded_requires = embedded_edges(name)
      if embedded_requires == nil then
        local parsed, parse_trouble = ast.parse(built, source, name)
        if parsed == nil then
          return nil, parse_trouble
        end
        local parsed_requires, parsed_trouble = ast.all_requires(built, parsed)
        if parsed_requires == nil then
          return nil, parsed_trouble
        end
        embedded_requires = parsed_requires
      end
      dependency = {
        kind = "embedded", source_hash = Hash.hex_sha256(source),
        requires = embedded_requires,
      }
      dependencies[slot] = dependency
    end
    return dependency, ""
  end

  -- Hash the reachable graph as a sorted set rather than recursively
  -- hashing one node into another. Declarations can legally refer to each
  -- other, and a set closes over those cycles without making traversal
  -- order part of the key. When a declaration shadows an implementation,
  -- both matter: the checker reads the declaration, while the generated
  -- `require` loads the implementation at runtime.
  -- A module's own compile is keyed by its file as well as its import
  -- path (`file` below): `x.tl` and `x/init.tl` are both `x`, and
  -- build.contracts names its exemptions by file, so a module moved
  -- from one to the other is compiled again under its new file's rules.
  -- Only the key holds it: the graph key ([`build.positions`]'
  -- `graph_key`) is the import graph's by name and content, and a
  -- dependency's file decides nothing of this compile.
  local identify = function(name: string, file: string): Keys | nil, string
    local seen: {string:boolean} = {}
    local graph: {string} = {}
    local visit: function(string, string): boolean, string
    visit = function(slot: string, display: string): boolean, string
      if seen[slot] then
        return true, ""
      end
      local dependency, resolve_trouble = resolve(slot, display)
      if dependency == nil then
        if resolve_trouble ~= "" then return false, resolve_trouble end
        return true, ""
      end
      seen[slot] = true
      graph[#graph + 1] = slot .. "\n" .. dependency.kind .. "\n" ..
        dependency.source_hash
      for _, required in ipairs(dependency.requires) do
        local child, child_trouble = resolve(required, required)
        if child == nil and child_trouble ~= "" then
          return false, child_trouble
        end
        if child ~= nil then
          graph[#graph + 1] = slot .. "\nrequires\n" .. required
          local ok, trouble = visit(required, required)
          if not ok then
            return false, trouble
          end
          if child.kind == "decl" and dependencies["\0" .. required] ~= nil then
            graph[#graph + 1] = slot .. "\nloads\n" .. required
            ok, trouble = visit("\0" .. required, required)
            if not ok then
              return false, trouble
            end
          end
        end
      end
      return true, ""
    end
    local ok, trouble = visit("\0" .. name, name)
    if not ok then
      return nil, trouble
    end
    table.sort(graph)
    local sources = table.concat(graph, "\n\0\n")
    return { key = Hash.hex_sha256(sources .. "\n\0\nfile\n" .. file .. "\n" .. tool),
      graph = Hash.hex_sha256(sources) }, ""
  end

  local out: {string:Keys} = {}
  for _, m in ipairs(modules) do
    local keys, trouble = identify(m.path, m.file)
    if keys == nil then
      return nil, trouble
    end
    out[m.path] = keys
  end
  return out, ""
end

--- Every module the derived tree holds ([`build.importer.derive`]), with what
--- its parse found.
function compilation.collect(db: Sqlite.Handle): {Module} | nil, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT i.path, i.file, i.kind, i.origin, i.source, i.source_hash, " ..
      "p.has_return FROM inputs i JOIN parsed p ON p.source_hash = i.source_hash " ..
      "WHERE i.kind NOT IN ('decl', 'vendor') ORDER BY i.path")
  if rows == nil then
    return nil, trouble
  end
  local requires, requires_trouble = names_by_hash(db, "requires")
  if requires == nil then
    return nil, requires_trouble
  end
  local tests, tests_trouble = names_by_hash(db, "tests")
  if tests == nil then
    return nil, tests_trouble
  end
  local examples, examples_trouble = names_by_hash(db, "examples")
  if examples == nil then
    return nil, examples_trouble
  end
  local declared, inputs_trouble = test_inputs_by_hash(db)
  if declared == nil then
    return nil, inputs_trouble
  end
  local out: {Module} = {}
  for _, row in ipairs(rows) do
    local path, file, kind, origin = row[1], row[2], row[3], row[4]
    local source, source_hash, has_return = row[5], row[6], row[7]
    local inputs = declared[source_hash]
    if inputs ~= nil and kind ~= "test" and kind ~= "example" then
      -- A declaration holds for the tests of its own module, and a
      -- module that is no test's has none: what a module it requires
      -- reads, the test declares.
      return nil, file .. ":" .. inputs.line .. ": test.policy: only a test or example " ..
        "module declares what its tests read; call it in each test module that " ..
        "requires this one"
    end
    out[#out + 1] = {
      path = path,
      file = file,
      kind = kind,
      source = source,
      source_hash = source_hash,
      requires = requires[source_hash] or {},
      tests = kind == "test" and (tests[source_hash] or {}) or
        kind == "example" and (examples[source_hash] or {}) or
        {},
      inputs = inputs,
      has_top_level_return = has_return == "1",
      generated = origin == "doctest" or origin == "template",
      key = "",
      graph_key = "",
      lua = "",
    }
  end
  return out, ""
end

--- The modules in an order where nothing is compiled before what it
--- imports. A cycle is reported rather than looped on.
function compilation.ordered(modules: {Module}): {Module} | nil, string
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

--- Appends a generated `return` to compiled Lua for a test module, so a
--- `local function test_*` -- otherwise unreachable from outside the
--- file it is declared in -- comes back on the table `require` gives
--- the runner. The Teal source the test's author wrote is never
--- touched; only the compiled Lua this module already owns is.
local function with_test_tail(code: string, tests: {string}): string
  if #tests == 0 then
    return code
  end
  local fields: {string} = {}
  for _, name in ipairs(tests) do
    fields[#fields + 1] = name .. " = " .. name
  end
  return code .. "\nreturn { " .. table.concat(fields, ", ") .. " }\n"
end

--- A `local function test_*` at a test module's top level is only ever
--- called by the runner, from outside the file, so the checker's
--- "unused function" warning about it is a false positive: it is
--- narrow enough to name the exact function discovery already found,
--- rather than turning the warning off for the whole file.
local function discount_test_warnings(result: compiler.Result,
                                      tests: {string}): compiler.Result
  local names: {string:boolean} = {}
  for _, name in ipairs(tests) do
    names[name] = true
  end
  local kept: {compiler.Error} = {}
  for _, w in ipairs(result.warnings) do
    local unused = w.msg:match("^unused function ([%w_]+):")
    if unused == nil or not names[unused] then
      kept[#kept + 1] = w
    end
  end
  result.warnings = kept
  return result
end

--- Drops the one warning tl's checker always raises over a
--- [`build.doctest`] generated module: an example that declares an
--- `output` block shadows the global `print` with a local of the same
--- name, so a doc's own `print(...)` calls run against the capturing
--- one. The shadow is on purpose: `print` is `<const>` in tl's prelude,
--- so reassigning the global is a type error, and a local is the only
--- way to intercept a bare `print`. It drops less than
--- [`discount_test_warnings`] but applies more widely: to any module
--- `m.generated` marks, not only to functions a scan of `m` found.
local function discount_doctest_shadow_warnings(result: compiler.Result): compiler.Result
  local kept: {compiler.Error} = {}
  for _, w in ipairs(result.warnings) do
    if w.msg ~= "variable shadows previous declaration of 'print'" then
      kept[#kept + 1] = w
    end
  end
  result.warnings = kept
  return result
end

--- Whether `m`'s own source both defines tests of its own and returns
--- its own value at the top level. [`with_test_tail`] appends a generated
--- `return` after the module's compiled Lua, and Lua allows only one
--- `return` as a block's last statement, so the two together are always
--- a parse error. Both facts come from `collect`'s one parse of
--- `m.source`; this reads what `m` carries and parses nothing.
local function collides_with_test_tail(m: Module): boolean
  return #m.tests > 0 and m.has_top_level_return
end

--- Whether an example module found `Example.<name>` functions but has
--- no top-level `return` to hand any of them back: unlike a test
--- module, an example module gets no generated tail, since its own
--- `return Example` is what the runner and `cosmic docs` both need
--- reachable from outside the file -- see [`analyzer.ExampleEntry`].
--- Caught here, at compile time, rather than left to fail the moment
--- the runner indexes a table that `require` handed back as `true`.
local function missing_example_return(m: Module): boolean
  return #m.tests > 0 and not m.has_top_level_return
end

--- Lua's refusal of the chunk compiled from `file`, said at `file`'s
--- line rather than at the chunk's name. tl's generator writes each
--- statement on its source's line, adding lines only to reach one, so
--- the chunk's line is the line of the Teal.
local function at_source_line(trouble: string, file: string): string
  local line, said = trouble:match("^.-:(%d+): (.*)$")
  if line == nil then
    return file .. ": " .. trouble
  end
  return file .. ":" .. line .. ": " .. said
end

--- Bytecode for compiled Lua, checked to be the shape every target
--- shares.
local function bytecode_of(code: string, name: string,
                           file: string): string | nil, string
  local chunk, load_trouble = load(code, "@" .. name, "t")
  if chunk == nil then
    -- TODO: tl's checker passes what Lua 5.5 refuses only here:
    -- `global`, which Lua reserves, as a local, parameter, field or
    -- method name; a `goto` into a local's scope; and `function f()`
    -- over a `<const>` local or a for loop's control variable. The
    -- generator would write a key named `global` as `["global"]`, and
    -- the checker refuse the rest, as patch/tl/34 does an assignment.
    return nil, at_source_line(tostring(load_trouble), file)
  end
  local bytecode = string.dump(chunk, false)
  if not String.starts_with(bytecode, bytecode_header) then
    return nil, file .. ": this host dumps bytecode the three " ..
      "targets do not share"
  end
  return bytecode
end

--- Compiles one module: the checker over its source (with each
--- [`Shape.record_of`] call resolved first, [`build.shape_specs`]), the test
--- tail when it is a test, and the bytecode.
function compilation.generate(m: Module, built: compiler, env: compiler.Env,
                              typed: receivers.State, own_tree: boolean, judged: boolean,
                              render: function(string, string, compiler.Result): string): compilation.Generated | nil, string
  local source, spec_trouble = shape_specs.resolve(built, env, m.file, m.path, m.source)
  if source == nil then
    return nil, spec_trouble
  end
  -- Checked under the module's own file name, not `gen`'s empty
  -- one: a mismatch between a value's type and the type a slot
  -- expects is reported at the value's declaration when the checker
  -- takes both for one file's and the declaration lies after the use,
  -- which on a cold build put a template's error at the field in its
  -- data module, under the template's name.
  typed.checking = m.file
  local result: compiler.Result
  local checked_ok, raised = pcall(function()
    result = built.check_string(source, env, m.file, "tl")
  end)
  -- Put back before a raise goes on, so the run's state names no file
  -- the checker has left.
  typed.checking = ""
  if not checked_ok then
    error(raised, 0)
  end
  local code: string | nil = nil
  if result.ast ~= nil and #result.syntax_errors == 0 then
    local written, write_trouble = built.generate(result.ast, env.defaults.gen_target, nil)
    if written == nil then
      return nil, m.file .. ": " .. write_trouble
    end
    code = written
  end
  if m.kind == "test" and result ~= nil then
    result = discount_test_warnings(result, m.tests)
  end
  if m.generated and result ~= nil then
    result = discount_doctest_shadow_warnings(result)
  end
  -- Presentation cannot decide acceptance: even an empty rendering of
  -- a checker error must refuse the compile, and successful compiles
  -- never call the renderer.
  local rejected = result ~= nil and (#(result.syntax_errors or {}) > 0 or
    #(result.type_errors or {}) > 0 or #(result.warnings or {}) > 0)
  if code == nil or rejected then
    local complaint = result ~= nil and render(m.file, m.source, result) or ""
    return nil, m.file .. ": the compiler refused it\n" .. complaint
  end
  -- The checker has just seen this module whole; a module compiled
  -- after it that requires it is checked against that, rather than
  -- against a second read and check of the same source.
  env.modules[m.path] = result.type
  local checked = result.ast
  if not (checked is ast.Node) then
    return nil, m.file .. ": the compiler answered no syntax tree"
  end
  local refused = false
  if own_tree and contracts.applies(m.kind, m.generated) then
    local problems = contracts.check(m.file, checked, typed, contracts.quiet_records(env),
      contracts.binding_tables(env), nil, result.type)
    if #problems > 0 and judged then
      return nil, table.concat(problems, "\n")
    end
    refused = #problems > 0
  end
  local references = receivers.references(typed, env, checked)
  if m.kind == "test" then
    code = with_test_tail(code, m.tests)
  end
  local bytecode, dump_trouble = bytecode_of(code, m.path, m.file)
  if bytecode == nil then
    return nil, dump_trouble
  end
  return { lua = code, bytecode = bytecode, references = references, refused = refused }, ""
end

--- The record-field uses one compile found, kept under its key beside
--- the compile itself, replacing whatever an earlier compile under the
--- same key left.
function compilation.keep_references(db: Sqlite.Handle, key: string,
                                     references: {receivers.Reference}): boolean, string
  local ok, why = Sqlite.run(db, "DELETE FROM typed_refs WHERE key = ?1", { text(key) })
  if not ok then
    return false, why
  end
  for ordinal, entry in ipairs(references) do
    ok, why = Sqlite.run(db,
      "INSERT INTO typed_refs (key, ordinal, module, member, line) " ..
        "VALUES (?1, ?2, ?3, ?4, ?5)",
      { text(key), { integer = ordinal }, text(entry.module), text(entry.member),
        { integer = entry.line } })
    if not ok then
      return false, why
    end
  end
  return true, ""
end

--- A discovered test or example that cannot hand its functions back.
--- Checked before cache lookup, so a former cached compile cannot hide it.
function compilation.refusal(m: Module): string | nil
  if m.kind == "test" and collides_with_test_tail(m) then
    return m.file .. ": a test file may not both " ..
      "define test_* functions and return its own value; remove the " ..
      "top-level return so the generated tail can hand the runner " ..
      "its tests"
  elseif m.kind == "example" and missing_example_return(m) then
    return m.file .. ": an example file " ..
      "must return the table its Example.* functions are declared on " ..
      "(`return Example`), or the runner has nothing to call"
  end
  return nil
end

--- The vendored compiler's compile key. Its source is already Lua.
function compilation.vendor_key(source: string, tool: string): string
  return Hash.hex_sha256(source .. "\n" .. tool)
end

--- Dumped only when the vendor key missed the local compile cache.
function compilation.vendor_bytecode(source: string): string | nil, string
  local chunk, trouble = load(source, "@vendor.tl", "t")
  if chunk == nil then
    return nil, "the vendored compiler would not load: " .. tostring(trouble)
  end
  return string.dump(chunk, false), ""
end

--- The identity of the code that finds `typed_refs` and checks the
--- error-slot discipline beside the compiler: [`build.receivers`] and
--- [`build.contracts`] as the running binary carries them, or the binary
--- whole when it carries none. A boot carries no database and runs the
--- tree's own code, so it names them by the tree's source, as the tool
--- it writes will: the identity is signed into the projection
--- ([`build.writer`]), which a self-rebuild must write the same as a boot
--- does. Named apart from [`build.importer.analyzer_identity`] because its rows ride on
--- compiles, which only a change to this code must redo.
function compilation.receivers_identity(db: Sqlite.Handle): string | nil, string
  local booting = Store.meta("boot_hash") == nil
  local parts: {string} = {}
  for _, name in ipairs({ "build.receivers", "build.contracts" }) do
    local source: string | nil
    if booting then
      local rows, trouble = Sqlite.text_rows(db,
        "SELECT source FROM inputs WHERE path = ?1", { text(name) })
      if rows == nil then
        return nil, trouble
      end
      if #rows > 0 then
        source = rows[1][1]
      end
    else
      local carried, _ = Store.source(name)
      source = carried
    end
    if source == nil then
      return "binary " .. (Store.meta("boot_hash") or "")
    end
    parts[#parts + 1] = source
  end
  return Hash.hex_sha256(table.concat(parts, "\n\0\n"))
end

return compilation
