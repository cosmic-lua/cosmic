--- Tests of [`build.checker_declarations`]: the prelude and the standard library's declarations a tool carries for the projects
--- it types, read from the tree it is written from and held to the files as they were staged.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Test = require("cosmic.test")
local CheckerDeclarations = require("build.checker_declarations")
local work = require("build.work")

Test.policy{ grants = { { path = "checker/tl.tl", letters = "r" }, { path = "checker/stdlib.d.tl", letters = "r" } } }

local PRELUDE <const> = "do\n   global interface any\n   end\nend\n"
local TL <const> = "local VERSION = \"0\"\nlocal prelude = [=====[\n" .. PRELUDE .. "]=====]\nreturn {}\n"
local STDLIB <const> = "do\n   global function print(any...)\n   end\nend\n"

local function test_the_prelude_is_the_text_between_the_marks_of_the_forks_checker()
  assert(CheckerDeclarations.prelude_of(TL) == PRELUDE)
  assert(CheckerDeclarations.prelude_of("return {}\n") == nil)
  -- the real one declares what the language has before any library: the types the standard library names
  local real = assert(CheckerDeclarations.prelude_of((assert(Fs.read("checker/tl.tl")))))
  assert(real:find("global record metatable<T>", 1, true) ~= nil and real:find("global interface any", 1, true) ~= nil)
  assert(real:find("global record coroutine", 1, true) == nil, "the prelude holds a library")
  assert((assert(Fs.read("checker/stdlib.d.tl"))):find("global record coroutine", 1, true) ~= nil)
end

--- A tree of cosmic's own as far as the build asks, with the two files of `checker/`, staged under `tmp`.
local function own_tree(tmp: string, tl: string, stdlib: string): work.Handle, string
  local root = tmp .. "/own"
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/checker"))
  assert(Fs.write(root .. "/core/.keep", ""))
  assert(Fs.write(root .. "/build/importer.tl", "return {}\n"))
  assert(Fs.write(root .. "/checker/tl.tl", tl))
  assert(Fs.write(root .. "/checker/stdlib.d.tl", stdlib))
  local handle = assert(work.open(root))
  local staged, why = work.stage(handle, true)
  assert(staged ~= nil, tostring(why))
  return handle, root
end

local function test_the_texts_of_a_staged_tree_are_the_files_as_they_were_staged(tmp: string)
  local handle, root = own_tree(tmp, TL, STDLIB)
  local texts, why = CheckerDeclarations.staged(handle.db, root)
  assert(texts ~= nil and texts.prelude == PRELUDE and texts.stdlib == STDLIB, tostring(why))
  -- a file edited after it was staged is no part of the tool
  assert(Fs.write(root .. "/checker/stdlib.d.tl", STDLIB .. "-- edited\n"))
  local edited, edited_why = CheckerDeclarations.staged(handle.db, root)
  assert(edited == nil and edited_why:find("checker/stdlib.d.tl changed while the tool was being built", 1, true) ~= nil,
    tostring(edited_why))
  assert(work.close(handle))
end

local function test_a_tree_with_a_checker_that_has_no_prelude_is_refused(tmp: string)
  local handle, root = own_tree(tmp, "return {}\n", STDLIB)
  local texts, why = CheckerDeclarations.staged(handle.db, root)
  assert(texts == nil and why:find("has no prelude between `[=====[` marks", 1, true) ~= nil, tostring(why))
  assert(work.close(handle))
end

local function test_a_project_stages_none_and_says_nothing(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/checker"))
  assert(Fs.write(root .. "/m.tl", "return 1\n"))
  assert(Fs.write(root .. "/checker/tl.tl", TL))
  assert(Fs.write(root .. "/checker/stdlib.d.tl", STDLIB))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local texts, why = CheckerDeclarations.staged(handle.db, root)
  assert(texts == nil and why == "", tostring(why))
  assert(work.close(handle))
  assert(Hash.hex_sha256(TL) ~= Hash.hex_sha256(STDLIB))
end
