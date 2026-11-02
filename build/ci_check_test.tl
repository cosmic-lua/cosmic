--- A project of its own inside the tree (`ci/`) names its modules from its own root: `cosmic_ci.a` is `cosmic_ci/a.tl` when
--- `fix --check` runs with that directory as the working directory, and a type error in it fails there. The tree's own checks
--- read none of `ci/` ([`build.tree_checks`]'s `sources_of`); `ci/` itself is checked by the CI driver's format phase
--- (ci/cosmic_ci/orchestration.tl's `format_check`), which runs the same check with `ci/` as the working directory, since a
--- cold build and check of all of `ci/` takes some 16 s, more than a unit test is given. This holds the shape to a project of
--- two files.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which builds the project around its working directory.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local RECORD <const> = "local record A\n  n: integer\nend\nreturn A\n"
local USER <const> = 'local A = require("cosmic_ci.a")\nlocal a: A = { n = 1 }\nreturn a\n'

--- `cosmic fix --check` with `root` as the working directory.
local function check_in(root: string): Child.Result
  local env = this_program.environment()
  env["COSMIC_BUILD_CACHE"] = "0"
  local started = this_program.program({ "fix", "--check" }, { cwd = root, env = env, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(60) })
  return (assert(Child.run(started.argv, started.options)))
end

--- A project of two files, in a directory named `ci`, as `ci/` is.
local function project_in(tmp: string, user: string): string
  local root = tmp .. "/ci"
  assert(Fs.mkdirs(root .. "/cosmic_ci"))
  assert(Fs.write(root .. "/cosmic_ci/a.tl", RECORD))
  assert(Fs.write(root .. "/cosmic_ci/b.tl", user))
  return root
end

local function test_a_project_inside_the_tree_is_checked_from_its_own_directory_by_its_own_names(tmp: string)
  local clean = check_in(project_in(tmp, USER))
  assert(clean.code == 0, tostring(clean.stdout) .. tostring(clean.stderr))
end

local function test_a_type_error_in_a_project_inside_the_tree_fails_the_check_from_its_own_directory(tmp: string)
  local planted = check_in(project_in(tmp, USER .. 'local planted: integer = "s"\n'))
  local said = tostring(planted.stdout) .. tostring(planted.stderr)
  assert(planted.code ~= 0 and said:find("cosmic_ci/b.tl", 1, true) ~= nil, said)
end
