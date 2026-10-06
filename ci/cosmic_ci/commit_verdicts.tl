--- The verdicts main saves under each commit, for a branch based on it:
--- `merge-base`, which finds the main commit a run's tree grew from,
--- and `prune`, which deletes those entries a day on. Both ask the API
--- through [`Github.Host`] and never fail their step: a base not found,
--- or an entry left, costs time or space, never a result.
---
--- `merge_base`: the main commit a run's tree grew from, whose own
--- verdicts ci.yml's "restore test verdicts" takes before main's newest:
--- main's push of each commit saves a copy of its verdicts keyed by the
--- commit (`<prefix>sha-<commit>`), and a branch several commits behind
--- main stands on far more of its base's verdicts than of main's newest,
--- whose tree it does not have. EVENT is the run's event
--- (github.event_name) and REF its ref. A push to a branch other than
--- main asks the API (GH_TOKEN, with contents: read) for the merge base
--- of main and SHA in REPOSITORY, which needs no history in the
--- checkout; the merge queue's run takes its base, QUEUE_BASE
--- (github.event.merge_group.base_sha), with no call. It writes
--- `sha=<base>` to $GITHUB_OUTPUT (standard output, for a run by hand),
--- or nothing: on main, on another event, and wherever the lookup fails
--- or answers no commit, the restore takes main's newest. The call is cut
--- off after CALL_SECONDS (15).
---
--- `prune`: deletes the copies of main's verdicts keyed by a commit
--- (`verdicts-...-sha-<commit>`, which ci.yml saves beside each
--- content-keyed entry so a branch restores its merge base's) once they
--- are older than HOURS (24 by default): each is some 11 MB a leg a main
--- push, and the repository's 10 GB cache, once full, evicts the least
--- recently used entries, the zig outputs and the fuzz corpora among them
--- (README.md's "the caches"). A branch based on a commit older than that
--- restores main's newest verdicts. It deletes too the compiles a branch's
--- push saves for its later pushes (`compiles-branch-...`, some 5 MB a
--- leg, saved where a change to the compiler moved every compile's key)
--- once they are older than HOURS: a later push of that branch restores
--- main's, and saves its own again. ci.yml's `prune` job runs it on a
--- push to main (GH_TOKEN, with actions: write), against REPOSITORY. Each
--- call is cut off after CALL_SECONDS. An entry left is only space, which
--- the cache's own eviction reclaims.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Github = require("cosmic_ci.github")
local Plural = require("cosmic_ci.plural")
local Time = require("cosmic.time")

local record CommitVerdicts
  merge_base: function(env: {string:string}, host: Github.Host): integer
  prune: function(env: {string:string}, host: Github.Host): integer
  --- `driver.tl merge-base` and `prune-commit-verdicts`, in the process's
  --- environment.
  merge_base_command: function(argv: {string}): integer
  prune_command: function(argv: {string}): integer
end

--- A whole number of `name` in `env`, `default` where it names none, nil
--- and why where it is no whole number.
local function whole(env: {string:string}, name: string, default: integer): integer | nil, string
  local text = env[name]
  if text == nil or text == "" then return default, "" end
  local value = math.tointeger(tonumber(text))
  if value == nil or value < 0 then return nil, name .. " is no whole number: " .. text end
  return value, ""
end

function CommitVerdicts.merge_base(env: {string:string}, host: Github.Host): integer
  local call, why = whole(env, "CALL_SECONDS", 15)
  if call == nil then
    local _, _ = Fs.put(Fs.stderr, "merge-base: " .. why .. "\n")
    return 2
  end
  local base = ""
  local event, ref = env.EVENT or "", env.REF or ""
  if event == "merge_group" then
    base = env.QUEUE_BASE or ""
  elseif event == "push" and ref ~= "refs/heads/main" then
    local pages = Github.ask(host, "repos/" .. (env.REPOSITORY or "") .. "/compare/main..." .. (env.SHA or "") ..
        "?per_page=1", false, call)
    local commit = pages and pages[1] and type(pages[1]) == "table" and
      (pages[1] as {string:any}).merge_base_commit or nil
    local sha = type(commit) == "table" and (commit as {string:any}).sha or nil
    if sha is string then base = sha end
  end
  if Github.is_commit(base) then
    host.output("sha=" .. base)
    host.print("the tree's base on main: " .. base)
  else
    host.print("no base on main found: the restore takes main's newest verdicts")
  end
  return 0
end

--- Deletes each entry of the cache's listing under `prefix` that `wanted`
--- names (by id), and says how many as `entry`, in the plural `entries`.
--- `wanted` answers whether an entry of the listing is to go, nil where
--- it cannot tell.
local function prune(host: Github.Host, repository: string, call: integer, hours: integer,
                     prefix: string, entry: string, entries: string, wanted: function(entry: {string:any}): boolean | nil)
  local pages = Github.ask(host, "repos/" .. repository .. "/actions/caches?key=" .. prefix .. "&per_page=100", true, call)
  local ids: {string} = {}
  local listed = pages ~= nil
  for _, page in ipairs(pages or {}) do
    local list = type(page) == "table" and (page as {string:any}).actions_caches or nil
    if type(list) ~= "table" then
      listed = false
      break
    end
    for _, item in ipairs(list as {any}) do
      local go: boolean | nil = nil
      if type(item) == "table" then go = wanted(item as {string:any}) end
      if go == nil then
        listed = false
        break
      end
      if go then
        local raw = (item as {string:any}).id
        local id = raw is number and math.tointeger(raw) or nil
        if id == nil then
          listed = false
          break
        end
        ids[#ids + 1] = tostring(id)
      end
    end
    if not listed then break end
  end
  if not listed then
    host.print("could not list the cache's " .. entries .. ": none pruned")
    return
  end
  local deleted, failed = 0, 0
  for _, id in ipairs(ids) do
    if host.delete("repos/" .. repository .. "/actions/caches/" .. id, call) then
      deleted = deleted + 1
    else
      failed = failed + 1
    end
  end
  host.print("pruned " .. Plural.count(deleted, entry, entries) .. " older than " .. hours .. " h (" .. failed ..
      " failed)")
end

--- Whether `entry`'s `created_at`, an RFC 3339 time (with the
--- milliseconds the API writes, or none), is before `cutoff` seconds
--- since the epoch; nil where it holds none.
local function older(entry: {string:any}, cutoff: integer): boolean | nil
  local created = entry.created_at
  if not (created is string) then return nil end
  local ns = Time.parse_rfc3339(created)
  if ns == nil then return nil end
  return ns // 1000000000 < cutoff
end

--- Whether `key` ends in `-sha-` and a whole commit id.
local function under_a_commit(key: string): boolean
  local tail = key:sub(-45)
  return #tail == 45 and tail:match("^%-sha%-[0-9a-f]+$") ~= nil
end

function CommitVerdicts.prune(env: {string:string}, host: Github.Host): integer
  local hours, why = whole(env, "HOURS", 24)
  local call: integer | nil
  if hours ~= nil then call, why = whole(env, "CALL_SECONDS", 15) end
  if hours == nil or call == nil then
    local _, _ = Fs.put(Fs.stderr, "prune-commit-verdicts: " .. why .. "\n")
    return 2
  end
  local repository = env.REPOSITORY or ""
  local cutoff = host.now() - hours * 3600
  prune(host, repository, call, hours, "verdicts-", "commit-keyed verdict entry", "commit-keyed verdict entries", function(entry: {string:any}): boolean | nil
    local key = entry.key
    if not (key is string) then return nil end
    if not under_a_commit(key) then return false end
    return older(entry, cutoff)
  end)
  prune(host, repository, call, hours, "compiles-branch-", "branch compiles entry", "branch compiles entries", function(entry: {string:any}): boolean | nil
    local key = entry.key
    if not (key is string) then return nil end
    if key:sub(1, 16) ~= "compiles-branch-" then return false end
    return older(entry, cutoff)
  end)
  return 0
end

function CommitVerdicts.merge_base_command(_argv: {string}): integer
  local env = Env.all()
  return CommitVerdicts.merge_base(env, Github.live(env))
end

function CommitVerdicts.prune_command(_argv: {string}): integer
  local env = Env.all()
  return CommitVerdicts.prune(env, Github.live(env))
end

return CommitVerdicts
