--- Makes a test's directory reachable by the user a policy's child runs
--- as where the runner is root ([`Child.start`]'s `policy`): a user that
--- owns none of the host's files, so it searches only the directories
--- every user may. A test's own are private to their owner, so a test that
--- grants a path beneath one without `isolate` file opens them first.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local record searchable
end

--- Adds search for every user to `dir` and each directory above it that
--- lacks it and this process may change; the others stay as they are.
--- Answers `dir`.
function searchable.open(dir: string): string
  local above = dir
  while above ~= "/" and above ~= "." do
    local st, _ = sys.stat(above)
    if st ~= nil and st.mode & 1 == 0 then
      local _, _ = sys.chmod(above, st.mode & 4095 | 5)
    end
    above = Fs.dirname(above)
  end
  return dir
end

--- Adds read, write and, for a directory, search for every user to `path`,
--- which a test grants writable: the user of a root caller's child owns
--- nothing there. Answers `path`.
function searchable.share(path: string): string
  local st, _ = sys.stat(path)
  if st ~= nil then
    local _, _ = sys.chmod(path, st.mode & 4095 | (st.kind == "dir" and 7 or 6))
  end
  return path
end

return searchable
