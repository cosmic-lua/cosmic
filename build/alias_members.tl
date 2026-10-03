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
    --- The first record, interface, enum or `type X = Y` of `module`
    --- that its source spells `name`, or nil for none.
    declared: function(module: string, name: string): T | nil, string
    --- The first record, interface, enum or `type X = Y` that `module`
    --- exports as `name`, or nil for none.
    exported: function(module: string, name: string): T | nil, string
    --- The module that `module`'s own block binds `name` to
    --- ([`build.analyzer.Bound`]), or nil for none.
    bound: function(module: string, name: string): string | nil, string
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

--- The record a module's value is typed as, read off the signature of
--- the module's own row, which [`build.analyzer`] writes as the value's
--- declaration (`local module: Module`) when the module returns a name
--- other than that record; nil for any other signature. The value's
--- members are that record's: `order` of cosmic.cli is the row
--- `Module.order`.
function alias_members.value_record(signature: string): string | nil
  return signature:match("^local [%a_][%w_]*: ([%a_][%w_]*)$")
end

--- How many aliases of aliases a reference is followed through.
local DEPTH <const> = 4

--- Whether `row` is a record, interface or enum: a type with members of
--- its own, where following a reference ends.
local function concrete(row: alias_members.Declared): boolean
  return row.kind == "record" or row.kind == "interface" or row.kind == "enum"
end

--- The type `reference`, written in `module` as `name.Member`, names
--- through the module `module` binds `name` to: the one that module
--- exports as `Member`. Nil when it names none, or nil and why.
local function bound_type<T is alias_members.Declared>(source: alias_members.Source<T>,
                                                       module: string,
                                                       reference: string): T | nil, string
  local stem, rest = reference:match("^([%w_]+)%.([%w_%.]+)$")
  if stem == nil then
    return nil
  end
  local other, other_trouble = source.bound(module, stem)
  if other == nil then
    return nil, other_trouble
  end
  return source.exported(other, rest)
end

--- What a reference names of the types its module declares
--- ([`scoped`]): the type itself (`found`), or the type its first name
--- is (`holder`), which hides any module the file binds that name to.
local record Scoped<T>
  found: T | nil
  holder: T | nil
end

--- What `reference`, written in the declaration of `module` whose
--- source symbol is `written`, names of the types the module declares,
--- as Teal scopes a type's name: under each record that encloses it,
--- innermost first, then at the top. Neither field set when it names
--- none; nil and why when `source` cannot be read.
local function scoped<T is alias_members.Declared>(source: alias_members.Source<T>,
                                                   module: string, written: string,
                                                   reference: string): Scoped<T> | nil, string
  local stem = reference:match("^([%w_]+)%.")
  local scope = written:match("^(.*)%.[^.]*$") or ""
  while true do
    local prefix = scope ~= "" and scope .. "." or ""
    local found, trouble = source.declared(module, prefix .. reference)
    if found == nil and trouble ~= nil then
      return nil, trouble
    end
    -- A declaration does not name itself: `type Options = Options` in a
    -- record names the `Options` outside it.
    if found ~= nil and found.source_symbol ~= written then
      return { found = found }, ""
    end
    if stem ~= nil then
      local holder, holder_trouble = source.declared(module, prefix .. stem)
      if holder_trouble ~= nil then
        return nil, holder_trouble
      end
      if holder ~= nil and holder.source_symbol ~= written then
        return { holder = holder }, ""
      end
    end
    if scope == "" then
      return {}, ""
    end
    scope = scope:match("^(.*)%.[^.]*$") or ""
  end
end

--- The record, interface or enum that `reference`, written in the
--- declaration `from`, names: one its module declares, as Teal scopes
--- the name ([`scoped`]), or one another module exports under the name
--- its qualifier is bound to there ([`Stream.ArchiveEntry`] of
--- [`cosmic.archive`], where `local Stream = require("cosmic.stream")`;
--- `raw_sqlite.Handle`, [`sqlite.Handle`] of [`cosmic.internal.sqlite`]),
--- followed on through each alias it meets ([`Compress.Stream`]), in any
--- module. Nil when it names none, or past `DEPTH` aliases, which a
--- cycle of them reaches; nil and why when `source` cannot be read.
function alias_members.resolved<T is alias_members.Declared>(source: alias_members.Source<T>,
                                                             from: T,
                                                             reference: string): T | nil, string
  local depth = 0
  while true do
    local named, named_trouble = scoped(source, from.module, from.source_symbol, reference)
    if named == nil then
      return nil, named_trouble
    end
    local found, found_trouble, holder = named.found, "", named.holder
    if holder ~= nil then
      -- The first name is a type of the module's own: `Stream.X` under
      -- `type Stream = Y` is `Y.X`.
      local onward = not concrete(holder) and alias_members.references(holder)[1] or nil
      if onward == nil or depth >= DEPTH then
        return nil
      end
      from, reference, depth = holder, onward .. reference:match("%..*$"), depth + 1
    else
      if found == nil then
        found, found_trouble = bound_type(source, from.module, reference)
      end
      if found == nil then
        return nil, found_trouble
      end
      if concrete(found) then
        return found, ""
      end
      local onward = alias_members.references(found)[1]
      if onward == nil or depth >= DEPTH then
        return nil
      end
      from, reference, depth = found, onward, depth + 1
    end
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
      local target, target_trouble = alias_members.resolved(source, owner, reference)
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
