--- `cosmic fix` in a project that git ignores part of: an ignored path is no link's target, and an ignored directory's
--- Markdown is not checked. Only fix asks git, and only for the tree's own `.gitignore` files: the projection the build
--- writes is the same whatever git or the user's excludes say. It declares `tool` because it starts this program, and
--- "system" because the program asks git which paths are ignored.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local build_paths = require("build.paths")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic", "system" }, env = { "PATH", "HOME" },
  grants = { { path = "o/bin", letters = "rx" } } }

--- Runs fix with `args` in `root`; `extra` is added to the program's environment.
local function run(root: string, args: {string}, extra?: {string: string}): Child.Result
  local env = this_program.environment()
  for name, value in pairs(extra or {}) do env[name] = value end
  local started = this_program.program(args, { cwd = root, env = env,
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

--- A project with a README that names `out/gen.txt` and `src/kept.txt`, an ignored `out/` and an ignored
--- `node_modules/`, as a repository when `repository`.
local function project(tmp: string, name: string, repository: boolean): string
  local root = tmp .. "/" .. name
  assert(Fs.mkdirs(root .. "/out"))
  assert(Fs.mkdirs(root .. "/src"))
  assert(Fs.mkdirs(root .. "/node_modules/p"))
  assert(Fs.write(root .. "/.gitignore", "out/\nnode_modules/\n"))
  assert(Fs.write(root .. "/out/gen.txt", "generated\n"))
  assert(Fs.write(root .. "/src/kept.txt", "kept\n"))
  assert(Fs.write(root .. "/node_modules/p/R.md", "See [`gone`].\n"))
  assert(Fs.write(root .. "/README.md", "Writes `out/gen.txt` from `src/kept.txt`.\n"))
  if repository then git(root, { "init", "-q" }) end
  return root
end

local function test_an_ignored_target_is_no_link_and_an_ignored_directory_is_not_read(tmp: string)
  local root = project(tmp, "project", true)
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
  local root = project(tmp, "project", true)
  assert(Fs.write(root .. "/README.md", "Nothing here.\n"))
  local result = run(root, { "fix", "--check" })
  assert(result.ok, result.stdout)
  assert(assert(result.stdout):find("node_modules", 1, true) == nil, result.stdout)
end

local function test_without_git_node_modules_is_still_skipped(tmp: string)
  local root = project(tmp, "project", false)
  assert(Fs.write(root .. "/README.md", "Nothing here.\n"))
  local result = run(root, { "fix", "--check" })
  assert(result.ok, result.stdout)
  assert(assert(result.stdout):find("node_modules", 1, true) == nil, result.stdout)
end

--- Git that refuses a repository for its owner (as it does with the user's `safe.directory` unread) is told once, and fix
--- still runs with `node_modules/` alone left alone.
local function test_a_repository_git_refuses_is_told_once(tmp: string)
  local root = project(tmp, "project", true)
  assert(Fs.write(root .. "/README.md", "Writes `src/kept.txt`.\n"))
  local bin = tmp .. "/fakebin"
  assert(Fs.mkdirs(bin))
  assert(Fs.write(bin .. "/git", "#!/bin/sh\necho 'fatal: detected dubious ownership in repository at x' >&2\nexit 128\n", 0x1ed))
  local result = run(root, { "fix" }, { PATH = bin })
  assert(result.ok, result.stdout)
  local said = assert(result.stdout)
  local first = said:find("dubious ownership", 1, true)
  assert(first ~= nil, said)
  assert(said:find("only node_modules/ is left alone", 1, true) ~= nil, said)
  assert(said:find("dubious ownership", first + 1, true) == nil, said)
end

--- A negation un-ignores one file of an ignored directory's contents: it is a target again.
local function test_a_negated_path_is_a_link_again(tmp: string)
  local root = project(tmp, "project", true)
  assert(Fs.write(root .. "/.gitignore", "out/*\n!out/keep.txt\nnode_modules/\n"))
  assert(Fs.write(root .. "/out/keep.txt", "kept\n"))
  assert(Fs.write(root .. "/README.md", "Has `out/gen.txt` and `out/keep.txt`.\n"))
  local result = run(root, { "fix" })
  assert(result.ok, result.stdout)
  local text = assert(Fs.read(root .. "/README.md"))
  assert(text:find("[`out/keep.txt`]", 1, true) ~= nil, text)
  assert(text:find("[`out/gen.txt`]", 1, true) == nil, text)
end

--- A project in a subdirectory of a repository reads the ignore files above it too.
local function test_a_project_below_a_repository_root_is_read_with_its_parents_ignores(tmp: string)
  local top = tmp .. "/repository"
  local root = top .. "/app"
  assert(Fs.mkdirs(root .. "/out"))
  assert(Fs.mkdirs(root .. "/src"))
  assert(Fs.write(top .. "/.gitignore", "out/\n"))
  assert(Fs.write(root .. "/out/gen.txt", "generated\n"))
  assert(Fs.write(root .. "/src/kept.txt", "kept\n"))
  assert(Fs.write(root .. "/README.md", "Writes `out/gen.txt` from `src/kept.txt`.\n"))
  git(top, { "init", "-q" })
  local result = run(root, { "fix" })
  assert(result.ok, result.stdout)
  local text = assert(Fs.read(root .. "/README.md"))
  assert(text:find("[`src/kept.txt`]", 1, true) ~= nil, text)
  assert(text:find("[`out/gen.txt`]", 1, true) == nil, text)
end

--- The user's global excludes are not the tree's: they change neither what fix links nor the projection.
local function test_a_global_excludes_file_changes_neither_fix_nor_the_projection(tmp: string)
  local excludes = tmp .. "/excludes"
  assert(Fs.write(excludes, "src/\n"))
  local config = tmp .. "/gitconfig"
  assert(Fs.write(config, "[core]\n\texcludesFile = " .. excludes .. "\n"))
  local plain = project(tmp, "plain", true)
  local user_config = project(tmp, "global", true)
  local first = run(plain, { "fix" })
  local second = run(user_config, { "fix" }, { GIT_CONFIG_GLOBAL = config, XDG_CONFIG_HOME = tmp .. "/none",
    GIT_DIR = tmp .. "/nowhere", GIT_WORK_TREE = tmp .. "/nowhere" })
  assert(first.ok and second.ok, tostring(first.stdout) .. tostring(second.stdout))
  assert(assert(Fs.read(plain .. "/README.md")) == assert(Fs.read(user_config .. "/README.md")))
  assert(assert(Fs.read(user_config .. "/README.md")):find("[`src/kept.txt`]", 1, true) ~= nil)
  local function signature(root: string): string
    local db = assert(Sqlite.open(assert(build_paths.prepare(root)) .. "/cosmic.db"))
    local rows = assert(Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = 'projected'"))
    local value = assert(rows[1]):text(1)
    assert(db:close())
    return value
  end
  assert(signature(plain) ~= "" and signature(plain) == signature(user_config),
    signature(plain) .. " against " .. signature(user_config))
end
