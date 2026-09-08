--- Lexical replacement-template instantiation. Metavariables are code
--- tokens: lookalikes inside strings and comments stay literal.
local function long_open(text: string, at: integer): string | nil, integer
  if text:sub(at, at) ~= "[" then
    return nil, at
  end
  local i = at + 1
  while text:sub(i, i) == "=" do
    i = i + 1
  end
  if text:sub(i, i) == "[" then
    return "]" .. text:sub(at + 1, i - 1) .. "]", i
  end
  return nil, at
end

--- Substitute `$NAME` and `$$$NAME` only in template code.
--- `values` is keyed by matcher-desugared names (`_NAME`/`___NAME`).
--- @param template string Replacement template in surface syntax
--- @param values {string: string} Capture source bytes by desugared name
--- @return string Instantiated source
--- @return {string: integer} Use count by desugared name
local function instantiate(template: string,
    values: {string: string}): string, {string: integer}
  local out: {string} = {}
  local uses: {string: integer} = {}
  local i = 1
  while i <= #template do
    local c = template:sub(i, i)
    if c == "'" or c == '"' then
      local quote = c
      local j = i + 1
      while j <= #template do
        local q = template:sub(j, j)
        if q == "\\" then
          j = j + 2
        elseif q == quote then
          j = j + 1
          break
        else
          j = j + 1
        end
      end
      out[#out + 1] = template:sub(i, j - 1)
      i = j
    elseif template:sub(i, i + 1) == "--" then
      local close, open_end = long_open(template, i + 2)
      if close then
        local _, b = template:find(close, open_end + 1, true)
        local j = b and b + 1 or #template + 1
        out[#out + 1] = template:sub(i, j - 1)
        i = j
      else
        local nl = template:find("\n", i + 2, true)
        local j = nl or #template + 1
        out[#out + 1] = template:sub(i, j - 1)
        i = j
      end
    else
      local close, open_end = long_open(template, i)
      if close then
        local _, b = template:find(close, open_end + 1, true)
        local j = b and b + 1 or #template + 1
        out[#out + 1] = template:sub(i, j - 1)
        i = j
      elseif c == "$" then
        local dollars = template:sub(i, i + 2) == "$$$" and 3 or 1
        local a = i + dollars
        local first = template:sub(a, a)
        if first:match("[%u_]") then
          local j = a + 1
          while template:sub(j, j):match("[%w_]") do
            j = j + 1
          end
          local name = (dollars == 3 and "___" or "_")
          .. template:sub(a, j - 1)
          local value = values[name]
          if value ~= nil then
            out[#out + 1] = value
            uses[name] = (uses[name] or 0) + 1
          else
            out[#out + 1] = template:sub(i, j - 1)
          end
          i = j
        else
          out[#out + 1] = c
          i = i + 1
        end
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end
  return table.concat(out), uses
end

local record TemplateModule
  instantiate: function(string, {string: string}): string, {string: integer}
end

local M: TemplateModule = {instantiate = instantiate}
return M
