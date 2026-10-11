--- The stub of a standard-library module: what a project's checker reads
--- in place of its source to type a `require` of it.
---
--- A stub is the module's source with every function body left out:
--- each token it keeps stays at the line and column it had, so a position
--- the checker reports in the module means the same in either, and what it
--- keeps of the source's requires, types, records and top-level statements
--- is as the source wrote it. Comments and the space between tokens are
--- dropped, since the checker reads neither; lexing them is a good part of
--- what a module costs it.
---
--- Leaving a body out cannot change the module's type: tl takes a
--- function's types from its signature, or from the context of a function
--- literal (patch/tl/37), never from its body. A body is still checked
--- against those types in two ways. A function declared `: never` must
--- not reach its end (patch/tl/43), so its stub body is `error()`. A
--- function literal written with no return list must return what its
--- context expects of it, and nothing in its signature says what that is,
--- so its body is kept. The checker still warns of the parameters and
--- locals only a body read, but a required module's own warnings never
--- reach the module that requires it.
---
--- A module that returns a record or another type it declares at its top
--- level keeps, besides, only the statements that type needs: what its
--- declaration and the signatures of its functions name, and so on, with
--- the requires they reach. The rest is code only bodies read, whose
--- requires would make a project's checker load modules no type it sees
--- names (see `unneeded`). Any other module keeps every statement.
---
--- [`stub.difference`] compares what the checker made of a module from
--- its source and from its stub, which cosmic's own build holds every
--- stub to ([`build.compilation`]), so a stub that would type a project
--- differently fails the build that would carry it.

local ast = require("build.ast")

local record stub
end

--- The node kinds that have a function body.
local function_kinds <const>: {string:boolean} = {
  ["function"] = true, local_function = true, global_function = true,
  record_function = true,
}

--- What stands for a `: never` function's body.
local never_body <const> = "error()"

--- A span of the source left out, from `y`:`x` up to, not including,
--- `to_y`:`to_x`, with what stands in its place at its start, if
--- anything.
local record Span
  y: integer
  x: integer
  to_y: integer
  to_x: integer
  instead: string | nil
end

local function before(ay: integer, ax: integer, by: integer, bx: integer): boolean
  return ay < by or (ay == by and ax < bx)
end

