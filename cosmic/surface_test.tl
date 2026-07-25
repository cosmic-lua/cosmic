#!/usr/bin/env cosmic
--- The public surface, derived from position rather than declared.
---
--- `cosmic.public` used to be a hand-maintained list, and this file used
--- to be its lint: every embedded module had to appear on one of its two
--- lists, and neither list could go stale. Both of those tests are gone
--- because both classes of bug are gone with the manifest — a module is
--- public because of where it sits, so there is nothing to forget and
--- nothing to leave behind.
---
--- What survives is everything the manifest was a means to: the public
--- modules load, they are documented, and a directory module still
--- answers to its own name.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local visibility = require("cosmic.doc.visibility")

local EMBEDDED = "/zip/cosmic"

--- Enumerate top-level module names embedded in the running binary:
--- foo.lua files and directory modules (their init.lua is the module).
--- Returned as dotted names, so the visibility rule applies unchanged.
local function embedded_modules(): {string}
  local d = check.must(fs.opendir(EMBEDDED),
    "cannot open " .. EMBEDDED .. " (test must run in the binary)")
  local found: {string} = {}
  while true do
    local name = d:read()
    if not name then break end
    if name ~= "." and name ~= ".." then
      local lua = name:match("^(.+)%.lua$")
      if lua and lua ~= "init" then
        found[#found + 1] = "cosmic." .. lua
      elseif not lua and fs.isdir(EMBEDDED .. "/" .. name) then
        found[#found + 1] = "cosmic." .. name
      end
    end
  end
  d:close()
  return found
end

local public = visibility.public_of(embedded_modules())

--- The surface is not empty and not everything: a rule that classified
--- every module the same way would pass every test below while saying
--- nothing. `_cli` and `_require` are the internals it must exclude.
local function test_the_rule_actually_partitions()
  assert(#public > 20,
    "expected a substantial public surface, got " .. #public)
  for _, name in ipairs(public) do
    assert(name:match("^cosmic%.[%w]") and not name:match("^cosmic%._"),
      "public_of returned an underscore module: " .. name)
  end
  assert(not visibility.is_public("cosmic._cli"), "_cli is internal")
  assert(not visibility.is_public("cosmic._require"), "_require is internal")
  assert(not visibility.is_public("cosmic._version"),
    "the generated version stamp is internal")
  assert(not visibility.is_public("cosmic.fs.walk"),
    "a shard of a directory module is not itself public")
  assert(visibility.is_public("cosmic.fs"), "…but its entry point is")
end
test_the_rule_actually_partitions()

--- Every public module loads. This is the check the manifest existed
--- for, now asked of the set the tree defines.
local function test_public_modules_load()
  for _, name in ipairs(public) do
    local ok, err = pcall(require, name)
    assert(ok, "public module " .. name .. " failed to load: " .. tostring(err))
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

--- Documented <=> public (issue #556): every public module must have an
--- entry in the embedded docs index. doc/public_test.tl checks the
--- other direction (the listing shows public modules only).
local function test_public_modules_are_documented()
  local docs = require("cosmic.doc")
  local idx = check.must(docs.embedded_index())
  local undocumented: {string} = {}
  for _, name in ipairs(public) do
    if not idx.modules[name] then
      undocumented[#undocumented + 1] = name
    end
  end
  table.sort(undocumented)
  assert(#undocumented == 0,
    "public modules with no docs entry: " .. table.concat(undocumented, ", "))
end
test_public_modules_are_documented()

--- The index generator applies the same rule inline, because it also
--- runs under the pinned bootstrap whose stdlib predates this module.
--- Two copies of one rule is a drift risk, so it is asserted: every
--- module the index carries must agree with visibility.is_public about
--- whether it is internal.
local function test_index_visibility_agrees_with_the_rule()
  local docs = require("cosmic.doc")
  local idx = check.must(docs.embedded_index())
  for name, mod in pairs(idx.modules) do
    if not (name == "cosmo" or name:match("^cosmo%.")) then
      local marked_internal = (mod as {string: any}).internal == true -- cast: from any
      assert(marked_internal ~= visibility.is_public(name),
        "index and visibility.is_public disagree about " .. name)
    end
  end
end
test_index_visibility_agrees_with_the_rule()

print("all surface tests passed")
