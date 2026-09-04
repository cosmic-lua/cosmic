--- `brief`: emit the prompt a subagent runs one role from — builder,
--- research, review, refine, decompose — with every placeholder the board can
--- answer already filled: the item's id, handle, title, spec sidecar
--- verbatim, repo and base branch, the item branch, the PR under
--- review, and this checkout's own absolute path. Templates are
--- `_work.brieftext`; `review` picks between two by the handover the
--- item carries — a PR (`REVIEW`) or a research result
--- (`RESEARCH_REVIEW`); the fill grammar is `<UPPER_SNAKE>`, and a
--- placeholder the board cannot answer (a worktree path, a bounce
--- paragraph) survives the fill — the closing verdict line names each
--- survivor, so the caller's whole job is those and pasting the body
--- verbatim.
---
--- Every brief also mints and fills the session label this kind's own
--- claim belongs under (`mint_label`) and repeats it on the closing
--- verdict line, so the orchestrator claims — `take ID --session
--- <label>` — under the exact string the brief just printed, before
--- ever spawning the agent the body is handed to.
---
--- A read, not a mutation: nothing here writes the board.
local brieftext = require("_work.brieftext")
local fs = require("cosmic.fs")
local gate = require("_work.gitgate")
local gh = require("_work.gh")
local item = require("_work.item")
local review = require("_work.review")
local session = require("_work.session")
local store = require("_work.store")
local tail = require("_work.tail")

local KINDS < const >: {string: string} = {
  builder = brieftext.BUILDER,
  research = brieftext.RESEARCH,
  review = brieftext.REVIEW,
  refine = brieftext.REFINE,
  decompose = brieftext.DECOMPOSE,
}

--- The kind names, alphabetical, for refusals and help.
local KIND_LIST < const > = "builder, decompose, refine, research, review"

--- The label word each brief kind's minted claim carries: `builder`'s
--- own claim reads `build` (the word already in the commit log),
--- every other kind is its own name.
local LABEL_KIND < const >: {string: string} = {
  builder = "build",
  research = "research",
  review = "review",
  refine = "refine",
  decompose = "decompose",
}

--- The session label an orchestrator claims ID's `kind` work under:
--- `<kind>-<handle>-<orch8>`, where `<orch8>` is the first 8
--- characters of the session identity `_work.session` already derives
--- for THIS process (`gitboard show`'s "session: ... (from
--- CLAUDE_CODE_SESSION_ID)" line).
---
--- Deterministic and reusable ahead of the brief itself: an
--- orchestrator can compute (and `take ID --session` under) this exact
--- string before ever calling `brief`, because it is a pure function
--- of the kind, the item's handle, and the calling process's own
--- session — nothing the item's stored state contributes, and every
--- `gitboard` call inside one orchestrator run resolves the same
--- session identity. Embedding that identity is what a bare
--- `<kind>-<handle>-<n>` convention never had: two different physical
--- orchestrator sessions reviewing (or building) the same item mint
--- two different strings instead of the identical one `take`'s
--- exact-string mutual exclusion cannot tell apart from a re-claim.
--- @param kind string The brief kind
--- @param handle string The item's bare tail (`tail.bare`)
--- @return string The minted label
local function mint_label(kind: string, handle: string): string
  local identity = session.resolve(nil)
  local orch8 = identity:sub(1, 8)
  if orch8 == "" then
    orch8 = "unnamed"
  end
  return ("%s-%s-%s"):format(LABEL_KIND[kind] or kind, handle, orch8)
end

--- Replace every `<UPPER_SNAKE>` placeholder that `values` answers;
--- one the map does not answer survives verbatim.
--- @param text string The template
--- @param values {string: string} Fill values by placeholder name
--- @return string The filled text
local function fill(text: string, values: {string: string}): string
  local out = text:gsub("<(%u[%u_]*)>", function(key: string): string | nil
      return values[key]
    end)
  return out
end

--- The placeholders still unanswered in a filled body, first-seen
--- order, each once.
--- @param text string The filled template
--- @return {string} Placeholder names, possibly empty
local function unfilled(text: string): {string}
  local seen: {string: boolean} = {}
  local out: {string} = {}
  for key in text:gmatch("<(%u[%u_]*)>") do
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = ("<%s>"):format(key)
    end
  end
  return out
end

