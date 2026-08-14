--- Internal helpers for cosmic.fetch: URL/header validation, request
--- body building (query/json/form/multipart), the verb helpers, and
--- download. Lives in its own file so fetch/init.tl stays under the
--- 500-line cap; init wires everything together.
local cosmo = require("cosmo")
local url_mod = require("cosmic.url")
local stream = require("cosmic.stream")
local json_mod = require("cosmic.json")
local codec = require("cosmic.codec")
local rand = require("cosmic.rand")
local fd = require("cosmic.fd")
local fs = require("cosmic.fs")

--- One part of a multipart/form-data request body.
local record Part
  --- Form field name required.
  name: string
  --- Field or file content (required; "" is a valid empty value).
  value: string
  --- File name; its presence makes this a file part.
  filename: string
  --- Part content type (optional; files default to
  --- application/octet-stream, plain fields carry none).
  content_type: string
end

--- Validate a fetch URL with the same parser the HTTP client uses
--- (cosmo.ParseUrl) rather than a hand-rolled scheme pattern that could
--- disagree with it. ParseUrl preserves scheme case, so
--- the http/https comparison still lowercases; a scheme-only URL like
--- "http://" parses but carries no host, which fetch cannot use.
--- @param url string The URL to validate
--- @return string? Error message, or nil when the URL is usable
local function validate_url(url: string): string
  if url == "" then
    return "empty URL"
  end
  local u = cosmo.ParseUrl(url)
  local scheme = u.scheme
  if not scheme then
    return "unsupported URL scheme: (none)"
  end
  scheme = scheme:lower()
  if scheme ~= "http" and scheme ~= "https" then
    return "unsupported URL scheme: " .. scheme
  end
  if not u.host or u.host == "" then
    return "missing URL host"
  end
  return nil
end

-- True when s carries a CR, LF, or NUL. One character-class scan instead
-- of three separate plain-text searches over the same string.
local function has_forbidden_byte(s: string): boolean
  return s:find("[\r\n\0]") ~= nil
end

--- Reject header names or values that carry a CR, LF, or NUL. HTTP headers
--- are CRLF-delimited, so an embedded CR/LF in a name or value smuggles
--- additional header lines (or a body) past cosmo.Fetch — a request-splitting
--- / header-injection vector. The error names the offending
--- header but never echoes the raw control bytes back.
--- @param headers {string: string} request headers, or nil
--- @return string? error message, or nil when every header is safe
local function validate_headers(headers: {string: string}): string
  if not headers then
    return nil
  end
  for name, value in pairs(headers) do
    if name == "" then
      return "invalid header name: must not be empty"
    end
    if has_forbidden_byte(name) then
      return "invalid header name: must not contain CR, LF, or NUL"
    end
    if value ~= nil and has_forbidden_byte(value) then
      return "invalid value for header '" .. name .. "': must not contain CR, LF, or NUL"
    end
  end
  return nil
end

--- Append query params to a URL, honoring an existing query string.
local function append_query(url: string, params: {string: string}): string
  -- url.format_query is the one percent-encoder for query maps; it
  -- accepts plain-string values, so fetch's one-value map feeds it
  -- directly (sorted keys, %20 spaces).
  local qs = url_mod.format_query(params)
  if qs == "" then
    return url
  end
  if url:find("?", 1, true) then
    return url .. "&" .. qs
  end
  return url .. "?" .. qs
end

-- Multipart names and filenames are embedded in a quoted string inside
-- Content-Disposition; quotes and CR/LF would corrupt the framing.
local function bad_token(s: string): boolean
  return s:find('["\r\n]') ~= nil
end

