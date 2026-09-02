--- The owner rule an item's `repo` field meets: the repository a diff
--- lands in must share the board's own GitHub owner, or the spec must
--- name it under `## Access`. A claiming session is granted the
--- board's repositories and nothing this board can see beyond them,
--- so a `repo` under a foreign owner — a personal fork's name left
--- over from when the evidence was gathered, most often — strands the
--- claim before it starts. The owner is the proxy the board CAN
--- check; the `## Access` declaration is the deliberate cross-owner
--- case, stated where the reader of the spec will see it.
---
--- One rule, applied at both ends: `ready_problems` asks it of every
--- item before a take (stale data already on the board), and `new
--- --repo` and `set --repo` ask it before the write lands (stale data
--- entering). A board whose origin does not resolve to a GitHub slug
--- has no owner to compare against and skips the rule — the same
--- local-only waiver the handover gate uses.
local gh = require("_work.gh")
local spec = require("_work.spec")
local store = require("_work.store")

--- The board's own GitHub owner — the owner half of `gh.slug`'s
--- reading of the origin remote — or nil when the origin is missing
--- or is not a GitHub remote.
--- @param s store.Store The store
--- @return string | nil The owner, as the remote spells it
local function board_owner(s: store.Store): string | nil
  local slugged, _err = gh.slug(s, nil)
  if slugged == nil then
    return nil
  end
  return slugged:match("^([^/]+)/")
end

--- The problem a `repo` earns under the owner rule, or nil when it
--- passes: unset, sharing the board's owner (case-insensitively, as
--- GitHub compares), named under the spec's `## Access`, or asked on
--- a board with no owner to compare against. The problem names the
--- field, the value, and the repair: `gitboard set ID --repo` when
--- the item is already filed, the `--repo` flag itself when `new` is
--- about to file it (`id` is "").
--- @param s store.Store The store
--- @param repo string The item's repo field, "" when unset
--- @param body string The spec the rule reads `## Access` from
--- @param id string The item's full id, "" for an item not yet filed
--- @return string | nil The problem
local function repo_problem(s: store.Store, repo: string, body: string,
    id: string): string | nil
  if (repo or "") == "" then
    return nil
  end
  local owner = board_owner(s)
  if owner == nil then
    return nil
  end
  local repo_owner, name = repo:match("^([^/]+)/(.+)$")
  if repo_owner == nil or repo_owner:lower() == owner:lower() then
    return nil
  end
  if spec.declared_repos(body or "")[repo:lower()] then
    return nil
  end
  local repair = ("pass --repo %s/%s"):format(owner, name)
  if (id or "") ~= "" then
    repair = ("`gitboard set %s --repo %s/%s`"):format(id:sub(1, 8), owner, name)
  end
  return ("repo: %s is under %s, not this board's owner %s — a claiming "
    .. "session is granted the board's repositories, so the field most "
    .. "likely names a fork the session cannot reach; %s, or name %s "
    .. "under \"## Access\" when the cross-owner target is deliberate")
  :format(repo, repo_owner, owner, repair, repo)
end

local record gitowner
  board_owner: function(s: store.Store): string | nil
  repo_problem: function(s: store.Store, repo: string, body: string,
  id: string): string | nil
end

local M: gitowner = {
  board_owner = board_owner,
  repo_problem = repo_problem,
}

return M
