--- [`build.importer`]'s tests that read the projection beyond their own
--- closure, apart from build/importer_test.tl's so those stand while the
--- tree moves: a compile's hint names what the binary's docs, or the
--- tree's own last projection, document, and a project's uses of the
--- standard library are read back beside the binary's own rows.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local SyntaxNode = require("build.syntax_node")
local docs = require("build.docs")
local importer = require("build.importer")
local plans = require("build.plans")
local standard_text = require("build.standard_text")
local work = require("build.work")
local writer = require("build.writer")
local schema = require("build.schema")
-- What a refusal says to write instead is [`cosmic.removed`]'s, which
-- build.error_render loads by no `require` a parse records: required here, it
-- is in this test's closure, which the worker lets it load.
local _ = require("cosmic.removed")
local build_paths = require("build.paths")

--- The projection, asked directly, and whether the tree is cosmic's own.
Test.policy{
  grants = { { path = "core", letters = "r" }, { path = "o/cosmic.db", letters = "r" } },
}

--- `root`'s build directory ([`build.paths`]), made, with `root` made
--- first where it is not there yet.
local function build_dir(root: string): string
  assert(Fs.mkdirs(root))
  return (assert(build_paths.prepare(root)))
end

--- Writes every entry of `files` (filename -> source) into a fresh
--- project directory of its own, named after `case`.
local function write_fixture(case: string, files: {string:string}): string?, string
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
local function compile_fixture(root: string): importer.Result?, string
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, { own = false })
  if staged == nil then
    work.close(handle)
    return nil, stage_trouble
  end
  local result, compile_trouble = importer.compile(handle,
    "declaration-cache-test")
  work.close(handle)
  -- The new checker goes on past a module it refuses and says so in `refused`: that is no compile, as the tests ask.
  if result ~= nil and #result.refused > 0 then
    return nil, table.concat(result.refused, "\n")
  end
  return result, compile_trouble
end

