--- `cosmic fix` in a project that git ignores part of: an ignored path is
--- no link's target, and an ignored directory's Markdown is not checked.
--- It declares `tool` because it starts this program, and "system"
--- because the program asks git which paths are ignored.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic", "system" }, env = { "PATH", "HOME" },
  grants = { { path = "o/bin", letters = "rx" } } }

local function run(root: string, args: {string}): Child.Result
  local started = this_program.program(args, { cwd = root,
    stdout = "capture", stderr = "stdout", timeout_ns = Clock.seconds(90) })
  return (assert(Child.run(started.argv, started.options)))
end

local function git(root: string, args: {string})
  local found = assert(Proc.find("git"))
  local argv: mut {string} = { found, "-C", root }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result = assert(Child.run(argv, { stdout = "capture", stderr = "stdout",
    timeout_ns = Clock.seconds(30) }))
  assert(result.ok, result.stdout)
end

--- A project with a README that names `out/gen.txt` and `src/kept.txt`,
--- and an ignored `node_modules/` and `out/`.
local function project(tmp: string, repository: boolean): string
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/out"))
  assert(Fs.mkdirs(root .. "/src"))
  assert(Fs.mkdirs(root .. "/node_modules/p"))
  assert(Fs.write(root .. "/.gitignore", "out/\nnode_modules/\n"))
  assert(Fs.write(root .. "/out/gen.txt", "generated\n"))
  assert(Fs.write(root .. "/src/kept.txt", "kept\n"))
  assert(Fs.write(root .. "/node_modules/p/R.md", "See [`gone`].\n"))
  assert(Fs.write(root .. "/README.md", "Writes `out/gen.txt` from `src/kept.txt`.\n"))
  if repository then
    git(root, { "init", "-q" })
  end
  return root
end

local function test_an_ignored_target_is_no_link_and_an_ignored_directory_is_not_read(tmp: string)
  local root = project(tmp, true)
  local result = run(root, { "fix" })
  assert(result.ok, result.stdout)
  local text = assert(Fs.read(root .. "/README.md"))
  assert(text:find("[`src/kept.txt`]", 1, true) ~= nil, text)
  assert(text:find("[`out/gen.txt`]", 1, true) == nil, text)
  assert(text:find("node_modules", 1, true) == nil, text)
  assert(assert(result.stdout):find("node_modules", 1, true) == nil, result.stdout)
  assert(assert(Fs.read(root .. "/node_modules/p/R.md")) == "See [`gone`].\n")
end

local function test_check_skips_an_ignored_directory(tmp: string)
  local root = project(tmp, true)
  assert(Fs.write(root .. "/README.md", "Nothing here.\n"))
  local result = run(root, { "fix", "--check" })
  assert(result.ok, result.stdout)
  assert(assert(result.stdout):find("node_modules", 1, true) == nil, result.stdout)
end

local function test_without_git_node_modules_is_still_skipped(tmp: string)
  local root = project(tmp, false)
  assert(Fs.write(root .. "/README.md", "Nothing here.\n"))
  local result = run(root, { "fix", "--check" })
  assert(result.ok, result.stdout)
  assert(assert(result.stdout):find("node_modules", 1, true) == nil, result.stdout)
end
