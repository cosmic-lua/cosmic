--- Parses the lexer's items into a [`Types.Template`]. Private to
--- [`cosmic.template`].
---
--- The grammar, one action to a line of it:
---
---     {{type Name from import.path}}     first, after blank text only
---     {{mode html}}  {{mode text}}       optional, directly after it
---     {{use htmx}}                       optional, beside {{mode}} in either
---                                        order: a dialect of attributes
---     {{.}}  {{.a.b}}  {{.a | m.f}}      a value, put into the output
---     {{$}}  {{$.a}}  {{$x}}  {{$x.a}}   the same, from `$` or a variable
---     {{"{{"}}                           a string's bytes, as literal text
---     {{if P}} .. {{else if P}} .. {{else}} .. {{end}}
---     {{range P}} .. {{else}} .. {{end}} dot is each element, in order; the
---                                        else, if any, runs when there is none
---     {{range $x := P}} ..               the same, `$x` the element too
---     {{range $i, $x := P}} ..           and `$i` its index, from 1
---     {{with P}} .. {{else}} .. {{end}}  dot is the value, when it is filled
---     {{define name Type}} .. {{end}}    after the body, at the top level: a
---                                        template of `Type` of its own, which
---                                        `| name` calls and the module exports
---
--- where a pipeline `P` is a head, a path of fields from it, and then
--- stages `| import.path.func` (or `| name`, a `{{define}}`), each applied
--- to what is before it, and given after it the arguments that follow
--- its name: strings, numbers and paths (`| fmt.date "%Y" .zone`). The
--- head is dot (`.a` is a field of dot, `.` alone is dot), `$` (the value
--- `render`, or the `{{define}}` it stands in, is given) or a variable `$name`. A range's
--- variables are seen in its own body and everything nested in it, not in
--- its `{{else}}` nor after its `{{end}}`, so a variable used where none of
--- that name is seen is refused; and a name is bound only where no
--- variable of that name is seen, so a variable always names one value.
--- A path's names, a variable's and a stage's module and function are
--- identifiers; the module is reached by `require` of its path, and what
--- it is called is the name after the last dot. A string (`"` to `"`,
--- with `\"` and `\\` its only escapes) stands only as the whole of an
--- action, never in a pipeline: its bytes are literal text, the same as if
--- written outside an action, so `html` mode tracks them as markup and
--- escapes nothing.
---
--- Every refusal reads `name:line:col: reason`, where line and column are
--- the offending word's, or its action's `{{` for one about the block.

local lex = require("cosmic.template.lex")
local types = require("cosmic.template.types")

--- Where the parse is: the items, the next one to read, and the template's
--- name for messages.
local record Parser
  items: {types.Item}
  mut pos: integer
  name: string
  --- The variables seen where the parse is, by name without the `$`,
  --- each with the word that bound it.
  visible: mut {string: types.Token}
  --- How many blocks the parse is inside: a `{{define}}` stands at 0.
  mut depth: integer
end

--- `name:line:col: reason`.
local function refuse(p: Parser, line: integer, col: integer, reason: string): string
  return p.name .. ":" .. tostring(line) .. ":" .. tostring(col) .. ": " .. reason
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

--- Why `:=` is refused outside a range.
local BINDS_ALONE <const> = "only {{range}} binds variables, as {{range $i, $x := .list}}"

--- Why `:=` is refused in a range's list.
local BINDS_ONCE <const> = "unexpected ':=': a range binds once, before its list, as {{range $i, $x := .list}}"

--- Why `,` is refused anywhere but between a range's two variables.
local STRAY_COMMA <const> = "unexpected ',': only a range's two variables take one, as {{range $i, $x := .list}}"

