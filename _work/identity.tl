--- Session identity as an item field: the one shape refused before a
--- name is written into `claim`, `builders`, `speccers` or `reviewer`,
--- and the append-only involvement lists that record who has ever
--- been party to an item. Split from `_work.item`, which re-exports
--- both, so the item codec stays under the file cap; nothing here
--- reads or writes the store.

--- The refusal for a name that cannot be a session identity: a token
--- led by `-`. The live identities share no grammar — uuids, minted
--- `<word>-<digits>` and `review-<id8>-<ts>` names, scheduled-run and
--- free-form runner names, a person's user-host pair — so this is a
--- blocklist, not an allowlist: the one shape none of them has is a
--- leading dash, which is what gets recorded when a mangled argv
--- absorbs a flag as a value. Applied where a session name is WRITTEN
--- into an item field, never in `decode`/`problems` — the one
--- historical item already carrying such a token must keep reading.
--- @param session string The offered identity
--- @return string | nil The refusal, nil when the name is recordable
local function identity_refusal(session: string): string | nil
  if session:sub(1, 1) == "-" then
    return ("%q is a flag, not a session identity — an argv absorbed "
      .. "an option where a name belongs; pass --session <name>"):format(session)
  end
  return nil
end

--- Record that `session` is named in an involvement list — `builders`
--- (who claimed) or `speccers` (who wrote the spec) alike.
---
--- The claim answers who holds the item NOW and moves with every
--- drop; an involvement list answers who has EVER been party to it
--- and never moves, which is what makes the sequence of holders
--- auditable once the claim (or the spec's authorship) has moved on.
--- A session already on the list is a no-op — `problems` refuses a
--- repeat, so this is the only place a caller need not check first.
--- A flag-shaped name refuses (`identity_refusal`): these lists are
--- what the review-distance guard reads, so garbage recorded here is
--- garbage it trusts.
--- @param list {string} The involvement list, mutated in place
--- @param session string The session recorded
--- @return boolean True when the session is on the list
--- @return string The refusal for a name that cannot be an identity
local function record_involvement(list: {string}, session: string): boolean, string
  local bad = identity_refusal(session)
  if bad ~= nil then
    return false, bad
  end
  for _, name in ipairs(list) do
    if name == session then
      return true
    end
  end
  list[#list + 1] = session
  return true
end

local record identity
  identity_refusal: function(session: string): string
  record_involvement: function(list: {string}, session: string): boolean, string
end

local M: identity = {
  identity_refusal = identity_refusal,
  record_involvement = record_involvement,
}

return M
