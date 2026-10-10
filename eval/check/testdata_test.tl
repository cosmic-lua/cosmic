--- The hidden API tests under testdata/ run in the grader's regime and in
--- a solver's alike (unsandboxed, [`Grader.unsandboxed`]), so a test that
--- reaches the network or a child process must still declare it, to pass
--- on a host where `cosmic test` sandboxes its workers.
local Fs = require("cosmic.fs")
local String = require("cosmic.string")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "eval/check/testdata/", letters = "r" } } }

--- The text of every hidden API test, by file name, comment lines left out.
local function sources(): {string:string}
  local found: {string:string} = {}
  for _, entry in ipairs((assert(Fs.list("eval/check/testdata")))) do
    if entry:match("_api_test%.tl$") then
      local text = assert(Fs.read("eval/check/testdata/" .. entry))
      local lines: {string} = {}
      for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if not String.trim(line):match("^%-%-") then lines[#lines + 1] = line end
      end
      found[entry] = table.concat(lines, "\n")
    end
  end
  return found
end

local function test_there_are_hidden_tests_to_hold()
  local count = 0
  for _ in pairs(sources()) do count = count + 1 end
  assert(count >= 6, "found " .. count)
end

local function test_no_hidden_test_listens_on_a_socket_file()
  for name, text in pairs(sources()) do
    assert(not text:find("%.unix%("), name .. " names a unix socket: use loopback TCP and declare it")
  end
end

--- The modules that reach the network or start a process.
local reaching = { "net", "http", "child", "proc", "sandbox", "sys" }

local function test_a_hidden_test_that_reaches_the_network_or_children_declares_a_policy()
  for name, text in pairs(sources()) do
    for _, module in ipairs(reaching) do
      if text:find('require%("cosmic%.' .. module .. '"%)') then
        assert(text:find("\nTest.policy", 1, true) or text:sub(1, 11) == "Test.policy",
          name .. " requires cosmic." .. module .. " without a top-level Test.policy")
      end
    end
  end
end
