--- Rendering functions for gentype.
--- Generates Teal .d.tl content from parsed module declarations.
local gt = require("types.gentype_types")
local Param = gt.Param
local Return = gt.Return
local FuncDecl = gt.FuncDecl
local Constant = gt.Constant
local ClassDecl = gt.ClassDecl
local ModuleDecl = gt.ModuleDecl

-- The module currently being rendered. A dotted type reference whose prefix
-- is this module (`lsqlite3.Database` inside lsqlite3) collapses to the bare
-- class name; a foreign prefix (`unix.Errno` inside cosmo) stays dotted and
-- resolves through a `local <mod> = require("cosmo.<mod>")` emitted in the
-- file header.
local current_module: string = nil

-- Type conversion from LuaLS to Teal
local TYPE_ALIASES: {string: string} = {
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
  ["uint8"] = "number",
  ["int8"] = "number",
  ["int64"] = "number",
  -- definitions.lua declares these via ---@alias; the recursive JSON aliases
  -- have no Teal equivalent.
  ["JsonValue"] = "any",
  ["JsonEl"] = "any",
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
  -- Variadic type (`string...`): convert the base, keep the ellipsis. A bare
  -- or union-typed vararg (`...` / `...: string|nil`) degrades to `any...`.
  if t:match("^%.%.%.") then return "any..." end
  local va_base = t:match("^(.+)%.%.%.$")
  if va_base then return convert_type(va_base) .. "..." end
  -- A string-literal type (`"MD5"`) has no Teal inline equivalent.
  if t:match('^".*"$') or t:match("^'.*'$") then return "string" end
  -- LuaLS map/array table types have direct Teal equivalents.
  local map_v = t:match("^{%s*%[string%]%s*:%s*(.+)%s*}$")
  if map_v then return "{string: " .. convert_type(map_v) .. "}" end
  local arr_v = t:match("^{%s*%[integer%]%s*:%s*(.+)%s*}$")
  if arr_v then return "{" .. convert_type(arr_v) .. "}" end
  -- Other inline struct-table types (`{ name: string }`, `{ [1]: string }`)
  -- have no Teal inline equivalent.
  if t:match("^{.*:") then return "any" end
  if t:match("`") then return "any" end
  if TYPE_ALIASES[t] then return TYPE_ALIASES[t] end
  if t == "true" or t == "false" then return "boolean" end
  if t:match("^%-?%d+$") then return "number" end
  if t == "integer" then return "number" end
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
      -- Parenthesize a function type that has a return: when it appears in a
      -- param or return list, a following `, next` would otherwise parse as
      -- another return of the nested function.
      sig = "(" .. sig .. ": " .. convert_type(fun_ret) .. ")"
    end
    return sig
  end
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
  if t:match("|") then
    local parts: {string} = {}
    local seen: {string: boolean} = {}
    local has_nil = false
    for part in t:gmatch("[^|]+") do
      part = part:match("^%s*(.-)%s*$")
      if part == "nil" then
        has_nil = true
      elseif part ~= "" then
        local converted = convert_type(part)
        if not seen[converted] then
          seen[converted] = true
          table.insert(parts, converted)
        end
      end
    end
    -- A `nil` member is meaningful: `integer|nil` is how upstream marks a
    -- fallible success return, and dropping it hides the failure case from
    -- the checker. `any` already admits nil.
    local suffix = ""
    if has_nil then suffix = " | nil" end
    if #parts == 0 then return "any"
    elseif #parts == 1 then return parts[1] .. suffix
    else return table.concat(parts, " | ") .. suffix end
  end
  local prefix, suffix = t:match("^([%w_]+)%.([%w_]+)$")
  if prefix and suffix then
    if current_module and prefix ~= current_module then
      return t
    end
    return suffix
  end
  return t
end

--- Render a parameter list (optionally with a self receiver).
local function render_params(params: {Param}, self_name: string): string
  local parts: {string} = {}
  if self_name then
    table.insert(parts, "self: " .. self_name)
  end
  for _, p in ipairs(params) do
    local ptype = convert_type(p.param_type)
    if p.name == "..." then
      table.insert(parts, "...: " .. ptype)
    else
      local opt = p.optional and "?" or ""
      table.insert(parts, p.name .. opt .. ": " .. ptype)
    end
  end
  return table.concat(parts, ", ")
end

--- Render a return-type list. convert_type parenthesizes a function type
--- that itself has returns, which Teal only accepts inside a param list: in a
--- return list the LAST entry drops the parens (unambiguous) and earlier
--- entries degrade to bare `function` (Teal cannot express them).
local function render_returns(returns: {Return}, fallible: boolean, error_type: string): string
  local ret_types: {string} = {}
  for _, r in ipairs(returns) do
    if r.description ~= "type" then
      table.insert(ret_types, convert_type(r.return_type))
    end
  end
  -- A fallible function folds its failure overload into a trailing error
  -- return. Nothing may follow a Teal vararg return, so skip the fold there.
  -- A class-typed error (Errno) already present as the last @return is not
  -- duplicated; builtin error types (string) always append, since a trailing
  -- `string` return is a value, not the error slot.
  if fallible and #ret_types > 0 and not ret_types[#ret_types]:match("%.%.%.$") then
    local et = convert_type(error_type or "unix.Errno")
    if not (ret_types[#ret_types] == et and et:match("^%u")) then
      table.insert(ret_types, et)
    end
  end
  -- Honest fallibility: a fallible function returns nil on failure, so its
  -- success value must widen to `T | nil` — Teal then forces callers to narrow
  -- before use. Skip when the first return is already a nil-union (e.g. an
  -- honestly-annotated `table | nil`) or a vararg (nothing can precede it and a
  -- `T... | nil` return is not meaningful).
  if fallible and #ret_types > 0 then
    local first = ret_types[1]
    if not first:match("%.%.%.$") and first ~= "nil" and not first:find("| nil", 1, true) then
      ret_types[1] = first .. " | nil"
    end
  end
  for i, rt in ipairs(ret_types) do
    if rt:match("^%(function") then
      if i == #ret_types then
        ret_types[i] = rt:sub(2, -2)
      else
        ret_types[i] = "function"
      end
    end
  end
  if #ret_types > 0 then
    return ": " .. table.concat(ret_types, ", ")
  end
  return ""
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

--- Collect foreign module prefixes referenced from the module's types
--- (e.g. `unix.Errno` inside cosmo), so requires can be emitted for them.
local function foreign_modules(module: ModuleDecl): {string}
  local seen: {string: boolean} = {}
  local function scan(t: string)
    if not t then return end
    for prefix in t:gmatch("([%l_][%w_]*)%.[%u]") do
      if prefix ~= module.name then
        seen[prefix] = true
      end
    end
  end
  local function scan_funcs(funcs: {FuncDecl})
    for _, f in ipairs(funcs) do
      for _, p in ipairs(f.params) do scan(p.param_type) end
      for _, r in ipairs(f.returns) do scan(r.return_type) end
      if f.fallible then scan(f.error_type or "unix.Errno") end
    end
  end
  scan_funcs(module.functions)
  for _, cls in ipairs(module.classes) do
    scan_funcs(cls.methods)
    for _, f in ipairs(cls.fields) do scan(f.field_type) end
  end
  for _, c in ipairs(module.constants) do scan(c.const_type) end
  local result: {string} = {}
  for prefix in pairs(seen) do table.insert(result, prefix) end
  table.sort(result)
  return result
end

--- Generate Teal .d.tl content for a module.
local function generate_dtl(module: ModuleDecl): string
  current_module = module.name
  local out: {string} = {}
  if module.name == "cosmo" then
    table.insert(out, "-- type declarations for cosmo")
  else
    table.insert(out, "-- type declarations for cosmo." .. module.name)
  end
  table.insert(out, "-- GENERATED from cosmopolitan's definitions.lua by lib/types/gentype.tl.")
  table.insert(out, "-- Do not edit by hand. Regenerate with: bin/make regen-types")
  table.insert(out, "")

  -- Foreign class references resolve through the exporting module's record.
  local foreign = foreign_modules(module)
  for _, m in ipairs(foreign) do
    table.insert(out, "local " .. m .. " = require(\"cosmo." .. m .. "\")")
  end
  if #foreign > 0 then
    table.insert(out, "")
  end

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
        if ftype:match("^%(function") then
          ftype = ftype:sub(2, -2)
        end
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
        local params_str = render_params(method.params, cls.name)
        local ret_str = render_returns(method.returns, method.fallible, method.error_type)
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
    local params_str = render_params(func.params, nil)
    local ret_str = render_returns(func.returns, func.fallible, func.error_type)
    table.insert(out, "  " .. func.name .. ": function(" .. params_str .. ")" .. ret_str)
  end

  table.insert(out, "end")
  table.insert(out, "")
  table.insert(out, "return " .. module.name)
  table.insert(out, "")

  current_module = nil
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
