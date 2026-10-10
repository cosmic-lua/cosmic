--- Where cosmic keeps what it builds for a project: its build
--- directory, which a project's tests name `o` (`o/cosmic.db`, a grant
--- of `o/...` in [`Test.policy`]). It lies outside the project's sources,
--- under the absolute base `COSMIC_BUILD_HOME` names, or
--- `$XDG_CACHE_HOME/cosmic/trees` (`$HOME/.cache/cosmic/trees` without
--- it), in a directory of the project's own: every link to a root names
--- that root's, and no two roots share one, under one base or not.
---
---     local location = assert(Project.directory("."))
---     assert(location.none == "", location.none)
---     local projection = location.directory .. "/cosmic.db"

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")

local record Project
  --- Where [`Project.directory`] puts a project's build, or why there
  --- can be none here.
  record Location
    --- The absolute path of the build directory; "" where `none` says
    --- why there is none.
    directory: string
    --- Why there can be no build directory for this root here, where
    --- that is no configuration to fix: there is no cache directory to
    --- put it in and COSMIC_BUILD_HOME is not set, or it would be inside
    --- the root. "" where there is one.
    none: string
  end
end

--- `path` with its links resolved, or, where it does not exist yet, its
--- nearest existing ancestor's so resolved with the rest appended: a base
--- that is still to be made names the same directory from every working
--- directory and through every link to it.
local function named(path: string): string | nil, string
  local found, trouble = sys.realpath(path)
  if found ~= nil then return found, "" end
  local _, stat_trouble, errno = sys.stat(path)
  if errno ~= sys.ENOENT then return nil, path .. ": " .. (stat_trouble or trouble) end
  local parent = Fs.dirname(path)
  if parent == path then return nil, path .. ": " .. trouble end
  local resolved, resolve_trouble = named(parent)
  if resolved == nil then return nil, resolve_trouble end
  local name = path:match("([^/]+)/*$") or ""
  if name == "." then return resolved, "" end
  if name == ".." then return Fs.dirname(resolved), "" end
  return (resolved == "/" and "" or resolved) .. "/" .. name, ""
end

--- Whether the directory at `path`, where there is one, is one to keep
--- builds in: this user's and writable by no one else, since a later run
--- executes the tool kept there.
local function trusted(path: string): boolean, string
  local st, trouble, errno = sys.stat(path)
  if st == nil then
    if errno == sys.ENOENT then return true, "" end
    return false, path .. ": " .. trouble
  end
  if st.kind ~= "dir" then return false, path .. ": not a directory" end
  if st.uid ~= sys.getuid() then return false, path .. ": owned by another user" end
  if st.mode & 0x12 ~= 0 then return false, path .. ": writable by its group or others" end
  return true, ""
end

--- The absolute path of the build directory of the project at `root`,
--- named without making it or anything above it; it may not be there
--- yet. `environment` is the variables to read (`COSMIC_BUILD_HOME`,
--- `XDG_CACHE_HOME`, `HOME`), by default the process's own. Where there
--- is no cache directory to put it in, or it would be inside `root`, the
--- location's `none` says so. Nil and why, something to fix, where
--- `root` is no directory, COSMIC_BUILD_HOME is set but not absolute, or
--- the base or the directory is not this user's alone.
function Project.directory(root: string, environment?: {string:string}):
    Project.Location | nil, string
  if root == "" then return nil, "project root is empty" end
  local canonical, root_trouble = sys.realpath(root)
  if canonical == nil then return nil, "project root " .. root .. ": " .. root_trouble end
  local root_stat, root_stat_trouble = sys.stat(canonical)
  if root_stat == nil then return nil, canonical .. ": " .. root_stat_trouble end
  if root_stat.kind ~= "dir" then
    return nil, canonical .. ": the project root is not a directory"
  end
  local given: string
  if environment ~= nil then
    given = environment.COSMIC_BUILD_HOME or ""
  else
    given = Env.get_or("COSMIC_BUILD_HOME", "")
  end
  local home: string
  local cache = given == ""
  if cache then
    local selected, home_trouble = Fs.cache_dir("trees",
      { environment = environment, make = false })
    if selected == nil then
      return { directory = "", none = "no build directory for " .. canonical .. ": " ..
          home_trouble .. "; set COSMIC_BUILD_HOME to an absolute directory" }, ""
    end
    home = selected
  elseif given:sub(1, 1) ~= "/" then
    return nil, "COSMIC_BUILD_HOME=" .. given .. " is not an absolute path"
  else
    home = given
  end
  local where = cache and "build directory base " or "COSMIC_BUILD_HOME "
  local base, base_trouble = named(home)
  if base == nil then return nil, where .. base_trouble end
  local valid, trust_trouble = trusted(base)
  if not valid then return nil, where .. trust_trouble end
  local output = (base:gsub("/+$", "")) .. "/" .. Hash.hex_sha256(canonical)
  if Fs.within(output, canonical) then
    return { directory = "", none = "the build directory " .. output ..
        " is inside the project root " .. canonical ..
        "; set COSMIC_BUILD_HOME to a directory outside it" }, ""
  end
  local output_valid, output_trouble = trusted(output)
  if not output_valid then return nil, "build directory " .. output_trouble end
  return { directory = output, none = "" }, ""
end

return Project
