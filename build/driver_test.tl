--- Tests of [`build.driver`]: the names a tree's files answer to, one program over a module graph through its
--- providers, the corrections of the standard library made where the library is read (and their drift reported), each
--- module's errors and warnings and type report, a test module's functions, and a module held to its ceilings.
local Ast = require("lang.ast")
local Ceilings = require("build.ceilings")
local Check = require("lang.check")
local Driver = require("build.driver")
local Node = require("build.syntax_node")
local Types = require("lang.types")
local Programs = require("lang.check_programs")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")
local Translate = require("lang.translate")

Test.policy{}

local function nothing(_file: string): boolean
  return false
end

--- A build over `files` (pairs of a path and its text, in the new grammar) with the small library of the checker's tests as
--- its globals.
local function build_of(files: {{string}}): Driver.Build, Driver.Index
  local index = Driver.index(files, false, nothing)
  local build = Driver.new({
    globals = { Driver.declarations("std", "std.d.tl", Programs.library, false, false, {}) },
    adjust = nil, external = { "cosmic.sys" },
    types = true,
  })
  build:provide(Driver.files(index))
  return build, index
end

local function codes_of(list: {Driver.Problem}): string
  local out: {string} = {}
  for _, p in ipairs(list) do
    out[#out + 1] = p.code
  end
  return table.concat(out, " ")
end

--- The ceilings of a few stages: `declared`, `scoped` and `checked` each a table of `<file> <code>` to the count.
local function pins(declared: {string: integer}, scoped: {string: integer}, checked: {string: integer}): Ceilings.Table
  return { stages = { declared = declared, scoped = scoped, checked = checked } }
end

local RECORD <const> = "local record Box\n  n: integer\nend\nreturn Box\n"

local function test_a_file_is_the_module_its_path_names_and_answers_to_the_tail_of_its_path()
  local index = Driver.index({
    { "build/a.tl", "return 1\n" }, { "cosmic/http/init.tl", "return 2\n" }, { "ci/cosmic_ci/x.tl", "return 3\n" },
    { "ci/cosmic_ci/y.d.tl", "global record Y\nend\n" }, { "testdata/t.tl", "return 4\n" },
  }, false, function(file: string): boolean
    return file:find("^testdata/") ~= nil
  end)
  assert(#index.sources == 4 and index.by_module["testdata.t"] == nil)
  local x = assert(index.by_module["ci.cosmic_ci.x"])
  assert(x.filename == "ci/cosmic_ci/x.tl" and x.dialect == "tl" and x.checked and not x.translate)
  assert(index.by_module["cosmic_ci.x"] == x and index.by_module["x"] == x)
  assert(x.aliases[1] == "cosmic_ci.x" and x.aliases[2] == "x", table.concat(x.aliases, " "))
  assert(index.by_module["cosmic.http"] ~= nil and index.by_module["http"] == index.by_module["cosmic.http"])
  local y = assert(index.by_module["y"])
  assert(y.dialect == "decl" and y.module == "ci.cosmic_ci.y")
  assert(Driver.files(index)("build.a") == index.by_module["build.a"] and Driver.files(index)("nope") == nil)
end

local function test_a_declaration_is_read_ahead_of_a_source_of_the_same_module_and_the_tree_is_translated_on_request()
  local index = Driver.index({ { "m.tl", "return 1\n" }, { "m.d.tl", "global record M\nend\n" } }, true, nothing)
  assert(#index.sources == 2)
  assert(assert(index.by_module["m"]).dialect == "decl" and assert(index.by_module["m"]).translate)
  local backwards = Driver.index({ { "m.d.tl", "global record M\nend\n" }, { "m.tl", "return 1\n" } }, false, nothing)
  assert(assert(backwards.by_module["m"]).dialect == "decl")
end

local function test_one_program_is_built_over_modules_that_require_each_other_through_their_names()
  local build = build_of({
    { "box.tl", RECORD },
    { "use.tl", "local Box = require(\"box\")\nlocal b: Box = { n = 1 }\nlocal bad: Box = { n = \"s\" }\nreturn b\n" },
  })
  local result = assert(build:result("use", true))
  assert(codes_of(result.bodies) == "not_assignable", codes_of(result.errors))
  assert(result.errors[1] ~= nil and result.errors[1].stage == "checked" and result.errors[1].kind == "error")
  assert(result.lowered ~= nil and result.checked ~= nil and not result.broken)
  -- the module it requires was lowered with it, and is the same program's
  local box = assert(build:parsed("box"))
  assert(box.lowered ~= nil and box.checked == nil)
  assert(build:parsed("nothing here") == nil and build:result("nothing here", true) == nil)
end

local function test_two_modules_that_require_each_others_types_are_lowered_whichever_is_asked_first()
  local files = {
    { "a.tl", "local type B = require(\"b\")\nlocal record A\n  other: B\nend\nreturn A\n" },
    { "b.tl", "local type A = require(\"a\")\nlocal record B\n  other: A\nend\nreturn B\n" },
  }
  for _, first in ipairs({ "a", "b" }) do
    local build = build_of(files)
    build:lower({ first })
    for _, name in ipairs({ "a", "b" }) do
      local result = assert(build:result(name, true))
      assert(#result.errors == 0, name .. " after " .. first .. ": " .. codes_of(result.errors))
    end
  end
end

local function test_a_binding_of_c_is_typed_invalid_and_reported_where_it_is_used()
  local build = build_of({ { "m.tl", "local sys = require(\"cosmic.sys\")\nlocal n: integer = sys.getpid()\nreturn n\n" } })
  local result = assert(build:result("m", true))
  assert(codes_of(result.errors) == "unchecked_binding", codes_of(result.errors))
end

local function test_a_module_a_provider_answers_with_text_is_lowered_for_its_types_and_never_checked()
  local build = build_of({ { "use.tl", "local Box = require(\"cosmic.box\")\nlocal b: Box = { n = 1 }\nreturn b\n" } })
  -- the `cosmic.*` modules of the binary, each its stub or source; this one has a mistake in a body it never checks
  build:provide(Driver.standard(function(module: string): string | nil
    if module == "cosmic.box" then
      return "local record Box\n  n: integer\nend\nlocal bad: integer = \"not checked\"\nreturn Box\n"
    end
    return nil
  end))
  local result = assert(build:result("use", true))
  assert(#result.errors == 0, codes_of(result.errors))
  local library = assert(build:result("cosmic.box", true))
  assert(library.checked == nil and #library.bodies == 0 and #library.warnings == 0 and not library.source.checked)
  -- stubs are answered after the providers before them, and are no more checked
  local stubbed = build_of({ { "use.tl", "local Box = require(\"stub.box\")\nlocal b: Box = { n = 2 }\nreturn b\n" } })
  stubbed:provide(Driver.stubs({ ["stub.box"] = RECORD }))
  assert(#assert(stubbed:result("use", true)).errors == 0)
  assert(assert(stubbed:parsed("stub.box")).source.checked == false)
end

local function test_a_module_that_does_not_parse_is_lowered_for_those_that_import_it_and_is_broken()
  local build = build_of({
    { "bad.tl", "local record Box\n  n: integer\nend\nlocal x = = 1\nreturn Box\n" },
    { "use.tl", "local Box = require(\"bad\")\nlocal b: Box = { n = 1 }\nreturn b\n" },
  })
  local bad = assert(build:result("bad", true))
  assert(bad.broken and #bad.syntax >= 1 and bad.checked == nil and bad.errors[1] ~= nil and bad.errors[1].stage == "syntax")
  assert(#assert(build:result("use", true)).errors == 0)
end

local function test_a_declaration_file_in_the_tree_is_a_module_whose_types_others_use()
  local build = build_of({
    { "shapes.d.tl", "local record Shape\n  sides: integer\nend\nreturn Shape\n" },
    { "m.tl", "local Shape = require(\"shapes\")\nlocal s: Shape = { sides = 3 }\nreturn s\n" },
  })
  local result = assert(build:result("m", true))
  assert(#result.errors == 0, codes_of(result.errors))
  local decl = assert(build:result("shapes", true))
  assert(decl.checked == nil and #decl.bodies == 0)
end

local function test_the_corrections_of_the_standard_library_are_made_where_it_is_read_and_what_they_could_not_apply_is_reported()
  local text = "do\n  global record string\n    byte: function(string, ? integer): integer\n" ..
    "    byte: function(string, integer, ? integer): integer...\n  end\nend\n"
  local build = Driver.new({ globals = { Driver.declarations("lib", "lib.d.tl", text, true, true, {}) }, adjust = nil, external = {}, types = false })
  build:provide(Driver.files(Driver.index({ { "m.tl", "local b: integer = (\"a\"):byte(1)\nreturn b\n" } }, false, nothing)))
  local result = assert(build:result("m", true))
  -- `string.byte` answers nil for a position out of range, which the correction says and the file does not
  assert(codes_of(result.errors) == "nil_not_allowed", codes_of(result.errors))
  local mentioned = table.concat(build.problems, "\n")
  assert(mentioned:find("string.find: the file declares it 0 times", 1, true) and
      mentioned:find("lib.d.tl: StandardLibrary.assert: the file has no record StandardLibrary", 1, true) and
      mentioned:find("(lang/stdlib_corrections.tl)", 1, true) and not mentioned:find("string.byte", 1, true), mentioned)
  -- a file the corrections do not name is left as it is
  local plain = Driver.new({ globals = { Driver.declarations("lib", "lib.d.tl", text, true, false, {}) }, adjust = nil, external = {}, types = false })
  plain:provide(Driver.files(Driver.index({ { "m.tl", "local b: integer = (\"a\"):byte(1)\nreturn b\n" } }, false, nothing)))
  assert(#assert(plain:result("m", true)).errors == 0 and #plain.problems == 0)
end

local function test_the_globals_are_what_the_declaration_files_declare_less_what_the_host_withholds()
  local text = "global record Seen\n  n: integer\nend\nglobal record Withheld\n  n: integer\nend\n"
  local globals = Driver.globals({ Driver.declarations("lib", "lib.d.tl", text, false, false, {}) },
    function(names: {string: Scopes.Global})
      names["Withheld"] = nil
      names["Added"] = { space = "type", const = false }
    end)
  assert(globals["Seen"] ~= nil and globals["Withheld"] == nil and globals["Added"] ~= nil)
end

local function test_a_module_has_its_errors_of_every_stage_in_source_order_and_its_warnings_apart()
  local build = build_of({
    { "m.tl", "local a: {number: integer} = {}\nlocal unused = 1\nlocal b: integer = 3.5\nreturn a\n" },
  })
  local result = assert(build:result("m", true))
  assert(codes_of(result.errors) == "float_key not_assignable", codes_of(result.errors))
  assert(result.errors[1].stage == "declared" and result.errors[2].stage == "checked")
  assert(#result.declared == 1 and #result.bodies == 1 and #result.scope_errors == 0 and #result.syntax == 0)
  assert(#result.warnings == 2 and result.warnings[1].kind == "unused" and result.warnings[1].stage == "warning" and
      result.warnings[1].code == "unused_variable" and result.warnings[2].code == "unused_variable", codes_of(result.warnings))
  assert(result.errors[1].y == 1 and result.errors[2].y == 3)
end

local function test_a_module_without_the_bodies_asked_for_is_not_checked_and_asking_again_checks_it()
  local build = build_of({ { "m.tl", "local b: integer = 3.5\nreturn b\n" } })
  local declared = assert(build:result("m", false))
  assert(declared.checked == nil and #declared.errors == 0)
  local again = assert(build:result("m", true))
  assert(again == declared and again.checked ~= nil and codes_of(again.bodies) == "not_assignable")
  assert(#assert(build:result("m", true)).bodies == 1, "checked once")
end

--- A method call has no node for its callee, so the function each call took is kept by the id of the call: the one function
--- of a plain call, a method and a chained call, and the overload taken of a call of several.
local function test_the_function_each_call_took_is_kept_by_the_id_of_the_call()
  local source = table.concat({
    "local record Box",
    "  n: integer",
    "  get: function(Box, integer): integer, string",
    "end",
    "local b: Box = { n = 1, get = function(_: Box, i: integer): integer, string return i, '' end }",
    "local function make(): function(): boolean, string return function(): boolean, string return true, '' end end",
    "local first = b:get(1)",
    "local second = make()()",
    "local third = Over.put('x')",
    "local fourth = Over.put({ n = 1 })",
    "local fifth = ipairs({ 1 })",
    "More.run(function(a: string): string return a end)",
    "return b",
  }, "\n") .. "\n"
  local build = build_of({ { "m.tl", source } })
  local result = assert(build:result("m", true))
  assert(#result.errors == 0, codes_of(result.errors))
  local calls: {Ast.Node} = {}
  Node.walk(result.chunk, function(n: Ast.Node)
    if n is Ast.Call or n is Ast.MethodCall then
      calls[#calls + 1] = n
    end
  end)
  assert(#calls == 7, "calls: " .. #calls)
  local function took(i: integer): Types.Fn
    local t = result.callees[Node.base(calls[i]).id]
    assert(t ~= nil and t is Types.Fn, "call " .. i .. " took no function")
    return t
  end
  -- the method takes its record as the first parameter and answers two results
  assert(#took(1).params == 2 and #took(1).rets[1].items == 2)
  -- a chained call is judged by the function the inner call answered
  assert(#took(2).params == 0 and #took(2).rets[1].items == 2 and #took(3).rets[1].items == 1)
  -- the overload taken, not the first the name has
  assert(took(4).params[1].type.tag == "string" and took(5).params[1].type.tag == "named")
  -- a generic callee is the function with its type parameters, and a function literal argument is checked after the overload
  -- is chosen: the callee is the overload that takes a function of one parameter
  assert(#took(6).tparams == 1)
  local literal = took(7).params[1].type
  assert(literal is Types.Fn and #literal.params == 1)
  local lean = Driver.new({ globals = { Driver.declarations("std", "std.d.tl", Programs.library, false, false, {}) }, adjust = nil, external = {}, types = false })
  lean:provide(Driver.files(Driver.index({ { "m.tl", source } }, false, nothing)))
  assert(next(assert(lean:result("m", true)).callees) == nil)
end

local function test_the_type_report_is_by_the_id_of_each_node_when_asked_for_and_empty_when_not()
  local files = { { "m.tl", "local record Box\n  n: integer\nend\nlocal b: Box = { n = 1 }\nlocal total = b.n + 2\nreturn total\n" } }
  local build = build_of(files)
  local result = assert(build:result("m", true))
  local last: Driver.Outcome = result
  local counted = 0
  local named = 0
  for _, t in pairs(last.types) do
    counted = counted + 1
    if t.tag == "named" then
      named = named + 1
    end
  end
  assert(counted >= 8 and named >= 2, "typed " .. tostring(counted))
  local lean = Driver.new({ globals = { Driver.declarations("std", "std.d.tl", Programs.library, false, false, {}) }, adjust = nil, external = {}, types = false })
  lean:provide(Driver.files(Driver.index(files, false, nothing)))
  assert(next(assert(lean:result("m", true)).types) == nil)
  -- the hint that reads the type of what a method is called on does not wait for the report
  local method = "local record R\n  get: function(self: R): integer\nend\nlocal r: R = { get = function(self: R): integer return 1 end }\n" ..
    "return r.get(r)\n"
  local hinted = Driver.new({ globals = { Driver.declarations("std", "std.d.tl", Programs.library, false, false, {}) }, adjust = nil, external = {}, types = false })
  hinted:provide(Driver.files(Driver.index({ { "h.tl", method } }, false, nothing)))
  local warned = assert(hinted:result("h", true))
  assert(#warned.warnings == 1 and warned.warnings[1].code == "method_dot", codes_of(warned.warnings))
  assert(next(warned.types) == nil)
end

local function test_the_test_functions_of_a_test_module_are_called_from_outside_and_are_not_unused()
  local text = "local function test_works()\nend\nlocal function helper()\nend\n"
  local build = build_of({ { "w_test.tl", text }, { "w.tl", text } })
  local index = Driver.index({ { "w_test.tl", text }, { "w.tl", text } }, false, nothing)
  local test_source = assert(index.by_module["w_test"])
  test_source.tests = true
  local tested = Driver.new({ globals = { Driver.declarations("std", "std.d.tl", Programs.library, false, false, {}) }, adjust = nil, external = {}, types = false })
  tested:provide(Driver.files(index))
  local discounted = assert(tested:result("w_test", true))
  assert(#discounted.warnings == 1, codes_of(discounted.warnings))
  assert(discounted.warnings[1].msg:find("helper", 1, true), discounted.warnings[1].msg)
  local plain = assert(build:result("w", true))
  assert(#plain.warnings == 2, "outside a test module a function nothing calls is unused: " .. codes_of(plain.warnings))
end

--- Errors of the module `m`: four of `not_assignable` (no ceiling says otherwise) and a declaration's `float_key`.
local FOUR <const> = "local a: integer = 1.5\nlocal b: integer = 2.5\nlocal c: integer = 3.5\nlocal d: integer = 4.5\n" ..
  "local m: {number: integer} = {}\nreturn m\n"

local function test_a_count_above_its_ceiling_is_refused_with_the_places_and_what_it_is_pinned_at()
  local build = build_of({ { "m.tl", FOUR } })
  local result = assert(build:result("m", true))
  local lines = build:held(result, pins({}, {}, {}))
  assert(#lines == 7, table.concat(lines, "\n"))
  assert(lines[1]:find("m.tl:5:", 1, true) and lines[1]:find("(float_key)", 1, true), lines[1])
  assert(lines[2] == "m.tl: 1 error of float_key in its declarations, pinned 0; follow the fix above rather than raise the pin", lines[2])
  assert(lines[#lines] == "m.tl: 4 errors of not_assignable in its bodies, pinned 0; follow the fix above rather than raise the pin",
    lines[#lines])
  local declared = { ["m.tl float_key"] = 1 }
  local fewer = build:held(result, pins(declared, {}, { ["m.tl not_assignable"] = 3 }))
  assert(#fewer == 5, table.concat(fewer, "\n"))
  assert(fewer[5] == "m.tl: 4 errors of not_assignable in its bodies, pinned 3; follow the fix above rather than raise the pin")
  assert(#build:held(result, pins(declared, {}, { ["m.tl not_assignable"] = 4 })) == 0)
  assert(#build:held(result, pins(declared, {}, { ["m.tl not_assignable"] = 9 })) == 0,
    "a ceiling above the count refuses nothing; the check of the tree tells it to fall")
end

local function test_the_scope_builders_errors_are_held_to_their_own_stage_of_ceilings()
  local build = build_of({ { "m.tl", "local record R\nend\nlocal x = 1\ndo\n  local x = 2\n  print(x)\nend\nprint(x)\nreturn R\n" } })
  local result = assert(build:result("m", true))
  assert(codes_of(result.scope_errors) == "shadows", codes_of(result.errors))
  assert(#build:held(result, pins({}, {}, {})) == 2)
  assert(#build:held(result, pins({}, { ["m.tl shadows"] = 1 }, {})) == 0)
end

local function test_a_module_that_does_not_parse_is_refused_for_its_syntax_alone()
  local build = build_of({ { "m.tl", "local x = = 1\n" } })
  local result = assert(build:result("m", true))
  local lines = build:held(result, pins({}, {}, { ["m.tl not_assignable"] = 99 }))
  assert(#lines >= 1, table.concat(lines, "\n"))
  assert(lines[1]:find("m.tl:1:", 1, true), table.concat(lines, "\n"))
  for _, line in ipairs(lines) do
    assert(not line:find("pinned", 1, true), "a syntax error has no ceiling: " .. line)
  end
end

local function test_the_driver_checks_what_the_checker_does_alone()
  -- the same program through the driver and through the checker's own entry point has the same errors
  local source = "local record Box\n  n: integer\nend\nlocal b: Box = { n = \"s\" }\nlocal n: string = b.n\nreturn b\n"
  local run = Programs.run(source)
  local result = assert(build_of({ { "t.tl", source } }):result("t", true))
  local want: {string} = {}
  for _, e in ipairs(run.errors) do
    want[#want + 1] = tostring(e.code) .. tostring(e.y) .. ":" .. tostring(e.x)
  end
  local got: {string} = {}
  for _, e in ipairs(result.bodies) do
    got[#got + 1] = e.code .. tostring(e.y) .. ":" .. tostring(e.x)
  end
  assert(#want >= 2 and table.concat(got, " ") == table.concat(want, " "), table.concat(got, " ") .. " / " .. table.concat(want, " "))
  assert(#Check.codes > 0 and Ceilings.path == "build/ceilings.txt")
end

local function test_a_declaration_is_read_ahead_of_its_source_under_every_name_whichever_is_asked_first()
  local source = { "p/foo.tl", "local record Box\n  n: integer\nend\nreturn Box\n" }
  local decl = { "p/foo.d.tl", "local record Box\n  s: string\nend\nreturn Box\n" }
  local user = { "q/use.tl", "local Box = require(\"foo\")\nlocal b: Box = { s = \"x\" }\nreturn b\n" }
  local orders = { { source, decl, user }, { decl, source, user } }
  for _, files in ipairs(orders) do
    local index = Driver.index(files, false, nothing)
    local winner = assert(index.by_module["p.foo"])
    assert(winner.dialect == "decl" and index.by_module["foo"] == winner)
    assert(#winner.aliases == 1 and winner.aliases[1] == "foo")
    local pairs_asked: {{string}} = { { "foo", "p.foo" }, { "p.foo", "foo" } }
    for _, asked in ipairs(pairs_asked) do
      local one, other = asked[1], asked[2]
      assert(one ~= nil and other ~= nil)
      local build = Driver.new({ globals = { Driver.declarations("std", "std.d.tl", Programs.library, false, false, {}) },
        adjust = nil, external = {}, types = false })
      build:provide(Driver.files(index))
      local first = assert(build:parsed(one))
      local second = assert(build:parsed(other))
      assert(first == second and first.source.filename == "p/foo.d.tl", one .. " then " .. other)
      local used = assert(build:result("use", true))
      assert(#used.errors == 0, codes_of(used.errors))
    end
  end
end

local function test_a_test_module_is_a_file_that_ends_in_test_and_its_functions_are_not_unused()
  local text = "local function test_x()\nend\n"
  local index = Driver.index({ { "a_test.tl", text }, { "a.tl", text }, { "a_tested.tl", text } }, false, nothing)
  assert(assert(index.by_module["a_test"]).tests and not assert(index.by_module["a"]).tests and
      not assert(index.by_module["a_tested"]).tests)
  local build = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  build:provide(Driver.files(index))
  assert(#assert(build:result("a_test", true)).warnings == 0)
  assert(#assert(build:result("a", true)).warnings == 1)
end

local function test_a_module_whose_bodies_were_not_checked_is_told_so_by_held_and_a_declaration_file_is_not()
  local build = build_of({ { "m.tl", FOUR }, { "d.d.tl", "local record D\n  n: integer\nend\nreturn D\n" } })
  local unchecked = build:held(assert(build:result("m", false)), pins({}, {}, {}))
  assert(#unchecked >= 1, "told")
  assert(unchecked[#unchecked]:find("m.tl: its bodies were not checked", 1, true) ~= nil, table.concat(unchecked, "\n"))
  assert(#build:held(assert(build:result("d", false)), pins({}, {}, {})) == 0)
  local checked = build:held(assert(build:result("m", true)), pins({}, {}, {}))
  assert(#checked > 2 and not checked[#checked]:find("not checked", 1, true))
end

local function ceilings(text: string): Ceilings.Table
  return (assert(Ceilings.parse(text)))
end

local HAZARD <const> = "local record R\n  n: integer\nend\nlocal helper = 1\nfunction R:f(): integer\n  return self.n + helper\nend\nreturn R\n"

local function test_a_module_of_the_forks_teal_is_held_to_what_the_tree_counts_of_its_text_not_of_its_translation()
  local files = { { "hazard.tl", HAZARD }, { "broken.tl", "local t: {{string, integer}}\nreturn t\n" } }
  local index = Driver.index(files, true, nothing)
  local build = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  build:provide(Driver.files(index))
  -- the translation moves the method above `helper`, a scope error of the translated text that `[hazards]` counts
  local hazard = assert(build:result("hazard", true))
  assert(#hazard.scope_errors >= 1, "the translated method no longer sees `helper`")
  assert(#build:held(hazard, ceilings("")) == 0, table.concat(build:held(hazard, ceilings("")), "\n"))
  -- a translation that does not parse is held to `[translated]`
  local broken = assert(build:result("broken", true))
  assert(broken.broken)
  local refused = build:held(broken, ceilings(""))
  assert(#refused >= 2, "the error and the count")
  assert(refused[#refused]:find("broken.tl: 1 error of tuple_type in its translation, pinned 0;", 1, true) ~= nil,
    table.concat(refused, "\n"))
  assert(#build:held(broken, ceilings("[translated]\nbroken.tl tuple_type 1\n")) == 0)
  -- the same text in the new grammar has no such allowance: a syntax error is refused whatever is pinned
  local new = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  new:provide(Driver.files(Driver.index({ { "broken.tl", "local t: {{string, integer}}\nreturn t\n" } }, false, nothing)))
  local still = assert(new:result("broken", true))
  assert(still.broken and #new:held(still, ceilings("[translated]\nbroken.tl tuple_type 1\n")) >= 1)
end

local function test_a_declaration_file_the_driver_corrects_is_held_by_the_tree_as_written_and_by_no_ceiling_here()
  -- the corrected text may have forms the file as written does not: its errors are not what a ceiling counts
  local text = "do\n  global record string\n    byte: function(string, ? integer): integer\n  end\nend\n"
  local build = Driver.new({ globals = { Driver.declarations("lib", "lib.d.tl", text, true, true, {}) }, adjust = nil, external = {},
    types = false })
  build:provide(Driver.files(Driver.index({}, false, nothing)))
  local lib = assert(build:parsed("lib"))
  assert(#build:held(lib, pins({}, {}, {})) == 0)
end

local function test_a_source_written_from_another_file_is_the_module_it_says_and_is_pinned_under_the_name_it_gives()
  local text = "local record Box\n  n: integer\nend\nlocal bad: integer = 3.5\nreturn Box\n"
  local index = Driver.index({
    { "doc/guides/x.md", text, "doc.guides.x" },
    { "gen/sys.d.tl", "local record Sys\n  n: {number: integer}\nend\nreturn Sys\n", "cosmic.sys", "core/sys.h" },
  }, false, nothing)
  local guide = assert(index.by_module["doc.guides.x"])
  assert(guide.filename == "doc/guides/x.md" and guide.pinned == "" and guide.dialect == "tl" and guide.checked)
  assert(index.by_module["x"] == guide and index.by_module["doc.guides.x.md"] == nil)
  local sys = assert(index.by_module["cosmic.sys"])
  assert(sys.filename == "gen/sys.d.tl" and sys.pinned == "core/sys.h" and sys.dialect == "decl")
  local build = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  build:provide(Driver.files(index))
  -- a guide is held under the file it comes from
  local result = assert(build:result("doc.guides.x", true))
  assert(#build:held(result, pins({}, {}, { ["doc/guides/x.md not_assignable"] = 1 })) == 0)
  assert(#build:held(result, pins({}, {}, { ["x.md not_assignable"] = 1 })) == 2)
  -- a declaration written from a header is held under the header
  local declared = assert(build:result("cosmic.sys", false))
  assert(codes_of(declared.declared) == "float_key", codes_of(declared.errors))
  assert(#build:held(declared, pins({ ["core/sys.h float_key"] = 1 }, {}, {})) == 0)
  local refused = build:held(declared, pins({ ["gen/sys.d.tl float_key"] = 1 }, {}, {}))
  assert(#refused == 2, table.concat(refused, "\n"))
  assert(assert(refused[2]):find("^core/sys.h: 1 error of float_key") ~= nil, table.concat(refused, "\n"))
end

local function test_a_translated_source_tells_the_generator_what_the_translator_knows_and_the_text_the_checker_read()
  local text = "local n = 3\nlocal s = n > 2 and 1 or 2\nreturn s\n"
  local translated = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  translated:provide(Driver.files(Driver.index({ { "m.tl", text } }, true, nothing)))
  local one = assert(translated:parsed("m"))
  assert(one.never_false == Translate.never_false and one.text == Translate.translate(text, "m.tl").text)
  -- the new grammar is read as it is written, and the generator is told nothing
  local written = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  written:provide(Driver.files(Driver.index({ { "m.tl", text } }, false, nothing)))
  local two = assert(written:parsed("m"))
  assert(two.never_false == nil and two.text == text)
end

local function test_the_steps_a_source_needs_are_made_to_its_text_after_the_translation_and_before_the_parse()
  local build = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  local function mend(text: string): string
    return (text:gsub("WORD", "integer"))
  end
  build:provide(Driver.files(Driver.index({ { "m.tl", "local b: WORD = 1\nreturn b\n" } }, false, nothing,
    function(_file: string, _text: string): Driver.Extra
      return { tests = false, mend = mend }
    end)))
  local result = assert(build:result("m", true))
  assert(result.text == "local b: integer = 1\nreturn b\n" and #result.errors == 0, codes_of(result.errors))
  -- without them the same text is an error
  local bare = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  bare:provide(Driver.files(Driver.index({ { "m.tl", "local b: WORD = 1\nreturn b\n" } }, false, nothing)))
  assert(#assert(bare:result("m", true)).errors >= 1)
end

local function test_replacing_a_module_begins_a_new_program_in_which_everything_is_lowered_again()
  local build = build_of({
    { "box.tl", RECORD },
    { "use.tl", "local Box = require(\"box\")\nlocal b: Box = { n = 1 }\nlocal s: string = string.upper(\"x\")\nreturn b\n" },
    { "other.tl", "local record O\nend\nreturn O\n" },
  })
  local before = assert(build:result("use", true))
  assert(#before.errors == 0, codes_of(before.errors))
  local program = build.program
  local replaced = assert(build:replace("box", "local record Box\n  n: string\nend\nreturn Box\n"))
  assert(build.program ~= program, "a module cannot be lowered twice in one program")
  assert(replaced.module == "box" and replaced.text:find("n: string", 1, true) ~= nil and replaced.lowered == nil)
  build:lower({ "box" })
  assert(assert(build:parsed("box")).lowered ~= nil, "lowered when asked for")
  -- what requires it is checked again, against the new text, and the library's globals are still there
  local after = assert(build:result("use", true))
  assert(after ~= before and codes_of(after.errors) == "not_assignable", codes_of(after.errors))
  assert(build:parsed("box") == replaced and #assert(build:result("other", true)).errors == 0)
  -- the old text again, and the errors go; a module no provider has is not replaced
  assert(build:replace("box", RECORD) ~= nil)
  assert(#assert(build:result("use", true)).errors == 0)
  assert(build:replace("nothing here", RECORD) == nil)
end

local function test_a_replacement_is_read_as_written_and_keeps_what_the_module_was()
  local files = { { "m_test.tl", "local function test_x()\nend\n" }, { "d.tl", "return 1\n" } }
  local build = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  build:provide(Driver.files(Driver.index(files, true, nothing)))
  local old = assert(build:parsed("m_test"))
  assert(old.source.translate and old.source.tests)
  -- the replacement is in the new grammar: a `where` clause is a syntax error, not a thing the translator reads
  local replaced = assert(build:replace("m_test", "local record R\n  where self.a == 1\nend\nreturn R\n"))
  assert(replaced.source.translate and replaced.source.tests and replaced.source.filename == "m_test.tl")
  assert(replaced.broken)
  local looked = assert(build:result("m_test", true))
  local first = looked.errors[1]
  assert(looked == replaced and first ~= nil and first.stage == "syntax")
  assert(not assert(build:parsed("d")).broken)
end

local function test_a_standard_library_module_is_translated_when_asked_and_a_declaration_is_read_as_one()
  local texts: {string: string} = {
    ["cosmic.box"] = "local record Box\n  n: integer | nil\nend\nreturn Box\n",
    ["cosmic.sys"] = "local record Sys\n  n: integer\nend\nreturn Sys\n",
  }
  local function read(module: string): string | nil
    return texts[module]
  end
  local fork = Driver.standard(read, true)("cosmic.box")
  assert(fork ~= nil and fork.translate and not fork.checked and fork.dialect == "tl" and fork.filename == "cosmic/box.tl")
  local plain = Driver.standard(read)("cosmic.box")
  assert(plain ~= nil and not plain.translate)
  assert(Driver.standard(read, true)("cosmic.none") == nil)
  -- one it is told is a declaration is a declaration file
  local declared = Driver.standard(read, true, function(module: string): boolean
    return module == "cosmic.sys"
  end)
  local sys, box = declared("cosmic.sys"), declared("cosmic.box")
  assert(sys ~= nil and sys.dialect == "decl" and sys.filename == "cosmic/sys.d.tl" and not sys.checked)
  assert(box ~= nil and box.dialect == "tl")
end
