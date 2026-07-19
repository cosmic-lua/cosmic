--- End-to-end binary scenarios: process startup and Teal compilation.
--- Spawns the cosmic binary itself, so these numbers cover the whole
--- cosmopolitan stack: APE loader, zip filesystem, Lua runtime boot,
--- and (for the compile scenario) the embedded Teal compiler.
---
--- These are the scenarios that move when whilp/cosmopolitan (the cosmos
--- pin) changes. Set PERF_BIN to benchmark a different binary.

local child = require("cosmic.child")
local fs = require("cosmic.fs")
local pt = require("perf.perf_types")

local HELLO = "perf-hello"
local COMPILE_SRC = [[
local record Point
  x: number
  y: number
end
local function dist(p: Point, q: Point): number
  local dx = p.x - q.x
  local dy = p.y - q.y
  return math.sqrt(dx * dx + dy * dy)
end
print(dist({x = 0, y = 0}, {x = 3, y = 4}))
]]

local tmpdir: string

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
    if fs.isfile(p) then
      return p
    end
  end
  return rawget(arg, -1) as string -- cast: from any
end

--- Spawn the binary with the given argv tail and return trimmed stdout.
--- Raises on spawn failure or nonzero exit, which the harness reports.
--- @param bin string Binary path
--- @param argv_tail {string} Arguments after the binary path
--- @return string Trimmed stdout
local function spawn_capture(bin: string, argv_tail: {string}): string
  local argv: {string} = {bin}
  for _, a in ipairs(argv_tail) do
    table.insert(argv, a)
  end
  local result, serr = child.run(argv)
  assert(result, serr)
  local r = result as child.Result -- cast: record union after guard
  assert(r.ok, "exit code " .. tostring(r.code) .. ": " .. tostring(r.stdout))
  return (r.stdout:gsub("%s+$", ""))
end

local function scenarios(): {pt.Scenario}, string
  local bin = find_bin()
  if bin == nil or #bin == 0 then
    return nil, "cannot locate cosmic binary (set PERF_BIN)"
  end
  local dir, derr = fs.mkdtemp(fs.join(tmp_base(), "perf-startup-XXXXXX"))
  if dir == nil then
    return nil, "mkdtemp: " .. tostring(derr)
  end
  tmpdir = dir
  local hello_lua = fs.join(dir, "hello.lua")
  local hello_tl = fs.join(dir, "hello.tl")
  local compile_tl = fs.join(dir, "compile_target.tl")
  local hello_src = "print(\"" .. HELLO .. "\")\n"
  local wok, werr = fs.write(hello_lua, hello_src)
  if not wok then
    return nil, "barf: " .. tostring(werr)
  end
  wok, werr = fs.write(hello_tl, hello_src)
  if not wok then
    return nil, "barf: " .. tostring(werr)
  end
  wok, werr = fs.write(compile_tl, COMPILE_SRC)
  if not wok then
    return nil, "barf: " .. tostring(werr)
  end

  return {
    {
      -- Boot + run a plain Lua script: APE load, zip fs, runtime init.
      name = "startup_run_lua",
      fn = function(_: any): any
        return spawn_capture(bin, {hello_lua})
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= HELLO then -- cast: from any
          return false, "wrong output: " .. tostring(res)
        end
        return true
      end,
    },
    {
      -- Same, but through the Teal loader: adds type check + compile.
      name = "startup_run_teal",
      fn = function(_: any): any
        return spawn_capture(bin, {hello_tl})
      end,
      check = function(_: any, res: any): boolean, string
        if res as string ~= HELLO then -- cast: from any
          return false, "wrong output: " .. tostring(res)
        end
        return true
      end,
    },
    {
      -- Full compile of a small typed module via the embedded compiler.
      name = "startup_compile_teal",
      fn = function(_: any): any
        return spawn_capture(bin, {"--compile", compile_tl})
      end,
      check = function(_: any, res: any): boolean, string
        local out = res as string -- cast: from any
        if out == nil or not out:find("local function dist", 1, true) then
          return false, "compile output missing function"
        end
        if out:find("record", 1, true) then
          return false, "compile output still contains Teal syntax"
        end
        return true
      end,
    },
  }
end

local function cleanup()
  if tmpdir then
    fs.rmrf(tmpdir)
    tmpdir = nil
  end
end

local M: pt.BenchModule = {
  scenarios = scenarios,
  cleanup = cleanup,
}

return M
