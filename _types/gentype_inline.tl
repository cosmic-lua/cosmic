--- Inline table forms gentype's type conversion can render.
--- LuaLS writes a positional record inline (`{ [1]: string, [2]: string? }`),
--- and a list of them by suffixing `[]`. Teal has no inline struct type, so
--- most of those forms degrade to `any` — but a positional struct whose
--- members all carry one type IS an array, and renders as one.
--- Lives in its own file so _types/gentype_render.tl stays under the
--- 500-line cap.

--- One member's Teal type: the `[n]:` label and the optional marker are
--- notation, not part of the type.
--- @param member string One comma-separated piece of a positional struct body
--- @param convert function(string): string gentype's LuaLS-to-Teal conversion
--- @return string The member's Teal type
local function member_type(member: string, convert: function(string): string): string
  local labelled = member:match("^%s*%[%d+%]%s*:%s*(.-)%s*$")
  local raw = labelled or member:match("^%s*(.-)%s*$")
  return convert((raw:gsub("%s*%?$", "")))
end

--- The Teal type for an inline positional struct, or for a list of them.
---
--- Two forms are recognised and everything else is left to the caller:
--- a bracketed struct array (`{...}[]`), which is the element type wrapped
--- in a Teal array, and a positional struct (`{ [1]: T, [2]: U? }`), which
--- is an array of T when every member converts to T. Members that disagree
--- have no honest rendering — Teal has no tuple type — so they are declined
--- rather than flattened onto whichever member came first.
--- @param t string The LuaLS type, already trimmed
--- @param convert function(string): string gentype's LuaLS-to-Teal conversion
--- @return string | nil The Teal type, or nil when t is neither form
local function inline_array(t: string, convert: function(string): string): string | nil
  local struct_array = t:match("^({.*})%[%]$")
  if struct_array then
    return "{" .. convert(struct_array) .. "}"
  end
  local body = t:match("^{%s*%[1%]%s*:%s*(.+)}$")
  if not body then
    return nil
  end
  local element: string = nil
  for member in body:gmatch("[^,]+") do
    local converted = member_type(member, convert)
    if element and element ~= converted then
      return nil
    end
    element = converted
  end
  if not element then
    return nil
  end
  return "{" .. element .. "}"
end

local record gentype_inline
  inline_array: function(t: string, convert: function(string): string): string | nil
end

local M: gentype_inline = {
  inline_array = inline_array,
}

return M
