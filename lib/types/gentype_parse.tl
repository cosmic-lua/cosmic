--- Annotation-block parsing for gentype.
--- Splits `@param`/`@return` text into types and descriptions and parses a
--- LuaLS annotation block into structured declarations.
local gt = require("types.gentype_types")
local Param = gt.Param
local Return = gt.Return
local Field = gt.Field

--- Consume one type token from the head of `s`, treating whitespace inside
--- balanced (), {}, <> as part of the token (inline table types such as
--- `{ useoutput: boolean }?` and grouped unions carry internal spaces).
--- Returns the token and the remaining (trimmed) text.
local function scan_token(s: string): string, string
  local depth = 0
  local stop = 0
  for k = 1, #s do
    local c = s:sub(k, k)
    if c == "(" or c == "{" or c == "<" then
      depth = depth + 1
    elseif c == ")" or c == "}" or c == ">" then
      depth = depth - 1
    elseif c:match("%s") and depth == 0 then
      break
    end
    stop = k
  end
  if stop > 0 then
    return s:sub(1, stop), s:sub(stop + 1):match("^%s*(.-)%s*$")
  end
  return s, ""
end

--- Split the text following an `@param name` (or a `@return` entry) into its
--- type and trailing description. `fun(...)` types get their optional `?` and
--- `: <ret>` return annotation folded into the type token; the return itself
--- may be a braced or grouped type with internal spaces.
local function split_type_desc(rest: string): string, string
  if rest:match("^fun%(") then
    local depth = 0
    for k = 1, #rest do
      local c = rest:sub(k, k)
      if c == "(" then
        depth = depth + 1
      elseif c == ")" then
        depth = depth - 1
        if depth == 0 then
          local head = rest:sub(1, k)
          local after = rest:sub(k + 1)
          local q = after:match("^%?") and "?" or ""
          after = after:sub(#q + 1)
          local colon = after:match("^:%s*")
          if colon then
            after = after:sub(#colon + 1)
            local ret: string
            if after:match("^%.%.%.") then
              -- A typed vararg return (`fun(...): ...: string|nil`).
              ret = after:match("^(%.%.%.:%s*[^%s]+)") or "..."
              after = after:sub(#ret + 1)
            else
              ret, after = scan_token(after)
            end
            return head .. ": " .. ret .. q, after:match("^%s*(.-)%s*$")
          end
          return head .. q, after:match("^%s*(.-)%s*$")
        end
      end
    end
  end
  return scan_token(rest)
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
          -- Split into another return only when the comma is followed by a
          -- genuine type token: a builtin type name or a module-dotted type
          -- (`unix.Errno`). Prose in a trailing description ("ARIN, APNIC,
          -- DOD, etc.") must stay in the description.
          local rest_after_comma = full_return:sub(i + 1)
          local next_word = rest_after_comma:match("^%s*([%w_%.]+)")
          local builtin_types: {string: boolean} = {
            ["integer"] = true, ["string"] = true, ["number"] = true,
            ["boolean"] = true, ["any"] = true, ["nil"] = true,
            ["table"] = true, ["function"] = true, ["userdata"] = true,
            ["uint32"] = true, ["uint16"] = true, ["int64"] = true,
            ["true"] = true, ["false"] = true, ["fun"] = true,
          }
          local is_type_token = false
          if next_word then
            local first = next_word:match("^([%w_]+)")
            if first and builtin_types[first] then
              is_type_token = true
            elseif next_word:match("^[%l_][%w_]*%.[%w_]") then
              is_type_token = true
            end
          end
          if is_type_token then
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
        part_type, part_desc = split_type_desc(return_part)
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

    -- A failure overload's return list starts with `nil`; the error value
    -- follows, optionally labeled (`nil, error: string`, `nil, errno:
    -- integer`, `nil, unix.Errno`). Success-variant overloads (e.g. a
    -- useoutput=true encoding overload returning `true`) must not trigger.
    local overload_ret = line:match("^%-%-%-@overload%s+fun%b()%s*:%s*(.+)$")
    if overload_ret then
      local after_nil = overload_ret:match("^nil%s*,%s*(.+)$")
      if after_nil then
        local et = after_nil:match("^[%w_]+:%s*([%w_%.]+)") or after_nil:match("^([%w_%.]+)")
        if et then
          fallible = true
          error_type = et
        end
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
