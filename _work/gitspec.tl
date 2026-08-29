--- spec: replace an item's spec sidecar — the verb that moves the
--- DEFINITION of work, beside `_work.gitverbs`' state verbs, which
--- move an item's MOTION (the same split `_work/gitspec_test.tl`
--- already tests along). The write is a compare-and-swap against
--- `base` proving the writer read what is there. An in-flight item's
--- spec is its claim holder's to move (`gate.spec_refusal`) — a
--- foreign write onto a live claim needs `--force --why`, same as
--- taking one over. A named session joins `it.speccers` — `builders`'
--- counterpart for spec authorship — in the SAME commit as the
--- sidecar; a flag-shaped name is refused before anything is staged
--- (`item.record_involvement`).
local fs = require("cosmic.fs")
local gate = require("_work.gitgate")
local item = require("_work.item")
local store = require("_work.store")

--- @param s store.Store The store
--- @param id string The item whose spec is replaced
--- @param file string Path to the replacement markdown
--- @param base string | nil The spec text the caller read, as a file path
--- @param session string | nil The session making the write
--- @param force boolean | nil Rewrite a foreign LIVE claim's spec
--- @param why string | nil Why --force was needed
--- @return integer Exit code
local function cmd_spec(s: store.Store, id: string, file: string,
    base?: string, session?: string, force?: boolean, why?: string): integer
  local frc = force or false
  local rsn = why or ""
  local forced = gate.force_refusal(frc, rsn)
  if forced then
    return gate.verdict_line("spec", false, "REFUSED: " .. forced)
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("spec", false, lerr)
  end
  if not frc then
    local refusal = gate.spec_refusal(it, session or "")
    if refusal then
      return gate.verdict_line("spec", false, refusal)
    end
  end
  local body, rerr = fs.read(file)
  if body == nil then
    return gate.verdict_line("spec", false, rerr)
  end
  local stale = gate.base_refusal(store.read_spec(s, id), base or "", id)
  if stale then
    return gate.verdict_line("spec", false, stale)
  end
  local who = session or ""
  if who ~= "" then
    local recorded, ierr = item.record_involvement(it.speccers, who)
    if not recorded then
      return gate.verdict_line("spec", false, "REFUSED: " .. ierr)
    end
  end
  local ok, err = gate.commit_and_publish(s, it, body,
    ("spec %s%s"):format(id:sub(1, 8), gate.forced_suffix(frc, rsn)))
  if not ok then
    return gate.verdict_line("spec", false, err)
  end
  return gate.verdict_line("spec", true, ("%s's spec replaced"):format(id:sub(1, 8)))
end

local record gitspec
  cmd_spec: function(s: store.Store, id: string, file: string,
  base?: string, session?: string, force?: boolean, why?: string): integer
end

local M: gitspec = {
  cmd_spec = cmd_spec,
}

return M
