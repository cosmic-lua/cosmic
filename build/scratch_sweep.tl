--- The one place that removes the scratch directories earlier `cosmic
--- test` runs left in the temporary directory.
---
--- A test's scratch directory ([`build.test_key`]'s `scratch`) goes with
--- its worker, unless the test failed: then it is kept to look at. A run
--- that is stopped leaves the directories of the tests it was running.
--- Nothing removed them later, and a container that ran many suites held
--- 1428 of them (many 166 MB each) when its disk filled.
---
--- A pass runs at the start of each `cosmic test` that holds its
--- checkout's rebuild lock. It removes an entry of the temporary
--- directory only when all of these hold:
---
--- - its name is a scratch directory's: `cosmic-test-`, then the `_`s
---   that pad it, then mkdtemp's six letters and digits;
--- - it is a directory (not a link) of this user's;
--- - it was last modified over a day ago. Its modification time is when
---   its worker made it, not its last use, so this holds only while no
---   worker runs for a day (a test's limit is 30 s by default; a run
---   given a far longer `--timeout`, or a host suspended for a day, can
---   lose a directory it still uses).
---
--- A failed test's directory is so kept for a day, and a later run
--- removes it. A removal never follows a link ([`Fs.remove_tree`]). A
--- pass stops starting removals after five seconds; the next run goes on.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local record scratch_sweep
  --- What a pass did.
  record Report
    --- How many scratch directories it removed.
    mut removed: integer
    --- What it could not do, one line each.
    troubles: mut {string}
  end
  --- How old a scratch directory is before a pass removes it: a day,
  --- in seconds.
  kept_s: integer
end

scratch_sweep.kept_s = 24 * 3600

--- How long a pass goes on starting removals.
local budget_ns <const> = Clock.seconds(5)

--- Whether `name` is a scratch directory's.
function scratch_sweep.named(name: string): boolean
  return name:find("^cosmic%-test%-_*%w%w%w%w%w%w$") ~= nil
end
local named = scratch_sweep.named

--- Removes the scratch directories in `base` (default the temporary
--- directory) that earlier runs left, as the module's doc says, at `now`
--- (default the present, in seconds), starting no removal after `budget`
--- nanoseconds (default five seconds).
function scratch_sweep.prune(base?: string, now?: integer, budget?: integer): scratch_sweep.Report
  local report: scratch_sweep.Report = { removed = 0, troubles = {} }
  local dir = base or Fs.temp_dir()
  now = now or (Clock.now_ns() // 1000000000)
  local names, list_why = Fs.list(dir)
  if names == nil then
    report.troubles[1] = tostring(list_why)
    return report
  end
  local uid = sys.getuid()
  local started_ns = Clock.monotonic_ns()
  for _, name in ipairs(names) do
    if Clock.monotonic_ns() - started_ns >= (budget or budget_ns) then break end
    if named(name) then
      local path = (dir:gsub("/+$", "")) .. "/" .. name
      local st, _ = sys.lstat(path)
      if st ~= nil and st.kind == "dir" and st.uid == uid and now - st.mtime > scratch_sweep.kept_s then
        local gone, why = Fs.remove_tree(path)
        if gone then
          report.removed = report.removed + 1
        else
          local said = path .. ": " .. tostring(why)
          report.troubles[#report.troubles + 1] = said
        end
      end
    end
  end
  return report
end

return scratch_sweep
