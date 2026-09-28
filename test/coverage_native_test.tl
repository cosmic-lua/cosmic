--- The core's own C in coverage. A core built with native coverage --
--- every release core and the sanitized one -- answers every C line a
--- block begins on and puts hits on those lines; any other core answers
--- none, and its hits never name a C file. The case about a fresh
--- process's first window, which starts this program, is in
--- test/coverage_native_tool_test.tl.

local Coverage = require("cosmic.coverage")
local Hash = require("cosmic.hash")

local function is_core_c(path: string): boolean
  return path:match("^core/[%w_]+%.[ch]$") ~= nil
end

local function test_native_lines_are_core_c_files()
  for path, lines in pairs(Coverage.native_lines()) do
    assert(is_core_c(path), "not a core C path: " .. path)
    for line, observable in pairs(lines) do
      assert(line > 0 and observable == true, path .. ": bad line " .. tostring(line))
    end
  end
end

local function test_c_hits_land_on_native_lines()
  -- Hashing runs core/crypto.c inside this test's own window.
  assert(#Hash.sha256("coverage") == 32)
  local observable = Coverage.native_lines()
  local hits = Coverage.snapshot()
  local crypto_hit = false
  for path, lines in pairs(hits) do
    if is_core_c(path) then
      local here = observable[path]
      assert(here ~= nil, path .. " was hit but is not observable")
      for line in pairs(lines) do
        assert(here[line], path .. ":" .. line .. " was hit but is not observable")
      end
      crypto_hit = crypto_hit or path == "core/crypto.c"
    end
  end
  if next(observable) ~= nil then
    assert(crypto_hit, "hashing hit no line of core/crypto.c")
  end
end

--- Each C function's entry is one of its lines, and hashing enters one
--- of core/crypto.c's functions within this test's own window.
local function test_function_entries_are_observable_lines()
  local lines = Coverage.native_lines()
  local entries = Coverage.native_entries()
  for path, here in pairs(entries) do
    for line in pairs(here) do
      assert((lines[path] or {})[line], path .. ":" .. line .. " is not observable")
    end
  end
  if next(lines) == nil then
    assert(next(entries) == nil, "a core without native coverage has no entries")
    return
  end
  assert(#Hash.sha256("entries") == 32)
  local hit = Coverage.snapshot()["core/crypto.c"] or {}
  local entered = false
  for line in pairs(entries["core/crypto.c"] or {}) do
    entered = entered or hit[line] == true
  end
  assert(entered, "hashing entered no function of core/crypto.c")
end
