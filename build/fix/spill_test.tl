local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local spill = require("build.fix.spill")
local teal = require("build.teal")
local observations = require("build.filesystem_observations")
local type Declared = require("build.inputs").Declared

--- Where the checker looks for modules, which a test runs it without.
local _inputs: Declared = { env = { "TL_PATH" } }

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- Only the call the checker names is wrapped, whatever its arguments,
--- and nothing else on the line moves.
local function test_wraps_only_the_named_assert()
  local built = assert(teal.load())
  local src = 'local function f(cwd: string): string\n' ..
    '  return assert(cwd:match("^(.*)/[^/]+$"), cwd .. ": no parent")\nend\n' ..
    'local n = math.tointeger(assert(tonumber("1")))\nreturn { f, n }\n'
  local out, trouble = spill.wrap(built, src, "x.tl", { ["2:16"] = true })
  assert(out == 'local function f(cwd: string): string\n' ..
    '  return (assert(cwd:match("^(.*)/[^/]+$"), cwd .. ": no parent"))\nend\n' ..
    'local n = math.tointeger(assert(tonumber("1")))\nreturn { f, n }\n',
    tostring(out) .. trouble)
end

--- The sites are read off a build's own diagnostics, by file.
local function test_sites_read_the_checker_message()
  local text = "a/b.tl: the compiler refused it\n" ..
    "a/b.tl:3:9: wrong number of arguments (given 3, expects 1)\n" ..
    "a/b.tl:3:17: " .. spill.message .. "\n" ..
    "c.tl:1:1: " .. spill.message .. "\n"
  local sites = spill.sites(text)
  assert(sites["a/b.tl"]["3:17"] and not sites["a/b.tl"]["3:9"])
  assert(sites["c.tl"]["1:1"])
end

--- The checker types assert as returning every value it was given, so a
--- spill with nowhere to go is refused and the report lands on the `(` of
--- the assert it means; one given a single value returns only that one.
local function test_the_checker_names_the_spilling_assert()
  local built = assert(teal.load())
  local src = 'local function read(): string | nil, string return "7", "" end\n' ..
    'local n = tonumber(assert(read()))\n' ..
    'local t: {string} = { "a", assert(tostring(n)) }\n' ..
    'local function count(): integer | nil, string return 1, "" end\n' ..
    'local u: {integer} = { 2, assert(count()) }\nreturn { t, u }\n'
  local env = built.new_env({})
  local _, result = built.gen(src, env, nil, "tl")
  local found: {string} = {}
  for _, e in ipairs(result.type_errors) do
    if e.msg == spill.message then found[#found + 1] = e.y .. ":" .. e.x end
  end
  table.sort(found)
  assert(#found == 2 and found[1] == "2:26" and found[2] == "5:33",
    table.concat(found, " "))
end

local function fix(root: string, check: boolean): Child.Result
  local argv: {string} = { assert(Proc.executable()), "fix" }
  if check then argv[#argv + 1] = "--check" end
  return (assert(Child.run(argv, { cwd = root, env = observations.environment(),
    stdout = "capture", stderr = "stdout", timeout_ms = 60000 })))
end

--- `cosmic fix` builds the project, wraps the assert the checker names,
--- builds again, and stops once the checker names none; `--check` says
--- so without writing.
local function test_fix_wraps_what_the_checker_names(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  local source = 'local function read(): string | nil, string return "7", "" end\n' ..
    'return tonumber(assert(read()))\n'
  assert(Fs.write(root .. "/spill.tl", source))
  local checked = fix(root, true)
  assert(not checked.ok and assert(checked.stdout):find("would fix  spill.tl", 1, true),
    checked.stdout)
  assert(Fs.read(root .. "/spill.tl") == source, "--check wrote")
  local fixed = fix(root, false)
  assert(fixed.ok and assert(fixed.stdout):find("fixed  spill.tl", 1, true), fixed.stdout)
  assert(Fs.read(root .. "/spill.tl") == 'local function read(): string | nil, string ' ..
    'return "7", "" end\nreturn tonumber((assert(read())))\n')
  local again = fix(root, false)
  assert(again.ok and assert(again.stdout):find("0 fixed", 1, true), again.stdout)
end
