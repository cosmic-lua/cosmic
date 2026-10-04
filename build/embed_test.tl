--- `cosmic build` on a tree that writes no executable -- a library, or
--- cosmic's own tree -- and a core that holds no program. None of these
--- copies this program's database into one, so none needs `tool`: the
--- bare core is the running one, read through [`artifact.trusted_core`]
--- and keyed with the runtime's identity, as [`core/boot_test.tl`]'s is.
--- The executables it writes are proved in `embed_tool_test.tl`.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local artifact = require("build.artifact")
local embed = require("build.embed")
local Clock = require("cosmic.clock")

local greet_source = [[
local record greet
end

function greet.hello(name: string): string
  return "hello, " .. name
end

return greet
]]

local function test_a_tree_without_a_main_builds_and_writes_nothing(tmp: string)
  assert(Fs.write(tmp .. "/greet.tl", greet_source))
  local names, trouble = embed.tree(tmp)
  assert(names ~= nil, trouble)
  assert(#names == 0, "a library tree has no executable to write")
  local database_exists, exists_trouble = Fs.exists(tmp .. "/o/cosmic.db")
  assert(database_exists ~= nil, exists_trouble)
  assert(database_exists, "but it was built")
  assert(Fs.exists(tmp .. "/o/bin") == false)
end

local function test_cosmic_s_own_tree_is_refused(tmp: string)
  assert(Fs.mkdirs(tmp .. "/core"))
  assert(Fs.mkdirs(tmp .. "/build"))
  assert(Fs.write(tmp .. "/build/importer.tl", "return {}\n"))
  local names, trouble = embed.tree(tmp)
  assert(names == nil)
  assert(trouble:find("bin/zig build boot", 1, true) ~= nil, trouble)
end

local function run_program(path: string): Child.Result
  return (assert(Child.run({ path }, {
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })))
end

--- A core started on its own, with no program inside and no tree to
--- boot, says so and exits rather than running anything.
local function test_a_bare_core_refuses_to_run(tmp: string)
  local core = assert(artifact.trusted_core())
  local path = tmp .. "/cosmic-core"
  assert(Fs.write(path, core.bytes, 0x1ed))
  local r = run_program(path)
  assert(r.code == 2, "exit " .. tostring(r.code))
  assert((assert(r.stderr)):find("no database attached", 1, true), tostring(r.stderr))
end
