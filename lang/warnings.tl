--- The new checker's warnings ([`lang.check`]): what the fork's checker reports as a warning and no error, in three of its
--- four kinds. A warning is not a mistake in the program's types: a build that rejects any warning ([`build.driver`]) does so by
--- choice, and a check of the tree counts them by code.
---
--- **`unused`** (a variable, argument, function or type that nothing reads, writes or, for a type, names) and
--- **`unread`** (a name that is assigned and never read) come from the facts the scope builder keeps for each binding
--- ([`lang.scopes`]); the kind of a local depends on its type (a function-valued local is a function), which the checker
--- gives. A name that begins with `_` is exempt, as the fork has it, and a function whose only readers are its own body is
--- unused (a recursive call is no use). **`hint`** is a form that works and has a better spelling:
--- a method called with `.` and its receiver named twice (`r.m(r)`).
---
--- What the fork also hints at is an error here, or waits for a piece the checker lacks. `pairs` of an array, `#` of a map
--- with numeric keys, `a or b` of two types, the values a call does not give a `local`, and an `is` no value can pass
--- (the fork's `branch` warning, whose positive form is its error) are errors of the new checker (`not_assignable`,
--- `float_key`, `operand_type`, `value_count`, `is_disjoint`). The hints about the format string of `string.format`,
--- `string.pack` and `string.unpack` and about the patterns of `string.find`, `string.match`, `string.gmatch` and
--- `string.gsub` need the checker to read those strings, which it does not yet.
---
-- TODO: report a test that cannot fail (the `branch` kind: an `is` whose value is already of the type tested), once the
-- checker can tell a value its types vouch for from one they only claim: a value narrowed through a test it refuses
-- (`is_on_record` on an `any`), a parameter of a function called from untyped code and the keys of a decoded table are
-- typed, and the tests that guard them are live. Until then "remove the test" would delete the guard.
--
-- TODO: report the malformed or odd format strings and patterns of the standard library's string functions (`%y`, a
-- pattern missing its `]`), once the checker types `string.format` and the pattern functions from their literal arguments:
-- the fork warns of these as a `hint`.
local Lexer = require("lang.lexer")
local Scopes = require("lang.scopes")
local Types = require("lang.types")

local record Warnings
  --- The fork's kinds of warning that this checker reports.
  enum Kind
    "unused"
    "unread"
    "hint"
  end

  --- What a warning is, so that a reader does not parse its `msg`.
  enum Code
    -- a local, loop variable or match binding that nothing reads or assigns
    "unused_variable"
    -- a parameter that nothing reads or assigns
    "unused_argument"
    -- a function that nothing calls or reads, a recursive call apart
    "unused_function"
    -- a type (a record, interface, class, enum or alias, or a module that is one) that nothing names or reads
    "unused_type"
    -- a name that is assigned and never read
    "unread"
    -- a method called with `.` and its receiver named twice, `r.m(r)`
    "method_dot"
  end

  --- A warning, with the place of its tokens.
  record Warning
    filename: string
    code: Code
    kind: Kind
    --- What is the matter, in one line.
    msg: string
    --- The change that removes it, written against the program's own names.
    fix: string
    y: integer
    x: integer
    offset: integer
    length: integer
  end

  --- The rule behind a code.
  record Row
    code: Code
    kind: Kind
    --- The rule, named for what it holds.
    rule: string
    --- Why the language holds it.
    why: string
    --- What the fix says, with the placeholders `<...>` the warning fills from the program.
    fix: string
  end

  --- Every [`Code`], in the order the enum lists them.
  codes: {Code}

  --- The rule behind each code, in the order of `codes`.
  catalog: {Row}

  --- The kind of `code`.
  kind_of: function(code: Code): Kind

  --- The `unused` and `unread` warnings of a module: for each binding of `scoped` that is neither exempt nor used, in source
  --- order. `types` gives the type of each local, parameter and loop variable by [`Scopes.Var.id`]
  --- ([`Check.Checked.vars`](lang.check)), which tells a function-valued local from a variable, and `display` writes a
  --- type.
  usage: function(filename: string, tokens: Lexer.Tokens, scoped: Scopes.Scoped, types: {integer: Types.Type},
                  display: function(t: Types.Type): string): {Warning}

  --- Adds the warning `code` at the tokens `first` to `last` to `list`.
  add: function(list: {Warning}, filename: string, tokens: Lexer.Tokens, code: Code, first: integer, last: integer,
                msg: string, fix: string)
end

Warnings.codes = {
  "unused_variable", "unused_argument", "unused_function", "unused_type", "unread", "method_dot",
}

local UNUSED_FIX <const> = "name it `_` or `_<name>` to say it is meant to be unused, or remove it"

