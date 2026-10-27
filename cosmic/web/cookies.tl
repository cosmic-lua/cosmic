--- Cookies for [`cosmic.web`]: reading the `Cookie` request header and
--- writing `Set-Cookie` lines that a browser keeps.
---
---     local seen = Cookies.parse(req:header("cookie"))
---     local line = assert(Cookies.format("theme", "dark", { max_age = 86400 }))
---     -- theme=dark; Path=/; Max-Age=86400; HttpOnly; SameSite=Lax
---
--- [`Cookies.format`] refuses, rather than lets a browser drop silently, a
--- name or value that is not a cookie's, a `__Host-` or `__Secure-` name
--- without the attributes its prefix needs, `SameSite=None` without
--- `Secure`, and a line over 4096 bytes. It returns `nil` and why, as any
--- failure of data does. Defaults are the safe ones: path `/`, `HttpOnly`,
--- `SameSite=Lax`, no `Domain` (a host-only cookie), and `Secure` only when
--- asked for: the function cannot know the scheme, so
--- [`cosmic.web.session`] decides it from the request.

local String = require("cosmic.string")
local Response = require("cosmic.web.response")
local Time = require("cosmic.time")
local Types = require("cosmic.web.types")

local record Cookies
  --- A cookie's [`SameSite`] value.
  enum SameSite
    "Lax"
    "Strict"
    "None"
  end

  --- What [`Cookies.format`] takes beside the name and value; every field
  --- is optional.
  record Attributes
    --- Where the cookie is sent ("/" by default); no `;`, space or control
    --- byte.
    path?: string
    --- A domain the cookie is sent to as well as its subdomains (none by
    --- default: a host-only cookie). A leading dot is dropped.
    domain?: string
    --- Its lifetime in seconds; zero or less deletes it. Nil makes a
    --- session cookie, which browsers may keep across restarts, so it is no
    --- reliable expiry.
    max_age?: integer
    --- An absolute expiry in nanoseconds since the epoch, written as
    --- `Expires` beside `Max-Age` for a client that ignores the latter
    --- (never by default).
    expires_ns?: integer
    --- Hidden from script (true by default; pass false to turn it off).
    http_only?: boolean
    --- Only sent over https (false by default).
    secure?: boolean
    --- "Lax" by default.
    same_site?: SameSite
    --- A partitioned (CHIPS) cookie; needs `secure`.
    partitioned?: boolean
  end

  --- A `Set-Cookie` line read back by [`Cookies.parse_set_cookie`]; a
  --- field the line did not give is nil, and `secure`, `http_only` and
  --- `partitioned` are false.
  record Parsed
    --- The cookie's name.
    name: string
    --- Its value, quotes kept.
    value: string
    --- `Path`; nil when absent or not an absolute path.
    path?: string
    --- `Domain`, lowercase and without a leading dot.
    domain?: string
    --- `Max-Age` in seconds.
    max_age?: integer
    --- `Expires` in nanoseconds since the epoch; nil when absent or not a
    --- date.
    expires_ns?: integer
    --- Whether `Secure` was given.
    secure: boolean
    --- Whether `HttpOnly` was given.
    http_only: boolean
    --- [`SameSite`]; nil when absent or not one of the three.
    same_site?: SameSite
    --- Whether `Partitioned` was given.
    partitioned: boolean
  end
end

--- Browsers keep at most this many bytes of a cookie line.
local MAX_LINE <const> = 4096
--- The most of a `Cookie` header [`Cookies.parse`] reads.
local MAX_HEADER <const> = 8192
--- The most cookies [`Cookies.parse`] returns.
local MAX_COOKIES <const> = 100

--- Strips spaces and tabs from both ends.
local function trim(text: string): string
  return (text:match("^[ \t]*(.-)[ \t]*$"))
end

