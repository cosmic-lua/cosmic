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
--- Leaving a body out leaves each function's type as it is: tl takes it
--- from the function's signature, or from the context of a function
--- literal, never from its body. It can change other types: a body can
--- add a function to an outer record, type an outer empty table by its
--- use, or resolve a type an outer record's field still waits on, so a
--- stub may type a module otherwise than its source. A body is still checked
--- against those types in two ways. A function declared `: never` must
--- not reach its end, so its stub body is `error()`. A
--- function literal written with no return list must return what its
--- context expects of it, and nothing in its signature says what that is,
--- so its body is kept. The checker still warns of the parameters and
--- locals only a body read, but a required module's own warnings never
--- reach the module that requires it.
---
--- A module that returns a name whose last top-level declaration spells its
--- type -- a record or another type it declares, a local function, a local
--- of a written type -- keeps, besides, only the statements that type needs: what its
--- declaration and the signatures of its functions name, and so on, with
--- the requires they reach. The rest is code only bodies read, whose
--- requires would make a project's checker load modules no type it sees
--- names (see `unneeded`). Any other module keeps every statement, which
--- cosmic's own build refuses of a standard-library module
--- ([`stub.Made`]'s `pruned`).
---
--- [`stub.difference`] compares what the checker made of a module from
--- its source and from its stub, which cosmic's own build holds every
--- stub to ([`build.compilation`]), so a stub that would type a project
--- differently fails the build that would carry it. `cosmic lsp` compares
--- none of its stubs so: neither those it serves of a project's modules
--- ([`build.lsp.source`]) nor the one it reads a document's
--- [`Shape.record_of`] calls from ([`build.lsp.splice`]).

-- TODO: keep each body that can declare past itself, or derive stubs with
-- the new checker. tl lets a body change what the module declares, so a
-- stub that leaves it out types the module otherwise (checker/tl.tl):
-- a function on a name (`function a.b`, `function a:b`), which
-- `record_function` adds to the record the name's type is, wherever that
-- is declared; a declaration whose type is an empty table (`local t =
-- {}`, `({})`, `setmetatable({}, {})`, a call or an index that answers
-- one), which tl marks (`assigned_to`) and `infer_emptytable` types by its
-- first use, in every scope on the stack; and a `local type G` (or `local
-- G = <type>`) in a body, which `dismiss_unresolved` takes for the `G` an
-- outer record's field still waits on. (A global declared in a body
-- escapes too, but cosmic refuses every global, [`build.globals`].) The
-- first fix waits on nothing but is not done: the set is not known to be
-- closed, and the last two kinds reach names no syntax bounds, so it
-- would keep most bodies and cost most of what a stub saves. The second
-- waits on the build deriving stubs with the new checker
-- ([`build.syntax_stub`]), which has none of these paths, at the switch
-- (doc/plans/strict-teal.md).

local ast = require("build.ast")

local record stub
  --- A stub ([`stub.made`]).
  record Made
    text: string
    --- Whether it is declaration-only: whether the module returns a name
    --- whose last top-level declaration spells its type, so the stub leaves
    --- out every statement that type needs none of. Cosmic's own build
    --- refuses a standard-library module whose stub is not
    --- ([`build.compilation`]): a project's checker would read every
    --- statement it holds, and load every module it requires.
    pruned: boolean
  end
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

--- More columns than a line of a source has, so `y * line_width + x` names
--- a position by one integer.
local line_width <const> = 1 << 24

--- What one walk of each top-level statement finds: the bodies it holds,
--- in source order, and where each statement's leftmost node sits.
---
--- A body is its statements, from its first token up to the function's
--- `end` (whose position tl's parser stamps on the function's node). An
--- empty body has nothing to leave out; a `: never` one too short on its
--- own line to hold [`never_body`] is kept whole, and so is a function
--- literal's that has no return list (see the module's doc). What a
--- body left out holds is not walked.
local record Scan
  bodies: {Span}
  --- Each statement's leftmost node, `{y, x}`, which is its first token
  --- but for a declaration of a value, which tl's parser places at its
  --- name (`local x = ...`, `local type X = ...`).
  firsts: {{integer}}
