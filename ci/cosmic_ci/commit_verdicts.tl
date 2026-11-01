--- The verdicts main names under each commit, for a branch based on it:
--- `merge-base`, which finds the main commit a run's tree grew from,
--- `prune`, which deletes those entries a day on, and `invalidate`, which
--- deletes them all after a failed run. All ask the API
--- through [`Github.Host`] and never fail their step: a base not found,
--- or an entry left, costs time or space, never a result.
---
--- `merge_base`: the main commit a run's tree grew from, whose own
--- verdicts ci.yml's "restore test verdicts" takes before main's newest:
--- main's push of each commit saves its verdicts once, keyed by their
--- content (`<prefix><digest>`), and names that entry under the commit
--- with a tiny one of its own (`<prefix>sha-<commit>-<digest>`, from
--- another path, so another version), which the restore looks up by the
--- prefix `<prefix>sha-<base>-`, downloading nothing, to take the entry
--- its digest names. A branch several commits behind main stands on far
--- more of its base's verdicts than of main's newest, whose tree it does
--- not have. EVENT is the run's event
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
--- `prune`: deletes main's entries under a commit
--- (`verdicts-...-sha-<commit>-<digest>`, which name the content-keyed
--- entry a branch based on the commit restores) once they are older than
--- HOURS (24 by default), as it did the whole copies once saved there
--- (`verdicts-...-sha-<commit>`, some 11 MB a leg a main push): the
--- repository's 10 GB cache, once full, evicts the least recently used
--- entries, the zig outputs and the fuzz corpora among them (README.md's
--- "the caches"), and the content-keyed entry a name keeps in use is
--- room too. A branch based on a commit older than that restores main's
--- newest verdicts. It deletes too the compiles a branch's
--- push saves for its later pushes (`compiles-branch-...`, some 5 MB a
--- leg, saved where a change to the compiler moved every compile's key)
--- once they are older than HOURS: a later push of that branch restores
--- main's, and saves its own again. ci.yml's `prune` job runs it on a
--- push to main (GH_TOKEN, with actions: write), against REPOSITORY. Each
--- call is cut off after CALL_SECONDS. An entry left is only space, which
--- the cache's own eviction reclaims.
---
--- `invalidate`: deletes main's entries under COMMIT (a whole commit id,
--- github.sha; refused otherwise), whatever their age and host, after a
--- run of that commit that saves them failed. A forced recheck (the
--- scheduled run stands on no verdict) that finds a test failing takes
--- its passing row out of its own database and saves those rows by their
--- content, which a new name under the commit names; but a leg that
--- stopped before its trim names none, and its commit's first run's name
--- would still lead a branch based on the commit to the entry that holds
--- the pass. With the names gone the restore takes the newest by prefix,
--- which is the failed run's own save, kept: it is the evidence of the
--- failure. Every host's go, not only the failed leg's: the job cannot
--- tell which leg failed, and an entry deleted costs a branch some
--- verdicts to run again, never a result. ci.yml's `invalidate` job runs
--- it after every job that saves.
--- TODO: delete too the content-keyed entries the deleted names lead to
--- that the failed run did not save, once the job is given the digests
--- that run's legs saved (a job output of each): another commit whose run
--- stood on the same rows names the same entry, and its branches still
--- stand on the pass.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Github = require("cosmic_ci.github")
local Plural = require("cosmic_ci.plural")
local Shape = require("cosmic.shape")
local Time = require("cosmic.time")
local StepEnv = require("cosmic_ci.step_env")

local record CommitVerdicts
  merge_base: function(env: {string:string}, host: Github.Host): integer
  prune: function(env: {string:string}, host: Github.Host): integer
  invalidate: function(env: {string:string}, host: Github.Host): integer
  --- `driver.tl merge-base`, `prune-commit-verdicts` and
  --- `invalidate-commit-verdicts`, in the process's environment.
  merge_base_command: function(argv: {string}): integer
  prune_command: function(argv: {string}): integer
  invalidate_command: function(argv: {string}): integer
end

--- The part of the API's comparison of main with a commit that names the
--- commit the tree grew from.
local record BaseCommit
  sha: string
end
local record Comparison
  merge_base_commit?: BaseCommit
end
local COMPARISON <const> = Shape.record_of("Comparison")

--- One entry of the cache's listing, whose fields the API's schema types
--- and the lookups below test for what they need.
local record CacheEntry
  key?: any
  created_at?: any
  id?: any
end
--- One page of the cache's listing.
local record CachePage
  actions_caches: {CacheEntry}
end
local CACHE_PAGE <const> = Shape.record_of("CachePage")

local whole <const> = StepEnv.whole

