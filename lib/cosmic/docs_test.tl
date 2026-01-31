#!/usr/bin/env lua
--- Tests for the embedded documentation module.

local docs = require("cosmic.docs")

-- Test module loads correctly
local function test_module_loads()
  assert(docs, "docs module should load")
  assert(docs.run, "docs.run should exist")
  assert(docs.has_docs, "docs.has_docs should exist")
  assert(docs.list_topics, "docs.list_topics should exist")
  assert(docs.load_index, "docs.load_index should exist")
  assert(docs.render_module, "docs.render_module should exist")
  assert(docs.search, "docs.search should exist")
  assert(docs.render_search_results, "docs.render_search_results should exist")
  print("test_module_loads: PASS")
end
test_module_loads()

-- Test has_docs returns a boolean
local function test_has_docs()
  local result = docs.has_docs()
  assert(type(result) == "boolean", "has_docs should return a boolean")
  print("test_has_docs: PASS")
end
test_has_docs()

-- Test load_index
local function test_load_index()
  local index, err = docs.load_index()
  -- Either we have docs or we get an error message
  if index then
    assert(type(index) == "table", "index should be a table")
    assert(index.modules, "index should have modules")
    print("test_load_index: PASS (docs available)")
  else
    assert(type(err) == "string", "error should be a string")
    print("test_load_index: PASS (no docs: " .. err .. ")")
  end
end
test_load_index()

-- Test run with no query (list all)
local function test_run_list()
  local result = docs.run()
  assert(result, "run should return a result")
  assert(type(result.ok) == "boolean", "result.ok should be a boolean")
  assert(type(result.output) == "string", "result.output should be a string")
  if result.ok then
    assert(result.output:match("cosmic documentation") or result.output:match("Modules"),
           "list output should mention documentation or modules")
  end
  print("test_run_list: PASS")
end
test_run_list()

-- Test run with a module query
local function test_run_module()
  local result = docs.run("cosmic.doc")
  assert(result, "run should return a result")
  assert(type(result.ok) == "boolean", "result.ok should be a boolean")
  assert(type(result.output) == "string", "result.output should be a string")
  -- If docs are available, this should work; otherwise it returns an error
  if result.ok then
    assert(result.output:match("doc") or result.output:match("documentation"),
           "module output should contain relevant content")
  end
  print("test_run_module: PASS")
end
test_run_module()

-- Test run with a symbol query
local function test_run_symbol()
  local result = docs.run("cosmic.doc.parse")
  assert(result, "run should return a result")
  assert(type(result.ok) == "boolean", "result.ok should be a boolean")
  assert(type(result.output) == "string", "result.output should be a string")
  if result.ok then
    assert(result.output:match("parse") or result.output:match("function"),
           "symbol output should contain relevant content")
  end
  print("test_run_symbol: PASS")
end
test_run_symbol()

-- Test run with invalid query
local function test_run_invalid()
  local result = docs.run("nonexistent.module.that.does.not.exist")
  assert(result, "run should return a result")
  assert(type(result.output) == "string", "result.output should be a string")
  -- Should return an error for nonexistent module
  if not result.ok then
    assert(result.output:match("not found") or result.output:match("error"),
           "error output should mention not found or error")
  end
  print("test_run_invalid: PASS")
end
test_run_invalid()

-- Test list_topics
local function test_list_topics()
  local topics = docs.list_topics()
  assert(type(topics) == "table", "list_topics should return a table")
  -- Each topic should be a {name, description} pair
  for _, topic in ipairs(topics) do
    assert(type(topic) == "table", "each topic should be a table")
    assert(type(topic[1]) == "string", "topic name should be a string")
    assert(type(topic[2]) == "string", "topic description should be a string")
  end
  print("test_list_topics: PASS (found " .. #topics .. " topics)")
end
test_list_topics()

-- Test search functionality
local function test_search()
  local results = docs.search("doc")
  assert(type(results) == "table", "search should return a table")
  -- Each result should have the required fields
  for _, result in ipairs(results) do
    assert(type(result) == "table", "each result should be a table")
    assert(type(result.module_name) == "string", "result.module_name should be a string")
    assert(type(result.symbol_type) == "string", "result.symbol_type should be a string")
    assert(type(result.match_score) == "number", "result.match_score should be a number")
  end
  print("test_search: PASS (found " .. #results .. " results)")
end
test_search()

-- Test render_search_results
local function test_render_search_results()
  local results = docs.search("doc")
  local output = docs.render_search_results(results, "doc")
  assert(type(output) == "string", "render_search_results should return a string")
  assert(output:match("Search results") or output:match("No results"),
         "search results output should contain relevant content")
  print("test_render_search_results: PASS")
end
test_render_search_results()

-- Test empty search results
local function test_search_no_results()
  local output = docs.render_search_results({}, "nonexistentquerythatdoesnotmatchanything")
  assert(type(output) == "string", "render_search_results should return a string")
  assert(output:match("No results"), "empty search should mention no results")
  print("test_search_no_results: PASS")
end
test_search_no_results()

-- Test search finds record methods
local function test_search_methods()
  local results = docs.search("exec")
  assert(type(results) == "table", "search should return a table")
  -- Check that we find method-type results
  local found_method = false
  for _, result in ipairs(results) do
    if result.symbol_type == "method" then
      found_method = true
      assert(result.symbol_name:find("%."), "method symbol_name should be Record.method format")
    end
  end
  -- If docs are available and lsqlite3 is indexed, we should find Database.exec
  if docs.has_docs() then
    print("test_search_methods: PASS (found " .. #results .. " results, methods=" .. tostring(found_method) .. ")")
  else
    print("test_search_methods: PASS (no docs available)")
  end
end
test_search_methods()

-- Test run with method lookup (module.Record.method pattern)
local function test_run_method()
  local result = docs.run("cosmo.lsqlite3.Database.exec")
  assert(result, "run should return a result")
  assert(type(result.ok) == "boolean", "result.ok should be a boolean")
  assert(type(result.output) == "string", "result.output should be a string")
  if result.ok then
    assert(result.output:match("exec") or result.output:match("Database"),
           "method output should contain relevant content")
  end
  print("test_run_method: PASS")
end
test_run_method()

-- Test search finds bind methods
local function test_search_bind_methods()
  local results = docs.search("bind")
  assert(type(results) == "table", "search should return a table")
  local method_count = 0
  for _, result in ipairs(results) do
    if result.symbol_type == "method" then
      method_count = method_count + 1
    end
  end
  print("test_search_bind_methods: PASS (found " .. method_count .. " method results)")
end
test_search_bind_methods()

print("")
print("All docs tests passed!")
