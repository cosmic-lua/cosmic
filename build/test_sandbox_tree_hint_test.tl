--- End to end, what a failure says of a file of the tree a sandboxed test
--- read by a relative path without declaring it: the file exists in the
--- tree and is not in the worker's sandbox, which only a run whose own
--- workers are sandboxed tells from a file that is not there.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local confine = require("build.confine")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")

--- `cosmic test` with sandboxed workers, nested in this test's own sandbox
--- (`nests`), and the variables that hold a run to sandboxing, which a
--- case whose run sandboxed none of its workers reads to skip.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
  env = { "COSMIC_SANDBOX", "COSMIC_TEST_SANDBOX" },
  timeout = 120,
}

local function test_an_undeclared_tree_file_read_by_a_relative_path_names_the_grant(tmp: string)
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/suite/data"))
  assert(Fs.write(root .. "/fixture.txt", "top\n"))
  assert(Fs.write(root .. "/suite/data/present.txt", "here\n"))
  assert(Fs.write(root .. "/suite/data/granted.txt", "granted\n"))
  assert(Fs.write(root .. "/suite/undeclared_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy { grants = { { path = "suite/data/granted.txt", letters = "r" } } }

local function test_top()
  assert(Fs.read("fixture.txt"))
end

local function test_nested()
  assert(Fs.read("suite/data/present.txt"))
end

local function test_absent()
  assert(Fs.read("suite/data/absent.txt"))
end

local function test_granted()
  assert(Fs.read("suite/data/granted.txt") == "granted\n")
end

local function test_url()
  error("http://example.com/fixture.txt: No such file or directory")
end
]]))
  local env = this_program.environment()
  env["COSMIC_VERDICT_CACHE"] = "0"
  env["COSMIC_TEST_ALL"] = nil
  env["COSMIC_SANDBOX"] = nil
  env["COSMIC_TEST_SANDBOX"] = nil
  local output = tmp .. "/out"
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "test", "--all" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true,
    timeout_ns = Clock.seconds(100),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil and not result.ok, tostring(trouble) .. text)
  if text:find("no worker can be sandboxed here", 1, true) then
    if assert(sys.uname()).sysname == "Linux" then Test.skip(confine.unsandboxed_reason(text)) end
    return
  end
  --- What the run said of `test`'s failure, up to where it says to rerun it.
  local function failure(name: string): string
    local said = text:match("FAIL  suite.undeclared_test " .. name .. "(.-)rerun:")
    assert(said ~= nil, name .. ": " .. text)
    return said
  end
  local function hint(path: string): string
    return path .. " is not in this test's sandbox, though it is in the tree: grant it in " ..
      "Test.policy { grants = { { path = \"" .. path .. "\", letters = \"r\" } } } " ..
      "(see cosmic docs cosmic.test)"
  end
  local top = failure("test_top")
  assert(top:find("fixture.txt: No such file or directory", 1, true), top)
  assert(top:find("\n  " .. hint("fixture.txt"), 1, true), top)
  local nested = failure("test_nested")
  assert(nested:find("\n  " .. hint("suite/data/present.txt"), 1, true), nested)
  -- Said once.
  local _, times = nested:gsub("is not in this test's sandbox", "")
  assert(times == 1, nested)
  -- A file that is not in the tree, a URL and a granted file are none of its business.
  for _, name in ipairs({ "test_absent", "test_url" }) do
    local said = failure(name)
    assert(not said:find("sandbox", 1, true), said)
  end
  assert(not text:find("FAIL  suite.undeclared_test test_granted", 1, true), text)
end
