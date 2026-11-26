--- Test clients for an app: [`Testing.test_client`] calls the app's handler
--- in-process, with a cookie jar and the server's own checks of the reply,
--- and [`Testing.with_server`] serves the app on the loopback for a client
--- that speaks HTTP/1.1 over a socket.
--- @public

local Clock = require("cosmic.clock")
local Cookies = require("cosmic.web.cookies")
local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local App = require("cosmic.web.app")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Types = require("cosmic.web.types")
local Url = require("cosmic.url")
local String = require("cosmic.string")

local record Testing
  --- What the jar remembers about a cookie besides its value.
  record JarEntry
    --- Where it is sent: the `Path` it was set with, else the directory of
    --- the request that set it.
    path: string
    --- Whether it is sent only over https.
    secure: boolean
    --- When it lapses in ns since the epoch (`Max-Age` first, else
    --- `Expires`); nil for a session cookie, kept as long as the client.
    mut expires_ns?: integer
  end

  --- An app driven in-process: see [`Testing.test_client`].
  interface Client
    --- The app.
    app: Types.App
    --- The cookies the replies set, by name: sent back on the requests
    --- they belong to. A browser keys a cookie by name, domain and path;
    --- this jar by name alone, as the client speaks to one host, so two
    --- cookies of a name at different paths replace each other.
    jar: mut {string:string}
    --- What the jar knows of each cookie's `Path`, `Secure` and expiry, by name.
    attrs: mut {string:JarEntry}
    --- "http" (the default) or "https": whether the client acts as a browser
    --- on an https page. A `Secure` cookie is sent only when it is "https",
    --- which also adds `X-Forwarded-Proto: https`, believed by an app whose
    --- `trusted_proxy` names the request's peer (`127.0.0.1` unless the
    --- request gives another, so `"loopback"`).
    mut scheme: string
    --- Whether the app's lifespan has run.
    mut started: boolean
    --- The cleanup the lifespan returned, nil once run or when it returned none.
    mut shutdown?: Types.Shutdown

    --- One request, through the app's handler. `path` may hold a query.
    --- A reply the server would refuse raises, with the server's reason.
    request: function(self: Client, method: string, path: string,
        opts?: Types.TestOptions): Types.TestResponse
    --- A GET.
    get: function(self: Client, path: string, opts?: Types.TestOptions): Types.TestResponse
    --- A HEAD: the reply has the head a GET's would and no body.
    head: function(self: Client, path: string, opts?: Types.TestOptions): Types.TestResponse
    --- A POST.
    post: function(self: Client, path: string, opts?: Types.TestOptions): Types.TestResponse
    --- A PUT.
    put: function(self: Client, path: string, opts?: Types.TestOptions): Types.TestResponse
    --- A PATCH.
    patch: function(self: Client, path: string, opts?: Types.TestOptions): Types.TestResponse
    --- A DELETE.
    delete: function(self: Client, path: string, opts?: Types.TestOptions): Types.TestResponse
    --- An OPTIONS.
    options: function(self: Client, path: string, opts?: Types.TestOptions): Types.TestResponse

    __close: function(Client)
  end

  --- What [`Testing.with_server`] gives [`Web.serve`] besides the
  --- listener and `on_ready`, which are its own.
  record ServerOptions
    --- As [`Types.ServeOptions.compress`].
    compress?: boolean | Server.Compression
  end

  --- A client of an app served on the loopback: see [`Testing.with_server`].
  record Loopback
    --- The connection, kept alive between requests.
    mut conn: Net.Conn
    --- Bytes read from it and not yet taken.
    mut buf: string
    --- The `Host` the requests name.
    host: string
    --- How long a read or a write of the connection waits, as [`set_timeout`]
    --- last set it (nil: no limit).
    mut timeout_ns?: integer

    --- Sets how long a read or a write of the connection waits (nil: no
    --- limit). A request sending a large body sets the connection's own
    --- timeout back to this after each look for the reply, so one set on
    --- `conn` directly does not last past it.
    set_timeout: function(self: Loopback, wait_ns: integer?)

    --- One request over the connection; nil and why when the server's reply
    --- cannot be read.
    request: function(self: Loopback, method: string, path: string,
        opts?: Types.TestOptions): (Types.TestResponse) | (nil, Failure)
    --- A GET.
    get: function(self: Loopback, path: string,
        opts?: Types.TestOptions): (Types.TestResponse) | (nil, Failure)
    --- A POST.
    post: function(self: Loopback, path: string,
        opts?: Types.TestOptions): (Types.TestResponse) | (nil, Failure)
    --- A HEAD.
    head: function(self: Loopback, path: string,
        opts?: Types.TestOptions): (Types.TestResponse) | (nil, Failure)
    --- Sends `bytes` as they are and reads the reply: for a request no
    --- well-formed client would send.
    raw: function(self: Loopback, bytes: string, method?: string): (Types.TestResponse) | (nil, Failure)
  end
