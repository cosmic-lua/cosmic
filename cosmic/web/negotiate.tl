--- Content negotiation: which of the media types a handler can make a
--- request's Accept header likes best (RFC 9110 12.5.1).

local Number = require("cosmic.number")
local String = require("cosmic.string")

local record Negotiate
  --- One media range of an Accept header with its weight.
  record Range
    --- "text", or "*".
    kind: string
    --- "html", or "*".
    subtype: string
    --- The weight in thousandths, 0 to 1000.
    weight: integer
  end
end

local TOKEN <const> = "[%w!#$%%&'*+.^_`|~-]+"

--- The weight `text` (a `q` parameter's value) spells in thousandths, or
--- nil where it is no number from 0 to 1 with three decimals at most.
local function weight_of(text: string): integer?
  local whole, dot, fraction = text:match("^([01])(%.?)(%d*)$")
  if whole == nil or dot == nil or fraction == nil then return nil end
  if #fraction > 3 or (dot == "" and fraction ~= "") then return nil end
  local thousandths = Number.integer(whole) * 1000 +
    (if fraction == "" then 0 else Number.integer(fraction .. ("0"):rep(3 - #fraction)) end)
  if thousandths > 1000 then return nil end
  return thousandths
end

--- The ranges of `header`, in order, skipping any that is no media range
--- or has a weight that is no number. Nothing here raises on its text.
local function ranges_of(header: string): {Negotiate.Range}
  local out: mut {Negotiate.Range} = {}
  for piece in header:gmatch("[^,]+") do
    local media, rest = piece:match("^%s*([^;%s]+)(.*)$")
    if media ~= nil and rest ~= nil then
      local params = String.trim(rest)
      local kind, subtype = media:lower():match("^(" .. TOKEN .. ")/(" .. TOKEN .. ")$")
      if kind ~= nil and subtype ~= nil and not (kind == "*" and subtype ~= "*") then
        local weight: integer? = 1000
        for param in params:gmatch(";%s*([^;]*)") do
          local value = param:match("^[qQ]%s*=%s*(%S+)%s*$")
          if value ~= nil then weight = weight_of(value) end
        end
        if weight ~= nil then
          out[#out + 1] = { kind = kind, subtype = subtype, weight = weight }
        end
      end
    end
  end
  return out
end

--- The weight `ranges` give `offer`: that of the most specific range it
--- matches (an exact type, then `type/*`, then `*/*`), 0 when none does.
local function weight_for(ranges: {Negotiate.Range}, offer: string): integer
  local kind, subtype = offer:lower():match("^(" .. TOKEN .. ")/(" .. TOKEN .. ")")
  if kind == nil then return 0 end
  local best, specificity = 0, -1
  for _, range in ipairs(ranges) do
    local level = -1
    if range.kind == kind and range.subtype == subtype then
      level = 2
    elseif range.kind == kind and range.subtype == "*" then
      level = 1
    elseif range.kind == "*" then
      level = 0
    end
    if level > specificity then
      best, specificity = range.weight, level
    elseif level == specificity and level >= 0 then
      best = math.max(best, range.weight)
    end
  end
  return best
end

--- The offer `header` likes best: the highest weight above 0, ties to the
--- earlier offer; the first offer for a request that sent no Accept, an
--- empty one, or one no part of which is a media range with a valid weight
--- (read as absent, as most servers do); nil when it accepts none.
--- @param header string | nil The Accept header's value
--- @param offers {string} The media types that can be made, best first
--- @return string | nil The offer chosen
function Negotiate.best(header: string?, offers: {string}): string?
  if header == nil or header:find("^%s*$") ~= nil then return offers[1] end
  local ranges = ranges_of(header)
  if #ranges == 0 then return offers[1] end
  local chosen: string? = nil
  local top = 0
  for _, offer in ipairs(offers) do
    local weight = weight_for(ranges, offer)
    if weight > top then
      chosen, top = offer, weight
    end
  end
  return chosen
end

return Negotiate