--- Encode parts as a multipart/form-data body with a random boundary
--- (96 random bits, so a body containing it is not a practical concern).
--- @return string | nil The encoded body, or nil on error
--- @return string The content type carrying the boundary (error message when body is nil)
local function encode_multipart(parts: {Part}): string | nil, string
  if #parts == 0 then
    return nil, "multipart: no parts"
  end
  local boundary = "cosmic" .. codec.encode_hex(rand.bytes(12))
  local out: {string} = {}
  for _, part in ipairs(parts) do
    if not part.name or part.name == "" then
      return nil, "multipart: part missing name"
    end
    if bad_token(part.name) or (part.filename and bad_token(part.filename)) then
      return nil, "multipart: name/filename must not contain quotes, CR, or LF"
    end
    if part.value == nil then
      return nil, "multipart: part '" .. part.name .. "' missing value"
    end
    local head = "--" .. boundary .. "\r\nContent-Disposition: form-data; name=\"" .. part.name .. "\""
    if part.filename then
      head = head .. "; filename=\"" .. part.filename .. "\""
    end
    local ctype = part.content_type
    if not ctype and part.filename then
      ctype = "application/octet-stream"
    end
    if ctype then
      head = head .. "\r\nContent-Type: " .. ctype
    end
    table.insert(out, head .. "\r\n\r\n" .. part.value .. "\r\n")
  end
  table.insert(out, "--" .. boundary .. "--\r\n")
  return table.concat(out), "multipart/form-data; boundary=" .. boundary
end

-- Internal mirror of the fetch.Options fields prepare touches. The
-- full Options record lives in fetch/init.tl (its should_retry
-- callback references Result, and extras cannot require init back);
-- prepare is generic over the caller's record so the module boundary
-- itself stays fully typed.
local record PrepareOptions
  method: string
  body: string
  headers: {string: string}
  query: {string: string}
  json: any
  form: {string: string}
  multipart: {Part}
end

local function set_default_content_type(o: PrepareOptions, ctype: string)
  if o.headers then
    for k in pairs(o.headers) do
      if k:lower() == "content-type" then
        return
      end
    end
  else
    o.headers = {}
  end
  o.headers["Content-Type"] = ctype
end

--- Expand the declarative request options (query/json/form/multipart)
--- into a concrete URL and body. Returns the (possibly rewritten) URL,
--- the (possibly copied) options, and an error message. The caller's
--- options table is never mutated; a body-producing option defaults the
--- method to POST when none is set.
--- @param url string The request URL
--- @param opts_in T The fetch Options record, or nil
--- @return string The URL with query params appended
--- @return T The prepared options
--- @return string? Error message on invalid or conflicting options
local function prepare<T>(url: string, opts_in: T): string, T, string
  if opts_in == nil then
    return url, nil, nil
  end
  local opts = opts_in as PrepareOptions -- cast: generic T via mirror record
  local sources = 0
  if opts.body then sources = sources + 1 end
  if opts.json ~= nil then sources = sources + 1 end
  if opts.form then sources = sources + 1 end
  if opts.multipart then sources = sources + 1 end
  if sources > 1 then
    return url, nil, "at most one of body, json, form, multipart may be set"
  end
  if sources == 0 and not opts.query then
    return url, opts_in, nil
  end

  -- Shallow copy (headers too) so no caller table is mutated.
  local o: {string: any} = {}
  for k, v in pairs(opts_in as {string: any}) do -- cast: generic T as map to copy
    o[k] = v
  end
  local prepared = o as PrepareOptions -- cast: copied map as mirror record
  if opts.headers then
    local h: {string: string} = {}
    for k, v in pairs(opts.headers) do
      h[k] = v
    end
    prepared.headers = h
  end

  if opts.query then
    url = append_query(url, opts.query)
    prepared.query = nil
  end
  if opts.json ~= nil then
    local body, jerr = json_mod.encode(opts.json)
    if not body then
      return url, nil, "json body: " .. tostring(jerr)
    end
    prepared.json = nil
    prepared.body = body
    set_default_content_type(prepared, "application/json")
  elseif opts.form then
    prepared.form = nil
    prepared.body = url_mod.format_query(opts.form)
    set_default_content_type(prepared, "application/x-www-form-urlencoded")
  elseif opts.multipart then
    local body, ctype_or_err = encode_multipart(opts.multipart)
    if not body then
      return url, nil, ctype_or_err
    end
    prepared.multipart = nil
    prepared.body = body
    set_default_content_type(prepared, ctype_or_err)
  end
  if prepared.body and not prepared.method then
    prepared.method = "POST"
  end
  return url, o as T, nil -- cast: copied map back to generic T
