--- Resolves `Shape.record_of("Module.Record")` where a module is compiled: the call names a record, and this reads the
--- record's declaration off the checker's types and splices into the call a Teal function that builds the record field by
--- field from the [`cosmic.shape`] checks of its fields' types, and a node that describes the fields. The checker types
--- that code as any other, so the call's answer is typed as the record by what builds it.
---
--- The build is where this runs, not the program: a record's declaration is source, and reading it is the compiler's
--- work, which a program built into an executable does not carry. A call is rewritten in the compile's input alone; the
--- source a module is stored and shown under is what its author wrote.
---
--- The name is one of
---
--- - `Record` or `Record.Inner`, a record declared above the call in a block the call is in, however the module ends
---   (a test or an example declares its own and returns no type), or
--- - `module.name.Record`, a record the module `module.name` declares inside the record it returns, which the calling
---   module must `require` at its top level (`local Fs = require("cosmic.fs")`), so the compile is keyed by it
---   ([`build.plans`]'s `dependency_keys`).
---
--- What a record may hold is what [`cosmic.shape`] can check: strings, integers, numbers, booleans and `any`; arrays and
--- string-keyed maps of those; enums, as `one_of` in byte order; records of those; and `T?` for a field that may be
--- missing. Anything else (a function, a union of more than one type, a generic, an interface, a class, a record that
--- holds itself) is refused where the call is, naming the field.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Driver = require("build.driver")
local Match = require("build.syntax_match")
local Node = require("build.syntax_node")
local RecordCalls = require("build.syntax_record_calls")
local Types = require("lang.types")

local record ShapeSpecs
  --- One call's resolution.
  type Splice = RecordCalls.Splice

  --- What [`ShapeSpecs.splices`] found of a source.
  record Found
    --- Each call's splice, the last in the source first; none where a call was refused.
    splices: {Splice}
    --- What was refused, as the compiler words a refusal (`file:line: ...`); "" where nothing was.
    refusal: string
    --- The line of the call refused; 0 where none was.
    line: integer
  end

  --- What a compile splices into `source`, the text `module` of `build` was read from: for each
  --- `Shape.record_of("name")` it holds, the call's spec and the node that describes the record, put after the name
  --- on its own line, so the lines a message names do not move, but columns after the call on that line do. Each is a
  --- [`ShapeSpecs.Splice`], the last in the source first. None for a source that has no such call, which is every
  --- module but the few that use it, or that the compiler would refuse anyway.
  ---
  --- Where a call cannot be resolved (a name that is not a string literal, a record the module does not reach, a
  --- field with no shape), none, and the refusal, as the compiler words one (`file:line: ...`), with the call's line
  --- ([`ShapeSpecs.Found`]).
  splices: function(build: Driver.Build, module: string, file: string, source: string): Found

  --- `source` with each of `splices` put in, the last first as [`ShapeSpecs.splices`] answers them.
  spliced: function(source: string, splices: {Splice}): string
end

local type Type = Types.Type

--- Names in byte order.
local function sorted(names: {string}): {string}
  local out: mut {string} = {}
  for _, name in ipairs(names) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

local LEAVES <const>: {string: boolean} = {
  string = true, integer = true, number = true, boolean = true, any = true,
}

--- What the generator reads and keeps while it writes one record's code.
local record Gen
  --- The name the calling module gives cosmic.shape.
  shape: string
  store: Types.Store
  --- Where the call stands, for how the module spells a type.
  names: RecordCalls.Namer
  --- The records being read, which none may hold.
  holding: mut {Types.Decl: boolean}
  --- A number for each local the code names, so that no name is declared twice in it.
  mut count: integer
  --- The local that holds whether the record being written refuses a key it does not name.
  mut strict: string
end

--- The next number for a local.
local function fresh(g: Gen): integer
  g.count = g.count + 1
  return g.count
end

--- What the generator writes for a type: the Teal expression that is its spec, and the one that is its node.
local record Written
  spec: string
  node: string
end

local gen_spec: function(g: Gen, t: Type, path: string): Written?, string

--- A node's text with `optional` set: the first `optional = false` in it is its own.
local function optional_node(node: string): string
  return (node:gsub("optional = false", "optional = true", 1))
end

--- The most fields a record may have: its check names two locals for each field, and a Lua function holds 200.
local MOST_FIELDS <const> = 90

--- The check of the record `decl` at `path`, as a function of whether a key it does not name is refused, over the checks
--- of its fields, and the node that describes its fields. Where the record has a field of a type the generator cannot
--- spell, nil and why.
local function gen_record(g: Gen, t_of_decl: Type, decl: Types.Decl, path: string): Written?, string -- checked: not_assigned
  local body = decl.body
  if body == nil then return nil, path .. ": a declaration the checker did not resolve" end
  if body.array ~= nil then return nil, path .. ": a record that is also an array has no shape" end
  -- TODO: read the fields a record inherits (`supers`, expanded by the checker) and drop this refusal, once a caller
  -- gives a record that implements an interface a shape; the tree has none.
  if #body.supers > 0 then
    return nil, path .. ": a record that implements an interface has no shape; its inherited fields are not read"
  end
  if g.holding[decl] == true then
    return nil, path .. ": a record that holds itself has no finite shape"
  end
  if #body.fields > MOST_FIELDS then
    return nil, ("%s: a record with more fields than the %d allowed has no check: the function that checks it would name more " ..
      "locals than Lua allows; split the record"):format(path, MOST_FIELDS)
  end
  local spelled = RecordCalls.spelling(g.names, t_of_decl, decl)
  if spelled == nil then
    return nil, path .. ": the module cannot name this record, which is declared where it does not reach: declare it " ..
      "in the calling module or in a module it requires at its top level"
  end
  g.holding[decl] = true
  local fields: mut {Types.Field} = {}
  for _, field in ipairs(body.fields) do fields[#fields + 1] = field end
  table.sort(fields, function(x: Types.Field, y: Types.Field): boolean return x.name < y.name end)
  local S = g.shape
  local own = "sh_s" .. tostring(fresh(g))
  local outer = g.strict
  g.strict = own
  local checks: mut {string} = {}
  local reads: mut {string} = {}
  local names: mut {string} = {}
  local built: mut {string} = {}
  local nodes: mut {string} = {}
  for _, field in ipairs(fields) do
    local k = fresh(g)
    local written, why = gen_spec(g, field.type, path .. "." .. field.name)
    if written == nil then
      g.holding[decl] = nil
      g.strict = outer
      return nil, why
    end
    -- A field written `f?: T` is omittable whatever `T` is, and a field of `any` may be nil, as `any` holds nil: the store
    -- folds `any?` into `any`, so the union that would say so is gone from the field's type.
    local nilable = field.omittable == true or field.type == g.store.any
    local inner, node = written.spec, written.node
    if nilable and field.type.tag ~= "union" then
      inner = S .. ".optional(" .. inner .. ")"
      node = optional_node(node)
    end
    local step = ("%s.build.step(sh_path, %q)"):format(S, field.name)
    checks[#checks + 1] = ("local sh_c%d = %s "):format(k, inner)
    reads[#reads + 1] = ("local sh_v%d, sh_e%d = sh_c%d.check(%s.build.get(sh_t, %q), %s) %s"):format(
      k, k, k, S, field.name, step,
      if nilable or field.type.tag == "union" then ("if sh_e%d ~= \"\" then return nil, sh_e%d end"):format(k, k) else
        ("if sh_v%d == nil then return nil, %s.build.failed(sh_e%d, %s) end"):format(k, S, k, step) end)
    names[#names + 1] = ("%q"):format(field.name)
    built[#built + 1] = ("[%q] = sh_v%d"):format(field.name, k)
    nodes[#nodes + 1] = ("[%q] = %s"):format(field.name, node)
  end
  g.holding[decl] = nil
  g.strict = outer
  local check = ("(function(%s: boolean): %s.Spec<%s> %sreturn { check = function(sh_value: any, sh_path: string): %s?, string " ..
    "local sh_t, sh_why = %s.build.object(sh_value, sh_path, { %s }, %s) if sh_t == nil then return nil, sh_why end %s " ..
    "return { %s }, \"\" end } end)"):format(own, S, spelled, table.concat(checks), spelled, S,
      table.concat(names, ", "), own, table.concat(reads, " "), table.concat(built, ", "))
  return { spec = check, node = ('{ kind = "record", optional = false, fields = { %s } }'):format(table.concat(nodes, ", ")) }, ""
end

--- The Teal expression, over the `shape` alias, that is the spec of `t`, and the node that describes it, or nil and why
--- `t` has none. `path` names where `t` is, for the message. The local that holds whether a record refuses a key it does
--- not name is `strict`.
gen_spec = function(g: Gen, t: Type, path: string): Written?, string
  local S = g.shape
  if t.atom == true then
    if LEAVES[t.tag] == true then
      return { spec = S .. "." .. tostring(t.tag), node = ('{ kind = "%s", optional = false }'):format(tostring(t.tag)) }, ""
    end
    if t.tag == "invalid" then return nil, path .. ": a type the checker did not resolve" end
    return nil, ("%s: a %s type has no shape"):format(path, t.tag)
  elseif t.tag == "array" then
    local inner, why = gen_spec(g, t.element, path .. "[]")
    if inner == nil then return nil, why end
    return { spec = S .. ".list(" .. inner.spec .. ")",
      node = ('{ kind = "list", optional = false, of = %s }'):format(inner.node) }, ""
  elseif t.tag == "map" then
    local key = t.key
    if not ((key.atom == true) and key.tag == "string") then
      return nil, path .. ": a map keyed by anything but a string has no shape"
    end
    local inner, why = gen_spec(g, t.value, path .. "{}")
    if inner == nil then return nil, why end
    return { spec = S .. ".map(" .. inner.spec .. ")",
      node = ('{ kind = "map", optional = false, of = %s }'):format(inner.node) }, ""
  elseif t.tag == "union" then
    if #t.members > 1 then
      return nil, path .. ": a union of more than one type has no shape; `T?` is the one it has, and an enum a choice"
    end
    local inner, why = gen_spec(g, assert(t.members[1]), path)
    if inner == nil then return nil, why end
    return { spec = S .. ".optional(" .. inner.spec .. ")", node = optional_node(inner.node) }, ""
  elseif t.tag == "named" then
    local decl = t.decl
    local body = decl.body
    if #t.args > 0 or (body ~= nil and #body.tparams > 0) then
      return nil, path .. ": a generic type has no shape"
    end
    if decl.kind == "enum" then
      local values: {string} = if body ~= nil then sorted(body.values) else {} end
      if #values == 0 then return nil, path .. ": an enum with no values has no shape" end
      local spelled = RecordCalls.spelling(g.names, t, decl)
      if spelled == nil then
        return nil, path .. ": the module cannot name this enum, which is declared where it does not reach: declare " ..
          "it in the calling module or in a module it requires at its top level"
      end
      local arms: mut {string} = {}
      local listed: mut {string} = {}
      for _, value in ipairs(values) do
        arms[#arms + 1] = ('if sh_v == %q then return %q, "" end'):format(value, value)
        listed[#listed + 1] = ("%q"):format(value)
      end
      return { spec = ("(function(): %s.Spec<%s> return { check = function(sh_v: any, sh_p: string): %s?, string %s " ..
        "return nil, %s.build.not_one_of(sh_p, sh_v, %s) end } end)()"):format(S, spelled, spelled, table.concat(arms, " "),
          S, table.concat(listed, ", ")),
        node = ('{ kind = "one_of", optional = false, values = { %s } }'):format(table.concat(listed, ", ")) }, ""
    elseif decl.kind == "record" then
      local written, why = gen_record(g, t, decl, path)
      if written == nil then return nil, why end
      return { spec = written.spec .. "(" .. g.strict .. ")", node = written.node }, ""
    elseif decl.kind == "userdata" then
      return nil, path .. ": a userdata record has no shape"
    elseif decl.kind == "alias" then
      return nil, path .. ": a recursive alias has no shape"
    end
    return nil, ("%s: %s has no shape"):format(path, if decl.kind == "interface" then "an interface" else "a class" end)
  elseif t.tag == "fn" then
    return nil, path .. ": a function has no shape"
  end
  return nil, path .. ": a generic type has no shape"
end

local type Splice = ShapeSpecs.Splice

--- The comment that leaves a use of `record_of` unresolved on purpose, on the line of the use, wherever it is.
local UNRESOLVED_ON_PURPOSE <const> = "-- record_of: unresolved on purpose"

--- Whether `e` is `require("cosmic.shape")`.
local function requires_shape(e: Ast.Exp): boolean
  return RecordCalls.required_name(e) == "cosmic.shape"
end

--- Whether the line `text` ends in the comment [`UNRESOLVED_ON_PURPOSE`], exactly: the comment is the text from the first `--`
--- outside a string, so the marker inside a string, in a `---` doc comment, or followed by more text is not one.
local function marked(text: string): boolean
  local quote: string? = nil
  local i = 1
  while i <= #text do
    local c = text:sub(i, i)
    if quote ~= nil then
      if c == "\\" then
        i = i + 1
      elseif c == quote then
        quote = nil
      end
    elseif c == '"' or c == "'" then
      quote = c
    elseif c == "-" and text:sub(i, i + 1) == "--" then
      return (text:sub(i):gsub("%s+$", "")) == UNRESOLVED_ON_PURPOSE
    end
    i = i + 1
  end
  return false
end

--- The first use of cosmic.shape's `record_of` that the build does not complete, as a refusal and its line, or "" and 0.
--- Followed, per file and not per scope: a name that is `Shape` (or an alias already found), or `require("cosmic.shape")`,
--- bound by `local A = ...`, `local A, B = ..., ...` or `A = ...` to a bare name or a literal `require`. A use is
--- [`Shape.record_of`] not called (`local f = Shape.record_of`), the method form, `record_of` read through such a name
--- (`Alias.record_of`, `require("cosmic.shape").record_of`), or through an index (`Shape["record_of"]`).
--- A call that way raises when it runs; the build refuses it where it stands, unless the first line of the use ends in the
--- comment [`UNRESOLVED_ON_PURPOSE`].
---
--- Not followed, and failing at run time as any uncompleted call does (no check, so it raises): a wrapped alias
--- (`(Shape)`, `Shape or x`, `assert(Shape)`), a field target (`M.s = Shape`), the module passed as an argument,
--- `pcall(require, ...)` and `local R = require`, a function's result, `select`, a table and a computed key.
local function stray_use(chunk: Ast.Chunk, file: string, source: string, shape: string?): string, integer
  local names: mut {string: boolean} = {}
  if shape ~= nil then names[shape] = true end
  local called: mut {integer: boolean} = {}
  Node.walk(chunk, function(node: Ast.Node)
    if node.kind == "Call" then
      called[node.callee.last] = true
    elseif node.kind == "Local" then
      for i, binding in ipairs(node.bindings) do
        local value = node.values[i]
        if value ~= nil and ((value.kind == "Name" and names[value.text] == true) or requires_shape(value)) then
          names[binding.name] = true
        end
      end
    elseif node.kind == "Assign" then
      for i, target in ipairs(node.targets) do
        local value = node.values[i]
        if target.kind == "Name" and value ~= nil and
            ((value.kind == "Name" and names[value.text] == true) or requires_shape(value)) then
          names[target.text] = true
        end
      end
    end
  end)
  local lines: mut {string} = {}
  for text in (source .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = text end
  local refusal, line = "", 0
  Node.walk(chunk, function(node: Ast.Node)
    if refusal ~= "" then return end
    local object: Ast.Exp? = nil
    if node.kind == "Field" and node.name == "record_of" then
      object = node.object
    elseif node.kind == "MethodCall" and node.name == "record_of" then
      object = node.object
    elseif node.kind == "Index" and node.key.kind == "String" and node.key.value == "record_of" then
      object = node.object
    end
    if object == nil then return end
    local direct = object.kind == "Name" and object.text == shape
    local other = (object.kind == "Name" and object.text ~= shape and names[object.text] == true) or
      requires_shape(object)
    if not (direct or other) then return end
    -- A call of `Shape.record_of(...)` is the build's to complete or leave; any other way of reading it is not.
    if direct and node.kind == "Field" and called[node.last] == true then return end
    local at = Node.span(chunk, node).y
    if marked(lines[at] or "") then return end
    line = at
    refusal = ("%s:%d: record_of: read other than as a call written Shape.record_of(\"Name\"), which the build " ..
      "completes; written so, it has no check and raises when it runs. Bind cosmic.shape at the module's top level and call " ..
      "Shape.record_of(\"Name\") there; a use that means to fail at run time ends its first line in `%s`"
    ):format(file, at, UNRESOLVED_ON_PURPOSE)
  end)
  return refusal, line
end

function ShapeSpecs.splices(build: Driver.Build, module: string, file: string, source: string): ShapeSpecs.Found
  local none: {Splice} = {}
  if not source:find("record_of", 1, true) then
    return { splices = none, refusal = "", line = 0 }
  end
  -- A module that names `record_of` without requiring cosmic.shape at its top level (in a comment, a string, or
  -- another table's field) has nothing to splice: that is seen in its syntax, before lowering it and all it requires.
  -- The use of `record_of` that the build does not complete is a matter of syntax too, so it is refused here, before the
  -- early return: a module that reads it through `require("cosmic.shape")` inline requires nothing at its top level.
  -- The examples of a guide are functions (build/doctest/generate.tl), and a `Shape` they require is not one the splicer
  -- finds, so their `record_of` calls get no check from the build and raise if an example runs: a guide is not refused.
  local read = build:parsed(module)
  if read ~= nil and not read.broken then
    local top = RecordCalls.required(read.chunk)["cosmic.shape"]
    if file:sub(-3) ~= ".md" then
      local stray, stray_line = stray_use(read.chunk, file, source, top)
      if stray ~= "" then return { splices = none, refusal = stray, line = stray_line } end
    end
    if top == nil then
      return { splices = none, refusal = "", line = 0 }
    end
  end
  build:lower({ module })
  local outcome = build:result(module, false)
  if outcome == nil or outcome.broken then
    return { splices = none, refusal = "", line = 0 }
  end
  local chunk = outcome.chunk
  local aliases = RecordCalls.required(chunk)
  local shape = aliases["cosmic.shape"]
  if shape == nil then
    return { splices = none, refusal = "", line = 0 }
  end
  local pattern, pattern_trouble = Match.compile("$S.record_of($N, $$$MORE)")
  if pattern == nil then
    return { splices = none, refusal = pattern_trouble, line = 0 }
  end
  local calls: mut {Match.Hit} = {}
  for _, hit in ipairs(Match.find_all(pattern, chunk, chunk)) do
    local on = hit.caps["_S"]
    local head = if on ~= nil then on.nodes[1] else nil end
    if head ~= nil and (head.kind == "Name") and head.text == shape then
      calls[#calls + 1] = hit
    end
  end
  local splices: mut {Splice} = {}
  for _, hit in ipairs(calls) do
    local span = Node.span(chunk, hit.node)
    local where = ("%s:%d: %s.record_of"):format(file, span.y, shape)
    local more = hit.caps["___MORE"]
    -- A call that already has its check and node is left as it is: they are functions and data the checker types.
    if more ~= nil and #more.nodes > 0 then continue end
    local named = assert(hit.caps["_N"], "the pattern captures _N")
    local literal = named.nodes[1]
    if literal == nil or not ((literal.kind == "String")) then
      return { splices = none, line = span.y,
        refusal = where .. ": the name must be a string literal, which the build reads" }
    end
    local name_token = named.first
    local written = Lexer.text(chunk.tokens, name_token)
    local quote = written:sub(1, 1)
    if literal.long or (quote ~= '"' and quote ~= "'") or written:find("\\", 1, true) ~= nil then
      return { splices = none, line = span.y,
        refusal = where .. ": the name must be a plain quoted string with no escape in it" }
    end
    local target, unresolved = RecordCalls.resolve_name(build, outcome, literal.value, Node.base(hit.node).first, aliases)
    if target == nil then
      return { splices = none, line = span.y,
        refusal = ("%s(%q): %s"):format(where, literal.value, unresolved) }
    end
    local at = target.type
    if not ((at.tag == "named")) or at.decl.kind ~= "record" then
      local what = "a type, not a record"
      if (at.tag == "named") then
        what = if at.decl.kind == "enum" then "an enum, which " .. shape .. ".one_of checks" else
          "a " .. at.decl.kind .. ", not a record" end
      end
      return { splices = none, line = span.y,
        refusal = ("%s(%q): it is %s"):format(where, literal.value, what) }
    end
    local g: Gen = {
      shape = shape, store = build.program.store, holding = {}, count = 0, strict = "",
      names = {
        program = build.program, module = module, aliases = aliases, target = at.decl, spelled = target.spelled,
        visible = RecordCalls.visible(outcome, Node.base(hit.node).first),
      },
    }
    local made, refusal = gen_record(g, at, at.decl, literal.value)
    if made == nil then
      return { splices = none, line = span.y,
        refusal = ("%s(%q): %s"):format(where, literal.value, refusal) }
    end
    splices[#splices + 1] = {
      at = Lexer.stop(chunk.tokens, name_token) - 1,
      text = ", " .. made.spec .. ", " .. made.node,
    }
  end
  table.sort(splices, function(a: Splice, b: Splice): boolean
    return a.at > b.at
  end)
  return { splices = splices, refusal = "", line = 0 }
end

function ShapeSpecs.spliced(source: string, splices: {Splice}): string
  return RecordCalls.spliced(source, splices)
end

return ShapeSpecs
