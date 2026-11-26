local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local scratch_sweep = require("build.scratch_sweep")

local NOW <const> = 2000000000

--- A directory at `path` last modified `hours` before NOW.
local function made(path: string, hours: integer): string
  assert(Fs.mkdirs(path .. "/real"))
  assert(sys.utimensat(path, nil, nil, NOW - hours * 3600, 0))
  return path
end

local function exists(path: string): boolean
  return sys.lstat(path) ~= nil
end

--- Only a scratch directory's name is swept: not the sandbox's fixed one,
--- a worker's report, or anything else.
local function test_only_scratch_names_match()
  assert(scratch_sweep.named("cosmic-test-____abc123"))
  assert(scratch_sweep.named("cosmic-test-Ab9xYz"))
  assert(not scratch_sweep.named("cosmic-test-padded-to-a-macos-length____"))
  assert(not scratch_sweep.named("cosmic-test-____abc12"))
  assert(not scratch_sweep.named("cosmic-test-report-5"))
  assert(not scratch_sweep.named("other-____abc123"))
end

--- A scratch directory over a day old goes; a newer one, a link to
--- an old one, and an old directory of another name stay.
local function test_only_old_scratch_directories_go(tmp: string)
  local base = assert(sys.realpath(tmp))
  local old = made(base .. "/cosmic-test-____old001", 25)
  local new = made(base .. "/cosmic-test-____new001", 23)
  local other = made(base .. "/kept-____old002", 30)
  local target = made(base .. "/target", 30)
  assert(Fs.symlink(target, base .. "/cosmic-test-____lnk001"))
  local report = scratch_sweep.prune(base, NOW)
  assert(report.removed == 1, tostring(report.removed))
  assert(#report.troubles == 0, table.concat(report.troubles, "\n"))
  assert(not exists(old))
  assert(exists(new))
  assert(exists(other))
  assert(exists(target .. "/real"))
  assert(exists(base .. "/cosmic-test-____lnk001"))
end

--- A pass out of time removes nothing.
local function test_a_spent_budget_removes_nothing(tmp: string)
  local base = assert(sys.realpath(tmp))
  local old = made(base .. "/cosmic-test-____old001", 25)
  local report = scratch_sweep.prune(base, NOW, 0)
  assert(report.removed == 0)
  assert(exists(old))
end
