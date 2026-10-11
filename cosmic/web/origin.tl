--- Origins as [`cosmic.web.csrf`] and [`cosmic.web.cors`] compare them: the
--- `scheme://host[:port]` a browser sends in its Origin header, and the one a
--- `Referer` or the request itself names, each reduced to one spelling so
--- that two names of one origin are equal and nothing else is.

local Types = require("cosmic.web.types")

local record Origin
end

local DEFAULT_PORT <const>: {string:string} = { http = "80", https = "443" }

--- The longest origin read: a browser's is far shorter.
local MAX_LENGTH <const> = 300

--- `scheme://authority` reduced to one spelling, or nil: an http or https
--- scheme, a host of labels of letters, digits, dashes and underscores
--- (docker-compose names have them) joined by dots, none empty or starting or
--- ending in a dash (or a bracketed IP literal), an optional port from 1 to 65535, in lowercase, the scheme's
--- default port dropped.
local function reduce(scheme: string, authority: string): string | nil
  scheme = scheme:lower()
  if DEFAULT_PORT[scheme] == nil then return nil end
  local host, port = authority:match("^(%[[%x:.]+%])(:%d+)$")
  if host == nil then host = authority:match("^(%[[%x:.]+%])$") end
  if host == nil then
    host, port = authority:match("^([%w._-]+)(:%d+)$")
    if host == nil then host = authority:match("^([%w._-]+)$") end
  end
  if host == nil or host == "" then return nil end
  if host:sub(1, 1) ~= "[" then
    for label in (host .. "."):gmatch("([^.]*)%.") do
      if label == "" or label:find("^%-") or label:find("%-$") then return nil end
    end
  end
  local number: string = nil
  if port ~= nil then
    local n = tonumber(port:sub(2))
    if n == nil or n < 1 or n > 65535 or #port > 6 then return nil end
    number = tostring(math.tointeger(n))
  end
  if number == DEFAULT_PORT[scheme] then number = nil end
  return scheme .. "://" .. host:lower() .. (number ~= nil and (":" .. number) or "")
end

--- `text` as an origin in one spelling: it must be exactly an origin, with
--- no userinfo, path, query or fragment. Nil for anything else, for "null"
--- and for a value a client repeated (the server joins repeated headers with
--- ", ").
--- @param text string An Origin header, or an origin an app lists
--- @return string | nil The origin, "http://example.com:8080"
function Origin.normalize(text: string): string | nil
  if #text > MAX_LENGTH then return nil end
  local scheme, authority = text:match("^(%a[%w+.-]*)://([^/?#@%s,]*)$")
  if scheme == nil then return nil end
  return reduce(scheme, authority)
end

--- The origin of the URL `text`, which may have a path, a query and a
--- fragment (a `Referer`); nil where it names none, or carries userinfo.
--- @param text string The URL
--- @return string | nil The origin, in [`Origin.normalize`]'s spelling
function Origin.of_url(text: string): string | nil
  if #text > 8192 then return nil end
  local scheme, authority = text:match("^(%a[%w+.-]*)://([^/?#]*)")
  if scheme == nil or authority:find("[@%s,]") then return nil end
  return reduce(scheme, authority)
end

--- The origin the request was made to: its scheme and `Host` (or the
--- proxy's, with `trusted_proxy`). Nil where the request named no host.
--- @param req Types.Request The request
--- @return string | nil The origin
function Origin.of_request(req: Types.Request): string | nil
  if req.host == nil then return nil end
  return reduce(req.scheme, req.host)
end

return Origin
