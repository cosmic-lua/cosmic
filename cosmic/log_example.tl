--- Worked examples for [`cosmic.log`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Log = require("cosmic.log")

local Example = {}

--- A command's findings, on stdout.
function Example.say()
  local log = Log.new("notes")
  local wrote, trouble = log:say("1  buy milk")
  assert(wrote, trouble)
end

--- A failure names the program on stderr.
function Example.complain()
  local log = Log.new("notes")
  log:complain("no such note: 9")
  assert(log.name == "notes")
end

return Example
