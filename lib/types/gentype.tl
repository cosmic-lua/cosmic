#!/usr/bin/env cosmic
--- Generate Teal .d.tl type definitions from cosmo-lua definitions.lua.
--- Parses LuaLS annotations and produces Teal-compatible type declarations.

local cosmo = require("cosmo")
local cosmic = require("cosmic")
local gt = require("types.gentype_types")
local Param = gt.Param
local Return = gt.Return
local FuncDecl = gt.FuncDecl
local Constant = gt.Constant
local Field = gt.Field
local ClassDecl = gt.ClassDecl
local ModuleDecl = gt.ModuleDecl

local record GentypeRender
  generate_dtl: function(module: ModuleDecl): string
  convert_type: function(t: string): string
  extract_module_content: function(source: string, module_name: string): string
end
local render = require("types.gentype_render") as GentypeRender

-- Modules to generate (in order)
local MODULES = {"unix", "path", "getopt", "lsqlite3", "re", "argon2", "zip"}

--- Parse annotations from a block of text before a declaration.
local function parse_annotations(lines: {string}): {string}, {Param}, {Return}, boolean, string, {Field}
  local desc: {string} = {}
  local params: {Param} = {}
  local returns: {Return} = {}
  local fields: {Field} = {}
  local nodiscard = false
  local class_annotation: string = nil

  for _, line in ipairs(lines) do
    if not line:match("^%-%-%-@") then
      local desc_text = line:match("^%-%-%-(.*)$")
      if desc_text then
        if desc_text:sub(1, 1) == " " then
          desc_text = desc_text:sub(2)
        end
        if desc_text ~= "" then
          table.insert(desc, desc_text)
        end
      end
    end

    local pname, ptype, pdesc = line:match("^%-%-%-@param%s+([%w_%.%?]+)%s+([^%s]+)%s*(.*)$")
    if pname then
      local optional = ptype:match("%?$") ~= nil
      if optional then
        ptype = ptype:sub(1, -2)
      end
      if pname:match("%?$") then
        optional = true
        pname = pname:sub(1, -2)
      end
      table.insert(params, {name = pname, param_type = ptype, description = pdesc or "", optional = optional})
    end

    local fname, ftype, fdesc = line:match("^%-%-%-@field%s+([%w_%.%?]+)%s+([^%s]+)%s*(.*)$")
    if fname then
      local optional = false
      if fname:match("%?$") then
        optional = true
        fname = fname:sub(1, -2)
      end
      if ftype:match("%?$") then
        optional = true
        ftype = ftype:sub(1, -2)
      end
      table.insert(fields, {name = fname, field_type = ftype, description = {fdesc or ""}})
    end

    local full_return = line:match("^%-%-%-@return%s+(.+)$")
    if full_return then
      full_return = full_return:match("^%s*(.-)%s*$")

      local parts = {}
      local in_angle = 0
      local in_brace = 0
      local current = ""
      for i = 1, #full_return do
        local c = full_return:sub(i, i)
        if c == "<" then in_angle = in_angle + 1
        elseif c == ">" then in_angle = in_angle - 1
        elseif c == "{" then in_brace = in_brace + 1
        elseif c == "}" then in_brace = in_brace - 1
        end
        if c == "," and in_angle == 0 and in_brace == 0 then
          local rest_after_comma = full_return:sub(i + 1)
          local next_word = rest_after_comma:match("^%s*([%w_%.]+)")
          local lua_keywords = {
            ["and"] = true, ["or"] = true, ["not"] = true,
            ["if"] = true, ["then"] = true, ["else"] = true, ["elseif"] = true,
            ["end"] = true, ["while"] = true, ["do"] = true, ["for"] = true,
            ["repeat"] = true, ["until"] = true, ["break"] = true, ["return"] = true,
            ["local"] = true, ["in"] = true,
          }
          local is_function_call = rest_after_comma:match("^%s*" .. (next_word or "") .. "%s*%(")
          if next_word and not lua_keywords[next_word] and not is_function_call and (
            next_word:match("^[%l_]") or next_word:match("^[%u]") or next_word:match("%.")
          ) then
            table.insert(parts, current)
            current = ""
          else
            current = current .. c
          end
        else
          current = current .. c
        end
      end
      table.insert(parts, current)

      for _, return_part in ipairs(parts) do
        return_part = return_part:match("^%s*(.-)%s*$")
        local part_type: string = nil
        local part_desc: string = nil
        if return_part:match("^{") then
          part_type, part_desc = return_part:match("^({.-%}%[?%]?)%s+(.*)$")
          if not part_type then
            part_type = return_part:match("^({.-%}%[?%]?)%s*$")
          end
        elseif return_part:match("<.->") then
          part_type, part_desc = return_part:match("^([^%s]+<.->)%s+(.*)$")
          if not part_type then
            part_type = return_part:match("^([^%s]+<.->)%s*$")
          end
        end
        if not part_type then
          part_type, part_desc = return_part:match("^([^%s]+)%s+(.*)$")
          if not part_type then
            part_type = return_part
          end
        end
        if part_type and part_type ~= "" then
          if part_type == "table" and part_desc then
            local specific_type = part_desc:match("^([%w_]+)")
            if specific_type and specific_type:match("^[%l_]") then
              part_type = specific_type
              part_desc = part_desc:match("^[%w_]+%s*(.*)") or part_desc
            end
          end
          table.insert(returns, {return_type = part_type, description = part_desc or ""})
        end
      end
    end

    if line:match("^%-%-%-@nodiscard") then
      nodiscard = true
    end

    local cname = line:match("^%-%-%-@class%s+([%w_%.]+)")
    if cname then
      class_annotation = cname
    end

    local ttype = line:match("^%-%-%-?%s*@type%s+([%w_]+)")
    if ttype then
      table.insert(returns, {return_type = ttype, description = "type"})
    end
  end

  return desc, params, returns, nodiscard, class_annotation, fields
