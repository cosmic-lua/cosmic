#!/usr/bin/env cosmic
--- Generate Teal .d.tl type definitions from cosmo-lua definitions.lua.
--- Parses LuaLS annotations and produces Teal-compatible type declarations.

local defs = require("_types.gentype_defs")
local tl = require("tl")
local gt = require("_types.gentype_types")
local Param = gt.Param
local Return = gt.Return
local FuncDecl = gt.FuncDecl
local Field = gt.Field
local ClassDecl = gt.ClassDecl
local ModuleDecl = gt.ModuleDecl

local record GentypeRender
  generate_dtl: function(module: ModuleDecl): string
  convert_type: function(t: string): string
end
local render = require("_types.gentype_render") as GentypeRender -- cast: narrow surface

local record GentypeExtract
  extract_module_content: function(source: string, module_name: string): string
end
local extract = require("_types.gentype_extract") as GentypeExtract -- cast: narrow surface

local record GentypeParse
  parse_annotations: function(raw_lines: {string}): {string}, {Param}, {Return}, boolean, string, {Field}, boolean, string, {string}
  valid_type: function(t: string): boolean
end
local parse = require("_types.gentype_parse") as GentypeParse -- cast: narrow surface
local parse_annotations = parse.parse_annotations

-- Modules to generate (in order). "cosmo" is the top-level cosmo record
-- (kCosmoFuncs surface); the rest are require("cosmo.<name>") submodules.
local MODULES = {"cosmo", "unix", "path", "getopt", "lsqlite3", "re", "argon2", "zip", "repl"}

--- Helper to process a class annotation block.
local function process_class_block(anno_lines: {string}, module_name: string, classes: {ClassDecl})
  local desc, _, _, _, class_annotation, fields = parse_annotations(anno_lines)
  if not class_annotation then return end

  -- `---@class mod.Name: userdata` marks a userdata-backed class,
  -- rendered as Teal's `userdata` member (see gentype_render).
  local parent: string = nil
  for _, line in ipairs(anno_lines) do
    local par = line:match("^%s*%-%-%-@class%s+[%w_%.]+%s*:%s*([%w_%.]+)")
    if par then
      parent = par
      break
    end
  end

  local class_name = class_annotation:match("%.([%w_]+)$") or class_annotation
  local filtered_desc: {string} = {}
  for _, d in ipairs(desc) do
    if not d:match("^@class") then
      table.insert(filtered_desc, d)
    end
  end

  local found = false
  for _, cls in ipairs(classes) do
    if cls.name == class_name then
      found = true
      for _, field in ipairs(fields) do
        table.insert(cls.fields, field)
      end
      break
    end
  end
  if not found then
    table.insert(classes, {
        name = class_name,
        module = module_name,
        parent = parent,
        fields = fields,
        methods = {},
        description = filtered_desc,
      })
  end
end

--- True when an annotation block carries a `---@type` tag (the tag that
--- surfaces lowercase module-table fields such as `argon2.variants`).
local function has_type_annotation(anno_lines: {string}): boolean
  for _, line in ipairs(anno_lines) do
    if line:match("^%s*%-%-%-?%s*@type%s") then
      return true
    end
  end
  return false
end

--- Reconcile annotated params with the declaration's parameter list. The
--- declaration is authoritative for names and order; annotations attach
--- types. A declared-but-unannotated param becomes `any` (required, unless a
--- preceding param is optional — Teal forbids required-after-optional).
local function reconcile_params(params: {Param}, params_str: string): {Param}
  if not params_str or params_str == "" then return params end
  local by_name: {string: Param} = {}
  for _, p in ipairs(params) do by_name[p.name] = p end
  local result: {Param} = {}
  local used: {string: boolean} = {}
  for token in params_str:gmatch("[^,]+") do
    local pname = token:match("^%s*(.-)%s*$")
    if pname ~= "" then
      local p = by_name[pname]
      if p then
        table.insert(result, p)
        used[pname] = true
      else
        table.insert(result, {name = pname, param_type = "any", description = "", optional = false})
      end
    end
  end
  for _, p in ipairs(params) do
    if not used[p.name] then
      table.insert(result, p)
    end
  end
  local seen_optional = false
  for _, p in ipairs(result) do
    if p.optional then
      seen_optional = true
    elseif seen_optional then
      p.optional = true
    end
  end
  return result
