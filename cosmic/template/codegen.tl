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
---     url_local string | html.SafeUrl             `html.local_href` (a same-origin reference), likewise
---     urlpart string | number | html.SafeUrlPart  `html.url_part`, after literal text in a URL
---     json  html.SafeJson                         entity-escaped JSON text, the whole value
---     url_trusted html.SafeResourceUrl            `<script src>`, `<link href>`: attribute-escaped, the whole value
---     selector string | number                    `html.escape_css_attr`: an identifier in a CSS selector
---     rtext string | number                       `<title>`, `<textarea>`: escaped, no markup
---     ftext string | number                       text in `<svg>`, `<math>`, `<select>`: likewise
---     plain string | number                       a `text` template: as it is
---
--- A `SafeHtml` is markup checked as plain HTML text, so only a `text`
--- slot takes one: inside `<svg>`, `<math>` or `<select>` the browser
--- reads markup by other rules.
---
--- A number is written with `tostring`: no digit, sign, point, exponent
--- or `inf`/`nan` is a byte HTML treats as markup. A union of one userdata
--- type and others is one Teal can tell apart (`v is string`); a union of
--- two userdata types is not, which is why a slot is never given
--- `SafeHtml | SafeAttr`.
---
--- A stage returns one value. Each stage's call is the argument of `_one`,
--- an identity of one parameter, so the checker refuses a stage declared to
--- return a fixed number of values above one, whether a slot, a condition
--- or another stage takes it. Teal reads a variadic result (`T...`) as one
--- argument, so a stage declared so passes the checker, and what holds it
--- to one value is `_one` dropping the rest at run time.
---
--- The record's module is required with `local type`, which loads nothing
--- at run time, unless a stage reads it too: so a declaration (`.d.tl`)
--- can export the record, and a module's body does not run for its types.
--- The module must return the record type itself, as a `.d.tl` or `local
--- record M ... end return M` does: one that returns a value of it is
--- refused at the `{{type}}`'s line, since `require` then returns no
--- type.
---
--- Line N of the template is line N of the module. The requires, the
--- helpers, `render`'s header and `local parts` share the `{{type}}`'s
--- line, after a blank line for each blank line before it, so an error
--- in them (a refused require, an unknown record type) names that line;
--- each line of literal text, and each action,
--- is written on its line, with the newlines of a multi-line action and
--- of trimmed whitespace kept as blank ones; the `return` is on the
--- template's last line. A template with `{{define}}`s is the record
--- `_Module`, declared in the head with `render` as its first function:
--- `render`'s `return` shares the first define's line, each define is
--- `function _Module.name` on its own lines with a `return` on its
--- `{{end}}`'s, and a stage `| name` calls `_Module.name`, which any
--- function of the record may, itself too, where a local function may
--- call only those made before it. A call reads the field when it runs;
--- the fields are not `mut`, so checked code cannot replace one. So a checker or run-time error names the
--- template's line. A column is the module's, not the template's: the
--- line is what the build maps back, and a column map is not worth its
--- cost until something reads columns.
---
--- The names the module declares are `render`, `parts`, `d` (the value
--- `render` or a define is given, which `$` names) and `d1`, `d2` and so on (dot in each
--- `range` and `with`, which a range's element variable names too, a
--- range's index variable, and the list of a `range` that has an `else`),
--- so a template's variable is never declared under its own name and can
--- shadow nothing; `v` (a slot's value, in a block of its own, and
--- `_one`'s parameter), `T` (`_one`'s type parameter), and the helpers
--- `_one`, `_text`, `_rtext`, `_ftext`, `_attr`, `_url`, `_lurl`, `_part`, `_json` and `_sel`; a module that
--- is required is named by the last word of its path, or that word, `_`
--- and a number when the name is taken, reserved, or a keyword, so a name
--- is never declared twice. A name a
--- loop or `with` does not read is written `_`, which is not a warning.
--- A range's index is `ipairs`'s, an integer from 1.

local types = require("cosmic.template.types")

--- The names generated code uses or that read as syntax, which a required
--- module is never named.
local RESERVED <const>: mut {string: boolean} = {}
for _, word in ipairs({
    "parts", "render", "d", "v", "T", "_", "_Module", "_module", "_one", "_sure", "_text", "_rtext", "_ftext", "_attr", "_url", "_lurl", "_part", "_json", "_sel", "record", "enum", "type", "global",
    "interface", "is", "as", "where", "self", "macroexp",
    -- The standard library and its globals, which a required module must
    -- not shadow (a module named `string` would break every `string.format`
    -- the template's own stages call), and the types Teal reads by name.
    "_G", "_ENV", "_VERSION", "arg", "assert", "bit32", "collectgarbage", "coroutine", "debug", "dofile",
    "error", "getmetatable", "io", "ipairs", "load", "loadfile", "loadstring", "math", "module", "must", "next", "os",
    "package", "pairs", "pcall", "print", "rawequal", "rawget", "rawlen", "rawset", "require", "select",
    "setmetatable", "string", "table", "tonumber", "tostring", "unpack", "utf8", "warn", "xpcall",
    "any", "boolean", "function", "integer", "number", "thread", "userdata",
}) do
  RESERVED[word] = true
end

--- The helpers, in the order they are declared.
local HELPER_ORDER <const>: {types.Slot} = { "plain", "text", "rtext", "ftext", "attr", "url", "url_local", "urlpart", "json", "selector", "url_trusted" }

--- A name the template takes, and whether the loop or `with` that made
--- it has read it.
local record Dot
  name: string
  mut used: boolean
end

--- The modules the generated source requires, in the order first needed,
--- each with the name it is given, and those whose value it reads. The
--- rest it requires as `local type`, which loads nothing at run time.
local record Imports
  order: mut {string}
  alias_of: mut {string: string}
  taken: mut {string: boolean}
  as_value: mut {string: boolean}
end

--- What generation carries: the text so far, the generated line it is
--- on, the modules and helpers needed, whether a stage needs `_one`, and
--- the name counter.
local record Gen
  pieces: mut {string}
  --- The pieces a header finished after its body replaces, by place in `pieces`.
  patched: mut {integer: string}
  mut line: integer
  mut started: boolean
  mode: types.Mode
  imports: Imports
  mut html: string
  helpers: mut {types.Slot: boolean}
  mut staged: boolean
  --- Whether an arm reads the value its condition tested, through `_sure`.
  mut tested: boolean
  mut dots: integer
  --- What `$` names.
  mut root: Dot
  --- The template's variables in scope, by name without the `$`.
  vars: mut {string: Dot}
  --- The local an `{{if}}` has bound a field path to, by the path as
  --- written in the source (`d.error`), while the arm it guards is written.
  bound: mut {string: Dot}
  --- The local each `{{define}}` is, by its name.
  defines: mut {string: string}
end

--- The declaration of the output's pieces, which each function of the
--- module starts with.
local PIECES <const> = "local parts: mut {string} = {}"

--- The start of a statement that adds to the output.
local APPEND <const> = "parts[#parts + 1] = "

--- Quotes `text` as a Teal string literal.
local function quote(text: string): string
  local escapes: {string: string} = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r",
    ["\t"] = "\\t" }
  return '"' .. text:gsub('[%c\\"]', function(c: string): string
    return escapes[c] or string.format("\\%03d", (assert(c:byte(), "the pattern matches one byte")))
  end) .. '"'
end

--- The name `module_path` is required as; required as a type unless
--- [`value_alias`] also asks for it.
local function alias_for(g: Gen, module_path: string): string
  local imports = g.imports
  local existing = imports.alias_of[module_path]
  if existing ~= nil then
    return existing
  end
  local base = module_path:match("[^.]+$") or module_path
  local alias = base
  local number = 1
  while RESERVED[alias] == true or types.keywords[alias] == true or imports.taken[alias] == true or alias:find("^d%d*$") ~= nil do
    number = number + 1
    alias = base .. "_" .. tostring(number)
  end
  imports.order[#imports.order + 1] = module_path
  imports.alias_of[module_path] = alias
  imports.taken[alias] = true
  return alias
end

--- The name `module_path` is required as, for its value.
local function value_alias(g: Gen, module_path: string): string
  g.imports.as_value[module_path] = true
  return alias_for(g, module_path)
end

--- `base` then the field `name`: `.name`, or `["name"]` for a keyword.
local function member(base: string, name: string): string
  if types.keywords[name] == true then
    return base .. '["' .. name .. '"]'
  end
  return base .. "." .. name
end

--- The expression for `pipe` at `dot`: its path of fields from its head,
--- each stage wrapped round what is before it and held to one value by
--- `_one`. A path an enclosing `{{if}}` tested is read from the local that
--- test bound, unless `raw` asks for the path itself: only a local is
--- narrowed, so the checker takes the guarded reads as the test's value.
local function value(g: Gen, pipe: types.Pipeline, dot: Dot, raw?: boolean): string
  local head = dot
  if pipe.head == "root" then
    head = g.root
  elseif pipe.head == "variable" then
    local variable = g.vars[pipe.name]
    if variable == nil then
      error("cosmic.template: codegen met $" .. pipe.name .. ", which the parser let through unbound")
    end
    head = variable
  end
  head.used = true
  -- The path as the source writes it, which `g.bound` is keyed by, beside
  -- the expression, in which a prefix an enclosing test bound is its local.
  local written = head.name
  local expr = head.name
  for _, field in ipairs(pipe.path) do
    written = member(written, field)
    expr = member(expr, field)
    local held = if raw ~= true then g.bound[written] else nil end
    if held ~= nil then
      held.used = true
      expr = held.name
    end
  end
  if raw == true then
    expr = written
  end
  for _, stage in ipairs(pipe.stages) do
    g.staged = true
    local func = if stage.module_path == "" then g.defines[stage.func] else
      member(value_alias(g, stage.module_path), stage.func) end
    if func == nil then
      error("cosmic.template: codegen met | " .. stage.func .. ", which the parser let through undefined")
    end
    local call: mut {string} = { expr }
    for _, given in ipairs(stage.args) do
      if given.kind == "string" then
        call[#call + 1] = quote(given.text)
      elseif given.kind == "number" then
        call[#call + 1] = given.text
      else
        call[#call + 1] = value(g, assert(given.path, "the parser gives a path argument its path"), dot)
      end
    end
    expr = "_one(" .. func .. "(" .. table.concat(call, ", ") .. "))"
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

--- Writes `code` as the next statement of the line, and returns where in
--- the pieces it went, for a header that is finished after its body.
local function put(g: Gen, code: string): integer
  g.pieces[#g.pieces + 1] = (if g.started then " " else "" end) .. code
  g.started = true
  return #g.pieces
end

--- The first arm of a range or with `node`, which the parser gives every
--- block.
local function first_branch(node: types.Node): types.Branch
  local arm = node.branches[1]
  if arm == nil then
    error("cosmic.template: codegen met a {{" .. node.kind .. "}} with no arm, which the parser let through")
  end
  return arm
end

--- Writes the node list `body`, whose dot is `dot`.
local emit: function(g: Gen, body: {types.Node}, dot: Dot)

--- The type a slot at `ctx` accepts, as source.
local function accepts(g: Gen, ctx: types.Slot): string
  if ctx == "url" or ctx == "url_local" then
    return "string | " .. g.html .. ".SafeUrl"
  elseif ctx == "json" then
    return g.html .. ".SafeJson"
  elseif ctx == "url_trusted" then
    return g.html .. ".SafeResourceUrl"
  elseif ctx == "urlpart" then
    return "string | number | " .. g.html .. ".SafeUrlPart"
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
  elseif ctx == "url_local" then
    helper_name = "_lurl"
  elseif ctx == "json" then
    helper_name = "_json"
  elseif ctx == "selector" then
    helper_name = "_sel"
  elseif ctx == "url_trusted" then
    helper_name = "_turl"
  elseif ctx == "urlpart" then
    helper_name = "_part"
  elseif ctx == "attr" then
    helper_name = "_attr"
  elseif ctx == "rtext" then
    helper_name = "_rtext"
  elseif ctx == "ftext" then
    helper_name = "_ftext"
  end
  return "do local v: " .. accepts(g, ctx) .. " = " .. expr .. " " .. APPEND .. helper_name .. "(v) end"
end

--- A fresh name for dot.
local function new_dot(g: Gen): Dot
  g.dots = g.dots + 1
  return { name = "d" .. tostring(g.dots), used = false }
end

--- The condition that `expr` holds in a template: it is not nil, not false and not empty (`""`, or a table with no
--- key), as [`html.filled`] says.
local function filled(g: Gen, expr: string): string
  return value_alias(g, "cosmic.html") .. ".filled(" .. expr .. ")"
end

--- Writes an `if` or a `with`, or a `range`.
local function block(g: Gen, node: types.Node, dot: Dot) -- checked: not_assigned
  to_line(g, node.line)
  if node.kind == "range" then
    -- While its body runs, a range holds five of the function's locals (the
    -- loop's three hidden ones, the index or `_`, and dot), six with an
    -- `else`, and Lua allows a function 200: a module whose ranges nest
    -- about 40 deep (33 with an `else`) does not load, Lua naming the
    -- template's line ("too many local variables"). That stays: no template
    -- nests so deep, and a function per body, which would lift the limit,
    -- costs a closure each time a range runs. A `with`, and an `if` arm
    -- that reads the path it tests, hold two (the value and its `_sure`).
    local arm = first_branch(node)
    local other = node.branches[2]
    local inner = new_dot(g)
    local index: Dot = { name = "_", used = false }
    if arm.index ~= "" then
      index = new_dot(g)
    end
    -- The list is read where the range stands, before its variables are.
    local source = value(g, assert(arm.pipeline), dot)
    if arm.index ~= "" then
      g.vars[arm.index] = index
    end
    if arm.element ~= "" then
      g.vars[arm.element] = inner
    end
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
    g.vars[arm.index] = nil
    g.vars[arm.element] = nil
    local held = assert(g.pieces[head], "put made the piece at this place")
    g.patched[head] = held .. opening .. "for " .. (if index.used then index.name else "_" end) .. ", " ..
      (if inner.used then inner.name else "_" end) .. " in ipairs(" .. source .. ") do"
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
    local arm = first_branch(node)
    -- The value is read once, tested, and then read in the arm as a local of the type it has where it holds: what
    -- `filled` holds of is never nil.
    local held = new_dot(g).name
    local inner = new_dot(g)
    put(g, "do local " .. held .. " = " .. value(g, assert(arm.pipeline), dot) .. " if " .. filled(g, held) .. " then")
    local sure = put(g, "")
    emit(g, arm.body, inner)
    if inner.used then
      g.tested = true
      g.patched[sure] = assert(g.pieces[sure], "put made the piece") .. "local " .. inner.name .. " = _sure(" .. held .. ")"
    end
    local other = node.branches[2]
    if other ~= nil then
      to_line(g, other.line)
      put(g, "else")
      emit(g, other.body, dot)
    end
    to_line(g, node.close_line)
    put(g, "end end")
  else
    -- A field path an arm tests is bound to a local before it is tested:
    -- the test narrows the local, and the arm reads it.
    local function bindable(pipeline: types.Pipeline?): string?
      if pipeline == nil or #pipeline.stages > 0 or #pipeline.path == 0 then
        return nil
      end
      local written = value(g, pipeline, dot, true)
      return if g.bound[written] == nil then written else nil end
    end
    local any = false
    for _, arm in ipairs(node.branches) do
      any = any or bindable(arm.pipeline) ~= nil
    end
    -- A chain with a bound arm is flat, one `do` block to an arm in a
    -- `repeat` that each arm leaves by `break`, so that its depth does not
    -- grow with the arms (the checker nests by block) and a path is read
    -- only when the arms before it have failed.
    local flat = any and #node.branches > 1
    local closing = ""
    for at, arm in ipairs(node.branches) do
      to_line(g, arm.line)
      local pipeline = arm.pipeline
      local written = if pipeline ~= nil then bindable(pipeline) else nil end
      local bound: Dot? = nil
      local sure = 0
      local sure_of = ""
      local lead = if at == 1 and flat then "repeat " else "" end
      if pipeline == nil then
        put(g, if flat then closing else "else" end)
        closing = if flat then "" else "end" end
      else
        local tested = value(g, pipeline, dot)
        if written ~= nil then
          local held = new_dot(g).name
          bound = new_dot(g)
          put(g, closing .. (if closing ~= "" then " " else "" end) .. lead .. "do local " .. held .. " = " .. tested ..
              " if " .. filled(g, held) .. " then")
          sure = put(g, "")
          sure_of = held
          g.bound[written] = bound
          closing = if flat then "break end end" else "end end" end
        elseif flat then
          put(g, closing .. (if closing ~= "" then " " else "" end) .. lead .. "if " .. filled(g, tested) .. " then")
          closing = "break end"
        else
          put(g, (if at == 1 then "if " else "elseif " end) .. filled(g, tested) .. " then")
          closing = "end"
        end
      end
      emit(g, arm.body, dot)
      if written ~= nil then
        g.bound[written] = nil
        local b = assert(bound, "a bound arm made its local")
        if b.used then
          g.tested = true
          g.patched[sure] = assert(g.pieces[sure], "put made the piece") .. "local " .. b.name .. " = _sure(" ..
            sure_of .. ")"
        end
      end
    end
    to_line(g, node.close_line)
    if flat then
      put(g, closing .. (if closing ~= "" then " " else "" end) .. "until true")
    else
      put(g, closing)
    end
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
      put(g, slot_statement(g, node.ctx, value(g, assert(node.pipeline), dot)))
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
  elseif ctx == "rtext" or ctx == "ftext" then
    return "local function _" .. ctx .. "(v: string | number): string " ..
      "if v is number then return tostring(v) end return " .. html .. ".raw(" .. html .. ".escape(v)) end"
  elseif ctx == "attr" then
    return "local function _attr(v: string | number | " .. html .. ".SafeAttr): string " ..
      "if v is string then return " .. html .. ".raw_attr(" .. html .. ".escape_attr(v)) end " ..
      "if v is number then return tostring(v) end return " .. html .. ".raw_attr(v) end"
  elseif ctx == "urlpart" then
    return "local function _part(v: string | number | " .. html .. ".SafeUrlPart): string " ..
      "local p: " .. html .. ".SafeUrlPart if v is string then p = " .. html .. ".url_part(v) " ..
      "elseif v is number then p = " .. html .. ".url_part(v) else p = v end " ..
      "return " .. html .. ".raw(" .. html .. ".escape(" .. html .. ".raw_url_part(p))) end"
  elseif ctx == "url_local" then
    return "local function _lurl(v: string | " .. html .. ".SafeUrl): string " ..
      "if v is string then return " .. html .. ".raw_attr(" .. html .. ".escape_attr(" .. html ..
      ".raw_url(" .. html .. ".local_href(v)))) end return " .. html .. ".raw_attr(" .. html .. ".escape_attr(" ..
      html .. ".raw_url(v))) end"
  elseif ctx == "json" then
    return "local function _json(v: " .. html .. ".SafeJson): string " ..
      "return " .. html .. ".raw(" .. html .. ".escape(" .. html .. ".raw_json(v))) end"
  elseif ctx == "url_trusted" then
    return "local function _turl(v: " .. html .. ".SafeResourceUrl): string " ..
      "return " .. html .. ".raw_attr(" .. html .. ".escape_attr(" .. html .. ".raw_resource_url(v))) end"
  elseif ctx == "selector" then
    return "local function _sel(v: string | number): string " ..
      "return " .. html .. ".raw_attr(" .. html .. ".escape_css_attr(v)) end"
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
--- The source is in the new checker's grammar, which holds a project to what no
--- ceiling excuses: `parts` is a `mut {string}`, and the module returns a local declared with its record type, not a table
--- literal that no declaration describes.
--- @return string Source that has as many lines as the template
function Codegen.generate(template: types.Template): string
  local g: Gen = { pieces = {}, patched = {}, line = template.line, started = false, mode = template.mode,
    imports = { order = {}, alias_of = {}, taken = {}, as_value = {} }, html = "", helpers = {}, staged = false,
    tested = false, dots = 0, root = { name = "d", used = false }, vars = {}, bound = {}, defines = {} }
  -- A template with defines is a record of functions, declared first,
  -- which each function may call, itself too: a local function may call
  -- only those made before it.
  for _, define in ipairs(template.defines) do
    g.defines[define.name] = "_Module." .. define.name
  end
  local type_alias = alias_for(g, template.import_path)
  if template.mode == "html" then
    g.html = value_alias(g, "cosmic.html")
  end
  local result = if template.mode == "html" then g.html .. ".SafeHtml" else "string" end
  local finish = "return " .. (if template.mode == "html" then g.html .. ".trust(table.concat(parts))" else
    "table.concat(parts)" end) .. " end"
  emit(g, template.body, g.root)
  local main_used = g.root.used
  -- Each define is a function of its own, on its lines, after render's
  -- `return`, which shares the first define's line.
  for at, define in ipairs(template.defines) do
    to_line(g, define.line)
    if at == 1 then
      put(g, finish)
    end
    local root: Dot = { name = "d", used = false }
    g.root = root
    local header = put(g, "")
    emit(g, define.body, root)
    g.patched[header] = assert(g.pieces[header], "put made the piece at this place") ..
      "function _Module." .. define.name .. "(" .. (if root.used then "d" else "_" end) .. ": " .. type_alias .. "." ..
      define.type_name .. "): " .. result .. " " .. PIECES
    to_line(g, define.end_line)
    put(g, finish)
  end

  local head: mut {string} = {}
  for _, path in ipairs(g.imports.order) do
    local alias = assert(g.imports.alias_of[path], "alias_for names every path it orders")
    head[#head + 1] = (if g.imports.as_value[path] == true then "local " else "local type " end) .. alias ..
      " = require(\"" .. path .. "\")"
  end
  if g.staged then
    head[#head + 1] = "local function _one<T>(v: T): T return v end"
  end
  if g.tested then
    head[#head + 1] = "local function _sure<T>(v: T?): T return (assert(v)) end"
  end
  for _, ctx in ipairs(HELPER_ORDER) do
    if g.helpers[ctx] == true then
      head[#head + 1] = helper(g, ctx)
    end
  end
  local signature = "(" .. (if main_used then "d" else "_" end) .. ": " .. type_alias .. "." .. template.type_name ..
    "): " .. result
  local ending = ""
  if #template.defines == 0 then
    head[#head + 1] = "local function render" .. signature
    -- The module's value is a local of a record type that declares `render`, which is what a requirer reads its type from.
    ending = finish .. " local record _Module render: function(d: " .. type_alias .. "." .. template.type_name ..
      "): " .. result .. " end local _module: _Module = {render = render} return _module"
  else
    head[#head + 1] = "local record _Module end function _Module.render" .. signature
    ending = "return _Module"
  end
  head[#head + 1] = PIECES

  to_line(g, template.lines)
  put(g, ending)
  local body: mut {string} = {}
  for i, piece in ipairs(g.pieces) do
    body[#body + 1] = g.patched[i] or piece
  end
  return string.rep("\n", template.line - 1) .. table.concat(head, " ") .. " " ..
    table.concat(body) .. "\n"
end

--- Teal source for `template`, a template given to [`Template.text`] ([`Parse.inline`]): a function literal of one
--- parameter, dot, which the checker takes the type of from where it stands, returning the text. Its requires and
--- helpers are locals of its body, and line N of the template is line N of the source, as in [`Codegen.generate`].
--- @param template types.Template The tree of a `text` template with no header and no `{{define}}`
--- @return string A function literal, `function(d): string ... end`
function Codegen.inline(template: types.Template): string
  local g: Gen = { pieces = {}, patched = {}, line = 1, started = false, mode = "text",
    imports = { order = {}, alias_of = {}, taken = {}, as_value = {} }, html = "", helpers = {}, staged = false,
    tested = false, dots = 0, root = { name = "d", used = false }, vars = {}, bound = {}, defines = {} }
  emit(g, template.body, g.root)
  to_line(g, template.lines)
  put(g, "return table.concat(parts) end")
  local head: mut {string} = { "function(" .. (if g.root.used then "d" else "_" end) .. "): string" }
  for _, path in ipairs(g.imports.order) do
    local alias = assert(g.imports.alias_of[path], "alias_for names every path it orders")
    head[#head + 1] = "local " .. alias .. " = require(\"" .. path .. "\")"
  end
  if g.staged then
    head[#head + 1] = "local function _one<T>(v: T): T return v end"
  end
  if g.tested then
    head[#head + 1] = "local function _sure<T>(v: T?): T return (assert(v)) end"
  end
  for _, ctx in ipairs(HELPER_ORDER) do
    if g.helpers[ctx] == true then
      head[#head + 1] = helper(g, ctx)
    end
  end
  head[#head + 1] = PIECES
  local body: mut {string} = {}
  for i, piece in ipairs(g.pieces) do
    body[#body + 1] = g.patched[i] or piece
  end
  return table.concat(head, " ") .. " " .. table.concat(body)
end

return Codegen
