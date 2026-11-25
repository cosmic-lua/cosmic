--- How the checker refuses a value: the fixes it writes for a type that is not the one wanted, and the parts it does not check yet.

local Ast = require("lang.ast")
local Codes = require("lang.check_codes")
local Relation = require("lang.relation")
local Types = require("lang.types")
local Context = require("lang.check.context")
local Naming = require("lang.check.naming")
local type Type = Types.Type
local type Decl = Types.Decl
local type Code = Codes.Code
local type Ctx = Context.Ctx
local below = Context.below
local is_bool = Context.is_bool
local listed = Context.listed
local members_of = Context.members_of
local nilable = Context.nilable
local peel = Context.peel
local quoted = Context.quoted
local report = Naming.report
local show = Context.show
local subject = Context.subject
local text_of = Context.text_of

local record Refusals
  --- What the fix of a value that is none of the arms of a recursive alias adds, and what a table literal wanted as an
  --- interface is told in place of the generic fix, by the type (`<module> <name>`): the library's own advice for the type it
  --- declares, in words that name its functions.
  advice: {string: string}
end

Refusals.advice = {
  ["cosmic.json Json.Value empty"] = "write an empty array as `Json.array()`, which encodes as `[]`, and an empty object as a typed " ..
    "local (`local none: {string: Json.Value} = {}`): an unmarked empty table encodes as `{}`",
  ["cosmic.time Time.CivilFields"] = "write the literal where it is typed as the record that lists it: `local wall: Time.Wall = " ..
    "{ ... }`, or `Time.Civil`; for a date alone, `Time.parse_date(text, zone)` reads one",
  ["cosmic.json Json.Value"] = "for a record or a class of your own, call `Json.encode_any`, which takes any value",
  ["cosmic.sandbox.policy rules.Policy .promises"] = "a promise is a grant now: write `grants = { { calls = \"fork\" } }`, " ..
    "and read them with `Sandbox.calls(policy)`",
  ["cosmic.sandbox.policy rules.Policy .connect"] = "a host is a grant now: write " ..
    "`grants = { { connect = \"github.com:443\" } }`, and read them with `Sandbox.connects(policy)`",
  ["cosmic.internal.test_policy test_policy.Policy .promises"] = "a promise is a grant now: write " ..
    "`grants = { { calls = \"nest\" } }`",
  -- The names other languages give what these records have under another, which programs guess most.
  ["cosmic.json Json .parse"] = "`Json.decode(text)` reads JSON text: `local value, why = Json.decode(text)`",
  ["cosmic.json Json .stringify"] = "`Json.encode(value)` writes JSON text: `local text, why = Json.encode(value)`",
  ["cosmic.json Json .dumps"] = "`Json.encode(value)` writes JSON text: `local text, why = Json.encode(value)`",
  ["cosmic.json Json .loads"] = "`Json.decode(text)` reads JSON text: `local value, why = Json.decode(text)`",
  ["cosmic.fs Fs .exists"] = "`Fs.status(path)` tells whether anything is there: `local status = Fs.status(path)!`, " ..
    "then `status.exists`",
  ["cosmic.fs Fs .glob"] = "`Fs.walk(root)` lists every file under `root`, relative to it: filter the list with `path:match(...)`",
  ["cosmic.fs Fs .listdir"] = "`Fs.list(path)` lists the names in a directory",
  ["cosmic.fs Fs .readdir"] = "`Fs.list(path)` lists the names in a directory",
}

--- Whether a value of the optional type `t` may be a boolean where it is not nil: `false` is then a value of it, which a
--- test for truth takes for nil.
function Refusals.holds_boolean(ctx: Ctx, t: Type): boolean
  if not nilable(t) then
    return false
  end
  for _, m in ipairs(members_of(ctx.store, ctx.store:non_nil(t))) do
    if is_bool(m) then
      return true
    end
  end
  return false
end
local holds_boolean = Refusals.holds_boolean