--- The bodies `root` holds, in source order. A body is its statements,
--- from its first token up to the function's `end` (whose position tl's
--- parser stamps on the function's node). An empty body has nothing to
--- leave out; a `: never` one too short on its own line to hold
--- [`never_body`] is kept whole, and so is a function literal's that has
--- no return list (see the module's doc). A body inside another is
--- listed too, and [`stub.of`] leaves it out with the one around it.
local function bodies(root: ast.Node): {Span}
  local found: {Span} = {}
  ast.walk(root, function(n: ast.Node)
    local body = n.body
    local typed_by_context = n.kind == "function" and n.rets_omitted == true
    if function_kinds[n.kind] and not typed_by_context and body ~= nil and #body > 0 and
        n.yend ~= nil and n.xend ~= nil then
      -- tl's `end_at` stamps the last column of `end`.
      local to_y, to_x = n.yend, n.xend - 2
      if not n.never or body.y < to_y or to_x - body.x > #never_body then
        found[#found + 1] = {
          y = body.y, x = body.x, to_y = to_y, to_x = to_x,
          instead = n.never and never_body or nil,
        }
      end
    end
  end)
  table.sort(found, function(a: Span, b: Span): boolean
    return before(a.y, a.x, b.y, b.x)
  end)
  return found
end

--- Statement kinds [`unneeded`] may leave out: a declaration, an
--- assignment, a call, a block or a loop. None changes the type of a
--- record declared as such, beside what the names it declares do: an
--- assignment adds no field to one (tl refuses a key its type lacks).
--- Two things would, and neither reaches a stub. An assignment to a name
--- declared as a value after the record (`local M = {}` then `M.x = 1`)
--- infers that value's type, but `unneeded` prunes only a module whose
--- returned name was last declared a type. A require of a module that
--- declares a global brings a type in by no name the stub spells, but
--- cosmic's own build refuses a standard-library module that declares one
--- ([`build.compilation`]). A statement of any other kind is kept wherever
--- it is.
local droppable <const>: {string:boolean} = {
  local_declaration = true, local_function = true, local_type = true, record_function = true,
  assignment = true, op = true, ["if"] = true, fornum = true, forin = true, ["while"] = true,
  ["repeat"] = true, ["do"] = true, ["goto"] = true, label = true,
}

--- The names the top-level statement `s` declares, and, for a
--- `function M.f`, the name it adds a field to (its owner's first part).
local function names_of(s: ast.Node): {string}, string | nil
  local declared: {string} = {}
  if s.kind == "local_declaration" then
    for _, var in ipairs(s.vars or {}) do
      declared[#declared + 1] = var.tk
    end
  elseif s.kind == "local_function" and s.name ~= nil then
    declared[1] = s.name.tk
  elseif s.kind == "local_type" and s.var ~= nil then
    declared[1] = s.var.tk
  elseif s.kind == "record_function" then
    local owner = s.fn_owner
    while owner ~= nil and owner.e1 ~= nil do
      owner = owner.e1
    end
    return declared, owner ~= nil and owner.tk or nil
  end
  return declared, nil
end

--- The top-level statements of `parsed` a declaration of the module needs
--- none of, as spans to leave out, where the module returns a name its own
--- `local record`, `interface`, `enum` or `local type` declares last; none for
--- any other module, whose stub keeps every statement. Such a module's
--- type is that declaration's, with what each `function M.f` on it adds,
--- so the stub keeps the `return`, then what a kept statement names, to a
--- fixed point: the declaration of each name one of its tokens spells
--- (outside a body, which `body_spans` leaves out), and each `function
--- M.f` whose `M` is kept. A name is taken for a reference wherever it is
--- spelt, as a field's name too, which keeps a statement at worst. What is
--- left out is code only bodies read and requires only they reach, so a
--- project's checker loads fewer modules too.
local function unneeded(parsed: ast.Parsed, body_spans: {Span}): {Span}
  local statements: {ast.Node} = parsed.node
  local tokens = parsed.tokens
  local last = statements[#statements]
  local exps = last ~= nil and last.kind == "return" and last.exps or nil
  local value = exps ~= nil and #exps == 1 and exps[1] or nil
  local returned = value ~= nil and value.kind == "variable" and value.tk or nil
  if returned == nil then
    return {}
  end
  local at: {string:integer} = {}
  for k, token in ipairs(tokens) do
    at[token.y .. ":" .. token.x] = k
  end
  -- Each statement's first token. tl's parser places a declaration of a
  -- value (`local x = ...`, `local type X = ...`) at its name.
  local starts: {integer} = {}
  local declares: {{string}} = {}
  local owners: {string | nil} = {}
  local typed = false
  for i, s in ipairs(statements) do
    local first = ast.span_start(s)
    local k = at[first.y .. ":" .. first.x]
    if k == nil or (i > 1 and k <= starts[i - 1]) then
      return {}
    end
    local before_k = k > 1 and tokens[k - 1].tk or ""
    if before_k == "local" or before_k == "global" then
      k = k - 1
    elseif before_k == "type" and k > 2 and
        (tokens[k - 2].tk == "local" or tokens[k - 2].tk == "global") then
      k = k - 2
    end
    starts[i] = k
    declares[i], owners[i] = names_of(s)
    -- The returned name's last top-level declaration decides what it is.
    for _, name in ipairs(declares[i]) do
      if name == returned then
        typed = s.kind == "local_type"
      end
    end
  end
  if not typed then
    return {}
  end
  -- The names each statement's tokens outside a body spell.
  local spelt: {{string:boolean}} = {}
  local statement, next_span = 0, 1
  for k, token in ipairs(tokens) do
    while starts[statement + 1] ~= nil and k >= starts[statement + 1] do
      statement = statement + 1
    end
    while body_spans[next_span] ~= nil and
        not before(token.y, token.x, body_spans[next_span].to_y, body_spans[next_span].to_x) do
      next_span = next_span + 1
    end
    local span = body_spans[next_span]
    local outside = span == nil or before(token.y, token.x, span.y, span.x)
    if statement > 0 and outside and token.kind == "identifier" then
      spelt[statement] = spelt[statement] or {}
      spelt[statement][token.tk] = true
    end
  end
  local kept: {integer:boolean} = { [#statements] = true }
  local wanted: {string:boolean} = {}
  local grew = true
  while grew do
    grew = false
    for i in pairs(kept) do
      for name in pairs(spelt[i] or {}) do
        wanted[name] = true
      end
    end
    for i, s in ipairs(statements) do
      if not kept[i] then
        local keep = not droppable[s.kind] or (owners[i] ~= nil and wanted[owners[i]])
        for _, name in ipairs(declares[i]) do
          keep = keep or wanted[name] == true
        end
        if keep then
          kept[i], grew = true, true
        end
      end
    end
  end
  local out: {Span} = {}
  for i = 1, #statements - 1 do
    if not kept[i] then
      local from, to = tokens[starts[i]], tokens[starts[i + 1]]
      out[#out + 1] = { y = from.y, x = from.x, to_y = to.y, to_x = to.x }
    end
  end
  return out
end

--- The stub of the module `parsed` holds (see the module's own doc).
--- @param parsed a parse of the module's source ([`ast.parse`]), whose
---   tokens are in source order
function stub.of(parsed: ast.Parsed): string
  local spans = bodies(parsed.node)
  for _, span in ipairs(unneeded(parsed, spans)) do
    spans[#spans + 1] = span
  end
  -- A statement left out starts before the bodies inside it, so each
  -- span comes before those it holds.
  table.sort(spans, function(a: Span, b: Span): boolean
    return before(a.y, a.x, b.y, b.x)
  end)
  local out: {string} = {}
  local y, x = 1, 1
  local function put(at_y: integer, at_x: integer, text: string)
    if at_y > y then
      out[#out + 1] = ("\n"):rep(at_y - y)
      y, x = at_y, 1
    end
    if at_x > x then
      out[#out + 1] = (" "):rep(at_x - x)
    end
    out[#out + 1] = text
    -- A long string may span lines.
    local last = 0
    for at in text:gmatch("()\n") do
      y = y + 1
      last = math.tointeger(at) or 0
    end
    x = last > 0 and #text - last + 1 or at_x + #text
  end
  local next_span = 1
  for _, token in ipairs(parsed.tokens) do
    if token.kind == "$EOF$" then
      break
    end
    while spans[next_span] ~= nil and
        not before(token.y, token.x, spans[next_span].to_y, spans[next_span].to_x) do
      next_span = next_span + 1
    end
    local span = spans[next_span]
    if span == nil or before(token.y, token.x, span.y, span.x) then
      put(token.y, token.x, token.tk)
    elseif span.instead ~= nil then
      put(span.y, span.x, span.instead)
      span.instead = nil
    end
  end
  return table.concat(out) .. "\n"
end

--- The first top-level statement of `parsed` that declares a global, or
--- nil: a standard-library module may declare none (see `droppable`).
function stub.global_declaration(parsed: ast.Parsed): ast.Node | nil
  for _, s in ipairs(parsed.node) do
    if s.kind:sub(1, 7) == "global_" then
      return s
    end
  end
  return nil
end

--- Fields of a checked type that say where it was read, which a stub
--- moves no further than its source does but which name a fresh place
--- each check: positions, the file, the type's number; or what only its
--- comments said (a stub has none); or what the checker resolved of a
--- name as it met a use of it (`resolved`, a cache of `found`), which a
--- body it no longer reads may have been first to do.
local incidental <const>: {string:boolean} = {
  y = true, x = true, yend = true, xend = true, f = true, filename = true,
  typeid = true, inferred_at = true, resolved = true, comments = true,
  field_comments = true, meta_field_comments = true, value_comments = true,
}

--- Fields of a checked type keyed by the names its source declares: a
--- record's fields and metamethods, an enum's values. Each of their keys
--- is compared, though one may be spelt as an [`incidental`] field is.
local named <const>: {string:boolean} = { fields = true, meta_fields = true, enumset = true }

--- Fields naming a type variable, which the checker numbers afresh each
--- check (`T@12`): two are the same where their names are, less the
--- number, and the numbers correspond one to one throughout.
local type_variables <const>: {string:boolean} = { typevar = true, typearg = true }

--- Where the checker's `from_source` and `from_stub` types of a module
--- differ, as the path of fields to the first difference found, or nil
--- when they are the same type. The two are walked together: a table
--- reached on both sides at once (a type another module declares, which
--- both checks share) is the same; a table met again must meet its
--- counterpart again, and only it, so a cycle compares as a cycle; every other field
--- but the [`incidental`] ones must match, and every one of a [`named`]
--- field.
function stub.difference(from_source: any, from_stub: any): string | nil
  local paired: {any:any} = {}
  local paired_back: {any:any} = {}
  local renamed: {string:string} = {}
  local renamed_back: {string:string} = {}
  local function differ(a: any, b: any, path: string, key: string, names: boolean): string | nil
    if rawequal(a, b) then
      return nil
    end
    if type_variables[key] and a is string and b is string then
      local a_name, b_name = a:match("^(.-)@%d+$"), b:match("^(.-)@%d+$")
      local fresh = renamed[a] == nil and renamed_back[b] == nil
      if a_name ~= nil and a_name == b_name and (fresh or (renamed[a] == b and renamed_back[b] == a)) then
        renamed[a], renamed_back[b] = b, a
        return nil
      end
    end
    if not (a is {any:any}) or not (b is {any:any}) then
      return path .. ": " .. tostring(a) .. " in the source, " .. tostring(b) .. " in the stub"
    end
    if paired[a] ~= nil or paired_back[b] ~= nil then
      local same = rawequal(paired[a], b) and rawequal(paired_back[b], a)
      return not same and path .. ": a different type in the stub" or nil
    end
    paired[a], paired_back[b] = b, a
    for field, value in pairs(a) do
      if names or not incidental[tostring(field)] then
        local found = differ(value, b[field], path .. "." .. tostring(field), tostring(field),
          not names and named[tostring(field)] == true)
        if found ~= nil then
          return found
        end
      end
    end
    for field, _ in pairs(b) do
      if (names or not incidental[tostring(field)]) and a[field] == nil then
        return path .. "." .. tostring(field) .. ": only in the stub"
      end
    end
    return nil
  end
  return differ(from_source, from_stub, "", "", false)
end

return stub
