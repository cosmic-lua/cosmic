local Fuzz = require("build.fuzz")
local test_inputs = require("build.test_inputs")
local type analyzer = require("build.analyzer")
local type declared_inputs = require("build.inputs")
local type positions = require("build.positions")

local type Module = positions.Module

--- A module of a small tree: its path, file, what it requires, and what
--- it declares.
local function module(path: string, file: string, requires: {string},
                      inputs?: analyzer.Declared): Module
  return { path = path, file = file, kind = "test", requires = requires,
    tests = { "test_one", "test_two" }, inputs = inputs }
end

--- A declaration of what `fields` names, the rest left out.
local function declaring(fields: analyzer.Declared): analyzer.Declared
  return { line = 1, reads = fields.reads or {}, host = fields.host or {},
    env = fields.env or {}, network = fields.network or {}, processes = fields.processes == true,
    tool = fields.tool == true, store = fields.store == true }
end

--- A tree of four modules: a test requiring a helper, which requires a
--- module of its own and one only a declaration file answers for; the
--- helper runs fuzz properties when `fuzzes` says so.
local function tree(inputs?: analyzer.Declared, fuzzes?: boolean): Module, {string:Module}
  local helper_requires = { "lib.deep", "lib.declared" }
  if fuzzes then helper_requires[#helper_requires + 1] = "build.fuzz" end
  local helper = module("lib.helper", "lib/helper.tl", helper_requires)
  local deep = module("lib.deep", "lib/deep/init.tl", {})
  local other = module("lib.other", "lib/other.tl", {})
  local m = module("lib.thing_test", "lib/thing_test.tl", { "lib.helper", "cosmic.fs" }, inputs)
  return m, { [m.path] = m, [helper.path] = helper, [deep.path] = deep, [other.path] = other }
end

--- The tree's declaration files, by import path, as the build's
--- `inputs` view names them.
local staged: {string:string} = { ["lib.declared"] = "lib/declared.d.tl" }

--- A test's default inputs are its module's import closure, as files --
--- a declaration file for a module only it answers for included, and a
--- module the binary carries left out -- the pinned environment, and
--- nothing else of the tree, the host, the network or processes.
local function test_the_default_inputs_are_the_closure_and_the_pinned_environment()
  local m, by_path = tree()
  local effective = test_inputs.effective(m, by_path, staged)
  local files: {string} = {}
  for file in pairs(effective.files) do files[#files + 1] = file end
  table.sort(files)
  assert(table.concat(files, " ") ==
    "lib/declared.d.tl lib/deep/init.tl lib/helper.tl lib/thing_test.tl", table.concat(files, " "))
  assert(#effective.reads == 0 and #effective.host == 0)
  assert(effective.env.TMPDIR and effective.env.HOME and effective.env.FUZZ_SEED)
  assert(not effective.env.USER and not effective.env["*"])
  assert(next(effective.network) == nil)
  assert(not effective.processes and not effective.tool and not effective.store)
  assert(test_inputs.covers_tree(effective, "lib/helper.tl", "o"))
  assert(not test_inputs.covers_tree(effective, "lib/other.tl", "o"))
  -- What a directory an input sits in is, but not what it holds.
  assert(test_inputs.covers_tree(effective, "lib/deep", "s"))
  assert(test_inputs.covers_tree(effective, ".", "s"))
  assert(not test_inputs.covers_tree(effective, ".", "d"))
  assert(not test_inputs.covers_tree(effective, "lib/deep", "d"))
  assert(not test_inputs.covers_tree(effective, "lib/deep", "o"))
  assert(not test_inputs.covers_env(effective, "USER"))
end

--- A module's declaration adds to its defaults, each path with all
--- beneath it.
local function test_a_declaration_adds_to_the_defaults()
  local m, by_path = tree(declaring({ reads = { "data/" }, host = { "/etc/localtime" },
    env = { "*" }, network = { "127.0.0.1" }, processes = true, tool = true, store = true }))
  local effective = test_inputs.effective(m, by_path, staged)
  assert(test_inputs.covers_tree(effective, "data/a/b.txt", "o"))
  assert(test_inputs.covers_tree(effective, "data", "d"))
  assert(not test_inputs.covers_tree(effective, "database", "o"))
  assert(test_inputs.covers_tree(effective, "o/bin/cosmic", "o"))
  assert(test_inputs.covers_tree(effective, "o/cosmic.db", "o"))
  assert(test_inputs.covers_host(effective, "/etc/localtime", "o"))
  assert(test_inputs.covers_host(effective, "/etc", "s"))
  assert(not test_inputs.covers_host(effective, "/etc/passwd", "o"))
  assert(test_inputs.covers_env(effective, "ANYTHING"))
  assert(test_inputs.covers_network(effective, "http://127.0.0.1:1/x"))
  assert(test_inputs.covers_network(effective, "HTTP://user@127.0.0.1"))
  assert(not test_inputs.covers_network(effective, "https://example.com/"))
  assert(effective.processes)
end

--- Every fuzz corpus is a default input of a test whose closure runs
--- properties, where `build.fuzz` looks for one -- a property's name
--- may be computed -- and of no other test.
local function test_a_fuzz_tests_corpora_are_default_inputs(tmp: string)
  local m, by_path = tree(nil, true)
  local effective = test_inputs.effective(m, by_path, staged)
  local name = "Keep " .. string.rep("me", 1) .. "!"
  -- `build.fuzz` names the directory it looks in, in its report of a
  -- failure.
  local ok, report = pcall(Fuzz.run, {
    name = name, dir = tmp, iters = 1,
    gen = function(_: Fuzz.Source): string return "x" end,
    check = function(_: string): boolean, string return false, "no" end,
  })
  local corpus = tostring(report):match("mkdir %-p (%S+) ")
  assert(not ok and corpus ~= nil, tostring(report))
  assert(test_inputs.covers_tree(effective, corpus .. "/0123.input", "o"), corpus)
  assert(test_inputs.covers_tree(effective, test_inputs.plain(corpus), "d"), corpus)
  local plain, plain_by_path = tree()
  assert(not test_inputs.covers_tree(test_inputs.effective(plain, plain_by_path, staged),
    corpus .. "/0123.input", "o"))
end

--- A path as a declaration spells it.
local function test_a_path_is_spelled_plainly()
  assert(test_inputs.plain("./not/there/") == "not/there")
  assert(test_inputs.plain("not/../gone/./x") == "gone/x")
  assert(test_inputs.plain("a/..") == ".")
  assert(test_inputs.plain("../up") == "../up")
  assert(test_inputs.plain("//etc//x/") == "/etc/x")
  assert(test_inputs.plain("/../top") == "/top")
end

--- The audit of a module names each undeclared input once, beside the
--- tests that read it, and the declaration that would hold them all:
--- what the module declares with the rest added, many files of one
--- directory as the directory.
local function test_a_report_groups_tests_and_suggests_a_declaration()
  local m = tree(declaring({ reads = { "data/" }, env = { "PATH" } }))
  local found: {string:{test_inputs.Finding}} = {
    test_one = {
      { field = "reads", value = "vendor/x/a" }, { field = "reads", value = "vendor/x/b" },
      { field = "reads", value = "vendor/x/c" }, { field = "reads", value = "vendor/x/d" },
      { field = "env", value = "HOME" },
    },
    test_two = { { field = "env", value = "HOME" }, { field = "processes", value = "/bin/sh" } },
  }
  local lines = test_inputs.report(m, found)
  local text = table.concat(lines, "\n")
  assert(lines[1] == "audit: lib.thing_test (lib/thing_test.tl): 2 of 2 tests read what " ..
    "they do not declare", text)
  assert(text:find("\n  test_one, test_two:\n    env          HOME\n", 1, true), text)
  assert(text:find("\n  test_one:\n    reads        vendor/x/a, vendor/x/b, vendor/x/c, " ..
    "vendor/x/d\n", 1, true), text)
  assert(text:find("\n  test_two:\n    processes    /bin/sh\n", 1, true), text)
  assert(lines[#lines] == '  declare: Test.needs { reads = { "data/", ' ..
    '"vendor/x/" }, env = { "HOME", "PATH" }, processes = true }', text)
  assert(#test_inputs.report(m, { test_one = {}, test_two = {} }) == 0)
end

--- A declaration's canonical text is one for each declaration: what the
--- build reads and what `needs` is handed agree on `network = true` and
--- `{ "*" }`, a flag `false` and none, an empty list and none; the
--- literal's order and its duplicates are kept; and a value is quoted,
--- so no two declarations share a text.
local function test_canonical_text_names_one_declaration()
  local function of(needs: declared_inputs.Needs): string
    return test_inputs.canonical(test_inputs.as_declared(needs))
  end
  assert(test_inputs.canonical(nil) == "" and of(nil) == "")
  assert(of({}) == "" and of({ reads = {}, tool = false, network = false }) == "")
  assert(of({ network = true }) == of({ network = { "*" } }))
  assert(of({ network = true }) == test_inputs.canonical(declaring({ network = { "*" } })))
  assert(of({ reads = { "a", "b" } }) ~= of({ reads = { "b", "a" } }))
  assert(of({ reads = { "a", "a" } }) ~= of({ reads = { "a" } }))
  assert(of({ reads = { "a\nreads \"b\"" } }) ~= of({ reads = { "a", "b" } }))
  assert(of({ reads = { "a b" } }) ~= of({ reads = { "a", "b" } }))
  assert(of({ env = { "A" } }) ~= of({ host = { "A" } }))
  assert(of({ reads = { "x" }, processes = true, store = true }) ==
    'reads "x"\nprocesses true\nstore true', of({ reads = { "x" }, processes = true, store = true }))
  assert(of({ tool = true }) == test_inputs.canonical(declaring({ tool = true })))
end
