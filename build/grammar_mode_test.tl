--- The tests of [`build.grammar_mode`]: the checker a run asks for, and the tool string every compile key carries. A run that asks for
--- the fork's keys exactly as it did before the mode existed.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local GrammarMode = require("build.grammar_mode")
local importer = require("build.importer")
local Test = require("cosmic.test")
local teal = require("build.teal")
local work = require("build.work")

Test.policy{ env = { "COSMIC_GRAMMAR" }, grants = { { path = "core", letters = "r" } } }

local built = assert(teal.load())

local function test_an_unset_or_empty_variable_is_the_fork_and_a_word_that_is_none_is_refused()
  assert(GrammarMode.of(nil) == "teal" and GrammarMode.of("") == "teal" and GrammarMode.of("teal") == "teal")
  assert(GrammarMode.of("new") == "new")
  for _, word in ipairs({ "New", "tl", "fork", " new", "new " }) do
    local mode, why = GrammarMode.of(word)
    assert(mode == nil and why:find("COSMIC_GRAMMAR=" .. word, 1, true) ~= nil, word .. ": " .. tostring(why))
  end
end

local function test_the_mode_is_the_one_the_variable_names()
  -- The variable is the run's own: a rehearsal sets it, and every other run leaves it out.
  local word = Env.get("COSMIC_GRAMMAR")
  local mode, why = GrammarMode.mode()
  local want, want_why = GrammarMode.of(word)
  assert(mode == want and why == want_why)
  assert(word ~= "new" or mode == "new")
  assert(word ~= nil or mode == "teal")
end

-- A run that asks for the fork keys every compile as it did before: by the tool alone. These are the strings the keys of
-- compiled rows, shared compiles and verdicts were made of, for a few tools, and the checked variants of the same.
local function test_the_forks_tool_string_is_the_tool_unchanged_whatever_else_is_asked()
  for _, tool in ipairs({ "", "a", "0123456789abcdef", string.rep("x", 200), "a\0b" }) do
    assert(GrammarMode.tool(tool, "teal") == tool)
    assert(GrammarMode.tool(tool, "teal", false) == tool)
    -- the fork writes no calls of `__fact`
    assert(GrammarMode.tool(tool, "teal", true) == tool)
  end
  -- the keys of a checked run of the fork are what they were
  assert(importer.checked_tool("a") == "abdb762662b1e196ab3518448ef4b4a98dbed1698fff77d6c2eda3194b91b571")
  assert(importer.checked_tool("a", true) == "d2e4829f1990b58943dbb62f48084bc11cb4c1680e002a1f9b6d0720eaf8260e")
  assert(importer.checked_tool(GrammarMode.tool("a", "teal")) == importer.checked_tool("a"))
end

local function test_the_new_grammar_is_keyed_apart_from_the_fork_and_from_its_own_checked_run()
  assert(GrammarMode.tool("a", "new") == "a340d8fb401ad242f252858c92a6f1f4cb8242e94eb13d192dd79abc5fbb0f31")
  assert(GrammarMode.tool("a", "new", true) == "621455f4b8753f06c86c88f0c84841e3b89fc5ffc43cf1af5a5d91d40afdffb4")
  local kinds: mut {string: string} = {}
  local count = 0
  for _, tool in ipairs({ "a", "b" }) do
    local keys: {string} = {
      tool, importer.checked_tool(tool), importer.checked_tool(tool, true),
      GrammarMode.tool(tool, "new"), GrammarMode.tool(tool, "new", true),
      importer.checked_tool(GrammarMode.tool(tool, "new")), importer.checked_tool(GrammarMode.tool(tool, "new"), true),
    }
    for _, key in ipairs(keys) do
      assert(kinds[key] == nil, "two compiles share the key " .. key)
      kinds[key] = tool
      count = count + 1
    end
  end
  assert(count == 14)
end

--- The compile of the project under `tool`: the modules and their rows (path, key, Lua) and how many it compiled.
local function compiled_under(root: string, tool: string): {string}, integer
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local result = assert(importer.compile(handle, built, tool))
  local found = assert(Sqlite.text_rows(handle.db,
    "SELECT p.path, c.key, c.lua FROM plan p JOIN compiled c ON c.key = p.key ORDER BY p.path"))
  local rows: mut {string} = {}
  for _, row in ipairs(found) do
    rows[#rows + 1] = row:text(1) .. "\0" .. row:text(2) .. "\0" .. row:text(3)
  end
  assert(work.close(handle))
  return rows, result.compiled
end

-- The default mode is the tool alone, so a run that asks for nothing finds every compile of a run before the mode existed
-- standing, and writes the Lua it wrote. The new mode keys the same project afresh and, until the build calls the new
-- pipeline, to the same Lua.
local function test_a_project_compiled_under_the_default_mode_is_the_rows_it_was_and_the_new_mode_keys_them_apart(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/a.tl", "local record A\n  n: integer\nend\nlocal a: A = { n = 1 }\nreturn a\n"))
  assert(Fs.write(root .. "/b.tl", "local a = require(\"a\")\nlocal b: integer = a.n + 1\nreturn b\n"))
  local before, first = compiled_under(root, "tool-identity")
  assert(first == 2 and #before == 2, tostring(first))
  local default, again = compiled_under(root, GrammarMode.tool("tool-identity", "teal"))
  assert(again == 0, "the default mode compiled " .. tostring(again) .. " modules again")
  assert(table.concat(default, "\n") == table.concat(before, "\n"))
  local new, fresh = compiled_under(root, GrammarMode.tool("tool-identity", "new"))
  assert(fresh == 2, "the new mode found " .. tostring(2 - fresh) .. " modules compiled for the default")
  for index, row in ipairs(new) do
    local key_before, lua_before = before[index]:match("^[^%z]*%z([^%z]*)%z(.*)$")
    local key_new, lua_new = row:match("^[^%z]*%z([^%z]*)%z(.*)$")
    assert(key_before ~= key_new and lua_before == lua_new, "module " .. tostring(index))
  end
end
