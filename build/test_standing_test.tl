--- End to end: a test that changes its working directory runs again on
--- the next `cosmic test`, while a plain one beside it stands, whether
--- the change is made through `sys.chdir` looked up at call time or
--- through a reference the module took when it loaded.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

local function run(program: string, root: string, output: string): string
  local fd = assert(Fs.open_write(output))
  local result, trouble = Child.run({ program, "test" }, {
    cwd = root, env = Env.all(), stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil and result.ok, tostring(trouble) .. text)
  return text
end

local function test_a_chdir_never_stands(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/moves_test.tl", [[
local sys = require("cosmic.sys")
local chdir = sys.chdir

local function test_moves_at_call_time()
  assert(sys.chdir((assert(sys.getcwd()))))
end

local function test_moves_through_a_loaded_reference()
  assert(chdir((assert(sys.getcwd()))))
end

local function test_plain()
  assert(1 + 1 == 2)
end
]]))
  local program = assert(Proc.executable())
  local first = run(program, root, tmp .. "/first.out")
  assert(first:find("3 ran, 0 stood", 1, true), first)
  local second = run(program, root, tmp .. "/second.out")
  assert(second:find("2 ran, 1 stood", 1, true), second)
end
