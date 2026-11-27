--- What the shop-git-commit check prints, from cosmic.git: the last two subjects, the paths HEAD changed, what is
--- left uncommitted, who committed, HEAD's parent, and whether every object HEAD reaches reads.
local Git = require("cosmic.git")

local repo = assert(Git.open("."))
local commits = assert(repo:log({ limit = 2 }))
for _, c in ipairs(commits) do print((c.message:match("^[^\n]*"))) end
local head, parent = commits[1]!, commits[2]!

--- Each path under `tree` with the oid it holds, into `out`.
local function paths(tree: string, prefix: string, out: mut {string: string})
  for _, entry in ipairs(assert(repo:tree(tree))) do
    if entry.mode == "40000" then
      paths(entry.oid, prefix .. entry.name .. "/", out)
    else
      assert(repo:read(entry.oid))
      out[prefix .. entry.name] = entry.oid
    end
  end
end
local now: mut {string: string} = {}
local was: mut {string: string} = {}
paths(head.tree, "", now)
paths(parent.tree, "", was)
local changed: mut {string} = {}
for path, oid in pairs(now) do
  if was[path] ~= oid then table.insert(changed, path) end
end
for path in pairs(was) do
  if now[path] == nil then table.insert(changed, path) end
end
table.sort(changed)
for _, path in ipairs(changed) do print(path) end
local status = assert(repo:status())
for _, c in ipairs(status.staged) do print("staged " .. c.path) end
for _, c in ipairs(status.unstaged) do print("unstaged " .. c.path) end
for _, path in ipairs(status.untracked) do print("untracked " .. path) end
print(head.author.name .. " <" .. head.author.email .. ">")
print(parent.oid)
print("sound")
