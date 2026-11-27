--- The checks of `ci/` that a run of `fix` over the whole of cosmic's own tree starts beside its own. `ci/` is a project
--- of its own, which the tree's run reads none of, and it runs on two cosmics: the tree's, which CI's format phase and
--- the queue's macOS leg run its tests on, and the release ci/cosmic-driver.pin names, which runs it in every job. A change
--- outside `ci/` breaks it on either: a stdlib API it uses, or a file of ci/bootstrap-files.txt the release runs
--- standalone. So the run holds `ci/` to both, as CI does:
---
--- - this tool's `fix` (with `--check` where the run checks), run as [`bin/cosmic`] with `ci/` as the working directory;
--- - `bin/cosmic-bootstrap cosmic_ci/driver.tl check-islands` (ci/cosmic_ci/islands.tl), which checks the bootstrap's
---   files and all of `ci/` on the pinned release, fetched and verified by its digest the first time.
---
--- Both start before the tree's own checks and run beside them, each with a build base of its own; [`CiProject.finish`] waits for them. `COSMIC_BOOTSTRAP` is
--- left out of the release's environment: it names another host in place of the pin's, which is not the check.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local clock = require("build.clock")
local plural = require("build.plural")

local record CiProject
  --- The checks started, each with what it is called in a finding.
  record Started
    names: mut {string}
    handles: mut {Child.Handle}
    started: integer
    --- A check that could not start, in words: a finding.
    refused: mut {string}
  end
end

--- How long [`CiProject.finish`] waits for each check, counted from when it starts to wait, not from the start: the
--- tree's own checks, beside which they run, take up to 11 minutes cold. A cold fetch of the release and a cold build of
--- `ci/` take well under a minute.
local TIMEOUT_NS <const> = Clock.seconds(600)

--- Whether `root`, cosmic's own tree, holds the `ci/` project these checks run in.
function CiProject.applies(root: string): boolean
  local driver, _ = Fs.status(root .. "/ci/cosmic_ci/driver.tl")
  local bootstrap, _ = Fs.status(root .. "/bin/cosmic-bootstrap")
  return driver ~= nil and driver.exists and bootstrap ~= nil and bootstrap.exists
end

--- The build base the pinned release's check of `ci/` uses, made private (a base that others can write is refused), or nil
--- where there is none to name: inside COSMIC_BUILD_HOME where it is set, else in the user's cache.
local function pinned_base(env: {string:string}): string?
  local given = env["COSMIC_BUILD_HOME"] or ""
  local parent: string
  if given ~= "" then
    parent = given
  else
    local cache = env["XDG_CACHE_HOME"] or ""
    local home = env["HOME"] or ""
    if cache:sub(1, 1) == "/" then
      parent = cache
    elseif home:sub(1, 1) == "/" then
      parent = home .. "/.cache"
    else
      return nil
    end
  end
  local base = parent .. "/cosmic-pinned-ci"
  local made, _ = Fs.mkdirs(base, 448)
  if not made then return nil end
  return base
end

