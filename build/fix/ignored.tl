--- Which paths of a tree `cosmic fix` leaves alone when it reads Markdown: the paths the tree's own `.gitignore` files
--- ignore and anything under a `node_modules/`. Only `fix` asks. The build, the link index and the projection never do,
--- so what they hold does not turn on git, on a user's excludes or on what the tree has ignored.
---
--- The result is the same on every host that holds the tree: [`cosmic.git`] reads the tree's own `.gitignore` files
--- alone, with no git program, so neither the user's global excludes (`core.excludesFile`), nor `.git/info/exclude`,
--- nor the global or system git configuration is read. Where the tree cannot be read as a repository (the root is no
--- repository, or its index cannot be read) only `node_modules/` is left alone, and the `say` that [`ignored.of`] is
--- given hears of that once. A project below the repository's top is read with the `.gitignore` files above it.

local Fs = require("cosmic.fs")
local Git = require("cosmic.git")

local record ignored
  --- What [`ignored.of`] reads of the tree at `root`, as one text: the paths it leaves alone, or why it could read none.
  --- Two runs that read the same text leave the same paths alone, so a verdict on the tree keys on it
  --- ([`build.fix.verdict`]).
  answer: function(root: string): string
end

--- Whether the untracked, ignored paths of the tree at `root` can be had, and what they are: files by their path from
--- `root`, and directories (which are listed whole) by theirs.
local function listed(root: string, say?: function(string)): {string: boolean}?, {string: boolean}?
  -- `plain`: no GIT_DIR or GIT_WORK_TREE of a hook may name another repository.
  local opened, _ = Git.open(root, true)
  local function unread(trouble: any): {string: boolean}?, {string: boolean}?
    if say ~= nil and trouble ~= nil then
      say("the ignored paths of " .. root .. " cannot be read (" .. tostring(trouble) ..
          "), so only node_modules/ is left alone")
    end
    return nil, nil
  end
  -- No repository there is no trouble to tell of: the project is not under git.
  if opened == nil then return nil, nil end
  local all, trouble = opened:ignored()
  if all == nil then return unread(trouble) end
  -- The paths come from the top of the worktree, and the project may lie below it.
  local absolute, _ = Fs.absolute(root)
  local below, _ = Fs.relative(absolute or root, opened.worktree)
  local prefix = if below == nil or below == "." or below == "" then "" else below .. "/" end
  local paths: mut {string} = {}
  for _, path in ipairs(all) do
    if path:sub(1, #prefix) == prefix then paths[#paths + 1] = path:sub(#prefix + 1) end
  end
  local files: mut {string: boolean} = {}
  local directories: mut {string: boolean} = {}
  for _, path in ipairs(paths) do
    if path:sub(-1) == "/" then
      directories[path:sub(1, -2)] = true
    else
      files[path] = true
    end
  end
  return files, directories
end

function ignored.answer(root: string): string
  local said: mut {string} = {}
  local files, directories = listed(root, function(line: string)
    said[#said + 1] = line
  end)
  if files == nil or directories == nil then
    return "unread\0" .. table.concat(said, "\0")
  end
  local out: mut {string} = {}
  for path in pairs(files) do
    out[#out + 1] = "f " .. path
  end
  for path in pairs(directories) do
    out[#out + 1] = "d " .. path
  end
  table.sort(out)
  return table.concat(out, "\0")
end

--- A test of whether a path under `root`, given from it, is left alone. The tree is read once, at the first path.
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