--- Project projections retain resolved references to bundled modules even
--- though those targets are absent from the project's own build plan.
local function test_project_keeps_uses_of_bundled_symbols()
  local root = assert(write_fixture("stdlib-uses", {
    ["main.tl"] = table.concat({
      'local disk = require("cosmic.fs")',
      "local record Main",
      "  check: function(string): boolean, string",
      "end",
      "--- Checks whether a path exists.",
      "function Main.check(path: string): boolean, string",
      "  local found, _ = disk.exists(path)",
      "  if found ~= true then",
      "    return false, \"the project path does not exist\"",
      "  end",
      "  return true, \"\"",
      "end",
      "return Main",
      "",
    }, "\n"),
  }))
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, "importer-test"))
  assert(#result.refused == 0, table.concat(result.refused, "\n"))
  assert(writer.write_result(handle, build_dir(root) .. "/cosmic.db", result))
  local shipped = assert(Sqlite.open(build_dir(root) .. "/cosmic.db"))
  local rows = assert(Sqlite.text_rows(shipped,
    "SELECT module, symbol, from_module, line FROM uses ORDER BY module, symbol"))
  assert(#rows == 1, tostring(#rows))
  assert(assert(rows[1]):text(1) == "cosmic.fs" and assert(rows[1]):text(2) == "exists")
  assert(assert(rows[1]):text(3) == "main" and assert(rows[1]):text(4) == "7")
  local guidance = assert(Sqlite.text_rows(shipped,
    "SELECT coalesce(c.text, (SELECT d.text FROM docs d " ..
      "WHERE d.module = c.module AND d.source_symbol = c.symbol)) " ..
      "FROM catalog c WHERE c.module = 'main' AND c.symbol = 'Main.check'"))
  assert(#guidance == 1 and assert(guidance[1]):text(1) == "Checks whether a path exists.")
  local databases: mut {Sqlite.Handle} = { shipped }
  for _, database in ipairs(Store.databases()) do
    databases[#databases + 1] = database
  end
  local effective = assert(docs.view(databases))
  local definition = assert(docs.lookup(effective, "Fs.exists"))
  assert(#definition == 1 and assert(definition[1]).module == "cosmic.fs")
  local uses = assert(docs.uses(effective, "Fs.exists"))
  local found_main = false
  for _, use in ipairs(uses) do
    if use.from_module == "main" and use.line == 7 then found_main = true end
  end
  assert(found_main, "effective uses dropped the project's bundled reference")
  assert(shipped:close())
  work.close(handle)
end

--- The checker strips `os` (and `io`, `debug`, `dofile`, `loadfile`)
--- from the checker's own globals, so a bare reference is tl's own
--- "unknown variable" -- not left to fail only once a built program
--- actually runs and reaches [`core/surface.c`]'s replacement text. The
--- message earns the same hint an unused variable does: a pointer at
--- [`cosmic.removed`]'s own field for the name, found by [`symbols.named`]
--- the same way `cosmic docs os` would find it.
local function test_unresolved_removed_global_names_its_own_replacement()
  local root = assert(write_fixture("removed-global-hint", {
    ["thing.tl"] = "return function(): integer\n  return os.time()\nend\n",
  }))
  local result, compile_trouble = compile_fixture(root)
  assert(result == nil, "expected the bare `os` reference to refuse the compile")
  assert(compile_trouble:find("thing.tl:2:10: `os` is not declared (unknown_variable): os.time is not available: use Clock.now_ns()",
    1, true) ~= nil, compile_trouble)
  assert(compile_trouble:find("see also in docs: Removed.os", 1, true) ~= nil,
    compile_trouble)
end

--- A removed name's refusal says what to write instead of the very
--- field used, not only where the docs are: `os.getenv` is [`Env.get`],
--- and the `require` that brings it in, ahead of the docs pointer.
local function test_a_removed_field_names_its_replacement_at_compile_time()
  local root = assert(write_fixture("removed-field-replacement", {
    ["thing.tl"] = 'return function(): string\n  return os.getenv("HOME") or ""\nend\n',
  }))
  local result, compile_trouble = compile_fixture(root)
  assert(result == nil, "expected `os.getenv` to refuse the compile")
  assert(compile_trouble:find("thing.tl:2:10: `os` is not declared (unknown_variable): os.getenv is not " ..
      'available: use Env.get(name) (local Env = require("cosmic.env"))' ..
      " -- see also in docs: Removed.os", 1, true) ~= nil, compile_trouble)
end

--- The same hint, for a literal `require` of a removed name: the checker
--- resolves `require("io")` against its modules, which strip `io` too, so this fails as an ordinary unresolvable
--- module rather than a bare global.
local function test_unresolved_removed_require_names_its_own_replacement()
  local root = assert(write_fixture("removed-require-hint", {
    ["thing.tl"] = 'local _io = require("io")\nreturn function(): integer\n  return 0\nend\n',
  }))
  local result, compile_trouble = compile_fixture(root)
  assert(result == nil, "expected `require(\"io\")` to refuse the compile")
  assert(compile_trouble:find("thing.tl:1:13: the project has no module `io` (require_unknown): io is not available",
    1, true) ~= nil, compile_trouble)
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
  assert(build_dir(root))
  local projection = assert(Sqlite.open(build_dir(root) .. "/cosmic.db", { writable = true }))
  for _, statement in ipairs(schema.create("")) do assert(projection:exec(statement)) end
  assert(projection:exec("INSERT INTO docs (module, symbol, source_symbol, exported, " ..
      "kind, signature, text, file, line) VALUES ('greeter', '', 'greeter', 1, " ..
      "'module', '', 'Greets.', 'greeter.tl', 1)"))
  assert(projection:close())
  local result, compile_trouble = compile_fixture(root)
  assert(result == nil, "expected the undeclared name to refuse the compile")
  assert(compile_trouble:find("`greeter` is not declared (unknown_variable)", 1, true) ~= nil, compile_trouble)
  assert(compile_trouble:find("-- see also in docs: greeter", 1, true) ~= nil, compile_trouble)
end

--- An ordinary undeclared-name typo, unrelated to anything the
--- database documents, earns no hint: [`symbols.named`] is an exact
--- match, never the free-text search `cosmic docs` falls back to, so
--- a name that happens to share words with unrelated prose is never
--- printed as though it explained this failure.
local function test_an_unrelated_unknown_name_earns_no_hint()
  local root = assert(write_fixture("unrelated-unknown-name", {
    ["thing.tl"] = "return function(): integer\n  return pritn(1)\nend\n",
  }))
  local result, compile_trouble = compile_fixture(root)
  assert(result == nil, "expected the undeclared name to refuse the compile")
  assert(compile_trouble:find("`pritn` is not declared (unknown_variable)", 1, true) ~= nil, compile_trouble)
  assert(compile_trouble:find("see also in docs", 1, true) == nil, compile_trouble)
  assert(compile_trouble:find("cosmic docs", 1, true) == nil, compile_trouble)
end

--- Concrete checker families point at checked language examples. These are
--- real project compiles, so the original position and diagnostic remain in
--- the output beside the hint. That every query advertised is answered by
--- the tree's docs is held by `cosmic fix --check .` ([`build.tree_checks`]).
local function test_language_errors_name_relevant_checked_docs()
  local cases: {string:{string}} = {
    wrong_arguments = {
      "return function(): integer\n  return string.find(\"abc\")\nend\n",
      "`string.find` takes 2 to 4 arguments, but 1 is given (arity)", "generics_functions_returns",
    },
    record_field = {
      "local record R\nend\nreturn function(): integer\n" ..
        "  local r: R = {}\n  return r.y\nend\n",
      "`R` has no field `y` (field_unknown)", "records_interfaces_methods",
    },
    builtin_argument_type = {
      "return function(n: number): integer?\n  return string.byte(\"a\", n)\nend\n",
      "no overload of `string.byte` takes the arguments (string, number) (overload_none)", "generics_functions_returns",
    },
  }
  for name, case in pairs(cases) do
    local root = assert(write_fixture("language-hint-" .. name,
      { ["thing.tl"] = case[1] }))
    local result, trouble = compile_fixture(root)
    assert(result == nil, "expected " .. name .. " to refuse the compile")
    assert(trouble:find("thing.tl:", 1, true) ~= nil, trouble)
    assert(trouble:find(case[2], 1, true) ~= nil, trouble)
    assert(trouble:find("cosmic docs " .. assert(case[3]), 1, true) ~= nil, trouble)
  end
end

--- A malformed type, which the parser refuses before the checker runs,
--- keeps its own diagnostic.
local function test_malformed_type_keeps_its_error()
  local root = assert(write_fixture("language-guide-malformed-type", {
    ["thing.tl"] = "local x: {string = integer} = {}\nreturn x\n",
  }))
  local result, trouble = compile_fixture(root)
  assert(result == nil)
  assert(trouble:find("expected `}` to close the collection type on line 1, found `=` (unclosed)", 1, true) ~= nil, trouble)
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
  assert(trouble:find("`string.find` takes 2 to 4 arguments, but 1 is given (arity)", 1, true) ~= nil, trouble)
  assert(trouble:find("cosmic docs generics_functions_returns", 1, true) ~= nil,
    trouble)
  assert(trouble:find("cosmic docs table.concat", 1, true) == nil, trouble)
end

--- A closure over what the program loads leaves out the names only a
--- declaration requires: `decl_imports` is the checker's, and no
--- closure reads it.
local function test_a_closure_leaves_out_the_names_only_a_declaration_requires()
  local databases = Store.databases()
  local binary = assert(databases[#databases])
  local only = assert(Sqlite.text_rows(binary,
    "SELECT DISTINCT d.requires FROM decl_imports d WHERE d.requires <> '' " ..
      "AND NOT EXISTS (SELECT 1 FROM imports i WHERE i.requires = d.requires) " ..
      "AND NOT EXISTS (SELECT 1 FROM modules m WHERE m.path = d.requires)"))
  assert(#only > 0, "every name a declaration requires is a module the program holds")
  local reached: mut {string:boolean} = {}
  for _, name in ipairs(Store.closure({ "cosmic.json", "cosmic.archive" }, { types = true })) do
    reached[name] = true
  end
  for _, row in ipairs(only) do
    assert(reached[row:text(1)] ~= true, row:text(1) .. " is in a closure of modules it is no import of")
  end
end

--- The stored edges are the ones the source holds: what parsing a
--- standard-library module for its requires finds is what its rows say.
local function test_stored_edges_equal_the_parsed_ones()
  local databases = Store.databases()
  local binary = assert(databases[#databases])
  local paths = assert(Sqlite.text_rows(binary,
    "SELECT path, 'decl' FROM decls WHERE path LIKE 'cosmic.%' " ..
      "UNION SELECT path, 'tl' FROM modules WHERE path LIKE 'cosmic.%' AND path NOT IN (SELECT path FROM decls) " ..
      "ORDER BY path"))
  assert(#paths > 0)
  for _, row in ipairs(paths) do
    local name = row:text(1)
    local source = assert(Store.source(name))
    local dialect: Ast.Dialect = if row:text(2) == "decl" then "decl" else "tl" end
    local parsed = Parser.parse(Lexer.lex(source, name .. ".tl"), name .. ".tl", dialect)
    local first_error = parsed.errors[1]
    assert(#parsed.errors == 0, name .. ": " .. (if first_error ~= nil then first_error.msg else "" end))
    local found = SyntaxNode.requires(parsed.chunk)
    local set: mut {string:boolean} = {}
    for _, required in ipairs(found) do set[required] = true end
    local wanted: mut {string} = {}
    for required in pairs(set) do wanted[#wanted + 1] = required end
    table.sort(wanted)
    local stored = assert(Sqlite.text_rows(binary,
      "SELECT requires FROM decl_imports WHERE path = ?1 AND requires <> '' " ..
        "ORDER BY requires",
      { { text = name } }))
    local got: mut {string} = {}
    for index, edge in ipairs(stored) do got[index] = edge:text(1) end
    assert(table.concat(got, ",") == table.concat(wanted, ","),
      name .. ": stored " .. table.concat(got, ",") .. ", parsed " .. table.concat(wanted, ","))
  end
end

--- The keys of a tree that reaches a standard-library module parse none of them to learn what they require, cold or warm:
--- the edges are stored.
local function test_the_keys_of_a_tree_do_not_parse_the_standard_library()
  local root = assert(write_fixture("no-embedded-parse", {
    ["main.tl"] = 'local Json = require("cosmic.json")\nlocal record Main\nend\nlocal main: Main = {}\nlocal _ = Json\nreturn main\n',
  }))
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  assert(importer.derive(handle))
  local modules = assert(plans.collect(handle.db))
  local parse = Parser.parse
  local parsed: mut {string} = {}
  Parser.parse = function(lexed: Lexer.Lexed, name: string, dialect: Ast.Dialect): Parser.Parsed
    parsed[#parsed + 1] = name
    return parse(lexed, name, dialect)
  end
  local keys, trouble = plans.dependency_keys(handle.db, modules, "no-parse-test")
  Parser.parse = parse
  work.close(handle)
  assert(keys ~= nil, tostring(trouble))
  assert(#parsed == 0, "parsed " .. table.concat(parsed, ", "))
end

--- An edit to what the checker reads of a standard-library module, its
--- stub or its source ([`standard_text.of`]), moves the key of a module
--- that reaches it, whether it requires that module or a module that
--- does, by the stored edges; so does the same text served as the other.
local function test_an_edit_to_an_embedded_source_moves_the_key_of_what_reaches_it()
  local function key_with(edited: string?, flipped?: boolean): string
    local root = assert(write_fixture("embedded-edit" .. tostring(edited), {
      ["main.tl"] = 'local Json = require("cosmic.json")\nlocal record Main\nend\nlocal main: Main = {}\nlocal _ = Json\nreturn main\n',
    }))
    local of = standard_text.of
    standard_text.of = function(name: string): standard_text.Standard?
      local found = of(name)
      if found ~= nil and name == edited then
        return { text = flipped and found.text or found.text .. "\n-- edited\n",
          stubbed = (flipped == true) ~= found.stubbed }
      end
      return found
    end
    local result, trouble = compile_fixture(root)
    standard_text.of = of
    assert(result ~= nil, tostring(trouble))
    for _, m in ipairs(result.modules) do
      if m.path == "main" then return assert(m.key) end
    end
    error("main is not among the compiled modules")
  end
  local plain = key_with(nil)
  assert(key_with(nil) == plain, "an unchanged tree moved a key")
  assert(key_with("cosmic.json") ~= plain, "an edit to a required module kept the key")
  assert(key_with("cosmic.json", true) ~= plain,
    "a required module served as a stub rather than its source, or the other way, kept the key")
  assert(key_with("cosmic.internal.json") ~= plain,
    "an edit to a module required by a required module kept the key")
end
