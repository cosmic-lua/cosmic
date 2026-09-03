--- Turns a parsed `types.Template` into Teal module source. Internal
--- to `cosmic.template` — see `cosmic/template/types.tl` for the AST
--- and why this directory is not the published API.
---
--- Every guarantee this feature makes is a guarantee about the OUTPUT:
--- there is no runtime here, so what this emits is what
--- `cosmic --check types` checks. In `mode html`, every interpolation
--- is typed by its context — `html.SafeHtml` by default, or whichever
--- of `html.SafeAttr`/`url.SafeUrl`/`js.SafeJs`/`css.SafeCss` the
--- template named at that slot (`CTX_TARGET` below) — so a raw
--- `string`, or the WRONG context's safe type, reaching that slot is a
--- compile error at the template line that produced it, never silent
--- output. This module does not know what makes an escaper correct;
--- it only emits the annotation that makes the Teal checker enforce
--- the match.

local types = require("cosmic.template.types")

--- Quote a template's literal text as a Teal string literal. Escapes
--- backslash, the double quote, and the four control characters a
--- template is likely to actually contain — not a general Lua
--- literal-quoting routine, just enough for text a human wrote.
--- @param text string The literal text
--- @return string A double-quoted Teal string literal
local function quote(text: string): string
  local out = text:gsub("\\", "\\\\")
  out = out:gsub('"', '\\"')
  out = out:gsub("\n", "\\n")
  out = out:gsub("\t", "\\t")
  out = out:gsub("\r", "\\r")
  return '"' .. out .. '"'
end

--- Tracks the `require`d modules a generated module needs, in
--- first-use order, with a collision-free local alias for each.
local record Imports
  order: {string}
  alias_of: {string: string}
  used: {string: boolean}
end

