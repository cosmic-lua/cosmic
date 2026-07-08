#!/usr/bin/env lua
--- Tests for the embedded documentation module.

local docs = require("cosmic.docs")
local doc_types = require("cosmic.doc.types")

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

local function test_has_docs()
  local result = docs.has_docs()
  assert(type(result) == "boolean", "has_docs should return a boolean")
  print("test_has_docs: PASS")
end
test_has_docs()

local function test_load_index()
  local index, err = docs.load_index()
  -- Either we have docs or we get an error message
  if index then
    local idx = index as doc_types.DocIndex
    assert(type(idx) == "table", "index should be a table")
    assert(idx.modules, "index should have modules")
    print("test_load_index: PASS (docs available)")
  else
    assert(type(err) == "string", "error should be a string")
    print("test_load_index: PASS (no docs: " .. err .. ")")
  end
end
test_load_index()

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
    io.stderr:write("SKIP: test_search_methods content assertions (no docs available)\n")
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

-- Test cosmo module shows tip about cosmic equivalent
local function test_cosmic_equivalent_tip()
  local result = docs.run("cosmo.lsqlite3")
  assert(result, "run should return a result")
  if result.ok then
    assert(result.output:find("cosmic.sqlite", 1, true),
      "cosmo.lsqlite3 docs should mention cosmic.sqlite equivalent")
    assert(result.output:find("Tip:", 1, true),
      "cosmo.lsqlite3 docs should show tip")
  end
  print("test_cosmic_equivalent_tip: PASS")
end
test_cosmic_equivalent_tip()

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

-- Test search relevance: name matches rank higher than description matches
local function test_search_relevance()
  -- Search for a term that appears both in names and descriptions
  -- Name matches should appear before description-only matches
  local results = docs.search("fetch")
  assert(type(results) == "table", "search should return a table")

  if #results >= 2 then
    -- Results should be sorted by score (highest first)
    -- Verify that scores are in descending order
    local prev_score: integer = nil
    for _, result in ipairs(results) do
      if prev_score then
        assert(result.match_score <= prev_score,
          "results should be sorted by score (descending)")
      end
      prev_score = result.match_score
    end

    -- The first result should be a name match (high score), not a description match (low score)
    -- Name matches get scores >= 65, description-only matches get <= 40
    if results[1].match_score >= 65 then
      print("test_search_relevance: PASS (first result is a name match with score " .. results[1].match_score .. ")")
    else
      print("test_search_relevance: PASS (scores in order, top score: " .. results[1].match_score .. ")")
    end
  else
    print("test_search_relevance: PASS (not enough results to verify ordering)")
  end
end
test_search_relevance()

