#!/usr/bin/env cosmic
--- reads: _cli _make _build _tool _docs _perf _types cosmic cmd embed bin
-- Ratchet over the COSMIC_* environment variable registry (#1003).
--
-- The public/internal split used to be prose in sys/help.md
-- ("everything else is INTERNAL"), and prose drifts: variables were
-- read by code and named in neither list. Now the registry
-- (_cli/env_vars.tl) declares every variable with a role, --help
-- renders the public rows, and this gate holds the two directions: a
-- variable code reads must be declared, and a declared row must be
-- read by something.

local check = require("cosmic.check")
local env_vars = require("_cli.env_vars")
local fs = require("cosmic.fs")

local TREES < const >: {string} = {"_cli", "_make", "_build", "_tool",
  "_docs", "_perf", "_types", "cosmic", "cmd"}

--- Whether a source file participates in the scan. Tests and examples
--- invent fixture variables (COSMIC_TEST_*, COSMIC_ENVD_*) that are
--- not configuration; the registry itself declares names in quotes.
--- @param path string A source path
--- @return boolean
local function is_scanned(path: string): boolean
  if path:find("/testdata/", 1, true) then
    return false
  end
  if path:match("_test%.tl$") or path:match("_example%.tl$") then
    return false
  end
  if path:find("env_vars.tl", 1, true) then
    return false
  end
  return true
end

--- Every COSMIC_* name the tree reads, with one place it does.
--- Quoted occurrences in Teal (the shape of an env.get/os.getenv
--- argument) plus $-references in the shell trust root and the make
--- rules; comments mention names unquoted and stay out.
--- @return {string: string} Variable name -> a path that reads it
local function scan(): {string: string}
  local found: {string: string} = {}
  for _, tree in ipairs(TREES) do
    local files = check.must(fs.find(tree, {glob = "*.tl"}))
    for _, path in ipairs(files) do
      if is_scanned(path) then
        local text = fs.read(path)
        if text then
          for name in text:gmatch("[\"'](COSMIC_[A-Z_]+)[\"']") do
            found[name] = found[name] or path
          end
        end
      end
    end
  end
  for _, path in ipairs({"bin/cosmic", "embed/cosmic.mk"}) do
    local text = fs.read(path)
    if text then
      for name in text:gmatch("%$[{(]?(COSMIC_[A-Z_]+)") do
        found[name] = found[name] or path
      end
    end
  end
  return found
end

local function test_every_read_variable_is_declared()
  local found = scan()
  local declared = env_vars.names()
  local missing: {string} = {}
  for name, where in pairs(found) do
    if not declared[name] then
      missing[#missing + 1] = name .. " (" .. where .. ")"
    end
  end
  table.sort(missing)
  assert(#missing == 0,
    "COSMIC_* variable(s) read by code but missing from " ..
    "_cli/env_vars.tl — declare each with a role:\n  " ..
    table.concat(missing, "\n  "))
end
test_every_read_variable_is_declared()

local function test_every_declared_variable_is_read()
  local found = scan()
  local stale: {string} = {}
  for _, v in ipairs(env_vars.rows) do
    if not found[v.name] then
      stale[#stale + 1] = v.name
    end
  end
  table.sort(stale)
  assert(#stale == 0,
    "registry row(s) nothing reads — delete them from " ..
    "_cli/env_vars.tl:\n  " .. table.concat(stale, "\n  "))
end
test_every_declared_variable_is_read()

print("all env-var registry tests passed")
