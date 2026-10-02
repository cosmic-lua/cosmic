--- Worked examples for [`cosmic.proc`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")

-- Account lookup can consult the host's directory service.
Test.needs{ system = true }

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

--- A command dispatcher chooses shell status 126 or 127 from the kind,
--- leaving the reason for a person. Resolution of an explicit path only
--- selects its spelling: starting that path can still fail.
function Example.find_result()
  local dir = assert(Fs.mkdtemp("cosmic-proc-example-"))
  assert(Fs.write(dir .. "/blocked", "", 0x180))
  local function status(name: string): integer
    local result = Proc.find_result(name, dir)
    if result.kind == "resolved" then
      print("selected", result.path)
      return 0
    end
    print(result.reason)
    return result.kind == "not_executable" and 126 or 127
  end
  assert(status("blocked") == 126)
  assert(status("missing") == 127)
  assert(status(dir .. "/missing") == 0)
  assert(Fs.remove_tree(dir))
end

--- Resolve an explicit account with [`Proc.user`] before configuring a
--- child's numeric identity. Missing and failed lookups are different.
function Example.user()
  local user, trouble = Proc.user("nobody")
  if user ~= nil then
    print("uid", user.uid, "gid", user.gid)
  elseif trouble == "" then
    print("no account named nobody")
  else
    error(trouble)
  end
end

return Example