--- The fix for a read `e` of an index that may be nil. A map's key may be missing, so its read is tested, taken with
--- `!` (`e!`, which is `assert(e)`) or given a default. For an array, the counted loop and the range test are offered only where they could
--- apply: an array that is a local name, read at a name. [`Array.at`] and `!` take any array and key; `or <default>` is steered from.
--
-- A value that may hold a boolean (`t`) is not taken with `assert(x)`, which raises for false and is refused
-- (`asserted_boolean` in [`lang.check.calls`]), nor given a default with `or`, which replaces false: it is named and said to be there.
local function index_fix(ctx: Ctx, e: Ast.Index, t: Type): string
  local xs, key = text_of(ctx, e.object), text_of(ctx, e.key)
  local read = text_of(ctx, e)
  local flag = holds_boolean(ctx, t)
  local named = "name it and say it is there (`local v = " .. read .. "` then `assert(v ~= nil)`)"
  if ctx.map_reads[e.id] == true then
    if flag then
      return "test it (`local v = " .. read .. " if v ~= nil then ... end`), or " .. named .. " where the key must be there"
    end
    return "test it (`local v = " .. read .. " if v ~= nil then ... end`), take it with `" .. read .. "!` where " ..
      "the key must be there, or write `" .. read .. " or <default>` where a missing key means that default"
  end
  local object, at = peel(e.object), peel(e.key)
  local parts = "iterate with `for _, v in ipairs(" .. xs .. ")`, "
  if object.kind == "Name" and at.kind == "Name" then
    parts = parts .. "count the keys with `for " .. key .. " = 1, #" .. xs .. " do` or test the index with `if " .. key ..
      " >= 1 and " .. key .. " <= #" .. xs .. " then`, which read " .. quoted(read) .. " as a value only where nothing " ..
      "in the body, before the read or after it, calls a function that may run code of the program: one it declares, " ..
      "one of the library that may (`table.insert`, `pcall`, `ipairs`), or one given a function or a class value " ..
      "(`print`, `tostring`, `string.*`, `math.*` and a string's methods, given strings, numbers or arrays of them, do " ..
      "not count), compares two locals with `<`, `<=`, `>` or `>=` (`v > best` counts; `v > 0` does not), loops " ..
      "with `for ... in`, or assigns " .. quoted(xs) .. " or " .. quoted(key) .. "; else "
  end
  return parts .. "read it with `Array.at(" .. xs .. ", " .. key .. ")` (`cosmic.array`: raises when missing)" ..
    (if flag then ", " .. named else " or `" .. read .. "!`" end) .. ", or test it (`local v = " .. read .. " if v ~= nil then ... end`); `or <default>` turns an out-of-range " ..
    "read into a wrong value"
end

--- The fix for a value of type `t` that may be nil. One that may hold a boolean is not sent to `assert(x)`, as in
--- [`index_fix`].
function Refusals.nil_fix(ctx: Ctx, node: Ast.Node, t: Type): string
  local e = peel(node)
  local flag = holds_boolean(ctx, t)
  if (e.kind == "Call") or (e.kind == "MethodCall") then
    local call = subject(ctx, e)
    if flag then
      return "name the value and say it is there (`local v = " .. text_of(ctx, e) .. "` then `assert(v ~= nil)`), or test " ..
        "it first (`if v == nil then " .. Naming.on_nil(ctx, "v") .. " end`); " .. call .. " answers nil when it fails"
    end
    return "take the value with `local v = " .. text_of(ctx, e) .. "!`, or test it first (`if v == nil then " ..
      Naming.on_nil(ctx, "v") .. " end`); " .. call .. " answers nil when it fails"
  end
  if e.kind == "Index" then
    return index_fix(ctx, e, t)
  end
  local s = text_of(ctx, e)
  if (e.kind == "Field") then
    return "copy " .. quoted(s) .. " to a local and test that: `local v = " .. s .. " if v ~= nil then ... end`, or " ..
      (if flag then "say it is there with `assert(v ~= nil)`" else "take it with `" .. s .. "!`" end)
  end
  return "test it first (`if " .. s .. " == nil then " .. Naming.on_nil(ctx, s) .. " end`), or " ..
    (if flag then "say it is there with `assert(" .. s .. " ~= nil)`" else "take it with `" .. s .. "!`" end)
