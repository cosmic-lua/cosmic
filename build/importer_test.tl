--- [`build.importer`] over fixture trees: what a module requires, what a
--- warm compile compiles again, the tool's hashes, the compiler's,
--- analyzer's and writer's identities, the uses a projection keeps, and
--- what a compile refuses.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Test = require("cosmic.test")
local identity = require("build.identity")
local docs = require("build.docs")
local importer = require("build.importer")
local GrammarMode = require("build.grammar_mode")
local Pipeline = require("build.pipeline")
local type _ = require("build.test_inputs")
-- Read as source by the closure checks below, though the modules above
-- name it only by type, which no closure follows.
local type _ = require("build.module")
local type _ = require("build.inputs")
local work = require("build.work")
local writer = require("build.writer")
local shared_compiles = require("build.shared_compiles")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local SyntaxNode = require("build.syntax_node")

--- Whether the tree is cosmic's own. The tests that read the projection
--- beyond this module's closure -- the docs a compile's hint names --
--- are build/importer_store_test.tl's.
Test.policy{
  grants = { { path = "core", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" },
    { path = "lang/stdlib.d.tl", letters = "r" } },
}

--- The modules the source `source` of the file `file` requires, as a parse of it finds them.
local function requires_of(source: string, file: string): {string}
  local parsed = Parser.parse(Lexer.lex(source, file), file, "tl")
  assert(#parsed.errors == 0, file .. ": " .. (if parsed.errors[1] ~= nil then parsed.errors[1].msg else "" end))
  return SyntaxNode.requires(parsed.chunk)
end

--- A module requiring each of `uses`, by name.
local function module_requiring(uses: {string}): string
  local lines: mut {string} = {}
  for index, used in ipairs(uses) do
    lines[#lines + 1] = "local m" .. index .. " = require(\"" .. used .. "\")"
  end
  lines[#lines + 1] = "local record M\n  uses: {any}\nend"
  local names: mut {string} = {}
  for index = 1, #uses do names[#names + 1] = "m" .. index end
  lines[#lines + 1] = "M.uses = { " .. table.concat(names, ", ") .. " }"
  lines[#lines + 1] = "return M"
  return table.concat(lines, "\n") .. "\n"
end

--- A module returning a record that holds `n`, as the grammar takes a module's value.
local function valued(n: integer): string
  return "local record Valued\n  value: integer\nend\nlocal valued: Valued = { value = " .. tostring(n) ..
    " }\nreturn valued\n"
end

--- A module `types` whose record has the type `Thing` of a `value` and builds one.
local TYPES_IMPLEMENTED <const> = "local record Types\n  record Thing\n    value: number\n  end\n  make: function(): Types.Thing\nend\n" ..
  "function Types.make(): Types.Thing\n  return { value = 1 }\nend\nreturn Types\n"

--- The declaration of the module `types` of [`TYPES_IMPLEMENTED`], with a `value` of `kind`.
local function types_declared(kind: string): string
  return "local record Types\n  record Thing\n    value: " .. kind .. "\n  end\n  make: function(): Types.Thing\nend\nreturn Types\n"
end

--- The module `dep` over the record the declaration `dep.d.tl` gives, holding `n`.
local function dep_valued(n: integer): string
  return "local record Dep\n  value: number\nend\nlocal dep: Dep = { value = " .. tostring(n) .. " }\nreturn dep\n"
end

--- A module returning a record that holds the value of the module `name`.
local function requiring(name: string): string
  return "local " .. name .. " = require(\"" .. name .. "\")\nlocal record Requiring\n  value: integer\nend\n" ..
    "local requiring: Requiring = { value = " .. name .. ".value }\nreturn requiring\n"
end

--- The compile of the staged tree in `handle`, which must refuse no module.
local function compiled_clean(handle: work.Handle): importer.Result
  local result, trouble = importer.compile(handle, "importer-test")
  assert(result ~= nil, trouble)
  assert(#result.refused == 0, table.concat(result.refused, "\n"))
  return result
end

--- Writes every entry of `files` (filename -> source) into a fresh
--- project directory of its own, named after `case`.
local function write_fixture(case: string, files: {string:string}): string?, string
  local root, trouble = Fs.mkdtemp("cosmic-importer-test-" .. case .. "-")
  if root == nil then
    return nil, trouble
  end
  local all: mut {string:string} = {}
  for filename, source in pairs(files) do
    all[filename] = source
  end
  -- A tree that is cosmic's own ([`build.tree`]) is checked against the declarations of the standard library it holds.
  if files["build/importer.tl"] ~= nil then
    all["lang/prelude.d.tl"] = assert(Fs.read("lang/prelude.d.tl"))
    all["lang/stdlib.d.tl"] = assert(Fs.read("lang/stdlib.d.tl"))
    all["build/ceilings.txt"] = "[checked]\n"
  end
  for filename, source in pairs(all) do
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

--- Builds the fixture project at `root` and returns the `requires` of
--- whichever compiled module has import path `path`.
local function requires_of_fixture(root: string, path: string): {string}?, string
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
  if staged == nil then
    work.close(handle)
    return nil, stage_trouble
  end
  local result, compile_trouble = importer.compile(handle, "importer-test")
  work.close(handle)
  if result == nil then
    return nil, compile_trouble
  end
  if #result.refused > 0 then
    return nil, table.concat(result.refused, "\n")
  end
  for _, m in ipairs(result.modules) do
    if m.path == path then
      return m.requires
    end
  end
  return nil, path .. ": not found among compiled modules"
end

--- Stages and compiles one fixture run. Reopening the same root keeps its
--- working database, which lets a test exercise the real warm cache.
local function compile_fixture(root: string): importer.Result?, string
  local handle, open_trouble = work.open(root)
  if handle == nil then
    return nil, open_trouble
  end
  local staged, stage_trouble = work.stage(handle, false)
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

--- Observes the real derive and compile through an empty shared cache.
--- Offers must survive a later failure, and no operation may follow finish.
local record SharedTrace
  mut finished: integer
  mut offered: integer
  kept: mut {string}
  flushed: mut {string}
end

local function traced_cache(): importer.Shared, SharedTrace
  local trace: SharedTrace = { finished = 0, offered = 0, kept = {}, flushed = {} }
  local function active()
    assert(trace.finished == 0, "cache used after finish")
  end
  local shared: importer.Shared = {
    analyzers = function(_hashes: {string}): {string}
      active()
      return {}
    end,
    requires = function(_analyzer: string, _hashes: {string}): {string:{string}}
      active()
      return {}
    end,
    parse = function(_analyzer: string, _hash: string, _mapped: boolean): importer.Shared.Parse?
      active()
      return nil
    end,
    offer = function(_analyzer: string, _hash: string, _mapped: boolean, _made: importer.Shared.Parse)
      active()
      trace.offered = trace.offered + 1
    end,
    look = function(_module: importer.Module, _own: boolean): importer.Shared.Compile?
      active()
      return nil
    end,
    keep = function(module: importer.Module, _own: boolean, _made: importer.Shared.Compile)
      active()
      trace.kept[#trace.kept + 1] = module.path
    end,
    finish = function()
      active()
      trace.finished = trace.finished + 1
      for _, path in ipairs(trace.kept) do trace.flushed[#trace.flushed + 1] = path end
    end,
  }
  return shared, trace
end

local function test_compile_consumes_shared_cache_on_success_and_failure()
  for _, failing in ipairs({ false, true }) do
    local root = assert(write_fixture("cache-compile", {
      ["a.tl"] = valued(1),
      ["z.tl"] = if failing then "local value: string = 1\nreturn value\n" else
        valued(2) end,
    }))
    local handle = assert(work.open(root))
    assert(work.stage(handle, false))
    local shared, trace = traced_cache()
    local result, trouble = importer.compile(handle, "cache-lifetime", false, shared)
    assert(trace.finished == 1, "compile did not finish its cache exactly once")
    assert(trace.offered == 2, "derive did not offer both sources")
    assert(trace.flushed[1] == "a", "a successful compile was lost before finishing")
    if failing then
      assert(result ~= nil, trouble)
      assert(#result.refused == 1 and result.refused[1]:find("z.tl", 1, true) ~= nil, table.concat(result.refused, "\n"))
      assert(#trace.flushed == 1, "a refused compile was shared")
    else
      assert(result ~= nil, trouble)
      assert(result.parses.parsed == 2 and #trace.flushed == 2)
    end
    assert(work.close(handle))
  end
end

local function test_compile_finishes_shared_cache_when_derivation_fails()
  local root = assert(write_fixture("cache-derive", { ["cosmic/claimed.tl"] = "return {}\n" }))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local shared, trace = traced_cache()
  local result, trouble = importer.compile(handle, "cache-lifetime", false, shared)
  assert(result == nil and trouble:find("reserved", 1, true) ~= nil, trouble)
  assert(trace.finished == 1 and trace.offered == 0 and #trace.flushed == 0)
  assert(work.close(handle))
end

local function test_self_compile_consumes_cache_after_identity_selection()
  for _, phase in ipairs({ "success", "record", "select" }) do
    local root = assert(write_fixture("cache-identity", {
      ["build/importer.tl"] = "local record Stub end\nreturn Stub\n",
      ["build/pipeline.tl"] = "local fs = require(\"cosmic.fs\")\nlocal record Pipeline\nend\nlocal pipeline: Pipeline = {}\nlocal _ = fs\nreturn pipeline\n",
      ["core/empty.h"] = "",
    }))
    local handle = assert(work.open(root))
    assert(work.stage(handle, true))
    if phase == "record" then
      assert(handle.db:exec("CREATE TRIGGER refuse_identity BEFORE INSERT ON meta " ..
          "WHEN NEW.key = 'compiler' BEGIN SELECT RAISE(ABORT, 'identity refused'); END"))
    end
    local shared, trace = traced_cache()
    local selected = { value = false }
    local result, trouble = importer.compile_tree(handle,
      function(recorded: identity.Identities): string?,
      string
        selected.value = true
        assert(trace.finished == 0 and trace.offered == 2,
          "identity selected before derivation completed")
        local rows = assert(Sqlite.text_rows(handle.db,
          "SELECT value FROM meta WHERE key = 'compiler'"))
        assert(rows[1]:text(1) == recorded.compiler, "selection ran before recording identities")
        if phase == "select" then return nil, "selection refused" end
        return "chosen-compiler", ""
      end, false, shared)
    assert(trace.finished == 1, "self-build did not finish its cache exactly once")
    assert(selected.value == (phase ~= "record"))
    if phase == "success" then
      assert(result ~= nil, trouble)
      -- The tool the selection answered, as the compile in the new mode keys it ([`Pipeline.coded_of`]).
      local chosen = "chosen-compiler"
      local moded = GrammarMode.tool(chosen, "new")
      local c1, c2 = Pipeline.coded(chosen), assert(Pipeline.coded_of(chosen, handle.db))
      local c3, c4 = Pipeline.coded(moded), assert(Pipeline.coded_of(moded, handle.db))
      assert(result.parses.parsed == 2, tostring(result.parses.parsed))
      assert(result.tool == c1 or result.tool == c2 or result.tool == c3 or result.tool == c4,
        result.tool .. " not in " .. c1 .. " " .. c2 .. " " .. c3 .. " " .. c4)
      assert(trace.offered == 2 and #trace.flushed == 2)
    else
      assert(result == nil and trouble:find("refused", 1, true) ~= nil, trouble)
      assert(trace.offered == 2 and #trace.flushed == 0)
    end
    assert(work.close(handle))
  end
end

--- A declaration is the source the checker uses for an imported module,
--- including when an implementation with the same import path exists. An
--- edit that changes its public type must invalidate a warm dependent.
local function test_declaration_edit_invalidates_a_warm_dependent()
  local root, write_trouble = write_fixture("declaration-cache", {
    ["main.tl"] = table.concat({
      'local type Types = require("types")',
      "local value: number = 42",
      "local thing: Types.Thing = { value = value }",
      "return thing",
      "",
    }, "\n"),
    ["types.tl"] = TYPES_IMPLEMENTED,
    ["types.d.tl"] = types_declared("number"),
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  assert(compile_fixture(root))
  assert(Fs.write(root .. "/types.d.tl", types_declared("string")))
  local result, trouble = compile_fixture(root)
  assert(result == nil, "a warm compile reused code checked against the old declaration")
  assert(trouble:find("string", 1, true) ~= nil,
    "the changed declaration did not reach the checker: " .. trouble)
end

--- Type-only imports participate in the same transitive closure. The main
--- module does not name `types`, but changing that declaration must still
--- invalidate `helper` and then main in a warm database.
local function test_declaration_edit_invalidates_transitive_type_only_dependents()
  local root, write_trouble = write_fixture("transitive-declaration-cache", {
    ["main.tl"] = table.concat({
      'local helper = require("helper")',
      "local record Main",
      "  value: number",
      "end",
      "local made = helper.make()",
      "local main: Main = { value = made.value }",
      "return main",
      "",
    }, "\n"),
    ["helper.tl"] = table.concat({
      'local type Types = require("types")',
      "local record helper",
      "  make: function(): Types.Thing",
      "end",
      "function helper.make(): Types.Thing",
      "  return { value = 42 }",
      "end",
      "return helper",
      "",
    }, "\n"),
    ["types.d.tl"] = types_declared("number"),
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  assert(compile_fixture(root))
  assert(Fs.write(root .. "/types.d.tl", types_declared("string")))
  local result, trouble = compile_fixture(root)
  assert(result == nil, "a warm compile missed a transitive declaration edit")
  assert(trouble:find("string", 1, true) ~= nil,
    "the transitive declaration did not reach the checker: " .. trouble)
end

--- The declaration controls checking, but the implementation still controls
--- what a test loads. Changing only that implementation must move the test's
--- key so a previously passing verdict is not reused.
local function test_implementation_edit_invalidates_a_declared_dependent()
  local root, write_trouble = write_fixture("declared-implementation-cache", {
    ["dep.tl"] = dep_valued(1),
    ["dep.d.tl"] = "local record Dep\n  value: number\nend\nreturn Dep\n",
    ["main_test.tl"] = table.concat({
      'local dep = require("dep")',
      "local function test_value()",
      "  assert(dep.value == 1)",
      "end",
      "",
    }, "\n"),
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  assert(compile_fixture(root))
  assert(Fs.write(root .. "/dep.tl", dep_valued(2)))
  local result, trouble = compile_fixture(root)
  assert(result ~= nil, "the edited fixture did not compile: " .. tostring(trouble))
  assert(result.compiled == 2,
    "the implementation edit left its declared dependent cached")
end

--- A module's own compile is keyed by its file as well as its import
--- path: `x.tl` moved to `x/init.tl`, the same module of the same source,
--- is compiled again (build.syntax_contracts' exemptions are by file), while a
--- module that requires it, whose compile no file of its dependency
--- decides, stands, and so does the graph key a test's verdict is kept by.
local function test_a_module_moved_to_its_init_file_is_compiled_again()
  local root, write_trouble = write_fixture("moved-to-init", {
    ["x.tl"] = valued(1),
    ["main.tl"] = requiring("x"),
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local first = assert(compile_fixture(root))
  assert(Fs.mkdirs(root .. "/x"))
  assert(Fs.rename(root .. "/x.tl", root .. "/x/init.tl"))
  local result = assert(compile_fixture(root))
  assert(result.compiled == 1 and result.cached == 1,
    result.compiled .. " compiled, " .. result.cached .. " cached")
  local function by_path(modules: {importer.Module}, path: string): importer.Module
    for _, m in ipairs(modules) do
      if m.path == path then return m end
    end
    error(path .. ": not among the modules")
  end
  local before, after = by_path(first.modules, "x"), by_path(result.modules, "x")
  assert(after.file == "x/init.tl", after.file)
  assert(before.key ~= after.key, "the move kept x's compile key")
  assert(before.graph_key == after.graph_key, "the move moved x's graph key")
end

--- What the working database of the project at `root` answers to `sql`,
--- as rows of text.
local function asked_of(root: string, sql: string): {{string}}
  local handle = assert(work.open(root))
  local rows = assert(Sqlite.text_rows(handle.db, sql))
  work.close(handle)
  local out: mut {{string}} = {}
  for _, row in ipairs(rows) do out[#out + 1] = row:texts() end
  return out
end

--- The keys a run makes are kept for the next run that has the same inputs
--- (`keys_memo`), and an input that changes is never answered with them: an
--- edit to a module moves its own key and its dependents', and what a
--- module that requires nothing of it holds stands.
local function test_the_keys_of_unchanged_inputs_are_kept_and_an_edit_moves_them()
  local root = assert(write_fixture("keys-memo", {
    ["x.tl"] = valued(1),
    ["main.tl"] = requiring("x"),
    ["other.tl"] = valued(2),
  }))
  local function keys_of(result: importer.Result): {string:string}
    local out: mut {string:string} = {}
    for _, m in ipairs(result.modules) do
      out[m.path] = (m.key or "") .. " " .. (m.graph_key or "")
    end
    return out
  end
  local first = keys_of((assert(compile_fixture(root))))
  assert(#asked_of(root, "SELECT fp FROM keys_memo") == 1, "the first run kept no keys")
  local again = keys_of((assert(compile_fixture(root))))
  assert(#asked_of(root, "SELECT fp FROM keys_memo") == 1, "an unchanged tree kept its keys twice")
  for path, key in pairs(first) do
    assert(again[path] == key, path .. ": the kept keys are not the ones made")
  end
  assert(Fs.write(root .. "/x.tl", valued(3)))
  local edited = keys_of((assert(compile_fixture(root))))
  assert(#asked_of(root, "SELECT fp FROM keys_memo") == 2, "an edit was answered with the keys before it")
  assert(edited["x"] ~= first["x"], "x: an edit kept its key")
  assert(edited["main"] ~= first["main"], "main: an edit to what it requires kept its key")
  assert(edited["other"] == first["other"], "other: an edit to another module moved its key")
  assert(Fs.write(root .. "/x.tl", valued(1)))
  local undone = keys_of((assert(compile_fixture(root))))
  for path, key in pairs(first) do
    assert(undone[path] == key, path .. ": undoing the edit did not find its keys again")
  end
end

--- A run that finds a compile cached does not write the compile's row, which
--- holds all its Lua and bytecode, to say it used it: its `seen` is written
--- only once it is many runs old, so a compile in use is never dropped.
local function test_a_cached_compile_is_marked_seen_only_once_it_is_old()
  local root = assert(write_fixture("seen-lazily", {
    ["x.tl"] = valued(1),
  }))
  assert(compile_fixture(root))
  local function seen_of(): integer
    local rows = asked_of(root, "SELECT seen FROM compiled")
    assert(#rows == 1, "expected one compile")
    local row = assert(rows[1])
    return assert(math.tointeger(tonumber(row[1])))
  end
  local made = seen_of()
  assert(compile_fixture(root))
  assert(seen_of() == made, "a run that used a recent compile wrote its row again")
  local handle = assert(work.open(root))
  assert(Sqlite.run(handle.db, "UPDATE compiled SET seen = seen - 50"))
  work.close(handle)
  assert(compile_fixture(root))
  assert(seen_of() ~= made - 50, "an old compile used by a run kept its old mark")
end

--- The test above sets `seen` below zero, which marks a compile never
--- reused, so it is compiled again whether or not a use of the old one
--- marks it. This one ages the compile by the runs that went by instead:
--- one standing, used by a run many runs after its mark, is marked again
--- and not compiled.
local function test_a_standing_compile_used_many_runs_later_is_marked_not_compiled()
  local root = assert(write_fixture("seen-by-runs", {
    ["x.tl"] = valued(1),
  }))
  assert(compile_fixture(root))
  local function seen_of(): integer
    local rows = asked_of(root, "SELECT seen FROM compiled")
    assert(#rows == 1, "expected one compile")
    local row = assert(rows[1])
    return assert(math.tointeger(tonumber(row[1])))
  end
  local made = seen_of()
  local handle = assert(work.open(root))
  assert(Sqlite.run(handle.db, "UPDATE meta SET value = value + 40 WHERE key = 'run'"))
  work.close(handle)
  local result = assert(compile_fixture(root))
  assert(result.compiled == 0 and result.cached == 1, "a standing compile was made again")
  assert(seen_of() >= made + 40, "a compile used 40 runs after its mark kept its mark")
end

--- Stages and compiles the fixture at `root` as `cosmic fix` does, asking for
--- the build it made a moment ago where nothing has moved since.
local function compile_again(root: string): importer.Result
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local result = assert(importer.compile(handle, "importer-test", false, nil, nil, true))
  work.close(handle)
  return result
end

--- A build asked for again is the one before while the files and the plan it
--- left are as they were, not compiled but handed back with nothing made; an
--- edit, a file gone, or a plan another run replaced is built afresh.
local function test_a_build_asked_for_again_is_the_one_before_only_while_nothing_moved()
  local root = assert(write_fixture("again", {
    ["x.tl"] = valued(1),
    ["y.tl"] = requiring("x"),
  }))
  local first = compile_again(root)
  assert(first.compiled == 2, "the first build compiled " .. tostring(first.compiled))
  local again = compile_again(root)
  assert(again.compiled == 0 and again.cached == 2, "a build nothing moved was made again")
  assert(again.modules == first.modules, "the build before was not handed back")

  assert(Fs.write(root .. "/x.tl", valued(2)))
  local edited = compile_again(root)
  assert(edited.compiled >= 1, "an edit was not built")
  assert(compile_again(root).compiled == 0, "the build after an edit was not handed back")

  local handle = assert(work.open(root))
  assert(Sqlite.run(handle.db, "DELETE FROM plan WHERE path = 'y'"))
  work.close(handle)
  local replanned = compile_again(root)
  assert(replanned.compiled == 0 and replanned.cached == 2 and replanned.modules ~= edited.modules,
    "a plan another run replaced was served")
  local handle_after = assert(work.open(root))
  local planned = assert(Sqlite.text_rows(handle_after.db, "SELECT count(*) FROM plan"))
  work.close(handle_after)
  assert(assert(planned[1]):text(1) == "2", "the plan was not written again")

  assert(Fs.remove(root .. "/y.tl"))
  local gone = compile_again(root)
  assert(#gone.modules == 1, "a file gone was served")
end

--- Mutually recursive declaration types are valid input to the checker. A
--- cache key closes over the graph without rejecting that cycle itself.
local function test_declaration_dependency_keys_allow_cycles()
  local root, write_trouble = write_fixture("declaration-cycle", {
    ["main.tl"] = table.concat({
      'local type A = require("a")',
      "return function(value: A.Value): number",
      "  return value.n",
      "end",
      "",
    }, "\n"),
    ["a.d.tl"] = table.concat({
      'local type B = require("b")',
      "local record A",
      "  record Value",
      "    n: number",
      "    peer: B.Value",
      "  end",
      "end",
      "return A",
      "",
    }, "\n"),
    ["b.d.tl"] = table.concat({
      'local type A = require("a")',
      "local record B",
      "  record Value",
      "    n: number",
      "    peer: A.Value",
      "  end",
      "end",
      "return B",
      "",
    }, "\n"),
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local result, trouble = compile_fixture(root)
  assert(result ~= nil, "declaration cycle was refused: " .. tostring(trouble))
end

--- A `require("cosmic.hidden_dep")` inside a comment or a string literal
--- is not an import: [`requires_of`] finds no `require` call in this
--- source, though its bytes carry that text twice. A match over the
--- source text, with no notion of a comment or a string, would report
--- `cosmic.hidden_dep` as a dependency.
local function test_ignores_a_require_inside_a_comment_and_a_string()
  local source = table.concat({
    '-- require("cosmic.hidden_dep") is only text in this comment.',
    'local _sample = "require(\\"cosmic.hidden_dep\\")"',
    "local record thing",
    "end",
    "return thing",
    "",
  }, "\n")
  local root, write_trouble = write_fixture("comment-and-string",
    { ["main.tl"] = source })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local requires, trouble = requires_of_fixture(root, "main")
  assert(requires ~= nil, "compile failed: " .. tostring(trouble))
  assert(#requires == 0,
    "expected no requires, got " .. #requires .. ": " .. table.concat(requires, ", "))
end

--- A genuine top-level require of a real sibling module is found.
local function test_finds_a_real_top_level_require()
  local root, write_trouble = write_fixture("real-require", {
    ["main.tl"] = 'local dep = require("real_dep")\nlocal record Main\n  name: string\nend\nlocal main: Main = { name = dep.name }\nreturn main\n',
    ["real_dep.tl"] = "local record real_dep\n  name: string\nend\nlocal real: real_dep = { name = \"x\" }\nreturn real\n",
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local requires, trouble = requires_of_fixture(root, "main")
  assert(requires ~= nil, "compile failed: " .. tostring(trouble))
  assert(#requires == 1, "expected 1 require, got " .. #requires)
  assert(requires[1] == "real_dep", "got: " .. tostring(requires[1]))
end

--- A `pcall(require, "<name>")` is an import as a `require` is: it is among the module's requires, and an edit to the
--- module it probes moves the key of the module that probes it.
local function test_finds_a_pcall_of_require_with_a_literal_name_and_keys_it()
  local root = assert(write_fixture("pcall-require", {
    ["main.tl"] = "local record Main\n  found: boolean\nend\nlocal found, _ = pcall(require, \"probed\")\n" ..
      "local main: Main = { found = found }\nreturn main\n",
    ["probed.tl"] = valued(1),
  }))
  local requires, trouble = requires_of_fixture(root, "main")
  assert(requires ~= nil, "compile failed: " .. tostring(trouble))
  assert(#requires == 1 and requires[1] == "probed", "got: " .. table.concat(requires, ", "))
  local function key_of(result: importer.Result, path: string): string
    for _, m in ipairs(result.modules) do
      if m.path == path then return (m.key or "") .. " " .. (m.graph_key or "") end
    end
    error(path .. ": not among the modules")
  end
  local first = key_of(assert(compile_fixture(root)), "main")
  assert(Fs.write(root .. "/probed.tl", valued(2)))
  local edited = key_of(assert(compile_fixture(root)), "main")
  assert(edited ~= first, "an edit to a module probed with pcall(require, ...) kept its importer's key")
end

--- A `require` or `pcall(require, ...)` whose name is computed is refused, naming the call and what to write.
local function test_a_computed_require_is_refused_with_its_fix()
  local root = assert(write_fixture("computed-require", {
    ["main.tl"] = "local record Main\n  found: boolean\nend\nlocal name = \"probed\"\n" ..
      "local found, _ = pcall(require, name)\nlocal main: Main = { found = found }\nreturn main\n",
    ["probed.tl"] = valued(1),
  }))
  local requires, trouble = requires_of_fixture(root, "main")
  assert(requires == nil, "a computed require compiled")
  assert(trouble:find("`pcall(require, name)` names its module by an expression", 1, true) ~= nil, trouble)
  assert(trouble:find("write the module's name as a string", 1, true) ~= nil, trouble)
end

--- A file under `testdata/` is inert input, even one named as a Teal
--- test. Ordinary sources beside it still compile.
local function test_testdata_is_not_a_module_or_test_source()
  local root, write_trouble = write_fixture("testdata-classification", {
    ["suite/pass_test.tl"] = "local function test_pass() assert(true) end\n",
    ["suite/testdata/hostile_test.tl"] =
      "this is deliberately not valid Teal\n",
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local result, trouble = compile_fixture(root)
  assert(result ~= nil, "testdata entered compilation: " .. tostring(trouble))
  local found = false
  for _, module in ipairs(result.modules) do
    assert(module.file ~= "suite/testdata/hostile_test.tl",
      "testdata was classified as source")
    if module.file == "suite/pass_test.tl" and module.kind == "test" then
      found = true
    end
  end
  assert(found, "ordinary sibling test was not classified")
end

--- The tool's hash over a tree, staged fresh: each call is its own
--- run, so a file that has gone since the last call is gone from the
--- fingerprints too.
local function boot_hash_of(root: string): string
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local fingerprint = assert(identity.record_fingerprint(handle.db, handle.root))
  work.close(handle)
  return fingerprint.boot
end

--- The tool's hash over what its C core is built from.
local function image_hash_of(root: string): string
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local fingerprint = assert(identity.record_fingerprint(handle.db, handle.root))
  work.close(handle)
  return fingerprint.image
end

--- A Teal test beside the core's C is not a core input, nor one of the
--- tool's: no binary carries it, so an edit to one rebuilds neither.
local function test_image_hash_leaves_out_teal_under_core()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-image-hash-"))
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/core/main.c", "original"))
  assert(Fs.write(root .. "/core/main_test.tl", "original"))
  local image = image_hash_of(root)
  local boot = boot_hash_of(root)
  assert(Fs.write(root .. "/core/main_test.tl", "changed"))
  assert(image_hash_of(root) == image, "a Teal test moved the core's hash")
  assert(boot_hash_of(root) == boot, "a Teal test moved the tool's hash")
  assert(Fs.write(root .. "/core/main.c", "changed"))
  assert(image_hash_of(root) ~= image, "the core's C did not move its hash")
end

--- A rebuild lays the artifact out with the running tool's own
--- build/artifact.tl, so an edit to it boots, as one to the launcher does.
local function test_image_hash_covers_the_artifact_layout()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-image-artifact-"))
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/build/artifact.tl", "return {}\n"))
  assert(Fs.write(root .. "/build/launcher.tl", "return {}\n"))
  local image = image_hash_of(root)
  assert(Fs.write(root .. "/build/artifact.tl", "return { changed = true }\n"))
  local moved = image_hash_of(root)
  assert(moved ~= image, "an edit to build/artifact.tl did not move the core's hash")
  assert(Fs.write(root .. "/build/launcher.tl", "return { changed = true }\n"))
  assert(image_hash_of(root) ~= moved, "an edit to build/launcher.tl did not move the core's hash")
end

--- The compiler identity is what turns source into bytecode: the Teal
--- compiler's and Lua's pins and patches, and the build's own modules a
--- compile or a parse runs ([`identity.compiler_modules`]). The standard
--- library the importer runs on is not in it, so an edit there does not
--- recompile the world. Nor is [`cosmic.removed`], though a refusal
--- quotes it: the names it strips from the checker, which
--- decide what a compile accepts, it spells itself, and no compile keeps
--- a refusal. A stdlib-simplifying change adds to the catalog on almost
--- every edit, and must not compile every module again for it.
local function test_compiler_identity_follows_the_compiler_not_the_stdlib()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-identity-"))
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic",
      "patch/lua", "vendor/lua", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/vendor/lua/PIN", "version 1"))
  assert(Fs.write(root .. "/cosmic/fs.tl", "local record Fs\nend\nreturn Fs\n"))
  assert(Fs.write(root .. "/cosmic/removed.tl",
    "local record Removed\nend\nreturn Removed\n"))
  assert(Fs.write(root .. "/build/withheld.tl",
    "local Fs = require(\"cosmic.fs\")\nlocal Removed = require(\"cosmic.removed\")\n" ..
      "local record withheld\nend\nwithheld.fs = Fs\nwithheld.removed = Removed\nreturn withheld\n"))
  assert(Fs.write(root .. "/build/importer.tl",
    "local withheld = require(\"build.withheld\")\nlocal record importer\nend\n" ..
      "importer.withheld = withheld\nreturn importer\n"))
  local function identities(): {string}
    local handle = assert(work.open(root))
    assert(work.stage(handle, true))
    assert(importer.derive(handle, true))
    local found = assert(identity.record_identities(handle.db))
    work.close(handle)
    return { found.compiler, found.runtime_basis }
  end
  local original = identities()
  assert(identities()[1] == original[1], "a second open of the same tree moved the identity")
  assert(Fs.write(root .. "/cosmic/fs.tl", "local record Fs\nend\nreturn Fs\n-- edited\n"))
  local after_stdlib = identities()
  assert(after_stdlib[1] == original[1], "a stdlib edit moved the compiler identity")
  assert(after_stdlib[2] == original[2], "a stdlib edit moved the runtime basis")
  assert(Fs.write(root .. "/cosmic/removed.tl",
    "local record Removed\nend\nreturn Removed\n-- edited\n"))
  local after_removed = identities()
  assert(after_removed[1] == original[1], "an edit to cosmic.removed moved the compiler identity")
  assert(after_removed[2] == original[2], "an edit to cosmic.removed moved the runtime basis")
  assert(Fs.write(root .. "/build/withheld.tl",
    "local Fs = require(\"cosmic.fs\")\nlocal Removed = require(\"cosmic.removed\")\n" ..
      "local record withheld\nend\nwithheld.fs = Fs\nwithheld.removed = Removed\n" ..
      "withheld.globals = { \"io\" }\nreturn withheld\n"))
  local after_withheld = identities()
  assert(after_withheld[1] ~= original[1],
    "an edit to the names the checker strips did not move the compiler identity")
end

--- The declarations the new checker types a program against, [`lang/stdlib.d.tl`] and [`lang/prelude.d.tl`], are carried as
--- text, so an edit to one moves what every compile is a function of and the tool's boot hash, but not the core's image: no
--- boot compiles them. They are the new grammar's, so the fork, which compiles every declaration file, never reads them.
local function test_compiler_identity_follows_the_new_checkers_declarations()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-identity-new-declarations-"))
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "lang", "patch/lua", "vendor/lua", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/vendor/lua/PIN", "version 1"))
  assert(Fs.write(root .. "/lang/prelude.d.tl", "do\nend\n"))
  assert(Fs.write(root .. "/lang/stdlib.d.tl", "do\n   global record Seen\n      n?: integer\n   end\nend\n"))
  assert(Fs.write(root .. "/build/withheld.tl", "local record withheld\nend\nreturn withheld\n"))
  assert(Fs.write(root .. "/build/importer.tl",
    "local withheld = require(\"build.withheld\")\nlocal record importer\nend\n" ..
      "importer.withheld = withheld\nreturn importer\n"))
  local function hashes(): {string}, boolean
    local handle = assert(work.open(root))
    assert(work.stage(handle, true))
    assert(importer.derive(handle, true))
    local found = assert(identity.record_identities(handle.db))
    local fingerprint = assert(identity.record_fingerprint(handle.db, handle.root))
    local rows = assert(Sqlite.text_rows(handle.db, "SELECT count(*) FROM files WHERE path GLOB 'lang/*'"))
    work.close(handle)
    return { found.compiler, found.runtime_basis, fingerprint.image, fingerprint.boot }, assert(rows[1]):text(1) == "0"
  end
  local original, none_is_input = hashes()
  assert(none_is_input, "a declaration file of the new checker is an input of the build")
  for _, file in ipairs({ "lang/stdlib.d.tl", "lang/prelude.d.tl" }) do
    local before = hashes()
    assert(Fs.write(root .. "/" .. file, "do\n   global record Other\n   end\nend\n"))
    local after = hashes()
    assert(after[1] ~= before[1], "an edit to " .. file .. " did not move the compiler identity")
    assert(after[2] ~= before[2], "an edit to " .. file .. " did not move the runtime basis")
    assert(after[4] ~= before[4], "an edit to " .. file .. " did not move the boot hash")
    assert(after[3] == before[3], "an edit to " .. file .. " moved the image hash, which no boot is needed for")
  end
  assert(hashes()[1] ~= original[1])
end

--- An edit to anything the tool is built from moves its boot hash: its
--- Teal, examples and C, build.zig, bin/zig and their pins. A vendored
--- tree counts through its pin and the records that patch it: it is
--- never edited in place, so its contents are not walked.
local function test_boot_hash_tracks_embedded_inputs()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-boot-hash-"))
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "lang", "vendor/lua", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  local paths = {
    "build/main.tl", "core/main.c", "cosmic/example.tl",
    "cosmic/example_example.tl", "lang/check.tl", "vendor/lua/PIN",
    "cmd/cosmic/main.tl", "build.zig", "build.zig.zon", "bin/zig", "bin/zig.pin",
  }
  for _, path in ipairs(paths) do
    assert(Fs.write(root .. "/" .. path, "original"))
  end
  local original = assert(boot_hash_of(root))
  assert(boot_hash_of(root) == original)
  for _, path in ipairs(paths) do
    assert(Fs.write(root .. "/" .. path, "changed"))
    assert(boot_hash_of(root) ~= original, "missed changed input: " .. path)
    assert(Fs.write(root .. "/" .. path, "original"))
    assert(boot_hash_of(root) == original)
  end
  -- Generated output must not make a freshly built tool stale.
  assert(Fs.mkdirs(root .. "/o"))
  assert(Fs.write(root .. "/o/output", "generated"))
  assert(boot_hash_of(root) == original)
  assert(Fs.write(root .. "/cosmic/added.tl", "new module"))
  assert(boot_hash_of(root) ~= original, "missed added module")
  assert(Fs.remove(root .. "/cosmic/added.tl"))
  assert(boot_hash_of(root) == original)
  -- A vendored tree's own files are reached through its pin, never
  -- edited in place, so a stray write there is not an input.
  assert(Fs.write(root .. "/vendor/lua/lua.c", "edited in place"))
  assert(boot_hash_of(root) == original, "walked into a vendored tree")
end

--- A Teal test is none of what the tool is made of: no binary carries
--- one ([`build.writer`]'s `carried`), so an edit to one, a new one or one
--- removed leaves the tool fresh, whichever of the tool's trees holds
--- it, and a module beside it still moves the hash. The test is staged
--- as an input all the same, for `cosmic test` to build.
local function test_boot_hash_leaves_out_tests()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-boot-hash-tests-"))
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  local tests = { "build/main_test.tl", "core/main_test.tl", "cosmic/example_test.tl",
    "cmd/cosmic/main_test.tl" }
  assert(Fs.write(root .. "/cosmic/example.tl", "original"))
  for _, path in ipairs(tests) do
    assert(Fs.write(root .. "/" .. path, "original"))
  end
  local original = boot_hash_of(root)
  for _, path in ipairs(tests) do
    assert(Fs.write(root .. "/" .. path, "changed"))
    assert(boot_hash_of(root) == original, "a test moved the tool's hash: " .. path)
  end
  assert(Fs.write(root .. "/cosmic/added_test.tl", "new test"))
  assert(boot_hash_of(root) == original, "a new test moved the tool's hash")
  assert(Fs.remove(root .. "/cosmic/example_test.tl"))
  assert(boot_hash_of(root) == original, "a removed test moved the tool's hash")
  assert(Fs.write(root .. "/cosmic/example.tl", "changed"))
  assert(boot_hash_of(root) ~= original, "the module beside the tests did not move it")
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local rows = assert(Sqlite.text_rows(handle.db,
    "SELECT (SELECT count(*) FROM tool WHERE path GLOB '*_test.tl'), " ..
      "(SELECT count(*) FROM files WHERE path = 'cosmic/added_test.tl')"))
  work.close(handle)
  assert(rows[1]:text(1) == "0", "the tool's rows hold a test")
  assert(rows[1]:text(2) == "1", "a test was not staged as an input")
end

--- A tree that is not cosmic's own can `require` the standard library
--- and be checked against it: the binary carries every `cosmic.*`
--- source and declaration, and the checker is answered from those
--- rows for a name the tree itself does not hold.
local function test_types_the_standard_library_from_the_binary()
  local root, write_trouble = write_fixture("stdlib", {
    ["main.tl"] = table.concat({
      'local Fs = require("cosmic.fs")',
      "local function exists(path: string): boolean",
      "  local answer, trouble = Fs.exists(path)",
      "  assert(answer ~= nil, trouble)",
      "  return answer",
      "end",
      "return exists",
      "",
    }, "\n"),
  })
  assert(root ~= nil, "could not write fixture: " .. tostring(write_trouble))
  local requires, trouble = requires_of_fixture(root, "main")
  assert(requires ~= nil, "compile failed: " .. tostring(trouble))
  assert(#requires == 1 and requires[1] == "cosmic.fs",
    "expected cosmic.fs, got " .. table.concat(requires, ", "))
end

--- A function held in a nested record's field is used wherever a value
--- the checker typed as that record reads it, by `:` or by `.`, whatever
--- the value is named -- including a record a `.d.tl` declares. An
--- assignment to the field defines it rather than using it, and a
--- module member reached through its alias is still found by name.
local function test_uses_of_a_record_field_follow_the_value_s_type()
  local root = assert(write_fixture("record-field-uses", {
    ["shapes.tl"] = table.concat({
      "local record Shapes",
      "  record Box",
      "    mut width: integer",
      "    area: function(Box): integer",
      "  end",
      "  box: function(integer): Shapes.Box",
      "end",
      "local function area(self: Shapes.Box): integer",
      "  return self.width * self.width",
      "end",
      "function Shapes.box(width: integer): Shapes.Box",
      "  return { width = width, area = area }",
      "end",
      "return Shapes",
      "",
    }, "\n"),
    ["counter.d.tl"] = table.concat({
      "local record Counter",
      "  record Tally",
      "    bump: function(Tally, integer)",
      "  end",
      "end",
      "return Counter",
      "",
    }, "\n"),
    ["main.tl"] = table.concat({
      'local Shapes = require("shapes")',
      'local type Counter = require("counter")',
      "local record Main",
      "end",
      "function Main.run(t: Counter.Tally): integer",
      "  local b = Shapes.box(2)",
      "  local first = b:area()",
      "  local read = b.area",
      "  b.width = 3",
      "  t:bump(first)",
      "  return read(b)",
      "end",
      "return Main",
      "",
    }, "\n"),
  }))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local result = compiled_clean(handle)
  assert(writer.write_result(handle, handle.dir .. "/cosmic.db", result))
  local shipped = assert(Sqlite.open(handle.dir .. "/cosmic.db"))
  local rows = assert(Sqlite.text_rows(shipped,
    "SELECT module, symbol, line FROM uses WHERE from_module = 'main' " ..
      "ORDER BY line, module, symbol"))
  local got: mut {string} = {}
  for _, row in ipairs(rows) do
    got[#got + 1] = row:text(3) .. " " .. row:text(1) .. " " .. row:text(2)
  end
  local want = "6 shapes box, 7 shapes Box.area, 8 shapes Box.area, " ..
    "10 counter Tally.bump"
  assert(table.concat(got, ", ") == want, table.concat(got, ", "))
  local view = assert(docs.view({ shipped }))
  for _, query in ipairs({ "Shapes.Box.area", "Box.area", "area" }) do
    local uses = assert(docs.uses(view, query))
    local lines: mut {string} = {}
    for _, use in ipairs(uses) do
      lines[#lines + 1] = use.from_file .. ":" .. use.line
    end
    assert(table.concat(lines, " ") == "main.tl:7 main.tl:8",
      query .. ": " .. table.concat(lines, " "))
  end
  local tally = assert(docs.uses(view, "Counter.Tally.bump"))
  assert(#tally == 1 and tally[1].line == 10, tostring(#tally))
  assert(shipped:close())
  work.close(handle)
end

--- The compiler identity closes over what its roots require
--- ([`identity.compiler_modules`]), so it is the same whether the working
--- database is fresh or has parsed the tree before -- a boot on an empty
--- `o/` must key its modules exactly as a warm one does, or the two
--- ship different databases. A helper only build.importer requires is
--- not in it: the importer is outside the semantic closure.
local function test_compiler_identity_is_the_same_on_a_fresh_database()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-fresh-identity-"))
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic",
      "patch/lua", "vendor/lua", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/vendor/lua/PIN", "version 1"))
  assert(Fs.write(root .. "/build/helper.tl",
    "local record helper\nend\nreturn helper\n"))
  assert(Fs.write(root .. "/build/other.tl",
    "local record other\nend\nreturn other\n"))
  assert(Fs.write(root .. "/build/withheld.tl",
    "local helper = require(\"build.helper\")\nlocal record withheld\nend\n" ..
      "withheld.helper = helper\nreturn withheld\n"))
  assert(Fs.write(root .. "/build/importer.tl",
    "local withheld = require(\"build.withheld\")\nlocal other = require(\"build.other\")\n" ..
      "local record importer\nend\nimporter.withheld = withheld\nimporter.other = other\n" ..
      "return importer\n"))
  local function compiler_identity(): string
    local handle = assert(work.open(root))
    assert(work.stage(handle, true))
    assert(importer.derive(handle, true))
    local found = assert(identity.record_identities(handle.db))
    work.close(handle)
    return found.compiler
  end
  local fresh = compiler_identity()
  local warm = compiler_identity()
  assert(warm == fresh, "a second open of the same tree moved the compiler identity")
  assert(Fs.write(root .. "/build/other.tl",
    "local record other\nend\nreturn other\n-- edited\n"))
  assert(compiler_identity() == fresh,
    "an edit to a module only build.importer requires moved the compiler identity")
  assert(Fs.write(root .. "/build/helper.tl",
    "local record helper\nend\nreturn helper\n-- edited\n"))
  assert(compiler_identity() ~= fresh,
    "an edit to a module the compiler requires did not move its identity")
end

--- The writer identity is every module [`build.writer`] reaches, the
--- standard library's included, but what a root requires that
--- [`identity.writer_modules`] leaves out: an edit to a module it requires
--- moves it, and an edit to build.importer, which build.writer requires
--- for a type alone, or to a module only the importer requires, does
--- not. It is what a projection is signed with ([`build.writer`]), so a
--- tool whose writer stands writes what the tree's own would.
local function test_writer_identity_follows_the_writer_closure()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-writer-identity-"))
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "lang",
      "patch/lua", "vendor/lua", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/vendor/lua/PIN", "version 1"))
  assert(Fs.write(root .. "/build/schema.tl",
    "local record schema\nend\nreturn schema\n"))
  assert(Fs.write(root .. "/build/helper.tl",
    "local record helper\nend\nreturn helper\n"))
  assert(Fs.write(root .. "/cosmic/codec.tl",
    "local record codec\nend\nreturn codec\n"))
  assert(Fs.write(root .. "/build/work.tl",
    "local record work\nend\nreturn work\n"))
  assert(Fs.write(root .. "/build/identity.tl",
    "local record identity\nend\nreturn identity\n"))
  assert(Fs.write(root .. "/build/writer.tl",
    "local work = require(\"build.work\")\n" ..
      "local schema = require(\"build.schema\")\n" ..
      "local importer = require(\"build.importer\")\n" ..
      "local codec = require(\"cosmic.codec\")\nlocal record writer\nend\n" ..
      "writer.work = work\nwriter.schema = schema\nwriter.importer = importer\nwriter.codec = codec\n" ..
      "return writer\n"))
  assert(Fs.write(root .. "/build/importer.tl",
    "local helper = require(\"build.helper\")\nlocal record importer\nend\n" ..
      "importer.helper = helper\nreturn importer\n"))
  local function writer_identity(): string
    local handle = assert(work.open(root))
    assert(work.stage(handle, true))
    assert(importer.derive(handle, true))
    local found = assert(identity.record_identities(handle.db))
    work.close(handle)
    return found.writer
  end
  local fresh = writer_identity()
  assert(writer_identity() == fresh, "a second open of the same tree moved the writer identity")
  assert(Fs.write(root .. "/build/work.tl",
    "local record work\nend\nreturn work\n-- edited\n"))
  assert(writer_identity() == fresh, "an edit to staging moved the writer identity")
  assert(Fs.write(root .. "/build/importer.tl",
    "local helper = require(\"build.helper\")\nlocal record importer\nend\n" ..
      "importer.helper = helper\nreturn importer\n-- edited\n"))
  assert(writer_identity() == fresh, "an edit to build.importer moved the writer identity")
  assert(Fs.write(root .. "/build/helper.tl",
    "local record helper\nend\nreturn helper\n-- edited\n"))
  assert(writer_identity() == fresh,
    "an edit to a module only build.importer requires moved the writer identity")
  assert(Fs.write(root .. "/build/schema.tl",
    "local record schema\nend\nreturn schema\n-- edited\n"))
  local after_build = writer_identity()
  assert(after_build ~= fresh,
    "an edit to a module the writer requires did not move its identity")
  assert(Fs.write(root .. "/cosmic/codec.tl",
    "local record codec\nend\nreturn codec\n-- edited\n"))
  assert(writer_identity() ~= after_build,
    "an edit to a standard library module the writer requires did not move its identity")
  local before_definition = writer_identity()
  assert(Fs.write(root .. "/build/identity.tl",
    "local record identity\nend\nreturn identity\n-- edited\n"))
  assert(writer_identity() ~= before_definition,
    "an edit to the fingerprint and identity definitions did not move the writer identity")

  assert(Fs.write(root .. "/build/schema.tl",
    "local work = require(\"build.work\")\nlocal record schema\nend\n" ..
      "schema.work = work\nreturn schema\n"))
  local through_schema = writer_identity()
  assert(Fs.write(root .. "/build/work.tl",
    "local record work\nend\nreturn work\n-- edited again\n"))
  assert(writer_identity() ~= through_schema,
    "the writer's root exclusion also excluded a dependency reached through its schema")

end

--- The Lua a module compiles to keeps the line numbers of the Teal it
--- came from: an uncaught error names a Lua line, and the runtime
--- reads that line straight out of the Teal source, so the two must
--- agree on every line a declaration sits on -- however a doc comment
--- or a wrapped signature moved things above it.
local function test_generated_lua_keeps_teal_line_numbers()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-lines-"))
  assert(Fs.mkdirs(root))
  local source = table.concat({
    "--- A module whose lines are known.",
    "---",
    "--- Three lines of comment, then a blank.",
    "",
    "local record lines",
    "end",
    "",
    "--- Adds, on line eight.",
    "function lines.add(a: integer,",
    "                   b: integer): integer",
    "  return a + b",
    "end",
    "",
    "function lines.fail(): boolean, string",
    "  return false, \"line fifteen fails\"",
    "end",
    "",
    "return lines",
  }, "\n") .. "\n"
  assert(Fs.write(root .. "/lines.tl", source))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local result = compiled_clean(handle)
  local lua: string? = nil
  for _, m in ipairs(result.modules) do
    if m.path == "lines" then
      lua = m.lua
    end
  end
  work.close(handle)
  assert(lua ~= nil, "lines did not compile")
  local generated: mut {string} = {}
  for line in String.lines(lua) do
    generated[#generated + 1] = line
  end
  assert(generated[9]:find("function lines.add", 1, true), "line 9: " .. generated[9])
  assert(generated[11]:find("return a + b", 1, true), "line 11: " .. generated[11])
  assert(generated[15]:find("line fifteen fails", 1, true), "line 15: " .. generated[15])
end

--- What a parse derived -- docs, requires, tests, the catalog -- is
--- keyed by the source it came from and found again while that source
--- stands. It is right only while the code that derived it stands too:
--- when the analyzer's identity moves, every derived row is forgotten
--- and every source is seen again, so an extractor that learns to see
--- something new sees it in old sources as well. The analyzer is the
--- code that ran, not the tree: a tool edited anywhere else keeps what
--- was derived.
local function test_a_changed_analyzer_forgets_what_it_derived()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-analyzer-"))
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "lang",
      "patch/lua", "vendor/lua", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/vendor/lua/PIN", "version 1"))
  assert(Fs.write(root .. "/cosmic/thing.tl",
    "--- A thing.\nlocal record Thing\nend\nreturn Thing\n"))
  local function derived_with(boot_hash: string, plant: boolean, analyzer?: string): integer
    local handle = assert(work.open(root))
    assert(work.stage(handle, true))
    assert(Sqlite.run(handle.db,
      "INSERT OR REPLACE INTO meta (key, value) VALUES ('boot_hash', ?1)",
      { { text = boot_hash } }))
    if analyzer ~= nil then
      assert(Sqlite.run(handle.db,
        "INSERT OR REPLACE INTO meta (key, value) VALUES ('analyzer', ?1)",
        { { text = analyzer } }))
    end
    if plant then
      -- Under the real source's hash, so only the analyzer sweep, and
      -- not the ordinary collection of rows no input refers to, can
      -- remove it.
      assert(Sqlite.run(handle.db,
        "INSERT OR REPLACE INTO docs (source_hash, ordinal, symbol, source_symbol, " ..
          "exported, kind, signature, text, line) SELECT source_hash, 99, " ..
          "'Planted', 'Planted', 0, 'record', '', '', 1 " ..
          "FROM inputs WHERE path = 'cosmic.thing'"))
    end
    assert(importer.derive(handle, true))
    local rows = assert(Sqlite.text_rows(handle.db,
      "SELECT count(*) FROM docs WHERE symbol = 'Planted'"))
    work.close(handle)
    return math.tointeger(tonumber(rows[1]:text(1))) or -1
  end
  assert(derived_with("tool-one", false) == 0)
  -- The same analyzer: a planted row survives, as any derived row does.
  assert(derived_with("tool-one", true) == 1, "the same analyzer forgot its rows")
  -- The tool changed, but not the code that analyzes: nothing is re-derived.
  assert(derived_with("tool-two", true) == 1, "an edit outside the analyzer forgot its rows")
  -- Derived by another analyzer: a stale tool rebuilding itself derives
  -- with its own, older code, and its rows are not this binary's.
  assert(derived_with("tool-two", true, "an older analyzer") == 0,
    "rows another analyzer derived were kept")
end

--- `ci/` is the pinned CI driver's own project, walked and built by
--- the pinned host with cwd `ci/`, never by cosmic's own build: staging
--- cosmic's own tree must record nothing under `ci/`, and deriving
--- inputs from what was staged must yield no module from there either.
local function test_own_tree_staging_skips_the_ci_driver_tree()
  local root = assert(Fs.mkdtemp("cosmic-importer-test-skip-ci-"))
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "lang",
      "patch/lua", "vendor/lua", "bin",
      "ci/cosmic_ci", "ci/o" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  assert(Fs.write(root .. "/vendor/lua/PIN", "version 1"))
  assert(Fs.write(root .. "/build/importer.tl",
    "local record importer\nend\nreturn importer\n"))
  assert(Fs.write(root .. "/ci/cosmic_ci/probe_test.tl",
    "local function test_probe()\n  assert(true)\nend\n"))
  assert(Fs.write(root .. "/ci/o/build.db", "not a real sqlite database"))

  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local staged = assert(Sqlite.text_rows(handle.db,
    "SELECT path FROM files WHERE path GLOB 'ci/*'"))
  assert(#staged == 0, "staging recorded a file under ci/: " .. tostring(staged[1]))

  assert(importer.derive(handle, true))
  local inputs = assert(Sqlite.text_rows(handle.db,
    "SELECT file FROM inputs WHERE file GLOB 'ci/*'"))
  assert(#inputs == 0, "derived inputs included a module under ci/: " ..
      tostring(inputs[1]))
  work.close(handle)
end

--- [`build.syntax_contracts`] holds a module's exports to rule 10 as it compiles,
--- so an exported function answering a tuple never does.
local function test_compile_rejects_an_exported_tuple()
  local root = assert(write_fixture("api-contract", {
    ["build/importer.tl"] = "local record Stub end\nreturn Stub\n",
    -- A core/ beside build/importer.tl makes the tree cosmic's own
    -- ([`build.tree.is_own`]), whose modules the contracts hold.
    ["core/syscalls.h"] = table.concat({
      "/**",
      " * --- Reads bytes.",
      " * ---@param fd integer descriptor",
      " * ---@return string|nil data bytes",
      " * ---@return string error failure",
      " * ---@return integer errno number",
      " */",
      "COSMIC_SYSCALL(read, 1);",
    }, "\n") .. "\n",
    ["cosmic/bad.tl"] = table.concat({
      "local record Bad end",
      "function Bad.split(): string, string",
      "  return 'a', 'b'",
      "end",
      "return Bad",
    }, "\n") .. "\n",
  }))
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local result, trouble = importer.compile(handle, "api-contract-test")
  work.close(handle)
  assert(result ~= nil, trouble)
  local refused = table.concat(result.refused, "\n")
  assert(refused:find("Bad.split: an exported function answers one result", 1, true), refused)
end

--- The error-slot discipline ([`build.syntax_contracts`]) is checked beside the
--- checker as cosmic's own modules compile: a dropped reason refuses
--- the module, whatever the compiled cache holds.
local function test_compile_rejects_a_dropped_error_slot()
  local root = assert(write_fixture("error-slot", {
    ["build/importer.tl"] = "local record Stub end\nreturn Stub\n",
    ["core/syscalls.h"] = table.concat({
      "/**",
      " * --- Reads bytes.",
      " * ---@param fd integer descriptor",
      " * ---@return string|nil data bytes",
      " * ---@return string error failure",
      " * ---@return integer errno number",
      " */",
      "COSMIC_SYSCALL(read, 1);",
    }, "\n") .. "\n",
    ["cosmic/dropped.tl"] = table.concat({
      "local record Dropped end",
      "local function get(): integer?, string return nil, 'none' end",
      "function Dropped.value(): integer",
      "  return get() or 0",
      "end",
      "return Dropped",
    }, "\n") .. "\n",
  }))
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local result, trouble = importer.compile(handle, "error-slot-test")
  work.close(handle)
  assert(result ~= nil, trouble)
  local refused = table.concat(result.refused, "\n")
  assert(refused:find("cosmic/dropped.tl:4: get: its error slot is dropped", 1, true), refused)
end

--- [`cosmic.sys`]'s documentation points into the header it is generated
--- from, not into the generated source: each row's line is its
--- declaration's own line in core/syscalls.h, through the build and
--- into the shipped database, along with the worked examples that pair
--- with it though it is only a declaration.
local function test_generated_syscall_docs_carry_header_lines()
  local root = assert(write_fixture("syscall-lines", {
    ["build/importer.tl"] = "local record Stub end\nreturn Stub\n",
    ["core/syscalls.h"] = table.concat({
      "/*",
      " * --- Reads bytes.",
      " * ---@param fd integer descriptor",
      " * ---@return string|nil data bytes",
      " * ---@return string error failure",
      " * ---@return integer errno number",
      " */",
      "COSMIC_SYSCALL(read, 1);",
      "",
      "/*",
      " * ---@class Constants",
      " * ---@field O_RDONLY integer open for reading",
      " */",
      "COSMIC_CONSTANT(O_RDONLY)",
    }, "\n") .. "\n",
    ["cosmic/sys_example.tl"] = table.concat({
      'local syscalls = require("cosmic.sys")',
      "local record Example",
      "end",
      "function Example.read()",
      "  syscalls.read(0)",
      "end",
      "return Example",
    }, "\n") .. "\n",
  }))
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local result = assert(importer.compile(handle, "syscall-lines-test"))
  assert(writer.write_result(handle, root .. "/out.db", result))
  work.close(handle)

  local out = assert(Sqlite.open(root .. "/out.db"))
  local rows = assert(Sqlite.text_rows(out,
    "SELECT symbol, file, line, text FROM docs WHERE module = 'cosmic.sys' " ..
      "AND symbol IN ('read', 'O_RDONLY') ORDER BY symbol"))
  local examples = assert(Sqlite.text_rows(out,
    "SELECT name FROM examples WHERE module = 'cosmic.sys'"))
  assert(out:close())
  assert(#examples == 1 and examples[1]:text(1) == "read", tostring(#examples))
  assert(#rows == 2, tostring(#rows))
  assert(rows[1]:text(1) == "O_RDONLY" and rows[1]:text(2) == "core/syscalls.h" and
      rows[1]:text(3) == "12", table.concat(rows[1]:texts(), " "))
  assert(rows[2]:text(1) == "read" and rows[2]:text(3) == "8", table.concat(rows[2]:texts(), " "))
  assert(rows[2]:text(4):find("Reads bytes.", 1, true) == 1, rows[2]:text(4))
end

--- The file of the tree's module `name`, as the build finds it: nil
--- where the tree has none.
local function tree_file_of(name: string): string?
  local base = name:gsub("%.", "/")
  for _, candidate in ipairs({ base .. ".tl", base .. "/init.tl", base .. ".d.tl" }) do
    if Fs.exists(candidate) == true then return candidate end
  end
  return nil
end

--- A tree laid out as cosmic's own is, as far as the compiler's identity
--- reaches: build.importer requiring each root and the modules it runs
--- for the rest of the build, which reach build/zig.tl as the real
--- ones do, beside the pins and patches.
local function identity_fixture(case: string): string
  local files: {string:string} = {
    ["vendor/lua/PIN"] = "version 1",
    ["patch/lua/01.txt"] = "a record",
    ["cosmic/fs.tl"] = module_requiring({}),
    ["cosmic/removed.tl"] = module_requiring({}),
    ["build/importer.tl"] = module_requiring({ "build.analysis_schema", "build.plans", "build.withheld", "build.tree",
      "build.work", "build.positions", "build.symbols", "build.caches" }),
    ["build/plans.tl"] = module_requiring({ "build.withheld", "build.bind" }),
    ["build/derivation.tl"] = module_requiring({ "build.analysis_schema", "build.cache_names", "build.bind" }),
    ["build/analysis_schema.tl"] = module_requiring({}),
    ["build/bind.tl"] = module_requiring({}),
    ["build/cache_names.tl"] = module_requiring({}),
    ["build/withheld.tl"] = module_requiring({ "cosmic.fs", "cosmic.removed", "build.withheld_helper" }),
    ["build/withheld_helper.tl"] = module_requiring({}),
    ["build/tree.tl"] = module_requiring({ "cosmic.fs" }),
    ["build/work.tl"] = module_requiring({ "build.analysis_schema", "build.todo_scan" }),
    ["build/todo_scan.tl"] = module_requiring({}),
    ["build/positions.tl"] = module_requiring({}),
    ["build/symbols.tl"] = module_requiring({}),
    ["build/caches.tl"] = module_requiring({ "cosmic.fs", "build.cache_names", "build.zig" }),
    ["build/zig.tl"] = module_requiring({ "cosmic.fs" }),
  }
  local root = assert(Fs.mkdtemp("cosmic-importer-test-" .. case .. "-"))
  for _, dir in ipairs({ "core", "cmd/cosmic", "bin" }) do
    assert(Fs.mkdirs(root .. "/" .. dir))
  end
  for name, source in pairs(files) do
    assert(Fs.mkdirs(root .. "/" .. (name:match("^(.+)/[^/]+$") or ".")))
    assert(Fs.write(root .. "/" .. name, source))
  end
  return root
end

--- The compiler's identity and the analyzer's, as a boot names them
--- over the tree at `root` once it has parsed it.
local function identities_of(root: string): {string}
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  assert(importer.derive(handle, true))
  local found = assert(identity.record_identities(handle.db))
  local analyzer = importer.analyzer_identity((assert(importer.tree_code(handle))))
  work.close(handle)
  return { found.compiler, analyzer }
end

--- Appends a comment to the file `path` under `root`.
local function edit(root: string, path: string)
  local source = assert(Fs.read(root .. "/" .. path))
  assert(Fs.write(root .. "/" .. path, source .. "-- edited\n"))
end

--- An edit to a module a compile and a parse do not run to decide what
--- they store -- the working database's staging and records, the build's
--- reports, the check that fails a whole build before any key is looked
--- up, the host's caches and build/zig.tl, which the caches reach, the
--- catalog of removed names, which only a refusal quotes, though
--- build.withheld requires it -- compiles and parses nothing again: it moves
--- neither the compiler's identity nor the analyzer's.
local function test_compiler_identity_leaves_out_what_shapes_no_compile()
  local root = identity_fixture("identity-leaves-out")
  local original = identities_of(root)
  assert(identities_of(root)[1] == original[1], "a second open moved the identity")
  for _, path in ipairs({ "build/importer.tl", "build/work.tl", "build/todo_scan.tl", "build/positions.tl",
      "build/symbols.tl", "build/caches.tl", "build/zig.tl",
      "cosmic/fs.tl", "cosmic/removed.tl" }) do
    edit(root, path)
    local after = identities_of(root)
    assert(after[1] == original[1], "an edit to " .. path .. " moved the compiler identity")
    assert(after[2] == original[2], "an edit to " .. path .. " moved the analyzer identity")
  end
end

--- An edit to a module a compile or a parse runs to decide what it
--- stores, to a module one requires, to the names the checker is
--- stripped of, or to a pin or a patch of Teal or Lua, moves both
--- identities: every compile and parse is made again.
local function test_compiler_identity_follows_what_shapes_a_compile()
  local root = identity_fixture("identity-follows")
  local seen: mut {string:string} = {}
  local original = identities_of(root)
  seen[original[1]] = "the original tree"
  for _, path in ipairs({ "build/plans.tl", "build/derivation.tl", "build/withheld.tl", "build/withheld_helper.tl",
      "build/tree.tl", "build/analysis_schema.tl", "build/bind.tl", "build/cache_names.tl", "vendor/lua/PIN",
      "patch/lua/01.txt" }) do
    local before = identities_of(root)
    edit(root, path)
    local after = identities_of(root)
    assert(seen[after[1]] == nil, "an edit to " .. path ..
        " did not move the compiler identity from that of " .. tostring(seen[after[1]]))
    assert(after[2] ~= before[2], "an edit to " .. path .. " did not move the analyzer identity")
    seen[after[1]] = path
  end
end

--- The compiler's identity holds what a compile or a parse runs to
--- decide what it stores ([`build.identity`]'s `compiler_identity`). That
--- holds only while the set is closed: every module of the tree's that
--- one of them requires is in it too, or is the standard library the
--- compile runs on.
---
--- build.importer is outside the set, but every module it calls is in
--- the set or named below with the reason it is not; a new require of it
--- fails here until it is one or the other. Every module of the
--- analyzer's but the standard library's is the compiler's too, since
--- the analyzer's identity starts from the compiler's.
---
--- A `cosmic.*` require is let through whole: it is the standard
--- library the compile runs on, which the identity leaves out. This
--- cannot tell that from data that decides what a compile accepts, so
--- none may be: [`build.withheld`] spells the globals it strips rather than
--- reading [`cosmic.removed`]'s, and requires the catalog by no name a
--- parse records, for a refusal's words alone.
---
--- The walk here reads the running binary's `imports`
--- ([`Store.requires`]), where [`identity.compiler_identity`] reads the working
--- database's `requires`, which has rows for a declaration's source
--- (`.d.tl`) too. The two reach the same modules while no module of the
--- identity has a declaration of its own but build.compiler, which
--- requires nothing.
local function test_the_compiler_modules_are_closed_under_require()
  local modules = assert(identity.compiler_modules(Store.requires))
  local covered: mut {string:boolean} = {}
  for _, name in ipairs(modules) do covered[name] = true end
  for _, name in ipairs((assert(importer.analyzer_modules()))) do
    assert(covered[name] == true or name:match("^cosmic%.") ~= nil,
      name .. " is the analyzer's but not in the compiler's identity")
  end
  for _, name in ipairs({ "build.plans", "build.derivation", "build.module", "build.withheld", "build.tree",
      "build.analysis_schema", "build.cache_names" }) do
    assert(covered[name], name .. " is not in the compiler's identity: " ..
        table.concat(modules, ", "))
  end
  --- A template's generated module is stored by derivation, so the
  --- compiler of templates is part of the identity: a change to it
  --- regenerates every template.
  for _, name in ipairs({ "cosmic.template", "cosmic.template.codegen", "cosmic.template.parse" }) do
    assert(covered[name], name .. " is not in the compiler's identity: " ..
        table.concat(modules, ", "))
  end
  assert(covered["cosmic.removed"] ~= true, "cosmic.removed is in the compiler's identity: " ..
      table.concat(modules, ", "))
  --- What build.importer requires that the compiler's identity leaves
  --- out, and why no compile or parse stores anything it decides.
  local left_out: {string:string} = {
    ["build.identity"] = "fingerprints the tool and defines its identities",
    ["build.work"] = "stages the tree and keeps the records; " ..
      "the schema a parse's rows are shaped by is build.analysis_schema's",
    ["build.positions"] = "fails a whole build before any key is looked up, and stores nothing",
    ["build.pipeline"] = "the compile with the new checker (COSMIC_GRAMMAR=new), keyed by the code that reads it " ..
      "(`Pipeline.coded`) and not by the compiler's identity, which a default run keeps",
  }
  assert(covered["build.importer"] ~= true, "cache coordination and diagnostics entered compiler identity")
  local used: mut {string:boolean} = {}
  local missing: mut {string} = {}
  local checked: mut {string} = { "build.importer" }
  for _, name in ipairs(modules) do checked[#checked + 1] = name end
  for _, name in ipairs(checked) do
    local file = tree_file_of(name)
    assert(file ~= nil, name .. " is in the compiler's identity but is no module of the tree's")
    local source = assert(Fs.read(file))
    for _, required in ipairs(requires_of(source, file)) do
      local ours = (required:match("^build%.") or required:match("^cosmic%.")) and
        not required:match("^cosmic%.internal%.") and tree_file_of(required) ~= nil
      if ours and covered[required] ~= true then
        if name == "build.importer" and left_out[required] ~= nil then
          used[required] = true
        elseif not required:match("^cosmic%.") then
          missing[#missing + 1] = name .. " requires " .. required
        end
      end
    end
  end
  assert(#missing == 0, "neither in the compiler's identity (build.identity's " ..
      "compiler_roots) nor left out of it with a reason: " .. table.concat(missing, ", "))
  for name in pairs(left_out) do
    assert(covered[name] ~= true, name .. " is named as left out of the compiler's identity, " ..
        "but is in it")
    assert(used[name], name .. " is left out of the compiler's identity, " ..
        "but build.importer no longer requires it")
  end
end

--- The writer's identity holds what decides a projection's bytes beside
--- the rows it is filled from ([`build.identity`]'s `writer_identity`): all
--- that build.writer and build.identity reach, but the few requires of
--- theirs that [`identity.writer_left_out`] names with a reason. Each one
--- named is still a require of theirs, and reaches the identity no
--- other way.
---
--- What that leaves out of build.writer's whole import closure is
--- either the compiler's (whose identity a projection's signature
--- holds) or named below with the reason no projection turns on it,
--- whether a module of the standard library or of the build. So a new
--- require of the importer's that fills a row the writer projects, or
--- that runs on a standard-library module the writer does not, fails
--- here until it is one or the other.
local function test_the_writer_modules_are_closed_under_require()
  local modules = assert(identity.writer_modules(Store.requires))
  local covered: mut {string:boolean} = {}
  for _, name in ipairs(modules) do covered[name] = true end
  for _, name in ipairs({ "build.writer", "build.identity", "build.schema", "build.bom",
      "build.roots", "build.tree", "build.bind", "build.symbols",
      "cosmic.sqlite", "cosmic.codec", "cosmic.store" }) do
    assert(covered[name], name .. " is not in the writer's identity: " ..
        table.concat(modules, ", "))
  end
  local roots_require: mut {string:boolean} = {}
  for _, root in ipairs({ "build.writer", "build.identity" }) do
    for _, name in ipairs((assert(Store.requires(root)))) do roots_require[name] = true end
  end
  for name, why in pairs(identity.writer_left_out()) do
    assert(why ~= "", name .. " is left out of the writer's identity with no reason")
    assert(roots_require[name], name .. " is left out of the writer's identity, " ..
        "but neither build.writer nor build.identity requires it")
    assert(covered[name] ~= true, name .. " is left out of the writer's identity, but is in it")
  end
  local compiler: mut {string:boolean} = {}
  for _, name in ipairs((assert(identity.compiler_modules(Store.requires)))) do
    compiler[name] = true
  end
  --- What build.writer's closure reaches that neither identity holds,
  --- and why no projection's bytes turn on it.
  local neither: mut {string:string} = {
    ["build.work"] = "stages rows and owns transactions and history",
    ["build.link_files"] = "stages prose links, whose rows the projection holds",
    ["build.c_tokens"] = "reads C comments for those staged links",
    ["build.importer"] = "coordinates semantic operations and cache transport, and renders diagnostics",
    ["build.grammar_mode"] = "names the grammar a build reads (COSMIC_GRAMMAR), which only the new grammar's compile consults",
    ["build.positions"] = "fails a whole build before any key is looked up, and stores nothing",
    ["build.todo_scan"] = "fills the TODO tables, which no projection carries",
    ["build.patch"] = "parses a patch record only for the TODO rows build.todo_scan " ..
      "fills, which no projection carries",
  }
  --- What [`build.writer`] reaches, without going on from the modules named in `stop`.
  local function reach(stop: {string:boolean}): {string:boolean}
    local seen: mut {string:boolean} = {}
    local pending: mut {string} = { "build.writer" }
    while #pending > 0 do
      local name = table.remove(pending)
      if seen[name] == nil then
        seen[name] = true
        if stop[name] == nil then
          for _, required in ipairs((assert(Store.requires(name)))) do
            pending[#pending + 1] = required
          end
        end
      end
    end
    return seen
  end
  local reached = reach({})
  -- The new grammar's compile (`COSMIC_GRAMMAR=new`, build.pipeline and what it reads) runs only where the build is asked for
  -- it, and its output is keyed apart from the compiler's by [`Pipeline.coded`] over those sources; no projection of the
  -- default compile turns on them.
  local through_pipeline = reach({ ["build.pipeline"] = true })
  neither["build.pipeline"] = "compiles in the new grammar only when asked, its output keyed by Pipeline.coded over its own closure"
  local only_pipeline: mut {string:boolean} = {}
  for name in pairs(reached) do
    if through_pipeline[name] == nil then
      only_pipeline[name] = true
    end
  end
  local unclassified: mut {string} = {}
  local used: mut {string:boolean} = {}
  for name in pairs(reached) do
    if neither[name] ~= nil then
      used[name] = true
      assert(covered[name] ~= true and compiler[name] ~= true,
        name .. " is named as in neither identity, but is in one")
    elseif only_pipeline[name] == true or name:sub(1, 5) == "lang." then
      -- The new checker's own modules: the code a compile and a parse are keyed by is [`Pipeline.coded`] over them.
      used[name] = true
    elseif covered[name] ~= true and compiler[name] ~= true then
      unclassified[#unclassified + 1] = name
    end
  end
  table.sort(unclassified)
  assert(#unclassified == 0, "build.writer reaches, in neither the writer's identity " ..
      "(build.identity's writer_roots) nor the compiler's, with no reason: " ..
      table.concat(unclassified, ", "))
  for name in pairs(neither) do
    assert(used[name], name .. " is named as in neither identity, " ..
        "but build.writer no longer reaches it")
  end
end

--- What a source parses to is decided by [`importer.analyzer_modules`] and
--- nothing else in the tool, so an edit anywhere else reparses only what
--- it edited. That holds only while the set is closed: every module of
--- the tree's that one of them requires, as a parse of its source finds
--- it, is in it too -- including a module only reached through another
--- ([`build.syntax_match`]), and never one the importer alone reaches
--- ([`build.test`]). No semantic module has an exception. The importer
--- coordinates them from outside the closure. A declaration of a C binding (`cosmic.internal.*`) is
--- types over the core, not analysis.
local function test_the_analyzer_modules_are_closed_under_require()
  local modules = assert(importer.analyzer_modules())
  local listed: mut {string:boolean} = {}
  for _, name in ipairs(modules) do listed[name] = true end
  assert(listed["build.derivation"] == true and listed["cosmic.string"] == true, table.concat(modules, ", "))
  assert(listed["build.importer"] ~= true and listed["build.test"] ~= true and listed["build.syntax_receivers"] ~= true,
    table.concat(modules, ", "))
  -- The readers of the new syntax tree are named by the code that reads the tree in the new mode ([`Pipeline.coded`]) and not
  -- by this set; the privacy-by-position check, which only the importer calls, is in neither.
  assert(listed["build.syntax_analyzer"] ~= true and listed["build.positions"] ~= true, table.concat(modules, ", "))
  -- The analysis schema is; the rest of the working database and the caches themselves, which reach build/zig.tl, are not.
  assert(listed["build.analysis_schema"], table.concat(modules, ", "))
  assert(listed["build.work"] ~= true and listed["build.caches"] ~= true and
      listed["build.zig"] ~= true, table.concat(modules, ", "))
  local file_of = tree_file_of
  local missing: mut {string} = {}
  for _, name in ipairs(modules) do
    local file = file_of(name)
    assert(file ~= nil, name .. " is listed but is no module of the tree's")
    assert(Store.source(name) ~= nil, name .. " has no source in the running binary, " ..
        "so the analyzer could only be named by the whole binary")
    do
      local source = assert(Fs.read(file))
      for _, required in ipairs(requires_of(source, file)) do
        local ours = (required:match("^build%.") or required:match("^cosmic%.")) and
          not required:match("^cosmic%.internal%.")
        if ours == true and listed[required] ~= true and file_of(required) ~= nil then
          missing[#missing + 1] = name .. " requires " .. required
        end
      end
    end
  end
  assert(#missing == 0, "not in importer.analyzer_modules: " .. table.concat(missing, ", "))
end

--- A stale tool rebuilding itself compiles without judging the tree by
--- its own, older build.syntax_contracts; the next judged compile judges every
--- module compiled so, rather than finding it cached.
local function test_an_unjudged_compile_is_judged_by_the_next()
  local root = assert(write_fixture("unjudged", {
    ["build/importer.tl"] = "local record Stub end\nreturn Stub\n",
    ["core/syscalls.h"] = table.concat({
      "/**",
      " * --- Reads bytes.",
      " * ---@param fd integer descriptor",
      " * ---@return string|nil data bytes",
      " * ---@return string error failure",
      " * ---@return integer errno number",
      " */",
      "COSMIC_SYSCALL(read, 1);",
    }, "\n") .. "\n",
    ["cosmic/casting.tl"] = table.concat({
      "local record Casting end",
      "local function get(): integer?, string return nil, 'none' end",
      "function Casting.value(): integer",
      "  return get() or 0",
      "end",
      "return Casting",
    }, "\n") .. "\n",
  }))
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local unjudged, unjudged_trouble = importer.compile(handle, "unjudged-test", true)
  assert(unjudged ~= nil, unjudged_trouble)
  local result, trouble = importer.compile(handle, "unjudged-test")
  work.close(handle)
  assert(result ~= nil, trouble)
  local refused = table.concat(result.refused, "\n")
  assert(refused:find("cosmic/casting.tl:4: get: its error slot is dropped", 1, true), refused)
end

--- A compile a stale tool's rebuild keeps though build.syntax_contracts
--- refuses it is that run's alone: never offered the compiles every
--- checkout shares, while the rest of the same run's are.
local function test_an_unjudged_refused_compile_is_not_shared()
  local root = assert(write_fixture("unjudged-shared", {
    ["build/importer.tl"] = "local record Stub end\nreturn Stub\n",
    ["core/syscalls.h"] = table.concat({
      "/**",
      " * --- Reads bytes.",
      " * ---@param fd integer descriptor",
      " * ---@return string|nil data bytes",
      " * ---@return string error failure",
      " * ---@return integer errno number",
      " */",
      "COSMIC_SYSCALL(read, 1);",
    }, "\n") .. "\n",
    ["cosmic/casting.tl"] = table.concat({
      "local record Casting end",
      "local function get(): integer?, string return nil, 'none' end",
      "function Casting.value(): integer",
      "  return get() or 0",
      "end",
      "return Casting",
    }, "\n") .. "\n",
    ["cosmic/clean.tl"] = "local record Clean end\nreturn Clean\n",
  }))
  local path = root .. "/cache/cache.db"
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local result, trouble = importer.compile(handle,
    "unjudged-test",
    true,
    shared_compiles.for_build({ COSMIC_BUILD_CACHE = path }))
  work.close(handle)
  assert(result ~= nil, trouble)
  local cache = assert(shared_compiles.open(path))
  local shared: mut {string:boolean} = {}
  for _, m in ipairs(result.modules) do
    local found, look_trouble = shared_compiles.look(cache,
      shared_compiles.key(assert(m.key), true, m.generated))
    assert(look_trouble == "", look_trouble)
    shared[m.path] = found ~= nil
  end
  shared_compiles.close(cache)
  assert(shared["cosmic.clean"] == true, "the passing compile was not shared")
  assert(shared["cosmic.casting"] == false, "the refused compile was shared")
end

--- A module a stale tool's rebuild compiles and its contracts pass is
--- cached as any other: the command it re-enters compiles nothing again.
local function test_a_passing_unjudged_compile_is_cached()
  local root = assert(write_fixture("unjudged-clean", {
    ["build/importer.tl"] = "local record Stub end\nreturn Stub\n",
    ["core/syscalls.h"] = table.concat({
      "/**",
      " * --- Reads bytes.",
      " * ---@param fd integer descriptor",
      " * ---@return string|nil data bytes",
      " * ---@return string error failure",
      " * ---@return integer errno number",
      " */",
      "COSMIC_SYSCALL(read, 1);",
    }, "\n") .. "\n",
    ["cosmic/clean.tl"] = table.concat({
      "local record Clean end",
      "function Clean.value(v: integer): integer",
      "  return v + 1",
      "end",
      "return Clean",
    }, "\n") .. "\n",
  }))
  local handle = assert(work.open(root))
  assert(work.stage(handle, true))
  local unjudged, unjudged_trouble = importer.compile(handle, "unjudged-test", true)
  assert(unjudged ~= nil, unjudged_trouble)
  assert(unjudged.compiled > 0, "the rebuild compiled nothing")
  local result, trouble = importer.compile(handle, "unjudged-test")
  work.close(handle)
  assert(result ~= nil, trouble)
  assert(result.compiled == 0 and result.cached == unjudged.compiled,
    result.compiled .. " compiled, " .. result.cached .. " cached")
end

--- A declaration of what a test reads holds for its own module's tests,
--- so a module that is no test is refused one, naming its line.
local HELPER_BODY <const> = "local record Helper\nend\nlocal helper: Helper = {}\nreturn helper\n"

local function test_only_a_test_module_declares_its_inputs()
  local root = assert(write_fixture("inputs-kind", {
    ["lib/helper.tl"] = "local Test = require(\"cosmic.test\")\n" ..
      "Test.policy { grants = { { path = \"data/\", letters = \"r\" } } }\n" .. HELPER_BODY,
    ["lib/helper_test.tl"] = "local helper = require(\"lib.helper\")\n" ..
      "local Test = require(\"cosmic.test\")\n" ..
      "Test.policy { grants = { { path = \"data/\", letters = \"r\" } } }\n" ..
      "local function test_x() assert(helper) end\n",
  }))
  local requires, trouble = requires_of_fixture(root, "lib.helper_test")
  assert(requires == nil, "a module no test's declared its inputs")
  assert(trouble:find("lib/helper.tl:2: test.policy: only a test or example module", 1, true),
    trouble)
  assert(Fs.write(root .. "/lib/helper.tl", HELPER_BODY))
  local again = assert(requires_of_fixture(root, "lib.helper_test"))
  assert(again[1] == "lib.helper")
end

--- A fixture whose one compile keeps record-field uses in
--- `typed_refs`, compiled once, and its working database left open.
local function compiled_with_references(case: string): work.Handle
  local root = assert(write_fixture(case, {
    ["shapes.tl"] = table.concat({
      "local record Shapes",
      "  record Box",
      "    mut width: integer",
      "  end",
      "  box: function(integer): Shapes.Box",
      "end",
      "function Shapes.box(width: integer): Shapes.Box",
      "  return { width = width }",
      "end",
      "return Shapes",
      "",
    }, "\n"),
    ["main.tl"] = table.concat({
      'local Shapes = require("shapes")',
      "local record Main",
      "  run: function(): integer",
      "end",
      "function Main.run(): integer",
      "  local b = Shapes.box(2)",
      "  b.width = 3",
      "  return b.width",
      "end",
      "return Main",
      "",
    }, "\n"),
  }))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  compiled_clean(handle)
  return handle
end

local function count_of(db: Sqlite.Handle, sql: string): integer
  local rows = assert(Sqlite.text_rows(db, sql))
  return math.tointeger(tonumber(rows[1]:text(1))) or -1
end

--- The record-field uses of a compile `compiled` has dropped go at
--- the end of the next compile, even one that drops no compile itself;
--- the uses of a compile it holds stay.
local function test_a_compile_sweeps_the_uses_of_a_vanished_compile()
  local handle = compiled_with_references("reference-prune")
  local live = count_of(handle.db,
    "SELECT count(*) FROM typed_refs WHERE key IN (SELECT key FROM compiled)")
  assert(live > 0, "the fixture kept no record-field uses")
  assert(Sqlite.run(handle.db,
    "INSERT INTO typed_refs (key, ordinal, module, member, line) " ..
      "VALUES ('no-such-compile', 1, 'shapes', 'Box.width', 3)"))
  local again = compiled_clean(handle)
  assert(again.compiled == 0, again.compiled .. " compiled on a warm run")
  assert(count_of(handle.db,
    "SELECT count(*) FROM typed_refs WHERE key = 'no-such-compile'") == 0,
    "the uses of a vanished compile were kept")
  assert(count_of(handle.db, "SELECT count(*) FROM typed_refs") == live,
    "the uses of a held compile were dropped")
  work.close(handle)
end

--- The sweep reads `compiled` once into a list rather than probing its
--- key once per `typed_refs` row: that key is the table itself, its
--- Lua and bytecode inline, and the probes cost a warm build of the
--- whole tree some 300 ms.
local function test_the_reference_sweep_reads_compiled_once()
  local handle = compiled_with_references("reference-prune-plan")
  local plan = assert(Sqlite.text_rows(handle.db,
    "EXPLAIN QUERY PLAN " .. importer.prune_references))
  work.close(handle)
  local details: mut {string} = {}
  for _, row in ipairs(plan) do
    details[#details + 1] = row:text(4)
  end
  local said = table.concat(details, "; ")
  assert(not said:find("IN-OPERATOR", 1, true), said)
  assert(said:find("LIST SUBQUERY", 1, true), said)
end

--- A shared record must not bring code generation into a position or
--- input-declaration reader's import closure.
local function test_the_module_shape_does_not_reach_the_plans_or_the_readers()
  local seen: mut {string:boolean} = {}
  local pending: mut {string} = { "build.positions", "build.test_inputs" }
  while #pending > 0 do
    local name = table.remove(pending)
    if seen[name] ~= true then
      seen[name] = true
      for _, required in ipairs((assert(Store.requires(name)))) do
        pending[#pending + 1] = required
      end
    end
  end
  assert(seen["build.module"], "position and input readers lost their shared module shape")
  for _, name in ipairs({ "build.plans", "build.syntax_contracts", "build.syntax_receivers" }) do
    assert(seen[name] ~= true, "the shared module shape pulled in " .. name)
  end
end
