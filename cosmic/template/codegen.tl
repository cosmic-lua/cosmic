--- Writes Teal source for a parsed, annotated [`Types.Template`]. Private
--- to [`cosmic.template`].
---
--- Every guarantee a template makes is the type checker's, about what
--- this writes: a template has no run-time engine. A slot's value is bound
--- to a local declared as the union of what the slot's place accepts, so
--- what the checker refuses there is what the place refuses, and then goes
--- through a small function the module declares first, which tells the
--- members of the union apart:
---
---     text  string | number | html.SafeHtml       escaped, or taken as it is
---     attr  string | number | html.SafeAttr       likewise, for an attribute
---     url   string | html.SafeUrl                 `html.href`, then attribute-escaped
---     rtext string | number                       `<title>`, `<textarea>`: escaped, no markup
---     plain string | number                       a `text` template: as it is
---
--- A number is written with `tostring`: no digit, sign, point, exponent
--- or `inf`/`nan` is a byte HTML treats as markup. A union of one userdata
--- type and others is one Teal can tell apart (`v is string`); a union of
--- two userdata types is not, which is why a slot is never given
--- `SafeHtml | SafeAttr`.
---
--- Line N of the template is line N of the module. The requires, the
--- helpers, `render`'s header and `local parts` share line 1 with the
--- template's first line; each line of literal text, and each action,
--- is written on its line, with the newlines of a multi-line action and
--- of trimmed whitespace kept as blank ones; the `return` is on the
--- template's last line. So a checker or run-time error names the
--- template's line. A column is the module's, not the template's: the
--- line is what the build maps back, and a column map is not worth its
--- cost until something reads columns.
---
--- The names the module declares are `render`, `parts`, `d` and `d1`, `d2`
--- and so on (dot in each `range` and `with`, and the list of a `range`
--- that has an `else`), `v` (a slot's value, in a
--- block of its own), and the helpers
--- `_text`, `_attr` and `_url`; a module that is required is named by the last
--- word of its path, or that word, `_` and a number when the name is taken,
--- reserved, or a keyword, so a name is never declared twice. A name a
--- loop or `with` does not read is written `_`, which is not a warning.

local types = require("cosmic.template.types")

--- The names generated code uses or that read as syntax, which a required
--- module is never named.
local RESERVED <const>: {string: boolean} = {}
for _, word in ipairs({
    "parts", "render", "d", "v", "_", "_text", "_rtext", "_attr", "_url", "record", "enum", "type", "global",
    "interface", "is", "as", "where", "self", "macroexp",
    -- The standard library and its globals, which a required module must
    -- not shadow (a module named `string` would break every `string.format`
    -- the template's own stages call), and the types Teal reads by name.
    "_G", "_ENV", "_VERSION", "arg", "assert", "bit32", "collectgarbage", "coroutine", "debug", "dofile",
    "error", "getmetatable", "io", "ipairs", "load", "loadfile", "loadstring", "math", "module", "next", "os",
    "package", "pairs", "pcall", "print", "rawequal", "rawget", "rawlen", "rawset", "require", "select",
    "setmetatable", "string", "table", "tonumber", "tostring", "unpack", "utf8", "warn", "xpcall",
    "any", "boolean", "function", "integer", "number", "thread", "userdata",
}) do
  RESERVED[word] = true
end

--- The helpers, in the order they are declared.
local HELPER_ORDER <const>: {types.Slot} = { "plain", "text", "rtext", "attr", "url" }

--- A name the template takes, and whether the loop or `with` that made
--- it has read it.
local record Dot
  name: string
  used: boolean
end

--- The modules the generated source requires, in the order first needed,
--- each with the name it is given.
local record Imports
  order: {string}
  alias_of: {string: string}
  taken: {string: boolean}
end

--- What generation carries: the text so far, the generated line it is
--- on, the modules and helpers needed, and the name counter.
local record Gen
  pieces: {string}
  line: integer
  started: boolean
  mode: types.Mode
  imports: Imports
  html: string
  helpers: {types.Slot: boolean}
  dots: integer
end

--- The start of a statement that adds to the output.
local APPEND <const> = "parts[#parts + 1] = "

--- Quotes `text` as a Teal string literal.
local function quote(text: string): string
  local escapes: {string: string} = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r",
    ["\t"] = "\\t" }
  return '"' .. text:gsub('[%c\\"]', function(c: string): string
    return escapes[c] or string.format("\\%03d", c:byte())
  end) .. '"'
end

