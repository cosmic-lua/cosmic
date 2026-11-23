--- Whether a path is there, for ci/, which runs on the release that
--- ci/cosmic-driver.pin names as well as on the tree's own cosmic: this
--- asks [`sys.stat`], which both have, since the status call of the tree's cosmic.fs is
--- not in that release.
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

local record Predicate
end

--- Whether anything is at `path`, false where it or a parent of it is
--- missing; nil and why where it cannot be looked at.
function Predicate.there(path: string): boolean?, string
  local st, why, errno = sys.stat(path)
  if st ~= nil then return true, "" end
  if errno == sys.ENOENT or errno == sys.ENOTDIR then return false, "" end
  return nil, path .. ": " .. why
end

--- Whether a directory is at `path`; nil and why where it cannot be
--- looked at.
function Predicate.directory(path: string): boolean?, string
  local st, why, errno = sys.stat(path)
  if st ~= nil then return st.kind == "dir", "" end
  if errno == sys.ENOENT or errno == sys.ENOTDIR then return false, "" end
  return nil, path .. ": " .. why
end

--- Whether anything is at `path`; raises where it cannot be looked at.
function Predicate.exists(path: string): boolean
  local answer, trouble = Predicate.there(path)
  assert(answer ~= nil, trouble)
  return answer
end

--- Whether a directory is at `path`; raises where it cannot be looked at.
function Predicate.is_dir(path: string): boolean
  local answer, trouble = Predicate.directory(path)
  assert(answer ~= nil, trouble)
  return answer
end

--- Whether `path` has no status: nothing is there, or it cannot be looked at.
function Predicate.absent(path: string): boolean
  local status, _ = Fs.stat(path)
  return status == nil
end

return Predicate