--- Starts both checks of `root .. "/ci"`; `checking` passes `--check` to this tool's `fix`, which otherwise mends.
function CiProject.start(root: string, checking: boolean): CiProject.Started
  local ci = root .. "/ci"
  local started: CiProject.Started = { names = {}, handles = {}, started = Clock.monotonic_ns(), refused = {} }
  local function launch(name: string, argv: {string}, env: {string:string})
    -- In this process's group, so the interrupt that ends the run ends them too.
    local handle, why = Child.start(argv, { cwd = ci, env = env, stdout = "capture", stderr = "capture",
      timeout_ns = Child.FOREVER, process_group = false })
    if handle == nil then
      local line = "ci/: " .. name .. " did not start: " .. tostring(why)
      started.refused[#started.refused + 1] = line
      return
    end
    started.names[#started.names + 1] = name
    started.handles[#started.handles + 1] = handle
  end
  -- The tool as [`bin/cosmic`] runs it, which finds this tree's tool from ci/ as from anywhere else.
  local argv: mut {string} = { root .. "/bin/cosmic", "fix" }
  if checking then argv[#argv + 1] = "--check" end
  launch("`../bin/cosmic fix" .. (if checking then " --check" else "" end) .. "` in ci/", argv, Env.all())
  local env = Env.all()
  env["COSMIC_BOOTSTRAP"] = nil
  -- Its own build base: both tools build `ci/` into the build directory of that root, and a second tool finds a
  -- database another's writer made unreadable (build/writer.tl), answers from empty ones, and fails every link, as the
  -- release did when the two started together on a cold cache (queue run 45922217954).
  local base = pinned_base(env)
  if base ~= nil then env["COSMIC_BUILD_HOME"] = base end
  launch("`bin/cosmic-bootstrap cosmic_ci/driver.tl check-islands` (the pinned release) in ci/",
    { root .. "/bin/cosmic-bootstrap", "cosmic_ci/driver.tl", "check-islands" }, env)
  return started
end

--- How many lines of a failing check a finding shows; the rest are counted.
local SHOWN <const> = 30

--- The lines of `text`, a failing check's output, that a finding keeps: what it found, without its progress lines and the
--- links that do not resolve only because the build was refused, the other links last, at most [`SHOWN`] of them. A
--- path is named from the tree's root (`ci/...`).
local function said(text: string): {string}
  local first: mut {string} = {}
  local links: mut {string} = {}
  for read in text:gmatch("[^\n]+") do
    local rest = read:match("^fix: FAIL  (.*)$")
    local line = rest or read
    local noise = (rest == nil and line:sub(1, 5) == "fix: ") or line:find("; fix that first)", 1, true) ~= nil
    if not noise then
      if line:match("^[%w_][%w_/.-]*%.tl:") ~= nil and line:sub(1, 3) ~= "ci/" then
        line = "ci/" .. line
      end
      if line:find(": link: ", 1, true) ~= nil then
        links[#links + 1] = line
      else
        first[#first + 1] = line
      end
    end
  end
  local kept: mut {string} = {}
  local left = 0
  for _, group in ipairs({ first, links }) do
    for _, line in ipairs(group) do
      if #kept < SHOWN then kept[#kept + 1] = line else left = left + 1 end
    end
  end
  if #kept == 0 then
    kept[#kept + 1] = "(it said nothing but its progress; run it alone to see it)"
  end
  if left > 0 then
    kept[#kept + 1] = "... and " .. plural.count(left, "more line") .. "; run it alone to see them"
  end
  return kept
end

--- What a passing check says it changed: the files a mending `fix` laid out, named from the tree's root.
local function mended(text: string): {string}
  local lines: mut {string} = {}
  for line in text:gmatch("[^\n]+") do
    local file = line:match("^fix: fixed  (.*)$")
    if file ~= nil then lines[#lines + 1] = "fix: fixed  ci/" .. file end
  end
  return lines
end

--- Waits for the checks `started` and answers a finding for each that failed, and the lines that say what passed: the
--- files of `ci/` a mending run fixed, then the line that says both checks passed.
function CiProject.finish(started: CiProject.Started): {string}, {string}
  local findings: mut {string} = {}
  local passed: mut {string} = {}
  for _, line in ipairs(started.refused) do findings[#findings + 1] = line end
  for i, handle in ipairs(started.handles) do
    local name = started.names[i] or "a check"
    local result, why = handle:wait(TIMEOUT_NS)
    if result == nil then
      findings[#findings + 1] = "ci/: " .. name .. " ended without a result: " .. tostring(why)
    elseif not result.ok then
      local ended = if result.timed_out then "ran past its " .. tostring(TIMEOUT_NS // 1000000000) .. " s"
        elseif result.code ~= nil then "exited " .. tostring(result.code)
        else "was ended by signal " .. tostring(result.signal) end
      local lines = said((result.stdout or "") .. "\n" .. (result.stderr or ""))
      findings[#findings + 1] = "ci/: " .. name .. " " .. ended .. "; to run it alone, `cd ci` first:\n  " ..
        table.concat(lines, "\n  ")
    else
      for _, line in ipairs(mended((result.stdout or "") .. "\n" .. (result.stderr or ""))) do
        passed[#passed + 1] = line
      end
    end
  end
  passed[#passed + 1] = "fix: ci/ checked as a project of its own, with this tool and on the pinned release, " ..
    "done " .. clock.took(started.started) .. " after they started"
  return findings, passed
end

return CiProject
