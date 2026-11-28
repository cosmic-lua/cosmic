--- Which paths of a tree `cosmic fix` leaves alone when it reads Markdown: the paths the tree's own `.gitignore` files
--- ignore and anything under a `node_modules/`. Only `fix` asks. The build, the link index and the projection never do,
--- so what they hold does not turn on git, on a user's excludes or on what the tree has ignored.
---
--- The result is the same on every host that holds the tree: git is asked with `--exclude-per-directory=.gitignore`
--- alone, so neither the user's global excludes (`core.excludesFile`), nor `.git/info/exclude`, nor the global or
--- system git configuration is read (the repository's own `.git/config` still is), and the `GIT_*` variables that could point it at another repository are cleared. Where git
--- cannot tell (it is not installed, the root is no repository, or it lies inside an ignored directory, which git
--- refuses) only `node_modules/` is left alone. Because the global configuration is not read, neither is the user's
--- `safe.directory`: in a repository another user owns git exits 128 ("dubious ownership"), and the `say` that
--- [`ignored.of`] is given hears of that fallback once.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")

local record ignored
  --- What [`ignored.of`] hears from git for the tree at `root`, as one text: whether git ran, its status, and what it
  --- listed and said. Two runs that hear the same text leave the same paths alone, so a verdict on the tree keys on it
  --- ([`build.fix.verdict`]).
  answer: function(root: string): string
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
  -- Git's refusal is matched by its English words.
  out["LC_ALL"] = "C"
  return out
end

--- What git answers when asked for the untracked, ignored paths of the tree at `root`; nil where it is not installed.
local function ask(root: string): Child.Result?
  local git, _ = Proc.find("git")
  if git == nil then return nil end
  local result, _ = Child.run({ git, "-C", root, "ls-files", "-z", "--others", "--ignored",
    "--exclude-per-directory=.gitignore", "--directory" }, { env = clean_env(), stdin = "null",
      stdout = "capture", stderr = "capture", timeout_ns = git_timeout_ns })
  return result
end

--- Whether the untracked, ignored paths of the tree at `root` can be had from git, and what they are: files by their path
--- from `root`, and directories (which git lists whole) by theirs.
local function listed(root: string, say?: function(string)): {string: boolean}?, {string: boolean}?
  local result = ask(root)
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

function ignored.answer(root: string): string
  local result = ask(root)
  if result == nil then return "no git" end
  return table.concat({ tostring(result.ok), tostring(result.code), tostring(result.timed_out), result.stdout or "",
    result.stderr or "" }, "\0")
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