end

--- The fields [`scan`] does not follow: the "if" an "if_block" belongs to,
--- which points back up the tree, and, of a function whose body is left
--- out, the body, which is most of a module and holds nothing a stub keeps.
local not_followed <const>: {string:boolean} = { if_parent = true }
local not_into_body <const>: {string:boolean} = { if_parent = true, body = true }

local function scan(statements: {ast.Node}): Scan
  local found: {Span} = {}
  local firsts: {{integer}} = {}
  for i, statement in ipairs(statements) do
    local first = { y = statement.y, x = statement.x }
    local function visit(n: ast.Node)
      if before(n.y, n.x, first.y, first.x) then
        first.y, first.x = n.y, n.x
      end
      local body = n.body
      local typed_by_context = n.kind == "function" and n.rets_omitted == true
      local left_out = false
      local yend = n.yend
      local xend = n.xend
      if function_kinds[n.kind] and not typed_by_context and body ~= nil and #body > 0 and
          yend ~= nil and xend ~= nil then
        -- tl's `end_at` stamps the last column of `end`.
        local to_y, to_x = yend, xend - 2
        if not n.never or body.y < to_y or to_x - body.x > #never_body then
          found[#found + 1] = {
            y = body.y, x = body.x, to_y = to_y, to_x = to_x,
            instead = n.never and never_body or nil,
          }
          left_out = true
        end
      end
      local skipped: {string:boolean} = not_followed
      if left_out then
        skipped = not_into_body
      end
      ast.each_child_node(n, skipped, visit)
    end
    visit(statement)
    firsts[i] = { first.y, first.x }
  end
  table.sort(found, function(a: Span, b: Span): boolean
    return before(a.y, a.x, b.y, b.x)
  end)
  return { bodies = found, firsts = firsts }
end

--- Statement kinds [`unneeded`] may leave out: a declaration, an
--- assignment, a call, a block or a loop. None changes the type of a
--- record declared as such, beside what the names it declares do: an
--- assignment adds no field to one (tl refuses a key its type lacks).
--- Three things would. An assignment to a name declared as a value with
--- no type written (`local M = {}` then `M.x = 1`) infers that value's
--- type, but `unneeded` prunes only a module whose returned name's last
--- declaration spells its type. An `if`, an `assert` or an assignment may
--- narrow the union a local is written to be (`local m: A | B`), which
--- [`stub.difference`] tells, so cosmic's own build refuses that stub. A
--- require of a module that declares a global would bring a type in by no
--- name the stub spells, but a build refuses a module that declares one
--- ([`build.compilation`]). A statement of any
--- other kind is kept wherever it is.
local droppable <const>: {string:boolean} = {
  local_declaration = true, local_function = true, local_type = true, record_function = true,
  assignment = true, op = true, ["if"] = true, fornum = true, forin = true, ["while"] = true,
  ["repeat"] = true, ["do"] = true, ["goto"] = true, label = true,
}

