--- .github/scripts/changed-paths.sh, which names what a branch changed
--- since its base on main for a light run's format check: every path
--- added, changed or removed, one a line, or none at all -- and the
--- check covers the whole tree -- where it cannot name them all. It runs
--- against a stand-in for git on its PATH that answers what the system's
--- git said (testdata/changed_paths, made again by its record.sh) and
--- fails on any other call; build/changed_paths_git_test.tl runs the
--- system's own.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

--- The script under test and the recorded answers, and the system's `sh`
--- and tools, which run it.
Test.policy{
  profiles = { "system" },
  grants = {
    { path = ".github/scripts/changed-paths.sh", letters = "r" },
    { path = "testdata/changed_paths", letters = "r" },
  },
}

-- By its whole path: a process the test starts elsewhere finds it.
local SCRIPT <const> = assert(Fs.absolute(".github/scripts/changed-paths.sh"))
local DATA <const> = assert(Fs.absolute("testdata/changed_paths"))

--- The commit the recorded branch is based on.
local RECORDED_BASE <const> = (assert(Fs.read(DATA .. "/base")):gsub("%s+$", ""))

--- A `git` that fetches only the recorded base, as an origin that holds it
--- does (any other commit: git's refusal, status 128), and diffs the
--- recorded base against HEAD into the recorded answer of $SCENARIO (none
--- where it has no file: a diff that fails); any other call fails, its
--- arguments said.
local FAKE <const> = [[#!/bin/sh
case "$*" in
  "fetch --quiet --no-tags --depth=1 origin $RECORDED_BASE") exit 0 ;;
  "fetch --quiet --no-tags --depth=1 origin "*)
    echo "fatal: remote error: upload-pack: not our ref" >&2; exit 128 ;;
  "diff --no-renames --name-only -z $RECORDED_BASE HEAD --")
    [ -f "$DATA/$SCENARIO.z" ] || { echo "fatal: bad revision" >&2; exit 128; }
    cat "$DATA/$SCENARIO.z"; exit 0 ;;
esac
echo "fake git: unexpected call: $*" >&2
exit 99
]]

--- What the script wrote running with `base` as its base for the change
--- recorded as `scenario`: the paths, nil for none, and what it said to
--- $GITHUB_OUTPUT.
local function named(tmp: string, scenario: string, base: string, limit?: string): string | nil, string
  local dir = tmp .. "/run"
  assert(Fs.mkdirs(dir .. "/bin"))
  assert(Fs.write(dir .. "/bin/git", FAKE))
  assert(Fs.chmod(dir .. "/bin/git", 493))
  local out = dir .. "/changed"
  local said = dir .. "/output"
  assert(Fs.write(said, ""))
  local result = assert(Child.run({ "/bin/sh", SCRIPT }, { cwd = dir, stdin = "null",
    stdout = "capture", stderr = "capture",
    env = { PATH = dir .. "/bin:/usr/bin:/bin", HOME = dir, BASE = base, OUT = out,
      GITHUB_OUTPUT = said, LIMIT = limit or "400", RECORDED_BASE = RECORDED_BASE,
      DATA = DATA, SCENARIO = scenario } }))
  assert(result.ok, (result.stdout or "") .. (result.stderr or ""))
  assert(not (result.stderr or ""):find("fake git", 1, true), result.stderr)
  local listed, _ = Fs.read(out)
  return listed, (assert(Fs.read(said)))
end

--- Every path the branch added, changed or removed, one a line, from
--- its base alone: not what main did since.
local function test_it_names_every_path_the_branch_changed(tmp: string)
  local listed, said = named(tmp, "edited", RECORDED_BASE)
  assert(listed == "doc/a b.md\nedited.tl\nremoved.tl\n", tostring(listed))
  assert(said == "paths=" .. tmp .. "/run/changed\n", said)
  -- Past its limit, it names none.
  local over, over_said = named(tmp, "edited", RECORDED_BASE, "2")
  assert(over == nil and over_said == "", tostring(over) .. over_said)
end

--- A branch that changed nothing names no path, and says so.
local function test_a_branch_that_changed_nothing_names_none(tmp: string)
  local listed, said = named(tmp, "none", RECORDED_BASE)
  assert(listed == "" and said:find("^paths=") ~= nil, tostring(listed) .. said)
end

--- Where it cannot name every path -- no base, a base it cannot fetch, a
--- diff that fails, a path holding a line break -- it names none, and
--- the check covers the whole tree.
local function test_what_it_cannot_name_whole_it_names_none(tmp: string)
  for _, from in ipairs({ "", "not a commit", string.rep("0", 40) }) do
    local listed, said = named(tmp, "linebreak", from)
    assert(listed == nil and said == "", from .. ": " .. tostring(listed) .. said)
  end
  local listed, said = named(tmp, "linebreak", RECORDED_BASE)
  assert(listed == nil and said == "", tostring(listed) .. said)
  local failed, failed_said = named(tmp, "missing", RECORDED_BASE)
  assert(failed == nil and failed_said == "", tostring(failed) .. failed_said)
end
