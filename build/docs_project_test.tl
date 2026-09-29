--- `cosmic docs` and `cosmic uses` in a project: they build it first, as
--- `cosmic test` does, so what they answer is the tree as it stands, and
--- every module they list answers its own name. Run in this process
--- (`build.invoke`), which reads every module's rows; kept apart so the
--- tests of the verbs' contract (build/verbs_store_test.tl) stand while
--- the build's cache is out of their keys.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local invoke = require("build.invoke")

Test.needs{ reads = { "core" }, env = { "COSMIC_TREE" }, store = true }

--- `cosmic <args>` in `dir`, built without the shared cache, which lives
--- outside the test's own directory.
local function cosmic(dir: string, args: {string}): invoke.Result
  return invoke.run(args, { cwd = dir, env = { COSMIC_BUILD_CACHE = "0" } })
end

local function docs_in(dir: string, ...: string): string
  local words: {string} = { "docs", ... }
  local result = cosmic(dir, words)
  assert(result.code == 0, table.concat(words, " ") .. ": " .. result.stdout .. result.stderr)
  return result.stdout
end

--- `docs` and `uses` answer from the project as it stands: an edit to a
--- doc comment shows with no build between, where a project has one to
--- make, and a directory of no project is left as it was.
local function test_docs_answers_from_the_tree_as_it_stands(tmp: string)
  local project = tmp .. "/project"
  assert(Fs.mkdirs(project))
  local function module(word: string): string
    return "--- " .. word .. " words.\nlocal record Thing\nend\nreturn Thing\n"
  end
  assert(Fs.write(project .. "/thing.tl", module("First")))
  local first = docs_in(project, "thing")
  assert(first:find("First words.", 1, true), first)
  assert(Fs.write(project .. "/thing.tl", module("Second")))
  local second = docs_in(project, "thing")
  assert(second:find("Second words.", 1, true), second)
  assert(not second:find("First words.", 1, true), second)
  local empty = tmp .. "/nothing"
  assert(Fs.mkdirs(empty))
  local _ = cosmic(empty, { "docs", "Fs.read" })
  local made, made_trouble = Fs.exists(empty .. "/o")
  assert(made ~= nil, made_trouble)
  assert(not made, "a directory of no project gets no o/")
end

--- Every module `cosmic docs` lists answers `cosmic docs <module>`, one
--- that returns a function (a command's `main`) with no record to hold
--- its comment among them.
local function test_a_listed_function_module_answers_its_name(tmp: string)
  local project = tmp .. "/project"
  assert(Fs.mkdirs(project .. "/cmd/greet"))
  assert(Fs.write(project .. "/cmd/greet/main.tl",
    "--- Says hello.\nlocal function main(_argv: {integer:string}): integer\n" ..
    "  return 0\nend\nreturn main\n"))
  local index = docs_in(project)
  assert(index:find("cmd.greet.main", 1, true), index)
  local page = docs_in(project, "cmd.greet.main")
  assert(page:find("Says hello.", 1, true), page)
end
