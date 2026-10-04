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
Test.needs{ reads = { "cosmic/sandbox.tl" } }

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
  { "Test.needs { tool = true }", 'Test.policy { profiles = { "cosmic" } }' },
  { "Test.needs { tool = true, system = true }",
    'Test.policy { profiles = { "system", "cosmic" } }' },
  { "Test.needs { nests = true }", 'Test.policy { promises = { "nest" } }' },
  { 'Test.needs { env = { "PATH", "HOME", "PATH" } }',
    'Test.policy { env = { "PATH", "HOME", "PATH" } }' },
  { 'Test.needs { network = { "127.0.0.1", "127.0.0.2" } }',
    'Test.policy { loopback = { "127.0.0.1", "127.0.0.2" } }' },
  -- A promise with no `needs` field changes no key before the filter runs.
  { "Test.needs { }", 'Test.policy { promises = { "fork", "jit", "fattr" }, tmp = true }' },
  { 'Test.needs { reads = { "testdata" }, system = true, tool = true, nests = true, ' ..
      'env = { "PATH", "TMPDIR" }, network = { "127.0.0.1" } }',
    'Test.policy { profiles = { "cosmic", "system" }, promises = { "nest", "fork" }, ' ..
      'grants = { { path = "testdata", letters = "r" } }, env = { "PATH", "TMPDIR" }, ' ..
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
    { "Test.policy { reeds = {} }", "test.policy: has no field reeds; it has connect, env" },
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
--- `Policy`, no more and no fewer.
local function test_the_policy_record_is_the_sandboxs()
  local text = assert(Fs.read("cosmic/sandbox.tl"))
  local record = assert(text:match("\n  record Policy\n(.-)\n  end\n"), "no Policy")
  local theirs: {string} = {}
  for name in ("\n" .. record):gmatch("\n    ([%a_]+): ") do theirs[#theirs + 1] = name end
  table.sort(theirs)
  local _, said = Test.needs_of({ nothing = true })
  local listed = assert(said:match("it has (.*)$"), said)
  assert(listed == table.concat(theirs, ", "), listed .. " is not " .. table.concat(theirs, ", "))
end