end

--- Parse a module from definitions.lua source.
local function parse_module(source: string, module_name: string): ModuleDecl
  local content = extract.extract_module_content(source, module_name)
  if not content then return nil end

  local module: ModuleDecl = {
    name = module_name, description = {},
    functions = {}, classes = {}, constants = {}, aliases = {},
  }

  -- Keep empty lines: a blank line terminates an annotation block (e.g. a
  -- standalone @class block emitted by extract_module_content).
  local lines: {string} = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end

  local anno_lines: {string} = {}
  local i = 1
  local in_class_block = false

  while i <= #lines do
    local line = lines[i]

    local aname, arest = line:match("^%-%-%-@alias%s+([%w_%.]+)%s+(.+)$")
    if aname then
      -- Only module-prefixed aliases become named types; bare legacy
      -- aliases (uint32, JsonValue, ...) stay hardcoded conversions in
      -- gentype_render.TYPE_ALIASES.
      if aname:match("%.") then
        local adesc = parse_annotations(anno_lines)
        table.insert(module.aliases, {
            name = aname:match("%.([%w_]+)$"),
            module = module_name,
            alias_type = arest:match("^(%S+)"),
            description = adesc,
          })
      end
      anno_lines = {}
      i = i + 1
    elseif line:match("^%s*%-%-%-") or line:match("^%-%-%-") then
      if line:match("^%-%-%-@class%s+") and in_class_block and #anno_lines > 0 then
        process_class_block(anno_lines, module_name, module.classes)
        anno_lines = {}
      end

      table.insert(anno_lines, line)
      if line:match("^%-%-%-@class%s+") then
        in_class_block = true
      end
      i = i + 1
    elseif line:match("^%s*[%l_][%w_]*%s*=%s*") and not line:match("^%s*local%s") and
    has_type_annotation(anno_lines) then
      -- A lowercase module-table field annotated with `---@type <T>` (e.g.
      -- `argon2.variants`) becomes a typed field on the module record.
      local fname = line:match("^%s*([%l_][%w_]*)%s*=")
      if fname and fname ~= module_name then
        local desc, _, returns, _, _, _ = parse_annotations(anno_lines)
        if #returns > 0 and returns[1].description == "type" then
          table.insert(module.constants, {
              name = fname, const_type = returns[1].return_type, description = desc,
            })
        end
      end
      anno_lines = {}
      i = i + 1
    elseif line:match("^%s*([A-Z][A-Z0-9_]*)%s*=%s*") then
      local name = line:match("^%s*([A-Z][A-Z0-9_]*)%s*=")
      if name then
        local already_exists = false
        for _, c in ipairs(module.constants) do
          if c.name == name then already_exists = true; break end
        end
        if not already_exists then
          local desc, _, returns, _, _, _ = parse_annotations(anno_lines)
          local const_type = "integer"
          if #returns > 0 and returns[1].description == "type" then
            const_type = returns[1].return_type
          end
          table.insert(module.constants, {
              name = name, const_type = const_type, description = desc,
            })
        end
      end
      anno_lines = {}
      i = i + 1
    elseif line:match("^function%s+" .. module_name .. "%.([%w_]+)%s*%(") then
      local fname = line:match("^function%s+" .. module_name .. "%.([%w_]+)%s*%(")
      local params_str = line:match("%((.-)%)")

      -- Check for embedded @class
      local class_start_idx = 0
      for idx, anno_line in ipairs(anno_lines) do
        if anno_line:match("^%-%-%-@class%s+") then
          class_start_idx = idx
          break
        end
      end

      if class_start_idx > 0 then
        local class_lines: {string} = {}
        local func_lines: {string} = {}
        for idx = 1, class_start_idx - 1 do
          table.insert(func_lines, anno_lines[idx])
        end
        local class_end_idx = class_start_idx
        for idx = class_start_idx, #anno_lines do
          local anno_line = anno_lines[idx]
          if anno_line:match("^%-%-%-@class%s+") or anno_line:match("^%-%-%-@field%s+") then
            class_end_idx = idx
          elseif idx > class_start_idx and anno_line:match("^%-%-%-$") then
            if idx < #anno_lines and anno_lines[idx + 1]:match("^%-%-%-@field%s+") then
              class_end_idx = idx
            else break end
          elseif idx > class_start_idx then break end
        end
        for idx = class_start_idx, class_end_idx do
          table.insert(class_lines, anno_lines[idx])
        end
        for idx = class_end_idx + 1, #anno_lines do
          table.insert(func_lines, anno_lines[idx])
        end
        if #class_lines > 0 then
          process_class_block(class_lines, module_name, module.classes)
        end
        anno_lines = func_lines
      end

      local desc, params, returns, nodiscard, _, _, fallible, error_type, generics = parse_annotations(anno_lines)
      params = reconcile_params(params, params_str)
      table.insert(module.functions, {
          name = fname, module = module_name, description = desc,
          params = params, returns = returns, is_method = false, nodiscard = nodiscard,
          fallible = fallible, error_type = error_type, generics = generics,
        })
      anno_lines = {}
      i = i + 1
    elseif line:match("^function%s+([%w_%.]+):([%w_]+)%s*%(") then
      local full_class_name, method_name = line:match("^function%s+([%w_%.]+):([%w_]+)%s*%(")
      local class_name = full_class_name:match("%.([%w_]+)$") or full_class_name
      local method_params_str = line:match("%((.-)%)")
      local desc, params, returns, nodiscard, _, _, fallible, error_type, generics = parse_annotations(anno_lines)
      params = reconcile_params(params, method_params_str)
      local method: FuncDecl = {
        name = method_name, module = module_name, description = desc,
        params = params, returns = returns, is_method = true,
        class_name = class_name, nodiscard = nodiscard,
        fallible = fallible, error_type = error_type, generics = generics,
      }
      local found = false
      for _, cls in ipairs(module.classes) do
        if cls.name == class_name then
          table.insert(cls.methods, method)
          found = true
          break
        end
      end
      if not found then
        table.insert(module.classes, {
            name = class_name, module = module_name,
            fields = {}, methods = {method}, description = {},
          })
      end
      anno_lines = {}
      i = i + 1
    else
      if in_class_block and #anno_lines > 0 then
        process_class_block(anno_lines, module_name, module.classes)
        in_class_block = false
      end
      anno_lines = {}
      i = i + 1
    end
  end

  -- Process remaining @class block
  if in_class_block and #anno_lines > 0 then
    process_class_block(anno_lines, module_name, module.classes)
  end

  return module
