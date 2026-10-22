--- The tests of [`build.tree_program`], the program the pins are measured over and the build's own pipeline checks against: which files
--- are modules, the globals, the bindings of C, and the sources the build writes from other files.
local Driver = require("build.driver")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local TreeProgram = require("build.tree_program")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

Test.policy{ grants = {
  { path = "checker/stdlib.d.tl", letters = "r" }, { path = "checker/tl.tl", letters = "r" },
  { path = "core/syscalls.h", letters = "r" }, { path = "core/process.h", letters = "r" },
  { path = "core/socket.h", letters = "r" }, { path = "core", letters = "r" },
} }

local built = assert(teal.load())

--- The files of the sources of `index`, in order, as one line.
local function files_of(index: Driver.Index): string
  local files: {string} = {}
  for _, source in ipairs(index.sources) do
    files[#files + 1] = source.filename
  end
  return table.concat(files, " ")
end

local function test_the_fork_checker_and_the_programs_of_testdata_are_left_out_of_the_program()
  local index = TreeProgram.index({
    { "checker/tl.tl", "return 1\n" }, { "testdata/t.tl", "return 2\n" }, { "ci/testdata/b/c.tl", "return 3\n" },
    { "x/testdata/y.tl", "return 4\n" }, { "checker/flow.tl", "return 5\n" }, { "mytestdata/a.tl", "return 6\n" },
    { "lang/a.tl", "local x = 1\nreturn x\n" },
    { "doc/guides/g.md", "return 7\n", "doc.guides.g" }, { "gen/s.d.tl", "return 8\n", "cosmic.s", "core/s.h" },
  }, true, {})
  local kept = files_of(index)
  assert(kept == "checker/flow.tl mytestdata/a.tl lang/a.tl doc/guides/g.md gen/s.d.tl", kept)
  assert(assert(index.by_module["lang.a"]).translate)
  assert(assert(index.by_module["doc.guides.g"]).filename == "doc/guides/g.md")
  assert(assert(index.by_module["cosmic.s"]).pinned == "core/s.h")
end

--- A project's `checker/` is its own, so its file of the fork's name is a module of it; only cosmic's own tree leaves it out.
local function test_a_project_keeps_a_file_of_the_forks_name()
  local entries = { { "checker/tl.tl", "return 1\n" }, { "testdata/t.tl", "return 2\n" }, { "m.tl", "return 3\n" } }
  local kept = files_of(TreeProgram.index(entries, false, {}))
  assert(kept == "checker/tl.tl m.tl", kept)
  local own = files_of(TreeProgram.index(entries, true, {}))
  assert(own == "m.tl", own)
end

local function test_the_globals_are_the_prelude_and_the_library_less_what_the_runtime_withholds()
  local stdlib = Driver.source("checker.stdlib", "checker/stdlib.d.tl", (assert(Fs.read("checker/stdlib.d.tl"))), "decl")
  local made = TreeProgram.fork_globals(".", stdlib)
  assert(#made.sources == 2 and made.sources[1].module == "checker.prelude" and made.sources[2].module == "checker.stdlib")
  assert(made.sources[2].translate and made.sources[2].corrections and not made.sources[1].translate)
  -- the prelude is what the fork keeps between the marks
  local prelude = made.sources[1].text
  assert(prelude:find("global record metatable<T>", 1, true) ~= nil and #prelude < 4000 and prelude:sub(1, 3) == "do\n")
  local globals = Driver.globals(made.sources, made.adjust)
  for _, kept in ipairs({ "string", "table", "math", "metatable", "_G", "userdata", "print" }) do
    assert(globals[kept] ~= nil, kept .. " is no global")
  end
  for _, withheld in ipairs(teal.withheld) do
    assert(globals[withheld] == nil, withheld .. " is a global")
  end
  assert(globals["interface"] == nil, "the prelude's `interface userdata` declares no `interface`")
  assert(assert(globals["userdata"]).space == "type")
end

local function test_a_tree_without_the_fork_checker_has_the_library_alone_and_nothing_withdrawn_from_it(tmp: string)
  local stdlib = Driver.source("checker.stdlib", "checker/stdlib.d.tl", (assert(Fs.read("checker/stdlib.d.tl"))), "decl")
  assert(Fs.mkdirs(tmp .. "/checker"))
  assert(Fs.write(tmp .. "/checker/tl.tl", "return 1\n"))
  for _, root in ipairs({ tmp, tmp .. "/none" }) do
    local alone = TreeProgram.fork_globals(root, stdlib)
    assert(#alone.sources == 1 and alone.sources[1].module == "checker.stdlib")
    local only = Driver.globals(alone.sources, alone.adjust)
    assert(only["string"] ~= nil and only["metatable"] == nil and only["userdata"] == nil and only["_G"] ~= nil)
  end
  -- and with no library either, only what the runtime adds
  local none = TreeProgram.fork_globals(tmp, nil)
  assert(#none.sources == 0 and Driver.globals(none.sources, none.adjust)["_G"] ~= nil)
end

local function test_a_binding_of_c_is_typed_where_the_tree_declares_it_and_untyped_where_nothing_does()
  local stdlib = Driver.source("checker.stdlib", "checker/stdlib.d.tl", (assert(Fs.read("checker/stdlib.d.tl"))), "decl")
  local globals = TreeProgram.fork_globals(".", stdlib)
  local none = TreeProgram.build(TreeProgram.index({}, false, {}), globals)
  for _, name in ipairs({ "cosmic.sys", "cosmic.internal.process", "cosmic.internal.socket" }) do
    assert(none.program.external[name] == true, name)
  end
  local bindings = TreeProgram.bindings_of(".")
  assert(#bindings == 3)
  local typed = TreeProgram.build(TreeProgram.index(bindings, false, {}), globals)
  local names: {string} = {}
  for _, entry in ipairs(bindings) do
    names[#names + 1] = assert(entry[3])
    assert(typed.program.external[assert(entry[3])] ~= true)
    -- the file they stand for, the module, and the header the ceilings are kept under
    assert(entry[1]:find("%.d%.tl$") ~= nil and entry[4]:find("^core/%w+%.h$") ~= nil, entry[1] .. " " .. entry[4])
  end
  -- a provider that answers one is a declaration too
  local provided = TreeProgram.build(TreeProgram.index({}, false, {}), globals, false, nil, function(module: string): Driver.Source | nil
    return module == "cosmic.sys" and Driver.declarations(module, "cosmic/sys.d.tl", "local record S\nend\nreturn S\n", false, false, {}) or nil
  end)
  assert(provided.program.external["cosmic.sys"] ~= true and provided.program.external["cosmic.internal.process"] == true)
  -- the declarations the headers give have no error of their own: no ceiling holds them
  typed:lower(names)
  for _, name in ipairs(names) do
    local result = assert(typed:result(name, false))
    assert(not result.broken and #result.errors == 0, name .. ": " .. tostring(result.errors[1] and result.errors[1].msg))
  end
end

local GUIDE <const> = "# a guide\n\n```teal\nlocal x = 1\nassert(x == 1)\n```\n"
local TEMPLATE <const> = "{{type Page from pages.data}}\n<p>{{.name}}</p>\n"

local function test_the_guides_and_templates_are_the_modules_the_stage_derives_from_them(tmp: string)
  local root = tmp .. "/derived"
  assert(Fs.mkdirs(root))
  for name, text in pairs({
      ["doc/guides/g.md"] = GUIDE, ["doc/guides/h.md"] = "# h\n\n```teal\nlocal y = 2\nassert(y == 2)\n```\n",
      ["doc/guides/sub/ignored.md"] = GUIDE, ["doc/other.md"] = GUIDE,
      ["pages/home.tmpl"] = TEMPLATE, ["pages/init.tmpl"] = TEMPLATE, ["pages/testdata/skipped.tmpl"] = TEMPLATE,
      ["m.tl"] = "return 1\n",
  }) do
    local parent = name:match("^(.+)/[^/]+$")
    if parent ~= nil then
      assert(Fs.mkdirs(root .. "/" .. parent))
    end
    assert(Fs.write(root .. "/" .. name, text))
  end
  local entries = assert(TreeProgram.derived_of(root))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  assert(importer.derive(handle, false, built))
  local rows = assert(Sqlite.text_rows(handle.db, "SELECT file, path, source, origin FROM derived ORDER BY file"))
  local derived: {{string}} = {}
  for _, row in ipairs(rows) do
    if row:text(4) == "doctest" or row:text(4) == "template" then
      derived[#derived + 1] = { row:text(1), row:text(2), row:text(3) }
    end
  end
  assert(work.close(handle))
  table.sort(entries, function(a: {string}, b: {string}): boolean
    return a[1] < b[1]
  end)
  -- the same files, the same modules, the same text: two guides and two templates
  assert(#entries == 4 and #derived == 4, #entries .. " / " .. #derived)
  for i, entry in ipairs(entries) do
    local row = assert(derived[i])
    assert(entry[1] == row[1] and entry[3] == row[2] and entry[2] == row[3], entry[1] .. " is not the stage's " .. row[1])
  end
  assert(entries[1][3] == "doc.guides.g" and entries[3][3] == "pages.home" and entries[4][3] == "pages", entries[3][3])
end

local function test_a_guide_or_template_the_build_refuses_is_refused_with_its_reason(tmp: string)
  local root = tmp .. "/refused"
  assert(Fs.mkdirs(root .. "/pages"))
  assert(Fs.write(root .. "/pages/bad.tmpl", "{{if}}\n"))
  local entries, why = TreeProgram.derived_of(root)
  assert(entries == nil and why:find("bad.tmpl", 1, true) ~= nil, tostring(why))
end

local TAGGED <const> = "local record Ast\n  record Local is Base\n    where self.kind == \"Local\"\n  end\n" ..
  "  record Other is Base\n    where self.kind == \"Other\"\n  end\nend\n"

local function test_the_steps_blank_the_clauses_and_write_a_test_of_a_record_they_told_apart_as_its_tag()
  local entries = {
    { "lang/ast.tl", TAGGED }, { "lang/types.tl", "local record Types\nend\nreturn Types\n" },
    { "lang/use.tl", "local Ast = require(\"lang.ast\")\nlocal function f(x: Ast.Local | Ast.Other): boolean\n" ..
        "  return x is Ast.Local\nend\nreturn f\n" },
    { "lang/plain.tl", "return 1\n" },
  }
  local mended = TreeProgram.index(entries, true, {})
  local ast = assert(mended.by_module["lang.ast"]).mend
  assert(ast ~= nil)
  local blanked = ast(TAGGED)
  assert(blanked:find("where", 1, true) == nil and select(2, blanked:gsub("\n", "")) == select(2, TAGGED:gsub("\n", "")),
    blanked)
  local use = assert(mended.by_module["lang.use"])
  local rewrite = use.mend
  assert(rewrite ~= nil)
  local tested = rewrite(use.text)
  assert(tested:find("x.kind == \"Local\"", 1, true) ~= nil and tested:find("is Ast.Local", 1, true) == nil, tested)
  -- a module that mentions neither is read as it is, and so is every module where the steps are not asked for
  assert(assert(mended.by_module["lang.plain"]).mend == nil)
  local plain = TreeProgram.index(entries, false, {})
  assert(assert(plain.by_module["lang.ast"]).mend == nil and assert(plain.by_module["lang.use"]).mend == nil)
end

local function test_the_files_and_the_sources_written_from_them_are_one_list_with_the_written_told_apart()
  local files = { { "a.tl", "return 1\n" } }
  local written = { { "doc/guides/g.md", "return 2\n", "doc.guides.g" } }
  local joined = TreeProgram.joined(files, written)
  assert(#joined.files == 2 and joined.files[1][1] == "a.tl" and joined.files[2][1] == "doc/guides/g.md")
  assert(joined.derived["doc/guides/g.md"] == true and joined.derived["a.tl"] == nil)
  assert(#files == 1, "the list given is left as it was")
end

local function test_a_module_without_a_call_to_resolve_is_left_as_it_is_and_one_the_build_lacks_is_refused()
  local build = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  build:provide(Driver.files(TreeProgram.index({
    { "a.tl", "local record R\n  n: integer\nend\nreturn R\n" },
    { "b.tl", "return 2\n" },
  }, false, {})))
  assert(TreeProgram.splice(build, "a", "a.tl") == false and TreeProgram.splice(build, "b", "b.tl") == false)
  local lacking, why = TreeProgram.splice(build, "nowhere", "nowhere.tl")
  assert(lacking == nil and why:find("nowhere.tl", 1, true) ~= nil, tostring(why))
  assert(build:parsed("a") ~= nil and not assert(build:parsed("a")).broken)
end

local function test_modules_are_streamed_after_the_modules_among_them_that_they_require_and_each_is_retired_after_its_turn()
  local index = TreeProgram.index({
    { "top.tl", "local a = require(\"lib.a\")\nlocal b = require('lib.b')\nreturn a\n" },
    { "lib/a.tl", "local b = require(\"lib.b\")\nreturn b\n" },
    { "lib/b.tl", "return 1\n" },
    { "other.tl", "local x = require(\"cosmic.fs\")\nreturn x\n" },
    { "cycle/one.tl", "local two = require(\"cycle.two\")\nreturn two\n" },
    { "cycle/two.tl", "local one = require(\"cycle.one\")\nreturn one\n" },
  }, false, {})
  local function streamed(modules: {string}): string
    local build = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
    build:provide(Driver.files(index))
    local seen: {string} = {}
    local refused = TreeProgram.stream(build, index, modules, true, function(module: string)
      local result = build:result(module, false)
      assert(result == nil or result.lowered ~= nil, module)
      seen[#seen + 1] = module
    end)
    assert(#refused == 0)
    for _, module in ipairs(modules) do
      assert(build:retired(module) or index.by_module[module] == nil, module)
    end
    return table.concat(seen, " ")
  end
  assert(streamed({ "top", "other", "lib.a", "lib.b", "cycle.one", "cycle.two", "absent" }) ==
      "lib.b lib.a top other cycle.two cycle.one absent")
  -- only the modules asked for are in the order, though the others are required
  assert(streamed({ "top" }) == "top")
end
