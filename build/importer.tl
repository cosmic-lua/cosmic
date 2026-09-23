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

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local ast = require("build.ast")
local doctest = require("build.doctest")
local positions = require("build.positions")
local type compiler = require("build.compiler")

local type Module = positions.Module

local record importer
  Module: Module

  record Result
    modules: {Module}
    boot_hash: string
    main: string | nil
    -- One message per `kind = "test"` module refused compilation
    -- because it both defines its own tests and returns its own value;
    -- every module NOT in this list compiled and is in `modules`.
    refused: {string}
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
--- hidden. `doc` is handled separately by `skip` itself, below: almost
--- all of it is prose with no examples, but `doc/guides/*.md` is the
--- one place doc/meta.md's grammar applies, and `collect` needs to see
--- those files to run `build.doctest` over them.
local not_source: {string:boolean} = {
  ["o"] = true,
  ["vendor"] = true,
  ["patches"] = true,
  ["bin"] = true,
}

--- Whether `file` is a doc this tree extracts runnable examples from --
--- exactly `doc/guides/*.md`, never a markdown file anywhere else in
--- the tree (`doc/design.md`, `doc/roadmap.md`, and `doc/meta.md` are
--- prose with no examples, and stay out of scope on purpose).
local function is_doc_guide(file: string): boolean
  return file:match("^doc/guides/[^/]+%.md$") ~= nil
end

local function skip(entry: string): boolean
  local first = entry:match("^([^/]+)") or entry
  if first == "doc" then
    if entry == "doc" or entry == "doc/guides" then
      return false
    end
    return not is_doc_guide(entry)
  end
  if not_source[first] then
    return true
  end
  local name = entry:match("([^/]+)$") or entry
  return name:sub(1, 1) == "."
end

local function import_path(file: string): string
  local dir = file:match("^(.+)/init%.tl$")
  if dir ~= nil then
    return (dir:gsub("/", "."))
  end
  return (file:gsub("%.tl$", ""):gsub("/", "."))
end

--- A doc guide's import path, the same dotted-name convention
--- `import_path` gives every `.tl` file: `doc/guides/quickstart.md`
--- compiles as `doc.guides.quickstart`.
local function import_path_of_doc(file: string): string
  return (file:gsub("%.md$", ""):gsub("/", "."))
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
    return "main"
  end
  return "module"
end

--- The modules another module names, in the order they appear, read
--- from `file`'s real AST (`build.ast.all_requires`) so a `require`
--- inside a string or a comment is not an import, while a type-only
--- `local type x = require(...)` and a re-assignment inside an `if`
--- both are.
--- @param built the compiler, loaded and ready
--- @param source the file's own source text
--- @param file the file's path, for parse diagnostics
--- @return {string} | nil every required module, in source order
--- @return string error message on a lex or parse failure
local function requires_of(built: compiler, source: string,
                           file: string): {string} | nil, string
  local parsed, parse_trouble = ast.parse(built, source, file)
  if parsed == nil then
    return nil, parse_trouble
  end
  return ast.all_requires(built, parsed)
end

