#!/usr/bin/env cosmic
--- reads: _cli _make _build _tool _docs _perf _types cosmic cmd embed bin docs/guides/make.md
-- Ratchet over the COSMIC_* environment variable registry.
--
-- Prose drifts: a variable can be read by code and named in neither
-- list. The registry (_cli/env_vars.tl) declares every variable with
-- a role, --help renders the public rows, and this gate holds the
-- two directions: a variable code reads must be declared, and a
-- declared row must be read by something.

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
--- @param trees {string} Trees to scan; defaults to every tracked tree
--- @return {string: string} Variable name -> a path that reads it
local function scan(trees?: {string}): {string: string}
  local found: {string: string} = {}
  for _, tree in ipairs(trees or TREES) do
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

--- The `COSMIC_*` names named in backtick spans on table rows of the
--- guide's "Environment variables" section (`## Environment variables`
--- up to the next `## ` heading, or end of file). A table row is a line
--- starting with `` | ` ``; the header and separator rows don't match.
--- @return {string: boolean} Names the guide's public table documents
local function guide_table_names(): {string: boolean}
  local content = check.must(fs.read("docs/guides/make.md"))
  local names: {string: boolean} = {}
  local in_section = false
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^## Environment variables") then
      in_section = true
    elseif in_section and line:match("^## ") then
      break
    elseif in_section and line:match("^| `") then
      for name in line:gmatch("`(COSMIC_[A-Z_]+)`") do
        names[name] = true
      end
    end
  end
  return names
end

local function test_the_guide_table_matches_the_builds_public_reads()
  local guide_names = guide_table_names()
  local public: {string: boolean} = {}
  for _, v in ipairs(env_vars.rows) do
    if v.public then
      public[v.name] = true
    end
  end

  local not_public: {string} = {}
  for name in pairs(guide_names) do
    if not public[name] then
      not_public[#not_public + 1] = name
    end
  end
  table.sort(not_public)
  assert(#not_public == 0,
    "docs/guides/make.md's Environment variables table names " ..
    "variable(s) not declared public in _cli/env_vars.tl:\n  " ..
    table.concat(not_public, "\n  "))

  local build_reads = scan({"_make", "_cli/build"})
  local undocumented: {string} = {}
  for _, v in ipairs(env_vars.rows) do
    if v.public and build_reads[v.name] and not guide_names[v.name] then
      undocumented[#undocumented + 1] = v.name
    end
  end
  table.sort(undocumented)
  assert(#undocumented == 0,
    "public variable(s) the build reads but docs/guides/make.md's " ..
    "Environment variables table omits:\n  " ..
    table.concat(undocumented, "\n  "))
end

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

print("all env-var registry tests passed")
