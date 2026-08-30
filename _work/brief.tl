--- `brief`: emit the prompt a subagent runs one role from — builder,
--- review, refine, decompose — with every placeholder the board can
--- answer already filled: the item's id, handle, title, spec sidecar
--- verbatim, repo and base branch, the item branch, the PR under
--- review, and this checkout's own absolute path. Templates are
--- `_work.brieftext`; the fill grammar is `<UPPER_SNAKE>`, and a
--- placeholder the board cannot answer (a worktree path, a bounce
--- paragraph, the reviewer's minted session) survives the fill — the
--- closing verdict line names each survivor, so the caller's whole
--- job is those and pasting the body verbatim.
---
--- A read, not a mutation: nothing here writes the board.
local brieftext = require("_work.brieftext")
local fs = require("cosmic.fs")
local gate = require("_work.gitgate")
local gh = require("_work.gh")
local store = require("_work.store")
local tail = require("_work.tail")

local KINDS < const >: {string: string} = {
  builder = brieftext.BUILDER,
  review = brieftext.REVIEW,
  refine = brieftext.REFINE,
  decompose = brieftext.DECOMPOSE,
}

--- The kind names, alphabetical, for refusals and help.
local KIND_LIST < const > = "builder, decompose, refine, review"

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

--- brief: print one role's prompt for an item, filled from the board.
--- The body prints first and the verdict line closes it (the `show`
--- shape), naming the placeholders left for the caller.
--- @param s store.Store The store
--- @param kind string builder | review | refine | decompose
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
  if kind == "review" and (it.pr or 0) == 0 then
    return gate.verdict_line("brief", false,
      ("%s has no PR recorded — the handover (`take %s --pr N`) is what "
        .. "a review judges"):format(id:sub(1, 8), id:sub(1, 8)))
  end
  local values: {string: string} = {
    ITEM_ID = it.id,
    HANDLE = tail.handle(it.id),
    TITLE = it.title,
    BRANCH = it.id:sub(1, 8),
    SPEC = spec,
    CURRENT_SPEC = spec ~= "" and spec or "(the item has no spec sidecar)",
    BOARD_DIR = fs.absolute_path(s.root),
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
  local body = fill(template, values)
  print(body)
  local left = unfilled(body)
  local tail_note = "nothing left to fill — paste the body verbatim"
  if #left > 0 then
    tail_note = ("fill %s, then paste the body verbatim"):format(
      table.concat(left, ", "))
  end
  return gate.verdict_line("brief",
    true, ("%s brief for %s — %s"):format(kind, tail.handle(it.id), tail_note))
end

local record brief
  fill: function(text: string, values: {string: string}): string
  unfilled: function(text: string): {string}
  cmd_brief: function(s: store.Store, kind: string, id: string): integer
end

local M: brief = {
  fill = fill,
  unfilled = unfilled,
  cmd_brief = cmd_brief,
}

return M