end
local nil_fix = Refusals.nil_fix

--- Whether the type `t` names `invalid` anywhere.
function Refusals.names_invalid(t: Type): boolean
  if t.tag == "invalid" then
    return true
  end
  for _, part in ipairs(Types.parts(t)) do
    if Refusals.names_invalid(part) then
      return true
    end
  end
  return false
end
local names_invalid = Refusals.names_invalid

--- For `e` that names a local made by a `local` statement with a type that has no nil (a cursor made of a value, which
--- runs out to nil later: `local p = 1`): the fix that declares it optional where it is made, so it may be nil. Nil for
--- a parameter, a loop variable, a global, or a local whose type has nil or reads otherwise with `?`.
function Refusals.optional_local(ctx: Ctx, e: Ast.Node): string?
  local at = peel(e)
  if not (at.kind == "Name") then return nil end
  local id = at.binding
  if id == nil then return nil end
  local v, t = ctx.scoped.vars[id], ctx.vars[id]
  if v == nil or t == nil or v.kind ~= "local" then return nil end
  -- A type that `T?` writes plainly: no union, function or type variable, whose `?` would read otherwise.
  local tag = t.tag
  if not (tag == "integer" or tag == "number" or tag == "string" or tag == "boolean" or tag == "true" or
      tag == "false" or tag == "named" or tag == "array" or tag == "map") then
    return nil
  end
  local shown = Types.display(t, ctx.binders, ctx.fn_names)
  return "declare `" .. at.text .. "` `" .. shown .. "?` where it is declared (`local " .. at.text .. ": " .. shown ..
    "? = ...`), so it may be nil"
end

