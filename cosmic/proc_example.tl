--- Worked examples for `cosmic.proc`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

local Example = {}

--- Colour and progress lines are for a person at a terminal: when
--- standard output is a pipe or a file, write plain lines instead.
function Example.is_tty()
  if Proc.is_tty(Fs.stdout) then
    print("\27[1mbold, for a terminal\27[0m")
  else
    print("plain, for a pipe or a file")
  end
end

return Example
