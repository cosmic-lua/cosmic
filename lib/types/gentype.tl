#!/usr/bin/env cosmic
--- Generate Teal .d.tl type definitions from cosmo-lua definitions.lua.
--- Parses LuaLS annotations and produces Teal-compatible type declarations.

local cosmo = require("cosmo")
local cosmic = require("cosmic")

-- Modules to generate (in order)
local MODULES = {"unix", "path", "getopt", "lsqlite3", "re", "argon2", "zip"}

-- Type conversion from LuaLS to Teal
-- integer -> number for Teal compatibility (Teal infers numeric literals as number)
local TYPE_ALIASES = {
  ["integer"] = "number",
  ["number"] = "number",
  ["string"] = "string",
  ["boolean"] = "boolean",
  ["any"] = "any",
  ["nil"] = "nil",
  ["table"] = "table",
  ["function"] = "function",
  ["userdata"] = "userdata",
  ["FILE"] = "FILE",
  ["uint32"] = "number",
  ["uint16"] = "number",
  ["int64"] = "number",
}

-- Records for parsed data
local record Param
  name: string
  param_type: string
  description: string
  optional: boolean
end

local record Return
  return_type: string
  description: string
end

local record FuncDecl
  name: string
  module: string
  description: {string}
  params: {Param}
  returns: {Return}
  is_method: boolean
  class_name: string
  nodiscard: boolean
end

local record Constant
  name: string
  const_type: string
  description: {string}
end

local record Field
  name: string
  field_type: string
  description: {string}
end

local record ClassDecl
  name: string
  module: string
  parent: string
  fields: {Field}
  methods: {FuncDecl}
  description: {string}
end

local record ModuleDecl
  name: string
  description: {string}
  functions: {FuncDecl}
  classes: {ClassDecl}
  constants: {Constant}
end

