--- Parses a lexed token stream into a `types.Template`. Internal to
--- `cosmic.template` — see `cosmic/template/types.tl` for the AST and
--- why this directory is not the published API.
---
--- The grammar this parses:
---
---   {{type <Record> from <import.path>}}   required, first action
---   {{mode html}}                          optional, must directly
---                                           follow the type decl
---   {{.field}} {{.a.b}}                    field access
---   {{if <pipeline>}} … {{else}} … {{end}}
---   {{range <pipeline>}} … {{end}}         rebinds dot to the element
---   {{with <pipeline>}} … {{end}}          rescopes dot
---   {{<pipeline> | <import.path>}}         pipeline stages, left to right
---
--- There is no `{{template}}` action — composition is a pipeline stage
--- naming another compiled template's `render`.

local lex = require("cosmic.template.lex")
local types = require("cosmic.template.types")

--- An empty pipeline, for Node fields a given kind does not use.
local EMPTY_PIPELINE < const >: types.Pipeline = {path = {}, stages = {}, line = 0}

--- The result of parsing a run of nodes: the nodes themselves, plus
--- which stop word ended the run ("" at EOF) — `parse_nodes`'s only
--- extra beyond success or failure, carried here rather than as a
--- third return slot (`fallible-returns`, see `cosmic --docs guide.lint`).
local record NodesResult
  nodes: {types.Node}
  stop: string
end

local STOP_ELSE < const >: {string: boolean} = {["else"] = true, ["end"] = true}
local STOP_END < const >: {string: boolean} = {["end"] = true}

--- Split a pipeline stage's import path into the module to `require`
--- and the function called on it. `cosmic.html.safe` splits into
--- "cosmic.html" and "safe"; a path with no dot has no module to
--- require, so it cannot be a pipeline stage.
--- @param s string The dotted import path
--- @return string|nil The module path
--- @return string The function name, or an error when s has no dot
local function split_import(s: string): string | nil, string
  local mod, func = s:match("^(.+)%.([^.]+)$")
  if not mod then
    return nil, "'" .. s .. "' is not a function reached by import path" ..
    " (expected module.function)"
  end
  return mod, func
end

