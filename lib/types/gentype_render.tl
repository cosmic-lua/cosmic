--- Rendering functions for gentype.
--- Generates Teal .d.tl content from parsed module declarations.
local gt = require("types.gentype_types")
local Param = gt.Param
local FuncDecl = gt.FuncDecl
local Constant = gt.Constant
local ClassDecl = gt.ClassDecl
local ModuleDecl = gt.ModuleDecl

-- Type conversion from LuaLS to Teal
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

--- Convert a LuaLS type to Teal type.
local function convert_type(t: string): string
  if not t or t == "" then return "any" end
  t = t:match("^%s*(.-)%s*$")
  -- A type fully wrapped in parentheses (LuaLS groups unions this way, e.g.
  -- `(true | string)`) is unwrapped and converted on its own. Guard against
  -- `fun(...)` which also contains parens but never starts with one.
  local grouped = t:match("^%((.+)%)$")
  if grouped then return convert_type(grouped) end
  if t:match("^{%s*[%w_]+%s*:%s*") then return "any" end
  if t:match("`") then return "any" end
  if TYPE_ALIASES[t] then return TYPE_ALIASES[t] end
  if t == "true" or t == "false" then return "boolean" end
  if t:match("^%-?%d+$") then return "number" end
  if t == "integer" then return "number" end
  local base = t:match("^(.+)%?$")
  if base then
    if base:match("|") then
      local table_count = 0
      for part in base:gmatch("[^|]+") do
        part = part:match("^%s*(.-)%s*$")
        if part:match("^[%u]") or part:match("%.([%u][%w_]*)$") then
          table_count = table_count + 1
        end
      end
      if table_count > 1 then return "any" end
    end
    return convert_type(base) .. " | nil"
  end
  base = t:match("^(.+)%[%]$")
  if base then return "{" .. convert_type(base) .. "}" end
  local k, v = t:match("^table<([^,]+),%s*(.+)>$")
  if k and v then return "{" .. convert_type(k) .. ":" .. convert_type(v) .. "}" end
  local fun_match = t:match("^fun%((.*)%)$")
  if fun_match then return "function(" .. fun_match .. ")" end
  fun_match = t:match("^fun%((.*)%):(.+)$")
  if fun_match then
    local args, ret = t:match("^fun%((.*)%):(.+)$")
    return "function(" .. (args or "") .. "): " .. convert_type(ret or "")
  end
  if t:match("^fun%(") then
    local inside = t:match("^fun%((.*)%):%s*(.+)$")
    if inside then
      local args_part, ret_part = t:match("^fun%((.*)%):%s*(.+)$")
      return "function(" .. (args_part or "") .. "): " .. convert_type(ret_part or "")
    end
    inside = t:match("^fun%((.*)%)$")
    if inside then return "function(" .. inside .. ")" end
  end
  if t:match("|") then
    local parts: {string} = {}
    for part in t:gmatch("[^|]+") do
      part = part:match("^%s*(.-)%s*$")
      if part ~= "nil" and part ~= "" then
        table.insert(parts, convert_type(part))
      end
    end
    if #parts == 0 then return "any"
    elseif #parts == 1 then return parts[1]
    else return table.concat(parts, " | ") end
  end
  local prefix, suffix = t:match("^([%w_]+)%.([%w_]+)$")
  if prefix and suffix then return suffix end
  return t
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
  table.insert(out, "-- type declarations for cosmo." .. module.name)
  table.insert(out, "")

  for _, cls in ipairs(module.classes) do
    if #cls.methods > 0 or #cls.fields > 0 then
      for _, line in ipairs(format_description(cls.description, "")) do
        table.insert(out, line)
      end
      table.insert(out, "local record " .. cls.name)

      for _, field in ipairs(cls.fields) do
        if #field.description > 0 then
          for _, line in ipairs(format_description(field.description, "  ")) do
            table.insert(out, line)
          end
        end
        local ftype = convert_type(field.field_type)
        table.insert(out, "  " .. field.name .. ": " .. ftype)
      end

      if #cls.fields > 0 and #cls.methods > 0 then
        table.insert(out, "")
      end

      for _, method in ipairs(cls.methods) do
        if #method.description > 0 then
          for _, line in ipairs(format_description(method.description, "  ")) do
            table.insert(out, line)
          end
        end
        local params_parts: {string} = {"self: " .. cls.name}
        for _, p in ipairs(method.params) do
          local ptype = convert_type(p.param_type)
          if p.name == "..." then
            table.insert(params_parts, "...: " .. ptype)
          else
            local opt = p.optional and "?" or ""
            table.insert(params_parts, p.name .. opt .. ": " .. ptype)
          end
        end
        local params_str = table.concat(params_parts, ", ")

        local ret_str = ""
        do
          local ret_types: {string} = {}
          for _, r in ipairs(method.returns) do
            if r.description ~= "type" then
              table.insert(ret_types, convert_type(r.return_type))
            end
          end
          if method.fallible and #ret_types > 0 then
            local et = convert_type(method.error_type or "unix.Errno")
            if ret_types[#ret_types] ~= et then
              table.insert(ret_types, et)
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

  table.insert(out, "local record " .. module.name)

  if #module.constants > 0 then
    for _, c in ipairs(module.constants) do
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

  for _, func in ipairs(module.functions) do
    if #func.description > 0 then
      for _, line in ipairs(format_description(func.description, "  ")) do
        table.insert(out, line)
      end
    end
    local params_parts: {string} = {}
    for _, p in ipairs(func.params) do
      local ptype = convert_type(p.param_type)
      if p.name == "..." then
        table.insert(params_parts, "...: " .. ptype)
      else
        local opt = p.optional and "?" or ""
        table.insert(params_parts, p.name .. opt .. ": " .. ptype)
      end
    end
    local params_str = table.concat(params_parts, ", ")

    local ret_str = ""
    do
      local ret_types: {string} = {}
      for _, r in ipairs(func.returns) do
        if r.description ~= "type" then
          table.insert(ret_types, convert_type(r.return_type))
        end
      end
      if func.fallible and #ret_types > 0 then
        local et = convert_type(func.error_type or "unix.Errno")
        if ret_types[#ret_types] ~= et then
          table.insert(ret_types, et)
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

--- Extract a module's content from definitions.lua.
local function extract_module_content(source: string, module_name: string): string
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

  local content = source:sub(start_pos, end_pos)

  local search_start = end_pos
  local first_func = source:find("\nfunction " .. module_name .. "%.", search_start)
  if first_func then
    content = content .. source:sub(end_pos, first_func - 1)
    search_start = first_func
  end

  while true do
    local func_start = source:find("\nfunction " .. module_name .. "%.", search_start)
    if not func_start then break end

    local next_module_start = source:find("\n[%w_]+ = {", func_start + 1)
    if next_module_start and func_start > next_module_start then
      break
    end

    local func_end = source:find("\nfunction ", func_start + 1)
    local next_module = next_module_start

    if func_end and next_module then
      func_end = math.min(func_end, next_module)
    elseif next_module then
      func_end = next_module
    end

    if func_end then
      content = content .. "\n" .. source:sub(func_start, func_end - 1)
      search_start = func_end
    else
      content = content .. "\n" .. source:sub(func_start)
      break
    end
  end

  return content
end

local record GentypeRenderModule
  generate_dtl: function(module: ModuleDecl): string
  convert_type: function(t: string): string
  extract_module_content: function(source: string, module_name: string): string
end

local M: GentypeRenderModule = {
  generate_dtl = generate_dtl,
  convert_type = convert_type,
  extract_module_content = extract_module_content,
}

return M
