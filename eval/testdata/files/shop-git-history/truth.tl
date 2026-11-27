--- The right answer to shop-git-history, from cosmic.git: the subject of each commit on `main` that changed
--- money.tl, newest first.
local Git = require("cosmic.git")

local repo = assert(Git.open("."))

local function money(tree: string): string?
  for _, entry in ipairs(assert(repo:tree(tree))) do
    if entry.name == "money.tl" then return entry.oid end
  end
  return nil
end

for _, c in ipairs(assert(repo:log())) do
  local before: string? = nil
  local first = c.parents[1]
  if first ~= nil then before = money(assert(repo:commit_info(first)).tree) end
  if money(c.tree) ~= before then print((c.message:match("^[^\n]*"))) end
end