--- The name `module_path` is required as.
local function alias_for(g: Gen, module_path: string): string
  local imports = g.imports
  local existing = imports.alias_of[module_path]
  if existing ~= nil then
    return existing
  end
  local base = module_path:match("[^.]+$") or module_path
  local alias = base
  local number = 1
  while RESERVED[alias] or types.keywords[alias] or imports.taken[alias] or alias:find("^d%d*$") do
    number = number + 1
    alias = base .. "_" .. number
  end
  imports.order[#imports.order + 1] = module_path
  imports.alias_of[module_path] = alias
  imports.taken[alias] = true
  return alias
end

--- `base` then the field `name`: `.name`, or `["name"]` for a keyword.
local function member(base: string, name: string): string
  if types.keywords[name] then
    return base .. '["' .. name .. '"]'
  end
  return base .. "." .. name
end

--- The expression for `pipe` at `dot`: its path of fields, each stage
--- wrapped round what is before it.
local function value(g: Gen, pipe: types.Pipeline, dot: Dot): string
  dot.used = true
  local expr = dot.name
  for _, field in ipairs(pipe.path) do
    expr = member(expr, field)
  end
  for _, stage in ipairs(pipe.stages) do
    expr = member(alias_for(g, stage.module_path), stage.func) .. "(" .. expr .. ")"
  end
  return expr
end

--- Moves to template line `line`, writing the newlines between.
local function to_line(g: Gen, line: integer)
  while g.line < line do
    g.pieces[#g.pieces + 1] = "\n"
    g.line = g.line + 1
    g.started = false
  end
end

--- Writes `code` as the next statement of the line, and answers where in
--- the pieces it went, for a header that is finished after its body.
local function put(g: Gen, code: string): integer
  g.pieces[#g.pieces + 1] = (g.started and " " or "") .. code
  g.started = true
  return #g.pieces
end

--- Writes the node list `body`, whose dot is `dot`.
local emit: function(g: Gen, body: {types.Node}, dot: Dot)

--- The type a slot at `ctx` accepts, as source.
local function accepts(g: Gen, ctx: types.Slot): string
  if ctx == "url" then
    return "string | " .. g.html .. ".SafeUrl"
  elseif ctx == "attr" then
    return "string | number | " .. g.html .. ".SafeAttr"
  elseif ctx == "text" then
    return "string | number | " .. g.html .. ".SafeHtml"
  end
  return "string | number"
end

--- The statement that puts `expr` into the output at a slot. The value
--- is first bound to a local of the type the slot accepts: a mismatch is
--- then reported at the slot, in a message that spells the type, where an
--- argument of the helper alone would be reported, the first time its type
--- is met, where the field was declared, in another file.
local function slot_statement(g: Gen, ctx: types.Slot, expr: string): string
  g.helpers[ctx] = true
  local helper_name = "_text"
  if ctx == "url" then
    helper_name = "_url"
  elseif ctx == "attr" then
    helper_name = "_attr"
  elseif ctx == "rtext" then
    helper_name = "_rtext"
  end
  return "do local v: " .. accepts(g, ctx) .. " = " .. expr .. " " .. APPEND .. helper_name .. "(v) end"
end

--- A fresh name for dot.
local function new_dot(g: Gen): Dot
  g.dots = g.dots + 1
  return { name = "d" .. g.dots, used = false }
end

--- Writes an `if` or a `with`, or a `range`.
local function block(g: Gen, node: types.Node, dot: Dot)
  to_line(g, node.line)
  if node.kind == "range" then
    -- While its body runs, a range holds five of the function's locals (the
    -- loop's three hidden ones, `_` and dot), six with an `else`, and Lua
    -- allows a function 200: a module whose ranges nest about 40 deep (33
    -- with an `else`) does not load, Lua naming the template's line ("too
    -- many local variables"). That stays: no template nests so deep, and a
    -- function per body, which would lift the limit, costs a closure each
    -- time a range runs.
    local arm = node.branches[1]
    local other = node.branches[2]
    local inner = new_dot(g)
    local source = value(g, arm.pipeline, dot)
    local opening = ""
    if other ~= nil then
      -- The list is read once, then tested for a first element: ipairs
      -- makes no step exactly when there is none.
      local list = new_dot(g).name
      opening = "do local " .. list .. " = " .. source .. " if " .. list .. "[1] ~= nil then "
      source = list
    end
    local head = put(g, "")
    emit(g, arm.body, inner)
    g.pieces[head] = g.pieces[head] .. opening .. "for _, " .. (inner.used and inner.name or "_") ..
      " in ipairs(" .. source .. ") do"
    if other ~= nil then
      to_line(g, other.line)
      put(g, "end else")
      emit(g, other.body, dot)
      to_line(g, node.close_line)
      put(g, "end end")
    else
      to_line(g, node.close_line)
      put(g, "end")
    end
  elseif node.kind == "with" then
    local arm = node.branches[1]
    local inner = new_dot(g)
    put(g, "do local " .. inner.name .. " = " .. value(g, arm.pipeline, dot) .. " if " .. inner.name ..
        " then")
    emit(g, arm.body, inner)
    local other = node.branches[2]
    if other ~= nil then
      to_line(g, other.line)
      put(g, "else")
      emit(g, other.body, dot)
    end
    to_line(g, node.close_line)
    put(g, "end end")
  else
    for at, arm in ipairs(node.branches) do
      to_line(g, arm.line)
      if arm.pipeline == nil then
        put(g, "else")
      else
        put(g, (at == 1 and "if " or "elseif ") .. value(g, arm.pipeline, dot) .. " then")
      end
      emit(g, arm.body, dot)
    end
    to_line(g, node.close_line)
    put(g, "end")
  end
end

emit = function(g: Gen, body: {types.Node}, dot: Dot)
  for _, node in ipairs(body) do
    if node.kind == "text" then
      local line = node.line
      for segment in node.text:gmatch("[^\n]*\n?") do
        if segment ~= "" then
          to_line(g, line)
          put(g, APPEND .. quote(segment))
          line = line + 1
        end
      end
    elseif node.kind == "interp" then
      to_line(g, node.line)
      put(g, slot_statement(g, node.ctx, value(g, node.pipeline, dot)))
    else
      block(g, node, dot)
    end
  end
end

--- The helper `ctx` names, as source.
local function helper(g: Gen, ctx: types.Slot): string
  local html = g.html
  if ctx == "plain" then
    return "local function _text(v: string | number): string if v is number then return tostring(v) end " ..
      "return v end"
  elseif ctx == "text" then
    return "local function _text(v: string | number | " .. html .. ".SafeHtml): string " ..
      "if v is string then return " .. html .. ".raw(" .. html .. ".escape(v)) end " ..
      "if v is number then return tostring(v) end return " .. html .. ".raw(v) end"
  elseif ctx == "rtext" then
    return "local function _rtext(v: string | number): string " ..
      "if v is number then return tostring(v) end return " .. html .. ".raw(" .. html .. ".escape(v)) end"
  elseif ctx == "attr" then
    return "local function _attr(v: string | number | " .. html .. ".SafeAttr): string " ..
      "if v is string then return " .. html .. ".raw_attr(" .. html .. ".escape_attr(v)) end " ..
      "if v is number then return tostring(v) end return " .. html .. ".raw_attr(v) end"
  end
  return "local function _url(v: string | " .. html .. ".SafeUrl): string " ..
    "if v is string then return " .. html .. ".raw_attr(" .. html .. ".escape_attr(" .. html ..
    ".raw_url(" .. html .. ".href(v)))) end return " .. html .. ".raw_attr(" .. html .. ".escape_attr(" ..
    html .. ".raw_url(v))) end"
end

local record Codegen
end

--- Teal source for `template`.
--- @param template types.Template The tree, its slots' places set
--- @return string Source that has as many lines as the template
function Codegen.generate(template: types.Template): string
  local g: Gen = { pieces = {}, line = 1, started = false, mode = template.mode,
    imports = { order = {}, alias_of = {}, taken = {} }, html = "", helpers = {}, dots = 0 }
  local type_alias = alias_for(g, template.import_path)
  if template.mode == "html" then
    g.html = alias_for(g, "cosmic.html")
  end
  local root: Dot = { name = "d", used = false }
  emit(g, template.body, root)

  local head: {string} = {}
  for _, path in ipairs(g.imports.order) do
    head[#head + 1] = "local " .. g.imports.alias_of[path] .. " = require(\"" .. path .. "\")"
  end
  for _, ctx in ipairs(HELPER_ORDER) do
    if g.helpers[ctx] then
      head[#head + 1] = helper(g, ctx)
    end
  end
  local result = template.mode == "html" and g.html .. ".SafeHtml" or "string"
  head[#head + 1] = "local function render(" .. (root.used and "d" or "_") .. ": " .. type_alias .. "." ..
    template.type_name .. "): " .. result
  head[#head + 1] = "local parts: {string} = {}"

  to_line(g, template.lines)
  put(g, "return " .. (template.mode == "html" and g.html .. ".trust(table.concat(parts))" or
    "table.concat(parts)") .. " end return {render = render}")
  return table.concat(head, " ") .. " " .. table.concat(g.pieces) .. "\n"
end

return Codegen
