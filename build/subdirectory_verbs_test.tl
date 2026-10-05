--- `cosmic fix`, `uses` and `docs` started in a subdirectory of a built
--- project answer for the project ([`build.tree_root`]): a link is
--- resolved against its root and its databases, not the subdirectory's.
--- Run in this process ([`build.invoke`]), which reads every module's
--- rows.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local invoke = require("build.invoke")

-- `store`: the verbs, run in this process, read every module's docs.
Test.policy{
  grants = { { path = "o/cosmic.db", letters = "r" } },
  env = { "COSMIC_TREE" },
}

--- `cosmic <args>` in `dir`, built without the shared cache, which lives
--- outside the test's own directory.
local function cosmic(dir: string, args: {string}): invoke.Result
  return invoke.run(args, { cwd = dir, env = { COSMIC_BUILD_CACHE = "0" } })
end

--- A project at `tmp/project` built at its root, with a module and a
--- Markdown file in `greet/`.
local function project(tmp: string): string
  local root = assert(Fs.absolute(tmp)) .. "/project"
  assert(Fs.mkdirs(root .. "/greet"))
  assert(Fs.write(root .. "/README.md", "# Project\n"))
  assert(Fs.write(root .. "/main.tl", 'local greet = require("greet")\nprint(greet.hello("x"))\n'))
  assert(Fs.write(root .. "/greet/init.tl", table.concat({
    "--- Greetings.",
    "local record greet",
    "end",
    "",
    "--- Says hello to `name`.",
    "function greet.hello(name: string): string",
    '  return "hello " .. name',
    "end",
    "",
    "return greet",
    "",
  }, "\n")))
  local built = cosmic(root, { "build" })
  assert(built.code == 0, built.stdout .. built.stderr)
  return root
end

--- A link from a subdirectory to a file above it, to a path from the
--- root, and to a symbol of the project resolves; one to a file that is
--- not there still fails, named from the root.
local function test_fix_in_a_subdirectory_resolves_links_at_the_root(tmp: string)
  local root = project(tmp)
  assert(Fs.write(root .. "/greet/notes.md", table.concat({
    "# Notes",
    "",
    "See [main](../main.tl), [the readme](/README.md) and [`greet.hello`].",
    "",
    "[`greet.hello`]: init.tl",
    "",
  }, "\n")))
  local result = cosmic(root .. "/greet", { "fix", "--check", "notes.md" })
  assert(result.code == 0, result.stdout .. result.stderr)
  assert(result.stderr:find("fix runs in " .. root, 1, true), result.stderr)
  local made, made_trouble = Fs.exists(root .. "/greet/o")
  assert(made ~= nil, made_trouble)
  assert(not made, "a fix in a subdirectory made an o/ there")

  assert(Fs.write(root .. "/greet/broken.md", "See [gone](../gone.tl).\n"))
  local broken = cosmic(root .. "/greet", { "fix", "--check", "broken.md" })
  assert(broken.code ~= 0, broken.stdout .. broken.stderr)
  local said = broken.stdout .. broken.stderr
  assert(said:find("greet/broken.md:1: link: ../gone.tl does not resolve", 1, true), said)
end

--- `uses` and `docs` in a subdirectory read the project's database.
local function test_lookups_in_a_subdirectory_read_the_project(tmp: string)
  local root = project(tmp)
  local uses = cosmic(root .. "/greet", { "uses", "greet.hello" })
  assert(uses.code == 0, uses.stdout .. uses.stderr)
  assert(uses.stdout:find("main.tl:2:", 1, true), uses.stdout)
  local docs = cosmic(root .. "/greet", { "docs", "greet.hello" })
  assert(docs.code == 0, docs.stdout .. docs.stderr)
  assert(docs.stdout:find("Says hello to `name`.", 1, true), docs.stdout)
end