--- The alias a module path gets: its last dotted segment, or that
--- segment with a numeric suffix if a different module already
--- claimed it (e.g. two modules both named `*.html` on one pipeline).
--- @param imports Imports The import table to register into
--- @param module_path string The module to require
--- @return string The local variable name bound to require(module_path)
local function alias_for(imports: Imports, module_path: string): string
  local existing = imports.alias_of[module_path]
  if existing then
    return existing
  end
  local base = module_path:match("[^.]+$") or module_path
  local alias = base
  local suffix = 2
  while imports.used[alias] do
    alias = base .. tostring(suffix)
    suffix = suffix + 1
  end
  imports.order[#imports.order + 1] = module_path
  imports.alias_of[module_path] = alias
  imports.used[alias] = true
  return alias
end

--- The Teal expression for a pipeline, evaluated against `dot_var`:
--- the field path off dot, then each stage's function call wrapped
--- around the previous expression, left to right.
--- @param imports Imports The import table (stages register into it)
--- @param pipe types.Pipeline The pipeline to emit
--- @param dot_var string The Teal variable name holding the current dot
--- @return string The generated expression
local function pipeline_expr(imports: Imports, pipe: types.Pipeline,
    dot_var: string): string
  local expr = dot_var
  for _, seg in ipairs(pipe.path) do
    expr = expr .. "." .. seg
  end
  for _, stage in ipairs(pipe.stages) do
    local alias = alias_for(imports, stage.module_path)
    expr = alias .. "." .. stage.func_name .. "(" .. expr .. ")"
  end
  return expr
end

--- Everything a node's subtree needs that does not change as it
--- recurses, bundled so emitting a deeply nested `{{range}}` does not
--- carry a growing positional argument list.
local record Ctx
  imports: Imports
  mode: string
  name: string
  html_alias: string
  next_var: function(): string
  next_dot: function(): string
end

--- Where an interpolation's `Safe*` type comes from: the module to
--- `require` and the type name within it.
local record CtxTarget
  module_path: string
  type_name: string
end

--- One entry per word `CTX_WORDS` (`cosmic.template.parse`) accepts —
--- the other half of that table. "attr" is the one context that
--- shares `html`'s module: `SafeAttr` lives in `cosmic.html` beside
--- `SafeHtml`, so the two never cost a second `require`.
local CTX_TARGET < const >: {string: CtxTarget} = {
  html = {module_path = "cosmic.html", type_name = "SafeHtml"},
  attr = {module_path = "cosmic.html", type_name = "SafeAttr"},
  url = {module_path = "cosmic.url", type_name = "SafeUrl"},
  js = {module_path = "cosmic.js", type_name = "SafeJs"},
  css = {module_path = "cosmic.css", type_name = "SafeCss"},
}

--- Appends the Teal statements for one node's subtree to `out`, in
--- order. `dot_var` names the Teal local currently bound to the
--- template's "dot" value; `range` and `with` open a new one, from
--- `ctx.next_dot()`, rather than reusing `dot_var` — the generated
--- code never shadows a local, which `--check types` treats as a
--- warning and this project's build treats as an error.
--- @param out {string} The output line buffer, appended in place
--- @param ctx Ctx The codegen context (imports, mode, var allocators)
--- @param node types.Node The node to emit
--- @param dot_var string The Teal variable holding the current dot
--- @param indent string The current indentation
local function emit_node(out: {string}, ctx: Ctx, node: types.Node,
    dot_var: string, indent: string)
  if node.kind == "text" then
    if node.text ~= "" then
      out[#out + 1] = indent .. "parts[#parts + 1] = " .. quote(node.text)
    end
  elseif node.kind == "interp" then
    out[#out + 1] = indent .. "-- " .. ctx.name .. ":" .. tostring(node.line)
    local expr = pipeline_expr(ctx.imports, node.pipeline, dot_var)
    local v = ctx.next_var()
    if ctx.mode == "html" then
      local target = CTX_TARGET[node.ctx]
      local alias = alias_for(ctx.imports, target.module_path)
      out[#out + 1] = indent .. "local " .. v .. ": " .. alias .. "." ..
      target.type_name .. " = " .. expr
      out[#out + 1] = indent .. "parts[#parts + 1] = " .. v .. ".raw"
    else
      out[#out + 1] = indent .. "local " .. v .. ": string = " .. expr
      out[#out + 1] = indent .. "parts[#parts + 1] = " .. v
    end
  elseif node.kind == "if" then
    local expr = pipeline_expr(ctx.imports, node.pipeline, dot_var)
    out[#out + 1] = indent .. "if " .. expr .. " then"
    for _, child in ipairs(node.body) do
      emit_node(out, ctx, child, dot_var, indent .. "  ")
    end
    if #node.else_body > 0 then
      out[#out + 1] = indent .. "else"
      for _, child in ipairs(node.else_body) do
        emit_node(out, ctx, child, dot_var, indent .. "  ")
      end
    end
    out[#out + 1] = indent .. "end"
  elseif node.kind == "range" then
    local expr = pipeline_expr(ctx.imports, node.pipeline, dot_var)
    local inner = ctx.next_dot()
    out[#out + 1] = indent .. "for _, " .. inner .. " in ipairs(" .. expr ..
    ") do"
    for _, child in ipairs(node.body) do
      emit_node(out, ctx, child, inner, indent .. "  ")
    end
    out[#out + 1] = indent .. "end"
  elseif node.kind == "with" then
    local expr = pipeline_expr(ctx.imports, node.pipeline, dot_var)
    local inner = ctx.next_dot()
    out[#out + 1] = indent .. "do"
    out[#out + 1] = indent .. "  local " .. inner .. " = " .. expr
    for _, child in ipairs(node.body) do
      emit_node(out, ctx, child, inner, indent .. "  ")
    end
    out[#out + 1] = indent .. "end"
  end
end

--- Generate Teal module source from a parsed template.
---
--- The generated module requires the record's declared import path
--- (aliased to its last dotted segment) plus `cosmic.html` in mode
--- html, and exports one function: `render(d: <alias>.<TypeName>):
--- html.SafeHtml` in mode html, `render(d: <alias>.<TypeName>): string`
--- in mode text. Never fails: a `types.Template` is already a valid
--- AST by construction (`parse.parse` is the fallible boundary).
--- @param template types.Template The parsed template
--- @param name string The template's name, for source-line comments
--- @return string The generated Teal module source
local function generate(template: types.Template, name: string): string
  local imports: Imports = {order = {}, alias_of = {}, used = {}}
  local type_alias = alias_for(imports, template.import_path)
  local html_alias = ""
  if template.mode == "html" then
    html_alias = alias_for(imports, "cosmic.html")
  end

  local var_n = 0
  local function next_var(): string
    var_n = var_n + 1
    return "v" .. tostring(var_n)
  end
  local dot_n = 0
  local function next_dot(): string
    dot_n = dot_n + 1
    return "d" .. tostring(dot_n)
  end

  local ctx: Ctx = {imports = imports, mode = template.mode, name = name,
    html_alias = html_alias, next_var = next_var, next_dot = next_dot}
  local body_lines: {string} = {}
  for _, node in ipairs(template.body) do
    emit_node(body_lines, ctx, node, "d", "  ")
  end

  local out: {string} = {}
  for _, path in ipairs(imports.order) do
    out[#out + 1] = "local " .. imports.alias_of[path] .. " = require(\"" ..
    path .. "\")"
  end
  out[#out + 1] = ""
  local ret_type = template.mode == "html" and (html_alias .. ".SafeHtml")
  or "string"
  out[#out + 1] = "local function render(d: " .. type_alias .. "." ..
  template.type_name .. "): " .. ret_type
  out[#out + 1] = "  local parts: {string} = {}"
  for _, line in ipairs(body_lines) do
    out[#out + 1] = line
  end
  if template.mode == "html" then
    out[#out + 1] = "  return " .. html_alias .. ".trusted(table.concat(parts))"
  else
    out[#out + 1] = "  return table.concat(parts)"
  end
  out[#out + 1] = "end"
  out[#out + 1] = ""
  out[#out + 1] = "return {render = render}"
  out[#out + 1] = ""
  return table.concat(out, "\n")
end

local record CodegenModule
  generate: function(template: types.Template, name: string): string
end

local M: CodegenModule = {generate = generate}
return M