--- The names the top-level statement `s` declares, and, for a
--- `function M.f`, the name it adds a field to (its owner's first part).
local function names_of(s: ast.Node): {string}, string | nil
  local declared: {string} = {}
  local fn_name, type_var = s.name, s.var
  if s.kind == "local_declaration" then
    for _, var in ipairs(s.vars or {}) do
      declared[#declared + 1] = var.tk
    end
  elseif s.kind == "local_function" and fn_name ~= nil then
    declared[1] = fn_name.tk
  elseif s.kind == "local_type" and type_var ~= nil then
    declared[1] = type_var.tk
  elseif s.kind == "record_function" then
    local owner = s.fn_owner
    while owner ~= nil and owner.e1 ~= nil do
      owner = owner.e1
    end
    return declared, owner ~= nil and owner.tk or nil
  end
  return declared, nil
end

--- The names the top-level statement `s`, an assignment, writes as plain
--- names (`feed = function() ... end`); none for any other statement.
local function written_names(s: ast.Node): {string}
  local written: {string} = {}
  if s.kind == "assignment" then
    for _, var in ipairs(s.vars or {}) do
      if var.kind == "variable" then
        written[#written + 1] = var.tk
      end
    end
  end
  return written
end

--- Whether the top-level statement `s` gives the one name it declares a
--- type no later statement can change: a type declaration (`local record
--- M`), a local function, whose type is its signature, or a local whose
--- type is written (`local m: M = {...}`). tl never infers any of these
--- from what follows, though a later statement may narrow a local's union
--- (see `droppable`).
local function spells_its_type(s: ast.Node): boolean
  if s.kind == "local_type" or s.kind == "local_function" then
    return true
  end
  local decltuple = s.decltuple
  local written = decltuple ~= nil and decltuple.tuple or nil
  local vars = s.vars
  return s.kind == "local_declaration" and vars ~= nil and #vars == 1 and
    written ~= nil and #written == 1
end

--- The top-level statements of `parsed` a declaration of the module needs
--- none of, as spans to leave out, where the module returns a name whose
--- last top-level declaration spells its type ([`spells_its_type`]); nil
--- for any other module, whose stub keeps every statement. Such a module's
--- type is that declaration's, with what each `function M.f` on it adds,
--- so the stub keeps the `return`, then what a kept statement names, to a
--- fixed point: the declaration of each name one of its tokens spells
--- (outside a body `scanned` found), and each `function
--- M.f` whose `M` is kept. A name is taken for a reference wherever it is
--- spelt, as a field's name too, which keeps a statement at worst. What is
--- left out is code only bodies read and requires only they reach, so a
--- project's checker loads fewer modules too.
local function unneeded(parsed: ast.Parsed, scanned: Scan): {Span} | nil
  local statements: {ast.Node} = parsed.node
  local tokens = parsed.tokens
  local body_spans = scanned.bodies
  local last = statements[#statements]
  local exps = last ~= nil and last.kind == "return" and last.exps or nil
  local value = exps ~= nil and #exps == 1 and exps[1] or nil
  local returned = value ~= nil and value.kind == "variable" and value.tk or nil
  if returned == nil then
    return nil
  end
  local declares: {{string}} = {}
  local writes: {{string}} = {}
  local owners: {string | nil} = {}
  local typed = false
  for i, s in ipairs(statements) do
    declares[i], owners[i] = names_of(s)
    writes[i] = written_names(s)
    -- The returned name's last top-level declaration decides what it is.
    for _, name in ipairs(declares[i]) do
      if name == returned then
        typed = spells_its_type(s)
      end
    end
  end
  if not typed then
    return nil
  end
  -- Each statement's first token, by its leftmost node's position.
  local at: {integer:integer} = {}
  for k, token in ipairs(tokens) do
    at[token.y * line_width + token.x] = k
  end
  local starts: {integer} = {}
  for i, first in ipairs(scanned.firsts) do
    local k = at[first[1] * line_width + first[2]]
    if k == nil or (i > 1 and k <= starts[i - 1]) then
      return nil
    end
    local before_k = k > 1 and tokens[k - 1].tk or ""
    if before_k == "local" or before_k == "global" then
      k = k - 1
    elseif before_k == "type" and k > 2 and
        (tokens[k - 2].tk == "local" or tokens[k - 2].tk == "global") then
      k = k - 2
    end
    starts[i] = k
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
        -- The assignment of a name a kept statement spells stays: a local
        -- declared with no value is read in the stub only if the stub
        -- assigns it, as the source does.
        for _, name in ipairs(writes[i]) do
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
--- @param every whether to keep every top-level statement, leaving out
---   only bodies, as for a module that returns no name whose declaration
---   spells its type: what is kept of a statement is the same either way,
---   which `cosmic lsp` reads the top-level calls of
---   ([`build.lsp.check`]). The stub made is never `pruned` then.
function stub.made(parsed: ast.Parsed, every?: boolean): stub.Made
  local scanned = scan(parsed.node)
  local spans: {Span} = {}
  for _, span in ipairs(scanned.bodies) do
    spans[#spans + 1] = span
  end
  local dropped: {Span} | nil = nil
  if every ~= true then dropped = unneeded(parsed, scanned) end
  for _, span in ipairs(dropped or {}) do
    spans[#spans + 1] = span
  end
  -- A statement left out starts before the bodies inside it, so each
  -- span comes before those it holds.
  table.sort(spans, function(a: Span, b: Span): boolean
    return before(a.y, a.x, b.y, b.x)
  end)
  local out: {string} = {}
  local cursor = { y = 1, x = 1 }
  local function put(at_y: integer, at_x: integer, text: string)
    if at_y > cursor.y then
      out[#out + 1] = ("\n"):rep(at_y - cursor.y)
      cursor.y, cursor.x = at_y, 1
    end
    if at_x > cursor.x then
      out[#out + 1] = (" "):rep(at_x - cursor.x)
    end
    out[#out + 1] = text
    -- A long string may span lines.
    local last = 0
    for at in text:gmatch("()\n") do
      cursor.y = cursor.y + 1
      last = math.tointeger(at) or 0
    end
    cursor.x = last > 0 and #text - last + 1 or at_x + #text
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
    else
      local instead = span.instead
      if instead ~= nil then
        put(span.y, span.x, instead)
        span.instead = nil
      end
    end
  end
  return { text = table.concat(out) .. "\n", pruned = dropped ~= nil }
end

--- The stub text `text` less where it puts its tokens: the form two stubs of
--- the same tokens share wherever they stand, which is what a dependent's
--- compile can see of a stub, since no output of it holds a position in
--- another module's source (a check names the dependent's own line, and a
--- diagnostic refuses the compile). A run of space between tokens is one
--- space, or one line break where it held any, and the text starts at its
--- first token. The line break stays because tl reads a `(` on a later line
--- than the token before it as a statement of its own; how many lines apart,
--- and in which column, it does not read. A string, quoted or long, is kept
--- as it is. Text it cannot scan (a string that does not end) is answered
--- as it is, which only keeps what a position would have moved.
function stub.canonical(text: string): string
  local out: {string} = {}
  local at = 1
  local size = #text
  local find, sub = string.find, string.sub
  while at <= size do
    local from, to = find(text, "^%s+", at)
    local stop = find(text, "[%s\"'%[]", at) or size + 1
    if from ~= nil then
      if #out > 0 then
        out[#out + 1] = find(sub(text, from, to), "\n", 1, true) ~= nil and "\n" or " "
      end
      at = to + 1
    elseif stop > at then
      out[#out + 1] = sub(text, at, stop - 1)
      at = stop
    else
      local c = sub(text, at, at)
      local close: integer | nil = nil
      local level = c == "[" and text:match("^%[(=*)%[", at) or nil
      if c == "[" and level == nil then
        close = at
      elseif level ~= nil then
        local _, e = find(text, "]" .. level .. "]", at + #level + 2, true)
        close = e
      else
        local k = at + 1
        while k <= size do
          local e = find(text, "[\\" .. c .. "]", k)
          if e == nil then
            break
          elseif sub(text, e, e) == "\\" then
            k = e + 2
          else
            close = e
            break
          end
        end
      end
      if close == nil then
        return text
      end
      out[#out + 1] = sub(text, at, close)
      at = close + 1
    end
  end
  return table.concat(out)
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