--- The cookies in a `Cookie` header, by name. The first of a name wins
--- (browsers send the most specific path first). Pairs are split on `;`,
--- and on `,` as well: a cookie value never holds a comma, so one means a
--- sender joined several `Cookie` lines with ", ". A piece without `=` or
--- with an empty name is skipped, a value in double quotes loses them, and
--- nothing is percent-decoded. At most 100 cookies and 8 KiB of the header
--- are read. It never raises.
--- @param header string | nil The header's value
--- @return {string:string} The cookies
function Cookies.parse(header: string?): {string:string}
  local out: mut {string:string} = {}
  if header == nil or header == "" then return out end
  local text: string = header or ""
  if #text > MAX_HEADER then
    -- Cut at a separator, so a cookie is never read half.
    text = text:sub(1, MAX_HEADER)
    local last = text:find("[;,][^;,]*$")
    text = last ~= nil and text:sub(1, last - 1) or ""
  end
  local count = 0
  for piece in (text .. ";"):gmatch("([^;,]*)[;,]") do
    local name, value = piece:match("^([^=]*)=(.*)$")
    if name ~= nil then
      name = trim(name)
      value = trim(value)
      if name ~= "" and out[name] == nil then
        if #value >= 2 and value:sub(1, 1) == '"' and value:sub(-1) == '"' then
          value = value:sub(2, -2)
        end
        out[name] = value
        count = count + 1
        if count >= MAX_COOKIES then break end
      end
    end
  end
  return out
end

--- Whether `name` is an RFC 9110 token.
local function is_token(name: string): boolean
  return name ~= "" and name:find("[^%w!#$%%&'*+%-.^_`|~]") == nil
end

