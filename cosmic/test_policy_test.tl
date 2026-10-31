--- The cases of [`cosmic.test`]'s `policy`: the `needs` each policy
--- stands for, as the build reads it and as the harness translates it --
--- the same declaration, so the same sandbox and the same key -- and what
--- a policy refuses where it has no `needs` to stand for.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Analyzer = require("build.syntax_analyzer")
local type PolicyRules = require("build.policy_rules")
local test_inputs = require("build.test_inputs")

-- The source of cosmic.sandbox.policy, whose `Policy` fields [`Test.Policy`] repeats.
Test.policy{ grants = { { path = "cosmic/sandbox/policy.tl", letters = "r" } } }

--- A module that declares `call` on `Test`, as the build reads it.
local function declared(call: string): PolicyRules.Declared?, string
  local source = 'local Test = require("cosmic.test")\n' .. call .. "\n"
  local found, trouble = Analyzer.analyze(source, "fixture_test.tl")
  if found == nil then return nil, trouble end
  return found.inputs, ""
end

--- The `needs` the running harness makes of the policy `call` writes, as
--- a table of its fields, or nil and why: `call` is `Test.policy <table>`.
local function runtime_needs(call: string): Test.Needs?, string
  local chunk = load("return " .. call:gsub("^Test%.policy%s*", ""))
  if chunk == nil then return nil, "not a table" end
  return Test.needs_of(chunk())
end

--- Pairs of what a policy stands for and the policy: a table of the fields
--- of [`Test.Needs`], and the [`Test.policy`] call that makes it.
--- What a policy stands for, as a table of the fields of [`Test.Needs`], and the policy.
local record Same
  needs: string
  policy: string
end

--- A [`Test.policy`] call, and the words its refusal holds.
local record Refusal
  call: string
  says: string
end

