--- End to end: a test that changes its working directory stands like
--- any other, whether the change is made through `sys.chdir` looked up
--- at call time or through a reference the module took when it loaded:
--- what it read from there is keyed by where that is -- even past a
--- module that stubs `sys.getcwd` -- so it runs again when a file it
--- read changes, and never stands on a read outside the tree.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- Runs `cosmic test` on `root` with `words` after it -- `--all`, so a
--- test no key holds runs, unless others are given.
local function run(program: string, root: string, output: string,
                   env: {string:string}, fails?: boolean, words?: {string}): string
  local fd = assert(Fs.open_write(output))
  local argv: {string} = { program, "test" }
  for _, word in ipairs(words or { "--all" }) do argv[#argv + 1] = word end
  local result, trouble = Child.run(argv, {
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
  local env = observations.environment()
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

--- A test no key can hold -- this one reads outside its tree -- is
--- assumed to pass as it last did, until it, what it loads, or what of
--- its reads a key can hold (a file of the tree, a variable) changes, or
--- it is asked for: by --all, by COSMIC_TEST_ALL=1, or by name. One that
--- failed is never assumed.
local function test_a_test_no_key_holds_is_assumed_until_asked_for(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(tmp .. "/outside"))
  assert(Fs.write(tmp .. "/outside/f", "out\n"))
  assert(Fs.write(root .. "/suite/data.txt", "one\n"))
  local source = [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")

local function test_reads_outside()
  assert(Fs.read(assert(Env.get("OUTSIDE")) .. "/f") == "out\n")
  assert(Fs.read("suite/data.txt") ~= nil)
  assert(Env.get("FLAVOUR") ~= "sour")
end

local function test_plain()
  assert(1 + 1 == 2)
end
]]
  assert(Fs.write(root .. "/suite/outside_test.tl", source))
  local program = assert(Proc.executable())
  local env = observations.environment()
  env.OUTSIDE = tmp .. "/outside"
  env.COSMIC_TEST_ALL = nil
  env.FLAVOUR = "sweet"
  local function said(name: string, words: {string}, wanted: string, fails?: boolean)
    local text = run(program, root, tmp .. "/" .. name .. ".out", env, fails, words)
    assert(text:find(wanted, 1, true), name .. ": " .. text)
  end
  said("first", {}, "2 ran, 0 stood")
  said("second", {}, "0 ran, 1 stood, 1 assumed")
  said("all", { "--all" }, "1 ran, 1 stood")
  said("named", { "suite/outside_test.tl" }, "1 ran, 1 stood")
  env.COSMIC_TEST_ALL = "1"
  said("variable", {}, "1 ran, 1 stood")
  env.COSMIC_TEST_ALL = nil
  said("again", {}, "0 ran, 1 stood, 1 assumed")
  -- What of its reads a key can hold is still held: a file of the tree
  -- changed, or a variable it read, and it runs.
  assert(Fs.write(root .. "/suite/data.txt", "two\n"))
  said("data", {}, "1 ran, 1 stood")
  env.FLAVOUR = "sour"
  said("sour", {}, "1 of 2 failed", true)
  -- Failed, it is not assumed, however it is asked for next.
  said("failed", {}, "1 of 2 failed", true)
  env.FLAVOUR = "sweet"
  said("sweet", {}, "1 ran, 1 stood")
  -- Changed, it runs.
  assert(Fs.write(tmp .. "/outside/f", "changed\n"))
  assert(Fs.write(root .. "/suite/outside_test.tl", source .. "\n"))
  said("edited", {}, "1 of 2 failed", true)
end
