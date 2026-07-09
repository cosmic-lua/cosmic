#!/usr/bin/env lua
--- Tests for docs.show_module_examples: module rendering, the
--- module.function filter (deterministic pick + the module/function
--- name-collision fallback from #578), bare names, and no-match errors.
--- Split from query_test.tl to stay under the 500-line cap.

local docs = require("cosmic.doc")
local doc_types = require("cosmic.doc.types")

-- Test show_module_examples with function-level filter
local function test_show_module_examples_function_filter()
  if not docs.has_docs() then
    io.stderr:write("SKIP: test_show_module_examples_function_filter (no docs available)\n")
    print("test_show_module_examples_function_filter: PASS (skipped)")
    return
  end

  -- Find a module that has examples to test with
  local index = docs.embedded_index()
  assert(index, "index should load")
  local idx = index as doc_types.DocIndex

  -- Find a module with examples and functions. Iterate sorted so the pick
  -- is the same on every run — pairs() order varies per process, and a
  -- random pick made this test a coin flip (#578).
  local mod_names: {string} = {}
  for mod_name in pairs(idx.modules) do
    table.insert(mod_names, mod_name)
  end
  table.sort(mod_names)
  local test_mod: string = nil
  local test_func: string = nil
  for _, mod_name in ipairs(mod_names) do
    local mod_doc = idx.modules[mod_name]
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
  local index = docs.embedded_index()
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
  local index = docs.embedded_index()
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

-- Regression for #578: a query that names BOTH a module with no examples
-- (cosmic.quicksand.box.run, from box/run.tl) and a function of the parent
-- module (box's run(), matched by Example_run_return_shape) must fall back
-- to the function-filter reading instead of failing with "No examples".
local function test_show_module_examples_module_function_collision()
  if not docs.has_docs() then
    io.stderr:write("SKIP: test_show_module_examples_module_function_collision\n")
    print("test_show_module_examples_module_function_collision: PASS (skipped)")
    return
  end
  local index = docs.embedded_index()
  assert(index, "index should load")
  local idx = index as doc_types.DocIndex
  if not (idx.modules["cosmic.quicksand.box.run"] and idx.modules["cosmic.quicksand.box"]) then
    print("test_show_module_examples_module_function_collision: PASS (fixture modules absent)")
    return
  end
  local result = docs.show_module_examples("cosmic.quicksand.box.run")
  assert(result, "should return a result")
  assert(result.ok, "collision query must resolve via the function filter: " .. result.output)
  assert(result.output:match("run"), "output should mention run")
  print("test_show_module_examples_module_function_collision: PASS")
end
test_show_module_examples_module_function_collision()
