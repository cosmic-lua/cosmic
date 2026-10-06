local Fs = require("cosmic.fs")
local Fuzz = require("build.fuzz")
local test_inputs = require("build.test_inputs")
local key_parts = require("build.key_parts")
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
    env = fields.env or {}, network = fields.network or {},
    tool = fields.tool == true, lua = fields.lua == true,
    noexec = fields.noexec == true,
    store = fields.store == true }
end

--- A tree of four modules: a test requiring a helper, which requires a
--- module of its own and one only a declaration file answers for, and a
--- module nothing requires. The helper runs fuzz properties when
--- `fuzzes` says so.
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

--- An edge `type_only` names is no part of the closure: the module it
--- reaches, and what only it reaches, are left out, and one reached
--- another way stays. A test module's own requires are all followed.
local function test_a_type_only_edge_is_no_part_of_the_closure()
  local m, by_path = tree()
  local type_only = { ["lib.helper"] = { ["lib.deep"] = true, ["lib.declared"] = true } }
  assert(table.concat(test_inputs.modules(m, by_path, staged, type_only), " ") ==
      "lib.helper lib.thing_test")
  local files: {string} = {}
  for file in pairs(test_inputs.effective(m, by_path, staged, type_only).files) do
    files[#files + 1] = file
  end
  table.sort(files)
  assert(table.concat(files, " ") == "lib/helper.tl lib/thing_test.tl", table.concat(files, " "))
  local direct = module("lib.direct_test", "lib/direct_test.tl", { "lib.helper", "lib.deep" })
  by_path[direct.path] = direct
  assert(table.concat(test_inputs.modules(direct, by_path, staged, type_only), " ") ==
      "lib.deep lib.direct_test lib.helper")
  local lone = module("lib.lone_test", "lib/lone_test.tl", { "lib.helper" })
  by_path[lone.path] = lone
  local other = { ["lib.lone_test"] = { ["lib.helper"] = true } }
  assert(table.concat(test_inputs.modules(lone, by_path, staged, other), " ") ==
      "lib.lone_test")
end

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
  -- How a test of the sandbox itself confines what it starts.
  assert(effective.env.COSMIC_SANDBOX)
  assert(not effective.env.USER)
  assert(next(effective.network) == nil)
  assert(not effective.tool and not effective.store)
end

--- The modules a worker lets a test `require` of the tree are the
--- closure's by name: the module itself, what it requires directly or
--- not, and one only a declaration answers for, but neither a module
--- it never reaches nor one the binary carries.
local function test_the_closure_names_its_modules()
  local m, by_path = tree()
  assert(table.concat(test_inputs.modules(m, by_path, staged), " ") ==
      "lib.declared lib.deep lib.helper lib.thing_test")
end

--- A module's declaration adds to its defaults.
local function test_a_declaration_adds_to_the_defaults()
  local m, by_path = tree(declaring({ reads = { "data/" }, host = { "/etc/localtime" },
    env = { "FLAVOUR" }, network = { "127.0.0.1" }, tool = true, store = true }))
  local effective = test_inputs.effective(m, by_path, staged)
  assert(table.concat(effective.reads, " ") == "data/", table.concat(effective.reads, " "))
  assert(table.concat(effective.host, " ") == "/etc/localtime")
  assert(effective.env.FLAVOUR and effective.env.TMPDIR)
  assert(effective.network["127.0.0.1"] and next(effective.network, "127.0.0.1") == nil)
  assert(effective.tool and effective.store)
end

--- Every fuzz corpus is a default input of a test whose closure runs
--- properties, where [`build.fuzz`] looks for one -- a property's name
--- may be computed -- and of no other test.
local function test_a_fuzz_tests_corpora_are_default_inputs(tmp: string)
  local m, by_path = tree(nil, true)
  local effective = test_inputs.effective(m, by_path, staged)
  local name = "Keep " .. string.rep("me", 1) .. "!"
  -- [`build.fuzz`] names the directory it looks in, in its report of a
  -- failure.
  local ok, report = pcall(Fuzz.run, {
    name = name, dir = tmp, iters = 1,
    gen = function(_: Fuzz.Source): string return "x" end,
    check = function(_: string): boolean, string return false, "no" end,
  })
  local corpus = tostring(report):match("mkdir %-p (%S+) ")
  assert(not ok and corpus ~= nil, tostring(report))
  local reads = table.concat(effective.reads, " ")
  assert(reads == "testdata/fuzz/", reads)
  assert(test_inputs.plain(corpus):sub(1, #reads) == reads, corpus)
  local plain, plain_by_path = tree()
  assert(#test_inputs.effective(plain, plain_by_path, staged).reads == 0)
end

--- A `host` path a worker cannot be given fails its module's tests,
--- naming the declaration and why: a path that is the tree's, or holds it,
--- as written or where a link leads.
local function test_a_host_path_that_cannot_be_given_is_named()
  local function trouble(host: {string}): string
    local m, by_path = tree(declaring({ host = host }))
    local effective = test_inputs.effective(m, by_path, staged)
    test_inputs.resolve(effective, { "/fixture/tree", "/real/tree" })
    return effective.unresolved
  end
  local said = "Test.policy grant of the host path "
  local wants: {{string}} = {
    { "/fixture/tree/x", said .. '"/fixture/tree/x": /fixture/tree/x is the tree\'s' },
    { "/fixture/tree", said .. '"/fixture/tree": /fixture/tree is the tree\'s' },
    { "/real/tree/sub/f", "/real/tree/sub/f is the tree's" },
    { "/fixture", "/fixture holds the tree" },
    { "/", "/ holds the tree" },
  }
  for _, want in ipairs(wants) do
    local why = trouble({ "/fixture/written", want[1] })
    assert(why:find(want[2], 1, true), want[1] .. ": " .. why)
  end
  assert(trouble({ "/fixture/written", "/fixture/product/f", "/proc" }) == "")
end

--- A `host` path that is a directory where the host has it fails its
--- module's tests, naming the declaration: a key holds a host path by
--- what the file holds, and none walks a directory. A path that is not there is given, as a file
--- of another platform's is (/proc, which no key could hold by what it
--- holds: build/declared_key_test.tl, which declares it).
local function test_a_host_directory_is_refused_but_proc(tmp: string)
  local dir = assert(Fs.absolute(tmp)) .. "/dir"
  assert(Fs.mkdirs(dir))
  assert(Fs.write(dir .. "/f", "f"))
  local function trouble(host: {string}): string
    local m, by_path = tree(declaring({ host = host }))
    local effective = test_inputs.effective(m, by_path, staged)
    test_inputs.resolve(effective, { "/fixture/tree" })
    return effective.unresolved
  end
  local said = trouble({ dir .. "/f", dir })
  assert(said == string.format("Test.policy grant of the host path %q: %s is a directory; " ..
      "a grant of the host names files, or /proc: grant the files the tests read", dir, dir), said)
  assert(trouble({ dir .. "/f", dir .. "/missing" }) == "")
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

--- A declaration's canonical text is one for each declaration: what the
--- build reads and what a policy stands for agree on a flag `false` and
--- none, an empty list and none; the literal's order and its duplicates
--- are kept; and a value is quoted, so no two declarations share a text.
local function test_canonical_text_names_one_declaration()
  local function of(needs: declared_inputs.Needs): string
    return test_inputs.canonical(test_inputs.as_declared(needs))
  end
  assert(test_inputs.canonical(nil) == "" and of(nil) == "")
  assert(of({}) == "" and of({ reads = {}, tool = false, network = {} }) == "")
  assert(of({ network = { "127.0.0.1" } }) ==
      test_inputs.canonical(declaring({ network = { "127.0.0.1" } })))
  assert(of({ reads = { "a", "b" } }) ~= of({ reads = { "b", "a" } }))
  assert(of({ reads = { "a", "a" } }) ~= of({ reads = { "a" } }))
  assert(of({ reads = { "a\nreads \"b\"" } }) ~= of({ reads = { "a", "b" } }))
  assert(of({ reads = { "a b" } }) ~= of({ reads = { "a", "b" } }))
  assert(of({ env = { "A" } }) ~= of({ host = { "A" } }))
  assert(of({ reads = { "x" }, tool = true, store = true }) ==
      'reads "x"\ntool true\nstore true', of({ reads = { "x" }, tool = true, store = true }))
  assert(of({ tool = true }) == test_inputs.canonical(declaring({ tool = true })))
  assert(of({ lua = true }) == "lua true" and
      of({ lua = true }) == test_inputs.canonical(declaring({ lua = true })))
end

--- A module that declares `lua` holds in its closure each module of the
--- tree `cosmic -e` loads (`lua_loads`), as its files and by name, so
--- its key holds them and every process it starts may load them -- but
--- not what one of them requires only inside a function, as dispatch
--- requires each verb's modules: an edit to those runs its tests no more
--- than an edit to any module outside its closure does.
local function test_a_lua_closure_holds_what_e_loads_and_no_more()
  local m, by_path = tree(declaring({ lua = true }))
  for _, name in ipairs(test_inputs.lua_loads) do
    by_path[name] = module(name, name:gsub("%.", "/") .. ".tl",
      name == "build.dispatch" and { "build.importer", "build.exit_status" } or {})
  end
  by_path["build.importer"] = module("build.importer", "build/importer.tl", {})
  local names = test_inputs.modules(m, by_path, staged)
  local held: {string:boolean} = {}
  for _, name in ipairs(names) do held[name] = true end
  for _, name in ipairs(test_inputs.lua_loads) do assert(held[name], name) end
  assert(not held["build.importer"], "what dispatch requires lazily is out")
  assert(held["lib.helper"] and held["lib.deep"], "the module's own closure is in")
  local effective = test_inputs.effective(m, by_path, staged)
  assert(effective.lua and effective.files["build/dispatch.tl"])
  assert(not effective.files["build/importer.tl"])
  -- Without it, none of them.
  local plain, plain_by_path = tree()
  for name, one in pairs(by_path) do plain_by_path[name] = plain_by_path[name] or one end
  local without = table.concat(test_inputs.modules(plain, plain_by_path, staged), " ")
  assert(not without:find("build.dispatch", 1, true), without)
end

--- A module that declares `lua` alone holds none of what `cosmic
--- --standalone` loads beyond `-e` (`standalone_loads`): an edit to the
--- checker runs its tests no more, and its children may not load it.
--- One that requires build.standalone holds each of them too, through
--- what that requires.
local function test_only_a_standalone_closure_holds_what_standalone_loads()
  local function names_of(declared: analyzer.Declared, standalone: boolean): {string:boolean}, test_inputs.Effective
    local m, by_path = tree(declared)
    for _, list in ipairs({ test_inputs.lua_loads, test_inputs.standalone_loads }) do
      for _, name in ipairs(list) do
        by_path[name] = module(name, name:gsub("%.", "/") .. ".tl", {})
      end
    end
    local needed: {string} = {}
    for _, name in ipairs(test_inputs.standalone_loads) do
      if name ~= "build.standalone" then needed[#needed + 1] = name end
    end
    by_path["build.standalone"].requires = needed
    if standalone then m.requires[#m.requires + 1] = "build.standalone" end
    local held: {string:boolean} = {}
    for _, name in ipairs(test_inputs.modules(m, by_path, staged)) do held[name] = true end
    return held, test_inputs.effective(m, by_path, staged)
  end
  local chunk, chunk_effective = names_of(declaring({ lua = true }), false)
  local both, both_effective = names_of(declaring({ lua = true }), true)
  for _, name in ipairs(test_inputs.lua_loads) do assert(chunk[name] and both[name], name) end
  for _, name in ipairs(test_inputs.standalone_loads) do
    assert(not chunk[name], name .. " is held by a module that declares lua alone")
    assert(both[name], name)
  end
  assert(not chunk_effective.files["build/teal.tl"] and both_effective.files["build/teal.tl"])
  -- No module is on both ways' lists: each is held by the narrowest.
  local on_e: {string:boolean} = {}
  for _, name in ipairs(test_inputs.lua_loads) do on_e[name] = true end
  for _, name in ipairs(test_inputs.standalone_loads) do assert(not on_e[name], name) end
end

--- What `lua` adds to a closure is no reader of the compiler's identity
--- (`compiler_sought`): build.dispatch, which reads it past requiring
--- build.importer, does not key a module that declares `lua` by the
--- compiler's identity, so an edit to the compiler runs it no more; a
--- reader of its own closure, build.importer, still does, and a module
--- that does not declare `lua` is sought whole.
local function test_what_lua_adds_reads_no_compiler()
  local closure = { "lib.thing_test" }
  for _, name in ipairs(test_inputs.lua_loads) do closure[#closure + 1] = name end
  for _, name in ipairs(test_inputs.standalone_loads) do closure[#closure + 1] = name end
  assert(key_parts.reads_compiler(closure), "build.dispatch reads it")
  assert(not key_parts.reads_compiler(test_inputs.compiler_sought(closure, true)))
  assert(key_parts.reads_compiler(test_inputs.compiler_sought(closure, false)))
  closure[#closure + 1] = "build.importer"
  assert(key_parts.reads_compiler(test_inputs.compiler_sought(closure, true)))
end

local function test_noexec_is_requested_but_not_granted_by_a_declaration()
  local m, by_path = tree(declaring({ noexec = true }))
  local effective = test_inputs.effective(m, by_path, staged)
  assert(effective.noexec and not effective.noexec_ready)
  assert(test_inputs.canonical(m.inputs) == "noexec true")
  assert(test_inputs.canonical(test_inputs.as_declared({ noexec = true })) == "noexec true")
  assert(test_inputs.canonical(test_inputs.as_declared({ noexec = false })) == "")
end
