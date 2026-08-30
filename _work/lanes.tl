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
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local gate = require("_work.gitgate")
local gh = require("_work.gh")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local literal = require("cosmic.literal")
local publish = require("_work.publish")
local store = require("_work.store")
local time = require("cosmic.time")

--- The scheduled workflows the board tracks, by filename under
--- `.github/workflows/`. Stable order: `record`'s commit subject and
--- `cmd_sync`'s printed lines both walk this list, so a reader always
--- sees the same lane in the same place.
local LANES: {string} = {"release.yml", "fuzz.yml", "docs.yml"}

--- Where a red lane's repair items are filed: G8, the flow-system
--- outcome this mechanism serves.
local LANE_PARENT < const > = "3HyRdT1JQS7pCPgF3sZi2Deo66q"

--- How long a real observation stays fresh before `at_sync` is
--- willing to spend another GET on it. The lanes themselves move on a
--- daily cadence (release.yml, fuzz.yml) or on pushes to main
--- (docs.yml) — nothing here changes minute to minute — so a window
--- longer than one builder loop's tick suppresses the redundant
--- back-to-back reads a busy session (or an orchestrator polling
--- `sync` in a loop) would otherwise pay for, while still catching a
--- lane turning red the same day. Local to this checkout's `o/`, so
--- it says nothing about what another worktree observed.
local FRESH_WINDOW_S < const > = 15 * 60

--- Set (to anything) to force a fresh read past the freshness window
--- — the escape hatch for a session that knows a lane just finished
--- and wants the current word rather than a recent one.
local FRESH_ENV < const > = "GITBOARD_LANES_FRESH"

--- Below this many REST calls left in the hour, the observation is
--- skipped rather than spent: it is the one OPTIONAL read `sync`
--- makes (`take`/`done`'s pull and check-run reads are not, and never
--- degrade). Set well above the three GETs one sync would otherwise
--- cost, so the skip triggers with real quota still spare, not at the
--- edge of a refusal.
local LOW_REMAINING < const > = 200

--- Where this checkout's last successful lane observation is noted —
--- disposable, under `o/`, alongside the ETag and rate-limit caches
--- `_work.api` keeps there; never committed, and shared with no other
--- worktree.
--- @param s store.Store The store
--- @return string Path under the store's `o/`
local function observed_at_path(s: store.Store): string
  return fs.join(s.root, "o", "lanes_observed_at.tl")
end

--- Note that an observation just completed, now.
--- @param s store.Store The store
local function touch_observed_at(s: store.Store)
  -- Fire-and-forget: this note is a local speed-up, never a contract
  -- — a write failure here never fails the sync that just observed.
  local _ok, _err = fs.make_dirs(fs.join(s.root, "o"))
  local now = time.now()
  local _wok, _werr = literal.format_file(observed_at_path(s), {at = now})
end

--- Seconds since the last noted observation, nil when none has ever
--- been noted (a fresh checkout, or one whose `o/` was cleaned) —
--- never a failure; unknown freshness never skips a read.
--- @param s store.Store The store
--- @return integer | nil Seconds elapsed
local function last_observed_age_s(s: store.Store): integer | nil
  local t = literal.parse_file(observed_at_path(s))
  if t == nil then
    return nil
  end
  local at = t["at"]
  if not (at is integer) then
    return nil
  end
  local now = time.now()
  return now - at
end

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
--- @param root string The store checkout root, for `_work.api`'s cache
--- @return string | nil The conclusion ("success", "failure", ...)
--- @return string Error message
local function observe_one(slug: string, lane: string, root: string): string | nil, string
  local path = ("/repos/%s/actions/workflows/%s/runs?per_page=1&status=completed")
  :format(slug, lane)
  local res, err = api.call("GET", path, root)
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
    local c, oerr = observe_one(slug, lane, s.root)
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
  local committed = child.run({"git", "-c", "user.email=noreply@anthropic.com",
      "-c", "user.name=Claude", "-c", "core.createObject=rename",
      "commit", "-q", "-m", "sync lanes: " .. table.concat(parts, " ")},
    {cwd = s.root})
  if committed == nil or not committed.ok then
    return false, ("git commit failed: %s"):format(
      committed and committed.stderr or "could not start git")
  end
  return publish.publish(s)
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
  --- Exported for tests only: the freshness window and its override,
  --- so a test drives the exact bound rather than a guessed copy of it.
  FRESH_WINDOW_S: integer
  FRESH_ENV: string
  --- Exported for tests only: the quota floor a low-remaining test
  --- straddles.
  LOW_REMAINING: integer
  observe: function(s: store.Store): {string: string} | nil, string
  read_state: function(s: store.Store): {string: string}
  record: function(s: store.Store, facts: {string: string}): boolean, string
  mint: function(s: store.Store, facts: {string: string}): boolean, string
  report: function(s: store.Store, facts: {string: string}): {string}
  at_sync: function(s: store.Store): {string}
  --- Exported for tests only: `at_sync`'s freshness note, driven
  --- directly rather than through a real observation.
  touch_observed_at: function(s: store.Store)
