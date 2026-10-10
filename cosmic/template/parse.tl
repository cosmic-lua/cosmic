--- Parses the lexer's items into a [`Types.Template`]. Private to
--- [`cosmic.template`].
---
--- The grammar, one action to a line of it:
---
---     {{type Name from import.path}}     first, after blank text only
---     {{mode html}}  {{mode text}}       optional, directly after it
---     {{.}}  {{.a.b}}  {{.a | m.f}}      a value, put into the output
---     {{"{{"}}                           a string's bytes, as literal text
---     {{if P}} .. {{else if P}} .. {{else}} .. {{end}}
---     {{range P}} .. {{end}}             dot is each element, in order
---     {{with P}} .. {{else}} .. {{end}}  dot is the value, when it is truthy
---
--- where a pipeline `P` is a path of fields from dot (`.` alone is dot)
--- and then stages `| import.path.func`, each applied to what is before
--- it. A path's names and a stage's module and function are identifiers;
--- the module is reached by `require` of its path, and what it is called
--- is the name after the last dot. A string (`"` to `"`, with `\"` and
--- `\\` its only escapes) stands only as the whole of an action, never in
--- a pipeline: its bytes are literal text, the same as if written outside
--- an action, so `html` mode tracks them as markup and escapes nothing.
---
--- Every refusal reads `name:line:col: reason`, where line and column are
--- the offending word's, or its action's `{{` for one about the block.

local lex = require("cosmic.template.lex")
local types = require("cosmic.template.types")

--- Where the parse is: the items, the next one to read, and the template's
--- name for messages.
local record Parser
  items: {types.Item}
  pos: integer
  name: string
end

--- `name:line:col: reason`.
local function refuse(p: Parser, line: integer, col: integer, reason: string): string
  return p.name .. ":" .. line .. ":" .. col .. ": " .. reason
end

--- Whether `s` is a dotted run of identifiers, `min` names at least.
local function dotted(s: string, min: integer): boolean
  local count = 0
  for part in (s .. "."):gmatch("([^.]*)%.") do
    if not part:find("^[%a_][%w_]*$") then
      return false
    end
    count = count + 1
  end
  return count >= min
end

--- Why a string is refused anywhere but as the whole of an action.
local STRING_ALONE <const> = "a string is not a value: it stands alone, as {{\"{{\"}}, to write its bytes as literal text"

--- A hint for a word that starts with the `-` of a trim marker written
--- without the space it needs, or "".
local function trim_hint(token: types.Token): string
  if token.kind == "word" and token.value:sub(1, 1) == "-" then
    return ": a trim marker takes a space, as {{- and -}}"
  end
  return ""
end