end

local record Result
  success: boolean
  output: string
  error: string
end

local UPSTREAM_HINT = "; fix the annotation upstream in whilp/cosmopolitan"
.. " tool/net/definitions.lua (its test_definitions_coverage.lua check 9"
.. " validates the same type grammar)"

--- Validate every parsed type expression in a module against the type
--- grammar, so a malformed upstream annotation fails generation loudly with
--- a pointer at the offending definitions.lua entry instead of rendering
--- invalid Teal. Returns an error message, or nil when everything is valid.
local function validate_module(module: ModuleDecl): string
  local function bad(decl: string, what: string, text: string): string
    return "invalid type annotation in definitions.lua module '" .. module.name
    .. "': " .. decl .. " " .. what .. " has malformed type '"
    .. tostring(text) .. "'" .. UPSTREAM_HINT
  end
  local function check_func(decl: string, f: FuncDecl): string
    for _, p in ipairs(f.params) do
      if not parse.valid_type(p.param_type) then
        return bad(decl, "param '" .. p.name .. "'", p.param_type)
      end
    end
    for idx, r in ipairs(f.returns) do
      if r.description ~= "type" and not parse.valid_type(r.return_type) then
        return bad(decl, "return #" .. idx, r.return_type)
      end
    end
    if f.fallible and f.error_type and not parse.valid_type(f.error_type) then
      return bad(decl, "error type", f.error_type)
    end
    return nil
  end
  for _, f in ipairs(module.functions) do
    local err = check_func(module.name .. "." .. f.name, f)
    if err then return err end
  end
  for _, cls in ipairs(module.classes) do
    for _, field in ipairs(cls.fields) do
      if not parse.valid_type(field.field_type) then
        return bad(module.name .. "." .. cls.name .. "." .. field.name,
          "field", field.field_type)
      end
    end
    for _, m in ipairs(cls.methods) do
      local err = check_func(module.name .. "." .. cls.name .. ":" .. m.name, m)
      if err then return err end
    end
  end
  for _, c in ipairs(module.constants) do
    if not parse.valid_type(c.const_type) then
      return bad(module.name .. "." .. c.name, "constant", c.const_type)
    end
  end
  return nil
