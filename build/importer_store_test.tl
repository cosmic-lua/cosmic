--- `build.importer`'s tests that read the projection beyond their own
--- closure, apart from build/importer_test.tl's so those stand while the
--- tree moves: a compile's hint names what the binary's docs, or the
--- tree's own last projection, document, and a project's uses of the
--- standard library are read back beside the binary's own rows.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local docs = require("build.docs")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")
local schema = require("build.schema")

--- The projection, asked directly, and whether the tree is cosmic's own.
Test.needs{ reads = { "core" }, store = true }

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Writes every entry of `files` (filename -> source) into a fresh
--- one-off project directory under `/tmp`, named after `case` and a random
--- suffix so a quickly reused process ID cannot pick up a prior run's cache.
local function write_fixture(case: string, files: {string:string}): string | nil, string
  local root, trouble = Fs.mkdtemp("cosmic-importer-test-" .. case .. "-")
  if root == nil then
    return nil, trouble
  end
  for filename, source in pairs(files) do
    local parent = filename:match("^(.+)/[^/]+$")
    if parent and not Fs.mkdirs(root .. "/" .. parent) then
      return nil, root .. "/" .. parent .. ": could not create fixture directory"
    end
    local ok: boolean
    ok, trouble = Fs.write(root .. "/" .. filename, source)
    if not ok then
      return nil, trouble
    end
  end
  return root, ""
end

--- Stages and compiles one fixture run. Reopening the same root keeps its
--- working database, which lets a test exercise the real warm cache.
local function compile_fixture(root: string): importer.Result | nil, string
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    work.close(handle)
    return nil, stage_trouble
  end
  local result, compile_trouble = importer.compile(handle, built,
    "declaration-cache-test")
  work.close(handle)
  return result, compile_trouble
end