local SAME: {Same} = {
  { needs = "{ }", policy = "Test.policy { }" },
  {
    needs = '{ reads = { "testdata/", "bin/zig.pin" } }',
    policy = 'Test.policy { grants = { { path = "testdata/", letters = "r" }, ' ..
      '{ path = "bin/zig.pin", letters = "r" } } }',
  },
  {
    needs = '{ host = { "/etc/localtime", "/proc/self/maps" } }',
    policy = 'Test.policy { grants = { { path = "/etc/localtime", letters = "r" }, ' ..
      '{ path = "/proc/self/maps", letters = "r" } } }',
  },
  {
    needs = '{ reads = { "a", "b" }, host = { "/etc/hosts" } }',
    policy = 'Test.policy { grants = { { path = "a", letters = "r" }, ' ..
      '{ path = "/etc/hosts", letters = "r" }, { path = "b", letters = "r" } } }',
  },
  { needs = "{ system = true }", policy = 'Test.policy { profiles = { "system" } }' },
  -- The profile alone is the program held to the module's closure; with the
  -- grant of o/bin, which the program is in, it is the program itself.
  { needs = "{ lua = true }", policy = 'Test.policy { profiles = { "cosmic" } }' },
  {
    needs = '{ lua = true, host = { "/proc" }, nests = true, network = { "127.0.0.1" } }',
    policy = 'Test.policy { profiles = { "cosmic" }, grants = { { path = "/proc", letters = "r" } }, ' ..
      'promises = { "nest" }, loopback = { "127.0.0.1" } }',
  },
  -- The profile "proc" is the grant of /proc by hand, to the key.
  { needs = '{ host = { "/proc" } }', policy = 'Test.policy { profiles = { "proc" } }' },
  {
    needs = '{ lua = true, host = { "/proc" }, nests = true, network = { "127.0.0.1" } }',
    policy = 'Test.policy { profiles = { "cosmic", "proc" }, promises = { "nest" }, ' ..
      'loopback = { "127.0.0.1" } }',
  },
  {
    needs = '{ system = true, tool = true, host = { "/etc/hosts", "/proc" } }',
    policy = 'Test.policy { profiles = { "system", "cosmic", "proc" }, grants = { { path = "o/bin", letters = "rx" }, ' ..
      '{ path = "/etc/hosts", letters = "r" } } }',
  },
  { needs = "{ tool = true }",
    policy = 'Test.policy { profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }' },
  {
    needs = '{ tool = true, store = true, reads = { "a" } }',
    policy = 'Test.policy { profiles = { "cosmic" }, grants = { { path = "a", letters = "r" }, ' ..
      '{ path = "o/bin", letters = "rx" }, { path = "o/cosmic.db", letters = "r" } } }',
  },
  { needs = "{ tool = true, system = true }",
    policy = 'Test.policy { profiles = { "system", "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }' },
  { needs = "{ nests = true }", policy = 'Test.policy { promises = { "nest" } }' },
  { needs = '{ env = { "PATH", "HOME", "PATH" } }', policy = 'Test.policy { env = { "PATH", "HOME", "PATH" } }' },
  { needs = '{ network = { "127.0.0.1", "127.0.0.2" } }',
    policy = 'Test.policy { loopback = { "127.0.0.1", "127.0.0.2" } }' },
  -- Three grants are the fields they stand for, not reads.
  { needs = "{ store = true }", policy = 'Test.policy { grants = { { path = "o/cosmic.db", letters = "r" } } }' },
  { needs = "{ noexec = true }", policy = 'Test.policy { grants = { { path = "/noexec", letters = "rwc" } } }' },
  { needs = '{ caches = { "zig" } }',
    policy = 'Test.policy { grants = { { path = "/cache/zig", letters = "rwxc" } } }' },
  {
    needs = '{ caches = { "zig", "bootstrap" }, reads = { "a" }, store = true, ' ..
      'noexec = true, host = { "/etc/hosts" } }',
    policy = 'Test.policy { grants = { { path = "/cache/zig", letters = "rwxc" }, ' ..
      '{ path = "a", letters = "r" }, { path = "/noexec", letters = "rwc" }, ' ..
      '{ path = "/cache/bootstrap", letters = "rwxc" }, ' ..
      '{ path = "o/cosmic.db", letters = "r" }, { path = "/etc/hosts", letters = "r" } } }',
  },
  -- A file above the project root is a field, not a host read.
  {
    needs = '{ parent = { "bin/cosmic-bootstrap", ".github/workflows/ci.yml" } }',
    policy = 'Test.policy { grants = { { path = "/parent/bin/cosmic-bootstrap", letters = "r" }, ' ..
      '{ path = "/parent/.github/workflows/ci.yml", letters = "r" } } }',
  },
  {
    needs = '{ parent = { "a" }, host = { "/etc/hosts" }, reads = { "b" } }',
    policy = 'Test.policy { grants = { { path = "/etc/hosts", letters = "r" }, ' ..
      '{ path = "/parent/a", letters = "r" }, { path = "b", letters = "r" } } }',
  },
  -- A promise with no `needs` field changes no key before the filter runs.
  { needs = "{ }", policy = 'Test.policy { promises = { "fork", "jit", "fattr" }, tmp = true }' },
  {
    needs = '{ reads = { "testdata" }, system = true, tool = true, nests = true, ' ..
      'env = { "PATH", "TMPDIR" }, network = { "127.0.0.1" } }',
    policy = 'Test.policy { profiles = { "cosmic", "system" }, promises = { "nest", "fork" }, ' ..
      'grants = { { path = "testdata", letters = "r" }, { path = "o/bin", letters = "rx" } }, ' ..
      'env = { "PATH", "TMPDIR" }, ' ..
      'loopback = { "127.0.0.1" }, tmp = true, isolate = {}, limits = {} }',
  },
}