--- Convert a LuaLS type to Teal type.
local function convert_type(t: string): string
  if not t or t == "" then return "any" end

  -- Remove leading/trailing whitespace
  t = t:match("^%s*(.-)%s*$")

  -- Handle inline record types like "{ name: string, ip: integer }" or "{ name: string }[]"
  -- Teal doesn't support inline record definitions in function signatures, convert to any
  if t:match("^{%s*[%w_]+%s*:%s*") then
    return "any"
  end

  -- Handle backtick-quoted types (invalid) -> convert to any
  if t:match("`") then
    return "any"
  end

  -- Check simple aliases
  if TYPE_ALIASES[t] then
    return TYPE_ALIASES[t]
  end

  -- Handle literal boolean types: true -> boolean, false -> boolean
  if t == "true" or t == "false" then
    return "boolean"
  end

  -- Handle literal number types: 0, 1, etc. -> number
  -- Use number instead of integer for Teal compatibility (Teal infers numeric values as number)
  if t:match("^%-?%d+$") then
    return "number"
  end

  -- Convert integer to number for Teal compatibility
  -- Teal's type system infers all Lua numbers as 'number', not 'integer'
  if t == "integer" then
    return "number"
  end

  -- Handle nullable types: T? -> T | nil
  -- For return types, nullable should be represented as a union with nil
  -- However, if T is already a union of multiple table types, use 'any' instead
  -- because Teal cannot discriminate between multiple table types
  local base = t:match("^(.+)%?$")
  if base then
    -- Check if base is a union of multiple types (contains |)
    if base:match("|") then
      -- Count how many parts look like table/record types (start with uppercase)
      local table_count = 0
      for part in base:gmatch("[^|]+") do
        part = part:match("^%s*(.-)%s*$")
        if part:match("^[%u]") or part:match("%.([%u][%w_]*)$") then
          table_count = table_count + 1
        end
      end
      -- If multiple table types, use 'any' to avoid Teal's union discrimination issue
      if table_count > 1 then
        return "any"
      end
    end
    local converted_base = convert_type(base)
    -- Return as union with nil
    return converted_base .. " | nil"
  end

  -- Handle array types: string[] -> {string}
  base = t:match("^(.+)%[%]$")
  if base then
    return "{" .. convert_type(base) .. "}"
  end

  -- Handle table<K,V> -> {K:V}
  local k, v = t:match("^table<([^,]+),%s*(.+)>$")
  if k and v then
    return "{" .. convert_type(k) .. ":" .. convert_type(v) .. "}"
  end

  -- Handle fun(args): ret -> function(args): ret
  local fun_match = t:match("^fun%((.*)%)$")
  if fun_match then
    return "function(" .. fun_match .. ")"
  end
  fun_match = t:match("^fun%((.*)%):(.+)$")
  if fun_match then
    local args, ret = t:match("^fun%((.*)%):(.+)$")
    return "function(" .. (args or "") .. "): " .. convert_type(ret or "")
  end

  -- Handle generic function syntax: fun(a: T, b: U): R
  if t:match("^fun%(") then
    local inside = t:match("^fun%((.*)%):%s*(.+)$")
    if inside then
      local args_part, ret_part = t:match("^fun%((.*)%):%s*(.+)$")
      return "function(" .. (args_part or "") .. "): " .. convert_type(ret_part or "")
    end
    inside = t:match("^fun%((.*)%)$")
    if inside then
      return "function(" .. inside .. ")"
    end
  end

  -- Handle union types: T|U -> T | U
  -- Teal supports union types with | syntax
  if t:match("|") then
    local parts: {string} = {}
    for part in t:gmatch("[^|]+") do
      part = part:match("^%s*(.-)%s*$")
      if part ~= "nil" and part ~= "" then
        table.insert(parts, convert_type(part))
      end
    end
    if #parts == 0 then
      return "any"
    elseif #parts == 1 then
      return parts[1]
    else
      return table.concat(parts, " | ")
    end
  end

  -- Handle module-prefixed types: lsqlite3.Database -> Database
  local prefix, suffix = t:match("^([%w_]+)%.([%w_]+)$")
  if prefix and suffix then
    return suffix
  end

  -- Return as-is (it's probably a class name)
  return t
end

--- Parse annotations from a block of text before a declaration.
local function parse_annotations(lines: {string}): {string}, {Param}, {Return}, boolean, string, {Field}
  local desc: {string} = {}
  local params: {Param} = {}
  local returns: {Return} = {}
  local fields: {Field} = {}
  local nodiscard = false
  local class_annotation: string = nil

  for _, line in ipairs(lines) do
    -- Skip lines with annotations (---@) - handle them separately below
    if not line:match("^%-%-%-@") then
      -- Description line (--- text but not ---@)
      -- Only strip the single space immediately after ---, preserve additional indentation
      local desc_text = line:match("^%-%-%-(.*)$")
      if desc_text then
        -- Strip single leading space if present, but preserve additional spaces (for code examples)
        if desc_text:sub(1, 1) == " " then
          desc_text = desc_text:sub(2)
        end
        if desc_text ~= "" then
          table.insert(desc, desc_text)
        end
      end
    end

    -- @param name type description
    -- Parameter name may end with ? for optional params
    local pname, ptype, pdesc = line:match("^%-%-%-@param%s+([%w_%.%?]+)%s+([^%s]+)%s*(.*)$")
    if pname then
      local optional = ptype:match("%?$") ~= nil
      if optional then
        ptype = ptype:sub(1, -2)
      end
      -- Also check if name ends with ?
      if pname:match("%?$") then
        optional = true
        pname = pname:sub(1, -2)
      end
      table.insert(params, {name = pname, param_type = ptype, description = pdesc or "", optional = optional})
    end

    -- @field name type description
    -- Field name may end with ? for optional fields
    local fname, ftype, fdesc = line:match("^%-%-%-@field%s+([%w_%.%?]+)%s+([^%s]+)%s*(.*)$")
    if fname then
      local optional = false
      -- Check if name ends with ?
      if fname:match("%?$") then
        optional = true
        fname = fname:sub(1, -2)
      end
      -- Check if type ends with ?
      if ftype:match("%?$") then
        optional = true
        ftype = ftype:sub(1, -2)
      end
      table.insert(fields, {name = fname, field_type = ftype, description = {fdesc or ""}})
    end

    -- @return type [name] [description]
    -- Can have multiple return values: "@return type1 name1, type2 name2" (for function signatures)
    -- But NOT for descriptions containing commas
    local full_return = line:match("^%-%-%-@return%s+(.+)$")
    if full_return then
      full_return = full_return:match("^%s*(.-)%s*$")  -- trim
      local rtype: string = nil
      local rdesc: string = nil

      -- Check if it looks like multiple typed returns (e.g., "integer reader, integer writer")
      -- Pattern: "type name, type name" where both parts start with a type word
      local parts = {}
      local in_angle = 0
      local in_brace = 0
      local current = ""
      for i = 1, #full_return do
        local c = full_return:sub(i, i)
        if c == "<" then
          in_angle = in_angle + 1
        elseif c == ">" then
          in_angle = in_angle - 1
        elseif c == "{" then
          in_brace = in_brace + 1
        elseif c == "}" then
          in_brace = in_brace - 1
        end
        if c == "," and in_angle == 0 and in_brace == 0 then
          -- Only split on commas outside angle brackets and curly braces
          -- Check if what follows looks like a type (word at start, optionally with dot for module types)
          local rest_after_comma = full_return:sub(i + 1)
          local next_word = rest_after_comma:match("^%s*([%w_%.]+)")

          -- Lua keywords that should not be treated as type names
          local lua_keywords = {
            ["and"] = true, ["or"] = true, ["not"] = true,
            ["if"] = true, ["then"] = true, ["else"] = true, ["elseif"] = true,
            ["end"] = true, ["while"] = true, ["do"] = true, ["for"] = true,
            ["repeat"] = true, ["until"] = true, ["break"] = true, ["return"] = true,
            ["local"] = true, ["in"] = true,
          }

          -- Split if next word looks like a type name (starts with letter/underscore, may contain dots)
          -- Common types: integer, number, string, boolean, nil, table, function
          -- Or module-prefixed types: unix.Errno, zip.Reader, etc.
          -- But exclude Lua keywords like "or", "and", etc.
          -- Also exclude function calls like "remaining()" - check if word is followed by ()
          local is_function_call = rest_after_comma:match("^%s*" .. (next_word or "") .. "%s*%(")

          if next_word and not lua_keywords[next_word] and not is_function_call and (
            next_word:match("^[%l_]") or  -- Starts with lowercase or underscore (like integer, nil, string)
            next_word:match("^[%u]")      -- Starts with uppercase (like Memory, Errno)
            or next_word:match("%.")      -- Contains dot (like unix.Errno)
          ) then
            -- This looks like another typed return value, split here
            table.insert(parts, current)
            current = ""
          else
            -- Comma is part of description, keep it
            current = current .. c
          end
        else
          current = current .. c
        end
      end
      table.insert(parts, current)

      -- Process each part
      for _, return_part in ipairs(parts) do
        return_part = return_part:match("^%s*(.-)%s*$")  -- trim
        local part_type: string = nil
        local part_desc: string = nil

        -- Check if it's an inline record type: { ... }
        if return_part:match("^{") then
          -- Match everything up to closing } or }[]
          part_type, part_desc = return_part:match("^({.-%}%[?%]?)%s+(.*)$")
          if not part_type then
            part_type = return_part:match("^({.-%}%[?%]?)%s*$")
          end
        -- Check if it contains angle brackets (generic type like table<K, V>)
        elseif return_part:match("<.->") then
          -- Match generic type, everything after closing > is description
          part_type, part_desc = return_part:match("^([^%s]+<.->)%s+(.*)$")
          if not part_type then
            part_type = return_part:match("^([^%s]+<.->)%s*$")
          end
        end
        -- Simple type: just first word
        if not part_type then
          part_type, part_desc = return_part:match("^([^%s]+)%s+(.*)$")
          if not part_type then
            part_type = return_part
          end
        end
        if part_type and part_type ~= "" then
          -- If type is generic "table" but description starts with a specific type name,
          -- use that specific type instead (e.g., "@return table parser ..." -> return type "parser")
          if part_type == "table" and part_desc then
            local specific_type = part_desc:match("^([%w_]+)")
            if specific_type and specific_type:match("^[%l_]") then
              -- Description starts with what looks like a type name, use it
              part_type = specific_type
              -- Remove the type name from description since it's redundant
              part_desc = part_desc:match("^[%w_]+%s*(.*)") or part_desc
            end
          end
          table.insert(returns, {return_type = part_type, description = part_desc or ""})
        end
      end
    end

    -- @nodiscard
    if line:match("^%-%-%-@nodiscard") then
      nodiscard = true
    end

    -- @class ClassName or @class ClassName: parent
    local cname = line:match("^%-%-%-@class%s+([%w_%.]+)")
    if cname then
      class_annotation = cname
    end

    -- @type annotation (for constants)
    local ttype = line:match("^%-%-%-?%s*@type%s+([%w_]+)")
    if ttype then
      -- Store in returns as a workaround for constants
      table.insert(returns, {return_type = ttype, description = "type"})
    end
  end

  return desc, params, returns, nodiscard, class_annotation, fields