end

local M: lanes = {
  LANES = LANES,
  LANE_PARENT = LANE_PARENT,
  FRESH_WINDOW_S = FRESH_WINDOW_S,
  FRESH_ENV = FRESH_ENV,
  LOW_REMAINING = LOW_REMAINING,
  observe = observe,
  read_state = read_state,
  record = record,
  touch_observed_at = touch_observed_at,
  mint = mint,
}

--- Record an already-observed fact set and mint or close repair items
--- for it, returning every line the caller should print — a record or
--- mint failure included, so nothing sync learns is ever silently
--- discarded. Split from `at_sync` so a test can drive it with a fake
--- facts table, the same way `record` and `mint` already are, with no
--- live `observe` (network + token) needed to produce one. Goes
--- through `M` rather than the bare locals: `record` is also a Teal
--- keyword, and only the qualified call parses as one.
--- @param s store.Store The store
--- @param facts {string: string} One conclusion per lane
--- @return {string} Lines for the caller to print, one fact per line
local function report(s: store.Store, facts: {string: string}): {string}
  local lines: {string} = {}
  local rok, rerr = M.record(s, facts)
  if not rok and rerr ~= "" then
    lines[#lines + 1] = ("gitboard-sync: lanes record failed: %s"):format(rerr)
  end
  local mok, merr = M.mint(s, facts)
  if not mok then
    lines[#lines + 1] = ("gitboard-sync: lanes mint failed: %s"):format(merr)
  end
  for _, lane in ipairs(LANES) do
    if facts[lane] ~= "success" then
      lines[#lines + 1] = ("gitboard-sync: lane %s is %s"):format(lane, facts[lane])
    end
  end
  return lines
end

M.report = report

--- The whole sync-time pipeline: two ways to skip the read entirely —
--- a recent-enough observation, or a quota too low to spend on an
--- optional read — then observe and `report` on what it found (or a
--- one-line "unknown" when observe itself failed). A skip prints one
--- line and nothing else: the lanes verdicts (`show`, `next`) read
--- `read_state` regardless, so they reuse the last real observation
--- exactly as if this call had made one. Isolated here, not in
--- `cmd_sync` itself, so `_work.gitverbs` stays under its 500-line
--- cap; `cmd_sync` is the only caller.
--- @param s store.Store The store
--- @return {string} Lines for the caller to print, one fact per line
local function at_sync(s: store.Store): {string}
  if (env.get(FRESH_ENV) or "") == "" then
    local age = last_observed_age_s(s)
    if age ~= nil and age < FRESH_WINDOW_S then
      return {("gitboard-sync: lanes: skipped (observed %ds ago, within "
          .. "the %ds freshness window) — reusing the last observation")
        :format(age, FRESH_WINDOW_S)}
    end
  end
  local remaining, reset = api.read_rate(s.root)
  if remaining ~= nil and remaining < LOW_REMAINING then
    return {("gitboard-sync: lanes: skipped — rate limit low (remaining=%d, "
        .. "resets %s) — reusing the last observation"):format(remaining,
        reset ~= nil and time.format_http(reset) or "unknown")}
  end
  local facts, lerr = M.observe(s)
  if facts == nil then
    return {("gitboard-sync: lanes: unknown (%s)"):format(lerr)}
  end
  touch_observed_at(s)
  return M.report(s, facts)
end

M.at_sync = at_sync

return M
