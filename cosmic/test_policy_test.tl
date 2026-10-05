--- The cases of [`cosmic.test`]'s `policy`: the `needs` each policy
--- stands for, held to what a declaration of that `needs` gives -- the
--- same declaration, so the same sandbox and the same key -- and what a
--- policy refuses where it has no `needs` to stand for.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local teal = require("build.teal")
local analyzer = require("build.analyzer")
local test_inputs = require("build.test_inputs")

-- The source of cosmic.sandbox, whose `Policy` fields [`Test.Policy`] repeats.
Test.policy{ grants = { { path = "cosmic/sandbox.tl", letters = "r" } } }

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- A module that declares `call` on `Test`, as the build reads it.
local function declared(call: string): analyzer.Declared | nil, string
  local source = 'local Test = require("cosmic.test")\n' .. call .. "\n"
  local found, trouble = analyzer.analyze(built, source, "fixture_test.tl")
  if found == nil then return nil, trouble end
  return found.inputs, ""
end

--- The `needs` the running harness makes of the policy `call` writes, as
--- a table of its fields, or nil and why: `call` is `Test.policy <table>`.
local function runtime_needs(call: string): Test.Needs | nil, string
  local chunk = load("return " .. call:gsub("^Test%.policy%s*", ""))
  if chunk == nil then return nil, "not a table" end
  return Test.needs_of(chunk())
end

--- Pairs of declarations that mean the same: a `needs`, and the policy
--- that stands for it.
local SAME: {{string}} = {
  { "Test.needs { }", "Test.policy { }" },
  { 'Test.needs { reads = { "testdata/", "bin/zig.pin" } }',
    'Test.policy { grants = { { path = "testdata/", letters = "r" }, ' ..
      '{ path = "bin/zig.pin", letters = "r" } } }' },
  { 'Test.needs { host = { "/etc/localtime", "/proc/self/maps" } }',
    'Test.policy { grants = { { path = "/etc/localtime", letters = "r" }, ' ..
      '{ path = "/proc/self/maps", letters = "r" } } }' },
  { 'Test.needs { reads = { "a", "b" }, host = { "/etc/hosts" } }',
    'Test.policy { grants = { { path = "a", letters = "r" }, ' ..
      '{ path = "/etc/hosts", letters = "r" }, { path = "b", letters = "r" } } }' },
  { "Test.needs { system = true }", 'Test.policy { profiles = { "system" } }' },
  -- The profile alone is the program held to the module's closure; with the
  -- grant of o/bin, which the program is in, it is the program itself.
  { "Test.needs { lua = true }", 'Test.policy { profiles = { "cosmic" } }' },
  { 'Test.needs { lua = true, host = { "/proc" }, nests = true, network = { "127.0.0.1" } }',
    'Test.policy { profiles = { "cosmic" }, grants = { { path = "/proc", letters = "r" } }, ' ..
      'promises = { "nest" }, loopback = { "127.0.0.1" } }' },
  { "Test.needs { tool = true }",
    'Test.policy { profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }' },
  { 'Test.needs { tool = true, store = true, reads = { "a" } }',
    'Test.policy { profiles = { "cosmic" }, grants = { { path = "a", letters = "r" }, ' ..
      '{ path = "o/bin", letters = "rx" }, { path = "o/cosmic.db", letters = "r" } } }' },
  { "Test.needs { tool = true, system = true }",
    'Test.policy { profiles = { "system", "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }' },
  { "Test.needs { nests = true }", 'Test.policy { promises = { "nest" } }' },
  { 'Test.needs { env = { "PATH", "HOME", "PATH" } }',
    'Test.policy { env = { "PATH", "HOME", "PATH" } }' },
  { 'Test.needs { network = { "127.0.0.1", "127.0.0.2" } }',
    'Test.policy { loopback = { "127.0.0.1", "127.0.0.2" } }' },
  -- Three grants are the fields they stand for, not reads.
  { "Test.needs { store = true }",
    'Test.policy { grants = { { path = "o/cosmic.db", letters = "r" } } }' },
  { "Test.needs { noexec = true }",
    'Test.policy { grants = { { path = "/noexec", letters = "rwc" } } }' },
  { 'Test.needs { caches = { "zig" } }',
    'Test.policy { grants = { { path = "/cache/zig", letters = "rwxc" } } }' },
  { 'Test.needs { caches = { "zig", "bootstrap" }, reads = { "a" }, store = true, ' ..
      'noexec = true, host = { "/etc/hosts" } }',
    'Test.policy { grants = { { path = "/cache/zig", letters = "rwxc" }, ' ..
      '{ path = "a", letters = "r" }, { path = "/noexec", letters = "rwc" }, ' ..
      '{ path = "/cache/bootstrap", letters = "rwxc" }, ' ..
      '{ path = "o/cosmic.db", letters = "r" }, { path = "/etc/hosts", letters = "r" } } }' },
  -- A promise with no `needs` field changes no key before the filter runs.
  { "Test.needs { }", 'Test.policy { promises = { "fork", "jit", "fattr" }, tmp = true }' },
  { 'Test.needs { reads = { "testdata" }, system = true, tool = true, nests = true, ' ..
      'env = { "PATH", "TMPDIR" }, network = { "127.0.0.1" } }',
    'Test.policy { profiles = { "cosmic", "system" }, promises = { "nest", "fork" }, ' ..
      'grants = { { path = "testdata", letters = "r" }, { path = "o/bin", letters = "rx" } }, ' ..
      'env = { "PATH", "TMPDIR" }, ' ..
      'loopback = { "127.0.0.1" }, tmp = true, isolate = {}, limits = {} }' },
}

