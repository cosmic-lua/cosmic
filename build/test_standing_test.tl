--- End to end: a test that changes its working directory stands like
--- any other, whether the change is made through `sys.chdir` looked up
--- at call time or through a reference the module took when it loaded:
--- what it read from there is keyed by where that is -- even past a
--- module that stubs `sys.getcwd` -- so it runs again when a file it
--- read changes, and never stands on a read outside the tree.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

local function run(program: string, root: string, output: string,
                   env: {string:string}, fails?: boolean): string
  local fd = assert(Fs.open_write(output))
  local result, trouble = Child.run({ program, "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil and result.ok == not fails, tostring(trouble) .. text)
  return text
end

local function test_a_chdir_stands_on_what_it_read_from_there(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/data"))
  assert(Fs.mkdirs(tmp .. "/outside"))
  assert(Fs.write(root .. "/data/f", "one\n"))
  assert(Fs.write(tmp .. "/outside/f", "out\n"))
  assert(Fs.write(root .. "/suite/loaded_test.tl", [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local root = assert(sys.getcwd())
assert(sys.chdir("data"))

local function test_reads_where_the_module_moved()
  local ok = Fs.read("f") == "one\n"
  assert(sys.chdir(root))
  assert(ok)
end
]]))
  assert(Fs.write(root .. "/suite/stubbed_test.tl", [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local root = assert(sys.getcwd())
sys.getcwd = function(): string, string, integer return root, "", 0 end

local function test_reads_where_it_moved_past_a_stubbed_getcwd()
  assert(sys.chdir("data"))
  local ok = Fs.read("f") == "one\n"
  assert(sys.chdir(root))
  assert(ok)
end
]]))
  assert(Fs.write(root .. "/suite/moves_test.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local chdir = sys.chdir

local function test_moves_at_call_time()
  local here = assert(sys.getcwd())
  assert(sys.chdir("data"))
  assert(Fs.read("f") == "one\n")
  assert(sys.chdir(here))
end

local function test_moves_through_a_loaded_reference()
  local here = assert(sys.getcwd())
  assert(chdir(here .. "/data"))
  assert(Fs.read("f") == "one\n")
  assert(chdir(here))
end

local function test_moves_outside()
  assert(sys.chdir(assert(Env.get("OUTSIDE"))))
  assert(Fs.read("f") == "out\n")
end

local function test_plain()
  assert(1 + 1 == 2)
end
]]))
  local program = assert(Proc.executable())
  local env = Env.all()
  env.OUTSIDE = tmp .. "/outside"
  local first = run(program, root, tmp .. "/first.out", env)
  assert(first:find("6 ran, 0 stood", 1, true), first)
  local second = run(program, root, tmp .. "/second.out", env)
  assert(second:find("1 ran, 5 stood", 1, true), second)
  -- Rewritten in place, so nothing but the file itself says it changed:
  -- not its directory's listing or stat.
  local fd = assert(sys.open(root .. "/data/f", sys.O_WRONLY | sys.O_TRUNC))
  assert(sys.write(fd, "two\n") == 4)
  sys.close(fd)
  local third = run(program, root, tmp .. "/third.out", env, true)
  assert(third:find("4 of 6 failed", 1, true), third)
end
