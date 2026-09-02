--- Shared helpers for benches that build or run a real cosmic binary
--- artifact: locating which binary to measure, and removing the
--- scratch directory each such bench works under once a run is done.

local fs = require("cosmic.fs")

--- Locate the cosmic binary to benchmark.
--- PERF_BIN wins; then TEST_BIN/cosmic (set by the test harness); then
--- the interpreter running this script (arg[-1], per cosmic.child docs).
--- @return string Path to the binary, or nil if none was found
local function find_bin(): string | nil
  local envbin = os.getenv("PERF_BIN")
  if envbin and #envbin > 0 then
    return envbin
  end
  local test_bin = os.getenv("TEST_BIN")
  if test_bin and #test_bin > 0 then
    local p = fs.join(test_bin, "cosmic")
    if fs.is_file(p) then
      return p
    end
  end
  local last = rawget(arg, -1)
  if last is string then
    return last
  end
  return nil
end

--- Remove a bench's scratch directory, if one was created; a nil tmpdir
--- (never set, or already cleared) is a no-op.
--- @param tmpdir string | nil The directory to remove, or nil if none was set
--- @return string | nil Always nil, so the caller can reset its tmpdir field
local function cleanup(tmpdir: string | nil): string | nil
  if tmpdir then
    local _ok, _err = fs.remove_all(tmpdir)
  end
  return nil
end

local record binary
  find_bin: function(): string | nil
  cleanup: function(string | nil): string | nil
end

local M: binary = {
  find_bin = find_bin,
  cleanup = cleanup,
}

return M