end

--- Belt and suspenders: the rendered output must at least parse as Teal.
--- Full cross-module type resolution is not available at generation time,
--- so only syntax errors are consulted. Returns an error message or nil.
local function syntax_check(output: string, module_name: string): string
  local name = "cosmo/" .. module_name .. ".d.tl"
  local env = tl.init_env(true)
  local ok, res = pcall(tl.process_string, output, false, env, name)
  if not ok then
    return "generated " .. name .. " failed to parse: " .. tostring(res)
    .. "; this usually means a malformed type annotation in definitions.lua"
    .. UPSTREAM_HINT
  end
  local result = res
  if result and result.syntax_errors and #result.syntax_errors > 0 then
    local msgs: {string} = {}
    for idx, e in ipairs(result.syntax_errors) do
      if idx > 3 then break end
      table.insert(msgs, tostring(e.y or 0) .. ":" .. tostring(e.x or 0)
        .. ": " .. (e.msg or ""))
    end
    return "generated " .. name .. " is not valid Teal ("
    .. table.concat(msgs, "; ")
    .. "); this usually means a malformed type annotation in definitions.lua"
    .. UPSTREAM_HINT
  end
  return nil
end

--- Validate a parsed module and render it, syntax-checking the result.
--- Returns the rendered output, or nil and an error message.
local function render_module(module: ModuleDecl): string, string
  local verr = validate_module(module)
  if verr then return nil, verr end
  local output = render.generate_dtl(module)
  local serr = syntax_check(output, module.name)
  if serr then return nil, serr end
  return output
end

--- Run the generator for a specific module or all modules.
local function run(module_name: string): Result
  local source, derr = defs.read()
  if not source then
    return {success = false, error = derr}
  end

  if module_name then
    local found = false
    for _, m in ipairs(MODULES) do
      if m == module_name then found = true; break end
    end
    if not found then
      return {success = false, error = "Unknown module: " .. module_name}
    end
    local module = parse_module(source, module_name)
    if not module then
      return {success = false, error = "Failed to parse module: " .. module_name}
    end
    local output, err = render_module(module)
    if not output then
      return {success = false, error = err}
    end
    return {success = true, output = output}
  else
    local outputs: {string} = {}
    for _, m in ipairs(MODULES) do
      local module = parse_module(source, m)
      if module then
        local output, err = render_module(module)
        if not output then
          return {success = false, error = err}
        end
        table.insert(outputs, "-- === " .. m .. " ===")
        table.insert(outputs, output)
      end
    end
    return {success = true, output = table.concat(outputs, "\n")}
  end
end

local function get_modules(): {string}
  return MODULES
end

local record GenTypeModule
  run: function(module_name?: string): Result
  parse_module: function(source: string, module_name: string): ModuleDecl
  render_module: function(module: ModuleDecl): string, string
  generate_dtl: function(module: ModuleDecl): string
  convert_type: function(t: string): string
  get_modules: function(): {string}
  MODULES: {string}
end

local M: GenTypeModule = {
  run = run,
  parse_module = parse_module,
  render_module = render_module,
  generate_dtl = render.generate_dtl,
  convert_type = render.convert_type,
  get_modules = get_modules,
  MODULES = MODULES,
}

return M
