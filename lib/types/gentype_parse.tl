--- Annotation-block parsing for gentype.
--- Splits `@param`/`@return` text into types and descriptions and parses a
--- LuaLS annotation block into structured declarations.
local gt = require("types.gentype_types")
local Param = gt.Param
local Return = gt.Return
local Field = gt.Field

--- Split the text following an `@param name` (or a `@return` entry) into its
--- type and trailing description. Handles parenthesized union types such as
--- `(integer | string)?` whose internal spaces would otherwise truncate the
--- type at the first whitespace.
local function split_type_desc(rest: string): string, string
  if rest:sub(1, 1) == "(" then
    local depth = 0
    for k = 1, #rest do
      local c = rest:sub(k, k)
      if c == "(" then
        depth = depth + 1
      elseif c == ")" then
        depth = depth - 1
        if depth == 0 then
          local after = rest:sub(k + 1)
          local q = after:match("^%?") and "?" or ""
          local desc = after:sub(#q + 1):match("^%s*(.-)%s*$")
          return rest:sub(1, k) .. q, desc
        end
      end
    end
  end
  -- `fun(...)` types carry internal spaces; scan to the balanced close paren,
  -- then take an optional `?` and an optional `: <ret>` return annotation.
  if rest:match("^fun%(") then
    local depth = 0
    for k = 1, #rest do
      local c = rest:sub(k, k)
      if c == "(" then
        depth = depth + 1
      elseif c == ")" then
        depth = depth - 1
        if depth == 0 then
          local stop = k
          local after = rest:sub(k + 1)
          local q = after:match("^%?") and "?" or ""
          after = after:sub(#q + 1)
          local ret = after:match("^:%s*([^%s]+)")
          if ret then
            local ret_at = after:find(ret, 1, true)
            after = after:sub(ret_at + #ret)
            return rest:sub(1, stop) .. ": " .. ret .. q, after:match("^%s*(.-)%s*$")
          end
          return rest:sub(1, stop) .. q, after:match("^%s*(.-)%s*$")
        end
      end
    end
  end
  local t, d = rest:match("^([^%s]+)%s*(.-)%s*$")
  return t or rest, d or ""
end

--- Parse annotations from a block of text before a declaration.
local function parse_annotations(raw_lines: {string}): {string}, {Param}, {Return}, boolean, string, {Field}, boolean, string
  local desc: {string} = {}
  local params: {Param} = {}
  local returns: {Return} = {}
  local fields: {Field} = {}
  local nodiscard = false
  local class_annotation: string = nil
  -- Annotations inside a module table (constants, @type fields) are indented;
  -- strip leading whitespace so the anchored tag patterns below see them.
  local lines: {string} = {}
  local generics: {string: boolean} = {}
  for _, raw in ipairs(raw_lines) do
    table.insert(lines, raw:match("^%s*(%-%-%-.*)$") or raw)
  end
  -- A fallible function's failure return is expressed upstream as an
  -- `@overload fun(...): nil, <error> unix.Errno`. LuaLS renders that as a
  -- second signature; the generator instead folds it into a trailing `, Errno`
  -- return so callers see `value, Errno`. Detect any overload whose return list
  -- carries an Errno type.
  local fallible = false
  local error_type: string = nil

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

    local pname, prest = line:match("^%-%-%-@param%s+([%w_%.%?]+)%s+(.+)$")
    if pname then
      local ptype, pdesc = split_type_desc(prest)
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
      local in_paren = 0
      local current = ""
      for i = 1, #full_return do
        local c = full_return:sub(i, i)
        if c == "<" then in_angle = in_angle + 1
        elseif c == ">" then in_angle = in_angle - 1
        elseif c == "{" then in_brace = in_brace + 1
        elseif c == "}" then in_brace = in_brace - 1
        elseif c == "(" then in_paren = in_paren + 1
        elseif c == ")" then in_paren = in_paren - 1
        end
        if c == "," and in_angle == 0 and in_brace == 0 and in_paren == 0 then
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
        -- A variadic return (`@return string ... desc`) is rendered as a Teal
        -- vararg return type. Nothing can follow a vararg, so stop here.
        local va_type = return_part:match("^([%w_%.]+)%s+%.%.%.") or
          (return_part == "..." and "any" or nil)
        if va_type then
          table.insert(returns, {return_type = va_type .. "...", description = ""})
          break
        end
        if return_part:match("^%(") then
          part_type, part_desc = split_type_desc(return_part)
        elseif return_part:match("^{") then
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

    local gname = line:match("^%-%-%-@generic%s+([%w_]+)")
    if gname then
      generics[gname] = true
    end

    local overload_ret = line:match("^%-%-%-@overload%s+fun%b()%s*:%s*(.+)$")
    if overload_ret then
      local et = overload_ret:match("([%w_]+%.Errno)") or overload_ret:match("(Errno)")
      if et then
        fallible = true
        error_type = et
      end
    end

    local cname = line:match("^%-%-%-@class%s+([%w_%.]+)")
    if cname then
      class_annotation = cname
    end

    local ttype = line:match("^%-%-%-?%s*@type%s+([%w_%.]+)")
    if ttype then
      table.insert(returns, {return_type = ttype, description = "type"})
    end
  end

  -- LuaLS generics (`---@generic T`) have no Teal equivalent in a record
  -- field type; degrade each generic name to `any` wherever it appears.
  if next(generics) then
    local function degrade(t: string): string
      if not t then return t end
      for g in pairs(generics) do
        t = t:gsub("%f[%w_]" .. g .. "%f[^%w_]", "any")
      end
      return t
    end
    for _, p in ipairs(params) do p.param_type = degrade(p.param_type) end
    for _, r in ipairs(returns) do r.return_type = degrade(r.return_type) end
    for _, f in ipairs(fields) do f.field_type = degrade(f.field_type) end
  end

  return desc, params, returns, nodiscard, class_annotation, fields, fallible, error_type
end

local record GentypeParseModule
  split_type_desc: function(rest: string): string, string
  parse_annotations: function(raw_lines: {string}): {string}, {Param}, {Return}, boolean, string, {Field}, boolean, string
end

local M: GentypeParseModule = {
  split_type_desc = split_type_desc,
  parse_annotations = parse_annotations,
}

return M
