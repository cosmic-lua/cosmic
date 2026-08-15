--- Startup of an embed.write()-produced executable.
---
--- embed.write() bundles a user app into a copy of the cosmic binary; the
--- produced executable boots into the embedded main.lua, which loads the
--- app's other embedded .lua modules. Whatever compression those modules
--- carry is paid back as inflate() calls on every launch of the app — the
--- same per-boot cost cosmic's own payload avoids paying, but for the
--- executables embed produces. This scenario builds one such executable
--- once (the ~megabyte base-binary copy is fixed overhead we keep out of
--- the timed op) and measures its cold start.

local child = require("cosmic.child")
local embed = require("cosmic.embed")
local fs = require("cosmic.fs")
local pt = require("_perf.perf_types")

-- A code-heavy app: MODULES modules the entry point loads at boot, each
-- padded to a few KB of real Lua so the store-vs-deflate difference is a
-- measurable amount of inflate() work rather than rounding noise.
local MODULES = 10
local SENTINEL = "EMBED_STARTUP"

local tmpdir: string
local packed_exe: string
local expected_sum: integer

--- Base directory for scratch files.
--- @return string An existing writable directory
local function tmp_base(): string
  return os.getenv("TEST_TMPDIR") or os.getenv("TMPDIR") or "/tmp"
end

--- Locate the cosmic binary to benchmark.
--- PERF_BIN wins; then TEST_BIN/cosmic (set by the test harness); then
--- the interpreter running this script (arg[-1], per cosmic.child docs).
--- @return string Path to the binary, or nil if none was found
local function find_bin(): string
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
  return rawget(arg, -1) as string -- cast: from any
end

--- Source text for module i: returns the integer i after defining a padded
--- block of trivial Lua, so each embedded module carries a few KB of
--- compressible source (deflate has something to inflate at boot).
--- @param i integer Module index
--- @return string Lua source
local function module_src(i: integer): string
  local parts: {string} = {}
  parts[#parts + 1] = "local t = {}"
  for k = 1, 40 do
    parts[#parts + 1] = string.format(
      "t[%d] = function() return %d * %d + %d end", k, i, k, k)
  end
  parts[#parts + 1] = "return " .. tostring(i)
  return table.concat(parts, "\n") .. "\n"
end

--- Write the app tree (main.lua + MODULES modules) under dir.
--- main.lua loadfile()s each embedded module from /zip and prints the sum,
--- so every module is genuinely loaded (and inflated, if deflated) at boot.
--- @param dir string Application source directory
--- @return string Error message, or nil on success
local function init_app(dir: string): string
  expected_sum = 0
  for i = 1, MODULES do
    expected_sum = expected_sum + i
    local wok, werr = fs.write(fs.join(dir, "mod_" .. i .. ".lua"), module_src(i))
    if not wok then
      return "barf mod_" .. i .. ": " .. tostring(werr)
    end
  end
  local main: {string} = {"local sum = 0"}
  for i = 1, MODULES do
    main[#main + 1] = string.format(
      'sum = sum + assert(loadfile("/zip/mod_%d.lua"))()', i)
  end
  main[#main + 1] = 'print("' .. SENTINEL .. ':" .. sum)'
  local mok, merr = fs.write(fs.join(dir, "main.lua"), table.concat(main, "\n") .. "\n")
  if not mok then
    return "barf main.lua: " .. tostring(merr)
  end
  return nil
end

--- Spawn the binary and return trimmed stdout.
--- Raises on spawn failure or nonzero exit, which the harness reports.
--- @param bin string Binary path
--- @return string Trimmed stdout
local function spawn_capture(bin: string): string
  local r, rerr = child.run({bin})
  assert(r ~= nil, tostring(rerr))
  assert(r.ok, "exit code " .. tostring(r.code) .. ": " .. tostring(r.stdout))
  return (r.stdout:gsub("%s+$", ""))
end

local function scenarios(): {pt.Scenario}, string
  local bin = find_bin()
  if bin == nil or #bin == 0 then
    return nil, "cannot locate cosmic binary (set PERF_BIN)"
  end
  local dir, derr = fs.temp_dir(fs.join(tmp_base(), "perf-embed-startup-XXXXXX"))
  if dir == nil then
    return nil, "mkdtemp: " .. tostring(derr)
  end
  tmpdir = dir
  local appdir = fs.join(tmpdir, "app")
  local mok, merr = fs.make_dirs(appdir)
  if not mok then
    return nil, "makedirs: " .. tostring(merr)
  end
  local aerr = init_app(appdir)
  if aerr then
    return nil, aerr
  end

  -- Build the embedded executable once: the per-op cost is its startup,
  -- not the (fixed, megabyte-scale) embed operation.
  packed_exe = fs.join(tmpdir, "packed")
  local count, werr = embed.write({appdir}, {output = packed_exe, exe_path = bin})
  if not count then
    return nil, "embed.write: " .. tostring(werr)
  end

  local want = SENTINEL .. ":" .. tostring(expected_sum)
  return {
    {
      -- Cold start of the produced executable: APE load, zip fs, Lua boot,
      -- then loadfile() of every embedded module (the inflate() path that
      -- storing boot .lua eliminates).
      name = "embed_run_startup",
      fn = function(_: any): any
        return spawn_capture(packed_exe)
      end,
      check = function(_: any, res2: any): boolean, string
        if res2 as string ~= want then -- cast: from any
          return false, "wrong output: " .. tostring(res2) .. " want " .. want
        end
        return true
      end,
    },
  }
end

local function cleanup()
  if tmpdir then
    local _ok, _err = fs.remove_all(tmpdir)
    tmpdir = nil
  end
end

local M: pt.BenchModule = {
  scenarios = scenarios,
  cleanup = cleanup,
}

return M