--- A policy is the declaration of the `needs` it stands for: the text a
--- verdict's key holds of it (the declared key's `inputs` part), and
--- every field, are equal.
local function test_a_policy_is_keyed_as_its_needs()
  for _, pair in ipairs(SAME) do
    local from_needs, why_needs = declared(pair[1])
    local from_policy, why_policy = declared(pair[2])
    assert(from_needs ~= nil, pair[1] .. ": " .. why_needs)
    assert(from_policy ~= nil, pair[2] .. ": " .. why_policy)
    assert(test_inputs.canonical(from_needs) == test_inputs.canonical(from_policy),
      pair[2] .. "\n" .. test_inputs.canonical(from_policy) .. "\nis not\n" ..
        test_inputs.canonical(from_needs))
    -- What the worker is handed is what the build read: the runtime's
    -- translation is the build's.
    local handed, why_handed = runtime_needs(pair[2])
    assert(handed ~= nil, pair[2] .. ": " .. tostring(why_handed))
    assert(test_inputs.canonical(test_inputs.as_declared(handed)) ==
        test_inputs.canonical(from_needs), pair[2] .. ": the worker is handed another needs")
    from_needs.line, from_policy.line = 0, 0
    for field, value in pairs(from_needs as {string:any}) do
      local other = (from_policy as {string:any})[field]
      -- A policy says what it implies of the host; a `needs` says none.
      if field == "implied" then
        other = value
      end
      if value is {string} and other is {string} then
        assert(table.concat(value, " ") == table.concat(other, " "), pair[2] .. " " .. field)
      else
        assert(value == other, pair[2] .. " " .. field)
      end
    end
  end
end

