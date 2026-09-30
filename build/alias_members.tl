--- The members a declaration hands out by standing for another type:
--- `type Handle = raw_sqlite.Handle` hands out the fields and methods of
--- the record it names, as [`Sqlite.Handle.close`] reads, and `record
--- Options is raw_http.Options` those of its base. One rule for
--- `cosmic docs` ([`build.docs`]), which reads it off a database, and
--- for the links `cosmic fix` checks and the build indexes
--- ([`build.symbol_index`]), which read it off rows held in memory: each
--- gives the rule its rows through a [`Source`].

local record alias_members
  --- What the rule reads of a row of `docs` ([`build.schema`]).
  interface Declared
    module: string
    symbol: string
    source_symbol: string
    kind: string
    signature: string
  end

  --- Where the rule finds the rows it follows a declaration through.
  --- Each answers nil and why only when its rows cannot be read.
  record Source<T>
    --- The first record, interface or enum of `module` that its source
    --- spells `name`, or nil for none.
    declared: function(module: string, name: string): T | nil, string
    --- The first exported `type X = Y` spelled `name` in any module,
    --- or nil for none.
    alias: function(name: string): T | nil, string
    --- The fields and values declared directly under `target`, less any
    --- named `_...`: what it hands to a declaration that stands for it.
    under: function(target: T): {T} | nil, string
    --- `member`, a member of the type `owner` stands for, as `owner`'s
    --- own member named `name`.
    as_member: function(owner: T, member: T, name: string): T
  end
end

--- The types `declared` stands for, each as its module spelled it: one
--- for an alias, the bases of a record or interface that extends any
--- (comma separated), none otherwise.
function alias_members.references(declared: alias_members.Declared): {string}
  local out: {string} = {}
  local alias = declared.signature:match("^type [%w_]+ = ([%w_%.]+)$")
  if alias ~= nil then
    out[1] = alias
    return out
  end
  local bases = declared.signature:match("^[%a ]*record [%w_]+ is ([%w_%.,%s]+)$") or
    declared.signature:match("^[%a ]*interface [%w_]+ is ([%w_%.,%s]+)$")
  if bases ~= nil then
    for base in bases:gmatch("[%w_%.]+") do out[#out + 1] = base end
  end
  return out
end

--- How many aliases of aliases a reference is followed through.
local DEPTH <const> = 4

--- The record, interface or enum that `reference`, written in `module`,
--- names: one the module declares, one of `cosmic.internal.<module>`
--- (`raw_sqlite.Handle` is [`sqlite.Handle`] there), or one that another
--- module's own alias ([`Compress.Stream`]) points on to. Nil when it
--- names none, or nil and why when `source` cannot be read.
function alias_members.resolved<T is alias_members.Declared>(source: alias_members.Source<T>,
                                                           module: string,
                                                           reference: string): T | nil, string
  local depth = 0
  while true do
    local same, same_trouble = source.declared(module, reference)
    if same ~= nil then
      return same, ""
    end
    if same_trouble ~= nil then
      return nil, same_trouble
    end
    local stem, rest = reference:match("^([%w_]+)%.([%w_%.]+)$")
    if stem == nil then
      return nil
    end
    local record = stem:gsub("^raw_", ""):lower()
    local internal, internal_trouble = source.declared("cosmic.internal." .. record,
      record .. "." .. rest)
    if internal ~= nil then
      return internal, ""
    end
    if internal_trouble ~= nil then
      return nil, internal_trouble
    end
    if depth >= DEPTH then
      return nil
    end
    local alias, alias_trouble = source.alias(reference)
    if alias == nil then
      return nil, alias_trouble
    end
    local onward = alias_members.references(alias)[1]
    if onward == nil then
      return nil
    end
    module, reference, depth = alias.module, onward, depth + 1
  end
end

--- The members named `name` of the types `owners` stand for, each as
--- the owner's own member (`Handle.close` of [`cosmic.sqlite`] for the
--- `close` of the record its `Handle` aliases).
function alias_members.named<T is alias_members.Declared>(source: alias_members.Source<T>,
                                                        owners: {T}, name: string): {T} | nil, string
  local out: {T} = {}
  for _, owner in ipairs(owners) do
    for _, reference in ipairs(alias_members.references(owner)) do
      local target, target_trouble = alias_members.resolved(source, owner.module, reference)
      if target == nil and target_trouble ~= nil then
        return nil, target_trouble
      end
      if target ~= nil then
        local members, members_trouble = source.under(target)
        if members == nil then
          return nil, members_trouble
        end
        for _, member in ipairs(members) do
          if member.source_symbol:match("([^.]*)$") == name then
            out[#out + 1] = source.as_member(owner, member, name)
          end
        end
      end
    end
  end
  return out, ""
end

return alias_members