--- The refusal `brief review` earns from a PR's CI state, and the
--- head sha to fill `<HEAD_SHA>` with when there is one worth
--- trusting — green only, so a reviewer is handed a head worth
--- reading rather than one the brief's own rules already say to stop
--- on. A read failure (no origin, no token, a network error) answers
--- neither: a brief for a store with no GitHub reach emits exactly as
--- it always has, `<HEAD_SHA>` left for the caller to fill.
--- @param s store.Store The store
--- @param it item.Item The item under review
--- @param id8 string The item's handle, for the refusal text
--- @return string The refusal, "" when the brief may emit
--- @return string The PR's head sha, "" when unknown or not green
local function ci_refusal(s: store.Store, it: item.Item, id8: string):
  string, string
  local state, _serr = gh.head_checks(s, it.pr, it.repo)
  if state ~= "green" and state ~= "running" and state ~= "red" then
    return "", ""
  end
  local p, _perr = gh.pull(s, it.pr, it.repo)
  if state == "green" then
    if p == nil then
      return "", ""
    end
    return "", p.head_sha
  end
  local sha7 = "?"
  local runs: {review.CheckRun} = {}
  if p ~= nil then
    sha7 = p.head_sha:sub(1, 7)
    runs = gh.checks(s, p.head_sha, it.repo) or {}
  end
  if state == "running" then
    local done = 0
    for _, r in ipairs(runs) do
      if r.status == "completed" then done = done + 1 end
    end
    return ("REFUSED: %s's head %s has CI running (%d of %d checks done) — "
      .. "review when it settles"):format(id8, sha7, done, #runs), ""
  end
  return "REFUSED: " .. (review.blocks_on_ci(runs)
    or "CI has already concluded failure on this head"), ""
end

--- brief: print one role's prompt for an item, filled from the board.
--- The body prints first and the verdict line closes it (the `show`
--- shape), naming the placeholders left for the caller.
--- @param s store.Store The store
--- @param kind string builder | research | review | refine | decompose
--- @param id string The item the brief is about
--- @return integer Exit code
local function cmd_brief(s: store.Store, kind: string, id: string): integer
  local template = KINDS[kind or ""]
  if template == nil then
    return gate.verdict_line("brief", false,
      ("unknown brief '%s' — one of: %s"):format(tostring(kind), KIND_LIST))
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("brief", false, lerr)
  end
  local spec = store.read_spec(s, id)
  if spec == "" and kind ~= "decompose" then
    return gate.verdict_line("brief", false,
      ("%s has no spec sidecar — a %s brief carries the spec verbatim, "
        .. "so refine it first"):format(id:sub(1, 8), kind))
  end
  -- A review judges a handover, and there are two: a PR for a diff,
  -- a research result for a spec. Which template the brief is comes
  -- from the item, never from the caller.
  local head_sha = ""
  if kind == "review" then
    if (it.result or "") ~= "" then
      template = brieftext.RESEARCH_REVIEW
    elseif (it.pr or 0) == 0 then
      return gate.verdict_line("brief", false,
        ("%s has no handover recorded — `take %s --pr N` (a diff) or "
          .. "`take %s --result` (a research spec) is what a review "
          .. "judges"):format(id:sub(1, 8), id:sub(1, 8), id:sub(1, 8)))
    else
      local refusal, sha = ci_refusal(s, it, id:sub(1, 8))
      if refusal ~= "" then
        return gate.verdict_line("brief", false, refusal)
      end
      head_sha = sha
    end
  end
  local label = mint_label(kind, tail.bare(it.id))
  local values: {string: string} = {
    ITEM_ID = it.id,
    HANDLE = tail.handle(it.id),
    TITLE = it.title,
    BRANCH = it.id:sub(1, 8),
    SPEC = spec,
    CURRENT_SPEC = spec ~= "" and spec or "(the item has no spec sidecar)",
    BOARD_DIR = fs.absolute_path(s.root),
    REVIEW_SESSION = label,
  }
  -- The slug can fail (no origin remote in a scratch checkout); the
  -- brief still emits, with <REPO> surviving for the caller — named
  -- by the verdict line like any other unanswered placeholder.
  local repo, _rerr = gh.slug(s, it.repo)
  if repo ~= nil then
    values["REPO"] = repo
    if (it.base or "") ~= "" then
      values["BASE_BRANCH"] = it.base
    elseif repo:find("cosmopolitan", 1, true) ~= nil then
      values["BASE_BRANCH"] = "master"
    else
      values["BASE_BRANCH"] = "main"
    end
    if (it.pr or 0) ~= 0 then
      values["PR_URL"] = ("https://github.com/%s/pull/%d"):format(repo, it.pr)
    end
  elseif (it.base or "") ~= "" then
    values["BASE_BRANCH"] = it.base
  end
  if (it.pr or 0) ~= 0 then
    values["PR_NUMBER"] = ("%d"):format(it.pr)
  end
  if head_sha ~= "" then
    values["HEAD_SHA"] = head_sha
  end
  local body = fill(template, values)
  print(body)
  local left = unfilled(body)
  local tail_note = "nothing left to fill — paste the body verbatim"
  if #left > 0 then
    tail_note = ("fill %s, then paste the body verbatim"):format(
      table.concat(left, ", "))
  end
  return gate.verdict_line("brief",
    true, ("%s brief for %s, claim it as %s — %s"):format(
      kind, tail.handle(it.id), label, tail_note))
end

local record brief
  fill: function(text: string, values: {string: string}): string
  unfilled: function(text: string): {string}
  mint_label: function(kind: string, handle: string): string
  cmd_brief: function(s: store.Store, kind: string, id: string): integer
end

local M: brief = {
  fill = fill,
  unfilled = unfilled,
  mint_label = mint_label,
  cmd_brief = cmd_brief,
}

return M