function CommitVerdicts.merge_base(env: {string:string}, host: Github.Host): integer
  local call, why = whole(env, "CALL_SECONDS", 15)
  if call == nil then
    local _, _ = Fs.put(Fs.stderr, "merge-base: " .. why .. "\n")
    return 2
  end
  local base = ""
  local event, ref = env["EVENT"] or "", env["REF"] or ""
  if event == "merge_group" then
    base = env["QUEUE_BASE"] or ""
  elseif event == "push" and ref ~= "refs/heads/main" then
    local pages = Github.ask(host, "repos/" .. (env["REPOSITORY"] or "") .. "/compare/main..." .. (env["SHA"] or "") ..
        "?per_page=1", false, call)
    local first = pages and pages[1]
    if first ~= nil then
      local compared, _ = COMPARISON:decode_into(first)
      local commit = compared and compared.merge_base_commit
      if commit ~= nil then base = commit.sha end
    end
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
local function prune(host: Github.Host, repository: string, call: integer, age: string,
                     prefix: string, entry: string, entries: string, wanted: function(entry: CacheEntry): boolean?)
  local pages = Github.ask(host, "repos/" .. repository .. "/actions/caches?key=" .. prefix .. "&per_page=100", true, call)
  local ids: mut {string} = {}
  local listed = pages ~= nil
  for _, text in ipairs(pages or {}) do
    local page, _ = CACHE_PAGE:decode_into(text)
    if page == nil then
      listed = false
      break
    end
    for _, item in ipairs(page.actions_caches) do
      local go = wanted(item)
      if go == nil then
        listed = false
        break
      end
      if go then
        local raw = item.id
        local id: integer? = nil
        if raw is number then id = math.tointeger(raw) end
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
    local gone, _ = host.delete("repos/" .. repository .. "/actions/caches/" .. id, call)
    if gone then
      deleted = deleted + 1
    else
      failed = failed + 1
    end
  end
  host.print("pruned " .. Plural.count(deleted, entry, entries) .. " " .. age .. " (" .. tostring(failed) ..
      " failed)")
end

--- Whether `entry`'s `created_at`, an RFC 3339 time (with the
--- milliseconds the API writes, or none), is before `cutoff` seconds
--- since the epoch; nil where it holds none.
local function older(entry: CacheEntry, cutoff: integer): boolean?
  local created = entry.created_at
  if not (created is string) then return nil end
  local ns, _ = Time.parse_rfc3339(created)
  if ns == nil then return nil end
  return ns // 1000000000 < cutoff
end

--- The commit `key` is under: one ending in `-sha-`, a whole commit id
--- and `-` and a digest, or, as the whole copies were saved, in `-sha-`
--- and the commit alone; nil for any other key.
--- TODO: drop the form without a digest once prune has deleted the last
--- whole copy, a day after main last saved one.
local function commit_of(key: string): string?
  local commit = key:match("%-sha%-([0-9a-f]+)%-[0-9a-f]+$") or key:match("%-sha%-([0-9a-f]+)$")
  if commit ~= nil and Github.is_commit(commit) then return commit end
  return nil
end

function CommitVerdicts.prune(env: {string:string}, host: Github.Host): integer
  local hours, why = whole(env, "HOURS", 24)
  local call: integer?
  if hours ~= nil then call, why = whole(env, "CALL_SECONDS", 15) end
  if hours == nil or call == nil then
    local _, _ = Fs.put(Fs.stderr, "prune-commit-verdicts: " .. why .. "\n")
    return 2
  end
  local repository = env["REPOSITORY"] or ""
  local cutoff = host.now() - hours * 3600
  prune(host, repository, call, "older than " .. tostring(hours) .. " h", "verdicts-", "commit-keyed verdict entry", "commit-keyed verdict entries", function(entry: CacheEntry): boolean?
    local key = entry.key
    if not (key is string) then return nil end
    if commit_of(key) == nil then return false end
    return older(entry, cutoff)
  end)
  prune(host, repository, call, "older than " .. tostring(hours) .. " h", "compiles-branch-", "branch compiles entry", "branch compiles entries", function(entry: CacheEntry): boolean?
    local key = entry.key
    if not (key is string) then return nil end
    if key:sub(1, 16) ~= "compiles-branch-" then return false end
    return older(entry, cutoff)
  end)
  return 0
end

function CommitVerdicts.invalidate(env: {string:string}, host: Github.Host): integer
  local call, why = whole(env, "CALL_SECONDS", 15)
  local commit = env["COMMIT"] or ""
  if call ~= nil and not Github.is_commit(commit) then
    call, why = nil, "COMMIT is no whole commit id: " .. commit
  end
  if call == nil then
    local _, _ = Fs.put(Fs.stderr, "invalidate-commit-verdicts: " .. why .. "\n")
    return 2
  end
  prune(host, env["REPOSITORY"] or "", call, "under commit " .. commit, "verdicts-", "commit-keyed verdict entry", "commit-keyed verdict entries", function(entry: CacheEntry): boolean?
    local key = entry.key
    if not (key is string) then return nil end
    return commit_of(key) == commit
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

function CommitVerdicts.invalidate_command(_argv: {string}): integer
  local env = Env.all()
  return CommitVerdicts.invalidate(env, Github.live(env))
end

return CommitVerdicts
