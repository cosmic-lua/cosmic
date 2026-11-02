--- Which paths of a tree `cosmic fix` leaves alone when it reads Markdown: the paths the tree's own `.gitignore` files
--- ignore and anything under a `node_modules/`. Only `fix` asks. The build, the link index and the projection never do,
--- so what they hold does not turn on git, on a user's excludes or on what the tree has ignored.
---
--- The answer is the same on every host that holds the tree: git is asked with `--exclude-per-directory=.gitignore`
--- alone, so neither the user's global excludes (`core.excludesFile`), nor `.git/info/exclude`, nor the global or
--- system git configuration is read (the repository's own `.git/config` still is), and the `GIT_*` variables that could point it at another repository are cleared. Where git
--- cannot answer (it is not installed, the root is no repository, or it lies inside an ignored directory, which git
--- refuses) only `node_modules/` is left alone. Because the global configuration is not read, neither is the user's
--- `safe.directory`: in a repository another user owns git exits 128 ("dubious ownership"), and the `say` that
--- [`ignored.of`] is given hears of that fallback once.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")

local record ignored
end

--- How long asking git may take: a local listing of the tree.
local git_timeout_ns <const> = Clock.seconds(30)

--- The environment git runs in: the process's, without any `GIT_*` variable (a hook's `GIT_DIR` would name another
--- repository), and with no configuration file read.
local function clean_env(): {string: string}
  local out: mut {string: string} = {}
  for name, value in pairs(Env.all()) do
    if name:sub(1, 4) ~= "GIT_" then out[name] = value end
  end
  out["GIT_CONFIG_GLOBAL"] = "/dev/null"
  out["GIT_CONFIG_SYSTEM"] = "/dev/null"
  out["GIT_CONFIG_NOSYSTEM"] = "1"
  out["GIT_TERMINAL_PROMPT"] = "0"
  return out
end

--- Whether the untracked, ignored paths of the tree at `root` can be had from git, and what they are: files by their path
--- from `root`, and directories (which git lists whole) by theirs.
local function listed(root: string, say?: function(string)): {string: boolean}?, {string: boolean}?
  local git, _ = Proc.find("git")
  if git == nil then return nil, nil end
  local result, _ = Child.run({ git, "-C", root, "ls-files", "-z", "--others", "--ignored",
    "--exclude-per-directory=.gitignore", "--directory" }, { env = clean_env(), stdin = "null",
      stdout = "capture", stderr = "capture", timeout_ns = git_timeout_ns })
  if result == nil or result.timed_out then return nil, nil end
  if not result.ok then
    if say ~= nil and (result.stderr or ""):find("dubious ownership", 1, true) ~= nil then
      say("git refused to list the ignored paths of " .. root .. " (dubious ownership: another user owns the " ..
          "repository, and the user's safe.directory is not read), so only node_modules/ is left alone")
    end
    return nil, nil
  end
  local files: mut {string: boolean} = {}
  local directories: mut {string: boolean} = {}
  for path in (result.stdout or ""):gmatch("[^%z]+") do
    if path:sub(-1) == "/" then
      directories[path:sub(1, -2)] = true
    else
      files[path] = true
    end
  end
  return files, directories
end

--- A test of whether a path under `root`, given from it, is left alone. Git is asked once, at the first path. `say` is
--- given one line when git refuses the repository for its owner, which the fallback to `node_modules/` alone would
--- otherwise hide.
function ignored.of(root: string, say?: function(string)): function(string): boolean
  local files: {string: boolean}? = nil
  local directories: {string: boolean}? = nil
  local asked = false
  return function(path: string): boolean
    if ("/" .. path .. "/"):find("/node_modules/", 1, true) ~= nil then return true end
    if not asked then
      asked = true
      files, directories = listed(root, say)
    end
    local known, whole = files, directories
    if known == nil or whole == nil then return false end
    if known[path] == true or whole[path] == true then return true end
    local at = 0
    while true do
      at = path:find("/", at + 1, true) or 0
      if at == 0 then return false end
      if whole[path:sub(1, at - 1)] == true then return true end
    end
  end
end

return ignored