--- A policy is the declaration of the `needs` it stands for: the text a
--- verdict's key holds of it (the declared key's `inputs` part), and
--- every field, are equal to the `needs`'s, as the build reads the policy
--- and as the harness translates it.
local function test_a_policy_is_keyed_as_its_needs()
  for _, pair in ipairs(SAME) do
    local chunk = assert(load("return " .. pair.needs))
    local from_needs = assert(test_inputs.as_declared(chunk() as Test.Needs))
    local from_policy, why_policy = declared(pair.policy)
    assert(from_policy ~= nil, pair.policy .. ": " .. why_policy)
    assert(test_inputs.canonical(from_needs) == test_inputs.canonical(from_policy),
      pair.policy .. "\n" .. test_inputs.canonical(from_policy) .. "\nis not\n" ..
        test_inputs.canonical(from_needs))
    -- What the worker is handed is what the build read: the runtime's
    -- translation is the build's.
    local handed, why_handed = runtime_needs(pair.policy)
    assert(handed ~= nil, pair.policy .. ": " .. tostring(why_handed))
    assert(test_inputs.canonical(test_inputs.as_declared(handed)) ==
        test_inputs.canonical(from_needs), pair.policy .. ": the worker is handed another needs")
    from_needs.line, from_policy.line = 0, 0
    for field, value in pairs(from_needs as {string:any}) do
      local other = (from_policy as {string:any})[field]
      if value is {string} and other is {string} then
        assert(table.concat(value, " ") == table.concat(other, " "), pair.policy .. " " .. field)
      else
        assert(value == other, pair.policy .. " " .. field)
      end
    end
  end
end

