--- Tests of [`build.checker_declarations`]: the prelude and the standard library's declarations a tool carries for the projects
--- it types, read from the tree it is written from and held to the files as they were staged.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local CheckerDeclarations = require("build.checker_declarations")
local work = require("build.work")

Test.policy{ grants = { { path = "lang/prelude.d.tl", letters = "r" }, { path = "lang/stdlib.d.tl", letters = "r" } } }

local PRELUDE <const> = "--- @kind language\ndo\n   global record Seen\n   end\nend\n"
local STDLIB <const> = "--- @kind language\ndo\n   global print: function(...: any)\nend\n"

local function test_the_files_are_the_prelude_and_the_library_of_the_tree()
  assert(CheckerDeclarations.prelude_file() == "lang/prelude.d.tl" and CheckerDeclarations.stdlib_file() == "lang/stdlib.d.tl")
  -- the real prelude declares what the language has before any library, and the real library declares the libraries
  local prelude = assert(Fs.read(CheckerDeclarations.prelude_file()))
  assert(prelude:find("global record metatable<T>", 1, true) ~= nil)
  assert(prelude:find("global record coroutine", 1, true) == nil, "the prelude holds a library")
  assert((assert(Fs.read(CheckerDeclarations.stdlib_file()))):find("global record coroutine", 1, true) ~= nil)
end

--- A tree of cosmic's own as far as the build asks, with the files of the new checker's globals, staged under `tmp`.
local function own_tree(tmp: string, files: {string: string}): work.Handle, string
  local root = tmp .. "/own"
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.write(root .. "/core/.keep", ""))
  assert(Fs.write(root .. "/build/importer.tl", "return {}\n"))
  for file, text in pairs(files) do
    assert(Fs.write(root .. "/" .. file, text))
  end
  local handle = assert(work.open(root))
  local staged, why = work.stage(handle, { own = true })
  assert(staged ~= nil, tostring(why))
  return handle, root
end

local function test_the_texts_of_a_staged_tree_are_the_files_as_they_were_staged(tmp: string)
  local handle, root = own_tree(tmp, { ["lang/prelude.d.tl"] = PRELUDE, ["lang/stdlib.d.tl"] = STDLIB })
  local texts, why = CheckerDeclarations.staged(handle.db, root)
  assert(texts ~= nil and texts.prelude == PRELUDE and texts.stdlib == STDLIB, tostring(why))
  -- a file edited after it was staged is no part of the tool
  assert(Fs.write(root .. "/lang/stdlib.d.tl", STDLIB .. "-- edited\n"))
  local edited, edited_why = CheckerDeclarations.staged(handle.db, root)
  assert(edited == nil and edited_why:find("lang/stdlib.d.tl changed while the tool was being built", 1, true) ~= nil,
    tostring(edited_why))
  assert(work.close(handle))
end

local function test_a_declaration_file_is_a_tool_file_and_no_module_of_the_tree(tmp: string)
  local handle, _ = own_tree(tmp, { ["lang/prelude.d.tl"] = PRELUDE, ["lang/stdlib.d.tl"] = STDLIB, ["lang/m.tl"] = "return 1\n" })
  local function count(table_name: string, file: string): integer
    local rows = assert(Sqlite.text_rows(handle.db, "SELECT count(*) FROM " .. table_name .. " WHERE path = ?1",
      { { text = file } }))
    return math.tointeger(tonumber(assert(rows[1]):text(1))) or -1
  end
  -- the fork compiles every declaration file of the tree and reads Teal, not the new grammar these are written in
  for _, file in ipairs({ "lang/prelude.d.tl", "lang/stdlib.d.tl" }) do
    assert(count("files", file) == 0, file .. " is an input")
    assert(count("tool", file) == 1, file .. " is no tool file")
  end
  assert(count("files", "lang/m.tl") == 1 and count("tool", "lang/m.tl") == 1)
  assert(work.close(handle))
end

local function test_a_tree_staging_one_of_the_two_files_is_refused(tmp: string)
  local handle, root = own_tree(tmp, { ["lang/stdlib.d.tl"] = STDLIB })
  local texts, why = CheckerDeclarations.staged(handle.db, root)
  assert(texts == nil and why:find("stages lang/stdlib.d.tl without lang/prelude.d.tl", 1, true) ~= nil, tostring(why))
  assert(work.close(handle))
end

local function test_a_file_of_the_language_that_does_not_say_so_is_refused(tmp: string)
  local untagged = "do\n   global record Seen\n   end\nend\n"
  local handle, root = own_tree(tmp, { ["lang/prelude.d.tl"] = untagged, ["lang/stdlib.d.tl"] = STDLIB })
  local texts, why = CheckerDeclarations.staged(handle.db, root)
  assert(texts == nil and why == "lang/prelude.d.tl: the language's own declarations must say so: add the line " ..
      "`--- @kind language` to its leading comment", tostring(why))
  assert(work.close(handle))
end

local function test_a_project_stages_none_and_says_nothing(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/lang"))
  assert(Fs.write(root .. "/m.tl", "return 1\n"))
  assert(Fs.write(root .. "/lang/prelude.d.tl", PRELUDE))
  assert(Fs.write(root .. "/lang/stdlib.d.tl", STDLIB))
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  local texts, why = CheckerDeclarations.staged(handle.db, root)
  assert(texts == nil and why == "", tostring(why))
  assert(work.close(handle))
end
