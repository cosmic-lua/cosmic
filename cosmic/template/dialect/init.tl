--- What the attributes of a framework (`hx-*` of htmx) mean to a slot in
--- them: a lookup over the data a dialect module holds, in the shape of
--- [`Types.Def`]. A template that says `{{use htmx}}` is judged by the
--- base dialect `html` (the refusals that are always on) and the dialects
--- it names; an attribute no rule names is a plain attribute. Private to
--- [`cosmic.template`].
---
--- A name is matched in lower case (the tokenizer lower-cases attribute
--- names), and also with a `data-` prefix in front when the rest begins with
--- a family one of the dialects lists (`data-hx-get` is `hx-get`, as the
--- framework reads it). The exact name is tried first, then the longest
--- matching prefix.

local base = require("cosmic.template.dialect.html")
local htmx = require("cosmic.template.dialect.htmx")
local types = require("cosmic.template.types")

local type Rule = types.Rule

local record Dialect
  --- The merged rules of a template's dialects.
  record Table
    --- The rule for the attribute `attr` (lower case), or nil when the
    --- dialects say nothing of it.
    classify: function(self: Table, attr: string): Rule?
    --- The rule of each attribute that has one, by exact name.
    exact: {string: Rule}
    --- The prefix rules, longest prefix first.
    prefixes: {types.Prefix}
    --- The name families also read with a `data-` prefix.
    families: {string}
    --- What `classify` has answered: the rule of each attribute that has one.
    known: mut {string: Rule}
    --- What `classify` has answered of an attribute that has none.
    plain: mut {string: boolean}
  end

  --- The dialects `{{use name}}` names, by name.
  registry: {string: types.Def}

  --- The table for the always-on dialect and the dialects `names` in
  --- `registry`, or nil and why when a name is unknown or two of the named
  --- dialects give one attribute different rules.
  resolve: function(names: {string}, registry: {string: types.Def}): Table?, string
end

local function classify(self: Dialect.Table, attr: string): Rule?
  local known = self.known[attr]
  if known ~= nil then
    return known
  elseif self.plain[attr] == true then
    return nil
  end
  local name = attr
  if attr:sub(1, 5) == "data-" then
    local rest = attr:sub(6)
    for _, family in ipairs(self.families) do
      if rest:sub(1, #family) == family then
        name = rest
        break
      end
    end
  end
  local rule = self.exact[name]
  if rule == nil then
    for _, entry in ipairs(self.prefixes) do
      if name:sub(1, #entry.prefix) == entry.prefix then
        rule = entry.rule
        break
      end
    end
  end
  if rule == nil then
    self.plain[attr] = true
  else
    self.known[attr] = rule
  end
  return rule
end

--- `attr` without the `data-` that htmx reads `data-hx-x` through.
local function bare(attr: string): string
  if attr:sub(1, 8) == "data-hx-" then
    return attr:sub(6)
  end
  return attr
end

--- The attributes the always-on dialect refuses that a dialect may give the
--- class `json` (and no other): a JSON text made by Html.json cannot run.
local RELAXABLE <const>: {string: boolean} = { ["hx-vals"] = true, ["hx-headers"] = true, ["hx-request"] = true }

--- Whether the always-on dialect refuses a slot in the attribute `attr`
--- (without a `data-` prefix: see `bare`).
local function locked(attr: string): boolean
  local rule = base.exact[attr]
  if rule == nil then
    for _, entry in ipairs(base.prefixes) do
      if attr:sub(1, #entry.prefix) == entry.prefix then
        rule = entry.rule
        break
      end
    end
  end
  return rule ~= nil and rule.class == "refused"
end

--- Why the dialect `def` may not hold `rule` for the attribute `attr`, or "".
--- The refusals that are always on cannot be taken off by a dialect: only
--- the JSON attributes may be given the class `json`.
local function unlockable(def: types.Def): string
  local function bad(what: string): string
    return "dialect '" .. def.name .. "' gives " .. what .. ", which the always-on dialect refuses a slot in " ..
      "and no dialect may change"
  end
  for attr, rule in pairs(def.exact) do
    local name = bare(attr)
    if locked(name) and not (RELAXABLE[name] == true and rule.class == "json") and rule.class ~= "refused" then
      return bad("'" .. attr .. "' the class " .. rule.class)
    end
  end
  for _, entry in ipairs(def.prefixes) do
    -- A prefix at least as long as a refused one covers only names it also
    -- covers, and the tie goes to the later dialect.
    for _, held in ipairs(base.prefixes) do
      if held.rule.class == "refused" and bare(entry.prefix):sub(1, #held.prefix) == held.prefix and
          entry.rule.class ~= "refused" then
        return bad("the prefix '" .. entry.prefix .. "' the class " .. entry.rule.class)
      end
    end
  end
  return ""
end

--- Whether two rules are the same one.
local function same(a: Rule, b: Rule): boolean
  return a.class == b.class and a.why == b.why
end

--- The table for the always-on dialect and the dialects `names` in
--- `registry`, or nil and why when a name is unknown or two of the named
--- dialects give one attribute different rules. A named dialect may override
--- the always-on one, as `htmx` does for `hx-vals`.
--- @param names {string} The dialects a template uses, in order
--- @param registry {string: types.Def} Where their data is found by name
--- @return Dialect.Table|nil The merged rules
--- @return string The reason, on failure
function Dialect.resolve(names: {string}, registry: {string: types.Def}): Dialect.Table?, string
  local defs: mut {types.Def} = { base }
  for _, name in ipairs(names) do
    local def = registry[name]
    if def == nil then
      return nil, "unknown dialect '" .. name .. "'"
    end
    local bad = unlockable(def)
    if bad ~= "" then
      return nil, bad
    end
    defs[#defs + 1] = def
  end
  local exact: mut {string: Rule} = {}
  local owner: mut {string: string} = {}
  local order: mut {types.Prefix: integer} = {}
  local prefixes: mut {types.Prefix} = {}
  local seen: mut {string: boolean} = {}
  local families: mut {string} = {}
  for at, def in ipairs(defs) do
    for attr, rule in pairs(def.exact) do
      -- The always-on dialect is the one a named dialect may override, so
      -- that `hx-vals` is refused until a template says `{{use htmx}}`.
      local prior = exact[attr]
      if prior ~= nil and owner[attr] ~= base.name and not same(prior, rule) then
        return nil, "dialects '" .. owner[attr] .. "' and '" .. def.name .. "' give '" .. attr .. "' different rules"
      end
      exact[attr] = rule
      owner[attr] = def.name
    end
    for _, entry in ipairs(def.prefixes) do
      prefixes[#prefixes + 1] = entry
      order[entry] = at
    end
    for _, family in ipairs(def.families) do
      if seen[family] ~= true then
        seen[family] = true
        families[#families + 1] = family
      end
    end
  end
  table.sort(prefixes, function(a: types.Prefix, b: types.Prefix): boolean
    if #a.prefix ~= #b.prefix then
      return #a.prefix > #b.prefix
    end
    return order[a] > order[b]
  end)
  local merged: Dialect.Table = { classify = classify, exact = exact, prefixes = prefixes, families = families,
    known = {}, plain = {} }
  return merged, ""
end

Dialect.registry = { htmx = htmx }

return Dialect