end

--- Extract a module's content from definitions.lua.
local function extract_module_content(source: string, module_name: string): string
  -- Find module start: modulename = { or modulename = {}
  local pattern = "\n" .. module_name .. " = {"
  local start_pos = source:find(pattern, 1, true)
  if not start_pos then
    pattern = "^" .. module_name .. " = {"
    if source:match(pattern) then
      start_pos = 1
    else
      return nil
    end
  end

  -- Find module end by tracking braces
  local brace_count = 0
  local in_module = false
  local end_pos = start_pos

  for i = start_pos, #source do
    local c = source:sub(i, i)
    if c == "{" then
      brace_count = brace_count + 1
      in_module = true
    elseif c == "}" then
      brace_count = brace_count - 1
      if in_module and brace_count == 0 then
        end_pos = i
        break
      end
    end
  end

  -- Now find functions defined outside the module block: function module.func() or function Class:method()
  -- Look for patterns after the closing brace
  local content = source:sub(start_pos, end_pos)

  -- Find all related function declarations after the module table
  -- Look for function module.name() or function module.Class:method()
  local search_start = end_pos

  -- Find the first function to determine where to start full extraction
  local first_func = source:find("\nfunction " .. module_name .. "%.", search_start)
  if first_func then
    -- Include everything from module table end to the first function
    -- This captures standalone @class blocks like OpenOptions
    content = content .. source:sub(end_pos, first_func - 1)
    search_start = first_func
  end

  while true do
    -- Find next function for this module (pattern: function module.anything)
    local func_start = source:find("\nfunction " .. module_name .. "%.", search_start)

    if not func_start then break end

    -- Check if we've moved past the next module definition
    local next_module_start = source:find("\n[%w_]+ = {", func_start + 1)
    if next_module_start and func_start > next_module_start then
      break
    end

    -- Find the end of this function (next function or end of file or next module)
    local func_end = source:find("\nfunction ", func_start + 1)
    local next_module = next_module_start

    if func_end and next_module then
      func_end = math.min(func_end, next_module)
    elseif next_module then
      func_end = next_module
    end

    if func_end then
      -- Include from function start to end (annotations already included above)
      content = content .. "\n" .. source:sub(func_start, func_end - 1)
      search_start = func_end
    else
      content = content .. "\n" .. source:sub(func_start)
      break
    end
  end

  return content
end

--- Parse a module from definitions.lua source.
local function parse_module(source: string, module_name: string): ModuleDecl
  local content = extract_module_content(source, module_name)
  if not content then
    return nil
  end


  local module: ModuleDecl = {
    name = module_name,
    description = {},
    functions = {},
    classes = {},
    constants = {},
  }

  -- Split into lines for easier parsing
  local lines: {string} = {}
  for line in content:gmatch("[^\n]+") do
    table.insert(lines, line)
  end

  local anno_lines: {string} = {}
  local i = 1
  local in_class_block = false

  while i <= #lines do
    local line = lines[i]

    -- Collect annotation lines
    if line:match("^%s*%-%-%-") or line:match("^%-%-%-") then
      -- Check if this is a NEW @class line while we're already in a class block
      if line:match("^%-%-%-@class%s+") and in_class_block and #anno_lines > 0 then
        -- Process the previous @class block before starting a new one
        local desc, _, _, _, class_annotation, fields = parse_annotations(anno_lines)
        if class_annotation then
          local class_name = class_annotation:match("%.([%w_]+)$") or class_annotation
          local filtered_desc: {string} = {}
          for _, d in ipairs(desc) do
            if not d:match("^@class") then
              table.insert(filtered_desc, d)
            end
          end

          local found = false
          for _, cls in ipairs(module.classes) do
            if cls.name == class_name then
              found = true
              for _, field in ipairs(fields) do
                table.insert(cls.fields, field)
              end
              break
            end
          end
          if not found then
            table.insert(module.classes, {
              name = class_name,
              module = module_name,
              fields = fields,
              methods = {},
              description = filtered_desc,
            })
          end
        end
        -- Clear anno_lines and start collecting the new class
        anno_lines = {}
      end

      table.insert(anno_lines, line)
      -- Check if this is a @class line - if so, keep collecting annotations
      if line:match("^%-%-%-@class%s+") then
        local cls_name = line:match("@class%s+([%w_%.]+)")
        in_class_block = true
      end
      i = i + 1
    -- Parse constant: NAME = value, or NAME = nil,
    elseif line:match("^%s*([A-Z][A-Z0-9_]*)%s*=%s*") then
      local name = line:match("^%s*([A-Z][A-Z0-9_]*)%s*=")
      if name then
        -- Check if constant already exists (skip duplicates)
        local already_exists = false
        for _, c in ipairs(module.constants) do
          if c.name == name then
            already_exists = true
            break
          end
        end
        if not already_exists then
          local desc, _, returns, _, _, _ = parse_annotations(anno_lines)
          local const_type = "integer"
          if #returns > 0 and returns[1].description == "type" then
            const_type = returns[1].return_type
          end
          table.insert(module.constants, {
            name = name,
            const_type = const_type,
            description = desc,
          })
        end
      end
      anno_lines = {}
      i = i + 1
    -- Parse function: function module.name(params) end
    elseif line:match("^function%s+" .. module_name .. "%.([%w_]+)%s*%(") then
      local fname = line:match("^function%s+" .. module_name .. "%.([%w_]+)%s*%(")
      local params_str = line:match("%((.-)%)")

      -- Check if there's a @class in the annotations - if so, split and process separately
      local class_start_idx = 0
      for idx, anno_line in ipairs(anno_lines) do
        if anno_line:match("^%-%-%-@class%s+") then
          class_start_idx = idx
          break
        end
      end

      if class_start_idx > 0 then
        -- Split annotations into class block and function block
        local class_lines: {string} = {}
        local func_lines: {string} = {}

        -- Everything before @class goes to function
        for idx = 1, class_start_idx - 1 do
          table.insert(func_lines, anno_lines[idx])
        end

        -- Find where class block ends (last @field line + any trailing blank comments)
        local class_end_idx = class_start_idx
        for idx = class_start_idx, #anno_lines do
          local anno_line = anno_lines[idx]
          if anno_line:match("^%-%-%-@class%s+") or anno_line:match("^%-%-%-@field%s+") then
            class_end_idx = idx
          elseif idx > class_start_idx and anno_line:match("^%-%-%-$") then
            -- Blank comment after @field might be part of class or separator
            -- Check if next line is still a field
            if idx < #anno_lines and anno_lines[idx + 1]:match("^%-%-%-@field%s+") then
              class_end_idx = idx
            else
              -- This is the separator between class and function docs
              break
            end
          elseif idx > class_start_idx then
            -- Hit a non-class annotation (like description or @param)
            break
          end
        end

        -- Extract class lines
        for idx = class_start_idx, class_end_idx do
          table.insert(class_lines, anno_lines[idx])
        end

        -- Everything after class block goes to function
        for idx = class_end_idx + 1, #anno_lines do
          table.insert(func_lines, anno_lines[idx])
        end

        -- Process the class
        if #class_lines > 0 then
          local _, _, _, _, class_annotation, class_fields = parse_annotations(class_lines)
          if class_annotation then
            local class_name = class_annotation:match("%.([%w_]+)$") or class_annotation

            local found = false
            for _, cls in ipairs(module.classes) do
              if cls.name == class_name then
                found = true
                for _, field in ipairs(class_fields) do
                  table.insert(cls.fields, field)
                end
                break
              end
            end
            if not found then
              table.insert(module.classes, {
                name = class_name,
                module = module_name,
                fields = class_fields,
                methods = {},
                description = {},
              })
            end
          end
        end

        -- Use func_lines for function processing
        anno_lines = func_lines
      end

      local desc, params, returns, nodiscard, _, _ = parse_annotations(anno_lines)

      -- If no @param annotations, infer parameter names from function signature
      -- Make all inferred parameters optional since we don't have type info
      if #params == 0 and params_str and params_str ~= "" then
        for pname in params_str:gmatch("([%w_]+)") do
          table.insert(params, {name = pname, param_type = "any", description = "", optional = true})
        end
      end

      local func: FuncDecl = {
        name = fname,
        module = module_name,
        description = desc,
        params = params,
        returns = returns,
        is_method = false,
        nodiscard = nodiscard,
      }
      table.insert(module.functions, func)
      anno_lines = {}
      i = i + 1
    -- Parse method: function Class:method(params) end (class may include module prefix like unix.Memory)
    elseif line:match("^function%s+([%w_%.]+):([%w_]+)%s*%(") then
      local full_class_name, method_name = line:match("^function%s+([%w_%.]+):([%w_]+)%s*%(")
      -- Extract just the class name without module prefix
      local class_name = full_class_name:match("%.([%w_]+)$") or full_class_name
      local method_params_str = line:match("%((.-)%)")
      local desc, params, returns, nodiscard, _, _ = parse_annotations(anno_lines)

      -- If no @param annotations, infer parameter names from method signature
      -- Make all inferred parameters optional since we don't have type info
      if #params == 0 and method_params_str and method_params_str ~= "" then
        for pname in method_params_str:gmatch("([%w_]+)") do
          table.insert(params, {name = pname, param_type = "any", description = "", optional = true})
        end
      end

      local method: FuncDecl = {
        name = method_name,
        module = module_name,
        description = desc,
        params = params,
        returns = returns,
        is_method = true,
        class_name = class_name,
        nodiscard = nodiscard,
      }

      -- Find or create the class
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
          name = class_name,
          module = module_name,
          fields = {},
          methods = {method},
          description = {},
        })
      end
      anno_lines = {}
      i = i + 1
    else
      -- Not a recognized pattern - check if we have accumulated a @class block
      if in_class_block and #anno_lines > 0 then
        -- Process accumulated @class with @field annotations
        local desc, _, _, _, class_annotation, fields = parse_annotations(anno_lines)

        if class_annotation then
          -- Remove module prefix if present
          local class_name = class_annotation:match("%.([%w_]+)$") or class_annotation

          -- Remove @class line from description (it's not descriptive text)
          local filtered_desc: {string} = {}
          for _, d in ipairs(desc) do
            if not d:match("^@class") then
              table.insert(filtered_desc, d)
            end
          end

          -- Check if class already exists
          local found = false
          local existing_class: ClassDecl = nil
          for _, cls in ipairs(module.classes) do
            if cls.name == class_name then
              found = true
              existing_class = cls
              break
            end
          end
          if not found then
            table.insert(module.classes, {
              name = class_name,
              module = module_name,
              fields = fields,
              methods = {},
              description = filtered_desc,
            })
          else
            -- Add fields to existing class
            if existing_class then
              for _, field in ipairs(fields) do
                table.insert(existing_class.fields, field)
              end
            end
          end
        end
        in_class_block = false
      end
      -- Clear annotations and move on
      anno_lines = {}
      i = i + 1
    end
  end

  -- Process any remaining @class block at end of file
  if in_class_block and #anno_lines > 0 then
    for _, anno_line in ipairs(anno_lines) do
      local class_annotation = anno_line:match("^%-%-%-@class%s+([%w_%.]+)")
      if class_annotation then
        local class_name = class_annotation:match("%.([%w_]+)$") or class_annotation
        local desc, _, _, _, _, fields = parse_annotations(anno_lines)

        local filtered_desc: {string} = {}
        for _, d in ipairs(desc) do
          if not d:match("^@class") then
            table.insert(filtered_desc, d)
          end
        end

        local found = false
        for _, cls in ipairs(module.classes) do
          if cls.name == class_name then
            found = true
            for _, field in ipairs(fields) do
              table.insert(cls.fields, field)
            end
            break
          end
        end
        if not found then
          table.insert(module.classes, {
            name = class_name,
            module = module_name,
            fields = fields,
            methods = {},
            description = filtered_desc,
          })
        end
        break
      end
    end
  end

  return module
end

--- Format description lines as comments.
local function format_description(desc: {string}, indent: string): {string}
  local result: {string} = {}
  if #desc > 0 then
    for _, line in ipairs(desc) do
      if line ~= "" then
        table.insert(result, indent .. "--- " .. line)
      else
        table.insert(result, indent .. "---")
      end
    end
  end
  return result
end

--- Generate Teal .d.tl content for a module.
local function generate_dtl(module: ModuleDecl): string
  local out: {string} = {}

  -- Header comment
  table.insert(out, "-- type declarations for cosmo." .. module.name)
  table.insert(out, "")

  -- Generate sub-records (classes) first
  for _, cls in ipairs(module.classes) do
    -- Include classes with fields or methods
    if #cls.methods > 0 or #cls.fields > 0 then
      -- Class description
      for _, line in ipairs(format_description(cls.description, "")) do
        table.insert(out, line)
      end
      table.insert(out, "local record " .. cls.name)

      -- Fields
      for _, field in ipairs(cls.fields) do
        -- Field description
        if #field.description > 0 then
          for _, line in ipairs(format_description(field.description, "  ")) do
            table.insert(out, line)
          end
        end
        local ftype = convert_type(field.field_type)
        table.insert(out, "  " .. field.name .. ": " .. ftype)
      end

      -- Add blank line between fields and methods if both exist
      if #cls.fields > 0 and #cls.methods > 0 then
        table.insert(out, "")
      end

      -- Methods
      for _, method in ipairs(cls.methods) do
        -- Method description
        if #method.description > 0 then
          for _, line in ipairs(format_description(method.description, "  ")) do
            table.insert(out, line)
          end
        end
        local params_parts: {string} = {"self: " .. cls.name}
        for _, p in ipairs(method.params) do
          local ptype = convert_type(p.param_type)
          -- Handle variadic params (named "...")
          if p.name == "..." then
            table.insert(params_parts, "...: " .. ptype)
          else
            local opt = p.optional and "?" or ""
            table.insert(params_parts, p.name .. opt .. ": " .. ptype)
          end
        end
        local params_str = table.concat(params_parts, ", ")

        local ret_str = ""
        if #method.returns > 0 then
          local ret_types: {string} = {}
          for _, r in ipairs(method.returns) do
            if r.description ~= "type" then
              table.insert(ret_types, convert_type(r.return_type))
            end
          end
          if #ret_types > 0 then
            ret_str = ": " .. table.concat(ret_types, ", ")
          end
        end

        table.insert(out, "  " .. method.name .. ": function(" .. params_str .. ")" .. ret_str)
      end
      table.insert(out, "end")
      table.insert(out, "")
    end
  end

  -- Generate main module record
  table.insert(out, "local record " .. module.name)

  -- Constants
  if #module.constants > 0 then
    for _, c in ipairs(module.constants) do
      -- Constant description
      if #c.description > 0 then
        for _, line in ipairs(format_description(c.description, "  ")) do
          table.insert(out, line)
        end
      end
      table.insert(out, "  " .. c.name .. ": " .. convert_type(c.const_type))
    end
    if #module.functions > 0 then
      table.insert(out, "")
    end
  end

  -- Functions
  for _, func in ipairs(module.functions) do
    -- Function description
    if #func.description > 0 then
      for _, line in ipairs(format_description(func.description, "  ")) do
        table.insert(out, line)
      end
    end
    local params_parts: {string} = {}
    for _, p in ipairs(func.params) do
      local ptype = convert_type(p.param_type)
      -- Handle variadic params (named "...")
      if p.name == "..." then
        table.insert(params_parts, "...: " .. ptype)
      else
        local opt = p.optional and "?" or ""
        table.insert(params_parts, p.name .. opt .. ": " .. ptype)
      end
    end
    local params_str = table.concat(params_parts, ", ")

    local ret_str = ""
    if #func.returns > 0 then
      local ret_types: {string} = {}
      for _, r in ipairs(func.returns) do
        if r.description ~= "type" then
          table.insert(ret_types, convert_type(r.return_type))
        end
      end
      if #ret_types > 0 then
        ret_str = ": " .. table.concat(ret_types, ", ")
      end
    end

    table.insert(out, "  " .. func.name .. ": function(" .. params_str .. ")" .. ret_str)
  end

  table.insert(out, "end")
  table.insert(out, "")
  table.insert(out, "return " .. module.name)
  table.insert(out, "")

  return table.concat(out, "\n")
end

local record Result
  success: boolean
  output: string
  error: string
end

--- Run the generator for a specific module or all modules.
local function run(module_name: string): Result
  -- Read definitions.lua from the embedded zip
  local source = cosmo.Slurp("/zip/.lua/definitions.lua")
  if not source then
    return {success = false, error = "Failed to read /zip/.lua/definitions.lua"}
  end

  if module_name then
    -- Generate for a specific module
    local found = false
    for _, m in ipairs(MODULES) do
      if m == module_name then
        found = true
        break
      end
    end
    if not found then
      return {success = false, error = "Unknown module: " .. module_name}
    end

    local module = parse_module(source, module_name)
    if not module then
      return {success = false, error = "Failed to parse module: " .. module_name}
    end

    local output = generate_dtl(module)
    return {success = true, output = output}
  else
    -- Generate for all modules
    local outputs: {string} = {}
    for _, m in ipairs(MODULES) do
      local module = parse_module(source, m)
      if module then
        table.insert(outputs, "-- === " .. m .. " ===")
        table.insert(outputs, generate_dtl(module))
      end
    end
    return {success = true, output = table.concat(outputs, "\n")}
  end
end

--- Get list of modules to generate.
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
  generate_dtl = generate_dtl,
  convert_type = convert_type,
  get_modules = get_modules,
  MODULES = MODULES,
}

-- Main entry point when run as script
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
