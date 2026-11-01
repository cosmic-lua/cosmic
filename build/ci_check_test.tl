--- `ci/` is a project of its own inside the tree: the tree's checks name no module of it, so what holds its sources to the
--- checker is `cosmic fix --check` run with `ci/` as the working directory, where its modules are `cosmic_ci.x`. This runs
--- that check on a copy of `ci/` with the tool the tree builds, so that a type error in `ci/cosmic_ci` fails the tree's own
--- suite, as it failed the tree's checks when they read `ci/` under the tree's names.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The sources of `ci/` to copy, and the program that checks them.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "ci/", letters = "r" } },
}

--- A copy of `ci/` below `tmp`, without a checkout-local `o/`, and the path of the copy.
local function copy_of_ci(tmp: string): string
  local root = tmp .. "/ci"
  local listed = assert(Fs.walk("ci", function(relative: string, name: string, kind: Fs.Kind): boolean
    return kind == "dir" and (relative == "ci/o" or relative == "o" or name:sub(1, 1) == ".")
  end))
  for _, file in ipairs(listed) do
    local text = assert(Fs.read("ci/" .. file))
    assert(Fs.mkdirs(Fs.dirname(root .. "/" .. file)))
    assert(Fs.write(root .. "/" .. file, text))
  end
  return root
end

--- `cosmic fix --check` with `root` as the working directory.
local function check_in(root: string): Child.Result
  local env = this_program.environment()
  env["COSMIC_BUILD_CACHE"] = "0"
  local started = this_program.program({ "fix", "--check" }, { cwd = root, env = env, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(120) })
  return (assert(Child.run(started.argv, started.options)))
end

local function test_ci_checked_from_its_own_directory_holds_its_sources_to_the_checker(tmp: string)
  local root = copy_of_ci(tmp)
  local clean = check_in(root)
  assert(clean.code == 0, tostring(clean.stdout) .. tostring(clean.stderr))
  local plural = assert(Fs.read(root .. "/cosmic_ci/plural.tl"))
  assert(Fs.write(root .. "/cosmic_ci/plural.tl", plural .. '\nlocal planted: integer = "s"\n'))
  local planted = check_in(root)
  local said = tostring(planted.stdout) .. tostring(planted.stderr)
  assert(planted.code ~= 0, said)
  assert(said:find("cosmic_ci/plural.tl", 1, true) ~= nil, said)
end
