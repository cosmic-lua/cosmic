--- .github/scripts/changed-paths.sh, which names what a branch changed
--- since its base on main for a light run's format check: every path
--- added, changed or removed, one a line, or none at all -- and the
--- check covers the whole tree -- where it cannot name them all.
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

--- The script under test, and the system's `sh`, git and tools, which
--- run it.
Test.needs{ reads = { ".github/scripts/changed-paths.sh" }, system = true }

-- By its whole path: a process the test starts elsewhere finds it.
local SCRIPT <const> = assert(Fs.absolute(".github/scripts/changed-paths.sh"))

--- Runs git in `dir`, answering what it printed, or nil where it failed.
local function git(dir: string, args: {string}): string | nil
  local found = Proc.find("git")
  if found == nil then return nil end
  local argv: {string} = { found, "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com",
    "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main" }
  for _, each in ipairs(args) do argv[#argv + 1] = each end
  local result = Child.run(argv, { stdin = "null", stdout = "capture", stderr = "capture",
    env = { PATH = Env.get("PATH") or "/usr/bin:/bin", HOME = dir } })
  if result == nil or not result.ok then return nil end
  return ((result.stdout or ""):gsub("\n$", ""))
end

--- A repository standing in for origin under `tmp`, with a commit on
--- main and a branch from it, whose commit `change` makes in its tree;
--- and a checkout of that branch alone, one commit deep, as
--- actions/checkout makes one. Answers the checkout and main's commit,
--- or nil where the system's git cannot make them.
local function branch(tmp: string, change: function(string)): string | nil, string
  local origin = tmp .. "/origin"
  assert(Fs.mkdirs(origin .. "/doc"))
  if git(origin, { "init", "-q" }) == nil then return nil, "" end
  assert(Fs.write(origin .. "/kept.tl", "return 1\n"))
  assert(Fs.write(origin .. "/edited.tl", "return 1\n"))
  assert(Fs.write(origin .. "/removed.tl", "return 1\n"))
  assert(git(origin, { "add", "." }) and git(origin, { "commit", "-q", "-m", "base" }))
  local base = assert(git(origin, { "rev-parse", "HEAD" }))
  assert(git(origin, { "checkout", "-q", "-b", "branch" }))
  change(origin)
  assert(git(origin, { "add", "-A" }) and git(origin, { "commit", "-q", "--allow-empty", "-m", "branch" }))
  -- The base is no branch's tip once main moves on.
  assert(git(origin, { "checkout", "-q", "main" }))
  assert(Fs.write(origin .. "/later.tl", "return 2\n"))
  assert(git(origin, { "add", "." }) and git(origin, { "commit", "-q", "-m", "later" }))
  assert(git(origin, { "config", "uploadpack.allowAnySHA1InWant", "true" }))
  local checkout = tmp .. "/checkout"
  assert(git(tmp, { "clone", "-q", "--depth=1", "--branch", "branch", "file://" .. origin, checkout }))
  return checkout, base
end

--- What the script wrote running in `checkout` from `base`: the paths,
--- nil for none, and what it said to $GITHUB_OUTPUT.
local function named(checkout: string, base: string, limit?: string): string | nil, string
  local out = checkout .. "/../changed"
  local said = checkout .. "/../output"
  assert(Fs.write(said, ""))
  local result = assert(Child.run({ "/bin/sh", SCRIPT }, { cwd = checkout, stdin = "null",
    stdout = "capture", stderr = "capture",
    env = { PATH = Env.get("PATH") or "/usr/bin:/bin", HOME = checkout, BASE = base, OUT = out,
      GITHUB_OUTPUT = said, LIMIT = limit or "400" } }))
  assert(result.ok, (result.stdout or "") .. (result.stderr or ""))
  local listed, _ = Fs.read(out)
  return listed, (assert(Fs.read(said)))
end

local function edit(origin: string)
  assert(Fs.write(origin .. "/edited.tl", "return 2\n"))
  assert(Fs.remove(origin .. "/removed.tl"))
  assert(Fs.write(origin .. "/doc/a b.md", "added\n"))
end

--- Every path the branch added, changed or removed, one a line, from
--- its base alone: not what main did since.
local function test_it_names_every_path_the_branch_changed(tmp: string)
  local checkout, base = branch(tmp, edit)
  if checkout == nil then return end
  local listed, said = named(checkout, base)
  assert(listed == "doc/a b.md\nedited.tl\nremoved.tl\n", tostring(listed))
  assert(said == "paths=" .. checkout .. "/../changed\n", said)
  -- Past its limit, it names none.
  local over, over_said = named(checkout, base, "2")
  assert(over == nil and over_said == "", tostring(over) .. over_said)
end

--- A branch that changed nothing names no path, and says so.
local function test_a_branch_that_changed_nothing_names_none(tmp: string)
  local checkout, base = branch(tmp, function(_: string) end)
  if checkout == nil then return end
  local listed, said = named(checkout, base)
  assert(listed == "" and said:find("^paths=") ~= nil, tostring(listed) .. said)
end

--- Where it cannot name every path -- no base, a base it cannot fetch,
--- a path holding a line break -- it names none, and the check covers
--- the whole tree.
local function test_what_it_cannot_name_whole_it_names_none(tmp: string)
  local checkout, base = branch(tmp, function(origin: string)
    edit(origin)
    assert(Fs.write(origin .. "/two\nlines.tl", "return 3\n"))
  end)
  if checkout == nil then return end
  for _, from in ipairs({ "", "not a commit", string.rep("0", 40), base }) do
    local listed, said = named(checkout, from)
    assert(listed == nil and said == "", from .. ": " .. tostring(listed) .. said)
  end
end
