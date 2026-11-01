--- The paths a branch changed since its base on main, for a light run's
--- format check (ci.yml's `format` job), which lays out only those and
--- makes every check spanning files over the whole tree (`cosmic fix
--- --check --changed`, through cosmic_ci's orchestration):
---
---     BASE=<commit> OUT=<file> cosmic-driver cosmic_ci/driver.tl changed-paths
---
--- BASE is the tree's base on main (`merge-base`), whose tree main's own
--- run held to the whole tree's check. `changed-paths` fetches that one
--- commit into the checkout (from origin, with the credentials
--- actions/checkout keeps), writes every path HEAD adds, changes or
--- removes since it to OUT, one a line, and `paths=<OUT>` to
--- $GITHUB_OUTPUT (standard output, for a run by hand). Where it cannot
--- -- no base, a fetch or a diff that fails, a path holding a line break,
--- more than LIMIT paths (400, past which the whole tree's check costs
--- about as much) -- it writes neither, and the check covers the whole
--- tree. The fetch is cut off after FETCH_SECONDS (60, 0 for no limit). Past a missing
--- OUT or a LIMIT or FETCH_SECONDS that is no whole number, which fail
--- the step, it returns 0: a list not made costs time, never a result.
---
--- It runs the host's own `git`, through a [`ChangedPaths.Git`] a test
--- replaces with git's recorded answers (testdata/changed_paths, made
--- again by its record.sh).
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Github = require("cosmic_ci.github")
local Plural = require("cosmic_ci.plural")
local Proc = require("cosmic.proc")
local StepEnv = require("cosmic_ci.step_env")

local record ChangedPaths
  --- What a run of git came to: whether it exited 0, and what it wrote to standard output.
  record Ran
    ok: boolean
    output: string
  end
  --- Runs `git` with `argv`, ended after `seconds` (never for 0), and answers whether it
  --- exited 0 and what it wrote to standard output. Where git cannot run,
  --- or runs out of time, it answers false.
  type Git = function(argv: {string}, seconds: integer): Ran
  --- [`ChangedPaths.Git`] for the host's `git`, found on `env`'s PATH,
  --- run in `env`.
  live_git: function(env: {string:string}): Git
  --- The step, in `env`, with `git` and `host`'s outputs and lines.
  changed_paths: function(env: {string:string}, host: Github.Host, git: Git): integer
  --- `driver.tl changed-paths`, in the process's environment.
  command: function(argv: {string}): integer
end

local whole <const> = StepEnv.whole

-- No test runs this, since no test runs the system's git: the tests hold
-- the argv through a recorded git, and finding git, the time limit and a
-- failed run read as false are met only in CI, where any of them going
-- wrong reads as the whole tree rather than a wrong list.
function ChangedPaths.live_git(env: {string:string}): ChangedPaths.Git
  local git, _ = Proc.find("git", env["PATH"] or "")
  return function(argv: {string}, seconds: integer): ChangedPaths.Ran
    if git == nil then return { ok = false, output = "" } end
    local words: mut {string} = { git }
    for _, word in ipairs(argv) do words[#words + 1] = word end
    local timeout_ns: integer? = nil
    if seconds > 0 then timeout_ns = Clock.seconds(seconds) end
    local result, _ = Child.run(words, { env = env, stdin = "null", stdout = "capture",
      timeout_ns = timeout_ns })
    if result == nil or not result.ok then return { ok = false, output = "" } end
    return { ok = true, output = result.stdout or "" }
  end
end

function ChangedPaths.changed_paths(env: {string:string}, host: Github.Host, git: ChangedPaths.Git): integer
  local out = env["OUT"]
  if out == nil or out == "" then
    local _, _ = Fs.put(Fs.stderr, "changed-paths: OUT names the file to write the paths to\n")
    return 2
  end
  -- A stale list must not outlive a refusal: a later step reads OUT.
  local _, _ = Fs.remove(out)
  local function whole_tree(reason: string): integer
    host.print("the format check covers the whole tree: " .. reason)
    return 0
  end
  local limit, why = whole(env, "LIMIT", 400)
  local wait: integer?
  if limit ~= nil then wait, why = whole(env, "FETCH_SECONDS", 60) end
  if limit == nil or wait == nil then
    local _, _ = Fs.put(Fs.stderr, "changed-paths: " .. why .. "\n")
    return 2
  end
  local base = env["BASE"] or ""
  if not Github.is_commit(base) then return whole_tree("no base on main") end
  if not git({ "fetch", "--quiet", "--no-tags", "--depth=1", "origin", base }, wait).ok then
    return whole_tree("could not fetch " .. base)
  end
  local diffed = git({ "diff", "--no-renames", "--name-only", "-z", base, "HEAD", "--" }, 0)
  if not diffed.ok then return whole_tree("could not list what changed since " .. base) end
  local listed = diffed.output
  -- One NUL ends each path, so a path holding a line break is one line
  -- too many.
  if listed:find("\n", 1, true) then return whole_tree("a path changed holds a line break") end
  local _, paths = listed:gsub("\0", "\n")
  if paths > limit then
    return whole_tree(Plural.count(paths, "path") .. " changed, more than " .. tostring(limit))
  end
  local written, _ = Fs.write(out, (listed:gsub("\0", "\n")))
  if not written then
    return whole_tree("could not write " .. out)
  end
  host.output("paths=" .. out)
  host.print("the format check lays out the " .. Plural.count(paths, "path") .. " changed since " .. base)
  return 0
end

function ChangedPaths.command(_argv: {string}): integer
  local env = Env.all()
  return ChangedPaths.changed_paths(env, Github.live(env), ChangedPaths.live_git(env))
end

return ChangedPaths
