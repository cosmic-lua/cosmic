local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Fixture = require("cosmic_ci.fixture")

-- The bound leaves the shell time to print on a slow or loaded runner;
-- the elapsed check, well short of the `sleep` and of the 30 s a test
-- of cosmic_ci gets (ci.yml's "check the pinned CI driver" sets no
-- COSMIC_TEST_TIMEOUT), shows the bound is what ended the child.
local function test_child_timeout_retains_diagnostics(tmp: string)
  local diagnostics = tmp .. "/timeout-logs"
  local started = Clock.monotonic_ns()
  local called, failure = pcall(Fixture.run, "timeout",
    { "/bin/sh", "-c", "printf 'before timeout\\n'; exec sleep 60" },
    tmp, diagnostics, nil, Clock.seconds(5))
  local elapsed = Clock.monotonic_ns() - started
  assert(not called and elapsed < Clock.seconds(25),
    "fixture timeout did not remain bounded")
  local diagnostic = tostring(failure)
  assert(diagnostic:find("timed_out=true", 1, true),
    "fixture timeout diagnostic omitted its verdict")
  assert(diagnostic:find("stdout=" .. diagnostics .. "/timeout.out", 1, true) and
      diagnostic:find("stderr=" .. diagnostics .. "/timeout.err", 1, true),
    "fixture timeout diagnostic omitted its retained log paths")
  assert(Fixture.small(diagnostics .. "/timeout.out", 1024) ==
      "before timeout\n", "fixture timeout output was not retained")
  assert(assert(Fs.stat(diagnostics .. "/timeout.err")).kind == "file",
    "fixture timeout stderr was not retained")
end

local function test_target_records_are_exact(tmp: string)
  local valid = "1\t1\trelease\tone\tLinux\tx86_64\n" ..
    "1\t2\tsanitized\ttwo\tLinux\tx86_64\n"
  local path = tmp .. "/valid.tsv"
  Fixture.write(path, valid)
  local targets = Fixture.targets(path)
  assert(#targets == 2 and assert(targets[1]).id == 1 and assert(targets[2]).id == 1 and
      assert(targets[1]).configuration == 1 and assert(targets[2]).configuration == 2)
  local invalid: {string:string} = {
    extra = "1\t1\trelease\tone\tLinux\tx86_64\textra\n",
    unterminated = "1\t1\trelease\tone\tLinux\tx86_64",
    empty = "1\t1\trelease\tone\tLinux\tx86_64\n\n",
    pair = valid .. "1\t1\trelease\tthree\tDarwin\tarm64\n",
    name = valid .. "2\t1\trelease\tone\tDarwin\tarm64\n",
    numeric = "999999999999999999999999\t1\trelease\tone\tLinux\tx86_64\n",
  }
  for name, contents in pairs(invalid) do
    local invalid_path = tmp .. "/" .. name .. ".tsv"
    Fixture.write(invalid_path, contents)
    local accepted, _ = pcall(Fixture.targets, invalid_path)
    assert(not accepted,
      "invalid target records were accepted: " .. name)
  end
end

local function test_call_with_descriptors_opens_each_path(tmp: string)
  Fixture.write(tmp .. "/eight", "eight;")
  Fixture.write(tmp .. "/nine", "nine")
  local outcome = Fixture.call_with_descriptors("descriptors",
    { "/bin/sh", "-c", "cat <&8; cat <&9" }, tmp, tmp .. "/logs",
    Fixture.environment(), { [8] = tmp .. "/eight", [9] = tmp .. "/nine" })
  assert(outcome.result.ok and Fixture.read(outcome.out) == "eight;nine",
    "the child did not read the files on its descriptors")
end

