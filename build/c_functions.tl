--- Every C function of the core that a test must enter: each one
--- `Coverage.native_functions` names in a `core/*.c` file. Every core
--- cosmic ships and tests with observes its own C, so a whole test run of
--- cosmic's own tree -- locally, on the release core, and in CI, on the
--- sanitized one too -- fails for any function no test enters, in its own
--- process or in one it starts (see `Coverage.children`), unless `exempt`
--- names it with the reason no test can.
---
--- A header's `static inline` helper is left out: every file that uses it
--- compiles its own copy and inlines it where it is small, so whether one
--- remaining copy's first line runs says nothing about the tests.

local Coverage = require("cosmic.coverage")

local record c_functions
  --- The C functions no test can enter, by `key`, and why.
  exempt: {string: string}

  --- How a run's hits measure up against every C function.
  record Tally
    --- The functions no test entered and none exempts, by `key`, sorted.
    unentered: {string}
    --- How many were entered.
    entered: integer
    --- How many are exempt and were not entered.
    exempted: integer
    --- How many functions there are.
    total: integer
  end
end

local read_only <const> = "the store's VFS is read-only: SQLite never writes, syncs, locks or sizes sectors through it"
local before_exec <const> = "runs in a forked child before exec, which reports nothing"
local forwarded <const> = "passes to the base VFS a call SQLite never makes on the store's read-only database"

c_functions.exempt = {
  ["core/vfs.c:file_write"] = read_only,
  ["core/vfs.c:file_truncate"] = read_only,
  ["core/vfs.c:file_sync"] = read_only,
  ["core/vfs.c:file_lock"] = read_only,
  ["core/vfs.c:file_unlock"] = read_only,
  ["core/vfs.c:file_check_reserved"] = read_only,
  ["core/vfs.c:file_sector_size"] = read_only,
  ["core/syscalls.c:report_child_error"] = before_exec,
  ["core/syscalls.c:close_child_descriptors"] = before_exec,
  ["core/syscalls.c:catch_child_cancel"] = "a signal handler in a process the same signal then ends, which reports nothing",
  ["core/store.c:die_unreadable"] = "the store's own database cannot be read, and the process ends",
  ["core/crypto.c:mbedtls_psa_external_get_random"] = "mbedtls asks for randomness only to make keys, which the core never does",
  ["core/vfs.c:vfs_delete"] = forwarded,
  ["core/vfs.c:vfs_access"] = forwarded,
  ["core/vfs.c:vfs_randomness"] = forwarded,
  ["core/vfs.c:vfs_sleep"] = forwarded,
  ["core/vfs.c:vfs_current_time"] = forwarded,
  ["core/vfs.c:vfs_last_error"] = forwarded,
  ["core/strnlen.c:strnlen"] = "a host libc's own strnlen can win the link; bin/zig build boot's strnlen check covers the core's",
}

--- How `function` is named in `exempt` and in a failure.
function c_functions.key(fn: Coverage.Function): string
  return fn.path .. ":" .. fn.name
end

--- Whether `here`, one file's hits, holds a line from `first` up to but
--- not including `stop` (nil for the end of the file).
local function hit_between(here: {integer: boolean}, first: integer, stop: integer | nil): boolean
  for line in pairs(here) do
    if line >= first and (stop == nil or line < stop) then return true end
  end
  return false
end

--- Measures `hits`, a run's hits, against `functions`, every C function
--- of the core. A function was entered when a hit lands anywhere from
--- its first line up to the next function's in the same file: where the
--- compiler inlines a call, the body runs without the function's own
--- first block, so its first line alone would miss it.
function c_functions.tally(functions: {Coverage.Function}, hits: Coverage.Hits): c_functions.Tally
  local starts: {string: {integer}} = {}
  for _, fn in ipairs(functions) do
    local lines = starts[fn.path]
    if lines == nil then
      lines = {}
      starts[fn.path] = lines
    end
    lines[#lines + 1] = fn.line
  end
  for _, lines in pairs(starts) do table.sort(lines) end
  local entered: {string: boolean} = {}
  for _, fn in ipairs(functions) do
    if fn.path:match("%.c$") ~= nil then
      local key = c_functions.key(fn)
      local here = hits[fn.path]
      local stop: integer | nil = nil
      for _, line in ipairs(starts[fn.path]) do
        if line > fn.line then
          stop = line
          break
        end
      end
      entered[key] = entered[key] == true or
        (here ~= nil and hit_between(here, fn.line, stop))
    end
  end
  local keys: {string} = {}
  for key in pairs(entered) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  local tally: c_functions.Tally = { unentered = {}, entered = 0, exempted = 0, total = #keys }
  for _, key in ipairs(keys) do
    if entered[key] then
      tally.entered = tally.entered + 1
    elseif c_functions.exempt[key] ~= nil then
      tally.exempted = tally.exempted + 1
    else
      tally.unentered[#tally.unentered + 1] = key
    end
  end
  return tally
end

return c_functions