--- Parse a lexed token stream into a Template.
--- @param toks {types.Token} The tokens to parse
--- @param name string The template's name, for error messages
--- @return types.Template|nil The parsed template
--- @return string The error, with template line and column, on failure
local function parse_tokens(toks: {types.Token}, name: string):
  types.Template | nil, string
  local pos = 1

  local function peek(): types.Token
    return toks[pos]
  end

  local function advance(): types.Token
    local t = toks[pos]
    pos = pos + 1
    return t
  end

  local function err_at(t: types.Token, msg: string): string
    if not t then
      return name .. ": " .. msg .. " (reached end of template)"
    end
    return name .. ":" .. t.line .. ":" .. t.col .. ": " .. msg
  end

  local function skip_blank_text()
    while peek() and peek().kind == "text" and peek().value:match("^%s*$") do
      advance()
    end
  end

  local function expect(kind: string, what: string): types.Token | nil, string
    local t = peek()
    if not t or t.kind ~= kind then
      return nil, err_at(t, "expected " .. what)
    end
    return advance(), ""
  end

  --- A pipeline: the current token must be a "field" token. Consumes
  --- it and any trailing `| <import.path>` stages.
  local function parse_pipeline(): types.Pipeline | nil, string
    local ftok, ferr = expect("field", "a field path (e.g. '.' or '.name')")
    if not ftok then
      return nil, ferr
    end
    local path: {string} = {}
    for seg in ftok.value:gmatch("[^.]+") do
      path[#path + 1] = seg
    end
    local stages: {types.Stage} = {}
    while peek() and peek().kind == "pipe" do
      advance()
      local wtok, werr = expect("word", "a function's import path after '|'")
      if not wtok then
        return nil, werr
      end
      local mod, func = split_import(wtok.value)
      if not mod then
        return nil, err_at(wtok, func)
      end
      stages[#stages + 1] = {import_path = wtok.value, module_path = mod,
        func_name = func, line = wtok.line}
    end
    return {path = path, stages = stages, line = ftok.line}, ""
  end

  -- `parse_action` and `parse_nodes` recur into each other (a block
  -- body is a node list, and a node list can hold a block action), so
  -- both are forward-declared and assigned below.
  local parse_action: function(): types.Node | nil, string
  local parse_nodes: function({string: boolean}): NodesResult | nil, string

  --- Nodes until EOF or an `{{end}}`/`{{else}}` whose word is in
  --- `stop_words`. The stopping action's `{{` is left unconsumed so
  --- the caller can dispatch on which word stopped it.
  --- @return NodesResult|nil The nodes, and which stop word ended them
  --- @return string The error on failure
  parse_nodes = function(stop_words: {string: boolean}): NodesResult | nil, string
    local nodes: {types.Node} = {}
    while true do
      local t = peek()
      if not t then
        if next(stop_words) then
          return nil, name .. ": unexpected end of template: missing {{end}}"
        end
        return {nodes = nodes, stop = ""}, ""
      elseif t.kind == "text" then
        advance()
        nodes[#nodes + 1] = {kind = "text", text = t.value,
          pipeline = EMPTY_PIPELINE, body = {}, else_body = {}, line = t.line}
      elseif t.kind == "open" then
        local nxt = toks[pos + 1]
        if nxt and nxt.kind == "word" and stop_words[nxt.value] then
          return {nodes = nodes, stop = nxt.value}, ""
        end
        local node, aerr = parse_action()
        if not node then
          return nil, aerr
        end
        nodes[#nodes + 1] = node
      else
        return nil, err_at(t, "unexpected '" .. t.value .. "' outside an action")
      end
    end
  end

  --- One `{{...}}` action: an interpolation, or an `if`/`range`/`with`
  --- block through its matching `{{end}}`. `peek()` is the action's
  --- `{{` on entry.
  parse_action = function(): types.Node | nil, string
    advance() -- "{{"
    local head = peek()
    if not head then
      return nil, err_at(nil, "an action must have content")
    end
    if head.kind == "word"
    and (head.value == "if" or head.value == "range" or head.value == "with") then
      local kw = advance().value
      local pipe, perr = parse_pipeline()
      if not pipe then
        return nil, perr
      end
      local _, cerr = expect("close", "'}}'")
      if cerr ~= "" then
        return nil, cerr
      end
      local stop_first = kw == "if" and STOP_ELSE or STOP_END
      local res1, berr1 = parse_nodes(stop_first)
      if not res1 then
        return nil, berr1
      end
      local else_body: {types.Node} = {}
      if kw == "if" and res1.stop == "else" then
        advance() -- "{{"
        advance() -- "else"
        local _, eerr = expect("close", "'}}'")
        if eerr ~= "" then
          return nil, eerr
        end
        local res2, berr2 = parse_nodes(STOP_END)
        if not res2 then
          return nil, berr2
        end
        else_body = res2.nodes
      end
      advance() -- "{{"
      advance() -- "end"
      local _, eerr2 = expect("close", "'}}'")
      if eerr2 ~= "" then
        return nil, eerr2
      end
      return {kind = kw, pipeline = pipe, body = res1.nodes, else_body = else_body,
        text = "", line = head.line}, ""
    elseif head.kind == "field" then
      local pipe, perr = parse_pipeline()
      if not pipe then
        return nil, perr
      end
      local _, cerr = expect("close", "'}}'")
      if cerr ~= "" then
        return nil, cerr
      end
      return {kind = "interp", pipeline = pipe, body = {}, else_body = {},
        text = "", line = head.line}, ""
    end
    return nil, err_at(head, "unexpected '" .. head.value .. "' in action")
  end

  -- 1. Leading whitespace-only text is discarded; anything else there
  --    is an error, because the type declaration must be first.
  skip_blank_text()
  local otok, oerr = expect("open", "'{{type <Record> from <import.path>}}'")
  if not otok then
    return nil, oerr
  end
  local kwtok, _kwerr = expect("word", "'type'")
  if not kwtok or kwtok.value ~= "type" then
    return nil, err_at(kwtok, "a template must begin with {{type <Record> from" ..
      " <import.path>}}")
  end
  local nametok, nameerr = expect("word", "the record's type name")
  if not nametok then
    return nil, nameerr
  end
  if not nametok.value:match("^[%a_][%w_]*$") then
    return nil, err_at(nametok, "'" .. nametok.value .. "' is not a valid type name")
  end
  local fromtok, _fromerr = expect("word", "'from'")
  if not fromtok or fromtok.value ~= "from" then
    return nil, err_at(fromtok, "{{type " .. nametok.value .. "}} needs 'from" ..
      " <import.path>'")
  end
  local pathtok, patherr = expect("word", "the record's import path")
  if not pathtok then
    return nil, patherr
  end
  if not pathtok.value:match("^[%a_][%w_.]*$") then
    return nil, err_at(pathtok, "'" .. pathtok.value .. "' is not a valid import path")
  end
  local _, tclose = expect("close", "'}}'")
  if tclose ~= "" then
    return nil, tclose
  end

  -- 2. An optional {{mode html|text}} directly follows.
  local mode = "text"
  skip_blank_text()
  if peek() and peek().kind == "open" then
    local nxt = toks[pos + 1]
    if nxt and nxt.kind == "word" and nxt.value == "mode" then
      advance() -- "{{"
      advance() -- "mode"
      local mtok, merr = expect("word", "'html' or 'text'")
      if not mtok then
        return nil, merr
      end
      if mtok.value ~= "html" and mtok.value ~= "text" then
        return nil, err_at(mtok, "{{mode}} must be 'html' or 'text', got '" ..
          mtok.value .. "'")
      end
      mode = mtok.value
      local _, mclose = expect("close", "'}}'")
      if mclose ~= "" then
        return nil, mclose
      end
    end
  end

  -- 3. Everything else is the render body.
  local res, berr = parse_nodes({})
  if not res then
    return nil, berr
  end
  return {type_name = nametok.value, import_path = pathtok.value, mode = mode,
    body = res.nodes}, ""
end

--- Parse template source into a Template AST.
--- @param src string The template source
--- @param name string The template's name, for error messages
--- @return types.Template|nil The parsed template
--- @return string The error, with template line and column, on failure
local function parse(src: string, name: string): types.Template | nil, string
  local toks, lerr = lex.lex(src, name)
  if not toks then
    return nil, lerr
  end
  return parse_tokens(toks, name)
end

local record ParseModule
  parse: function(src: string, name: string): types.Template | nil, string
end

local M: ParseModule = {parse = parse}
return M
