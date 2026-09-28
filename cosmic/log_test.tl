--- `cosmic.log`'s loggers, in this process: a name is required, and a
--- write says whether it landed. cosmic/log_tool_test.tl holds where
--- each line goes, which a script run by this program shows.

local function test_a_logger_needs_a_name()
  local Log = require("cosmic.log")
  assert(not pcall(Log.new, ""))
  assert(Log.new("x").name == "x")
end

local function test_a_write_answers_whether_it_landed()
  local Log = require("cosmic.log")
  local log = Log.new("x")
  local ok, trouble = log:verdict("t", true, "a write to stdout")
  assert(ok and trouble == "", trouble)
end
