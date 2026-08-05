#!/usr/bin/env lua
--- The docs surface must follow the `_` rule:
--- `--docs` lists public modules only, internal modules stay searchable
--- but badged, and their doc pages carry an internal-module header.
---
--- The expected set comes from cosmic.doc.visibility rather than from
--- the index's own `internal` flags, so this checks that the listing's
--- filter agrees with the RULE and not merely with itself.

local check = require("cosmic.check")
local docs = require("cosmic.doc")
local doc_types = require("cosmic.doc.types")
local visibility = require("cosmic.doc.visibility")

-- These tests are about the embedded index; they must run in the built
-- binary, where the index is always present.
local idx = check.must(docs.embedded_index(),
  "docs index must be embedded (run tests via the binary)")

local INTERNAL_SAMPLES = {
  "cosmic.child.io",
  "_cli.args",
  "cosmic.sqlite.bind",
  "cosmic.fs.walk",
  "_perf.harness",
}

local function topic_names(): {string: boolean}
  local names: {string: boolean} = {}
  for _, topic in ipairs(docs.list_topics()) do
    names[topic[1]] = true
  end
  return names
end

local function test_listing_hides_internal_modules()
  local names = topic_names()
  for _, internal_name in ipairs(INTERNAL_SAMPLES) do
    assert(not names[internal_name],
      "--docs listing must not contain internal module: " .. internal_name)
  end
  print("test_listing_hides_internal_modules: PASS")
end
test_listing_hides_internal_modules()

local function test_listing_is_exactly_the_public_surface()
  local names = topic_names()
  local indexed: {string} = {}
  for name in pairs(idx.modules) do
    indexed[#indexed + 1] = name
  end
  local expected = visibility.public_of(indexed)
  local count = 0
  for _ in pairs(names) do count = count + 1 end
  assert(count == #expected, string.format(
      "--docs lists %d modules, the `_` rule says %d are public",
      count, #expected))
  for _, name in ipairs(expected) do
    assert(names[name], "public module missing from --docs listing: " .. name)
  end
  print("test_listing_is_exactly_the_public_surface: PASS")
end
test_listing_is_exactly_the_public_surface()

local function test_directory_modules_indexed_under_their_name()
  assert(idx.modules["cosmic.fs"],
    "directory module must be indexed, not cosmic.fs.init")
  assert(not idx.modules["cosmic.fs.init"],
    "init shard must not appear own module")
  local result = docs.query("fs")
  assert(result.ok, "--docs fs must resolve to the fs module page")
  print("test_directory_modules_indexed_under_their_name: PASS")
end
test_directory_modules_indexed_under_their_name()

local function test_internal_modules_stay_searchable_with_badge()
  local results = docs.search("child.io")
  local found: doc_types.SearchResult = nil
  for _, r in ipairs(results) do
    if r.module_name == "cosmic.child.io" then found = r; break end
  end
  assert(found, "search must still find internal module cosmic.child.io")
  assert(found.internal,
    "search result for an internal module must carry internal = true")
  local rendered = docs.render_search_results(results, "child.io")
  assert(rendered:find("cosmic.child.io", 1, true), "rendered search output")
  assert(rendered:find("(internal)", 1, true),
    "search results must badge internal modules with (internal)")
  print("test_internal_modules_stay_searchable_with_badge: PASS")
end
test_internal_modules_stay_searchable_with_badge()

local function test_internal_doc_page_carries_header()
  local result = docs.query("cosmic.child.io")
  assert(result.ok, "--docs cosmic.child.io must still render a page")
  assert(result.output:find("internal module — not API, may change without notice", 1, true),
    "internal module page must carry the internal-module header")
  local public_page = docs.query("cosmic.json")
  assert(public_page.ok, "--docs cosmic.json must render")
  assert(not public_page.output:find("internal module — not API", 1, true),
    "public module page must not carry the internal-module header")
  print("test_internal_doc_page_carries_header: PASS")
end
test_internal_doc_page_carries_header()