--- The names of the run of fields `path` (`.a.b`, or "" for none).
local function fields(path: string): {string}
  local out: mut {string} = {}
  for part in path:gmatch("[^.]+") do
    out[#out + 1] = part
  end
  return out
end

--- The path `token` spells, from dot, `$` or a variable, with no stages.
local function path_of(p: Parser, token: types.Token): types.Pipeline?, string
  local result: types.Pipeline = { head = "dot", name = "", path = {}, stages = {} }
  if token.kind == "variable" then
    local name = token.value:match("^%$([%a_][%w_]*)") or ""
    local rest = token.value:sub(2 + #name)
    if rest ~= "" and (rest:sub(1, 1) ~= "." or not dotted(rest:sub(2), 1)) then
      return nil, refuse(p, token.line, token.col,
        "'" .. token.value .. "' is not a variable such as $, $.a, $x or $x.a")
    end
    result.head = if name == "" then "root" else "variable" end
    result.name = name
    result.path = fields(rest)
  elseif token.kind == "field" and (token.value == "." or dotted(token.value:sub(2), 1)) then
    result.path = fields(token.value:sub(2))
  else
    return nil, refuse(p, token.line, token.col, if token.kind == "string" then STRING_ALONE else
      "'" .. token.value .. "' is not a field path such as . or .a.b, nor a variable such as $ or $x.a" ..
        trim_hint(token) end)
  end
  return result, ""
end

--- Why the variable `path` starts from, which `token` spells, is not seen
--- here, or "".
local function unseen(p: Parser, path: types.Pipeline, token: types.Token): string
  if path.head == "variable" and p.visible[path.name] == nil then
    return refuse(p, token.line, token.col, "'$" .. path.name .. "' is not declared here: a variable is seen only in the body of " ..
        "the {{range}} that binds it, as {{range $x := .list}}")
  end
  return ""
end

--- The argument `token` spells after a stage: a string, a number, or a
--- path.
local function argument(p: Parser, token: types.Token): types.Arg?, string
  if token.kind == "string" then
    return { kind = "string", text = token.value }, ""
  elseif token.kind == "word" then
    local v = token.value
    -- An integer is one Lua reads as an integer, with no leading zero.
    local whole = v:find("^%-?[1-9]%d*$") ~= nil or v == "0"
    if (whole and math.tointeger(tonumber(v)) ~= nil) or v:find("^%-?%d+%.%d+$") ~= nil then
      return { kind = "number", text = v }, ""
    end
    return nil, refuse(p, token.line, token.col, "'" .. v .. "' is not an argument: a stage takes strings (\"x\"), " ..
        "numbers (2, -1, 0.5) and paths (.a, $, $x.a) after the value piped to it" .. trim_hint(token))
  end
  local path, why = path_of(p, token)
  if path == nil then
    return nil, why
  end
  local hidden = unseen(p, path, token)
  if hidden ~= "" then
    return nil, hidden
  end
  return { kind = "path", text = "", path = path }, ""
end

--- The pipeline `tokens[first ..]` spell, which is all that is left of
--- the action; `ranged` when it is a range's list.
local function pipeline(p: Parser, item: types.Item, first: integer, ranged: boolean): types.Pipeline?, string
  local tokens = item.tokens
  local head = tokens[first]
  if head == nil then
    return nil, refuse(p, item.line, item.col, "expected a value: a field path such as . or .name, or $ or $x.name")
  end
  local result, hwhy = path_of(p, head)
  if result == nil then
    return nil, hwhy
  end
  -- A comma or `:=` is never part of a pipeline, nor a string before the first stage.
  local staged = false
  for at = first + 1, #tokens do
    local token = assert(tokens[at], "the loop stays inside the tokens")
    local kind = token.kind
    local why = ""
    if kind == "pipe" then
      staged = true
    elseif kind == "string" and not staged then
      why = STRING_ALONE
    elseif kind == "comma" then
      why = STRAY_COMMA
    elseif kind == "declare" then
      why = if ranged then BINDS_ONCE else BINDS_ALONE end
    end
    if why ~= "" then
      return nil, refuse(p, token.line, token.col, why)
    end
  end
  local hidden = unseen(p, result, head)
  if hidden ~= "" then
    return nil, hidden
  end
  local stages = result.stages
  local at = first + 1
  local pipe = tokens[at]
  while pipe ~= nil do
    if pipe.kind ~= "pipe" then
      return nil, refuse(p, pipe.line, pipe.col, "expected | before '" .. pipe.value .. "'")
    end
    local stage = tokens[at + 1]
    if stage == nil then
      return nil, refuse(p, pipe.line, pipe.col, "expected a function after |, as module.path.func")
    end
    if stage.kind == "string" then
      return nil, refuse(p, stage.line, stage.col, "a string is not a function: write the stage's name bare, " ..
          "as | module.path.func")
    end
    -- The stage's name is checked before its arguments, so a refusal names
    -- what goes wrong first.
    local module_path, func = "", stage.value
    local after = tokens[at + 2]
    if stage.kind == "word" and dotted(stage.value, 1) and not dotted(stage.value, 2) then
      -- One name is a `{{define}}` of this template, which the parse checks once it has read them all.
      if after ~= nil and after.kind ~= "pipe" then
        return nil, refuse(p, stage.line, stage.col, "'" .. stage.value .. "' is one name, as only a {{define}} is " ..
            "called, and a {{define}} takes no arguments: a function that takes them is written module.path.func")
      end
    else
      if stage.kind ~= "word" or not dotted(stage.value, 2) then
        return nil, refuse(p, stage.line, stage.col,
          "'" .. stage.value .. "' is not a function reached by import path, as module.path.func, nor a {{define}}'s name")
      end
      local path, name = stage.value:match("^(.+)%.([^.]+)$")
      if path == nil or name == nil then
        return nil, refuse(p, stage.line, stage.col,
          "'" .. stage.value .. "' is not a function reached by import path, as module.path.func")
      end
      module_path, func = path, name
    end
    local args: mut {types.Arg} = {}
    at = at + 2
    local next_token = tokens[at]
    while next_token ~= nil and next_token.kind ~= "pipe" do
      local given, why = argument(p, next_token)
      if given == nil then
        return nil, why
      end
      args[#args + 1] = given
      at = at + 1
      next_token = tokens[at]
    end
    stages[#stages + 1] = { module_path = module_path, func = func, line = stage.line, col = stage.col, args = args }
    pipe = next_token
  end
  return result, ""
end

--- What a range binds: the words naming its index and its element (nil
--- for none), and where its pipeline starts.
local record Bound
  index?: types.Token
  element?: types.Token
  first: integer
end

--- Reads the bindings that open the range action `item`, `$x :=` or
--- `$i, $x :=`, if it has any.
local function bindings(p: Parser, item: types.Item): Bound?, string
  local tokens = item.tokens
  local one, after = tokens[2], tokens[3]
  if one ~= nil and one.kind == "variable" and after ~= nil and (after.kind == "field" or after.kind == "variable") then
    return nil, refuse(p, after.line, after.col, "expected := after " .. one.value .. ", as {{range $x := .list}}")
  end
  if one == nil or one.kind ~= "variable" or after == nil or (after.kind ~= "comma" and after.kind ~= "declare") then
    return { first = 2 }, ""
  end
  local names: mut {types.Token} = { one }
  if after.kind == "comma" then
    local two = tokens[4]
    if two == nil or two.kind ~= "variable" then
      local at = two or after
      return nil, refuse(p, at.line, at.col, "expected a variable to bind after ',', as {{range $i, $x := .list}}")
    end
    names[#names + 1] = two
    local declare = tokens[5]
    if declare == nil or declare.kind ~= "declare" then
      local at = declare or two
      return nil, refuse(p, at.line, at.col, "expected := after " .. two.value .. ", as {{range $i, $x := .list}}")
    end
  end
  local here: mut {string: types.Token} = {}
  for _, word in ipairs(names) do
    local name = word.value:sub(2)
    if not name:find("^[%a_][%w_]*$") then
      return nil, refuse(p, word.line, word.col,
        "'" .. word.value .. "' is not a name to bind: write $ and an identifier, as $x")
    end
    local seen = p.visible[name] or here[name]
    if seen ~= nil then
      return nil, refuse(p, word.line, word.col, "'" .. word.value .. "' is already declared at " .. tostring(seen.line) ..
          ":" .. tostring(seen.col) .. ": bind another name, so that each names one value")
    end
    here[name] = word
  end
  if #names == 2 then
    return { index = names[1], element = names[2], first = 6 }, ""
  end
  return { element = names[1], first = 4 }, ""
end

--- The first word of an action, or "" when it has none.
local function keyword(item: types.Item): string
  local head = item.tokens[1]
  if head ~= nil and head.kind == "word" then
    return head.value
  end
  return ""
end

local nodes: function(p: Parser): {types.Node}?, string

--- Parses the block action at the next item (`if`, `range` or `with`)
--- through its `{{end}}`.
local function block(p: Parser, open: types.Item): types.Node?, string -- checked: not_assigned
  local word = keyword(open)
  p.pos = p.pos + 1
  local bound: Bound = { first = 2 }
  if word == "range" then
    local read, bwhy = bindings(p, open)
    if read == nil then
      return nil, bwhy
    end
    bound = read
  end
  local first, why = pipeline(p, open, bound.first, word == "range")
  if first == nil then
    return nil, why
  end
  local index_token, element_token = bound.index, bound.element
  local index = index_token and index_token.value:sub(2) or ""
  local element = element_token and element_token.value:sub(2) or ""
  local kind: types.Kind = "if"
  if word == "range" then
    kind = "range"
  elseif word == "with" then
    kind = "with"
  end
  local node: types.Node = { kind = kind, line = open.line, col = open.col, end_line = open.end_line,
    close_line = open.end_line, text = "", branches = {}, ctx = "plain" }
  local cond: types.Pipeline? = first
  local arm = open
  local seen_else = false
  -- The range's own arm alone sees its variables.
  if index ~= "" and index_token ~= nil then
    p.visible[index] = index_token
  end
  if element ~= "" and element_token ~= nil then
    p.visible[element] = element_token
  end
  p.depth = p.depth + 1
  while true do
    local body, berr = nodes(p)
    if body == nil then
      return nil, berr
    end
    local own = #node.branches == 0
    node.branches[#node.branches + 1] = { pipeline = cond, index = if own then index else "" end,
      element = if own then element else "" end, body = body, line = arm.line, col = arm.col, end_line = arm.end_line }
    if own then
      p.visible[index] = nil
      p.visible[element] = nil
    end
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
      p.depth = p.depth - 1
      return node, ""
    end
    if seen_else then
      return nil, refuse(p, close.line, close.col, "{{else}} after {{else}}")
    end
    local second = close.tokens[2]
    if second == nil then
      cond = nil
      seen_else = true
    elseif kind == "if" and second.kind == "word" and second.value == "if" then
      local next_cond, cerr = pipeline(p, close, 3, false)
      if next_cond == nil then
        return nil, cerr
      end
      cond = next_cond
    else
      return nil, refuse(p, second.line, second.col,
        if kind ~= "if" then "{{else}} in a {{" .. kind .. "}} takes nothing: nest an {{if}}" else
          "{{else}} takes nothing, or 'if' and a condition" end)
    end
    arm = close
  end
end

nodes = function(p: Parser): {types.Node}?, string
  local out: mut {types.Node} = {}
  while true do
    local item = p.items[p.pos]
    if item == nil then break end
    if not item.action then
      out[#out + 1] = { kind = "text", line = item.line, col = item.col, end_line = item.line,
        close_line = item.line, text = item.text, branches = {}, ctx = "plain" }
      p.pos = p.pos + 1
    else
      local word = keyword(item)
      local first_token = item.tokens[1]
      if word == "else" or word == "end" then
        return out, ""
      elseif word == "define" then
        if p.depth > 0 then
          return nil, refuse(p, item.line, item.col, "{{define}} stands at the top level, after the body, in no block")
        end
        return out, ""
      elseif word == "if" or word == "range" or word == "with" then
        local node, why = block(p, item)
        if node == nil then
          return nil, why
        end
        out[#out + 1] = node
      elseif word == "type" or word == "mode" or word == "use" then
        return nil, refuse(p, item.line, item.col, if word == "type" then
          "{{type}} must be the first action" else "{{" .. word .. "}} must directly follow {{type}}" ..
            (if word == "use" then " or {{mode}}" else "" end) end)
      elseif first_token ~= nil and first_token.kind == "string" then
        local literal = first_token
        local extra = item.tokens[2]
        if extra ~= nil then
          return nil, refuse(p, extra.line, extra.col,
            "a string stands alone in its action: {{\"...\"}} writes its bytes and takes nothing after them" ..
              trim_hint(extra))
        end
        -- An empty string writes nothing: no node, as the lexer makes none
        -- for an empty run of text. The text's first byte stands just past
        -- the opening quote, where a refusal of it points; one past an escape
        -- is a column early.
        if literal.value ~= "" then
          out[#out + 1] = { kind = "text", line = literal.line, col = literal.col + 1, end_line = literal.line,
            close_line = literal.line, text = literal.value, branches = {}, ctx = "plain" }
        end
        p.pos = p.pos + 1
      else
        local pipe, why = pipeline(p, item, 1, false)
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
local function blank_text(item: types.Item?): boolean
  return item ~= nil and not item.action and not item.text:find("[^ \t\r\n]")
end

--- The record a `{{type}}` action names and the import path it is from.
local record Declared
  name: string
  import_path: string
end

--- Reads the `{{type}}` action at `item`: the record's name and where it
--- is from.
local function declaration(p: Parser, item: types.Item): Declared?, string
  local tokens = item.tokens
  local name, from, path = tokens[2], tokens[3], tokens[4]
  if #tokens ~= 4 or name == nil or from == nil or path == nil or from.kind ~= "word" or from.value ~= "from" then
    return nil, refuse(p, item.line, item.col, "write {{type Name from import.path}}")
  end
  if name.kind ~= "word" or not name.value:find("^[%a_][%w_]*$") or types.keywords[name.value] == true then
    return nil, refuse(p, name.line, name.col, "'" .. name.value .. "' is not a type name")
  end
  if path.kind ~= "word" or not dotted(path.value, 1) then
    return nil, refuse(p, path.line, path.col, "'" .. path.value .. "' is not an import path")
  end
  return { name = name.value, import_path = path.value }, ""
end

--- Reads the `{{define}}`s from the next item on, each with the blank
--- text after it.
local function definitions(p: Parser): {types.Define}?, string
  local defines: mut {types.Define} = {}
  local seen: mut {string: boolean} = {}
  local open = p.items[p.pos]
  while open ~= nil and open.action and keyword(open) == "define" do
    local tokens = open.tokens
    local name, type_name = tokens[2], tokens[3]
    if #tokens ~= 3 or name == nil or type_name == nil or name.kind ~= "word" or type_name.kind ~= "word" then
      return nil, refuse(p, open.line, open.col, "write {{define name Type}}, Type a record of the {{type}}'s module")
    end
    if not name.value:find("^[%a_][%w_]*$") or types.keywords[name.value] == true or name.value == "render" or
        name.value:sub(1, 2) == "__" then
      return nil, refuse(p, name.line, name.col, "'" .. name.value .. "' is not a name for a {{define}}: write an " ..
          "identifier other than render, which the module exports for the body, that starts with no __")
    end
    if seen[name.value] == true then
      return nil, refuse(p, name.line, name.col, "'" .. name.value .. "' is defined twice")
    end
    if not type_name.value:find("^[%a_][%w_]*$") or types.keywords[type_name.value] == true then
      return nil, refuse(p, type_name.line, type_name.col, "'" .. type_name.value .. "' is not a type name")
    end
    seen[name.value] = true
    p.pos = p.pos + 1
    local body, why = nodes(p)
    if body == nil then
      return nil, why
    end
    local close = p.items[p.pos]
    if close == nil then
      return nil, refuse(p, open.line, open.col, "{{define}} is never closed: missing {{end}}")
    elseif keyword(close) ~= "end" then
      return nil, refuse(p, close.line, close.col, "{{" .. keyword(close) .. "}} inside a {{define}}: " ..
          (if keyword(close) == "define" then "close the one before with {{end}} first" else
            "it has no block to belong to" end))
    elseif #close.tokens ~= 1 then
      return nil, refuse(p, close.line, close.col, "{{end}} takes nothing")
    end
    defines[#defines + 1] = { name = name.value, type_name = type_name.value, body = body, line = open.line,
      col = open.col, end_line = close.line, end_col = close.col }
    p.pos = p.pos + 1
    if blank_text(p.items[p.pos]) then
      p.pos = p.pos + 1
    end
    open = p.items[p.pos]
  end
  return defines, ""
end

--- Why a stage of one name in `body` or the `defines` names none of them,
--- or "".
local function called_defines(p: Parser, body: {types.Node}, defines: {types.Define}): string
  local named: mut {string: boolean} = {}
  for _, define in ipairs(defines) do
    named[define.name] = true
  end
  local function pipeline_ok(pipe: types.Pipeline?): string
    if pipe == nil then return "" end
    for _, stage in ipairs(pipe.stages) do
      if stage.module_path == "" and named[stage.func] == nil then
        return refuse(p, stage.line, stage.col, "'" .. stage.func .. "' names no {{define}} of this template, " ..
            "and a function of a module is reached by its path, as module.path.func")
      end
    end
    return ""
  end
  local function walk(list: {types.Node}): string
    for _, node in ipairs(list) do
      local why = pipeline_ok(node.pipeline)
      if why ~= "" then return why end
      for _, branch in ipairs(node.branches) do
        why = pipeline_ok(branch.pipeline)
        if why ~= "" then return why end
        why = walk(branch.body)
        if why ~= "" then return why end
      end
    end
    return ""
  end
  local why = walk(body)
  if why ~= "" then return why end
  for _, define in ipairs(defines) do
    why = walk(define.body)
    if why ~= "" then return why end
  end
  return ""
end

local record Parse
end

--- Parses a template.
--- @param src string The template source
--- @param name string The template's name, for messages
--- @param registry {string: types.Def} The dialects `{{use}}` may name
--- @return types.Template|nil The template
--- @return string The reason, as `name:line:col: ...`, on failure
function Parse.parse(src: string, name: string, registry: {string: types.Def}): types.Template?, string
  local lexed, lerr = lex.lex(src, name)
  if lexed == nil then
    return nil, lerr
  end
  local p: Parser = { items = lexed.items, pos = 1, name = name, visible = {}, depth = 0 }
  if blank_text(p.items[p.pos]) then
    p.pos = p.pos + 1
  end
  local head = p.items[p.pos]
  if head == nil or not head.action or keyword(head) ~= "type" then
    local line = if head ~= nil then head.line else 1 end
    local col = if head ~= nil then head.col else 1 end
    return nil, refuse(p, line, col, "a template starts with {{type Name from import.path}}")
  end
  local declared, terr = declaration(p, head)
  if declared == nil then
    return nil, terr
  end
  p.pos = p.pos + 1
  local mode: types.Mode = "html"
  local dialects: mut {string} = {}
  local uses: mut {string: boolean} = {}
  local first_use: types.Item?
  local seen_mode = false
  -- `{{mode}}` and `{{use}}` follow `{{type}}` in any order, each with blank
  -- text before it; the blank text after the last is the body's.
  while true do
    local at = p.pos
    if blank_text(p.items[at]) then
      at = at + 1
    end
    local decl = p.items[at]
    if decl == nil or not decl.action then break end
    local word = keyword(decl)
    if word == "mode" then
      local value = decl.tokens[2]
      if #decl.tokens ~= 2 or value == nil or value.kind ~= "word" or (value.value ~= "html" and value.value ~= "text") then
        return nil, refuse(p, decl.line, decl.col, "write {{mode html}} or {{mode text}}")
      elseif seen_mode then
        return nil, refuse(p, decl.line, decl.col, "{{mode}} is given once")
      end
      seen_mode = true
      mode = if value.value == "text" then "text" else "html" end
    elseif word == "use" then
      local value = decl.tokens[2]
      if #decl.tokens ~= 2 or value == nil or value.kind ~= "word" or not value.value:find("^[%a][%w_]*$") then
        return nil, refuse(p, decl.line, decl.col, "write {{use name}}, as {{use htmx}}")
      end
      if registry[value.value] == nil then
        local names: mut {string} = {}
        for dialect in pairs(registry) do
          names[#names + 1] = dialect
        end
        table.sort(names)
        return nil, refuse(p, value.line, value.col, "unknown dialect '" .. value.value .. "' (known: " ..
            table.concat(names, ", ") .. ")")
      elseif uses[value.value] == true then
        return nil, refuse(p, decl.line, decl.col, "{{use " .. value.value .. "}} is given once")
      end
      uses[value.value] = true
      dialects[#dialects + 1] = value.value
      if first_use == nil then first_use = decl end
    else
      break
    end
    p.pos = at + 1
  end
  if mode == "text" and first_use ~= nil then
    return nil, refuse(p, first_use.line, first_use.col, "a text template has no attributes: {{use}} is for an html template")
  end
  local body, berr = nodes(p)
  if body == nil then
    return nil, berr
  end
  local _, newlines = src:gsub("\n", "")
  local body_end_line = newlines + 1
  local body_end_col = #src - (src:match(".*()\n") or 0) + 1
  local defines, dwhy = definitions(p)
  if defines == nil then
    return nil, dwhy
  end
  local first_define = defines[1]
  if first_define ~= nil then
    body_end_line, body_end_col = first_define.line, first_define.col
  end
  local stray = p.items[p.pos]
  if stray ~= nil then
    if #defines > 0 and (not stray.action or (keyword(stray) ~= "else" and keyword(stray) ~= "end")) then
      return nil, refuse(p, stray.line, stray.col, (if stray.action then "an action" else "text" end) ..
          " after a {{define}}: after the first, only blank text and other {{define}}s follow")
    end
    return nil, refuse(p, stray.line, stray.col, "{{" .. keyword(stray) .. "}} without a block to close")
  end
  local called = called_defines(p, body, defines)
  if called ~= "" then
    return nil, called
  end
  return { type_name = declared.name, import_path = declared.import_path, line = head.line, mode = mode,
    dialects = dialects, body = body, body_end_line = body_end_line, body_end_col = body_end_col, defines = defines,
    lines = lexed.lines }, ""
end

return Parse
