--- Scheduled-lane health as board state: `sync` learns whether the
--- required lanes (release, fuzz, docs) came back green from their
--- last completed run, records the fact so reads stay tokenless and
--- offline, and mints one idempotent repair item per red lane. The
--- logic lives here rather than in `_work.gitverbs` so that module's
--- 500-line cap stays clear; `cmd_sync` there is the only caller.
---
--- A red lane mints; a green one closes an UNCLAIMED repair and
--- leaves a claimed one alone — the monitor never undoes a builder's
--- claim, and it never mints twice for one lane, because the repair
--- item's `lane` field is the idempotency key `mint` searches on.
local api = require("_work.api")
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local gate = require("_work.gitgate")
local gh = require("_work.gh")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local literal = require("cosmic.literal")
local store = require("_work.store")

--- The scheduled workflows the board tracks, by filename under
--- `.github/workflows/`. Stable order: `record`'s commit subject and
--- `cmd_sync`'s printed lines both walk this list, so a reader always
--- sees the same lane in the same place.
local LANES: {string} = {"release.yml", "fuzz.yml", "docs.yml"}

--- Where a red lane's repair items are filed: G8, the flow-system
--- outcome this mechanism serves.
local LANE_PARENT < const > = "3HyRdT1JQS7pCPgF3sZi2Deo66q"

--- The minted spec sidecar every repair item carries: short and
--- generic, because machinery files it, not a person — but it fills
--- the spec bar honestly (`## Change`, non-empty), the same bar every
--- other item clears before `take` admits it. Naming the workflow file
--- and the read-the-log-first step is enough for a builder to start;
--- anything more specific belongs in the PR the repair produces, not
--- in a template minted once per red lane.
--- @param lane string Workflow filename
--- @return string The spec sidecar's markdown
local function repair_spec(lane: string): string
  return ("## Change\n"
    .. "The scheduled workflow `.github/workflows/%s` is red. Read the "
    .. "latest failing run's log (Actions UI or `gh run view --log-failed`), "
    .. "diagnose the failure, and fix it on a PR like any other item.\n")
  :format(lane)
end

--- The committed fact file's path, at the board root rather than
--- under `items/` — it is board state, not an item, and living
--- outside `items/` is what keeps it off the append-only item history.
--- @param s store.Store The store
--- @return string Path under the store root
local function state_path(s: store.Store): string
  return fs.join(s.root, "lanes_state.tl")
end

--- One lane's last completed run, read live. Any failure — no token,
--- no network, a lane with no completed run yet — is reported so the
--- caller can treat the whole observation as unknown; a partial read
--- is never mistaken for a partial-red one.
--- @param slug string owner/repo
--- @param lane string Workflow filename
--- @return string | nil The conclusion ("success", "failure", ...)
--- @return string Error message
local function observe_one(slug: string, lane: string): string | nil, string
  local path = ("/repos/%s/actions/workflows/%s/runs?per_page=1&status=completed")
  :format(slug, lane)
  local res, err = api.call("GET", path)
  if res == nil then
    return nil, err
  end
  if not api.is_success(res.status) then
    return nil, api.error_of("GET", path, res)
  end
  local v = res.value
  if not (v is {string: any}) then
    return nil, ("GET %s: response is not an object"):format(path)
  end
  local runs = v["workflow_runs"]
  if not (runs is {any}) then
    return nil, ("GET %s: no workflow_runs array"):format(path)
  end
  if #runs == 0 then
    return nil, ("%s has no completed runs yet"):format(lane)
  end
  local first = runs[1]
  if not (first is {string: any}) then
    return nil, ("GET %s: a run is not an object"):format(path)
  end
  return tostring(first["conclusion"] or "")
end

--- Fetch each required lane's last completed conclusion. `sync`
--- treats a nil here as "lanes unknown" and never as red — a token or
--- network failure says nothing about whether the lanes are healthy.
--- @param s store.Store The store
--- @return {string: string} | nil One conclusion per lane in LANES
--- @return string Error message
local function observe(s: store.Store): {string: string} | nil, string
  local slug, serr = gh.slug(s, nil)
  if slug == nil then
    return nil, serr
  end
  local facts: {string: string} = {}
  for _, lane in ipairs(LANES) do
    local c, oerr = observe_one(slug, lane)
    if c == nil then
      return nil, ("%s: %s"):format(lane, oerr)
    end
    facts[lane] = c
  end
  return facts
end

--- The facts last recorded, read straight from the committed file —
--- this is what keeps a fresh worktree's reads offline and truthful.
--- Exported for `show`'s lanes row too: a fresh board that has never
--- synced has no file, so `read_state` comes back empty and `show`
--- renders no row rather than a row of blanks.
--- @param s store.Store The store
--- @return {string: string} One conclusion per lane, "" for the rest
local function read_state(s: store.Store): {string: string}
  local t = literal.parse_file(state_path(s))
  local out: {string: string} = {}
  if t == nil then
    return out
  end
  for _, lane in ipairs(LANES) do
    local v = t[lane]
    if v is string then
      out[lane] = v
    end
  end
  return out