--- Reports that the value of `node`, of type `got`, is not below `want`, and `r` says why. `where` is a phrase that
--- says what wants it, with a space before it, or "". `named` is how to write `want` where the program spells it
--- otherwise than the type is (a parameter of a generic function that a failed inference made `invalid`).
function Refusals.refused(ctx: Ctx, node: Ast.Node, got: Type, want: Type, r: Relation.Refusal, where: string, named?: string)
  local s = subject(ctx, node)
  local g, w = show(ctx, got), named or show(ctx, want)
  local shown = { g, w }
  local alternatives = r.alternatives
  local only = if alternatives ~= nil and #alternatives == 1 then alternatives[1] else nil end
  if r.code == "union_none" and only ~= nil and (r.sub.tag == "named") and Types.inferred_record(r.sub.decl) then
    -- A record inferred for a literal, where one record or nil is wanted: why that record refuses it is the reason.
    r = only
  end
  local code = r.code
  local from, into = r.sub, r.super
  if code ~= "declaration_value" then
    -- A module held in what is given (the `Box<Queue>` of `Bx.of(Queues)`, the `Queue` of an argument beside a `{Queue}`)
    -- where a value of its declaration is wanted, whatever the place around it (`Queue?`, a generic, an optional field).
    -- The module in `t` where `decl` is nil, else the type of values of `decl`.
    local function find(t: Type, decl: Decl?): Type?
      if (t.tag == "named") then
        if decl == nil and t.value and (t.decl.kind == "record" or t.decl.kind == "class") then
          return t
        elseif decl ~= nil and not t.value and t.decl == decl then
          return t
        end
      end
      for _, part in ipairs(Types.parts(t)) do
        local found = find(part, decl)
        if found ~= nil then
          return found
        end
      end
      return nil
    end
    local held = find(got, nil)
    if held ~= nil and (held.tag == "named") then
      local wanted = find(want, held.decl)
      if wanted ~= nil then
        code, from, into = "declaration_value", held, wanted
      end
    end
  end
  local e = peel(node)
  if code == "nil" then
    if got.tag == "nil" then
      -- A local made of a value and set to nil later (a cursor that runs out) is declared optional where it is made.
      local target = ctx.written
      local cursor = if target ~= nil then Refusals.optional_local(ctx, target) else nil end
      report(ctx, "nil_not_allowed", node, "nil is given" .. where .. ", where " .. quoted(w) .. " is wanted",
        if cursor ~= nil then cursor .. ", or give a value" else
          "give a value, or declare what takes it `" .. w .. "?` (a parameter or field `name?: T`)" end, shown)
    elseif (e.kind == "Index") then
      report(ctx, "index_may_be_nil", node, s .. " is " .. quoted(g) .. " (an index read may be nil), where " ..
          quoted(w) .. " is wanted" .. where,
        index_fix(ctx, e, got), shown)
    else
      report(ctx, "nil_not_allowed", node, s .. " is " .. quoted(g) .. ", so it may be nil, where " .. quoted(w) ..
          " is wanted" .. where, nil_fix(ctx, node, got), shown)
    end
  elseif code == "view_as_mut" then
    -- A view where a `mut` collection of a parameter that nothing else solved is wanted taints it: the collection
    -- wanted is the view, made `mut`.
    local super = Types.display(r.super, ctx.binders, ctx.fn_names)
    local made = w
    if names_invalid(r.super) and g:sub(1, 1) == "{" then
      made = "mut " .. g
      super = made
    end
    local held = Types.display(r.sub, ctx.binders, ctx.fn_names)
    local fix = "declare " .. s .. " `" .. made .. "` where it is made or received, or pass a collection made `mut`"
    -- An argument's receiver is a parameter, which may be `mut` by mistake: one typed as the view takes both.
    local callee = where:match("^ as argument %d+ of (`.+`)$")
    if callee ~= nil then
      fix = fix .. "; or, if " .. callee .. " does not change it, declare that parameter `" .. held .. "`, which takes both"
    end
    report(ctx, "view_as_mut", node, s .. " is " .. quoted(g) .. ", where " .. quoted(w) .. " is wanted" .. where ..
        ": the view " .. quoted(held) .. " is not " .. quoted(super) .. ", which the receiver may change", fix, shown)
  elseif code == "invariant_mut" or code == "invariant_key" then
    report(ctx, "invariant_mut", node, quoted(Types.display(r.sub, ctx.binders, ctx.fn_names)) .. " is not " ..
        quoted(Types.display(r.super, ctx.binders, ctx.fn_names)) .. " (" .. s .. " is " .. quoted(g) .. ", where " .. quoted(w) ..
        " is wanted" .. where .. "): a receiver could store another element type through a `mut` collection",
      "pass a view, or declare the receiver's type " .. quoted(g) .. " as the argument has it", shown)
  elseif code == "declaration_value" then
    local decl: Decl? = nil
    if from.tag == "named" then
      decl = from.decl
    elseif into.tag == "named" then
      decl = into.decl
    end
    local name, kind = g, "record"
    if decl ~= nil then
      name, kind = decl.name, decl.kind
    end
    if kind == "integer_enum" and (from.tag == "named") and from.value then
      report(ctx, "declaration_value", node, s .. " is " .. quoted(g) .. ", the table of the members of the integer enum " ..
          quoted(name) .. ", where " .. quoted(w) .. " is wanted" .. where,
        "pass a member (" .. quoted(name .. ".NAME") .. "), not the table", shown)
    elseif kind ~= "class" then
      -- A module is a record used as a value, and the places that hold one (a field `Seatbelt: Seatbelt`, an array
      -- `{Child}`, `local raw: hash = require(...)`) are typed with the record, whose values are not the module.
      -- The fix is the statement that requires it where it is used, unless the declaration is this module's own or
      -- declared in a block of it.
      local fix = "call a function on the module (" .. quoted(name .. ".f(...)") .. ") or pass the function itself, not the module"
      if decl ~= nil and decl.module ~= ctx.input.module and not decl.module:find("@", 1, true) then
        fix = "require the module where you use it (`local " .. decl.name .. " = require(\"" .. decl.module .. "\")`), " ..
          "instead of passing it" .. where
      end
      report(ctx, "declaration_value", node, s .. " is " .. quoted(g) .. ", the table of the functions of " .. quoted(name) ..
          ", where " .. quoted(w) .. " is wanted" .. where, fix, shown)
    elseif (from.tag == "named") and from.value then
      local fix = "make a value with a table literal typed as the type (`local v: " .. name .. " = { ... }`), or call a " ..
        "function of " .. quoted(name) .. " that makes one (`" .. name .. ".new(...)`)"
      if decl ~= nil and decl.module ~= ctx.input.module and not decl.module:find("@", 1, true) then
        -- A class of another module, stored where its values belong: the module is required where it is used.
        fix = "require the module where you use it (`local " .. decl.name .. " = require(\"" .. decl.module .. "\")`), " ..
          "instead of passing it" .. where .. "; to make a value, call a function of " .. quoted(name) ..
          " that makes one (`" .. name .. ".new(...)`)"
      end
      report(ctx, "declaration_value", node, s .. " is " .. quoted(g) .. ", the table of the functions of " .. quoted(name) ..
          ", where a value of " .. quoted(w) .. " is wanted" .. where, fix, shown)
    else
      report(ctx, "declaration_value", node, s .. " is a value of " .. quoted(name) .. ", where the declaration " ..
          quoted(name) .. " itself is wanted" .. where,
        "pass the declaration " .. quoted(name) .. ", not a value of it", shown)
    end
  elseif code == "record_as_map" or code == "map_as_record" then
    report(ctx, "record_as_map", node, s .. " is " .. quoted(g) .. ", where " .. quoted(w) .. " is wanted" .. where ..
        ": " .. (if code == "record_as_map" then "a record is not a map" else "a map is not a record" end),
      "pass a value of the declared type, or declare a map `{K: V}` for the data that is keyed", shown)
  elseif code == "any_source" or code == "any_sink" then
    if code == "any_source" then
      report(ctx, "any_use", node, s .. " is untrusted data (`any`), where " .. quoted(w) .. " is wanted" .. where,
        "validate it with a [`cosmic.shape`] validator, or test its tag (`type(" .. text_of(ctx, e) ..
          ") == \"string\"`), and use the checked value", shown)
    else
      report(ctx, "any_use", node, s .. " is " .. quoted(g) .. " and would be stored as untrusted data (`any`)" .. where,
        "declare what holds it with the type it has: `any` takes a value only as an argument to a parameter declared `any`",
        shown)
    end
  else
    local leaf = ""
    if code == "invariant_generic" then
      -- The arguments may well be related (`integer` is below `number`): the uses differ because the declaration both
      -- reads and writes that argument.
      leaf = " (" .. quoted(Types.display(r.sub, ctx.binders, ctx.fn_names)) .. " and " .. quoted(Types.display(r.super, ctx.binders, ctx.fn_names)) ..
        " are two types, and a type argument the declaration both reads and writes (by a `mut` field, a `mut` " ..
        "collection or a map's key) must be the same: " .. quoted(g) .. " is no " .. quoted(w) .. ")"
    elseif (r.sub ~= got or r.super ~= want) and not (code == "not_listed" and (r.sub.tag == "named") and
        Types.inferred_record(r.sub.decl)) then
      leaf = " (" .. quoted(Types.display(r.sub, ctx.binders, ctx.fn_names)) .. " is not below " ..
        quoted(Types.display(r.super, ctx.binders, ctx.fn_names)) .. ")"
    end
    local fix = "pass a value of type " .. quoted(w) .. ", or change the declaration to " .. quoted(g)
    local inferred = if (r.sub.tag == "named") and not r.sub.value then Types.inferred_record(r.sub.decl) else false end
    if inferred and code == "nominal" then
      -- A record inferred for a literal is below a record of the same fields, and no class: a class's values are made
      -- by a literal written against it.
      local sup = r.super
      local extra: string? = nil
      local mine = if (r.sub.tag == "named") then r.sub.decl.body else nil end
      local theirs = if (sup.tag == "named") and sup.decl.kind == "record" then sup.decl.body else nil end
      if mine ~= nil and theirs ~= nil then
        local declared: mut {string: boolean} = {}
        for _, f in ipairs(theirs.fields) do
          declared[f.name] = true
        end
        for _, f in ipairs(mine.fields) do
          if extra == nil and declared[f.name] ~= true then
            extra = f.name
          end
        end
      end
      fix = (if extra ~= nil then "remove `" .. extra .. "`, which " .. quoted(Types.display(sup, ctx.binders, ctx.fn_names)) ..
          " has no field of, or " else "" end) .. "write the literal against " .. quoted(w) .. " where it is made (`local v: " ..
        w .. " = { ... }`)"
    end
    local held = where:match("^ in the assignment to `([%a_][%w_]*)`$")
    local text_wanted = want == ctx.store.string
    if not text_wanted and (want.tag == "union") then
      -- `string?` wants a text as well.
      text_wanted = true
      for _, m in ipairs(members_of(ctx.store, want)) do
        if m ~= ctx.store.string and m.tag ~= "nil" then
          text_wanted = false
        end
      end
    end
    if text_wanted and Types.declares_method(got, "__tostring") then
      -- A class value with a text of its own (a [`cosmic.failure`]) is no string, and `tostring` gives its text.
      fix = "pass its text, `tostring(" .. text_of(ctx, node) .. ")`, or change the declaration to " .. quoted(g)
    end
    if want.tag == "nil" and held ~= nil then
      -- A local given `nil` and no type holds nil alone (`local x = nil`).
      fix = "declare `" .. held .. "` optional where it is made: `local " .. held .. ": " .. g ..
        (if nilable(got) then "" else "?" end) .. " = nil`"
    end
    local body = Types.unfold(want)
    if body ~= want then
      -- A recursive alias is wanted: its arms are what the program has to choose among.
      local arms: mut {string} = {}
      for _, m in ipairs(members_of(ctx.store, body)) do
        if m.tag ~= "nil" then
          arms[#arms + 1] = quoted(show(ctx, m))
        end
      end
      table.sort(arms)
      leaf = leaf .. "; " .. quoted(w) .. " is " .. listed(arms)
      fix = "make the value one of the arms of " .. quoted(w) .. ": " .. listed(arms) .. ", which " .. quoted(g) .. " is none of"
      if (want.tag == "named") then
        local advised = Refusals.advice[want.decl.module .. " " .. want.decl.name]
        if advised ~= nil then
          fix = fix .. "; " .. advised
        end
      end
    end
    if code == "number_for_integer" then
      fix = "convert with `math.tointeger(" .. text_of(ctx, e) .. ")` or `math.floor(" .. text_of(ctx, e) ..
        ")`, or declare what takes it `number`"
      local target = ctx.written
      local bound = if target ~= nil then target.binding else nil end
      local start = if bound ~= nil then ctx.starts[bound] else nil end
      if start ~= nil and target ~= nil then
        -- `math.tointeger` of a fraction is nil, and the name is an integer only because it started as one.
        local float = if start:find("^-?%d+$") then start .. ".0" else nil end
        fix = "start " .. subject(ctx, target) .. " as " .. (if float ~= nil then "`" .. float .. "`" else "a float" end) ..
          " where it is declared, or declare what takes it `number` (`local " .. target.text .. ": number = " .. start .. "`)"
      end
    elseif code == "not_listed" then
      local sub = quoted(Types.display(r.sub, ctx.binders, ctx.fn_names))
      local field = r.field
      if field ~= nil then
        -- A type conforms to an interface by having each of its fields as the interface declares them.
        local written = (if field.mut == true then "mut " else "" end) .. field.name ..
          (if field.omittable == true then "?" else "" end) .. ": " ..
          Types.display(if field.omittable == true then ctx.store:non_nil(field.type) else field.type end, ctx.binders,
            ctx.fn_names)
        leaf = leaf .. " (" .. sub .. (if r.has_name == true then " has `" .. field.name .. "`, but not as " else
          " has no field " end) .. quoted(written) .. ", which " .. quoted(Types.display(r.super, ctx.binders,
            ctx.fn_names)) .. " declares)"
        fix = "declare `" .. written .. "` in " .. sub .. ", as the interface does, or pass a value that has it"
        if (r.sub.tag == "named") and Types.shape_record(r.sub.decl) then
          fix = "write `" .. written .. "` in the braces of " .. sub .. ", or pass a value that has it"
        end
        if (r.sub.tag == "named") and Types.inferred_record(r.sub.decl) then
          local record = Types.display(r.super, ctx.binders, ctx.fn_names)
          local name = text_of(ctx, e)
          local against = "write the literal against " .. quoted(record) .. " where it is made (`local " ..
            (if name:match("^[%a_][%w_]*$") then name else "v" end) .. ": " .. record .. " = { ... }`)"
          fix = "give `" .. field.name .. "` in the literal as " .. quoted(Types.display(r.super, ctx.binders, ctx.fn_names)) ..
            " declares it, or " .. against
          if field.mut == true then
            -- A write through the record wanted would change, or add, a field that the literal's own record holds fixed.
            fix = against .. ": a write of `" .. field.name .. "` through " .. quoted(record) ..
              " would change a record whose type does not let it"
            if r.has_name == true and field.omittable ~= true and name:match("^[%a_][%w_]*$") ~= nil then
              -- Its own writes make the literal's field `mut`, of the type of its value.
              fix = fix .. "; or give `" .. field.name .. "` a value of exactly " .. quoted(Types.display(
                ctx.store:non_nil(field.type), ctx.binders, ctx.fn_names)) .. " and assign it through `" .. name ..
                "`, which makes it `mut`"
            end
          end
        end
      else
        fix = "pass a record, class or interface that has the interface's fields, or one that lists it with `is`"
      end
    elseif code == "may_return" then
      fix = "declare the function `: never` and end it with `error`, or pass a function that returns"
    end
    report(ctx, "not_assignable", node, s .. " is " .. quoted(g) .. ", where " .. quoted(w) .. " is wanted" .. where ..
        leaf, fix, shown)
  end
end
local refused = Refusals.refused

--- Whether the checker sees the parameter list of the function `node` writes or names: a function literal, or a
--- `local function` that nothing assigns. The type of a variable, field, parameter or return of function type is what
--- was declared, which may leave out parameters the value takes ([`Relation.subtype_known`]).
local function knows_parameters(ctx: Ctx, node: Ast.Node): boolean
  if ctx.no_drop then
    return false
  end
  local at = peel(node)
  if at.kind == "FunctionLit" then
    return true
  end
  if at.kind == "Name" then
    local id = at.binding
    if id == nil then
      return false
    end
    local v = ctx.scoped.vars[id]
    return v ~= nil and v.fn ~= nil and not v.assigned
  end
  return false
end

--- Whether the value of `node`, of type `got`, may stand where `want` is wanted, reporting it where not.
function Refusals.expect(ctx: Ctx, node: Ast.Node, got: Type, want: Type, where: string, named?: string): boolean
  local known = knows_parameters(ctx, node)
  if below(ctx, got, want) or (known and Relation.subtype_known(ctx.judge, got, want)) then
    return true
  end
  local r = ctx.judge:refuse(got, want)
  if r ~= nil then
    refused(ctx, node, got, want, r, where, named)
  end
  return false
end
local expect = Refusals.expect

--- [`expect`] for a position that accepts any value as `any`: an argument to a parameter declared `any`.
function Refusals.expect_argument(ctx: Ctx, node: Ast.Node, got: Type, want: Type, where: string, named?: string): boolean
  if want.tag == "any" then
    return true
  end
  return expect(ctx, node, got, want, where, named)
end

--- Reports a form a later piece of the checker types, whose result is `invalid`.
function Refusals.unchecked(ctx: Ctx, code: Code, node: Ast.Node, what: string)
  local row = Codes.row(code)
  report(ctx, code, node, what .. ", which the checker types in a later piece: its result is `invalid`, and reported " ..
      "here so that no `invalid` is silent", row ~= nil and row.fix or "none yet") -- checked: and_ternary
end

return Refusals