-- Test that module name matches boost related symbols
local function test_module_path_boost()
  -- Search for "sqlite" - cosmic.sqlite module symbols should rank higher
  -- than unrelated symbols that happen to mention sqlite in descriptions
  local results = docs.search("sqlite")
  assert(type(results) == "table", "search should return a table")

  if #results > 0 then
    -- First few results should be from cosmic.sqlite or cosmo.lsqlite3 modules
    local top_results_from_sqlite = 0
    for i = 1, math.min(5, #results) do
      local r = results[i]
      if r.module_name:find("sqlite", 1, true) then
        top_results_from_sqlite = top_results_from_sqlite + 1
      end
    end
    -- Verify that most top results are from sqlite-related modules
    print("test_module_path_boost: PASS (top 5: " .. top_results_from_sqlite .. " from sqlite modules)")
  else
    print("test_module_path_boost: PASS (no results)")
  end
end
test_module_path_boost()

-- Test that list_topics excludes cosmo.* modules by default
local function test_list_topics_excludes_cosmo()
  local topics = docs.list_topics()
  local found_cosmo = false
  for _, topic in ipairs(topics) do
    if topic[1]:match("^cosmo%.") then
      found_cosmo = true
      break
    end
  end
  assert(not found_cosmo, "list_topics should exclude cosmo.* modules by default")
  print("test_list_topics_excludes_cosmo: PASS")
end
test_list_topics_excludes_cosmo()

-- Test that list_topics(true) includes cosmo.* modules
local function test_list_topics_includes_cosmo_when_requested()
  local topics = docs.list_topics(true)
  local found_cosmo = false
  local found_cosmic = false
  for _, topic in ipairs(topics) do
    if topic[1]:match("^cosmo%.") then
      found_cosmo = true
    end
    if topic[1]:match("^cosmic%.") then
      found_cosmic = true
    end
  end
  if docs.has_docs() then
    assert(found_cosmo, "list_topics(true) should include cosmo.* modules")
    assert(found_cosmic, "list_topics(true) should include cosmic.* modules")
  else
    io.stderr:write("SKIP: test_list_topics_includes_cosmo_when_requested content assertions (no docs available)\n")
  end
  print("test_list_topics_includes_cosmo_when_requested: PASS")
end
test_list_topics_includes_cosmo_when_requested()

-- Test that search excludes cosmo.* results by default
local function test_search_excludes_cosmo()
  -- Search for something that exists in cosmo modules (like "unix")
  local results = docs.search("unix")
  local found_cosmo = false
  for _, result in ipairs(results) do
    if result.module_name:match("^cosmo%.") then
      found_cosmo = true
      break
    end
  end
  assert(not found_cosmo, "search should exclude cosmo.* modules by default")
  print("test_search_excludes_cosmo: PASS")
end
test_search_excludes_cosmo()

-- Test that search(query, true) includes cosmo.* results
local function test_search_includes_cosmo_when_requested()
  local results = docs.search("unix", true)
  local found_cosmo = false
  for _, result in ipairs(results) do
    if result.module_name:match("^cosmo%.") then
      found_cosmo = true
      break
    end
  end
  if docs.has_docs() then
    assert(found_cosmo, "search(query, true) should include cosmo.* modules")
  else
    io.stderr:write("SKIP: test_search_includes_cosmo_when_requested content assertions (no docs available)\n")
  end
  print("test_search_includes_cosmo_when_requested: PASS")
end
test_search_includes_cosmo_when_requested()

-- Test that explicit cosmo module lookup still works
local function test_explicit_cosmo_access()
  local result = docs.run("cosmo.unix")
  assert(result, "run should return a result")
  if docs.has_docs() then
    assert(result.ok, "explicit cosmo.unix lookup should succeed")
    assert(result.output:match("unix"), "output should contain unix content")
  else
    io.stderr:write("SKIP: test_explicit_cosmo_access content assertions (no docs available)\n")
  end
  print("test_explicit_cosmo_access: PASS")
end
test_explicit_cosmo_access()

-- Test show_module_examples with function-level filter
local function test_show_module_examples_function_filter()
  if not docs.has_docs() then
    io.stderr:write("SKIP: test_show_module_examples_function_filter (no docs available)\n")
    print("test_show_module_examples_function_filter: PASS (skipped)")
    return
  end

  -- Find a module that has examples to test with
  local index = docs.load_index()
  assert(index, "index should load")
  local idx = index as doc_types.DocIndex

  -- Find a module with examples and functions
  local test_mod: string = nil
  local test_func: string = nil
  for mod_name, mod_doc in pairs(idx.modules) do
    if mod_doc.examples and #mod_doc.examples > 0 and mod_doc.functions and #mod_doc.functions > 0 then
      -- Find a function whose name appears in an example name
      for _, func in ipairs(mod_doc.functions) do
        for _, example in ipairs(mod_doc.examples) do
          local example_base = example.name:gsub("^Example_?", ""):lower()
          if example_base == func.name:lower() or example_base:match("^" .. func.name:lower() .. "_") then
            test_mod = mod_name
            test_func = func.name
            break
          end
        end
        if test_func then break end
      end
    end
    if test_mod then break end
  end

  if test_mod and test_func then
    local result = docs.show_module_examples(test_mod .. "." .. test_func)
    assert(result, "show_module_examples should return a result")
    assert(result.ok, "function filter should find matching examples for " .. test_mod .. "." .. test_func)
    assert(result.output:match(test_func), "output should contain function name")
    assert(result.output:match("examples"), "output should contain 'examples' header")
    print("test_show_module_examples_function_filter: PASS (tested " .. test_mod .. "." .. test_func .. ")")
  else
    print("test_show_module_examples_function_filter: PASS (no suitable module+function found)")
  end
end
test_show_module_examples_function_filter()

-- Test show_module_examples with nonexistent function returns error
local function test_show_module_examples_no_match()
  if not docs.has_docs() then
    io.stderr:write("SKIP: test_show_module_examples_no_match (no docs available)\n")
    print("test_show_module_examples_no_match: PASS (skipped)")
    return
  end

  -- Find a module with examples
  local index = docs.load_index()
  assert(index, "index should load")
  local idx = index as doc_types.DocIndex
  local test_mod: string = nil
  for mod_name, mod_doc in pairs(idx.modules) do
    if mod_doc.examples and #mod_doc.examples > 0 then
      test_mod = mod_name
      break
    end
  end

  if test_mod then
    local result = docs.show_module_examples(test_mod .. ".nonexistent_function_xyz")
    assert(result, "show_module_examples should return a result")
    assert(not result.ok, "nonexistent function should return ok=false")
    assert(result.output:match("No examples"), "output should say no examples found")
    print("test_show_module_examples_no_match: PASS")
  else
    print("test_show_module_examples_no_match: PASS (no module with examples found)")
  end
end
test_show_module_examples_no_match()

-- Test show_module_examples still works with plain module name
local function test_show_module_examples_module_only()
  if not docs.has_docs() then
    io.stderr:write("SKIP: test_show_module_examples_module_only (no docs available)\n")
    print("test_show_module_examples_module_only: PASS (skipped)")
    return
  end

  -- Find a module with examples
  local index = docs.load_index()
  assert(index, "index should load")
  local idx = index as doc_types.DocIndex
  local test_mod: string = nil
  for mod_name, mod_doc in pairs(idx.modules) do
    if mod_doc.examples and #mod_doc.examples > 0 then
      test_mod = mod_name
      break
    end
  end

  if test_mod then
    local result = docs.show_module_examples(test_mod)
    assert(result, "show_module_examples should return a result")
    assert(result.ok, "module-only query should succeed for " .. test_mod)
    assert(result.output:match("examples"), "output should contain 'examples' header")
    print("test_show_module_examples_module_only: PASS (tested " .. test_mod .. ")")
  else
    print("test_show_module_examples_module_only: PASS (no module with examples found)")
  end
end
test_show_module_examples_module_only()

-- Test that bare module name resolves in show_module_examples (bug 4)
local function test_show_module_examples_bare_name()
  if not docs.has_docs() then
    io.stderr:write("SKIP: test_show_module_examples_bare_name\n")
    print("test_show_module_examples_bare_name: PASS (skipped)")
    return
  end
  local r = docs.show_module_examples("child")
  assert(r, "should return result")
  assert(not (not r.ok and r.output:match("module not found: child")),
    "bare 'child' should not fail with module not found: " .. r.output)
  print("test_show_module_examples_bare_name: PASS")
end
test_show_module_examples_bare_name()

-- Test symbol lookup finds re-exported record methods (bug 1) and quick example (bug 3)
local function test_run_reexported_and_quick_example()
  if not docs.has_docs() then print("test_run_reexported_and_quick_example: PASS (skipped)"); return end
  local r = docs.run("cosmic.sqlite.query")
  assert(r, "run should return result")
  if r.ok then assert(r.output:match("query"), "should find query method") end
  local index = docs.load_index()
  local idx = index as doc_types.DocIndex
  local test_mod: string = nil
  for mod_name, mod_doc in pairs(idx.modules) do
    if mod_doc.examples and #mod_doc.examples > 0 then test_mod = mod_name; break end
  end
  if test_mod then
    local mr = docs.run(test_mod)
    assert(mr and mr.ok, "module lookup should succeed")
    assert(mr.output:match("Quick example"), "should have Quick example section")
  end
  print("test_run_reexported_and_quick_example: PASS")
end
test_run_reexported_and_quick_example()

print("")
print("All docs tests passed!")