--- Project projections retain resolved references to bundled modules even
--- though those targets are absent from the project's own build plan.
local function test_project_keeps_uses_of_bundled_symbols()
  local root = assert(write_fixture("stdlib-uses", {
    ["main.tl"] = table.concat({
      'local disk = require("cosmic.fs")',
      "local record Main",
      "end",
      "--- Checks whether a path exists.",
      "function Main.check(path: string): boolean, string",
      "  if not disk.exists(path) then",
      "    return false, \"the project path does not exist\"",
      "  end",
      "  return true, \"\"",
      "end",
      "return Main",
      "",
    }, "\n"),
  }))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local result = assert(importer.compile(handle, built, "importer-test"))
  assert(writer.write_result(handle, root .. "/o/cosmic.db", result))
  local shipped = assert(Sqlite.open(root .. "/o/cosmic.db", false))
  local rows = assert(Sqlite.text_rows(shipped,
    "SELECT module, symbol, from_module, line FROM uses ORDER BY module, symbol"))
  assert(#rows == 1, tostring(#rows))
  assert(rows[1][1] == "cosmic.fs" and rows[1][2] == "exists")
  assert(rows[1][3] == "main" and rows[1][4] == "6")
  local guidance = assert(Sqlite.text_rows(shipped,
    "SELECT coalesce(c.text, (SELECT d.text FROM docs d " ..
    "WHERE d.module = c.module AND d.source_symbol = c.symbol)) " ..
    "FROM catalog c WHERE c.module = 'main' AND c.symbol = 'Main.check'"))
  assert(#guidance == 1 and guidance[1][1] == "Checks whether a path exists.")
  local databases: {Sqlite.Handle} = { shipped }
  for _, database in ipairs(Store.databases()) do
    databases[#databases + 1] = database
  end
  local effective = assert(docs.view(databases))
  local definition = assert(docs.lookup(effective, "Fs.exists"))
  assert(#definition == 1 and definition[1].module == "cosmic.fs")
  local uses = assert(docs.uses(effective, "Fs.exists"))
  local found_main = false
  for _, use in ipairs(uses) do
    if use.from_module == "main" and use.line == 6 then found_main = true end
  end
  assert(found_main, "effective uses dropped the project's bundled reference")
  assert(shipped:close())
  work.close(handle)
end

--- `build.teal` strips `os` (and `io`, `debug`, `dofile`, `loadfile`)
--- from the checker's own globals, so a bare reference is tl's own
--- "unknown variable" -- not left to fail only once a built program
--- actually runs and reaches `core/surface.c`'s replacement text. The
--- message earns the same hint an unused variable does: a pointer at
--- `cosmic.removed`'s own field for the name, found by `symbols.named`
--- the same way `cosmic docs os` would find it.
local function test_unresolved_removed_global_names_its_own_replacement()
  local root = assert(write_fixture("removed-global-hint", {
    ["thing.tl"] = "return function(): integer\n  return os.time()\nend\n",
  }))
  local result, compile_trouble = compile_fixture(root)
  assert(result == nil, "expected the bare `os` reference to refuse the compile")
  assert(compile_trouble:find("unknown variable: os", 1, true) ~= nil, compile_trouble)
  assert(compile_trouble:find("see also in docs: Removed.os", 1, true) ~= nil,
    compile_trouble)
end

--- A removed name's refusal says what to write instead of the very
--- field used, not only where the docs are: `os.getenv` is `Env.get`,
--- and the `require` that brings it in, ahead of the docs pointer.
local function test_a_removed_field_names_its_replacement_at_compile_time()
  local root = assert(write_fixture("removed-field-replacement", {
    ["thing.tl"] = 'return function(): string\n  return os.getenv("HOME") or ""\nend\n',
  }))
  local result, compile_trouble = compile_fixture(root)
  assert(result == nil, "expected `os.getenv` to refuse the compile")
  assert(compile_trouble:find("thing.tl:2:10: unknown variable: os -- os.getenv is not " ..
    'available: use Env.get(name) (local Env = require("cosmic.env"))' ..
    " -- see also in docs: Removed.os", 1, true) ~= nil, compile_trouble)
end

--- The same hint, for a literal `require` of a removed name: tl
--- resolves `require("io")` against `env.modules`, which `build.teal`
--- strips `io` from too, so this fails as an ordinary unresolvable
--- module rather than a bare global.
local function test_unresolved_removed_require_names_its_own_replacement()
  local root = assert(write_fixture("removed-require-hint", {
    ["thing.tl"] = 'local _io = require("io")\nreturn function(): integer\n  return 0\nend\n',
  }))
  local result, compile_trouble = compile_fixture(root)
  assert(result == nil, "expected `require(\"io\")` to refuse the compile")
  assert(compile_trouble:find("module not found: 'io'", 1, true) ~= nil, compile_trouble)
  assert(compile_trouble:find("see also in docs: Removed.io", 1, true) ~= nil,
    compile_trouble)
end

--- A tree's own last projection is where a hint finds the tree's own
--- modules, which the tool does not document for any tree but its
--- standard library's: an unknown name that `o/cosmic.db` documents
--- names it.
local function test_a_hint_names_what_the_tree_s_own_projection_documents()
  local root = assert(write_fixture("projection-hint", {
    ["thing.tl"] = "return function(): integer\n  return greeter.count()\nend\n",
  }))
  assert(Fs.mkdirs(root .. "/o"))
  local projection = assert(Sqlite.open(root .. "/o/cosmic.db", true))
  for _, statement in ipairs(schema.create("")) do assert(projection:exec(statement)) end
  assert(projection:exec("INSERT INTO docs (module, symbol, source_symbol, exported, " ..
    "kind, signature, text, file, line) VALUES ('greeter', '', 'greeter', 1, " ..
    "'module', '', 'Greets.', 'greeter.tl', 1)"))
  assert(projection:close())
  local result, compile_trouble = compile_fixture(root)
  assert(result == nil, "expected the undeclared name to refuse the compile")
  assert(compile_trouble:find("unknown variable: greeter -- see also in docs: greeter",
    1, true) ~= nil, compile_trouble)
end

--- An ordinary undeclared-name typo, unrelated to anything the
--- database documents, earns no hint: `symbols.named` is an exact
--- match, never the free-text search `cosmic docs` falls back to, so
--- a name that happens to share words with unrelated prose is never
--- printed as though it explained this failure.
local function test_an_unrelated_unknown_name_earns_no_hint()
  local root = assert(write_fixture("unrelated-unknown-name", {
    ["thing.tl"] = "return function(): integer\n  return pritn(1)\nend\n",
  }))
  local result, compile_trouble = compile_fixture(root)
  assert(result == nil, "expected the undeclared name to refuse the compile")
  assert(compile_trouble:find("unknown variable: pritn", 1, true) ~= nil, compile_trouble)
  assert(compile_trouble:find("see also in docs", 1, true) == nil, compile_trouble)
  assert(compile_trouble:find("cosmic docs", 1, true) == nil, compile_trouble)
end

--- Concrete checker families point at checked language examples. These are
--- real project compiles, so the original position and diagnostic remain in
--- the output beside the hint. That every query advertised is answered by
--- the tree's docs is held by `cosmic fix --check .` (`build.tree_checks`).
local function test_language_errors_name_relevant_checked_docs()
  local cases: {string:{string}} = {
    wrong_arguments = {
      "return function(): integer\n  return string.find(\"abc\")\nend\n",
      "wrong number of arguments", "generics_functions_returns",
    },
    record_field = {
      "local record R\n  x: integer\nend\nreturn function(): integer\n" ..
        "  local r: R = { x = 1 }\n  return r.y\nend\n",
      "invalid key 'y' in record", "records_interfaces_methods",
    },
    union_operator = {
      "return function(x: string | integer): integer\n  return x + 1\nend\n",
      "cannot use operator '+'", "unions_narrowing_casts",
    },
    builtin_argument_type = {
      "return function(): string\n  return table.concat(123)\nend\n",
      "argument 1: got integer", "generics_functions_returns",
    },
  }
  for name, case in pairs(cases) do
    local root = assert(write_fixture("language-hint-" .. name,
      { ["thing.tl"] = case[1] }))
    local result, trouble = compile_fixture(root)
    assert(result == nil, "expected " .. name .. " to refuse the compile")
    assert(trouble:find("thing.tl:", 1, true) ~= nil, trouble)
    assert(trouble:find(case[2], 1, true) ~= nil, trouble)
    assert(trouble:find("cosmic docs " .. case[3], 1, true) ~= nil, trouble)
  end
end

--- Syntax rejected while constructing the checker environment still keeps its
--- original diagnostic. Its corresponding language guide is independently
--- available rather than being promised by a code path compilation never
--- reaches, which `cosmic fix --check .` holds (`build.tree_checks`).
local function test_malformed_type_keeps_its_error()
  local root = assert(write_fixture("language-guide-malformed-type", {
    ["thing.tl"] = "local x: {string = integer} = {}\nreturn x\n",
  }))
  local result, trouble = compile_fixture(root)
  assert(result == nil)
  assert(trouble:find("expected a type list", 1, true) ~= nil, trouble)
end

--- An incidental API name elsewhere on the line cannot make an argument
--- diagnostic claim that API is the failed call.
local function test_argument_hint_does_not_sniff_the_whole_source_line()
  local root = assert(write_fixture("language-hint-no-line-sniff", {
    ["thing.tl"] = "return function(): integer\n" ..
      "  return string.find(\"abc\") -- table.concat\nend\n",
  }))
  local result, trouble = compile_fixture(root)
  assert(result == nil)
  assert(trouble:find("wrong number of arguments", 1, true) ~= nil, trouble)
  assert(trouble:find("cosmic docs generics_functions_returns", 1, true) ~= nil,
    trouble)
  assert(trouble:find("cosmic docs table.concat", 1, true) == nil, trouble)
end
