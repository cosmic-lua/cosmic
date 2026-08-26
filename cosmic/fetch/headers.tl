--- Response-header normalization for the cosmic.fetch module.
--- cosmo.Fetch/FetchStream return headers with original-case names, and
--- repeatable headers (Vary, Cache-Control, ...) arrive as nested array
--- tables even though the binding declares {string: string}. This chunk
--- flattens that into two honest views in one pass:
--- - headers: lowercase names, repeated values joined ", " (RFC 9110 §5.3)
--- - raw_headers: lowercase names, every value in arrival order

--- Normalize a raw header table from cosmo.Fetch/FetchStream.
--- @param raw {string: any} headers as returned by the C binding, or nil
--- @return {string: string} lowercase names; repeats joined with ", "
--- @return {string: {string}} lowercase names; all values in order
local function normalize(raw: {string: any}): {string: string}, {string: {string}}
  local headers: {string: string} = {}
  local raw_headers: {string: {string}} = {}
  if raw then
    for name, value in pairs(raw) do
      local key = string.lower(name)
      local list = raw_headers[key]
      if not list then
        list = {}
        raw_headers[key] = list
      end
      if value is {string} then
        for _, v in ipairs(value) do
          table.insert(list, v)
        end
      elseif value is string then
        table.insert(list, value)
      else
        table.insert(list, tostring(value))
      end
    end
    for key, list in pairs(raw_headers) do
      headers[key] = table.concat(list, ", ")
    end
  end
  return headers, raw_headers
end

local record FetchHeadersModule
  normalize: function(raw: {string: any}): {string: string}, {string: {string}}
end

local M: FetchHeadersModule = {
  normalize = normalize,
}

return M
