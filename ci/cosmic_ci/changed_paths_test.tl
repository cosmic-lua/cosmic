--- `changed-paths`, which names what a branch changed since its base on
--- main for a light run's format check: every path added, changed or
--- removed, one a line, or none at all -- and the check covers the whole
--- tree -- where it cannot name them all. It runs against a git that
--- answers what the system's git said (testdata/changed_paths, made again
--- by its record.sh) and fails on any other call; no test runs the
--- host's.
local ChangedPaths = require("cosmic_ci.changed_paths")
local Fs = require("cosmic.fs")
local GithubFake = require("cosmic_ci.github_fake")
local Test = require("cosmic.test")

--- The recorded answers.
Test.policy{
  grants = { { path = "testdata/changed_paths", letters = "r" } },
}

local DATA <const> = "testdata/changed_paths"

--- The commit the recorded branch is based on.
local RECORDED_BASE <const> = (assert(Fs.read(DATA .. "/base")):gsub("%s+$", ""))

--- A git that fetches only the recorded base, as an origin that holds it
--- does (any other commit: git's refusal), and diffs the recorded base
--- against HEAD into the recorded answer of `scenario` (none where it has
--- no file: a diff that fails); any other call fails the test, its
--- arguments said.
local function recorded(scenario: string, calls: {string}): ChangedPaths.Git
  return function(argv: {string}, seconds: integer): boolean, string
    local line = table.concat(argv, " ")
    calls[#calls + 1] = line
    assert(seconds == (argv[1] == "fetch" and 60 or 0), line .. " is cut off after " .. seconds .. " s")
    if line == "fetch --quiet --no-tags --depth=1 origin " .. RECORDED_BASE then return true, "" end
    if line:sub(1, #"fetch --quiet --no-tags --depth=1 origin ") == "fetch --quiet --no-tags --depth=1 origin " then
      return false, ""
    end
    if line == "diff --no-renames --name-only -z " .. RECORDED_BASE .. " HEAD --" then
      local answer = Fs.read(DATA .. "/" .. scenario .. ".z")
      if answer == nil then return false, "" end
      return true, answer
    end
    error("unexpected git call: " .. line)
  end
end

--- What `changed-paths` wrote running with `base` as its base for the
--- change recorded as `scenario`: the paths, nil for none, what it said
--- to $GITHUB_OUTPUT, what it printed, and its status.
local function named(tmp: string, scenario: string, base: string, limit?: string): string | nil, string, string, integer
  local out = tmp .. "/changed"
  -- A list an earlier run left is no answer of this one's.
  assert(Fs.write(out, "stale\n"))
  local fake = GithubFake.new(function(_path: string, _nth: integer): string | nil return nil end)
  local code = ChangedPaths.changed_paths({ BASE = base, OUT = out, LIMIT = limit or "400" }, fake.host,
    recorded(scenario, {}))
  local listed, _ = Fs.read(out)
  return listed, GithubFake.text(fake.outputs), GithubFake.text(fake.printed), code
end

--- Every path the branch added, changed or removed, one a line, from
--- its base alone: not what main did since.
local function test_it_names_every_path_the_branch_changed(tmp: string)
  local listed, said, printed, code = named(tmp, "edited", RECORDED_BASE)
  assert(code == 0 and listed == "doc/a b.md\nedited.tl\nremoved.tl\n", tostring(listed))
  assert(said == "paths=" .. tmp .. "/changed\n", said)
  assert(printed == "the format check lays out the 3 paths changed since " .. RECORDED_BASE .. "\n", printed)
  -- Past its limit, it names none.
  local over, over_said, over_printed = named(tmp, "edited", RECORDED_BASE, "2")
  assert(over == nil and over_said == "", tostring(over) .. over_said)
  assert(over_printed == "the format check covers the whole tree: 3 paths changed, more than 2\n", over_printed)
end

--- A branch that changed nothing names no path, and says so.
local function test_a_branch_that_changed_nothing_names_none(tmp: string)
  local listed, said, printed = named(tmp, "none", RECORDED_BASE)
  assert(listed == "" and said == "paths=" .. tmp .. "/changed\n", tostring(listed) .. said)
  assert(printed == "the format check lays out the 0 paths changed since " .. RECORDED_BASE .. "\n", printed)
end

--- Where it cannot name every path -- no base, a base it cannot fetch, a
--- diff that fails, a path holding a line break -- it names none, says
--- why, and the check covers the whole tree; the step still succeeds.
local function test_what_it_cannot_name_whole_it_names_none(tmp: string)
  local whole <const> = "the format check covers the whole tree: "
  for _, from in ipairs({ "", "not a commit", RECORDED_BASE:upper(), RECORDED_BASE:sub(1, 39) }) do
    local listed, said, printed, code = named(tmp, "linebreak", from)
    assert(code == 0 and listed == nil and said == "", from .. ": " .. tostring(listed) .. said)
    assert(printed == whole .. "no base on main\n", printed)
  end
  local missing = string.rep("0", 40)
  local listed, said, printed, code = named(tmp, "linebreak", missing)
  assert(code == 0 and listed == nil and said == "", tostring(listed) .. said)
  assert(printed == whole .. "could not fetch " .. missing .. "\n", printed)
  listed, said, printed, code = named(tmp, "linebreak", RECORDED_BASE)
  assert(code == 0 and listed == nil and said == "", tostring(listed) .. said)
  assert(printed == whole .. "a path changed holds a line break\n", printed)
  local failed, failed_said, failed_printed, failed_code = named(tmp, "missing", RECORDED_BASE)
  assert(failed_code == 0 and failed == nil and failed_said == "", tostring(failed) .. failed_said)
  assert(failed_printed == whole .. "could not list what changed since " .. RECORDED_BASE .. "\n", failed_printed)
  -- Where it cannot write the list, it names none.
  local fake = GithubFake.new(function(_path: string, _nth: integer): string | nil return nil end)
  local code2 = ChangedPaths.changed_paths({ BASE = RECORDED_BASE, OUT = tmp .. "/no/such/dir/changed" },
    fake.host, recorded("edited", {}))
  assert(code2 == 0 and #fake.outputs == 0 and
      GithubFake.text(fake.printed) == whole .. "could not write " .. tmp .. "/no/such/dir/changed\n",
    GithubFake.text(fake.printed))
end

--- A step with no OUT, or a limit or a wait that is no whole number, is
--- a mistake in the workflow, and fails.
local function test_a_step_without_its_settings_fails(tmp: string)
  for _, env in ipairs({
      { BASE = RECORDED_BASE },
      { BASE = RECORDED_BASE, OUT = "" },
      { BASE = RECORDED_BASE, OUT = tmp .. "/changed", LIMIT = "many" },
      { BASE = RECORDED_BASE, OUT = tmp .. "/changed", FETCH_SECONDS = "-1" },
  }) do
    local fake = GithubFake.new(function(_path: string, _nth: integer): string | nil return nil end)
    local calls: {string} = {}
    assert(ChangedPaths.changed_paths(env, fake.host, recorded("edited", calls)) == 2)
    assert(#calls == 0 and #fake.outputs == 0, table.concat(calls, "\n"))
  end
end

--- The fetch is cut off after FETCH_SECONDS, the diff never.
local function test_the_fetch_waits_as_long_as_it_is_told(tmp: string)
  local waits: {integer} = {}
  local fake = GithubFake.new(function(_path: string, _nth: integer): string | nil return nil end)
  local code = ChangedPaths.changed_paths({ BASE = RECORDED_BASE, OUT = tmp .. "/changed", FETCH_SECONDS = "7" },
    fake.host, function(_argv: {string}, seconds: integer): boolean, string
      waits[#waits + 1] = seconds
      return true, ""
    end)
  assert(code == 0 and #waits == 2 and waits[1] == 7 and waits[2] == 0, table.concat(waits as {string}, ","))
end
