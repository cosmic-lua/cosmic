--- The stub of a standard-library module: what a project's checker reads
--- in place of its source to type a `require` of it.
---
--- A stub is the module's source with every function body left out and
--- nothing else changed: each token outside a body stays at the line and
--- column it had, so a position the checker reports in the module means
--- the same in either, and its requires, types, records and top-level
--- statements are the source's own. Comments and the space between
--- tokens are dropped, since the checker reads neither; lexing them is a
--- good part of what a module costs it.
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

--- The stub of the module `parsed` holds (see the module's own doc).
--- @param parsed a parse of the module's source ([`ast.parse`]), whose
---   tokens are in source order
function stub.of(parsed: ast.Parsed): string
  -- TODO: a cold build of a project requiring cosmic.web still spends
  -- about 0.25 s checking its 59 stubs, near the 0.3 s it was meant to
  -- come in well under: leave out what no exported type depends on as well --
  -- top-level statements that declare no type, and requires only the
  -- bodies read -- or write a declaration (`.d.tl`) from a module whose
  -- record declares its whole surface, keeping the stub for the rest.
  local spans = bodies(parsed.node)
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