end

--- Commit the observed facts as `lanes_state.tl`, ONLY when they
--- differ from what is already recorded — an unchanged observation
--- has nothing for the log to say, and re-committing it every sync
--- would bury the runs that actually moved.
--- @param s store.Store The store
--- @param facts {string: string} One conclusion per lane
--- @return boolean True once committed (and pushed, given a remote);
--- false when the facts already matched what was recorded, or on failure
--- @return string Error message; "" when nothing changed
local function record(s: store.Store, facts: {string: string}): boolean, string
  local current = read_state(s)
  local changed = false
  local parts: {string} = {}
  local value: {string: any} = {}
  for _, lane in ipairs(LANES) do
    local c = facts[lane] or ""
    if c ~= (current[lane] or "") then
      changed = true
    end
    if c ~= "" then
      parts[#parts + 1] = ("%s=%s"):format(lane, c)
      value[lane] = c
    end
  end
  if not changed then
    return false, ""
  end
  local wrote, werr = literal.format_file(state_path(s), value)
  if not wrote then
    return false, werr
  end
  local added = child.run({"git", "add", "lanes_state.tl"}, {cwd = s.root})
  if added == nil or not added.ok then
    return false, ("git add lanes_state.tl failed: %s"):format(
      added and added.stderr or "could not start git")
  end
  local committed = child.run({"git", "-c", "user.email=board@cosmic",
      "-c", "user.name=cosmic-board", "-c", "core.createObject=rename",
      "commit", "-q", "-m", "sync lanes: " .. table.concat(parts, " ")},
    {cwd = s.root})
  if committed == nil or not committed.ok then
    return false, ("git commit failed: %s"):format(
      committed and committed.stderr or "could not start git")
  end
  return store.publish(s)
end

--- Whether `it` is the open repair item for `lane` — the search
--- `mint` runs before ever filing one, which is what keeps five red
--- days costing one item instead of five.
--- @param it item.Item The item
--- @param lane string Workflow filename
--- @return boolean True when it is open and carries this lane
local function is_repair_for(it: item.Item, lane: string): boolean
  return item.is_open(it) and (it.lane or "") == lane
end

--- File one repair item for a red lane, carrying the lane as its
--- idempotency key.
--- @param s store.Store The store
--- @param lane string Workflow filename
--- @return boolean True on success
--- @return string Error message
local function file_repair(s: store.Store, lane: string): boolean, string
  local title = ("lane repair: %s is red"):format(lane)
  local it: item.Item = {
    id = ksuid.new(), title = title, parent = LANE_PARENT, repo = "",
    beats = {}, blocked_by = {}, block_reason = {}, claim = "",
    builders = {}, reviewer = "", pr = 0, verdict = "", verdict_head = "",
    verdict_spec = "", resolution = "", lane = lane,
  }
  local bad = item.problems(it)
  if #bad > 0 then
    return false, table.concat(bad, "; ")
  end
  return gate.commit_and_publish(s, it, repair_spec(lane),
    ("new %s %s"):format(it.id:sub(1, 8), title))
end

--- Ensure each red lane has one open repair item, and close an
--- unclaimed one whose lane came back green; a claimed one is left
--- for its builder.
--- @param s store.Store The store
--- @param facts {string: string} One conclusion per lane
--- @return boolean True on success
--- @return string Error message
local function mint(s: store.Store, facts: {string: string}): boolean, string
  local all, aerr = store.list(s)
  if all == nil then
    return false, aerr
  end
  for _, lane in ipairs(LANES) do
    local existing: item.Item = nil
    for _, it in ipairs(all) do
      if is_repair_for(it, lane) then
        existing = it
        break
      end
    end
    local conclusion = facts[lane] or ""
    if conclusion ~= "success" then
      if existing == nil then
        local ok, err = file_repair(s, lane)
        if not ok then
          return false, err
        end
      end
    elseif existing ~= nil and (existing.claim or "") == "" then
      existing.resolution = "not-planned"
      local ok, err = gate.commit_and_publish(s, existing, nil,
        ("done %s not-planned (from todo)"):format(existing.id:sub(1, 8)))
      if not ok then
        return false, err
      end
    end
  end
  return true, ""
end

local record lanes
  LANES: {string}
  --- Exported for tests only: `mint`'s idempotency key search and
  --- `file_repair`'s parent both close over the local, and a test that
  --- wants to place the real repair parent (the way G8 already is on
  --- the live board) needs the same id rather than a second literal.
  LANE_PARENT: string
  observe: function(s: store.Store): {string: string} | nil, string
  read_state: function(s: store.Store): {string: string}
  record: function(s: store.Store, facts: {string: string}): boolean, string
  mint: function(s: store.Store, facts: {string: string}): boolean, string
end

local M: lanes = {
  LANES = LANES,
  LANE_PARENT = LANE_PARENT,
  observe = observe,
  read_state = read_state,
  record = record,
  mint = mint,
}

return M