--- What a policy cannot say as a `needs` is refused, naming the line and
--- the field, rather than accepted as a declaration that keys nothing of
--- it.
local function test_a_policy_with_no_needs_is_refused()
  local cases: {Refusal} = {
    { call = 'Test.policy { isolate = { "file" } }',
      says = "fixture_test.tl:2: test.policy: isolate is not yet taken" },
    { call = 'Test.policy { limits = { processes = 4 } }', says = "test.policy: limits is not yet taken" },
    { call = 'Test.policy { set_env = { A = "1" } }', says = "test.policy: set_env is not yet taken" },
    { call = 'Test.policy { set_env_digests = { A = "ab" } }', says = "test.policy: set_env_digests is refused" },
    { call = 'Test.policy { connect = { "example.com:443" } }',
      says = "test.policy: connect is refused: no test reaches a host but loopback" },
    { call = "Test.policy { tmp = false }", says = "test.policy: tmp = false is not yet taken" },
    { call = "Test.policy { user = 1000 }", says = "test.policy: user is refused: the harness chooses" },
    { call = "Test.policy { user = 1000, group = 1000 }", says = "is refused: the harness chooses" },
    { call = 'Test.policy { user = "me" }', says = "test.policy: user takes a whole number" },
    { call = 'Test.policy { grants = { { path = "o/cosmic.db", letters = "rw" } } }',
      says = 'test.policy: grants[1].path o/cosmic.db is the store, granted { path = "o/cosmic.db"' },
    { call = 'Test.policy { grants = { { path = "o/cosmic.db", letters = "r", from = "x" } } }',
      says = "test.policy: grants[1].path o/cosmic.db is the store" },
    {
      call = 'Test.policy { profiles = { "cosmic" }, grants = { { path = "o/cosmic.db", letters = "r" } } }',
      says = 'test.policy: profiles: "cosmic" without the grant of o/bin holds the program to what ' ..
        'the module requires, which is refused beside o/cosmic.db',
    },
    { call = 'Test.policy { profiles = { "system", "cosmic" } }',
      says = "which is refused beside system; grant { path = \"o/bin\", letters = \"rx\" }" },
    { call = 'Test.policy { profiles = { "cosmic" }, grants = { { path = "/cache/zig", letters = "rwxc" } } }',
      says = "which is refused beside /cache/zig" },
    {
      call = 'Test.policy { grants = { { path = "o/bin", letters = "rx" } } }',
      says = 'test.policy: grants: .path o/bin is the program\'s directory, granted only beside ' ..
        'the profile "cosmic"',
    },
    {
      call = 'Test.policy { profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "r" } } }',
      says = 'test.policy: grants[1].path o/bin is the directory the program is in, granted ' ..
        '{ path = "o/bin", letters = "rx" }',
    },
    { call = 'Test.policy { profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rwx" } } }',
      says = "test.policy: grants[1].path o/bin is the directory the program is in" },
    {
      call = 'Test.policy { profiles = { "cosmic" }, ' ..
        'grants = { { path = "o/bin", letters = "rx", from = "x" } } }',
      says = "test.policy: grants[1].path o/bin is the directory the program is in",
    },
    {
      call = 'Test.policy { grants = { { path = "/noexec", letters = "rwxc" } } }',
      says = 'test.policy: grants[1].path /noexec is the private scratch the harness gives, granted ' ..
        '{ path = "/noexec", letters = "rwc" }',
    },
    { call = 'Test.policy { grants = { { path = "/noexec", letters = "rwc", from = "/t" } } }',
      says = "test.policy: grants[1].path /noexec is the private scratch" },
    {
      call = 'Test.policy { grants = { { path = "/cache/zig", letters = "rwc" } } }',
      says = 'test.policy: grants[1].path /cache/<name> is a host cache, granted { path = "/cache/<name>", ' ..
        'letters = "rwxc" }',
    },
    { call = 'Test.policy { grants = { { path = "/cache/zig", letters = "rwxc", from = "/t" } } }',
      says = "test.policy: grants[1].path /cache/<name> is a host cache" },
    { call = 'Test.policy { grants = { { path = "/cache/nope", letters = "rwxc" } } }',
      says = "test.policy: grants[1].path /cache/nope: no cache nope; the caches are bootstrap, zig" },
    { call = 'Test.policy { grants = { { path = "d", letters = "rwc" } } }',
      says = 'test.policy: grants[1].letters "rwc" is not yet taken' },
    { call = 'Test.policy { grants = { { path = "d", letters = "rx" } } }',
      says = 'test.policy: grants[1].letters "rx" is not yet taken' },
    { call = 'Test.policy { grants = { { path = "d", letters = "r", from = "/e" } } }',
      says = "test.policy: grants[1].from is not yet taken" },
    { call = 'Test.policy { grants = { { path = "d", letters = "wr" } } }',
      says = "test.policy: grants[1].letters takes letters of rwxcu, in that order" },
    { call = 'Test.policy { grants = { { letters = "r" } } }', says = "test.policy: grants[1].path takes a path" },
    { call = 'Test.policy { profiles = { "net" } }', says = "test.policy: profiles: no profile net" },
    { call = 'Test.policy { grants = { { path = "/parent/a", letters = "rw" } } }',
      says = "grants[1].path /parent/<file> is a file of the project root's parent directory" },
    { call = 'Test.policy { grants = { { path = "/parent/a", letters = "r", from = "/e" } } }',
      says = "grants[1].path /parent/<file> is a file" },
    { call = 'Test.policy { grants = { { path = "/parent/", letters = "r" } } }', says = "names no file" },
    { call = 'Test.policy { grants = { { path = "/parent/a/", letters = "r" } } }', says = 'ends in a "/"' },
    { call = 'Test.policy { grants = { { path = "/parent/../a", letters = "r" } } }', says = 'has a ".." name' },
    { call = 'Test.policy { grants = { { path = "/parent/a/./b", letters = "r" } } }', says = 'has a "." name' },
    { call = 'Test.policy { grants = { { path = "/parent/a//b", letters = "r" } } }', says = "has an empty name" },
    { call = 'Test.policy { grants = { { path = "/parent/$HOME", letters = "r" } } }', says = "holds a $" },
    { call = 'Test.policy { database = "x.db" }', says = "test.policy: database is refused" },
    { call = 'Test.policy { promises = { "exec" } }', says = "test.policy: promises: no promise exec" },
    { call = "Test.policy { reeds = {} }", says = "test.policy: has no field reeds; it has connect, database, env" },
    { call = 'Test.policy { env = "PATH" }', says = "test.policy: env takes a list of string literals, written out" },
    { call = "Test.policy { tmp = 1 }", says = "test.policy: tmp takes true or false" },
    { call = 'Test.policy { limits = { cpu = 1 } }', says = "test.policy: limits takes open_files" },
    { call = 'Test.policy { loopback = { "localhost" } }',
      says = 'test.policy: loopback "localhost": loopback takes loopback' },
    { call = 'Test.policy { loopback = { "10.0.0.1" } }', says = "test.policy: loopback" },
    { call = 'Test.policy { grants = { { path = "/d/", letters = "r" } } }',
      says = "test.policy: grants: \"/d/\" names a directory" },
    { call = 'Test.policy { grants = { { path = "../x", letters = "r" } } }', says = "test.policy: grants:" },
    { call = 'Test.policy { env = { "PATH", "*" } }', says = 'no wildcard "*" in a policy' },
    { call = 'Test.policy { env = { "" } }', says = "test.policy: env: an empty name" },
    { call = "Test.policy { env = { \"A\\n\" } }", says = "write declared paths plainly" },
    { call = "Test.policy { env = { X } }", says = "test.policy: env takes a string written out as a literal" },
    { call = "Test.policy(1)", says = "hand it one table written out as a literal: Test.policy" },
    { call = 'Test.policy { env = { "A" }, env = { "B" } }', says = "env is declared twice" },
  }
  for _, case in ipairs(cases) do
    local got, trouble = declared(case.call)
    assert(got == nil and trouble:find(case.says, 1, true) ~= nil,
      case.call .. ": " .. tostring(trouble) .. " does not say " .. case.says)
    -- A policy the build refuses for what it says, the worker refuses
    -- too; one it refuses for an entry's own rule (a path, an address),
    -- which only the build checks, the worker takes.
    if not trouble:find("test.policy: [a-z]+: ") and
        not trouble:find(": no cache ", 1, true) and
        not trouble:find("test.policy: loopback", 1, true) and
        not trouble:find("written out", 1, true) and not trouble:find("plainly", 1, true) and
        not trouble:find("declared twice", 1, true) and not trouble:find("hand it", 1, true) then
      local needs, why = runtime_needs(case.call)
      assert(needs == nil, case.call .. ": the worker takes it, as " .. tostring(needs))
      assert(why ~= "")
    end
  end
