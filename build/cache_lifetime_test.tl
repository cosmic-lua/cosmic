local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local build_paths = require("build.paths")
local cache_lifetime = require("build.cache_lifetime")

local DAY <const> = 24 * 3600

--- The base the build directories of these tests are in.
local function base_of(tmp: string): string
  local base = assert(sys.realpath(tmp)) .. "/home"
  assert(Fs.mkdirs(base))
  return base
end

--- A build directory in `base` for a project named `name`, with a
--- build's files in it and its use recorded `days` ago, or not at all
--- where `days` is nil.
local function made(base: string, name: string, days?: integer): string
  local directory = build_paths.in_home("/projects/" .. name, base)
  assert(Fs.mkdirs(directory .. "/bin"))
  assert(Fs.write(directory .. "/build.db", "x"))
  if days ~= nil then
    local layout = build_paths.under(directory)
    assert(Fs.write(layout.used, ""))
    local then_s = (Clock.now_ns() // 1000000000) - days * DAY
    assert(sys.utimensat(layout.used, nil, nil, then_s, 0))
  end
  return directory
end

local function exists(path: string): boolean
  return sys.lstat(path) ~= nil
end

--- A directory unused for over thirty days goes, whatever its project;
--- one used within them stays, and so does the caller's own, however old.
local function test_only_a_directory_unused_for_thirty_days_goes(tmp: string)
  local base = base_of(tmp)
  local own = made(base, "own", 90)
  local old = made(base, "old", 31)
  local recent = made(base, "recent", 29)
  local report = cache_lifetime.prune(own)
  assert(report.ran)
  assert(#report.removed == 1 and report.removed[1] == old, table.concat(report.removed, ","))
  assert(#report.troubles == 0, table.concat(report.troubles, "; "))
  assert(not exists(old), "an old directory stayed")
  assert(exists(recent .. "/build.db"), "a recent directory went")
  assert(exists(own .. "/build.db"), "the caller's own directory went")
end

--- A directory a run holds the rebuild lock of stays, however old, and
--- goes once the run lets go.
local function test_a_held_lock_keeps_a_directory(tmp: string)
  local base = base_of(tmp)
  local own = made(base, "own", 0)
  local old = made(base, "old", 90)
  local holding = assert(sys.open(old .. "/rebuild.lock", sys.O_RDWR | sys.O_CREAT, 0x1a4))
  assert(sys.flock(holding, "exclusive"))
  local report = cache_lifetime.prune(own, (Clock.now_ns() // 1000000000))
  assert(#report.removed == 0 and report.busy[1] == old)
  assert(exists(old .. "/build.db"), "a directory with a held lock went")
  assert(sys.close(holding))
  assert(Fs.remove(base .. "/.pruned"))
  report = cache_lifetime.prune(own)
  assert(report.removed[1] == old, "a directory went on staying once its lock was let go")
  assert(not exists(old))
end

--- A link is never followed or removed, whatever it is named, and what
--- is not a build directory's name is left alone.
local function test_only_real_build_directories_are_touched(tmp: string)
  local base = base_of(tmp)
  local own = made(base, "own", 0)
  local outside = assert(sys.realpath(tmp)) .. "/outside"
  assert(Fs.mkdirs(outside))
  assert(Fs.write(outside .. "/used", ""))
  assert(sys.utimensat(outside .. "/used", nil, nil, (Clock.now_ns() // 1000000000) - 90 * DAY, 0))
  assert(Fs.write(outside .. "/build.db", "x"))
  local linked = build_paths.in_home("/projects/linked", base)
  assert(sys.symlink(outside, linked))
  local other = base .. "/notes"
  assert(Fs.mkdirs(other))
  assert(Fs.write(other .. "/used", ""))
  assert(sys.utimensat(other .. "/used", nil, nil, (Clock.now_ns() // 1000000000) - 90 * DAY, 0))
  local upper = base .. "/" .. string.rep("A", 64)
  assert(Fs.mkdirs(upper))
  assert(Fs.write(upper .. "/used", ""))
  assert(sys.utimensat(upper .. "/used", nil, nil, (Clock.now_ns() // 1000000000) - 90 * DAY, 0))
  local report = cache_lifetime.prune(own)
  assert(#report.removed == 0 and #report.troubles == 0)
  assert(exists(outside .. "/build.db"), "a link was followed")
  assert(assert(sys.lstat(linked)).kind == "link", "a link was removed")
  assert(exists(other .. "/used") and exists(upper .. "/used"))
end

--- A directory made before use was recorded is dated, not removed, and
--- one that holds nothing of a build is left alone.
local function test_a_directory_without_a_record_is_dated_not_removed(tmp: string)
  local base = base_of(tmp)
  local own = made(base, "own", 0)
  local before = made(base, "before")
  local empty = build_paths.in_home("/projects/empty", base)
  assert(Fs.mkdirs(empty))
  local report = cache_lifetime.prune(own)
  assert(#report.removed == 0)
  assert(exists(before .. "/build.db"))
  local layout = build_paths.under(before)
  local st = assert(sys.lstat(layout.used))
  assert(math.abs((Clock.now_ns() // 1000000000) - st.mtime) < 60, "the directory was not dated from now")
  assert(not exists(empty .. "/used"), "a directory with no build in it was dated")
  assert(exists(empty))
end

--- A pass over a base is spared for a day after the one before, and runs
--- again once the day is out.
local function test_a_pass_is_spared_for_a_day(tmp: string)
  local base = base_of(tmp)
  local own = made(base, "own", 0)
  assert(cache_lifetime.prune(own).ran)
  local old = made(base, "old", 90)
  local report = cache_lifetime.prune(own)
  assert(not report.ran and #report.removed == 0)
  assert(exists(old .. "/build.db"))
  report = cache_lifetime.prune(own, (Clock.now_ns() // 1000000000) + 2 * DAY)
  assert(report.ran and report.removed[1] == old)
end

--- A directory set aside by a pass that ended before removing it is
--- removed by the next, but one used since is not.
local function test_a_directory_set_aside_is_finished(tmp: string)
  local base = base_of(tmp)
  local own = made(base, "own", 0)
  local half = made(base, "half", 90)
  local aside = half .. ".pruning-1"
  assert(Fs.rename(half, aside))
  local used = made(base, "used", 1)
  local kept = used .. ".pruning-1"
  assert(Fs.rename(used, kept))
  local report = cache_lifetime.prune(own)
  assert(not exists(aside), "a stale directory set aside stayed")
  assert(exists(kept .. "/build.db"), "a used directory set aside went")
  assert(#report.troubles == 0)
end
