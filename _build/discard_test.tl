#!/usr/bin/env cosmic
--- reads: cosmic
--- reads: cmd
--- reads: _cli
--- reads: _make
--- reads: _build
--- reads: _docs
--- reads: _perf
--- reads: _types
--- reads: _build/discards.txt
--
-- The discarded-error ratchet (issue #948). The charter says "never
-- silently discard errors", and until now only review enforced it.
-- `_build/discard.tl` finds the two shapes with tl's typed report;
-- this file holds the judgement:
--
-- - the SPILL shape (a fallible call spilling its error return into
--   `print` and friends) is held at ZERO — every site was fixed when
--   the rule landed, and a new one is a bug at write time;
-- - the STATEMENT shape (a bare `fs.write(path, data)` line) is a
--   1400-site debt, ratcheted per file: existing debt is tolerated at
--   its committed level, new debt fails, and paying debt down is
--   rewarded by tightening the floor.
--
-- To rewrite the floor after paying debt down (never up):
--   COSMIC_DISCARD_BASELINE=1 bin/cosmic --make test _build/discard_test.tl
-- then commit _build/discards.txt.

local check = require("cosmic.check")
local discard = require("_build.discard")
local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

local BASELINE < const > = "_build/discards.txt"

--- Directory names the tree walk never descends into: build output,
--- vendored code, fixtures that are deliberately wrong.
local SKIP_DIRS < const >: {string: boolean} = {
  ["o"] = true,
  ["3p"] = true,
  [".git"] = true,
  ["testdata"] = true,
  [".claude"] = true,
}

--- Every first-party .tl source in the tree, sorted. `.d.tl`
--- declarations describe C bindings and carry no calls to judge.
local function tree_files(): {string}
  local acc: {string} = {}
  local _ctx, walk_err = fs.walk(".",
    function(path: string, name: string, st: fs.WalkStat, _c: any): fs.WalkAction
      if st:is_dir() and SKIP_DIRS[name] then
        return "skip"
      end
      if st:is_file() and string.match(name, "%.tl$")
      and not string.match(name, "%.d%.tl$") then
        acc[#acc + 1] = (string.gsub(path, "^%./", ""))
      end
    end)
  assert(walk_err == nil, "tree walk must be complete, got: " .. tostring(walk_err))
  table.sort(acc)
  return acc
end

--- The committed per-file floor: "path count" rows, `#` comments.
local function read_baseline(): {string: integer}
  local map: {string: integer} = {}
  local text = fs.read(BASELINE)
  if text is string then
    for line in string.gmatch(text, "([^\n]*)\n?") do
      if line ~= "" and string.sub(line, 1, 1) ~= "#" then
        local p, n = string.match(line, "^(%S+)%s+(%d+)$")
        if p and n then
          map[p] = math.tointeger(tonumber(n)) or 0
        end
      end
    end
  end
  return map
end

--- Write the floor from measured counts, sorted, with the how-to header.
local function write_baseline(counts: {string: integer})
  local paths: {string} = {}
  for p in pairs(counts) do
    paths[#paths + 1] = p
  end
  table.sort(paths)
  local lines: {string} = {
    "# Discarded-error STATEMENT sites per file (issue #948): calls whose",
    "# declared returns end in the error position, standing as bare",
    "# statements. This floor only moves DOWN: fix sites by capturing the",
    "# error (`local v, err = f(...)`, or `local _ok, _err = f(...)` for",
    "# deliberate fire-and-forget), then regenerate with",
    "#   COSMIC_DISCARD_BASELINE=1 bin/cosmic --make test _build/discard_test.tl",
    "# and commit the result. New sites fail _build/discard_test.tl.",
  }
  for _, p in ipairs(paths) do
    lines[#lines + 1] = p .. " " .. tostring(counts[p])
  end
  check.must(fs.write(BASELINE, table.concat(lines, "\n") .. "\n"))
end

-- One scan, shared by every assertion below: the whole-tree typed pass
-- costs seconds, and running it per test would multiply that.
local files = tree_files()
local result = discard.scan(files, teal.get_default_include_dirs())

local function test_scan_covers_the_tree()
  assert(result.checked > 300,
    "the scan should analyze the whole tree, got " .. tostring(result.checked))
  assert(#result.failed == 0, "every file must be analyzable — a skipped file"
    .. " reads as debt-free:\n  " .. table.concat(result.failed, "\n  "))
end
test_scan_covers_the_tree()

local function test_fallible_reads_signatures()
  assert(discard.fallible("function(string, string, ? integer): (boolean, string)"),
    "boolean, string is the fallible-effect shape")
  assert(discard.fallible("function(string): (string | nil, string)"),
    "T | nil, string is the fallible-value shape")
  assert(not discard.fallible("function(string): string"),
    "a single bare return has no error position")
  assert(not discard.fallible("function(...: <any type>)"),
    "no returns, no error position")
  assert(not discard.fallible("function(string): (integer, integer)"),
    "a non-string final return is not an error position")
end
test_fallible_reads_signatures()

local function test_no_spilled_error_returns()
  local msgs: {string} = {}
  for _, s in ipairs(result.sites) do
    if s.kind == "spill" then
      msgs[#msgs + 1] = s.file .. ":" .. tostring(s.line) .. " spills " .. s.callee
    end
  end
  assert(#msgs == 0, "a fallible call as the last argument of a variadic call"
    .. " passes its error return along (gotcha 8) — capture it first"
    .. " (`local v, err = f(...)`), wrap in check.must, or parenthesize:\n  "
    .. table.concat(msgs, "\n  "))
end
test_no_spilled_error_returns()

local function test_statement_debt_is_ratcheted()
  local counts: {string: integer} = {}
  for _, s in ipairs(result.sites) do
    if s.kind == "statement" then
      counts[s.file] = (counts[s.file] or 0) + 1
    end
  end

  if os.getenv("COSMIC_DISCARD_BASELINE") == "1" then
    write_baseline(counts)
    print("discard: wrote " .. BASELINE)
    return
  end

  local floor = read_baseline()
  local over: {string} = {}
  for file, n in pairs(counts) do
    local allowed = floor[file] or 0
    if n > allowed then
      over[#over + 1] = string.format("%s: %d site(s), floor %d", file, n, allowed)
    end
  end
  table.sort(over)
  assert(#over == 0, "new discarded-error statement(s) — the charter says"
    .. " never silently discard errors: capture the return"
    .. " (`local v, err = f(...)`; `local _ok, _err = f(...)` for deliberate"
    .. " fire-and-forget), or check.must in tests/examples:\n  "
    .. table.concat(over, "\n  "))
end
test_statement_debt_is_ratcheted()