end

--- Helper to process a class annotation block.
local function process_class_block(anno_lines: {string}, module_name: string, classes: {ClassDecl})
  local desc, _, _, _, class_annotation, fields = parse_annotations(anno_lines)
  if not class_annotation then return end

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
        fields = fields,
        methods = {},
        description = filtered_desc,
      })
  end
end

--- Parse a module from definitions.lua source.
local function parse_module(source: string, module_name: string): ModuleDecl
  local content = render.extract_module_content(source, module_name)
  if not content then return nil end

  local module: ModuleDecl = {
    name = module_name, description = {},
    functions = {}, classes = {}, constants = {},
  }

  local lines: {string} = {}
  for line in content:gmatch("[^\n]+") do
    table.insert(lines, line)
  end

  local anno_lines: {string} = {}
  local i = 1
  local in_class_block = false

  while i <= #lines do
    local line = lines[i]

    if line:match("^%s*%-%-%-") or line:match("^%-%-%-") then
      if line:match("^%-%-%-@class%s+") and in_class_block and #anno_lines > 0 then
        process_class_block(anno_lines, module_name, module.classes)
        anno_lines = {}
      end

      table.insert(anno_lines, line)
      if line:match("^%-%-%-@class%s+") then
        in_class_block = true
      end
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

      local desc, params, returns, nodiscard, _, _ = parse_annotations(anno_lines)
      if #params == 0 and params_str and params_str ~= "" then
        for pname in params_str:gmatch("([%w_]+)") do
          table.insert(params, {name = pname, param_type = "any", description = "", optional = true})
        end
      end
      table.insert(module.functions, {
          name = fname, module = module_name, description = desc,
          params = params, returns = returns, is_method = false, nodiscard = nodiscard,
        })
      anno_lines = {}
      i = i + 1
    elseif line:match("^function%s+([%w_%.]+):([%w_]+)%s*%(") then
      local full_class_name, method_name = line:match("^function%s+([%w_%.]+):([%w_]+)%s*%(")
      local class_name = full_class_name:match("%.([%w_]+)$") or full_class_name
      local method_params_str = line:match("%((.-)%)")
      local desc, params, returns, nodiscard, _, _ = parse_annotations(anno_lines)
      if #params == 0 and method_params_str and method_params_str ~= "" then
        for pname in method_params_str:gmatch("([%w_]+)") do
          table.insert(params, {name = pname, param_type = "any", description = "", optional = true})
        end
      end
      local method: FuncDecl = {
        name = method_name, module = module_name, description = desc,
        params = params, returns = returns, is_method = true,
        class_name = class_name, nodiscard = nodiscard,
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

--- Run the generator for a specific module or all modules.
local function run(module_name: string): Result
  local source = cosmo.Slurp("/zip/.lua/definitions.lua")
  if not source then
    return {success = false, error = "Failed to read /zip/.lua/definitions.lua"}
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
    return {success = true, output = render.generate_dtl(module)}
  else
    local outputs: {string} = {}
    for _, m in ipairs(MODULES) do
      local module = parse_module(source, m)
      if module then
        table.insert(outputs, "-- === " .. m .. " ===")
        table.insert(outputs, render.generate_dtl(module))
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
  generate_dtl: function(module: ModuleDecl): string
  convert_type: function(t: string): string
  get_modules: function(): {string}
  MODULES: {string}
end

local M: GenTypeModule = {
  run = run,
  parse_module = parse_module,
  generate_dtl = render.generate_dtl,
  convert_type = render.convert_type,
  get_modules = get_modules,
  MODULES = MODULES,
}

cosmic.main(function(args: {string}): number, string
    local module_name = args[1]
    local result = run(module_name)
    if result.success then
      print(result.output)
      return 0
    else
      return 1, result.error
    end
  end)

return M
