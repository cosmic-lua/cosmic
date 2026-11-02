--- Tests of [`build.driver`]: the names a tree's files answer to, one program over a module graph through its
--- providers, each module's errors and warnings and type report, a test module's functions, and a module held to its
--- ceilings.
local Ast = require("lang.ast")
local Ceilings = require("build.ceilings")
local Check = require("lang.check")
local Codegen = require("lang.codegen")
local Driver = require("build.driver")
local Node = require("build.syntax_node")
local Types = require("lang.types")
local Programs = require("lang.check_programs")
local TreeProgram = require("build.tree_program")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")
local Truthy = require("lang.truthy")
local support = require("build.test_support_fixture")

Test.policy{}

local function nothing(_file: string): boolean
  return false
end

--- A build over `files` (pairs of a path and its text, in the new grammar) with the small library of the checker's tests as
--- its globals.
local function build_of(files: {{string}}): Driver.Build, Driver.Index
  local index = Driver.index(files, nothing)
  local build = Driver.new({
    globals = { Driver.declarations("std", "std.d.tl", Programs.library, {}) },
    adjust = nil, external = { "cosmic.sys" },
    types = true,
    meant = TreeProgram.meant(index, true),
  })
  build:provide(Driver.files(index))
  return build, index
end

local function codes_of(list: {Driver.Problem}): string
  local out: mut {string} = {}
  for _, p in ipairs(list) do
    out[#out + 1] = p.code
  end
  return table.concat(out, " ")
end

--- The ceilings of a few stages: `declared`, `scoped` and `checked` each a table of `<file> <code>` to the count.
local function pins(declared: {string: integer}, scoped: {string: integer}, checked: {string: integer}): Ceilings.Table
  return { stages = { declared = declared, scoped = scoped, checked = checked }, none = nil }
end

local RECORD <const> = "local record Box\n  n: integer\nend\nreturn Box\n"

local function test_a_file_is_the_module_its_path_names_and_answers_to_that_name_alone()
  local index = Driver.index({
    { "build/a.tl", "return 1\n" }, { "cosmic/http/init.tl", "return 2\n" }, { "ci/cosmic_ci/x.tl", "return 3\n" },
    { "ci/cosmic_ci/y.d.tl", "global record Y\nend\n" }, { "testdata/t.tl", "return 4\n" },
  }, function(file: string): boolean
    return file:find("^testdata/") ~= nil
  end)
  assert(#index.sources == 4 and index.by_module["testdata.t"] == nil)
  local x = assert(index.by_module["ci.cosmic_ci.x"])
  assert(x.filename == "ci/cosmic_ci/x.tl" and x.dialect == "tl" and x.checked)
  assert(index.by_module["cosmic_ci.x"] == nil and index.by_module["x"] == nil and #x.aliases == 0)
  assert(index.by_module["cosmic.http"] ~= nil and index.by_module["http"] == nil)
  local y = assert(index.by_module["ci.cosmic_ci.y"])
  assert(y.dialect == "decl" and y.module == "ci.cosmic_ci.y")
  assert(Driver.files(index)("build.a") == index.by_module["build.a"] and Driver.files(index)("nope") == nil)
end

local function test_one_program_is_built_over_modules_that_require_each_other_through_their_names()
  local build = build_of({
    { "box.tl", RECORD },
    { "use.tl", "local Box = require(\"box\")\nlocal b: Box = { n = 1 }\nlocal bad: Box = { n = \"s\" }\nreturn b\n" },
  })
  local result = assert(build:result("use", true))
  assert(codes_of(result.bodies) == "not_assignable", codes_of(result.errors))
  assert(result.errors[1] ~= nil and support.nth(result.errors, 1).stage == "checked" and support.nth(result.errors, 1).kind == "error")
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
  build:provide(Driver.standard(function(module: string): string?
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
  assert(bad.broken and #bad.syntax >= 1 and bad.checked == nil and bad.errors[1] ~= nil and support.nth(bad.errors, 1).stage == "syntax")
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

local function test_the_globals_are_what_the_declaration_files_declare_less_what_the_host_withholds()
  local text = "global record Seen\n  n: integer\nend\nglobal record Withheld\n  n: integer\nend\n"
  local globals = Driver.globals({ Driver.declarations("lib", "lib.d.tl", text, {}) },
    function(names: mut {string: Scopes.Global})
      names["Withheld"] = nil
      names["Added"] = { space = "type", const = false }
    end)
  assert(globals["Seen"] ~= nil and globals["Withheld"] == nil and globals["Added"] ~= nil)
end

--- The lines of the problems `module` has against globals declared by the file `std.d.tl` with `text`.
local function problems_against(text: string, module: string): integer
  local build = Driver.new({
    globals = { Driver.declarations("std", "std.d.tl", text, {}) }, adjust = nil, external = {}, types = true,
  })
  build:provide(Driver.files(Driver.index({ { "m.tl", module } }, nothing)))
  local result = assert(build:result("m", true))
  return #result.errors + #result.scope_errors
end

local function test_the_globals_read_again_only_when_their_file_changes_and_a_changed_file_is_never_served_stale()
  local alpha = "global record Alpha\n  n: integer\nend\n"
  local beta = "global record Beta\n  n: integer\nend\n"
  local uses_alpha = "local a: Alpha = { n = 1 }\nreturn a\n"
  local uses_beta = "local b: Beta = { n = 1 }\nreturn b\n"
  assert(problems_against(alpha, uses_alpha) == 0, "Alpha is declared")
  assert(problems_against(alpha, uses_alpha) == 0, "Alpha is declared when the same text is met again")
  -- The same file name with other text: what it declared is gone, and what it declares now is there.
  assert(problems_against(beta, uses_alpha) > 0, "Alpha is no longer declared")
  assert(problems_against(beta, uses_beta) == 0, "Beta is declared")
  assert(problems_against(alpha, uses_beta) > 0, "Beta is no longer declared")
  assert(problems_against(alpha, uses_alpha) == 0, "Alpha is declared again")
end

local function test_a_module_has_its_errors_of_every_stage_in_source_order_and_its_warnings_apart()
  local build = build_of({
    { "m.tl", "local a: {number: integer} = {}\nlocal unused = 1\nlocal b: integer = 3.5\nreturn a\n" },
  })
  local result = assert(build:result("m", true))
  assert(codes_of(result.errors) == "float_key not_assignable", codes_of(result.errors))
  assert(support.nth(result.errors, 1).stage == "declared" and support.nth(result.errors, 2).stage == "checked")
  assert(#result.declared == 1 and #result.bodies == 1 and #result.scope_errors == 0 and #result.syntax == 0)
  assert(#result.warnings == 2 and result.warnings[1].kind == "unused" and result.warnings[1].stage == "warning" and
      result.warnings[1].code == "unused_variable" and result.warnings[2].code == "unused_variable", codes_of(result.warnings))
  assert(support.nth(result.errors, 1).y == 1 and support.nth(result.errors, 2).y == 3)
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
  local calls: mut {Ast.Node} = {}
  Node.walk(result.chunk, function(n: Ast.Node)
    if (n.kind == "Call") or (n.kind == "MethodCall") then
      calls[#calls + 1] = n
    end
  end)
  assert(#calls == 7, "calls: " .. tostring(#calls))
  local function took(i: integer): Types.Fn
    local t = result.callees[Node.base(support.nth(calls, i)).id]
    assert(t ~= nil and (t.tag == "fn"), "call " .. tostring(i) .. " took no function")
    return t
  end
  -- the method takes its record as the first parameter and answers two results
  assert(#took(1).params == 2 and #support.nth(took(1).rets, 1).items == 2)
  -- a chained call is judged by the function the inner call answered
  assert(#took(2).params == 0 and #support.nth(took(2).rets, 1).items == 2 and #support.nth(took(3).rets, 1).items == 1)
  -- the overload taken, not the first the name has
  assert(support.nth(took(4).params, 1).type.tag == "string" and support.nth(took(5).params, 1).type.tag == "named")
  -- a generic callee is the function with its type parameters, and a function literal argument is checked after the overload
  -- is chosen: the callee is the overload that takes a function of one parameter
  assert(#took(6).tparams == 1)
  local literal = support.nth(took(7).params, 1).type
  assert((literal.tag == "fn") and #literal.params == 1)
  local lean = Driver.new({ globals = { Driver.declarations("std", "std.d.tl", Programs.library, {}) }, adjust = nil, external = {}, types = false })
  lean:provide(Driver.files(Driver.index({ { "m.tl", source } }, nothing)))
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
  local lean = Driver.new({ globals = { Driver.declarations("std", "std.d.tl", Programs.library, {}) }, adjust = nil, external = {}, types = false })
  lean:provide(Driver.files(Driver.index(files, nothing)))
  assert(next(assert(lean:result("m", true)).types) == nil)
  -- the hint that reads the type of what a method is called on does not wait for the report
  local method = "local record R\n  get: function(self: R): integer\nend\nlocal r: R = { get = function(self: R): integer return 1 end }\n" ..
    "return r.get(r)\n"
  local hinted = Driver.new({ globals = { Driver.declarations("std", "std.d.tl", Programs.library, {}) }, adjust = nil, external = {}, types = false })
  hinted:provide(Driver.files(Driver.index({ { "h.tl", method } }, nothing)))
  local warned = assert(hinted:result("h", true))
  assert(#warned.warnings == 1 and warned.warnings[1].code == "method_dot", codes_of(warned.warnings))
  assert(next(warned.types) == nil)
end

local function test_the_test_functions_of_a_test_module_are_called_from_outside_and_are_not_unused()
  local text = "local function test_works()\nend\nlocal function helper()\nend\n"
  local build = build_of({ { "w_test.tl", text }, { "w.tl", text } })
  local index = Driver.index({ { "w_test.tl", text }, { "w.tl", text } }, nothing)
  local test_source = assert(index.by_module["w_test"])
  test_source.tests = true
  local tested = Driver.new({ globals = { Driver.declarations("std", "std.d.tl", Programs.library, {}) }, adjust = nil, external = {}, types = false })
  tested:provide(Driver.files(index))
  local discounted = assert(tested:result("w_test", true))
  assert(#discounted.warnings == 1, codes_of(discounted.warnings))
  assert(support.nth(discounted.warnings, 1).msg:find("helper", 1, true), support.nth(discounted.warnings, 1).msg)
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
  assert(support.nth(lines, 1):find("m.tl:5:", 1, true) and support.nth(lines, 1):find("(float_key)", 1, true), lines[1])
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
  assert(support.nth(lines, 1):find("m.tl:1:", 1, true), table.concat(lines, "\n"))
  for _, line in ipairs(lines) do
    assert(not line:find("pinned", 1, true), "a syntax error has no ceiling: " .. line)
  end
end

local function test_the_driver_checks_what_the_checker_does_alone()
  -- the same program through the driver and through the checker's own entry point has the same errors
  local source = "local record Box\n  n: integer\nend\nlocal b: Box = { n = \"s\" }\nlocal n: string = b.n\nreturn b\n"
  local run = Programs.run(source)
  local result = assert(build_of({ { "t.tl", source } }):result("t", true))
  local want: mut {string} = {}
  for _, e in ipairs(run.errors) do
    want[#want + 1] = tostring(e.code) .. tostring(e.y) .. ":" .. tostring(e.x)
  end
  local got: mut {string} = {}
  for _, e in ipairs(result.bodies) do
    got[#got + 1] = e.code .. tostring(e.y) .. ":" .. tostring(e.x)
  end
  assert(#want >= 2 and table.concat(got, " ") == table.concat(want, " "), table.concat(got, " ") .. " / " .. table.concat(want, " "))
  assert(#Check.codes > 0 and Ceilings.path == "build/ceilings.txt")
end

local function test_a_declaration_answers_to_its_whole_module_name_whichever_file_comes_first()
  local decl = { "p/foo.d.tl", "local record Box\n  s: string\nend\nreturn Box\n" }
  local user = { "q/use.tl", "local Box = require(\"p.foo\")\nlocal b: Box = { s = \"x\" }\nreturn b\n" }
  local orders = { { decl, user }, { user, decl } }
  for _, files in ipairs(orders) do
    local index = Driver.index(files, nothing)
    local winner = assert(index.by_module["p.foo"])
    assert(winner.dialect == "decl" and index.by_module["foo"] == nil and #winner.aliases == 0)
    local build = Driver.new({ globals = { Driver.declarations("std", "std.d.tl", Programs.library, {}) },
      adjust = nil, external = {}, types = false })
    build:provide(Driver.files(index))
    local first = assert(build:parsed("p.foo"))
    assert(first.source.filename == "p/foo.d.tl" and build:parsed("foo") == nil)
    local used = assert(build:result("q.use", true))
    assert(#used.errors == 0, codes_of(used.errors))
  end
end

--- Two files that are one module, a source and its package's entry, are not a pair: the first given answers, and the other is
--- a source of the index all the same.
local function test_the_first_of_two_files_of_one_module_answers()
  local one = "local n: integer = 1\nreturn n\n"
  local two = "local n: integer = 2\nreturn n\n"
  local index = Driver.index({ { "x.tl", one }, { "x/init.tl", two } }, nothing)
  assert(#index.sources == 2 and assert(index.by_module["x"]).filename == "x.tl")
  local reversed = Driver.index({ { "x/init.tl", two }, { "x.tl", one } }, nothing)
  assert(assert(reversed.by_module["x"]).filename == "x/init.tl")
end

--- The paths a test of the tree leaves out of its programs, as [`build.tree_program`] does.
local function testdata(file: string): boolean
  return file:find("^testdata/") ~= nil or file:find("/testdata/", 1, true) ~= nil
end

local UNTAGGED <const> = "local record R\nend\nreturn R\n"
local DECLARATION <const> = "--- @kind binding\n" .. UNTAGGED
local SOURCE <const> = "local n: integer = 1\nreturn n\n"

--- The complaint of a declaration beside a source of its module offers both ways out and names both files and the module.
local function test_pairing_names_both_files_and_offers_to_delete_or_rename()
  assert(Driver.pairing("lib/m.d.tl", "lib/m.tl", "lib.m") ==
      "lib/m.d.tl: lib/m.tl is already the module lib.m. A .d.tl is only for a module implemented in C, and the .tl is " ..
      "what is checked, so one module cannot have both. If the .tl is the module, delete lib/m.d.tl. To keep both, " ..
      "rename one of them so that they are different modules.")
end

--- A pair is found whichever way each of its files is written, in either order of the entries.
local function test_paired_finds_a_declaration_beside_a_source_of_its_module_in_each_form()
  local forms: {{string}} = {
    { "x.tl", "x.d.tl", "x" },
    { "x/init.tl", "x.d.tl", "x" },
    { "x.tl", "x/init.d.tl", "x" },
    { "x/init.tl", "x/init.d.tl", "x" },
    { "a/b.tl", "a/b.d.tl", "a.b" },
  }
  for _, form in ipairs(forms) do
    local source, declaration, module = assert(form[1]), assert(form[2]), assert(form[3])
    local want = Driver.pairing(declaration, source, module)
    local together: {{string}} = { { source, SOURCE }, { declaration, DECLARATION } }
    local backwards: {{string}} = { { declaration, DECLARATION }, { source, SOURCE } }
    assert(Driver.declared(together, nothing, false) == want, source .. " + " .. declaration)
    assert(Driver.declared(backwards, nothing, false) == want, declaration .. " + " .. source)
  end
  -- Not a pair: different modules, a test or an example beside a declaration, and a declaration alone.
  local apart: {{string}} = {
    { "x.tl", SOURCE }, { "y.d.tl", DECLARATION }, { "x_test.tl", SOURCE }, { "z.d.tl", DECLARATION },
    { "z_example.tl", SOURCE }, { "w/init.d.tl", DECLARATION },
  }
  assert(Driver.declared(apart, nothing, false) == "")
end

--- A pair under `testdata/` is a fixture of a test, left out of the programs, and so not refused; nor is a path the
--- caller skips.
local function test_paired_leaves_out_what_is_skipped()
  local fixture: {{string}} = {
    { "testdata/m.tl", SOURCE }, { "testdata/m.d.tl", DECLARATION },
    { "lib/testdata/n.tl", SOURCE }, { "lib/testdata/n.d.tl", DECLARATION },
  }
  assert(Driver.declared(fixture, testdata, false) == "")
  assert(Driver.declared(fixture, nothing, false) ~= "")
end

--- Several pairs are all told, one to a line and in the order of their declarations' paths, whatever the order of the entries.
local function test_paired_tells_every_pair_in_the_order_of_the_declarations()
  local entries: {{string}} = {
    { "z.d.tl", DECLARATION }, { "b/c.tl", SOURCE }, { "z.tl", SOURCE }, { "a.tl", SOURCE }, { "b/c.d.tl", DECLARATION },
    { "a.d.tl", DECLARATION }, { "lone.d.tl", DECLARATION },
  }
  local want = table.concat({
    Driver.pairing("a.d.tl", "a.tl", "a"),
    Driver.pairing("b/c.d.tl", "b/c.tl", "b.c"),
    Driver.pairing("z.d.tl", "z.tl", "z"),
  }, "\n")
  assert(Driver.declared(entries, nothing, false) == want, Driver.declared(entries, nothing, false))
  local reversed: mut {{string}} = {}
  for i = #entries, 1, -1 do reversed[#reversed + 1] = assert(entries[i]) end
  assert(Driver.declared(reversed, nothing, false) == want)
end

--- The words a declaration that names no kind is refused in: the file, and both ways out.
local function unnamed_words(file: string): string
  return file .. ": a .d.tl must name what it is, and this one names nothing. If it declares a module implemented in C, " ..
    "add the line `--- @kind binding` to its leading comment; otherwise write it as a .tl (types and code in a .tl are " ..
    "checked and real at run time)."
end

--- A `.d.tl` names what it is or is refused: a module implemented in C (`binding`) is accepted, and one that says nothing,
--- whether it holds types, globals or a module, is refused naming the file and both ways out.
local function test_naming_refuses_a_declaration_that_says_nothing_and_accepts_a_binding()
  assert(Driver.naming("lib/m.d.tl", UNTAGGED, false) == unnamed_words("lib/m.d.tl"))
  assert(Driver.naming("types.d.tl", "local record types\n  record Page\n  end\nend\nreturn types\n", false) == unnamed_words("types.d.tl"))
  assert(Driver.naming("g.d.tl", "global count: integer\n", false) == unnamed_words("g.d.tl"))
  assert(Driver.naming("g.d.tl", "global record Foo\nend\n", false) == unnamed_words("g.d.tl"))
  assert(Driver.naming("lib/m.d.tl", DECLARATION, false) == "")
  assert(Driver.naming("g.d.tl", "--- A C global.\n--- @kind binding\nglobal count: integer\n", false) == "")
  assert(Driver.naming("g.d.tl", "--- @kind binding\r\nglobal count: integer\r\n", false) == "")
  -- The line counts only in the opening doc block, on a line of its own.
  assert(Driver.naming("m.d.tl", UNTAGGED .. "--- @kind binding\n", false) == unnamed_words("m.d.tl"))
  assert(Driver.naming("m.d.tl", "--- @kind binding and more\n" .. UNTAGGED, false) == unnamed_words("m.d.tl"))
  assert(Driver.naming("m.d.tl", "--- @kind module\n" .. UNTAGGED, false) == unnamed_words("m.d.tl"))
end

--- The language's own kind is for the two files that are the build's globals and no other, and only in cosmic's own tree: a
--- project's file at the same path is refused for it.
local function test_naming_accepts_the_language_kind_only_for_the_files_of_the_globals_of_the_own_tree()
  local text = "--- @kind language\ndo\nend\n"
  assert(Driver.naming("lang/prelude.d.tl", text, true) == "")
  assert(Driver.naming("lang/stdlib.d.tl", text, true) == "")
  local words = " is only for the language's own declarations, lang/prelude.d.tl and lang/stdlib.d.tl, which are the " ..
    "build's globals. If it declares a module implemented in C, add the line `--- @kind binding` to its leading comment; " ..
    "otherwise write it as a .tl (types and code in a .tl are checked and real at run time)."
  for _, file in ipairs({ "lang/other.d.tl", "lib/lang/stdlib.d.tl", "stdlib.d.tl", "cosmic/internal/x.d.tl", "lang/stdlib/init.d.tl" }) do
    assert(Driver.naming(file, text, true) == file .. ": `--- @kind language`" .. words, Driver.naming(file, text, true))
  end
  -- Outside cosmic's own tree (a project, `cosmic compile`, the editor of one) the kind is not accepted anywhere, the two
  -- files of the globals included, and the message says so rather than naming the file the user gave.
  local outside = " is accepted only when building cosmic's own tree, and this is not one. If it declares a module " ..
    "implemented in C, add the line `--- @kind binding` to its leading comment; otherwise write it as a .tl (types and " ..
    "code in a .tl are checked and real at run time)."
  for _, file in ipairs({ "lang/prelude.d.tl", "lang/stdlib.d.tl", "lang/other.d.tl", "x.d.tl" }) do
    assert(Driver.naming(file, text, false) == file .. ": `--- @kind language`" .. outside, Driver.naming(file, text, false))
  end
  -- Untagged, the two files of the own tree are told to say `language`; a project's file of that name is told as any other.
  assert(Driver.naming("lang/stdlib.d.tl", "do\nend\n", true) == "lang/stdlib.d.tl: the language's own declarations must " ..
      "say so: add the line `--- @kind language` to its leading comment")
  assert(Driver.naming("lang/stdlib.d.tl", "do\nend\n", false) == unnamed_words("lang/stdlib.d.tl"))
end

--- A declaration names exactly one kind: two lines of kinds are refused, whichever the two and wherever the file.
local function test_naming_refuses_a_declaration_that_names_two_kinds()
  local both = "--- @kind binding\n--- @kind language\nlocal record R\nend\nreturn R\n"
  local words = ": a .d.tl must name exactly one kind, and this one names binding and language: keep the one line that says " ..
    "what it is (`--- @kind binding` for a module implemented in C)"
  for _, file in ipairs({ "lib/m.d.tl", "lang/stdlib.d.tl" }) do
    for _, own in ipairs({ true, false }) do
      assert(Driver.naming(file, both, own) == file .. words, Driver.naming(file, both, own))
    end
  end
  assert(Driver.naming("m.d.tl", "--- @kind language\n--- @kind binding\n", false) == "m.d.tl" .. words)
end

--- Every declaration of the entries that names nothing is told, one to a line in the order of the files, whatever the order
--- of the entries; a file the caller skips, a source and a tagged declaration are not.
local function test_unnamed_tells_every_declaration_that_says_nothing()
  local entries: {{string}} = {
    { "z.d.tl", UNTAGGED }, { "b.tl", SOURCE }, { "ok.d.tl", DECLARATION },
    { "a.d.tl", UNTAGGED }, { "testdata/t.d.tl", UNTAGGED }, { "c/init.d.tl", "global n: integer\n" },
  }
  local want = table.concat({ unnamed_words("a.d.tl"), unnamed_words("c/init.d.tl"), unnamed_words("z.d.tl") }, "\n")
  assert(Driver.declared(entries, testdata, false) == want, Driver.declared(entries, testdata, false))
  local reversed: mut {{string}} = {}
  for i = #entries, 1, -1 do reversed[#reversed + 1] = assert(entries[i]) end
  assert(Driver.declared(reversed, testdata, false) == want)
  assert(Driver.declared(entries, nothing, false):find(unnamed_words("testdata/t.d.tl"), 1, true) ~= nil)
  assert(Driver.declared({ { "ok.d.tl", DECLARATION }, { "m.tl", SOURCE } }, nothing, false) == "")
end

--- `declared` is the pair complaints and then those of a declaration that names nothing, one complaint to a file: a
--- declaration in a pair is told of the pair alone, as deleting it clears both.
local function test_declared_tells_a_pair_and_a_declaration_that_says_nothing_once_each()
  local entries: {{string}} = {
    { "p.d.tl", UNTAGGED }, { "p.tl", SOURCE }, { "u.d.tl", UNTAGGED },
    { "q.d.tl", DECLARATION }, { "q.tl", SOURCE },
  }
  local want = table.concat({
    Driver.pairing("p.d.tl", "p.tl", "p"),
    Driver.pairing("q.d.tl", "q.tl", "q"),
    unnamed_words("u.d.tl"),
  }, "\n")
  assert(Driver.declared(entries, nothing, false) == want, Driver.declared(entries, nothing, false))
  assert(Driver.declared({ { "ok.d.tl", DECLARATION }, { "m.tl", SOURCE } }, nothing, false) == "")
end

local function test_a_test_module_is_a_file_that_ends_in_test_and_its_functions_are_not_unused()
  local text = "local function test_x()\nend\n"
  local index = Driver.index({ { "a_test.tl", text }, { "a.tl", text }, { "a_tested.tl", text } }, nothing)
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

local function test_a_source_written_from_another_file_is_the_module_it_says_and_is_pinned_under_the_name_it_gives()
  local text = "local record Box\n  n: integer\nend\nlocal bad: integer = 3.5\nreturn Box\n"
  local index = Driver.index({
    { "doc/guides/x.md", text, "doc.guides.x" },
    { "gen/sys.d.tl", "local record Sys\n  n: {number: integer}\nend\nreturn Sys\n", "cosmic.sys", "core/sys.h" },
  }, nothing)
  local guide = assert(index.by_module["doc.guides.x"])
  assert(guide.filename == "doc/guides/x.md" and guide.pinned == "" and guide.dialect == "tl" and guide.checked)
  assert(index.by_module["x"] == nil and index.by_module["doc.guides.x.md"] == nil)
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

local function test_every_source_tells_the_generator_what_is_never_false_and_the_text_the_checker_read()
  local text = "local n = 3\nlocal s = n > 2 and 1 or 2\nreturn s\n"
  -- a source is read as it is written, and the generator is told what the rule knows
  local written = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  written:provide(Driver.files(Driver.index({ { "m.tl", text } }, nothing)))
  local two = assert(written:parsed("m"))
  assert(two.never_false == Truthy.never_false and two.text == text)
end

--- The Lua the generator writes of the module `m` of `text`.
local function lua_of(text: string): string
  local build = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  build:provide(Driver.files(Driver.index({ { "m.tl", text } }, nothing)))
  local read = assert(build:parsed("m"))
  return Codegen.generate(read.chunk, read.scoped, read.never_false).text
end

--- The value `if c then (v as T) else "z"` gives for `v` of `value`, a lie about the type `T`: the program's answer is `v`.
local function cast_if(value: string, cast: string): any
  local text = table.concat({
    "local v: any = " .. value,
    "local c: boolean = true",
    "local r: any = if c then (v as " .. cast .. ") else \"z\"",
    "return r",
    "",
  }, "\n")
  local lua = lua_of(text)
  return assert(load(lua, "=m", "t"))()
end

local function test_a_cast_does_not_make_the_middle_of_an_if_expression_never_false()
  -- the cast promises a type and holds no value: a nil or a false behind it is the answer, not the else branch
  assert(cast_if("nil", "string") == nil)
  assert(cast_if("nil", "{string}") == nil)
  assert(cast_if("nil", "integer") == nil)
  assert(cast_if("false", "string") == false)
  assert(cast_if("false", "{string}") == false)
  assert(cast_if("false", "integer") == false)
  -- and one that is a value gives itself
  assert(cast_if("\"s\"", "string") == "s")
  assert(cast_if("7", "integer") == 7)
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

local function test_a_retired_module_is_forgotten_and_a_module_that_requires_it_is_checked_as_before()
  local build = build_of({
    { "box.tl", RECORD },
    { "use.tl", "local Box = require(\"box\")\nlocal b: Box = { n = 1 }\nlocal s: string = b.n\nreturn b\n" },
  })
  build:lower({ "box" })
  local box = assert(build:result("box", true))
  assert(box.lowered ~= nil and #box.errors == 0)
  build:retire("box")
  -- the build answers nothing for it, and reads it again outside the program when asked to
  assert(build:result("box", true) == nil)
  local again = assert(build:parsed("box"))
  assert(again ~= box and again.lowered == nil and not again.broken)
  assert(build:parsed("box") ~= again, "a new reading each time, not one the build holds")
  -- what the program knows of it stays: the type of its field is read through it
  local used = assert(build:result("use", true))
  assert(codes_of(used.errors) == "not_assignable", codes_of(used.errors))
  assert(assert(build.program.modules["box"]).lowered)
  assert(build:retired("box") and not build:retired("use") and not build:retired("nothing here"))
end

local function test_a_build_tells_what_it_has_without_reading_it()
  local build = build_of({ { "box.tl", RECORD } })
  assert(build:provides("box") and build:provides("std") and not build:provides("nothing here"))
  build:lower({ "box" })
  build:retire("box")
  assert(build:provides("box"), "a retired module is still the build's")
end

local function test_a_retired_module_leaves_no_syntax_tree_behind()
  local build = build_of({ { "box.tl", RECORD } })
  build:lower({ "box" })
  local weak: mut {Ast.Chunk} = setmetatable({}, { __mode = "v" })
  weak[1] = assert(build:result("box", true)).chunk
  collectgarbage("collect")
  assert(weak[1] ~= nil, "the build holds the tree until it is retired")
  build:retire("box")
  collectgarbage("collect")
  assert(weak[1] == nil, "the tokens and the tree of a retired module are garbage")
end

local function test_retiring_every_module_forgets_them_all_and_keeps_the_globals()
  local build = build_of({
    { "box.tl", RECORD },
    { "use.tl", "local Box = require(\"box\")\nlocal b: Box = { n = 1 }\nreturn b\n" },
  })
  assert(#assert(build:result("use", true)).errors == 0)
  build:retire_all()
  assert(build:result("use", true) == nil and build:result("box", true) == nil)
  assert(assert(build.program.modules["use"]).lowered and assert(build.program.modules["box"]).lowered)
end

local function test_a_module_lowered_again_after_a_replacement_reads_the_modules_it_retired_from_their_sources()
  local build = build_of({
    { "box.tl", RECORD },
    { "use.tl", "local Box = require(\"box\")\nlocal b: Box = { n = 1 }\nreturn b\n" },
  })
  build:lower({ "box" })
  assert(#assert(build:result("box", true)).errors == 0)
  build:retire("box")
  assert(#assert(build:result("use", true)).errors == 0)
  -- `use` is lowered, so the program begins again; `box` is read from its source when `use` requires it
  local program = build.program
  assert(build:replace("use", "local Box = require(\"box\")\nlocal b: Box = { n = \"one\" }\nreturn b\n") ~= nil)
  assert(build.program ~= program)
  assert(codes_of(assert(build:result("use", true)).errors) == "not_assignable")
  assert(assert(build:result("box", true)).lowered ~= nil, "lowered again, from its source")
end

local function test_replacing_a_module_the_program_has_not_met_keeps_everything_lowered()
  local build = build_of({
    { "box.tl", RECORD },
    { "use.tl", "local Box = require(\"box\")\nlocal b: Box = { n = 1 }\nreturn b\n" },
    { "other.tl", "local record O\nend\nreturn O\n" },
  })
  build:lower({ "other" })
  local other = assert(build:result("other", true))
  local program = build.program
  local replaced = assert(build:replace("box", "local record Box\n  n: string\nend\nreturn Box\n"))
  assert(build.program == program, "no module of the program depends on the text that goes")
  assert(assert(build:parsed("box")) == replaced and assert(build:parsed("other")) == other)
  assert(codes_of(assert(build:result("use", true)).errors) == "not_assignable")
end

local function test_a_cycle_of_modules_keeps_the_errors_of_the_check_that_waited_for_the_other()
  local build = build_of({
    { "a.tl", "local type B = require(\"b\")\nlocal class C is B.I\nend\nreturn C\n" },
    { "b.tl", "local type A = require(\"a\")\nlocal record B\n  interface I\n    n: integer\n  end\nend\nreturn B\n" },
  })
  build:lower({ "b" })
  local a = assert(build:result("a", true))
  assert(codes_of(a.declared) == "interface_disagrees", codes_of(a.declared))
  build:retire("a")
  build:retire("b")
  assert(build:result("a", true) == nil)
end

local function test_the_scratch_build_reads_a_module_without_lowering_it_in_the_build()
  local build = build_of({
    { "box.tl", RECORD },
    { "use.tl", "local Box = require(\"box\")\nlocal b: Box = { n = 1 }\nreturn b\n" },
  })
  local scratch = build:scratch()
  assert(scratch ~= build and build:scratch() == scratch, "one scratch build, made when first asked for")
  scratch:lower({ "use" })
  assert(assert(scratch:result("use", true)).lowered ~= nil)
  scratch:retire_all(function(outcome: Driver.Outcome): boolean
    return outcome.module == "box"
  end)
  assert(scratch:retired("use") and not scratch:retired("box"), "what the answer keeps is not retired")
  scratch:retire_all()
  assert(scratch:retired("box"))
  -- nothing was met in this build
  assert(build.program.modules["use"] == nil and build.program.modules["box"] == nil and not build:retired("use"))
  assert(#assert(build:result("use", true)).errors == 0)
end

local function test_a_replacement_is_read_as_written_and_keeps_what_the_module_was()
  local files = { { "m_test.tl", "local function test_x()\nend\n" }, { "d.tl", "return 1\n" } }
  local build = Driver.new({ globals = {}, adjust = nil, external = {}, types = false })
  build:provide(Driver.files(Driver.index(files, nothing)))
  local old = assert(build:parsed("m_test"))
  assert(old.source.tests)
  -- the replacement is read as written: a `where` clause is a syntax error
  local replaced = assert(build:replace("m_test", "local record R\n  where self.a == 1\nend\nreturn R\n"))
  assert(replaced.source.tests and replaced.source.filename == "m_test.tl")
  assert(replaced.broken)
  local looked = assert(build:result("m_test", true))
  local first = looked.errors[1]
  assert(looked == replaced and first ~= nil and first.stage == "syntax")
  assert(not assert(build:parsed("d")).broken)
end

local function test_a_standard_library_module_is_read_as_written_and_a_declaration_is_read_as_one()
  local texts: {string: string} = {
    ["cosmic.box"] = "local record Box\n  n: integer | nil\nend\nreturn Box\n",
    ["cosmic.sys"] = "local record Sys\n  n: integer\nend\nreturn Sys\n",
  }
  local function read(module: string): string?
    return texts[module]
  end
  local plain = Driver.standard(read)("cosmic.box")
  assert(plain ~= nil and not plain.checked and plain.dialect == "tl" and plain.filename == "cosmic/box.tl")
  assert(Driver.standard(read)("cosmic.none") == nil)
  -- one it is told is a declaration is a declaration file
  local declared = Driver.standard(read, function(module: string): boolean
    return module == "cosmic.sys"
  end)
  local sys, box = declared("cosmic.sys"), declared("cosmic.box")
  assert(sys ~= nil and sys.dialect == "decl" and sys.filename == "cosmic/sys.d.tl" and not sys.checked)
  assert(box ~= nil and box.dialect == "tl")
end

local function test_a_problem_of_an_argument_keeps_the_call_the_checker_named_and_another_problem_keeps_none()
  local build = build_of({
    { "m.tl", "local function put(n: integer): integer\n  return n\nend\nlocal a = put(\"s\")\nlocal b: integer = \"t\"\nlocal record M\n  n: integer\nend\nreturn M\n" },
  })
  local result = assert(build:result("m", true))
  assert(codes_of(result.errors) == "not_assignable not_assignable", codes_of(result.errors))
  local call, assignment = assert(result.errors[1]), assert(result.errors[2])
  local argument = call.argument
  assert(argument ~= nil and argument.callee == "put" and argument.position == 1, codes_of(result.errors))
  assert(assignment.argument == nil)
end

--- The message of the `require_unknown` that `user` (a module of `files`) is refused for, and "" where it has none.
local function refusal_of(files: {{string}}, user: string): string
  local build = build_of(files)
  local result = assert(build:result(user, true))
  for _, e in ipairs(result.bodies) do
    if e.code == "require_unknown" then
      return e.msg
    end
  end
  return ""
end

local function test_a_module_is_required_by_its_whole_name_and_a_bare_last_segment_is_refused_with_the_one_it_may_mean()
  local m = { "b/m.tl", "local record M\n  n: integer\nend\nlocal m: M = { n = 1 }\nreturn m\n" }
  local bare = { "use.tl", "local m = require(\"m\")\nreturn m\n" }
  assert(refusal_of({ m, bare }, "use") == "the project has no module `m`; did you mean `b.m` (b/m.tl)?",
    refusal_of({ m, bare }, "use"))
  local whole = { "use.tl", "local m = require(\"b.m\")\nlocal n: integer = m.n\nreturn n\n" }
  local result = assert(build_of({ m, whole }):result("use", true))
  assert(#result.errors == 0, codes_of(result.errors))
end

local function test_two_modules_ending_in_a_name_are_both_named_and_neither_is_chosen_by_order()
  local a = { "a/m.tl", "return 1\n" }
  local b = { "b/m.tl", "return 2\n" }
  local bare = { "use.tl", "local m = require(\"m\")\nreturn m\n" }
  local want = "the project has no module `m`; did you mean one of `a.m` (a/m.tl), `b.m` (b/m.tl)?"
  assert(refusal_of({ a, b, bare }, "use") == want, refusal_of({ a, b, bare }, "use"))
  assert(refusal_of({ b, a, bare }, "use") == want, refusal_of({ b, a, bare }, "use"))
end

local function test_a_missing_module_with_no_candidate_gets_no_hint()
  local bare = { "use.tl", "local m = require(\"nope\")\nreturn m\n" }
  assert(refusal_of({ { "b/m.tl", "return 2\n" }, bare }, "use") == "the project has no module `nope`")
end

local function test_a_hint_names_only_what_the_file_may_require()
  local deep = { "x/y/m.tl", "local record M\n  n: integer\nend\nreturn M\n" }
  local outside = { "use.tl", "local m = require(\"y.m\")\nreturn m\n" }
  assert(refusal_of({ deep, outside }, "use") == "the project has no module `y.m`")
  local inside = { "x/y/use.tl", "local m = require(\"y.m\")\nreturn m\n" }
  assert(refusal_of({ deep, inside }, "x.y.use") == "the project has no module `y.m`; did you mean `x.y.m` (x/y/m.tl)?",
    refusal_of({ deep, inside }, "x.y.use"))
end

local function test_a_hint_never_names_the_file_itself_and_a_long_list_is_cut_short()
  local own = { "b/m.tl", "local m = require(\"m\")\nreturn m\n" }
  assert(refusal_of({ own }, "b.m") == "the project has no module `m`", refusal_of({ own }, "b.m"))
  local files: mut {{string}} = { { "use.tl", "local m = require(\"m\")\nreturn m\n" } }
  for n = 1, 25 do
    files[#files + 1] = { string.format("d%02d/m.tl", n), "return 1\n" }
  end
  local said = refusal_of(files, "use")
  assert(said:find("did you mean one of `d01.m` (d01/m.tl), `d02.m` (d02/m.tl), `d03.m` (d03/m.tl), `d04.m` (d04/m.tl), " ..
      "`d05.m` (d05/m.tl) and 20 more?", 1, true) ~= nil and #said < 300, said)
end
