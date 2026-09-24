local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local Fixture = require("cosmic_ci.fixture")

local function test_child_timeout_retains_diagnostics(tmp: string)
  local diagnostics = tmp .. "/timeout-logs"
  local started = assert(Time.monotonic_ns())
  local called, failure = pcall(Fixture.run, "timeout",
    { "/bin/sh", "-c", "printf 'before timeout\\n'; exec sleep 30" },
    tmp, diagnostics, nil, 500)
  local elapsed = assert(Time.monotonic_ns()) - started
  assert(not called and elapsed < 5000 * 1000000,
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
  assert(#targets == 2 and targets[1].id == 1 and targets[2].id == 1 and
    targets[1].configuration == 1 and targets[2].configuration == 2)
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
    assert(not pcall(Fixture.targets, invalid_path),
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
  assert(not called and tostring(failure):find("absent", 1, true),
    tostring(failure))
  assert(not Fs.stat(tmp .. "/logs/missing.out"), "a child started anyway")
end