--- The pipeline `tokens[first ..]` spell, which is all that is left of
--- the action.
local function pipeline(p: Parser, item: types.Item, first: integer): types.Pipeline | nil, string
  local tokens = item.tokens
  local head = tokens[first]
  if head == nil then
    return nil, refuse(p, item.line, item.col, "expected a value: a field path such as . or .name")
  end
  if head.kind ~= "field" or (head.value ~= "." and not dotted(head.value:sub(2), 1)) then
    return nil, refuse(p, head.line, head.col, head.kind == "string" and STRING_ALONE or
        "'" .. head.value .. "' is not a field path such as . or .a.b" .. trim_hint(head))
  end
  for at = first + 1, #tokens do
    if tokens[at].kind == "string" then
      return nil, refuse(p, tokens[at].line, tokens[at].col, STRING_ALONE)
    end
  end
  local path: {string} = {}
  if head.value ~= "." then
    for part in head.value:sub(2):gmatch("[^.]+") do
      path[#path + 1] = part
    end
  end
  local stages: {types.Stage} = {}
  local at = first + 1
  while tokens[at] ~= nil do
    local pipe = tokens[at]
    if pipe.kind ~= "pipe" then
      return nil, refuse(p, pipe.line, pipe.col, "expected | before '" .. pipe.value .. "'")
    end
    local stage = tokens[at + 1]
    if stage == nil then
      return nil, refuse(p, pipe.line, pipe.col, "expected a function after |, as module.path.func")
    end
    if stage.kind ~= "word" or not dotted(stage.value, 2) then
      return nil, refuse(p, stage.line, stage.col,
        "'" .. stage.value .. "' is not a function reached by import path, as module.path.func")
    end
    local module_path, func = stage.value:match("^(.+)%.([^.]+)$")
    stages[#stages + 1] = { module_path = module_path, func = func }
    at = at + 2
  end
  return { path = path, stages = stages }, ""
end

--- The first word of an action, or "" when it has none.
local function keyword(item: types.Item): string
  local head = item.tokens[1]
  if head ~= nil and head.kind == "word" then
    return head.value
  end
  return ""
end

local nodes: function(p: Parser): {types.Node} | nil, string

--- Parses the block action at the next item (`if`, `range` or `with`)
--- through its `{{end}}`.
local function block(p: Parser): types.Node | nil, string
  local open = p.items[p.pos]
  local word = keyword(open)
  p.pos = p.pos + 1
  local first, why = pipeline(p, open, 2)
  if first == nil then
    return nil, why
  end
  local kind: types.Kind = "if"
  if word == "range" then
    kind = "range"
  elseif word == "with" then
    kind = "with"
  end
  local node: types.Node = { kind = kind, line = open.line, col = open.col, end_line = open.end_line,
    close_line = open.end_line, text = "", branches = {}, ctx = "plain" }
  local cond: types.Pipeline = first
  local arm = open
  local seen_else = false
  while true do
    local body, berr = nodes(p)
    if body == nil then
      return nil, berr
    end
    node.branches[#node.branches + 1] = { pipeline = cond, body = body, line = arm.line, col = arm.col,
      end_line = arm.end_line }
    local close = p.items[p.pos]
    if close == nil then
      return nil, refuse(p, open.line, open.col, "{{" .. word .. "}} is never closed: missing {{end}}")
    end
    p.pos = p.pos + 1
    if keyword(close) == "end" then
      if #close.tokens ~= 1 then
        return nil, refuse(p, close.line, close.col, "{{end}} takes nothing")
      end
      node.close_line = close.line
      return node, ""
    end
    if kind == "range" then
      return nil, refuse(p, close.line, close.col,
        "{{else}} in a {{range}} is not supported: wrap the range in an {{if}} on the list")
    end
    if seen_else then
      return nil, refuse(p, close.line, close.col, "{{else}} after {{else}}")
    end
    local second = close.tokens[2]
    if second == nil then
      cond = nil
      seen_else = true
    elseif kind == "if" and second.kind == "word" and second.value == "if" then
      local next_cond, cerr = pipeline(p, close, 3)
      if next_cond == nil then
        return nil, cerr
      end
      cond = next_cond
    else
      return nil, refuse(p, second.line, second.col,
        kind == "with" and "{{else}} in a {{with}} takes nothing: nest an {{if}}" or
          "{{else}} takes nothing, or 'if' and a condition")
    end
    arm = close
  end
end

nodes = function(p: Parser): {types.Node} | nil, string
  local out: {types.Node} = {}
  while p.items[p.pos] ~= nil do
    local item = p.items[p.pos]
    if not item.action then
      out[#out + 1] = { kind = "text", line = item.line, col = item.col, end_line = item.line,
        close_line = item.line, text = item.text, branches = {}, ctx = "plain" }
      p.pos = p.pos + 1
    else
      local word = keyword(item)
      if word == "else" or word == "end" then
        return out, ""
      elseif word == "if" or word == "range" or word == "with" then
        local node, why = block(p)
        if node == nil then
          return nil, why
        end
        out[#out + 1] = node
      elseif word == "type" or word == "mode" then
        return nil, refuse(p, item.line, item.col, word == "type" and
            "{{type}} must be the first action" or "{{mode}} must directly follow {{type}}")
      elseif item.tokens[1] ~= nil and item.tokens[1].kind == "string" then
        local literal = item.tokens[1]
        local extra = item.tokens[2]
        if extra ~= nil then
          return nil, refuse(p, extra.line, extra.col,
            "a string stands alone in its action: {{\"...\"}} writes its bytes and takes nothing after them" ..
              trim_hint(extra))
        end
        -- An empty string writes nothing: no node, as the lexer makes none
        -- for an empty run of text.
        if literal.value ~= "" then
          out[#out + 1] = { kind = "text", line = literal.line, col = literal.col, end_line = literal.line,
            close_line = literal.line, text = literal.value, branches = {}, ctx = "plain" }
        end
        p.pos = p.pos + 1
      else
        local pipe, why = pipeline(p, item, 1)
        if pipe == nil then
          return nil, why
        end
        out[#out + 1] = { kind = "interp", line = item.line, col = item.col, end_line = item.end_line,
          close_line = item.end_line, text = "", pipeline = pipe, branches = {}, ctx = "plain" }
        p.pos = p.pos + 1
      end
    end
  end
  return out, ""
end

--- Whether `item` is literal text with nothing visible in it.
local function blank_text(item: types.Item): boolean
  return item ~= nil and not item.action and not item.text:find("[^ \t\r\n]")
end

--- Reads the `{{type}}` action at `item`: the record's name and where it
--- is from.
local function declaration(p: Parser, item: types.Item): string | nil, string
  local tokens = item.tokens
  if #tokens ~= 4 or tokens[3].kind ~= "word" or tokens[3].value ~= "from" then
    return nil, refuse(p, item.line, item.col, "write {{type Name from import.path}}")
  end
  local name = tokens[2]
  if name.kind ~= "word" or not name.value:find("^[%a_][%w_]*$") or types.keywords[name.value] then
    return nil, refuse(p, name.line, name.col, "'" .. name.value .. "' is not a type name")
  end
  local path = tokens[4]
  if path.kind ~= "word" or not dotted(path.value, 1) then
    return nil, refuse(p, path.line, path.col, "'" .. path.value .. "' is not an import path")
  end
  return name.value, ""
end

local record Parse
end

--- Parses a template.
--- @param src string The template source
--- @param name string The template's name, for messages
--- @return types.Template|nil The template
--- @return string The reason, as `name:line:col: ...`, on failure
function Parse.parse(src: string, name: string): types.Template | nil, string
  local lexed, lerr = lex.lex(src, name)
  if lexed == nil then
    return nil, lerr
  end
  local p: Parser = { items = lexed.items, pos = 1, name = name }
  if blank_text(p.items[p.pos]) then
    p.pos = p.pos + 1
  end
  local head = p.items[p.pos]
  if head == nil or not head.action or keyword(head) ~= "type" then
    local line = head ~= nil and head.line or 1
    local col = head ~= nil and head.col or 1
    return nil, refuse(p, line, col, "a template starts with {{type Name from import.path}}")
  end
  local type_name, terr = declaration(p, head)
  if type_name == nil then
    return nil, terr
  end
  local import_path = head.tokens[4].value
  p.pos = p.pos + 1
  local mode: types.Mode = "html"
  local at = p.pos
  if blank_text(p.items[at]) then
    at = at + 1
  end
  local decl = p.items[at]
  if decl ~= nil and decl.action and keyword(decl) == "mode" then
    local value = decl.tokens[2]
    if #decl.tokens ~= 2 or value.kind ~= "word" or (value.value ~= "html" and value.value ~= "text") then
      return nil, refuse(p, decl.line, decl.col, "write {{mode html}} or {{mode text}}")
    end
    mode = value.value == "text" and "text" or "html"
    p.pos = at + 1
  end
  local body, berr = nodes(p)
  if body == nil then
    return nil, berr
  end
  local stray = p.items[p.pos]
  if stray ~= nil then
    return nil, refuse(p, stray.line, stray.col, "{{" .. keyword(stray) .. "}} without a block to close")
  end
  return { type_name = type_name, import_path = import_path, mode = mode, body = body,
    lines = lexed.lines }, ""
end

return Parse