end

--- A path the module never declared is a mistake of the test, which
--- `parent` raises for, whether or not a runner gives it a parent directory.
local function test_parent_refuses_a_path_the_module_never_declared()
  local ok, why = pcall(Test.parent, "bin/cosmic-bootstrap")
  assert(not ok and tostring(why):find("parent(\"bin/cosmic-bootstrap\") is not declared", 1, true),
    tostring(why))
end

--- A module declares its policy once, at the top level.
local function test_a_module_declares_its_policy_once()
  local twice, again = declared('Test.policy { }\nTest.policy { }')
  assert(twice == nil and again:find("fixture_test.tl:3: test.policy: a module declares its " ..
      "policy once; line 2 did already", 1, true), again)
  local inside, within = declared('local function f() Test.policy { } end')
  assert(inside == nil and within:find("test.policy: call it as a statement at the module's " ..
      "top level", 1, true), within)
end

--- The fields [`Test.Policy`] repeats are the fields of cosmic.sandbox.policy's
--- `Policy`, and `requires`, which only a test declares.
local function test_the_policy_record_is_the_sandboxs()
  local text = assert(Fs.read("cosmic/sandbox/policy.tl"))
  local record = assert(text:match("\n  record Policy\n(.-)\n  end\n"), "no Policy")
  local theirs: mut {string} = {}
  for name in ("\n" .. record):gmatch("\n    ([%a_]+)%??: ") do theirs[#theirs + 1] = name end
  theirs[#theirs + 1] = "requires"
  table.sort(theirs)
  local _, said = Test.needs_of({ nothing = true })
  local listed = assert(said:match("it has (.*)$"), said)
  assert(listed == table.concat(theirs, ", "), listed .. " is not " .. table.concat(theirs, ", "))
end

--- What a policy requires of the host is what it declares, which the build
--- reads and the worker is handed alike, and the key holds. Nothing is
--- inferred from its other fields.
local function test_a_policy_declares_requirements()
  local function read(call: string): PolicyRules.Declared
    local found, why = declared(call)
    assert(found ~= nil, call .. ": " .. tostring(why))
    return found
  end
  local function names(list: {string}): string return table.concat(list, " ") end
  assert(names(read('Test.policy { requires = { "root", "portable" } }').requires) == "root portable")
  assert(#read('Test.policy { promises = { "nest" }, grants = { { path = "/proc", letters = "r" } } }').requires == 0)
  local call = 'Test.policy { requires = { "root" }, promises = { "nest" } }'
  local handed = assert(runtime_needs(call))
  assert(names(assert(handed.requires)) == "root")
  local from_policy = read(call)
  assert(test_inputs.canonical(test_inputs.as_declared(handed)) == test_inputs.canonical(from_policy))
  assert(test_inputs.canonical(from_policy):find('requires "root"', 1, true))
  assert(test_inputs.canonical(read("Test.policy { }")) == "")
end

--- A name the table does not have, a name written twice, a `path:` the
--- worker is given no host grant of and a `program:` it cannot find fail
--- the build, naming the rule; a Linux-class name does not.
local function test_a_requirement_that_breaks_a_rule_fails_the_build()
  local cases: {Refusal} = {
    { call = 'Test.policy { requires = { "sandbxo" } }', says = "unknown requirement \"sandbxo\"" },
    { call = 'Test.policy { requires = { "path:relative" } }', says = "absolute path" },
    { call = 'Test.policy { requires = { "landlock:0" } }', says = "positive integer" },
    { call = 'Test.policy { requires = { "root", "root" } }', says = "\"root\" is written twice" },
    { call = 'Test.policy { requires = { "path:/etc/hosts" } }', says = "needs a host grant of the path" },
    { call = 'Test.policy { requires = { "path:/etc/hosts" }, grants = { { path = "/etc/passwd", letters = "r" } } }',
      says = "needs a host grant of the path" },
    { call = 'Test.policy { requires = { "program:jq" } }',
      says = "needs the profile \"system\" and env = { \"PATH\" }" },
    { call = 'Test.policy { requires = { "program:jq" }, profiles = { "system" } }',
      says = "needs the profile \"system\" and env = { \"PATH\" }" },
    { call = 'Test.policy { requires = { "program:jq" }, env = { "PATH" } }',
      says = "needs the profile \"system\" and env = { \"PATH\" }" },
    { call = 'Test.policy { requires = "root" }', says = "requires takes a list of string literals" },
  }
  for _, case in ipairs(cases) do
    local found, why = declared(case.call)
    assert(found == nil and why:find("fixture_test.tl:2: test.policy: ", 1, true) ~= nil and
        why:find(case.says, 1, true) ~= nil, case.call .. ": " .. tostring(why))
  end
  for _, call in ipairs({
      'Test.policy { requires = { "path:/etc/hosts" }, grants = { { path = "/etc/hosts", letters = "r" } } }',
      'Test.policy { requires = { "path:/proc/self/status" }, grants = { { path = "/proc", letters = "r" } } }',
      'Test.policy { requires = { "path:/proc/self/status" }, profiles = { "proc" } }',
      'Test.policy { requires = { "program:jq" }, profiles = { "system" }, env = { "PATH" } }',
      'Test.policy { requires = { "root", "portable" } }',
      'Test.policy { requires = { "sandbox", "landlock", "landlock:3", "userns", "nest", "own_proc", "proc" } }',
  }) do
    local found, why = declared(call)
    assert(found ~= nil, call .. ": " .. tostring(why))
  end
end