end

-- Mirrors of the stream Response surface download consumes.
local record Reader
  read: function(self: Reader): string | nil, string
  close: function(self: Reader): boolean
end

local record StreamRes
  status: integer
  headers: {string: string}
  raw_headers: {string: {string}}
  url: string
  reader: Reader
end

--- The verb helpers and download, built around init's fetch/stream so
--- no require cycle forms. wrap attaches init's Response metatable
--- (is_success/json) to download's synthesized responses; fail_make
--- builds init's structured `nil, Error` failure pair (kind "io" —
--- download's local-file failures are not request failures).
local record Made
  get: function(string, any): any, any
  post: function(string, any): any, any
  put: function(string, any): any, any
  delete: function(string, any): any, any
  download: function(string, string, any): any, any
end

local function verb(fetch_fn: function(string, any): (any, any), method: string): function(string, any): (any, any)
  return function(url: string, opts_any: any): (any, any)
    local o: {string: any} = {}
    if opts_any then
      for k, v in pairs(opts_any as {string: any}) do -- cast: from any
        o[k] = v
      end
    end
    o["method"] = method
    return fetch_fn(url, o)
  end
end

local function make(fetch_fn: function(string, any): (any, any),
    stream_fn: function(string, any): (any, any),
    wrap: function(any): any,
    fail_make: function(string): (any, any)): Made
  local made: Made = {
    get = verb(fetch_fn, "GET"),
    post = verb(fetch_fn, "POST"),
    put = verb(fetch_fn, "PUT"),
    delete = verb(fetch_fn, "DELETE"),
  }

  made.download = function(url: string, path: string, opts_any: any): (any, any)
    local res_any, serr = stream_fn(url, opts_any)
    if res_any == nil then
      return nil, serr
    end
    local res = res_any as StreamRes -- cast: from any
    local out: {string: any} = {
      status = res.status, headers = res.headers,
      raw_headers = res.raw_headers, url = res.url, body = "",
    }
    local function fail_with(err: string): (any, any)
      res.reader:close()
      return fail_make(err)
    end
    if not (res.status >= 200 and res.status < 300) then
      -- Nothing is written for a non-2xx response; drain a bounded
      -- diagnostic body instead so callers can see the error page. A
      -- non-2xx status is a Response, not a failure.
      local parts: {string} = {}
      local total = 0
      while total < 65536 do
        local chunk = res.reader:read()
        if not chunk then break end
        table.insert(parts, chunk)
        total = total + #chunk
      end
      res.reader:close()
      out["body"] = table.concat(parts)
      return wrap(out)
    end
    local handle, oerr = fd.open(path, fd.O_WRONLY | fd.O_CREAT | fd.O_TRUNC, tonumber("644", 8))
    if not handle then
      return fail_with("download: " .. tostring(oerr))
    end
    local h = handle
    while true do
      local chunk, rerr = res.reader:read()
      if rerr then
        local _ok, _err = h:close()
        local _ok2, _err2 = fs.remove(path)
        return fail_with("download: " .. rerr)
      end
      if not chunk then break end
      local c = chunk
      local wok, werr = stream.write_all(h, c)
      if not wok then
        local _ok, _err = h:close()
        local _ok2, _err2 = fs.remove(path)
        return fail_with("download: write: " .. tostring(werr))
      end
    end
    res.reader:close()
    local cok, cerr = h:close()
    if not cok then
      local _ok, _err = fs.remove(path)
      return fail_make("download: close: " .. tostring(cerr))
    end
    return wrap(out)
  end

  return made
end

local record ExtrasModule
  type Part = Part
  type Made = Made
  validate_url: function(url: string): string
  validate_headers: function(headers: {string: string}): string
  prepare: function<T>(url: string, opts_in: T): string, T, string
  make: function(fetch_fn: function(string, any): (any, any),
  stream_fn: function(string, any): (any, any),
  wrap: function(any): any,
  fail_make: function(string): (any, any)): Made
end

local M: ExtrasModule = {
  validate_url = validate_url,
  validate_headers = validate_headers,
  prepare = prepare,
  make = make,
}

return M
