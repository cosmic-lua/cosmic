local Failure = require("cosmic.failure")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.policy{}

local function test_the_text_names_the_path_then_the_message()
  assert(tostring(Failure.new("not a number")) == "not a number")
  assert(tostring(Failure.new("not a number", "a.conf")) == "a.conf: not a number")
  local made = Failure.new("x")
  assert(made.errno == 0 and made.path == nil)
end

local function test_a_system_failure_keeps_its_errno_and_words()
  local made = Failure.system(sys.ENOENT, "/nowhere")
  assert(made.errno == sys.ENOENT)
  assert(made.message == sys.errno_message(sys.ENOENT))
  assert(tostring(made) == "/nowhere: " .. sys.errno_message(sys.ENOENT), tostring(made))
end

--- What a function that answers a value or a failure does with one: the
--- caller tests the cause by its errno and reads the text by `tostring`.
local function open(path: string): (integer) | (nil, Failure)
  local fd, _, errno = sys.open(path, sys.O_RDONLY)
  if fd == nil then
    return nil, Failure.system(errno, path)
  end
  return fd
end

local function test_a_caller_tells_the_cause_by_its_errno(tmp: string)
  local fd, why = open(tmp .. "/absent")
  if fd ~= nil then
    error("opened a path that is not there")
  end
  assert(why.errno == sys.ENOENT, tostring(why))
  assert(why.path == tmp .. "/absent")
  assert(tostring(why):find(": No such file or directory", 1, true) ~= nil, tostring(why))
end

local function test_a_raised_failure_reads_as_its_text()
  local ok, raised = pcall(function()
    error(Failure.new("refused", "here"))
  end)
  assert(not ok and tostring(raised) == "here: refused", tostring(raised))
end
