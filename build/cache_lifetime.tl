--- How long the build directories under `$XDG_CACHE_HOME/cosmic/trees`
--- (or `COSMIC_BUILD_HOME`) live, and the one place that removes them.
---
--- The rule is the one the shared caches' rows follow
--- ([`build.shared_compiles`], [`build.shared_verdicts`]): what no run
--- has used in thirty days goes. A build directory's use is the
--- modification time of its `used` file ([`build.paths`]' [`Layout.used`]),
--- which [`build.paths`]' `prepare` sets for every run that builds,
--- tests or opens the working database there. Each worktree, and each
--- project a test builds outside a sandbox's scratch directory, keeps a
--- directory that outlives the tree it was made for; nothing in it but
--- the tree's own projection, tool and stores, all made again by a build.
---
--- A pass runs in the `cosmic test` that holds its own checkout's
--- rebuild lock, at most once a day per base, and removes a sibling
--- directory only when every one of these holds:
---
--- - its name is a SHA-256 in lower-case hex, and it is a directory (not a
---   link) of this user's, in the base the caller's own directory is in;
--- - its `used` file is a regular file last modified over thirty days
---   ago, read again once the lock is held;
--- - its rebuild lock ([`build.rebuild_lock`]) is taken, so no run is
---   building, testing or writing there, and stays held to the end;
--- - the directory is renamed aside before anything is removed, and put
---   back if a use was recorded in the meantime, so a run that records
---   its use and then takes the lock finds the directory whole or gone,
---   never half removed.
---
--- A directory without a `used` file that holds a build's files is not
--- removed, only dated from now, so one made before the rule began lives
--- thirty days from the first pass that sees it. Nothing else in the
--- base is touched, and a removal never follows a link
--- ([`Fs.remove_tree`]).
---
--- A run that uses a directory without recording it -- a tool left
--- running for thirty days with no other `cosmic` run in the checkout --
--- is not excluded; the directory is removed from under it as a file is
--- from under a process that has it open, and the next build makes it
--- again.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local build_paths = require("build.paths")
local rebuild_lock = require("build.rebuild_lock")

local record cache_lifetime
  --- What a pass did.
  record Report
    --- The build directories it removed.
    removed: {string}
    --- The directories it left because a run held their lock.
    busy: {string}
    --- What it could not do, one line each; a failure keeps what it
    --- touched.
    troubles: {string}
    --- Whether it ran: not when the base was pruned in the day before.
    ran: boolean
  end
end

--- Thirty days, in seconds: the same age the shared caches' rows keep
--- ([`build.shared_compiles`]'s `kept_ns`).
local kept_s <const> = 30 * 24 * 3600

--- How long a pass spares its base after the one before.
local spared_s <const> = 24 * 3600

--- Where a build directory is set aside to be removed: its name and this.
local aside_infix <const> = ".pruning-"

--- The file whose modification time dates the last pass over a base.
local pass_name <const> = ".pruned"

--- Whether `name` is a build directory's: [`build.paths`]' `in_home`
--- names it by a SHA-256 in lower-case hex.
local function named(name: string): boolean
  return #name == 64 and name:find("^[0-9a-f]+$") ~= nil
end

--- What `path` is, without following a link; nil where there is nothing,
--- or nothing that can be looked at.
local function look(path: string): sys.Stat | nil
  local st, _ = sys.lstat(path)
  return st
end

--- How old a record of use is.
local enum Age
  "stale"
  "recent"
  "missing"
  "odd"
end

--- The age of the record of use at `path`: stale when it is a regular
--- file last modified more than `kept_s` before `now`, recent when not,
--- missing where there is none, and odd for anything else (a link, a
--- directory), or what cannot be looked at, or is dated after `now`.
local function age(path: string, now: integer): Age
  local st, _, errno = sys.lstat(path)
  if st == nil then
    if errno == sys.ENOENT then return "missing" end
    return "odd"
  end
  if st.kind ~= "file" or st.mtime > now then return "odd" end
  return now - st.mtime > kept_s and "stale" or "recent"
end

--- Whether `directory` holds anything a build writes, which only a
--- build directory does ([`build.paths`]' `Layout`).
local function built(layout: build_paths.Layout): boolean
  for _, path in ipairs({ layout.lock, layout.projection, layout.working, layout.bin }) do
    if look(path) ~= nil then return true end
  end
  return false
end

--- Removes `path`, a build directory under the held `lock`.
local function remove(path: string, name: string, base: string, now: integer,
                      report: cache_lifetime.Report)
  -- Read again under the lock: a run may have recorded its use since.
  if age(build_paths.under(path).used, now) ~= "stale" then return end
  local aside = base .. "/" .. name .. aside_infix .. tostring(sys.getpid())
  local moved, move_why = Fs.rename(path, aside)
  if not moved then
    report.troubles[#report.troubles + 1] = move_why
    return
  end
  -- A run that recorded its use after the check above, and has not yet
  -- taken the lock, is given its directory back.
  if age(build_paths.under(aside).used, now) ~= "stale" then
    local back, back_why = Fs.rename(aside, path)
    if not back then
      report.troubles[#report.troubles + 1] = back_why
    end
    return
  end
  local gone, gone_why = Fs.remove_tree(aside)
  if not gone then
    report.troubles[#report.troubles + 1] = gone_why
    return
  end
  report.removed[#report.removed + 1] = path
end

--- One entry of the base, a candidate by its name.
local function consider(base: string, name: string, now: integer,
                        report: cache_lifetime.Report)
  local path = base .. "/" .. name
  local st = look(path)
  if st == nil or st.kind ~= "dir" or st.uid ~= sys.getuid() then return end
  local layout = build_paths.under(path)
  local dated = age(layout.used, now)
  if dated == "missing" then
    if built(layout) then
      local _, _ = Fs.write(layout.used, "", 0x180)
    end
    return
  end
  if dated ~= "stale" then return end
  local lock, lock_why = rebuild_lock.claim(path)
  if lock == nil then
    if lock_why == "" then
      report.busy[#report.busy + 1] = path
    else
      report.troubles[#report.troubles + 1] = lock_why
    end
    return
  end
  local _held <close> = lock
  remove(path, name, base, now, report)
end

--- A directory set aside by a pass that ended before it removed it:
--- removed if its record of use is stale or gone (a removal that began
--- takes it first), as the pass would have.
local function sweep(base: string, name: string, now: integer, report: cache_lifetime.Report)
  local path = base .. "/" .. name
  local st = look(path)
  if st == nil or st.kind ~= "dir" or st.uid ~= sys.getuid() then return end
  local dated = age(build_paths.under(path).used, now)
  if dated ~= "stale" and dated ~= "missing" then return end
  local gone, gone_why = Fs.remove_tree(path)
  if gone then
    report.removed[#report.removed + 1] = path
  else
    report.troubles[#report.troubles + 1] = gone_why
  end
end

--- Prunes the build directories beside `own`, the one a run of this
--- checkout holds the lock of ([`rebuild_lock.hold`]), as the rules above
--- say, at `now` (default the present). Never removes `own`.
function cache_lifetime.prune(own: string, now?: integer): cache_lifetime.Report
  local report: cache_lifetime.Report = { removed = {}, busy = {}, troubles = {}, ran = false }
  now = now or (Clock.now_ns() // 1000000000)
  local base = Fs.dirname(own)
  local base_stat = look(base)
  if base_stat == nil or base_stat.kind ~= "dir" or base_stat.uid ~= sys.getuid() then
    return report
  end
  local pass = base .. "/" .. pass_name
  local last = look(pass)
  if last ~= nil and last.kind == "file" and now - last.mtime >= 0 and now - last.mtime < spared_s then
    return report
  end
  local names, list_why = Fs.list(base)
  if names == nil then
    report.troubles[1] = list_why
    return report
  end
  report.ran = true
  local own_name = Fs.basename(own)
  for _, name in ipairs(names) do
    if named(name) and name ~= own_name then
      consider(base, name, now, report)
    elseif named(name:sub(1, 64)) and name:sub(65, 64 + #aside_infix) == aside_infix then
      sweep(base, name, now, report)
    end
  end
  local written, write_why = Fs.write(pass, "", 0x180)
  if not written then report.troubles[#report.troubles + 1] = write_why end
  return report
end

return cache_lifetime