local function test_call_with_descriptors_refuses_a_missing_path(tmp: string)
  Fixture.write(tmp .. "/eight", "eight")
  local called, failure = pcall(Fixture.call_with_descriptors, "missing",
    { "/bin/sh", "-c", "exit 0" }, tmp, tmp .. "/logs", Fixture.environment(),
    { [8] = tmp .. "/eight", [9] = tmp .. "/absent" })
  assert(not called and tostring(failure):find("absent", 1, true) ~= nil,
    tostring(failure))
  assert(not Fs.stat(tmp .. "/logs/missing.out"), "a child started anyway")
end

--- A child a fixture starts compiles cold, whatever cache the fixture's
--- own run shares, unless the fixture says otherwise.
local function test_a_fixtures_children_take_no_shared_compiles()
  assert(Fixture.environment()["COSMIC_BUILD_CACHE"] == "0",
    "a fixture's child takes the fixture's shared compiles")
  assert(Fixture.environment({ COSMIC_BUILD_CACHE = "/elsewhere.db" })["COSMIC_BUILD_CACHE"] ==
      "/elsewhere.db", "a fixture cannot give its child a cache")
end

--- A `cosmic test` a fixture's child runs does not sandbox its workers,
--- whatever the fixture's own worker is given (COSMIC_TEST_SANDBOX=1
--- where the leg sandboxes it), unless the fixture says otherwise.
local function test_a_fixtures_children_run_cosmic_test_unsandboxed()
  local sandboxed = { COSMIC_TEST_SANDBOX = "1", COSMIC_SANDBOX = "must" }
  local child = Fixture.environment_of(sandboxed)
  assert(child["COSMIC_TEST_SANDBOX"] == "0",
    "a fixture's child sandboxes the workers of a cosmic test it runs")
  assert(child["COSMIC_SANDBOX"] == "must" and sandboxed["COSMIC_TEST_SANDBOX"] == "1")
  assert(Fixture.environment_of(sandboxed, { COSMIC_TEST_SANDBOX = "1" })["COSMIC_TEST_SANDBOX"] ==
      "1", "a fixture cannot choose its child's sandbox")
  assert(Fixture.environment()["COSMIC_TEST_SANDBOX"] == "0")
end

--- An artifact of the shape [`Fixture.retargeted`] reads: a head, a database with a `meta` table, and the trailer
--- that locates them.
local function artifact_with(path: string, scratch: string, built_from: string?): string
  local db = assert(Sqlite.open(scratch, { writable = true }))
  assert(Sqlite.run(db, "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID"))
  assert(Sqlite.run(db, "INSERT INTO meta (key, value) VALUES ('boot_hash', 'kept')"))
  if built_from ~= nil then
    assert(Sqlite.run(db, "INSERT INTO meta (key, value) VALUES ('built_from', ?1)", { { text = built_from } }))
  end
  assert(db:close())
  local head = "the launcher and the manifest"
  local database = Fixture.read(scratch)
  local trailer = "CosmicT1" .. string.pack(">I4I4I8I8I8I8", 1, 48, 3, 4, #head, #database)
  Fixture.write(path, head .. database .. trailer)
  return head
end

--- A fixture that puts a tool in a copy of its tree says which tree the tool is built from, and nothing else of the
--- tool moves.
local function test_a_tool_is_retargeted_to_the_tree_it_is_said_to_be_built_from(tmp: string)
  local head = artifact_with(tmp .. "/tool", tmp .. "/scratch.db", "/where/it/was/booted")
  Fixture.retargeted(tmp .. "/tool", tmp .. "/moved", "/where/it/is/now")
  local meta = Fixture.meta(tmp .. "/moved", tmp .. "/read.db")
  assert(meta["built_from"] == "/where/it/is/now" and meta["boot_hash"] == "kept")
  assert(Fixture.read(tmp .. "/moved"):sub(1, #head) == head, "the head moved")
  Fixture.retargeted(tmp .. "/moved", tmp .. "/old", nil)
  local old = Fixture.meta(tmp .. "/old", tmp .. "/read.db")
  assert(old["built_from"] == nil and old["boot_hash"] == "kept", "a tool older than the row has none")
end
