--- Internal helpers for cosmic.fetch: URL/header validation, request
--- body building (query/json/form/multipart), the verb helpers, and
--- download. Lives in its own file so fetch/init.tl stays under the
--- 500-line cap; init wires everything together.
local url_mod = require("cosmic.url")
local json_mod = require("cosmic.json")
local codec = require("cosmic.codec")
local rand = require("cosmic.rand")
local fd = require("cosmic.fd")
local fs = require("cosmic.fs")

--- One part of a multipart/form-data request body.
local record Part
  --- Form field name (required).
  name: string
  --- Field or file content (required; "" is a valid empty value).
  value: string
  --- File name; its presence makes this a file part.
  filename: string
  --- Part content type (optional; files default to
  --- application/octet-stream, plain fields carry none).
  content_type: string
end

local function validate_url(url: string): string
  if url == "" then
    return "empty URL"
  end
  local scheme = url:match("^([a-zA-Z][a-zA-Z0-9+%-.]*)://")
  if not scheme then
    return "unsupported URL scheme: (none)"
  end
  scheme = scheme:lower()
  if scheme ~= "http" and scheme ~= "https" then
    return "unsupported URL scheme: " .. scheme
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
--- / header-injection vector (audit §2.3). The error names the offending
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

--- Build a unix domain socket proxy URL from a socket path.
--- @param path string Absolute path to the unix domain socket
--- @return string | nil proxy URL in unix:// format
--- @return string? Error message if path is invalid
local function unix_proxy(path: string): string | nil, string
  if not path or path == "" then
    return nil, "empty socket path"
  end
  if path:sub(1, 1) ~= "/" then
    return nil, "socket path must be absolute"
  end
  if path:match("/%.%./") or path:match("/%.%.$") or path:match("/%./") or path:match("/%.$") then
    return nil, "socket path must not contain . or .. segments"
  end
  -- unix(7) sockaddr_un sun_path is typically 108 bytes
  if #path >= 108 then
    return nil, "socket path too long"
  end
  return "unix://" .. path
end

--- Percent-encode params as k=v pairs joined with "&", keys sorted so
--- the encoding is deterministic. Spaces become %20 (not "+").
local function encode_pairs(params: {string: string}): string
  local keys: {string} = {}
  for k in pairs(params) do
    table.insert(keys, k)
  end
  table.sort(keys)
  local out: {string} = {}
  for _, k in ipairs(keys) do
    table.insert(out, url_mod.encode(k) .. "=" .. url_mod.encode(params[k]))
  end
  return table.concat(out, "&")
end

--- Append query params to a URL, honoring an existing query string.
local function append_query(url: string, params: {string: string}): string
  local qs = encode_pairs(params)
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
  local raw, rerr = rand.bytes(12)
  if not raw then
    return nil, rerr
  end
  local boundary = "cosmic" .. codec.encode_hex(raw as string)
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
  local opts = opts_in as PrepareOptions
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
  for k, v in pairs(opts_in as {string: any}) do
    o[k] = v
  end
  local prepared = o as PrepareOptions
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
    prepared.body = encode_pairs(opts.form)
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
  return url, o as T, nil
end

-- Mirrors of the stream result surface download consumes.
local record Reader
  read: function(self: Reader): string | nil, string
  close: function(self: Reader): boolean
end

local record StreamRes
  ok: boolean
  status: integer
  headers: {string: string}
  raw_headers: {string: {string}}
  url: string
  error: string
  reader: Reader
end

--- The verb helpers and download, built around init's fetch/stream so
--- no require cycle forms. wrap attaches init's result metatable
--- (is_success/json) to download's synthesized results.
local record Made
  get: function(string, any): any
  post: function(string, any): any
  put: function(string, any): any
  delete: function(string, any): any
  download: function(string, string, any): any
end

local function verb(fetch_fn: function(string, any): any, method: string): function(string, any): any
  return function(url: string, opts_any: any): any
    local o: {string: any} = {}
    if opts_any then
      for k, v in pairs(opts_any as {string: any}) do
        o[k] = v
      end
    end
    o["method"] = method
    return fetch_fn(url, o)
  end
end

local function make(fetch_fn: function(string, any): any,
    stream_fn: function(string, any): any,
    wrap: function(any): any): Made
  local made: Made = {
    get = verb(fetch_fn, "GET"),
    post = verb(fetch_fn, "POST"),
    put = verb(fetch_fn, "PUT"),
    delete = verb(fetch_fn, "DELETE"),
  }

  made.download = function(url: string, path: string, opts_any: any): any
    local res_any = stream_fn(url, opts_any)
    local res = res_any as StreamRes
    if not res.ok then
      return res_any
    end
    local out: {string: any} = {
      ok = true, status = res.status, headers = res.headers,
      raw_headers = res.raw_headers, url = res.url, body = "",
    }
    local function fail_with(err: string): any
      res.reader:close()
      out["ok"] = false
      out["error"] = err
      return wrap(out)
    end
    if not (res.status >= 200 and res.status < 300) then
      -- Nothing is written for a non-2xx response; drain a bounded
      -- diagnostic body instead so callers can see the error page.
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
    local h = handle as fd.Handle
    while true do
      local chunk, rerr = res.reader:read()
      if rerr then
        h:close()
        fs.unlink(path)
        return fail_with("download: " .. rerr)
      end
      if not chunk then break end
      local c = chunk as string
      local off = 0
      while off < #c do
        local n, werr = h:write(c:sub(off + 1))
        if not n then
          h:close()
          fs.unlink(path)
          return fail_with("download: write: " .. tostring(werr))
        end
        off = off + math.floor(n)
      end
    end
    res.reader:close()
    local cok, cerr = h:close()
    if not cok then
      fs.unlink(path)
      out["ok"] = false
      out["error"] = "download: close: " .. tostring(cerr)
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
  unix_proxy: function(path: string): string | nil, string
  prepare: function<T>(url: string, opts_in: T): string, T, string
  make: function(fetch_fn: function(string, any): any,
  stream_fn: function(string, any): any,
  wrap: function(any): any): Made
end

local M: ExtrasModule = {
  validate_url = validate_url,
  validate_headers = validate_headers,
  unix_proxy = unix_proxy,
  prepare = prepare,
  make = make,
}

return M
