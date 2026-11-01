--- The leaves of [`cosmic.shape`] and its functions are fixed: a module that assigns one is refused by the checker, so no
--- importer can swap a check that the code the build writes for `record_of` reads. Each case is a chunk this program
--- checks as Teal, as `cosmic -e` does.
local Child = require("cosmic.child")
local _ = require("cosmic.shape") -- in the closure, so the program the chunk runs in finds it
local Test = require("cosmic.test")
local this_program = require("build.this_program")

Test.policy{
  cpu_features = true,
  profiles = { "cosmic", "proc" },
}

--- What checking `chunk` said, and whether it was taken.
local function checking(chunk: string): boolean, string
  local started = this_program.program({ "-e", chunk }, { stdout = "capture", stderr = "capture" })
  local r = assert(Child.run(started.argv, started.options))
  return r.ok, tostring(r.stdout) .. tostring(r.stderr)
end

local HEAD <const> = 'local Shape = require("cosmic.shape")\n'

local function test_a_leaf_of_shape_cannot_be_assigned_from_another_module()
  local ok, said = checking(HEAD .. "Shape.string = { check = function(_value: any, path: string): string?, string " ..
      'return "forged", path end }\n')
  assert(not ok and said:find("field_fixed", 1, true) ~= nil, said)
  local build_ok, build_said = checking(HEAD .. "Shape.build = Shape.build\n")
  assert(not build_ok and build_said:find("field_fixed", 1, true) ~= nil, build_said)
end

local function test_a_function_of_shape_cannot_be_assigned_from_another_module()
  local ok, said = checking(HEAD .. "Shape.list = Shape.map\n")
  assert(not ok and said:find("field_fixed", 1, true) ~= nil, said)
  local into_ok, into_said = checking(HEAD .. "Shape.into = Shape.into\n")
  assert(not into_ok and into_said:find("field_fixed", 1, true) ~= nil, into_said)
end

local function test_reading_them_is_taken()
  local ok, said = checking(HEAD .. "local spec = Shape.list(Shape.string)\nprint(type(spec))\n")
  assert(ok, said)
end