--- What a policy cannot say as a `needs` is refused, naming the line and
--- the field, rather than accepted as a declaration that keys nothing of
--- it.
local function test_a_policy_with_no_needs_is_refused()
  local cases: {{string}} = {
    { 'Test.policy { isolate = { "file" } }', "fixture_test.tl:2: test.policy: isolate is not yet taken" },
    { 'Test.policy { limits = { processes = 4 } }', "test.policy: limits is not yet taken" },
    { 'Test.policy { set_env = { A = "1" } }', "test.policy: set_env is not yet taken" },
    { 'Test.policy { set_env_digests = { A = "ab" } }', "test.policy: set_env_digests is refused" },
    { 'Test.policy { connect = { "example.com:443" } }',
      "test.policy: connect is refused: no test reaches a host but loopback" },
    { "Test.policy { tmp = false }", "test.policy: tmp = false is not yet taken" },
    { "Test.policy { user = 1000 }", "test.policy: user is refused: the harness chooses" },
    { "Test.policy { user = 1000, group = 1000 }", "is refused: the harness chooses" },
    { 'Test.policy { user = "me" }', "test.policy: user takes a whole number" },
    { 'Test.policy { grants = { { path = "o/cosmic.db", letters = "rw" } } }',
      'test.policy: grants[1].path o/cosmic.db is the store, granted { path = "o/cosmic.db"' },
    { 'Test.policy { grants = { { path = "o/cosmic.db", letters = "r", from = "x" } } }',
      "test.policy: grants[1].path o/cosmic.db is the store" },
    { 'Test.policy { profiles = { "cosmic" }, grants = { { path = "o/cosmic.db", letters = "r" } } }',
      'test.policy: profiles: "cosmic" without the grant of o/bin holds the program to what ' ..
        'the module requires, which is refused beside o/cosmic.db' },
    { 'Test.policy { profiles = { "system", "cosmic" } }',
      "which is refused beside system; grant { path = \"o/bin\", letters = \"rx\" }" },
    { 'Test.policy { profiles = { "cosmic" }, grants = { { path = "/cache/zig", letters = "rwxc" } } }',
      "which is refused beside /cache/zig" },
    { 'Test.policy { grants = { { path = "o/bin", letters = "rx" } } }',
      'test.policy: grants: .path o/bin is the program\'s directory, granted only beside ' ..
        'the profile "cosmic"' },
    { 'Test.policy { profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "r" } } }',
      'test.policy: grants[1].path o/bin is the directory the program is in, granted ' ..
        '{ path = "o/bin", letters = "rx" }' },
    { 'Test.policy { profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rwx" } } }',
      "test.policy: grants[1].path o/bin is the directory the program is in" },
    { 'Test.policy { profiles = { "cosmic" }, ' ..
        'grants = { { path = "o/bin", letters = "rx", from = "x" } } }',
      "test.policy: grants[1].path o/bin is the directory the program is in" },
    { 'Test.policy { grants = { { path = "/noexec", letters = "rwxc" } } }',
      'test.policy: grants[1].path /noexec is the private scratch the harness gives, granted ' ..
        '{ path = "/noexec", letters = "rwc" }' },
    { 'Test.policy { grants = { { path = "/noexec", letters = "rwc", from = "/t" } } }',
      "test.policy: grants[1].path /noexec is the private scratch" },
    { 'Test.policy { grants = { { path = "/cache/zig", letters = "rwc" } } }',
      'test.policy: grants[1].path /cache/<name> is a host cache, granted { path = "/cache/<name>", ' ..
        'letters = "rwxc" }' },
    { 'Test.policy { grants = { { path = "/cache/zig", letters = "rwxc", from = "/t" } } }',
      "test.policy: grants[1].path /cache/<name> is a host cache" },
    { 'Test.policy { grants = { { path = "/cache/nope", letters = "rwxc" } } }',
      "test.policy: grants[1].path /cache/nope: no cache nope; the caches are bootstrap, zig" },
    { 'Test.policy { grants = { { path = "d", letters = "rwc" } } }',
      'test.policy: grants[1].letters "rwc" is not yet taken' },
    { 'Test.policy { grants = { { path = "d", letters = "rx" } } }',
      'test.policy: grants[1].letters "rx" is not yet taken' },
    { 'Test.policy { grants = { { path = "d", letters = "r", from = "/e" } } }',
      "test.policy: grants[1].from is not yet taken" },
    { 'Test.policy { grants = { { path = "d", letters = "wr" } } }',
      "test.policy: grants[1].letters takes letters of rwxcu, in that order" },
    { 'Test.policy { grants = { { letters = "r" } } }', "test.policy: grants[1].path takes a path" },
    { 'Test.policy { profiles = { "net" } }', "test.policy: profiles: no profile net" },
    { 'Test.policy { promises = { "exec" } }', "test.policy: promises: no promise exec" },
    { "Test.policy { reeds = {} }", "test.policy: has no field reeds; it has connect, database, env" },
    { 'Test.policy { env = "PATH" }', "test.policy: env takes a list of string literals, written out" },
    { "Test.policy { tmp = 1 }", "test.policy: tmp takes true or false" },
    { 'Test.policy { limits = { cpu = 1 } }', "test.policy: limits takes open_files" },
    { 'Test.policy { loopback = { "localhost" } }', 'test.policy: network "localhost": network takes loopback' },
    { 'Test.policy { loopback = { "10.0.0.1" } }', "test.policy: network" },
    { 'Test.policy { grants = { { path = "/d/", letters = "r" } } }',
      "test.policy: host: \"/d/\" names a directory" },
    { 'Test.policy { grants = { { path = "../x", letters = "r" } } }', "test.policy: reads:" },
    { 'Test.policy { env = { "PATH", "*" } }', 'no wildcard "*" in a policy' },
    { 'Test.policy { env = { "" } }', "test.policy: env: an empty name" },
    { "Test.policy { env = { \"A\\n\" } }", "write declared paths plainly" },
    { "Test.policy { env = { X } }", "test.policy: env takes a string written out as a literal" },
    { "Test.policy(1)", "hand it one table written out as a literal: Test.policy" },
    { 'Test.policy { env = { "A" }, env = { "B" } }', "env is declared twice" },
  }
  for _, case in ipairs(cases) do
    local got, trouble = declared(case[1])
    assert(got == nil and trouble:find(case[2], 1, true) ~= nil,
      case[1] .. ": " .. tostring(trouble) .. " does not say " .. case[2])
    -- A policy the build refuses for what it says, the worker refuses
    -- too; one it refuses for an entry's own rule (a path, an address),
    -- as `needs` is, the worker takes as it takes `needs`.
    if not trouble:find("test.policy: [a-z]+: ") and
        not trouble:find(": no cache ", 1, true) and
        not trouble:find("test.policy: network", 1, true) and
        not trouble:find("written out", 1, true) and not trouble:find("plainly", 1, true) and
        not trouble:find("declared twice", 1, true) and not trouble:find("hand it", 1, true) then
      local needs, why = runtime_needs(case[1])
      assert(needs == nil, case[1] .. ": the worker takes it, as " .. tostring(needs))
      assert(why ~= "")
    end
  end