Warnings.catalog = {
  {
    code = "unused_variable", kind = "unused", rule = "names are used",
    why = "a local, loop variable or match binding that nothing reads or assigns is dead code, or a name the program " ..
      "meant to use and spelled otherwise",
    fix = UNUSED_FIX,
  },
  {
    code = "unused_argument", kind = "unused", rule = "names are used",
    why = "a parameter that nothing reads or assigns is a value the function ignores, or a name the body spelled " ..
      "otherwise",
    fix = UNUSED_FIX,
  },
  {
    code = "unused_function", kind = "unused", rule = "names are used",
    why = "a local function that nothing calls or reads (a recursive call of its own body is not a use) is dead code",
    fix = "remove it, or return it from the module if other files call it",
  },
  {
    code = "unused_type", kind = "unused", rule = "names are used",
    why = "a type that no annotation names and no code reads is dead code, or a module required for the type it " ..
      "returns and never used",
    fix = "remove it, or use it in the signature or annotation it was meant for",
  },
  {
    code = "unread", kind = "unread", rule = "names are used",
    why = "a name that is assigned and never read holds a value nothing looks at, so the assignments are dead, or the " ..
      "read is missing",
    fix = "read <name> where its value is wanted, or remove it and the assignments to it",
  },
  {
    code = "method_dot", kind = "hint", rule = "a method is called on its receiver",
    why = "a function that takes its own type as its first parameter is a method, and `r.m(r)` names the receiver twice; " ..
      "`r:m()` passes it once, and cannot pass another by mistake",
    fix = "write <receiver>:<method>(<arguments>)",
  },
}

--- The code of an unused name, by what it declares.
local UNUSED <const>: {string: Warnings.Code} = {
  variable = "unused_variable", argument = "unused_argument", ["function"] = "unused_function", type = "unused_type",
}

local KINDS <const>: {string: Warnings.Kind} = {
  unused_variable = "unused", unused_argument = "unused", unused_function = "unused", unused_type = "unused",
  unread = "unread", method_dot = "hint",
}

function Warnings.kind_of(code: Warnings.Code): Warnings.Kind
  return KINDS[tostring(code)] or "hint"
end

function Warnings.add(list: mut {Warnings.Warning}, filename: string, tokens: Lexer.Tokens, code: Warnings.Code,
                      first: integer, last: integer, msg: string, fix: string)
  local to = math.max(first, last)
  if tokens.text[first] == nil or tokens.text[to] == nil then
    return
  end
  table.insert(list, {
    filename = filename, code = code, kind = Warnings.kind_of(code), msg = msg, fix = fix, y = Lexer.y(tokens, first),
    x = Lexer.x(tokens, first), offset = Lexer.offset(tokens, first),
    length = math.max(0, Lexer.stop(tokens, to) - Lexer.offset(tokens, first)),
  })
end

--- What a binding declares, as the fork says it: an argument, a function, a type or a variable.
local function declares_of(v: Scopes.Var, t: Types.Type?): string
  local kind = v.kind
  if kind == "param" then
    return "argument"
  elseif kind == "function" then
    return "function"
  elseif kind == "record" or kind == "interface" or kind == "class" or kind == "enum" or kind == "alias" or
      kind == "import" then
    return "type"
  elseif t ~= nil and (t.tag == "fn") then
    return "function"
  elseif t ~= nil and (t.tag == "named") and t.value then
    return "type"
  end
  return "variable"
end

--- How many reads of `v` are outside the body of the function it names: all of them, for a variable.
local function outside_reads(v: Scopes.Var): integer
  local reads = #v.reads
  local own = v.fn
  if own == nil then
    return reads
  end
  for _, c in ipairs(v.captures) do
    if c.fn == own then
      reads = reads - #c.uses
    end
  end
  return reads
end

function Warnings.usage(filename: string, tokens: Lexer.Tokens, scoped: Scopes.Scoped, types: {integer: Types.Type},
                        display: function(t: Types.Type): string): {Warnings.Warning}
  local out: mut {Warnings.Warning} = {}
  for _, v in ipairs(scoped.list) do
    local name = v.name
    if name ~= "" and not v.exported and not v.nested and name:sub(1, 1) ~= "_" and name ~= "self" and
        v.kind ~= "typeparam" then
      local reads = outside_reads(v)
      local writes = #v.writes
      local t = types[v.id]
      if reads == 0 and writes > 0 then
        local declares = declares_of(v, t)
        local shown = if t ~= nil then " (of type " .. display(t) .. ")" else "" end
        Warnings.add(out, filename, tokens, "unread", v.declared, v.declared,
          declares .. " " .. name .. shown .. " is never read",
          "read " .. name .. " where its value is wanted, or remove it and the assignments to it")
      elseif reads == 0 and writes == 0 and #v.type_uses == 0 then
        local declares = declares_of(v, t)
        Warnings.add(out, filename, tokens, UNUSED[declares] or "unused_variable", v.declared, v.declared,
          "unused " .. declares .. " " .. name,
          if declares == "function" then "remove it, or return it from the module if other files call it" elseif
            declares == "type" then "remove it, or use it in the signature or annotation it was meant for" else
            "name it `_` or `_" .. name .. "` to say it is meant to be unused, or remove it" end)
      end
    end
  end
  table.sort(out, function(a: Warnings.Warning, b: Warnings.Warning): boolean
    return a.offset < b.offset
  end)
  return out
end

return Warnings
