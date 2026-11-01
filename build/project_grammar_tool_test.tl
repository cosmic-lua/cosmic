--- A project outside cosmic's tree, built and tested with the new checker (`COSMIC_GRAMMAR=new`) as the tool runs it: its
--- globals are the declarations of the standard library the tool carries ([`build.checker_declarations`]), since the project has
--- no `checker/` to read them from. The project of testdata/projects/project is written in the grammar and passes; the one of
--- testdata/projects/fork_only is written in forms the new grammar refuses, and is refused with the new checker's words and fix.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Test = require("cosmic.test")
local CheckerDeclarations = require("build.checker_declarations")
local this_program = require("build.this_program")

--- The program itself, which this test starts, and the two projects it builds.
Test.policy{ cpu_features = true, profiles = { "cosmic" }, grants = {
  { path = "o/bin", letters = "rx" }, { path = "testdata/projects", letters = "r" }, { path = "lang/stdlib.d.tl", letters = "r" },
  { path = "lang/prelude.d.tl", letters = "r" },
} }

--- A copy of the project `name` of testdata/projects under `tmp`, a tree of its own for a run in `grammar`.
local function copy_of(tmp: string, name: string, grammar: string): string
  local root = tmp .. "/" .. name .. "-" .. grammar
  assert(Fs.copy_tree("testdata/projects/" .. name, root))
  return root
end

--- Runs `cosmic test` in `root` with `grammar` as COSMIC_GRAMMAR, unsandboxed (a sandbox nested in this test's own may be
--- refused where the host nests only two deep), and answers what it said.
local function tested(root: string, tmp: string, grammar: string): Child.Result, string
  local output = tmp .. "/out." .. tostring(Clock.monotonic_ns())
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["COSMIC_BUILD_CACHE"] = "0"
  env["COSMIC_GRAMMAR"] = grammar
  env["TMPDIR"] = tmp
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ns = Clock.seconds(120),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  return assert(result, trouble), (assert(Fs.read(output)))
end

local function test_a_project_outside_the_tree_is_built_and_tested_with_the_new_checker(tmp: string)
  local root = copy_of(tmp, "project", "new")
  local result, text = tested(root, tmp, "new")
  assert(result.ok and text:find("test: 3 tests passed in 2 modules", 1, true) ~= nil, text)
  -- the fork's grammar is gone: the mode that names it is refused, naming the verb that rewrites a project to the new one
  local forked, forked_text = tested(copy_of(tmp, "project", "teal"), tmp, "teal")
  assert(not forked.ok and forked_text:find("COSMIC_GRAMMAR=teal: the fork's grammar is gone; " ..
      "rewrite a project to the new grammar by hand, as doc/guides/project.md says", 1, true) ~= nil, forked_text)
end

local function test_a_project_written_in_forms_the_new_grammar_refuses_is_refused_with_the_fix(tmp: string)
  local root = copy_of(tmp, "fork_only", "new")
  local result, text = tested(root, tmp, "new")
  assert(not result.ok and result.code == 1, text)
  -- nil for a type that does not hold it: the error says what to write
  assert(text:find("lookup.tl:10:12: nil is given as return value 1, where `Entry` is wanted (nil_not_allowed): give a value, " ..
      "or declare what takes it `Entry?`", 1, true) ~= nil, text)
  -- a function assigned to a path of two dots
  assert(text:find("cache.tl:8:1: `function Kv.Lru.get` has more than one dot (function_path): assign the function to the " ..
      "field: `Kv.Lru.get = function(...) ... end`", 1, true) ~= nil, text)
  -- what requires a refused module is told so, and no test ran
  assert(text:find("lookup_test.tl: not compiled: it requires lookup, which the new checker refused", 1, true) ~= nil, text)
  assert(text:find("test: 4 of 4 tests failed", 1, true) ~= nil, text)
  -- a project has no pins to raise: nothing in its errors speaks of one
  assert(text:find("pinned", 1, true) == nil and text:find("ceilings.txt", 1, true) == nil, text)
end

--- A project of `files` under `tmp`, a tree of its own for a run in `grammar`.
local function project_of(tmp: string, name: string, files: {string: string}): string
  local root = tmp .. "/" .. name
  assert(Fs.mkdirs(root))
  for file, source in pairs(files) do
    assert(Fs.write(root .. "/" .. file, source))
  end
  return root
end

--- A project is judged by the standard library the tool carries ([`lang/stdlib.d.tl`]): `tonumber` answers nil for text that
--- is no number, which a sum does not take.
local function test_a_project_is_judged_by_the_new_checkers_standard_library(tmp: string)
  local files: {string: string} = {
    ["inc.tl"] = "local function inc(s: string): number\n  return tonumber(s) + 1\nend\nreturn inc\n",
    ["inc_test.tl"] = "local inc = require(\"inc\")\n\nlocal function test_inc()\n  assert(inc(\"1\") == 2)\nend\n",
  }
  local result, text = tested(project_of(tmp, "inc-new", files), tmp, "new")
  assert(not result.ok, text)
  assert(text:find("inc.tl:2:", 1, true) ~= nil and text:find("`number?`", 1, true) ~= nil and
      text:find("(nil_not_allowed)", 1, true) ~= nil, text)
end

--- What the tool prints of the text its `decls` carry under `module`, as a length and a digest.
local function carried(module: string): string
  local chunk = "local Store = require('cosmic.store') local Hash = require('cosmic.hash') " ..
    "local text = assert(Store.source('" .. module .. "')) print(#text, Hash.hex_sha256(text))"
  local started = this_program.program({ "-e", chunk }, {
    env = this_program.environment(), stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60),
  })
  local result = assert(Child.run(started.argv, started.options))
  assert(result.code == 0, (result.stdout or "") .. (result.stderr or ""))
  return result.stdout or ""
end

--- The tool carries the declarations a project is typed against, as its projection carries the bindings of C: the files of
--- the tree it was built from, which a project has no `lang/` of cosmic's to read.
local function test_the_tool_carries_the_declarations_it_types_a_project_against()
  local stdlib = assert(Fs.read("lang/stdlib.d.tl"))
  assert(carried(CheckerDeclarations.stdlib_module()) == tostring(#stdlib) .. "\t" .. Hash.hex_sha256(stdlib) .. "\n")
  local prelude = assert(Fs.read("lang/prelude.d.tl"))
  assert(carried(CheckerDeclarations.prelude_module()) == tostring(#prelude) .. "\t" .. Hash.hex_sha256(prelude) .. "\n")
end
