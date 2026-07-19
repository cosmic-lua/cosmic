#!/usr/bin/env cosmic
--- The PUBLIC manifest lint: every requireable top-level cosmic.* module
--- embedded in the binary must be declared in cosmic.public as either
--- public or internal, and the manifest must not go stale.
local check = require("cosmic.check")
local manifest = require("cosmic.public")
local fs = require("cosmic.fs")

local EMBEDDED = "/zip/.lua/cosmic"

local function to_set(list: {string}): {string: boolean}
  local set: {string: boolean} = {}
  for _, name in ipairs(list) do
    assert(not set[name], "duplicate manifest entry: " .. name)
    set[name] = true
  end
  return set
end

local public_set = to_set(manifest.public)
local internal_set = to_set(manifest.internal)

local function test_no_overlap()
  for _, name in ipairs(manifest.public) do
    assert(not internal_set[name],
      "module in both public and internal: " .. name)
  end
end
test_no_overlap()

--- Enumerate top-level module names embedded in the running binary:
--- foo.lua files and directory modules (their init.lua is the module).
local function embedded_modules(): {string: boolean}
  local d = check.must(fs.opendir(EMBEDDED),
    "cannot open " .. EMBEDDED .. " (test must run in the binary)")
  local found: {string: boolean} = {}
  while true do
    local name = d:read()
    if not name then break end
    if name ~= "." and name ~= ".." then
      local lua = name:match("^(.+)%.lua$")
      if lua then
        found[lua] = true
      elseif fs.isdir(EMBEDDED .. "/" .. name) then
        found[name] = true
      end
    end
  end
  d:close()
  return found
end

local function test_every_module_is_declared()
  local found = embedded_modules()
  local missing: {string} = {}
  for name in pairs(found) do
    if name ~= "init" and not public_set[name] and not internal_set[name] then
      missing[#missing + 1] = name
    end
  end
  table.sort(missing)
  assert(#missing == 0,
    "modules missing from the cosmic.public manifest: "
    .. table.concat(missing, ", "))
end
test_every_module_is_declared()

local function test_manifest_is_not_stale()
  local found = embedded_modules()
  local stale: {string} = {}
  for _, name in ipairs(manifest.public) do
    if not found[name] then stale[#stale + 1] = name end
  end
  for _, name in ipairs(manifest.internal) do
    if not found[name] then stale[#stale + 1] = name end
  end
  table.sort(stale)
  assert(#stale == 0,
    "manifest entries with no embedded module: " .. table.concat(stale, ", "))
end
test_manifest_is_not_stale()

local function test_public_modules_load()
  for _, name in ipairs(manifest.public) do
    local ok, err = pcall(require, "cosmic." .. name)
    assert(ok, "public module cosmic." .. name .. " failed to load: "
      .. tostring(err))
  end
end
test_public_modules_load()

--- Require-compat per converted family (issue #557): the public entry
--- point of each directory module still loads under its old top-level
--- name and exposes its documented surface.
local function test_directory_module_entry_points()
  local surface: {string: string} = {
    sqlite = "open",
    doc = "parse_file",
    fetch = "fetch",
    net = "socket",
    child = "spawn",
    format = "format",
    fs = "read",
  }
  for name, fn in pairs(surface) do
    local mod = require("cosmic." .. name) as {string: any} -- cast: from any
    assert(type(mod[fn]) == "function",
      "cosmic." .. name .. " must expose " .. fn .. "()")
  end
  -- doc carries both halves of the converged family (#557): extraction
  -- (parse_file, checked above) and the embedded-index query surface.
  local doc = require("cosmic.doc") as {string: any} -- cast: from any
  assert(type(doc["run"]) == "function", "cosmic.doc must expose run()")
  assert(type(doc["search"]) == "function", "cosmic.doc must expose search()")
end
test_directory_module_entry_points()

--- Documented ⇔ public (issue #556): every public module must have an
--- entry in the embedded docs index. doc/public_test.tl checks the
--- other direction (the listing shows public modules only).
local function test_public_modules_are_documented()
  local docs = require("cosmic.doc")
  local idx = check.must(docs.embedded_index())
  local undocumented: {string} = {}
  for _, name in ipairs(manifest.public) do
    if not idx.modules["cosmic." .. name] then
      undocumented[#undocumented + 1] = name
    end
  end
  table.sort(undocumented)
  assert(#undocumented == 0,
    "public modules with no docs entry: " .. table.concat(undocumented, ", "))
end
test_public_modules_are_documented()