end

--- A module declares its inputs once, with `needs` or `policy`.
local function test_a_module_declares_needs_or_policy_not_both()
  local both, trouble = declared('Test.needs { tool = true }\nTest.policy { }')
  assert(both == nil and trouble:find("fixture_test.tl:3: test.policy: a module declares its " ..
      "inputs once, with Test.needs or Test.policy and not both; line 2 did already", 1, true),
    trouble)
  local twice, again = declared('Test.policy { }\nTest.needs { }')
  assert(twice == nil and again:find("fixture_test.tl:3: test.needs: a module declares", 1, true),
    again)
  local inside, within = declared('local function f() Test.policy { } end')
  assert(inside == nil and within:find("test.policy: call it as a statement at the module's " ..
      "top level", 1, true), within)
end

--- The fields [`Test.Policy`] repeats are the fields of cosmic.sandbox's
--- `Policy`, and `requires`, which only a test declares.
local function test_the_policy_record_is_the_sandboxs()
  local text = assert(Fs.read("cosmic/sandbox.tl"))
  local record = assert(text:match("\n  record Policy\n(.-)\n  end\n"), "no Policy")
  local theirs: {string} = {}
  for name in ("\n" .. record):gmatch("\n    ([%a_]+): ") do theirs[#theirs + 1] = name end
  theirs[#theirs + 1] = "requires"
  table.sort(theirs)
  local _, said = Test.needs_of({ nothing = true })
  local listed = assert(said:match("it has (.*)$"), said)
  assert(listed == table.concat(theirs, ", "), listed .. " is not " .. table.concat(theirs, ", "))
end

--- What a policy requires of the host is what it declares, which the build
--- reads and the worker is handed alike, and the key holds. Nothing is
--- inferred from its other fields, and a `needs` has none.
local function test_a_policy_declares_requirements()
  local function read(call: string): analyzer.Declared
    local found, why = declared(call)
    assert(found ~= nil, call .. ": " .. tostring(why))
    return found
  end
  local function names(list: {string}): string return table.concat(list, " ") end
  assert(names(read('Test.policy { requires = { "root", "portable" } }').requires) == "root portable")
  assert(#read('Test.policy { promises = { "nest" }, grants = { { path = "/proc", letters = "r" } } }').requires == 0)
  local call = 'Test.policy { requires = { "root" }, promises = { "nest" } }'
  local handed = assert(runtime_needs(call))
  assert(names(handed.requires) == "root")
  local from_policy = read(call)
  assert(test_inputs.canonical(test_inputs.as_declared(handed)) == test_inputs.canonical(from_policy))
  assert(test_inputs.canonical(from_policy):find('requires "root"', 1, true))
  assert(test_inputs.canonical(read("Test.policy { }")) == "")
  local refused, why = declared('Test.needs { requires = { "root" } }')
  assert(refused == nil and why:find("no field requires", 1, true), tostring(why))
end

--- A name the table does not have, a name written twice, a `path:` the
--- worker is given no host grant of and a `program:` it cannot find fail
--- the build, naming the rule; a Linux-class name does not.
local function test_a_requirement_that_breaks_a_rule_fails_the_build()
  local cases: {{string}} = {
    { 'Test.policy { requires = { "sandbxo" } }', "unknown requirement \"sandbxo\"" },
    { 'Test.policy { requires = { "path:relative" } }', "absolute path" },
    { 'Test.policy { requires = { "landlock:0" } }', "positive integer" },
    { 'Test.policy { requires = { "root", "root" } }', "\"root\" is written twice" },
    { 'Test.policy { requires = { "path:/etc/hosts" } }', "needs a host grant of the path" },
    { 'Test.policy { requires = { "path:/etc/hosts" }, grants = { { path = "/etc/passwd", letters = "r" } } }',
      "needs a host grant of the path" },
    { 'Test.policy { requires = { "program:jq" } }', "needs the profile \"system\" and env = { \"PATH\" }" },
    { 'Test.policy { requires = { "program:jq" }, profiles = { "system" } }',
      "needs the profile \"system\" and env = { \"PATH\" }" },
    { 'Test.policy { requires = { "program:jq" }, env = { "PATH" } }',
      "needs the profile \"system\" and env = { \"PATH\" }" },
    { 'Test.policy { requires = "root" }', "requires takes a list of string literals" },
  }
  for _, case in ipairs(cases) do
    local found, why = declared(case[1])
    assert(found == nil and why:find("fixture_test.tl:2: test.policy: ", 1, true) ~= nil and
        why:find(case[2], 1, true) ~= nil, case[1] .. ": " .. tostring(why))
  end
  for _, call in ipairs({
      'Test.policy { requires = { "path:/etc/hosts" }, grants = { { path = "/etc/hosts", letters = "r" } } }',
      'Test.policy { requires = { "path:/proc/self/status" }, grants = { { path = "/proc", letters = "r" } } }',
      'Test.policy { requires = { "program:jq" }, profiles = { "system" }, env = { "PATH" } }',
      'Test.policy { requires = { "root", "portable" } }',
      'Test.policy { requires = { "sandbox", "landlock", "landlock:3", "userns", "nest", "own_proc", "proc" } }',
  }) do
    local found, why = declared(call)
    assert(found ~= nil, call .. ": " .. tostring(why))
  end
end
