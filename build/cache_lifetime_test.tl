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

--- A record that is no regular file or is dated in the future is no
--- proof of disuse, and a directory without a build's files is not a
--- build directory, whatever its record says.
local function test_an_odd_record_proves_nothing(tmp: string)
  local base = base_of(tmp)
  local own = made(base, "own", 0)
  local linked = made(base, "linked", 90)
  local target = assert(sys.realpath(tmp)) .. "/old-record"
  assert(Fs.write(target, ""))
  assert(sys.utimensat(target, nil, nil, (Clock.now_ns() // 1000000000) - 90 * DAY, 0))
  assert(Fs.remove(linked .. "/used"))
  assert(sys.symlink(target, linked .. "/used"))
  local future = made(base, "future", -5)
  local bare = build_paths.in_home("/projects/bare", base)
  assert(Fs.mkdirs(bare))
  assert(Fs.write(bare .. "/used", ""))
  assert(sys.utimensat(bare .. "/used", nil, nil, (Clock.now_ns() // 1000000000) - 90 * DAY, 0))
  local report = cache_lifetime.prune(own)
  assert(#report.removed == 0 and #report.troubles == 0)
  assert(exists(linked .. "/build.db") and exists(future .. "/build.db") and exists(bare .. "/used"))
end

--- A base another user could write into is not pruned.
local function test_a_base_others_can_write_is_not_pruned(tmp: string)
  local base = base_of(tmp)
  local own = made(base, "own", 0)
  local old = made(base, "old", 90)
  assert(sys.chmod(base, 0x1ff))
  local report = cache_lifetime.prune(own)
  assert(not report.ran and exists(old .. "/build.db"))
end

--- A pass past its budget starts no removal and does not spare its
--- base, so the next one goes on.
local function test_a_pass_past_its_budget_goes_on_next_time(tmp: string)
  local base = base_of(tmp)
  local own = made(base, "own", 0)
  local old = made(base, "old", 90)
  local report = cache_lifetime.prune(own, nil, 0)
  assert(report.ran and #report.removed == 0 and exists(old .. "/build.db"))
  report = cache_lifetime.prune(own)
  assert(report.removed[1] == old)
end

--- Only a name a pass gives its set-aside directories is finished.
local function test_a_directory_named_otherwise_is_not_swept(tmp: string)
  local base = base_of(tmp)
  local own = made(base, "own", 0)
  local mine = made(base, "mine", 1)
  local stranger = mine .. ".pruning-x"
  assert(Fs.rename(mine, stranger))
  assert(Fs.remove(stranger .. "/used"))
  local report = cache_lifetime.prune(own)
  assert(#report.removed == 0 and exists(stranger .. "/build.db"))
end

--- The view the records of these tests are written in: a sandboxed
--- worker's /proc names no boot.
local VIEW <const> = "a-boot mnt:[1]"

--- The device a record of use names last.
local function record_device(record: string): string?
  return record:match("\n(%d+)$")
end

--- A directory whose record names a checkout that is gone goes at the
--- next pass, however recent its use; one whose checkout is still there,
--- or whose record names a root its name is not the hash of, waits out
--- its thirty days.
local function test_a_directory_of_a_removed_checkout_goes(tmp: string)
  local base = base_of(tmp)
  local own = made(base, "own", 0)
  local root = assert(sys.realpath(tmp)) .. "/checkouts"
  assert(Fs.mkdirs(root .. "/gone"))
  assert(Fs.mkdirs(root .. "/here"))
  local function of(name: string): string
    local path = root .. "/" .. name
    local directory = build_paths.in_home(path, base)
    assert(Fs.mkdirs(directory .. "/bin"))
    assert(Fs.write(directory .. "/build.db", "x"))
    local record = build_paths.record(path, VIEW)
    assert(record ~= "", "no record of " .. path)
    assert(Fs.write(build_paths.under(directory).used, record))
    return directory
  end
  local gone, here, elsewhere, moved, linked = of("gone"), of("here"), of("elsewhere"), of("moved"), of("linked")
  local device = assert(record_device(build_paths.record(root .. "/gone", VIEW)))
  assert(Fs.write(build_paths.under(elsewhere).used, "another-boot mnt:[1]\n" .. root .. "/elsewhere\n" .. device))
  -- Its parent on another device: a volume not mounted now.
  assert(Fs.write(build_paths.under(moved).used, VIEW .. "\n" .. root .. "/moved\n" ..
      tostring(assert(math.tointeger(tonumber(device))) + 1)))
  local forged = made(base, "forged", 1)
  assert(Fs.write(build_paths.under(forged).used, build_paths.record(root .. "/gone", VIEW)))
  -- Set aside by a pass that ended before it removed it.
  local half = of("half")
  local aside = half .. ".pruning-1"
  assert(Fs.rename(half, aside))
  assert(Fs.remove_tree(root .. "/gone"))
  assert(Fs.remove_tree(root .. "/elsewhere"))
  assert(Fs.remove_tree(root .. "/moved"))
  -- A link at the root, though it leads nowhere, is something there.
  assert(Fs.remove_tree(root .. "/linked"))
  assert(sys.symlink(root .. "/nowhere", root .. "/linked"))
  local report = cache_lifetime.prune(own, nil, nil, VIEW)
  assert(#report.troubles == 0, table.concat(report.troubles, "; "))
  table.sort(report.removed)
  local expected = { aside, gone }
  table.sort(expected)
  assert(table.concat(report.removed, ",") == table.concat(expected, ","), table.concat(report.removed, ","))
  assert(exists(here .. "/build.db"), "the directory of a checkout still there went")
  assert(exists(elsewhere .. "/build.db"), "a record written in another view of the file system counted")
  assert(exists(forged .. "/build.db"), "a record naming another directory's root counted")
  assert(exists(moved .. "/build.db"), "a root whose parent is on another device now counted")
  assert(exists(linked .. "/build.db"), "a link at the root counted as nothing there")
end
