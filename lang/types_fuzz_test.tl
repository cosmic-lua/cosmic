--- Fuzz properties for the type store ([`lang.types`]), over the random types of
--- [`lang.types_programs`]. Making a type again finds the type; a union is the one type
--- whatever the order its members come in, how they are grouped and the store that makes
--- it, and is in normal form; the text of a type decodes to the same type in its store and
--- to a type with the same text, display and digest in another store that has made other
--- types first; the display of a type parses and lowers to the same type; and the flags
--- `open` and `has_mut` are what a plain recursion says. `FUZZ_SEED` and `FUZZ_ITERS` pick
--- the inputs (build/fuzz/init.tl).
local Fuzz = require("build.fuzz")
local Programs = require("lang.types_programs")
local Test = require("cosmic.test")
local Types = require("lang.types")

Test.policy{}

local function gen_draws(src: Fuzz.Source): string
  local out: mut {string} = {}
  while Fuzz.more(src, #out, 120) do
    out[#out + 1] = tostring(src:int(0, 99))
  end
  return table.concat(out, " ")
end

local record World
  store: Types.Store
  fixture: Programs.Fixture
end

local function world(loader?: Types.Loader): World
  local store = Types.new(loader)
  return { store = store, fixture = Programs.fixture(store) }
end

--- A store that has made types of its own first, so that its ids are not another store's.
local function crowded(origin: Types.Store, draws: {integer}): Types.Store
  local store = Types.new(function(module: string, name: string): string?
    local decl = origin:find(module, name)
    return decl ~= nil and Types.encode_declaration(decl) or nil
  end)
  local decoded = store:decode('(map string (marray (ref "m" "Pair" integer (ref "m" "Tree"))))')
  assert(decoded ~= nil)
  local _ = store:array(store:optional(store.number))
  for i = #draws, 1, -1 do
    local _ = store:var(i % 3, i % 5)
  end
  return store
end

-- The labels a type reaches, so that a property that needs a form finds out when none is drawn.
local function label_all(t: Types.Type, seen: mut {integer: boolean})
  if seen[t.id] then
    return
  end
  seen[t.id] = true
  Fuzz.label(t.tag)
  if (t.tag == "union") then
    Fuzz.label(if t.nilable then "optional" else "union" end)
    for _, m in ipairs(t.members) do
      label_all(m, seen)
    end
  elseif (t.tag == "array") then
    Fuzz.label(if t.mut then "mut" else "view" end)
    label_all(t.element, seen)
  elseif (t.tag == "map") then
    label_all(t.key, seen)
    label_all(t.value, seen)
  elseif (t.tag == "named") then
    Fuzz.label(if #t.args > 0 then "generic use" else "plain use" end)
    if #t.args == 2 and t.args[1] == t.args[2] then
      Fuzz.label("shared parts")
    end
    for _, a in ipairs(t.args) do
      label_all(a, seen)
    end
  elseif (t.tag == "fn") then
    Fuzz.label(if #t.tparams > 0 then "generic function" else "plain function" end)
    if #t.rets == 0 then
      Fuzz.label("never returns")
    elseif #t.rets > 1 then
      Fuzz.label("several alternatives")
    end
    local rest = t.rest
    if rest ~= nil then
      Fuzz.label("rest")
    end
    for _, p in ipairs(t.params) do
      Fuzz.label(if p.omittable == true then "omittable" else "required" end)
      label_all(p.type, seen)
    end
    for _, alt in ipairs(t.rets) do
      local narrows, tail = alt.narrows, alt.tail
      if narrows ~= nil then
        Fuzz.label("narrows")
        label_all(narrows.to, seen)
      end
      if tail ~= nil then
        Fuzz.label("tail")
        label_all(tail, seen)
      end
      for _, item in ipairs(alt.items) do
        if (item.tag == "union") then
          for _, member in ipairs(item.members) do
            if member.tag == "fn" then
              Fuzz.label("functions returned as a union")
            end
          end
        end
        label_all(item, seen)
      end
    end
    for _, tp in ipairs(t.tparams) do
      local bound = tp.bound
      if bound ~= nil then
        Fuzz.label("bound")
      end
    end
  end
end

-- A type in normal form ------------------------------------------------------------------

--- Why a union is not in normal form, or "".
local function union_not_normal(t: Types.Union): string
  local members = t.members
  if #members < (if t.nilable then 1 else 2 end) then
    return "too few members: " .. Types.display(t)
  end
  local tags: mut {string: boolean} = {}
  local enum = false
  local previous = ""
  for _, m in ipairs(members) do
    tags[m.tag] = true
    if m.tag == "union" or m.tag == "nil" or m.tag == "never" or m.tag == "any" or m.tag == "invalid" then
      return "a " .. tostring(m.tag) .. " is a member of " .. Types.display(t)
    end
    if (m.tag == "named") and m.decl.kind == "enum" then
      enum = true
    end
    local d = Types.digest(m)
    if d <= previous then
      return "the members are not in digest order: " .. Types.display(t)
    end
    previous = d
  end
  if tags["integer"] and tags["number"] then
    return "integer beside number in " .. Types.display(t)
  end
  if (tags["true"] or tags["false"]) and tags["boolean"] then
    return "true or false beside boolean in " .. Types.display(t)
  end
  if tags["true"] and tags["false"] then
    return "true beside false in " .. Types.display(t)
  end
  if enum and tags["string"] == true then
    return "an enum beside string in " .. Types.display(t)
  end
  return ""
end

--- Why `t`, or a type inside it, is not in normal form, or "".
local function not_normal(t: Types.Type, seen: mut {integer: boolean}): string
  if seen[t.id] then
    return ""
  end
  seen[t.id] = true
  local parts: mut {Types.Type} = {}
  if (t.tag == "union") then
    local why = union_not_normal(t)
    if why ~= "" then
      return why
    end
    for _, member in ipairs(t.members) do
      parts[#parts + 1] = member
    end
  elseif (t.tag == "array") then
    parts = { t.element }
  elseif (t.tag == "map") then
    parts = { t.key, t.value }
  elseif (t.tag == "named") then
    for _, argument in ipairs(t.args) do
      parts[#parts + 1] = argument
    end
  elseif (t.tag == "fn") then
    for _, alt in ipairs(t.rets) do
      for _, item in ipairs(alt.items) do
        if item.tag == "never" then
          return "a never in an alternative of " .. Types.display(t)
        end
        parts[#parts + 1] = item
      end
    end
    for _, p in ipairs(t.params) do
      local param_type = p.type
      -- `any` absorbs the nil, so an omittable `any` is `any`.
      local optional = param_type.tag == "nil" or param_type.tag == "any" or param_type.tag == "invalid" or
        ((param_type.tag == "union") and param_type.nilable)
      if p.omittable == true and not optional then
        return "an omittable parameter that is not optional in " .. Types.display(t)
      end
      parts[#parts + 1] = p.type
    end
  end
  for _, part in ipairs(parts) do
    local why = not_normal(part, seen)
    if why ~= "" then
      return why
    end
  end
  return ""
end

-- The flags, by a plain recursion -----------------------------------------------------------

--- Every type a function type holds.
local function fn_parts(t: Types.Fn): {Types.Type}
  local parts: mut {Types.Type} = {}
  for _, tp in ipairs(t.tparams) do
    local bound = tp.bound
    if bound ~= nil then
      parts[#parts + 1] = bound
    end
  end
  for _, p in ipairs(t.params) do
    parts[#parts + 1] = p.type
  end
  local rest = t.rest
  if rest ~= nil then
    parts[#parts + 1] = rest
  end
  for _, alt in ipairs(t.rets) do
    for _, item in ipairs(alt.items) do
      parts[#parts + 1] = item
    end
    local tail = alt.tail
    if tail ~= nil then
      parts[#parts + 1] = tail
    end
    local narrows = alt.narrows
    if narrows ~= nil then
      parts[#parts + 1] = narrows.to
    end
  end
  return parts
end

--- `t`'s `open` and `has_mut`, worked out again from its parts.
local function flags(t: Types.Type): integer, boolean
  if (t.tag == "var") then
    return t.depth + 1, false
  end
  local parts: {Types.Type} = {}
  local own_mut = false
  if (t.tag == "named") then
    parts = t.args
  elseif (t.tag == "array") then
    parts = { t.element }
    own_mut = t.mut
  elseif (t.tag == "map") then
    parts = { t.key, t.value }
    own_mut = t.mut
  elseif (t.tag == "union") then
    parts = t.members
  elseif (t.tag == "fn") then
    parts = fn_parts(t)
  end
  local open, changes = 0, own_mut
  for _, part in ipairs(parts) do
    local o, m = flags(part)
    open = math.max(open, o)
    changes = changes or m
  end
  if (t.tag == "fn") and #t.tparams > 0 then
    open = math.max(0, open - 1)
  end
  -- A view does not reach through a named type or a function.
  return open, changes and not ((t.tag == "named") or (t.tag == "fn"))
end

local function flags_wrong(t: Types.Type, seen: mut {integer: boolean}): string
  if seen[t.id] then
    return ""
  end
  seen[t.id] = true
  local open, changes = flags(t)
  if open ~= t.open or changes ~= t.has_mut then
    return Types.display(t) .. " has open " .. tostring(t.open) .. " and has_mut " .. tostring(t.has_mut) ..
      ", worked out " .. tostring(open) .. " and " .. tostring(changes)
  end
  return ""
end

-- The properties --------------------------------------------------------------------------------

local function test_making_a_type_again_finds_it_and_adds_none(tmp: string)
  Fuzz.run({
    name = "types intern",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local draws = Programs.numbers(input)
      local w = world()
      local first = Programs.generate(w.store, w.fixture, draws)
      local size = w.store:size()
      local again = Programs.generate(w.store, w.fixture, draws)
      if again ~= first then
        return false, "made again, " .. Types.display(first) .. " is another type"
      end
      if w.store:size() ~= size then
        return false, "made again, " .. Types.display(first) .. " added " .. tostring(w.store:size() - size) .. " types"
      end
      local why = not_normal(first, {})
      if why ~= "" then
        return false, why
      end
      why = flags_wrong(first, {})
      if why ~= "" then
        return false, why
      end
      if first.open ~= 0 then
        return false, "a generated type is closed, " .. Types.display(first) .. " reaches " .. tostring(first.open)
      end
      label_all(first, {})
      return true, ""
    end,
    requires = { "array", "map", "union", "optional", "named", "fn", "generic use", "generic function", "bound",
      "omittable", "rest", "tail", "narrows", "never returns", "several alternatives", "mut", "var",
      "functions returned as a union", "shared parts" },
  })
end

--- The types that the draws `from` the `at`th number build, a few of them.
local function several(w: World, draws: {integer}): {Types.Type}
  local out: mut {Types.Type} = {}
  local count = 2 + (draws[1] or 0) % 5
  for i = 1, count do
    local slice: mut {integer} = {}
    for j = (i - 1) * 11 + 2, #draws do
      local draw = assert(draws[j], "`j` is within the draws")
      slice[#slice + 1] = draw
    end
    out[i] = Programs.generate(w.store, w.fixture, slice)
  end
  return out
end

--- The list rotated by `by`, and then every other member first.
local function shuffled(list: {Types.Type}, by: integer): {Types.Type}
  local out: mut {Types.Type} = {}
  local n = #list
  for i = 0, n - 1 do
    out[#out + 1] = assert(list[(i + by) % n + 1])
  end
  local odd: mut {Types.Type} = {}
  local even: mut {Types.Type} = {}
  for i, t in ipairs(out) do
    if i % 2 == 0 then
      even[#even + 1] = t
    else
      odd[#odd + 1] = t
    end
  end
  for _, t in ipairs(even) do
    odd[#odd + 1] = t
  end
  return odd
end

local function test_a_union_does_not_depend_on_the_order_grouping_or_store_of_its_members(tmp: string)
  Fuzz.run({
    name = "union order",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local draws = Programs.numbers(input)
      local w = world()
      local members = several(w, draws)
      local base = w.store:union(members)
      local text = Types.encode(base)
      local why = not_normal(base, {})
      if why ~= "" then
        return false, why
      end
      local function expect(other: Types.Type, how: string): boolean, string
        if other ~= base then
          return false, how .. " makes " .. Types.display(other) .. ", not " .. Types.display(base)
        end
        return true, ""
      end
      local ok, reason = expect(w.store:union(Programs.reversed(members)), "reversed")
      if not ok then
        return false, reason
      end
      ok, reason = expect(w.store:union(shuffled(members, draws[2] or 1)), "shuffled")
      if not ok then
        return false, reason
      end
      -- Grouped: the union of the halves, and a union with the members repeated.
      local half = #members // 2
      local left: mut {Types.Type} = {}
      local right: mut {Types.Type} = {}
      for i, m in ipairs(members) do
        if i <= half then
          left[#left + 1] = m
        else
          right[#right + 1] = m
        end
      end
      ok, reason = expect(w.store:union({ w.store:union(left), w.store:union(right) }), "grouped in two")
      if not ok then
        return false, reason
      end
      local folded = w.store.never
      for _, m in ipairs(members) do
        folded = w.store:union({ folded, m })
      end
      ok, reason = expect(folded, "folded")
      if not ok then
        return false, reason
      end
      local doubled: mut {Types.Type} = {}
      for _, m in ipairs(members) do
        doubled[#doubled + 1] = m
      end
      for _, m in ipairs(Programs.reversed(members)) do
        doubled[#doubled + 1] = m
      end
      ok, reason = expect(w.store:union(doubled), "repeated")
      if not ok then
        return false, reason
      end
      -- Another store makes the members in another order after other types, and has the same text.
      local other = crowded(w.store, draws)
      local there: mut {Types.Type} = {}
      for i, m in ipairs(Programs.reversed(members)) do
        local t, why_not = other:decode(Types.encode(m))
        if t == nil then
          return false, "decoding " .. Types.encode(m) .. ": " .. why_not
        end
        there[i] = t
      end
      local there_union = other:union(there)
      if Types.encode(there_union) ~= text then
        return false, "another store writes\n  " .. Types.encode(there_union) .. "\nnot\n  " .. text
      end
      if Types.display(there_union) ~= Types.display(base) then
        return false, "another store displays " .. Types.display(there_union) .. ", not " .. Types.display(base)
      end
      label_all(base, {})
      Fuzz.label(if #members >= 4 then "many members" else "few members" end)
      return true, ""
    end,
    requires = { "union", "optional", "many members", "named", "fn" },
  })
end

local function test_text_decodes_to_the_same_type_in_its_store_and_in_another(tmp: string)
  Fuzz.run({
    name = "types decode",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local draws = Programs.numbers(input)
      local w = world()
      local t = Programs.generate(w.store, w.fixture, draws)
      local text = Types.encode(t)
      local back, why = w.store:decode(text)
      if back ~= t then
        return false, "decoding " .. text .. " in its store gives " .. (back and Types.display(back) or why)
      end
      local other = crowded(w.store, draws)
      local there, reason = other:decode(text)
      if there == nil then
        return false, "decoding " .. text .. " in another store: " .. reason
      end
      if Types.encode(there) ~= text then
        return false, "another store writes\n  " .. Types.encode(there) .. "\nnot\n  " .. text
      end
      if Types.display(there) ~= Types.display(t) or Types.digest(there) ~= Types.digest(t) then
        return false, "another store displays " .. Types.display(there) .. ", not " .. Types.display(t)
      end
      if other:decode(text) ~= there then
        return false, "decoding twice in another store gives two types"
      end
      -- Every declaration the other store loaded has the text it has here.
      for _, decl in ipairs(other:declarations()) do
        local origin = w.store:find(decl.module, decl.name)
        if origin == nil or Types.encode_declaration(decl) ~= Types.encode_declaration(origin) then
          return false, "the declaration " .. decl.name .. " changed on the way"
        end
      end
      -- Back again: what the other store wrote reads as the original.
      if w.store:decode(Types.encode(there)) ~= t then
        return false, "the text of the other store's type reads as another type"
      end
      label_all(t, {})
      return true, ""
    end,
    requires = { "array", "map", "union", "optional", "named", "fn", "generic use", "generic function", "bound",
      "omittable", "tail", "narrows", "var" },
  })
end

local function test_the_display_of_a_type_parses_and_lowers_to_the_same_type(tmp: string)
  Fuzz.run({
    name = "types display parses",
    dir = tmp,
    gen = gen_draws,
    check = function(input: string): boolean, string
      local draws = Programs.numbers(input)
      local w = world()
      local t = Programs.generate(w.store, w.fixture, draws)
      local text = Types.display(t)
      local lowered, why = Programs.parse(w.store, w.fixture, text)
      if lowered == nil and why:find("refused ", 1, true) == 1 then
        -- a type the rules of declarations refuse: an array of optionals, a key that is no key, a union of records
        Fuzz.label("refused")
        return true, ""
      end
      if lowered == nil then
        return false, "the display " .. text .. " does not parse: " .. why
      end
      if lowered ~= t then
        return false, "the display " .. text .. " lowers to " .. Types.display(lowered) .. " (" .. Types.encode(lowered) ..
          "), not " .. Types.encode(t)
      end
      label_all(t, {})
      return true, ""
    end,
    requires = { "array", "map", "union", "optional", "named", "fn", "generic use", "generic function", "bound",
      "omittable", "tail", "narrows", "var", "several alternatives", "refused" },
    shares = { refused = 0.01 },
  })
end

--- The text of a random type with a few bytes changed, deleted, inserted or duplicated.
local function gen_mutated_text(src: Fuzz.Source): string
  local draws: mut {integer} = {}
  while Fuzz.more(src, #draws, 60) do
    draws[#draws + 1] = src:int(0, 99)
  end
  local w = world()
  local t = Programs.generate(w.store, w.fixture, draws)
  return Fuzz.mutate(src, Types.encode(t), 4)
end

local function test_text_with_a_few_bytes_changed_decodes_to_a_type_in_normal_form_or_is_refused(tmp: string)
  Fuzz.run({
    name = "types decode mutated text",
    dir = tmp,
    gen = gen_mutated_text,
    check = function(input: string): boolean, string
      -- A store with no declaration, which loads them from the fixture's as the text meets them.
      local origin = world()
      local fresh = Types.new(function(module: string, name: string): string?
        local decl = origin.store:find(module, name)
        return decl ~= nil and Types.encode_declaration(decl) or nil
      end)
      local size, declared = fresh:size(), #fresh:declarations()
      local t, why = fresh:decode(input)
      if t == nil then
        if why:find("types:", 1, true) ~= 1 then
          return false, "the refusal does not say whose it is: " .. why
        end
        if fresh:size() ~= size or #fresh:declarations() ~= declared then
          return false, "a refusal left " .. tostring(fresh:size() - size) .. " types and " .. tostring(#fresh:declarations() - declared) ..
            " declarations: " .. why
        end
        Fuzz.label("refused")
        return true, ""
      end
      Fuzz.label("decoded")
      local reason = not_normal(t, {})
      if reason ~= "" then
        return false, reason
      end
      local text = Types.encode(t)
      if fresh:decode(text) ~= t then
        return false, "the text " .. text .. " of the decoded type " .. input .. " reads as another type"
      end
      for _, decl in ipairs(fresh:declarations()) do
        if decl.body == nil then
          return false, "the declaration " .. decl.name .. " was left with no body"
        end
      end
      return true, ""
    end,
    requires = { "decoded", "refused" },
    shares = { refused = 0.2 },
  })
end