--- Whether `value` is made of cookie-octets (RFC 6265 4.1.1): printable
--- ASCII but not space, `"`, `,`, `;` or `\`.
local function is_cookie_value(value: string): boolean
  for i = 1, #value do
    local b = value:byte(i)
    if b < 0x21 or b > 0x7e or b == 0x22 or b == 0x2c or b == 0x3b or b == 0x5c then
      return false
    end
  end
  return true
end

--- Whether `text` is fit for a Path or Domain attribute.
local function is_attribute_value(text: string): boolean
  return text ~= "" and text:find("[%c; ]") == nil
end

--- The `Set-Cookie` line for a cookie, or nil and why: the name is no
--- token, the value holds a byte a cookie cannot, a `Path` or `Domain` is
--- unusable, `__Host-` lacks `Secure`, `Path=/` or is given a `Domain`,
--- `__Secure-` lacks `Secure`, `SameSite=None` or `Partitioned` lack
--- `Secure`, or the line is over 4096 bytes. Attributes come in a fixed
--- order: `Path`, `Max-Age`, `Expires`, `Domain`, `Secure`, `HttpOnly`,
--- [`SameSite`], `Partitioned`.
--- @param name string The cookie's name
--- @param value string The value: cookie-octets only; escape other text
--- @param attrs Cookies.Attributes | nil The attributes
--- @return string | nil The line
--- @return string Why none, or ""
function Cookies.format(name: string, value: string, attrs?: Cookies.Attributes): string?, string
  local a: Cookies.Attributes = attrs or {}
  if not is_token(name) then
    return nil, "cookies: the name is not a token"
  end
  if not is_cookie_value(value) then
    return nil, "cookies: the value of " .. name .. " holds a byte a cookie cannot (control, space, a quote, a comma, a semicolon or a backslash)"
  end
  local path = a.path or "/"
  if not is_attribute_value(path) then
    return nil, "cookies: the path of " .. name .. " holds a control byte, space or ';'"
  end
  local domain = a.domain
  if domain ~= nil then
    domain = domain:gsub("^%.", "")
    if not is_attribute_value(domain) then
      return nil, "cookies: the domain of " .. name .. " is not usable"
    end
  end
  local same_site = a.same_site or "Lax"
  if same_site ~= "Lax" and same_site ~= "Strict" and same_site ~= "None" then
    error("cookies: same_site must be Lax, Strict or None", 2)
  end
  local secure = a.secure == true
  if same_site == "None" and not secure then
    return nil, "cookies: SameSite=None needs Secure; browsers drop the cookie otherwise"
  end
  if a.partitioned == true and not secure then
    return nil, "cookies: Partitioned needs Secure"
  end
  local prefix = name:lower()
  if prefix:sub(1, 7) == "__host-" then
    if not secure or path ~= "/" or domain ~= nil then
      return nil, "cookies: " .. name .. " needs Secure, Path=/ and no Domain (a __Host- cookie)"
    end
  elseif prefix:sub(1, 9) == "__secure-" and not secure then
    return nil, "cookies: " .. name .. " needs Secure (a __Secure- cookie)"
  end
  local parts: mut {string} = { name .. "=" .. value, "Path=" .. path }
  local max_age = a.max_age
  if max_age ~= nil then
    if math.type(max_age) ~= "integer" then error("cookies: max_age must be an integer", 2) end
    parts[#parts + 1] = "Max-Age=" .. max_age
  end
  local expires_ns = a.expires_ns
  if expires_ns ~= nil then
    parts[#parts + 1] = "Expires=" .. Time.format_http(expires_ns)
  end
  if domain ~= nil then parts[#parts + 1] = "Domain=" .. domain end
  if secure then parts[#parts + 1] = "Secure" end
  if a.http_only ~= false then parts[#parts + 1] = "HttpOnly" end
  parts[#parts + 1] = "SameSite=" .. same_site
  if a.partitioned == true then parts[#parts + 1] = "Partitioned" end
  local line = table.concat(parts, "; ")
  if #line > MAX_LINE then
    return nil, ("cookies: %s would be %s; browsers keep at most %s"):format(name, String.counted(#line, "byte"),
      String.counted(MAX_LINE, "byte"))
  end
  return line, ""
end

--- A `Set-Cookie` line that deletes `name`: an empty value with
--- `Max-Age=0` and an `Expires` in 1970, for a client that ignores the
--- first. Its `path`, `domain`, `secure` and `partitioned` must be those
--- the cookie was set with, or the browser keeps it. Nil and why as
--- [`Cookies.format`].
--- @param name string The cookie's name
--- @param attrs Cookies.Attributes | nil The attributes it was set with
--- @return string | nil The line
--- @return string Why none, or ""
function Cookies.expire(name: string, attrs?: Cookies.Attributes): string?, string
  local given: Cookies.Attributes = attrs or {}
  local a: Cookies.Attributes = { path = given.path, domain = given.domain, http_only = given.http_only,
    secure = given.secure, same_site = given.same_site, partitioned = given.partitioned,
    max_age = 0, expires_ns = 0 }
  return Cookies.format(name, "", a)
end

--- Appends the line [`Cookies.format`] makes to `res` as a `Set-Cookie`
--- header, after any already there (a second cookie keeps the first).
--- Nil-and-why as `format`, with `res` unchanged.
--- @param res Types.Response The response
--- @param name string The cookie's name
--- @param value string The value
--- @param attrs Cookies.Attributes | nil The attributes
--- @return boolean Whether the cookie was added
--- @return string Why not, or ""
function Cookies.set(res: Types.Response, name: string, value: string,
                     attrs?: Cookies.Attributes): boolean, string
  local line, why = Cookies.format(name, value, attrs)
  if line == nil then return false, why end
  Response.add_header(res, "Set-Cookie", line)
  return true, ""
end

--- A `Set-Cookie` line read back as its parts, for the test client's
--- cookie jar and nothing else: it is lenient (an attribute it does not
--- know is skipped, a date it cannot read is nil) where a browser's
--- parsing is stricter in places. Nil and why for a line with no
--- `name=value`.
--- @param line string The header's value
--- @return Cookies.Parsed | nil The parts
--- @return string Why none, or ""
function Cookies.parse_set_cookie(line: string): Cookies.Parsed?, string
  local first, rest = line:match("^([^;]*)(.*)$")
  local name, value = first:match("^([^=]*)=(.*)$")
  if name == nil then return nil, "cookies: a Set-Cookie line needs name=value" end
  name = trim(name)
  if name == "" then return nil, "cookies: a Set-Cookie line needs a name" end
  local parsed: Cookies.Parsed = { name = name, value = trim(value), secure = false,
    http_only = false, partitioned = false }
  for piece in rest:gmatch(";([^;]*)") do
    local key, attr = piece:match("^([^=]*)=(.*)$")
    if key == nil then key, attr = piece, "" end
    key = trim(key):lower()
    attr = trim(attr)
    if key == "path" then
      if attr:sub(1, 1) == "/" then parsed.path = attr end
    elseif key == "domain" then
      local domain = attr:gsub("^%.", ""):lower()
      if domain ~= "" then parsed.domain = domain end
    elseif key == "max-age" then
      if attr:match("^%-?%d+$") ~= nil then
        parsed.max_age = math.tointeger(tonumber(attr))
      end
    elseif key == "expires" then
      local ns, _ = Time.parse_http(attr)
      if ns ~= nil then parsed.expires_ns = ns end
    elseif key == "secure" then
      parsed.secure = true
    elseif key == "httponly" then
      parsed.http_only = true
    elseif key == "partitioned" then
      parsed.partitioned = true
    elseif key == "samesite" then
      local lower = attr:lower()
      if lower == "lax" then
        parsed.same_site = "Lax"
      elseif lower == "strict" then
        parsed.same_site = "Strict"
      elseif lower == "none" then
        parsed.same_site = "None"
      end
    end
  end
  return parsed, ""
end

return Cookies
