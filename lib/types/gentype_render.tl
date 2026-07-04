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
  -- Variadic type (`string...`): convert the base, keep the ellipsis.
  local va_base = t:match("^(.+)%.%.%.$")
  if va_base then return convert_type(va_base) .. "..." end
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
  if k and v then return "{" .. convert_type(k) .. ": " .. convert_type(v) .. "}" end
  local fun_args, fun_ret = t:match("^fun%((.*)%)%s*:%s*(.+)$")
  if not fun_args then
    fun_args = t:match("^fun%((.*)%)$")
  end
  if fun_args then
    -- Convert each `name: type` argument's type (LuaLS `integer` etc. are not
    -- valid Teal). Split on top-level commas only.
    local converted: {string} = {}
    local depth = 0
    local cur = ""
    local function flush()
      local part = cur:match("^%s*(.-)%s*$")
      if part ~= "" then
        local aname, atype = part:match("^([%w_%.]+%??)%s*:%s*(.+)$")
        if aname then
          table.insert(converted, aname .. ": " .. convert_type(atype))
        elseif part == "..." then
          table.insert(converted, "...: any")
        else
          table.insert(converted, part)
        end
      end
      cur = ""
    end
    for i = 1, #fun_args do
      local c = fun_args:sub(i, i)
      if c == "<" or c == "{" or c == "(" then depth = depth + 1
      elseif c == ">" or c == "}" or c == ")" then depth = depth - 1
      end
      if c == "," and depth == 0 then flush() else cur = cur .. c end
    end
    flush()
    local sig = "function(" .. table.concat(converted, ", ") .. ")"
    if fun_ret then
      sig = sig .. ": " .. convert_type(fun_ret)
    end
    return sig
  end
  if t:match("|") then
    local parts: {string} = {}
    local seen: {string: boolean} = {}
    for part in t:gmatch("[^|]+") do
      part = part:match("^%s*(.-)%s*$")
      if part ~= "nil" and part ~= "" then
        local converted = convert_type(part)
        if not seen[converted] then
          seen[converted] = true
          table.insert(parts, converted)
        end
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
  if module.name == "cosmo" then
    table.insert(out, "-- type declarations for cosmo")
  else
    table.insert(out, "-- type declarations for cosmo." .. module.name)
  end
  table.insert(out, "-- GENERATED from cosmopolitan's definitions.lua by lib/types/gentype.tl.")
  table.insert(out, "-- Do not edit by hand. Regenerate with: bin/make regen-types")
  table.insert(out, "")

  -- Every class renders, even when empty: an opaque userdata handle (e.g.
  -- argon2.Variant) is still referenced from signatures.
  for _, cls in ipairs(module.classes) do
    do
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
          -- Nothing may follow a Teal vararg return, so skip the Errno fold.
          if method.fallible and #ret_types > 0 and
            not ret_types[#ret_types]:match("%.%.%.$") then
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

  -- Export each class type on the module record so consumers can name it
  -- (e.g. `local db: lsqlite3.Database`). A class whose name is also a module
  -- function (e.g. the `unix.Sigset` constructor) or constant keeps the value
  -- binding; the alias would collide.
  local taken: {string: boolean} = {}
  for _, f in ipairs(module.functions) do taken[f.name] = true end
  for _, c in ipairs(module.constants) do taken[c.name] = true end
  local aliased = 0
  for _, cls in ipairs(module.classes) do
    if not taken[cls.name] then
      table.insert(out, "  type " .. cls.name .. " = " .. cls.name)
      aliased = aliased + 1
    end
  end
  if aliased > 0 and (#module.constants > 0 or #module.functions > 0) then
    table.insert(out, "")
  end

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
      -- Nothing may follow a Teal vararg return, so skip the Errno fold.
      if func.fallible and #ret_types > 0 and
        not ret_types[#ret_types]:match("%.%.%.$") then
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
--- Selects, line-based: (1) the `<mod> = { ... }` table section, with brace
--- depth counted only outside comments (a stray `}` in a doc comment must not
--- terminate the table early); (2) every annotation block followed by a
--- `function <mod>.<name>(` or `function <mod>.<Class>:<method>(` declaration,
--- wherever it appears in the file; (3) every standalone `---@class <mod>.*`
--- data-class block. Blocks belonging to other modules never leak in, so no
--- boundary heuristics are needed.
local function extract_module_content(source: string, module_name: string): string
  local lines: {string} = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    table.insert(lines, line)
  end

  -- 1) module table section
  local start_idx: integer = nil
  for idx, line in ipairs(lines) do
    if line:match("^" .. module_name .. "%s*=%s*{") then
      start_idx = idx
      break
    end
  end
  if not start_idx then return nil end

  local out: {string} = {}
  local depth = 0
  local table_end = start_idx
  for idx = start_idx, #lines do
    local code = lines[idx]:gsub("%-%-.*$", "")
    for brace in code:gmatch("[{}]") do
      depth = depth + (brace == "{" and 1 or -1)
    end
    table.insert(out, lines[idx])
    table_end = idx
    if depth <= 0 then break end
  end

  -- 2) + 3) annotation blocks and declarations for this module
  local fn_pattern = "^function%s+" .. module_name .. "%."
  local class_pattern = "^%-%-%-@class%s+" .. module_name .. "%."
  local pending: {string} = {}
  local function flush_standalone_class()
    local is_class = false
    for _, a in ipairs(pending) do
      if a:match(class_pattern) then
        is_class = true
        break
      end
    end
    if is_class then
      for _, a in ipairs(pending) do table.insert(out, a) end
      table.insert(out, "")
    end
    pending = {}
  end

  for idx = 1, #lines do
    if idx >= start_idx and idx <= table_end then
      pending = {}
    else
      local line = lines[idx]
      if line:match("^%-%-%-") then
        table.insert(pending, line)
      elseif line:match(fn_pattern) then
        for _, a in ipairs(pending) do table.insert(out, a) end
        table.insert(out, line)
        pending = {}
      else
        flush_standalone_class()
      end
    end
  end
  flush_standalone_class()

  return table.concat(out, "\n")
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
