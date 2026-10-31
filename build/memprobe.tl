--- An opt-in probe of how much memory a long run holds, for finding what a tree-wide run keeps alive between its phases.
---
--- With `COSMIC_MEMPROBE` set (to anything), [`Memprobe.mark`] writes a line to standard error: the label, the seconds since
--- the probe started, the resident set and its peak since the last mark, and the Lua heap before and after a full
--- collection. The collection makes the heap the live data and not the garbage of the phase just ended, and the peak is
--- reset so that each line says what its phase alone reached. Without the variable a mark does nothing.
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")

local record Memprobe
  --- Whether marks are written: set by `COSMIC_MEMPROBE`.
  enabled: boolean
  --- Where a line goes: standard error.
  sink: function(line: string)
  --- Writes the line for `label` when the probe is enabled, and answers it (nil when it is not).
  mark: function(label: string): string?
end

--- The size in kilobytes of the field `name` ("VmRSS", "VmHWM") of /proc/self/status, 0 where the host has none.
local function kilobytes(status: string, name: string): integer
  local digits = status:match(name .. ":%s+(%d+) kB")
  if digits == nil then
    return 0
  end
  return math.tointeger(tonumber(digits)) or 0
end

--- Starts the peak over, as the kernel allows: writing 5 to clear_refs resets the high-water mark of the resident set.
local function restart_peak()
  local fd, _ = Fs.open_write("/proc/self/clear_refs")
  if fd ~= nil then
    local _, _ = Fs.put(fd, "5")
    local _, _ = Fs.close(fd)
  end
end

local started <const> = Clock.monotonic_ns()

Memprobe.enabled = Env.read("COSMIC_MEMPROBE") ~= nil

Memprobe.sink = function(line: string)
  local _, _ = Fs.put(Fs.stderr, line .. "\n")
end

function Memprobe.mark(label: string): string?
  if not Memprobe.enabled then
    return nil
  end
  local status, _ = Fs.read("/proc/self/status")
  local resident, peak = 0, 0
  if status ~= nil then
    resident, peak = kilobytes(status, "VmRSS"), kilobytes(status, "VmHWM")
  end
  local heap = collectgarbage("count")
  collectgarbage("collect")
  local live = collectgarbage("count")
  local line = string.format("MEM %-44s %7.1fs rss=%6.0fMB peak=%6.0fMB heap=%6.0fMB live=%6.0fMB", label,
    (Clock.monotonic_ns() - started) / 1e9, resident / 1024, peak / 1024, heap / 1024, live / 1024)
  restart_peak()
  Memprobe.sink(line)
  return line
end

return Memprobe
