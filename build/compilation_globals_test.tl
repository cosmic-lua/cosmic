--- A build refuses a `global` in any module it compiles
--- ([`build.compilation`]): each kind of declaration at its own
--- position, a global another module would have read, and a project
--- without one.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")

Test.policy{ grants = { { path = "core", letters = "r" } } }

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

local REFUSED <const> = ": a global is not allowed in a cosmic build: it reaches other modules by no " ..
  "`require`, which is all a build's cache and its order see -- put the value in a module and " ..
  "`require` it"

--- Compiles the project of `files` (filename -> source) under `tmp/<case>`.
local function compile_project(tmp: string, case: string,
                               files: {string:string}): importer.Result | nil, string
  local root = tmp .. "/" .. case
  assert(Fs.mkdirs(root))
  for filename, source in pairs(files) do
    assert(Fs.write(root .. "/" .. filename, source))
  end
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local result, trouble = importer.compile(handle, built, "globals-test")
  assert(work.close(handle))
  return result, trouble
end

--- Each kind of global declaration is refused once, where its `global`
--- keyword is (or `function`, for one written with no keyword), whatever
--- its length or nesting.
local function test_each_kind_of_global_is_refused_at_its_line(tmp: string)
  local cases: {{string}} = {
    { "variable", "global count: integer = 0\n", "2:1" },
    { "bare", "global count: integer\n", "2:1" },
    { "names", "global a, b: integer\n", "2:1" },
    { "function", "global function f(): integer\n  return 1\nend\n", "2:1" },
    { "implicit", "function f(): integer\n  return 1\nend\n", "2:1" },
    { "record", "global record R\n  n: integer\nend\n", "2:1" },
    { "interface", "global interface I\n  n: integer\nend\n", "2:1" },
    { "enum", 'global enum E\n  "a"\nend\n', "2:1" },
    { "type", "global type T = integer\n", "2:1" },
    { "nested", "local function f(): integer\n  global w: integer = 1\n  return w\nend\n", "3:3" },
  }
  for _, c in ipairs(cases) do
    local result, trouble = compile_project(tmp, c[1], {
      ["main.tl"] = "local n = 1\n" .. c[2] .. "return n\n",
    })
    local want = "main.tl:" .. c[3] .. REFUSED
    assert(result == nil and trouble == want,
      c[1] .. ": wanted " .. want .. ", got " .. tostring(trouble))
  end
end

--- A global one module declares and another reads is refused where it is
--- declared, not accepted in the order the modules happen to compile in.
local function test_a_global_another_module_would_read_is_refused_at_its_declaration(tmp: string)
  local result, trouble = compile_project(tmp, "leak", {
    ["shared.tl"] = "global record Shared\n  n: integer\nend\nreturn 1\n",
    ["user.tl"] = "local s: Shared = { n = 1 }\nreturn s.n\n",
  })
  assert(result == nil and trouble:find("shared.tl:1:1" .. REFUSED, 1, true) ~= nil,
    tostring(trouble))
end

--- Every module's own name is the way to share, so a project that
--- requires what it uses compiles.
local function test_a_project_without_globals_compiles(tmp: string)
  local result, trouble = compile_project(tmp, "clean", {
    ["shared.tl"] = "local record Shared\n  n: integer\nend\nreturn Shared\n",
    ["user.tl"] = 'local type Shared = require("shared")\nlocal s: Shared = { n = 1 }\nreturn s.n\n',
  })
  assert(result ~= nil, tostring(trouble))
end