--- Every source the tree holds, read and hashed. The root is the module
--- root, so a file's place in it is its import path.
--- @param self_tree whether `root` is cosmic's own tree, where the
---   `cosmic.` namespace is not reserved against the tree itself
--- @param built the compiler, loaded and ready -- needed to discover a
---   `kind = "test"` module's own tests, which reads its real AST
local function collect(root: string, self_tree: boolean,
                       built: compiler): {Module} | nil, string
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
      local kind = kind_of(file)
      local tests: {string} = {}
      local has_top_level_return = false
      if kind == "test" then
        local found, analyze_trouble = positions.analyze(built, source, file)
        if found == nil then
          return nil, file .. ": " .. analyze_trouble
        end
        tests = found.tests
        has_top_level_return = found.has_top_level_return
      end
      local requires, requires_trouble = requires_of(built, source, file)
      if requires == nil then
        return nil, file .. ": " .. requires_trouble
      end
      out[#out + 1] = {
        path = import_path(file),
        file = file,
        kind = kind,
        source = source,
        source_hash = Hash.hex_sha256(source),
        requires = requires,
        tests = tests,
        has_top_level_return = has_top_level_return,
        generated = false,
        key = "",
        lua = "",
        bytecode = "",
      }
    elseif is_doc_guide(file) then
      local doc_source, doc_failure = Fs.read(root .. "/" .. file)
      if doc_source == nil then
        return nil, doc_failure
      end
      local generated_source, extract_trouble = doctest.extract(doc_source, file)
      if generated_source == nil then
        return nil, file .. ": " .. extract_trouble
      end
      local found, analyze_trouble = positions.analyze(built, generated_source, file)
      if found == nil then
        return nil, file .. ": " .. analyze_trouble
      end
      local requires, requires_trouble = requires_of(built, generated_source, file)
      if requires == nil then
        return nil, file .. ": " .. requires_trouble
      end
      out[#out + 1] = {
        path = import_path_of_doc(file),
        file = file,
        kind = "test",
        source = generated_source,
        source_hash = Hash.hex_sha256(generated_source),
        requires = requires,
        tests = found.tests,
        has_top_level_return = found.has_top_level_return,
        generated = true,
        key = "",
        lua = "",
        bytecode = "",
      }
    end
  end
  local by_import_path: {string:string} = {}
  for _, m in ipairs(out) do
    local earlier = by_import_path[m.path]
    if earlier ~= nil then
      return nil, earlier .. " and " .. m.file .. " both compile to import " ..
        "path '" .. m.path .. "'; rename one"
    end
    by_import_path[m.path] = m.file
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

--- The one warning tl's checker always raises over a `build.doctest`
--- generated module: a generated example that declares an `output`
--- block shadows the global `print` with a local of the same name, on
--- purpose, so a doc's own verbatim `print(...)` calls run against the
--- capturing one instead -- print is declared `<const>` in tl's own
--- prelude, so reassigning the global outright is a hard type error,
--- and a local is the only way left to intercept a call the doc's own
--- source spells as a bare, unqualified `print`. This is narrower than
--- `discount_test_warnings` above in what it drops, but wider in who it
--- applies to: any module `m.generated` marks, not only the specific
--- function names a scan of `m` already found.
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
--- its own value at the top level. `with_test_tail` appends a generated
--- `return` after the module's compiled Lua, and Lua allows only one
--- `return` as a block's last statement, so the two together always
--- produce a parse error the moment both are true. `collect` already
--- read both facts off one parse of `m.source`, so this only reads
--- what `m` itself carries -- never a second parse of the same source.
local function collides_with_test_tail(m: Module): boolean
  return #m.tests > 0 and m.has_top_level_return
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
  local modules, trouble = collect(root, importer.is_own_tree(root), built)
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
  local main: string | nil = nil
  local compiled: {Module} = {}
  local refused: {string} = {}

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

    local colliding = m.kind == "test" and collides_with_test_tail(m)
    if colliding then
      -- Refused on its own, narrowly: every other module still
      -- compiles below, unaffected. Compiling this one anyway would
      -- only surface as `<eof> expected near 'return'` once
      -- `with_test_tail` appends its own generated return after this
      -- file's, a Lua parse error naming neither the file nor the
      -- cause.
      refused[#refused + 1] = m.file .. ": a test file may not both " ..
        "define test_* functions and return its own value; remove the " ..
        "top-level return so the generated tail can hand the runner " ..
        "its tests"
    else
      local code, result = built.gen(m.source, env, nil, "tl")
      if m.kind == "test" and result ~= nil then
        result = discount_test_warnings(result, m.tests)
      end
      if m.generated and result ~= nil then
        result = discount_doctest_shadow_warnings(result)
      end
      local complaint = result ~= nil and complain(m.file, result) or ""
      if code == nil or complaint ~= "" then
        return nil, m.file .. ": the compiler refused it\n" .. complaint
      end
      if m.kind == "test" then
        code = with_test_tail(code, m.tests)
      end
      m.lua = code

      local chunk, load_trouble = load(code, "@" .. m.path, "t")
      if chunk == nil then
        return nil, m.file .. ": " .. tostring(load_trouble)
      end
      m.bytecode = string.dump(chunk, false)
      if m.bytecode:sub(1, #bytecode_header) ~= bytecode_header then
        return nil, m.file .. ": this host dumps bytecode the three " ..
          "targets do not share"
      end

      if m.kind == "main" then
        main = m.path
      end
      compiled[#compiled + 1] = m
    end
  end

  return { modules = compiled, boot_hash = boot_hash, main = main,
           refused = refused }
end

return importer