end

local type Reply = Types.Response
local type Options = Types.TestOptions
local type Response = Types.TestResponse

--- Every name of `table`, sorted.
local function sorted_names<V>(table_: {string:V}): {string}
  local names: mut {string} = {}
  for name in pairs(table_) do names[#names + 1] = name end
  table.sort(names)
  return names
end

--- The pairs of `values`, a name to a string or a list, in name order.
local function pairs_of(values: {string: string | {string}}): {Url.Pair}
  local out: mut {Url.Pair} = {}
  for _, name in ipairs(sorted_names(values)) do
    local value = values[name]
    if value is string then
      out[#out + 1] = { name = name, value = value }
    elseif value ~= nil then
      for _, each in ipairs(value) do out[#out + 1] = { name = name, value = each } end
    end
  end
  return out
end

--- A header line of a reply, in the order it was sent.
local record HeaderLine
  name: string
  value: string
end

--- What a request is made of: the target, headers and body.
local record Prepared
  target: string
  path: string
  query: string
  headers: mut {string:string}
  body: string
end

--- Reads a Reader whole; the body of a request is bytes to the server.
local function bytes_of(body: string | Stream.Reader): string
  if body is string then return body end
  local data, why = Stream.read_all(body)
  if data == nil then error("web: test client: reading the request body: " .. tostring(why), 3) end
  return data
end

--- Makes the target, headers and body of a request from `path` and `opts`.
local function prepare(method: string, path: string, opts: Options): Prepared
  if path:sub(1, 1) ~= "/" and path ~= "*" then
    error("web: test client: the path must start with '/'", 3)
  end
  local at = path:find("?", 1, true)
  local base = at and path:sub(1, at - 1) or path
  local query = at and path:sub(at + 1) or ""
  local opts_query = opts.query
  if opts_query ~= nil then
    local extra = Url.encode_query(pairs_of(opts_query))
    if extra ~= "" then query = (if query == "" then extra else query .. "&" .. extra end) end
  end
  local headers: mut {string:string} = { host = "testserver" }
  for name, value in pairs(opts.headers or {}) do headers[name:lower()] = value end
  local body = ""
  local form, json, raw = opts.form, opts.json, opts.body
  if form ~= nil then
    body = Url.encode_query(pairs_of(form))
    headers["content-type"] = headers["content-type"] or "application/x-www-form-urlencoded"
  elseif json ~= nil then
    local text, why = Json.encode_any(json)
    if text == nil then error("web: test client: json: " .. tostring(why), 3) end
    body = text
    headers["content-type"] = headers["content-type"] or "application/json"
  elseif raw ~= nil then
    body = bytes_of(raw)
    local content_type = opts.content_type
    if content_type ~= nil then headers["content-type"] = content_type end
  end
  if body ~= "" or method == "POST" or method == "PUT" or method == "PATCH" then
    headers["content-length"] = tostring(#body)
  end
  return { target = base .. (if query ~= "" then "?" .. query else "" end), path = base, query = query,
    headers = headers, body = body }
end

local REDIRECT <const>: {integer:boolean} = {
  [301] = true, [302] = true, [303] = true, [307] = true, [308] = true,
}

--- What [`response_of`] makes.
local class Answered is Types.TestResponse
  function header_list(self, name: string): {string}
    local out: mut {string} = {}
    for i, line in ipairs(self.lines[name:lower()] or {}) do out[i] = line end
    return out
  end

  function text(self): string
    return self.body
  end

  function json(self): (Json.Value) | (nil, Failure)
    return Json.decode(self.body)
  end
end

--- A response from `lines`, header lines as `{name, value}` in order.
local function response_of(status: integer, lines: {HeaderLine}, body: string): Response
  local headers: mut {string:string} = {}
  local by_name: mut {string:{string}} = {}
  for _, line in ipairs(lines) do
    local name = line.name:lower()
    local held = headers[name]
    if held == nil then
      headers[name] = line.value
    else
      headers[name] = held .. ", " .. line.value
    end
    by_name[name] = by_name[name] or {}
    table.insert(by_name[name], line.value) -- checked: overload_none -- untyped: call
  end
  local response: Answered = { status = status, headers = headers, lines = by_name, body = body,
    ok = status >= 200 and status < 300, stream = nil, redirect_location = nil }
  if REDIRECT[status] == true then response.redirect_location = headers["location"] end
  return response
end

--- Whether a reply of `status` has no body.
local function bodiless(status: integer): boolean
  return status < 200 or status == 204 or status == 304
end

--- Starts the app's lifespan, once.
local function start(client: Testing.Client)
  if client.started then return end
  local lifespan = client.app.spec.lifespan
  if lifespan ~= nil then
    local cleanup, why = lifespan(client.app)
    if cleanup == nil and why ~= nil and why ~= "" then -- checked: compare_disjoint
      error("web: test client: the lifespan failed: " .. why, 0)
    end
    client.shutdown = cleanup
  end
  client.started = true
end

--- The directory of `path`, where a cookie set without a `Path` is sent
--- (RFC 6265 5.1.4).
local function default_path(path: string): string
  if path:sub(1, 1) ~= "/" then return "/" end
  local last = path:match("^.*()/")
  if last == nil or last == 1 then return "/" end
  return path:sub(1, last - 1)
end

--- Whether a cookie of `cookie_path` is sent for `path` (RFC 6265 5.1.4).
local function path_matches(cookie_path: string, path: string): boolean
  if cookie_path == path then return true end
  if path:sub(1, #cookie_path) ~= cookie_path then return false end
  return cookie_path:sub(-1) == "/" or path:sub(#cookie_path + 1, #cookie_path + 1) == "/"
end

--- Updates the jar with a `Set-Cookie` line the reply to a request for
--- `path` carried: a cookie with a `Max-Age` of 0 or less, or an
--- `Expires` in the past, deletes the one at its path; `Path`, `Secure`
--- and the expiry are kept for the requests that follow. It takes more
--- than a browser does. `Domain`, `SameSite` and `HttpOnly` are not read,
--- as the client has one host and sends every request itself. A `Secure`
--- cookie is stored whatever the client's scheme, and sent only while it
--- is "https"; one named `__Secure-` or `__Host-` is kept whatever its
--- attributes. A browser refuses either from an http page, and the
--- second without the attributes its prefix needs.
local function remember(client: Testing.Client, line: string, path: string)
  local parsed, _ = Cookies.parse_set_cookie(line)
  if parsed == nil then return end
  local name = parsed.name
  local cookie_path = parsed.path or default_path(path)
  local now = Clock.now_ns()
  local expires: integer? = nil
  local gone = false
  local max_age, expires_ns = parsed.max_age, parsed.expires_ns
  if max_age ~= nil then
    gone = max_age <= 0
    -- A huge Max-Age lasts as long as the clock can say.
    local room = (math.maxinteger - now) // 1000000000
    expires = now + math.min(max_age, room) * 1000000000
  elseif expires_ns ~= nil then
    gone = expires_ns <= now
    expires = expires_ns
  end
  if gone then
    local old = client.attrs[name]
    if old == nil or old.path == cookie_path then
      client.jar[name] = nil
      client.attrs[name] = nil
    end
    return
  end
  client.jar[name] = parsed.value
  client.attrs[name] = { path = cookie_path, secure = parsed.secure, expires_ns = expires }
end

--- The header lines of `reply`, in name order: `{name, value}`.
local function lines_of(reply: Reply): mut {HeaderLine}
  local out: mut {HeaderLine} = {}
  local headers = reply.headers or {}
  for _, name in ipairs(sorted_names(headers)) do
    local value = headers[name]
    if value is string then
      out[#out + 1] = { name = name, value = value }
    elseif value ~= nil then
      for _, each in ipairs(value) do out[#out + 1] = { name = name, value = each } end
    end
  end
  return out
end

--- One request to the app, with no redirect followed.
local function send(client: Testing.Client, method: string, path: string, opts: Options): Response
  start(client)
  local prepared = prepare(method, path, opts)
  local cookies: mut {string:string} = {}
  local now = Clock.now_ns()
  for name, value in pairs(client.jar) do
    local entry = client.attrs[name]
    local expires_ns = entry and entry.expires_ns
    if entry ~= nil and expires_ns ~= nil and expires_ns <= now then
      client.jar[name] = nil
      client.attrs[name] = nil
    elseif entry == nil or ((not entry.secure or client.scheme == "https") and
        path_matches(entry.path, prepared.path)) then
      cookies[name] = value
    end
  end
  if client.scheme == "https" and prepared.headers["x-forwarded-proto"] == nil then
    prepared.headers["x-forwarded-proto"] = "https"
  end
  for name, value in pairs(opts.cookies or {}) do cookies[name] = value end
  if next(cookies) ~= nil then
    local list: mut {string} = {}
    for _, name in ipairs(sorted_names(cookies)) do
      local value = cookies[name]
      if value ~= nil then list[#list + 1] = name .. "=" .. value end
    end
    local sent = table.concat(list, "; ")
    local old = prepared.headers["cookie"]
    prepared.headers["cookie"] = if old ~= nil then old .. "; " .. sent else sent end
  end
  local raw: Server.Request = { gone = function(): boolean return false end,
    wait_gone = function(_?: integer): boolean return false end,
    method = method, target = prepared.target, path = prepared.path, query = prepared.query,
    version = "HTTP/1.1", headers = prepared.headers, body = Stream.from_string(prepared.body),
    length = #prepared.body, peer = opts.peer or Net.tcp("127.0.0.1", 50000), listener = opts.listener,
  }
  local answered: mut {Response} = {}
  Poll.within(function()
    local reply = client.app.handle(raw)
    local trouble = Server.check(reply, method)
    if trouble ~= "" then
      local unsent = if type(reply) == "table" then reply.body else nil end
      if unsent ~= nil then
        if not unsent is string then
          local _, _ = unsent:close()
        end
      end
      error("web: test client: the server would answer 500 for this reply: " .. trouble, 0)
    end
    local lines = lines_of(reply)
    local body = ""
    local stream: Stream.Reader? = nil
    local given = reply.body
    local length: integer? = nil
    if given is string then
      body = given
      length = #given
    elseif given ~= nil then
      length = reply.length
      if method == "HEAD" or bodiless(reply.status) then
        local _, _ = given:close()
      elseif opts.stream == true then
        stream = given
      else
        local data, why = Stream.read_all(given)
        local _, _ = given:close()
        if data == nil then
          error("web: test client: reading the reply body: " .. tostring(why), 0)
        end
        body = data
        length = #data
      end
    else
      length = reply.length or 0
    end
    local has_length = false
    for _, line in ipairs(lines) do
      if line.name:lower() == "content-length" then has_length = true end
    end
    if not has_length and length ~= nil and not bodiless(reply.status) then
      table.insert(lines, { name = "content-length", value = tostring(length) })
    end
    if method == "HEAD" or bodiless(reply.status) then body = "" end
    local made = response_of(reply.status, lines, body)
    made.stream = stream
    answered[1] = made
  end)
  local result = answered[1]
  if result == nil then error("web: test client: the loop ended before the app answered", 0) end
  for _, line in ipairs(result.lines["set-cookie"] or {}) do
    remember(client, line, prepared.path)
  end
  return result
end

local function request(self: Testing.Client, method: string, path: string, opts?: Options): Response
  opts = opts or {}
  local res = send(self, method, path, opts)
  local hops = 0
  while true do
    local target = res.redirect_location
    if opts.follow_redirects ~= true or target == nil or hops >= 10 then break end
    hops = hops + 1
    if target:sub(1, 1) ~= "/" then
      local parts, why = Url.parse(target)
      if parts == nil then
        error("web: test client: the redirect to " .. target .. ": " .. tostring(why), 2)
      end
      local query = parts.query
      target = parts.path .. (if query ~= nil then "?" .. query else "" end)
    end
    local switch = res.status ~= 307 and res.status ~= 308 and method ~= "HEAD"
    if switch then
      method = "GET"
      opts = { headers = opts.headers, cookies = opts.cookies, follow_redirects = true,
        stream = opts.stream }
    else
      opts = { headers = opts.headers, form = opts.form, json = opts.json, body = opts.body,
        content_type = opts.content_type, cookies = opts.cookies, follow_redirects = true,
        stream = opts.stream }
    end
    res = send(self, method, target, opts)
  end
  return res
end

--- What [`Testing.test_client`] makes.
local class InProcess is Testing.Client
  function request(self, method: string, path: string, opts?: Options): Response
    return request(self, method, path, opts)
  end

  function get(self, path: string, opts?: Options): Response
    return self:request("GET", path, opts)
  end

  function head(self, path: string, opts?: Options): Response
    return self:request("HEAD", path, opts)
  end

  function post(self, path: string, opts?: Options): Response
    return self:request("POST", path, opts)
  end

  function put(self, path: string, opts?: Options): Response
    return self:request("PUT", path, opts)
  end

  function patch(self, path: string, opts?: Options): Response
    return self:request("PATCH", path, opts)
  end

  function delete(self, path: string, opts?: Options): Response
    return self:request("DELETE", path, opts)
  end

  function options(self, path: string, opts?: Options): Response
    return self:request("OPTIONS", path, opts)
  end

  --- Runs the app's cleanup, once: a second close does nothing.
  function __close(self)
    local shutdown = self.shutdown
    self.shutdown = nil
    if shutdown ~= nil then shutdown() end
  end
end

--- A client that calls `app` in-process: it builds a [`Server.Request`] and
--- calls `app.handle`, so the middleware and the router are the served
--- ones. It keeps a cookie jar across calls, runs the app's lifespan at
--- its first request (and its cleanup when closed), runs each call in a
--- [`Poll.run`] unless the caller is in one, and fails a call whose reply
--- the server would refuse with a 500.
--- @param app Types.App The app
--- @return Testing.Client The client
function Testing.test_client(app: Types.App): Testing.Client
  local client: InProcess = { app = app, jar = {}, attrs = {}, scheme = "http", started = false, shutdown = nil }
  return client
end

--- Runs `fn` with a client of `app` in one [`Poll.run`], the lifespan
--- started before it and cleaned up after it, so a handler that waits and
--- a resource the lifespan opens both work for every call `fn` makes.
--- @param app Types.App The app
--- @param fn function(client: Testing.Client) The test
function Testing.with_client(app: Types.App, fn: function(client: Testing.Client))
  local client <close> = Testing.test_client(app) -- checked: close_not_closable
  start(client)
  Poll.run(function() fn(client) end)
end

--- How long a connect, a read or a write of the loopback client waits: a
--- server that goes silent fails the test in this long, not never.
local IO_TIMEOUT_NS <const> = Clock.seconds(5)

--- Reads more of the connection into the buffer.
--- True; false where the connection ended; nil and a Failure where it failed.
local function fill(lb: Testing.Loopback): (boolean) | (nil, Failure)
  local piece, why = lb.conn:read()
  if piece == nil then return nil, why end
  if piece == false then return false end
  lb.buf = lb.buf .. piece
  return true
end

--- The next line, without its CRLF; nil and a Failure where the connection ends.
local function next_line(lb: Testing.Loopback): (string) | (nil, Failure)
  while true do
    local at = lb.buf:find("\r\n", 1, true)
    if at ~= nil then
      local found = lb.buf:sub(1, at - 1)
      lb.buf = lb.buf:sub(at + 2)
      return found
    end
    local ok, why = fill(lb)
    if ok == nil then return nil, why end
    if not ok then return nil, Failure.new("the connection ended within a head") end
  end
end

--- The next `n` bytes.
local function take(lb: Testing.Loopback, n: integer): (string) | (nil, Failure)
  while #lb.buf < n do
    local ok, why = fill(lb)
    if ok == nil then return nil, why end
    if not ok then return nil, Failure.new("the connection ended within a body") end
  end
  local out = lb.buf:sub(1, n)
  lb.buf = lb.buf:sub(n + 1)
  return out
end

--- The reply to a request of `method`, read off the connection.
local function read_reply(lb: Testing.Loopback, method: string): (Response) | (nil, Failure)
  local status_line, why = next_line(lb)
  if status_line == nil then return nil, why end
  local code = status_line:match("^HTTP/1%.[01] (%d%d%d)")
  if code == nil then return nil, Failure.new("not a status line: " .. status_line) end
  local status = math.tointeger(tonumber(code))
  if status == nil then return nil, Failure.new("not a status line: " .. status_line) end
  local lines: mut {HeaderLine} = {}
  local headers: mut {string:string} = {}
  while true do
    local line, line_why = next_line(lb)
    if line == nil then return nil, line_why end
    if line == "" then break end
    local name, rest = line:match("^([^:]+):(.*)$")
    if name == nil or rest == nil then return nil, Failure.new("not a header line: " .. line) end
    local value = String.trim(rest)
    lines[#lines + 1] = { name = name, value = value }
    headers[name:lower()] = value
  end
  local body = ""
  if method ~= "HEAD" and not bodiless(status) then
    if (headers["transfer-encoding"] or ""):lower() == "chunked" then
      local pieces: mut {string} = {}
      while true do
        local size_line, size_why = next_line(lb)
        if size_line == nil then return nil, size_why end
        local digits = size_line:match("^(%x+)$") or size_line:match("^(%x+);")
        if digits == nil then return nil, Failure.new("not a chunk size: " .. size_line) end
        local size = tonumber(digits, 16)
        if size == nil then return nil, Failure.new("not a chunk size: " .. size_line) end
        if size == 0 then
          repeat
            local trailer, trailer_why = next_line(lb)
            if trailer == nil then return nil, trailer_why end
          until trailer == ""
          break
        end
        local count = math.tointeger(size)
        if count == nil then return nil, Failure.new("not a chunk size: " .. size_line) end
        local data, data_why = take(lb, count)
        if data == nil then return nil, data_why end
        pieces[#pieces + 1] = data
        local crlf, crlf_why = take(lb, 2)
        if crlf == nil then return nil, crlf_why end
      end
      body = table.concat(pieces)
    elseif headers["content-length"] ~= nil then
      local data, data_why = take(lb, math.tointeger(tonumber(headers["content-length"])) or 0)
      if data == nil then return nil, data_why end
      body = data
    else
      while true do
        local ok, fill_why = fill(lb)
        if ok == nil then return nil, fill_why end
        if not ok then break end
      end
      body = lb.buf
      lb.buf = ""
    end
  end
  return response_of(status, lines, body)
end

--- Whether `buf`, the reply read so far, holds the start of a final reply:
--- something past every whole interim (1xx) reply it opens with.
local function final_begun(buf: string): boolean
  local at = 1
  while buf:find("^HTTP/%d%.%d 1%d%d ", at) ~= nil do
    local _, stop = buf:find("\r\n\r\n", at, true)
    if stop == nil then return false end
    at = stop + 1
  end
  return at <= #buf
end

--- How much of a request goes out between looks for the server's reply.
local SEND_SLICE <const> = 64 * 1024

--- Writes `bytes`, stopping where the server has responded already, and
--- answers false and why where a write failed. A server refusing a body
--- (413) responds at once, reads a bounded amount more and closes, and a
--- close with bytes unread resets the connection, which on BSD discards
--- the reply from the client's buffer. So the reply is looked for between
--- slices: a refusal sent while the server still drains is read before
--- its reset. An interim reply (`100 Continue`) is kept and the body goes
--- on.
-- TODO: a refusal the server sends only after more than it drains
-- (cosmic/http/server.tl's `linger`), or one whose reset meets the first
-- slice's write, can still be lost on BSD; reading the reply before the
-- first write, or half-closing instead of resetting, would close that.
local function send_until_answered(lb: Testing.Loopback, bytes: string): (true) | (false, Failure)
  local from = 1
  while from <= #bytes do
    local sent, why = lb.conn:write(bytes:sub(from, from + SEND_SLICE - 1))
    if not sent then return false, why end
    from = from + SEND_SLICE
    if from <= #bytes then
      -- A wait of none still yields the run, so the server's task reads.
      lb.conn:set_timeout(0)
      local piece, read_why = lb.conn:read()
      lb.conn:set_timeout(lb.timeout_ns)
      if piece is string then
        lb.buf = lb.buf .. piece
        if final_begun(lb.buf) then return true end
      elseif piece == false or read_why == nil or read_why.kind ~= "timeout" then
        return true
      end
    end
  end
  return true
end

local function loopback_raw(self: Testing.Loopback, bytes: string, method?: string): (Response) | (nil, Failure)
  local written, write_why = send_until_answered(self, bytes)
  -- A write that timed out met a server that stopped reading: waiting as
  -- long again for a reply would only double the failure's time.
  if not written and write_why.kind == "timeout" then return nil, write_why end
  local reply, why = read_reply(self, method or "GET")
  if reply == nil then return nil, (if not written then write_why else why end) end
  return reply
end

local function loopback_request(self: Testing.Loopback, method: string, path: string,
                                opts?: Options): (Response) | (nil, Failure)
  local prepared = prepare(method, path, opts or {})
  prepared.headers["host"] = self.host
  local head: mut {string} = { ("%s %s HTTP/1.1"):format(method, prepared.target) }
  for _, name in ipairs(sorted_names(prepared.headers)) do
    local value = prepared.headers[name]
    if value ~= nil then head[#head + 1] = name .. ": " .. value end
  end
  return loopback_raw(self, table.concat(head, "\r\n") .. "\r\n\r\n" .. prepared.body, method)
end

local function loopback_verb(method: string): function(Testing.Loopback, string, p3?: Options): (Response) | (nil, Failure)
  return function(self: Testing.Loopback, path: string, opts?: Options): (Response) | (nil, Failure)
    return self:request(method, path, opts)
  end
end

local function loopback_set_timeout(self: Testing.Loopback, wait_ns: integer?)
  self.conn:set_timeout(wait_ns)
  self.timeout_ns = wait_ns
end

--- Serves `app` through [`Web.serve`] on 127.0.0.1 at a port the kernel
--- chooses, calls `fn` with a client of it over one kept-alive connection,
--- and stops the server when `fn` returns. What `fn` raises is raised
--- again once the server has stopped. It is for what the in-process client
--- cannot see: real framing, `Connection: close`, the responses the server
--- makes itself, and graceful stop. It runs a [`Poll.run`] of its own, so
--- it cannot be called in a task, and a test using it declares
--- `Test.policy{ loopback = { "127.0.0.1" } }`. `opts` is what else
--- [`Web.serve`] is given.
--- @param app Types.App The app
--- @param fn function(client: Testing.Loopback) The test
--- @param opts Testing.ServerOptions | nil The server's options
function Testing.with_server(app: Types.App, fn: function(client: Testing.Loopback), opts?: Testing.ServerOptions)
  -- Why the test or its connection failed, if either did.
  local failures: mut {string} = {}
  local ok, why = App.serve(app, {
    listeners = { Net.tcp("127.0.0.1", 0) },
    compress = opts and opts.compress,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local address = addresses[1]
      if address == nil then
        failures[1] = "web: with_server: the server listened on no address"
        server:stop()
        return
      end
      local conn, connect_why = Net.connect(address, { timeout_ns = IO_TIMEOUT_NS })
      if conn == nil then
        local said = "web: with_server: connecting: " .. tostring(connect_why)
        failures[1] = said
        server:stop()
        return
      end
      conn:set_timeout(IO_TIMEOUT_NS)
      local client: Testing.Loopback = {
        conn = conn, buf = "", timeout_ns = IO_TIMEOUT_NS, host = "127.0.0.1:" .. tostring(assert(address.port)),
        set_timeout = loopback_set_timeout, request = loopback_request, raw = loopback_raw,
        get = loopback_verb("GET"), post = loopback_verb("POST"), head = loopback_verb("HEAD"),
      }
      local ran, raised = pcall(function() fn(client) end)
      if not ran then failures[1] = tostring(raised) end
      local _, _ = conn:close()
      server:stop()
    end,
  })
  if failures[1] ~= nil then error(failures[1], 0) end
  if not ok then error("web: with_server: " .. why, 2) end
end

return Testing
