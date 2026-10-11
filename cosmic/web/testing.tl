--- Test clients for an app: [`Testing.test_client`] calls the app's handler
--- in-process, with a cookie jar and the server's own checks of the reply,
--- and [`Testing.with_server`] serves the app on the loopback for a client
--- that speaks HTTP/1.1 over a socket.

local Clock = require("cosmic.clock")
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
  --- An app driven in-process: see [`Testing.test_client`].
  record Client
    --- The app.
    app: Types.App
    --- The cookies the replies set, by name: sent back on every request.
    jar: {string:string}
    --- Whether the app's lifespan has run.
    started: boolean
    --- The cleanup the lifespan returned.
    shutdown: Types.Shutdown

    --- One request, answered by the app's handler. `path` may hold a query.
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

    metamethod __close: function(Client)
  end

  --- A client of an app served on the loopback: see [`Testing.with_server`].
  record Loopback
    --- The connection, kept alive between requests.
    conn: Net.Conn
    --- Bytes read from it and not yet taken.
    buf: string
    --- The `Host` the requests name.
    host: string

    --- One request over the connection; nil and why when the server's reply
    --- cannot be read.
    request: function(self: Loopback, method: string, path: string,
        opts?: Types.TestOptions): Types.TestResponse | nil, string
    --- A GET.
    get: function(self: Loopback, path: string,
        opts?: Types.TestOptions): Types.TestResponse | nil, string
    --- A POST.
    post: function(self: Loopback, path: string,
        opts?: Types.TestOptions): Types.TestResponse | nil, string
    --- A HEAD.
    head: function(self: Loopback, path: string,
        opts?: Types.TestOptions): Types.TestResponse | nil, string
    --- Sends `bytes` as they are and reads the reply: for a request no
    --- well-formed client would send.
    raw: function(self: Loopback, bytes: string, method?: string): Types.TestResponse | nil, string
  end
end

local type Reply = Types.Response
local type Options = Types.TestOptions
local type Response = Types.TestResponse

--- Every name of `table`, sorted.
local function sorted_names<V>(table_: {string:V}): {string}
  local names: {string} = {}
  for name in pairs(table_) do names[#names + 1] = name end
  table.sort(names)
  return names
end

--- The pairs of `values`, a name to a string or a list, in name order.
local function pairs_of(values: {string: string | {string}}): {Url.Pair}
  local out: {Url.Pair} = {}
  for _, name in ipairs(sorted_names(values)) do
    local value = values[name]
    if value is string then
      out[#out + 1] = { name = name, value = value }
    else
      for _, each in ipairs(value) do out[#out + 1] = { name = name, value = each } end
    end
  end
  return out
end

--- What a request is made of: the target, headers and body.
local record Prepared
  target: string
  path: string
  query: string
  headers: {string:string}
  body: string
end

--- Reads a Reader whole; the body of a request is bytes to the server.
local function bytes_of(body: string | Stream.Reader): string
  if body is string then return body end
  local data, why = Stream.read_all(body)
  if data == nil then error("web: test client: reading the request body: " .. why, 3) end
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
  if opts.query ~= nil then
    local extra = Url.encode_query(pairs_of(opts.query))
    if extra ~= "" then query = query == "" and extra or query .. "&" .. extra end
  end
  local headers: {string:string} = { host = "testserver" }
  for name, value in pairs(opts.headers or {}) do headers[name:lower()] = value end
  local body = ""
  if opts.form ~= nil then
    body = Url.encode_query(pairs_of(opts.form))
    headers["content-type"] = headers["content-type"] or "application/x-www-form-urlencoded"
  elseif opts.json ~= nil then
    local text, why = Json.encode(opts.json)
    if text == nil then error("web: test client: json: " .. why, 3) end
    body = text
    headers["content-type"] = headers["content-type"] or "application/json"
  elseif opts.body ~= nil then
    body = bytes_of(opts.body)
    if opts.content_type ~= nil then headers["content-type"] = opts.content_type end
  end
  if body ~= "" or method == "POST" or method == "PUT" or method == "PATCH" then
    headers["content-length"] = tostring(#body)
  end
  return { target = base .. (query ~= "" and "?" .. query or ""), path = base, query = query,
    headers = headers, body = body }
end

local REDIRECT <const>: {integer:boolean} = {
  [301] = true, [302] = true, [303] = true, [307] = true, [308] = true,
}

local function header_list(self: Response, name: string): {string}
  local out: {string} = {}
  for i, line in ipairs(self.lines[name:lower()] or {}) do out[i] = line end
  return out
end

local function text(self: Response): string
  return self.body
end

local function json(self: Response): any | nil, string
  local value, why = Json.decode(self.body)
  if why ~= "" then return nil, why end
  return value, ""
end

local response_mt: metatable<Response> = {
  __index = { header_list = header_list, text = text, json = json },
}

--- A response from `lines`, header lines as `{name, value}` in order.
local function response_of(status: integer, lines: {{string}}, body: string): Response
  local headers: {string:string} = {}
  local by_name: {string:{string}} = {}
  for _, line in ipairs(lines) do
    local name = line[1]:lower()
    headers[name] = headers[name] == nil and line[2] or headers[name] .. ", " .. line[2]
    by_name[name] = by_name[name] or {}
    table.insert(by_name[name], line[2])
  end
  local response: Response = { status = status, headers = headers, lines = by_name, body = body,
    ok = status >= 200 and status < 300 }
  if REDIRECT[status] then response.redirect_location = headers["location"] end
  return setmetatable(response, response_mt)
end

--- Runs `fn` in a [`Poll.run`] unless the caller is already in a task of one.
local function in_loop(fn: function())
  if Poll.in_task() then
    fn()
  else
    Poll.run(fn)
  end
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
    if cleanup == nil and why ~= nil and why ~= "" then
      error("web: test client: the lifespan failed: " .. why, 0)
    end
    client.shutdown = cleanup
  end
  client.started = true
end

--- Updates the jar with a `Set-Cookie` line: the name and value, and a
--- cookie with `Max-Age` of 0 or less deleted. Its other attributes are
--- not read.
-- TODO: once cosmic.web.cookies has `parse_set_cookie`, read Path, Expires
-- and Secure here as a browser does.
local function remember(jar: {string:string}, line: string)
  local name, value = line:match("^%s*([^=;%s]+)=([^;]*)")
  if name == nil then return end
  local max_age = line:lower():match(";%s*max%-age%s*=%s*(%-?%d+)")
  if max_age ~= nil and math.tointeger(tonumber(max_age)) <= 0 then
    jar[name] = nil
  else
    jar[name] = value
  end
end

--- The header lines of `reply`, in name order: `{name, value}`.
local function lines_of(reply: Reply): {{string}}
  local out: {{string}} = {}
  local headers = reply.headers or {}
  for _, name in ipairs(sorted_names(headers)) do
    local value = headers[name]
    if value is string then
      out[#out + 1] = { name, value }
    else
      for _, each in ipairs(value) do out[#out + 1] = { name, each } end
    end
  end
  return out
end

--- One request to the app, with no redirect followed.
local function send(client: Testing.Client, method: string, path: string, opts: Options): Response
  start(client)
  local prepared = prepare(method, path, opts)
  local cookies: {string:string} = {}
  for name, value in pairs(client.jar) do cookies[name] = value end
  for name, value in pairs(opts.cookies or {}) do cookies[name] = value end
  if next(cookies) ~= nil then
    local list: {string} = {}
    for _, name in ipairs(sorted_names(cookies)) do
      list[#list + 1] = name .. "=" .. cookies[name]
    end
    local sent = table.concat(list, "; ")
    local old = prepared.headers["cookie"]
    prepared.headers["cookie"] = old ~= nil and old .. "; " .. sent or sent
  end
  local raw: Server.Request = {
    method = method, target = prepared.target, path = prepared.path, query = prepared.query,
    version = "HTTP/1.1", headers = prepared.headers, body = Stream.from_string(prepared.body),
    length = #prepared.body, peer = Net.tcp("127.0.0.1", 50000),
  }
  local result: Response = nil
  in_loop(function()
    local reply = client.app.handle(raw)
    local trouble = Server.check(reply, method)
    if trouble ~= "" then
      local unsent = type(reply) == "table" and reply.body or nil
      if unsent ~= nil and not unsent is string then
        local _, _ = unsent:close()
      end
      error("web: test client: the server would answer 500 for this reply: " .. trouble, 0)
    end
    local lines = lines_of(reply)
    local body = ""
    local stream: Stream.Reader = nil
    local given = reply.body
    local length: integer = nil
    if given is string then
      body = given
      length = #given
    elseif given ~= nil then
      length = reply.length
      if method == "HEAD" or bodiless(reply.status) then
        local _, _ = given:close()
      elseif opts.stream then
        stream = given
      else
        local data, why = Stream.read_all(given)
        local _, _ = given:close()
        if data == nil then error("web: test client: reading the reply body: " .. why, 0) end
        body = data
        length = #data
      end
    else
      length = reply.length or 0
    end
    local has_length = false
    for _, line in ipairs(lines) do
      if line[1]:lower() == "content-length" then has_length = true end
    end
    if not has_length and length ~= nil and not bodiless(reply.status) then
      lines[#lines + 1] = { "content-length", tostring(length) }
    end
    if method == "HEAD" or bodiless(reply.status) then body = "" end
    result = response_of(reply.status, lines, body)
    result.stream = stream
  end)
  for _, line in ipairs(result.lines["set-cookie"] or {}) do remember(client.jar, line) end
  return result
end

local function request(self: Testing.Client, method: string, path: string, opts?: Options): Response
  opts = opts or {}
  local res = send(self, method, path, opts)
  local hops = 0
  while opts.follow_redirects and res.redirect_location ~= nil and hops < 10 do
    hops = hops + 1
    local target = res.redirect_location
    if target:sub(1, 1) ~= "/" then
      local parts, why = Url.parse(target)
      if parts == nil then
        error("web: test client: the redirect to " .. target .. ": " .. why, 2)
      end
      target = parts.path .. (parts.query ~= nil and "?" .. parts.query or "")
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

local client_mt: metatable<Testing.Client>

local function verb(method: string): function(self: Testing.Client, path: string, opts?: Options): Response
  return function(self: Testing.Client, path: string, opts?: Options): Response
    return self:request(method, path, opts)
  end
end

client_mt = {
  __index = {
    request = request, get = verb("GET"), head = verb("HEAD"), post = verb("POST"),
    put = verb("PUT"), patch = verb("PATCH"), delete = verb("DELETE"), options = verb("OPTIONS"),
  },
  __close = function(self: Testing.Client)
    local shutdown = self.shutdown
    self.shutdown = nil
    if shutdown ~= nil then shutdown() end
  end,
}

--- A client that calls `app` in-process: it builds a [`Server.Request`] and
--- calls `app.handle`, so the middleware and the router are the served
--- ones. It keeps a cookie jar across calls, runs the app's lifespan at
--- its first request (and its cleanup when closed), runs each call in a
--- [`Poll.run`] unless the caller is in one, and fails a call whose reply
--- the server would answer 500 for.
--- @param app Types.App The app
--- @return Testing.Client The client
function Testing.test_client(app: Types.App): Testing.Client
  return setmetatable({ app = app, jar = {}, started = false }, client_mt)
end

--- Runs `fn` with a client of `app` in one [`Poll.run`], the lifespan
--- started before it and cleaned up after it, so a handler that waits and
--- a resource the lifespan opens both work for every call `fn` makes.
--- @param app Types.App The app
--- @param fn function(client: Testing.Client) The test
function Testing.with_client(app: Types.App, fn: function(client: Testing.Client))
  local client <close> = Testing.test_client(app)
  start(client)
  Poll.run(function() fn(client) end)
end

--- How long a connect, a read or a write of the loopback client waits: a
--- server that goes silent fails the test in this long, not never.
local IO_TIMEOUT_NS <const> = Clock.seconds(5)

--- Reads more of the connection into the buffer.
local function fill(lb: Testing.Loopback): boolean, string
  local piece, why = lb.conn:read()
  if piece == nil then return false, why end
  lb.buf = lb.buf .. piece
  return true, ""
end

--- The next line, without its CRLF; nil and why where the connection ends.
local function next_line(lb: Testing.Loopback): string | nil, string
  while true do
    local at = lb.buf:find("\r\n", 1, true)
    if at ~= nil then
      local found = lb.buf:sub(1, at - 1)
      lb.buf = lb.buf:sub(at + 2)
      return found, ""
    end
    local ok, why = fill(lb)
    if not ok then return nil, why ~= "" and why or "the connection ended within a head" end
  end
end

--- The next `n` bytes.
local function take(lb: Testing.Loopback, n: integer): string | nil, string
  while #lb.buf < n do
    local ok, why = fill(lb)
    if not ok then return nil, why ~= "" and why or "the connection ended within a body" end
  end
  local out = lb.buf:sub(1, n)
  lb.buf = lb.buf:sub(n + 1)
  return out, ""
end

--- The reply to a request of `method`, read off the connection.
local function read_reply(lb: Testing.Loopback, method: string): Response | nil, string
  local status_line, why = next_line(lb)
  if status_line == nil then return nil, why end
  local code = status_line:match("^HTTP/1%.[01] (%d%d%d)")
  if code == nil then return nil, "not a status line: " .. status_line end
  local status = math.tointeger(tonumber(code))
  local lines: {{string}} = {}
  local headers: {string:string} = {}
  while true do
    local line, line_why = next_line(lb)
    if line == nil then return nil, line_why end
    if line == "" then break end
    local name, rest = line:match("^([^:]+):(.*)$")
    if name == nil then return nil, "not a header line: " .. line end
    local value = String.trim(rest)
    lines[#lines + 1] = { name, value }
    headers[name:lower()] = value
  end
  local body = ""
  if method ~= "HEAD" and not bodiless(status) then
    if (headers["transfer-encoding"] or ""):lower() == "chunked" then
      local pieces: {string} = {}
      while true do
        local size_line, size_why = next_line(lb)
        if size_line == nil then return nil, size_why end
        local digits = size_line:match("^(%x+)$") or size_line:match("^(%x+);")
        if digits == nil then return nil, "not a chunk size: " .. size_line end
        local size = tonumber(digits, 16)
        if size == nil then return nil, "not a chunk size: " .. size_line end
        if size == 0 then
          repeat
            local trailer, trailer_why = next_line(lb)
            if trailer == nil then return nil, trailer_why end
          until trailer == ""
          break
        end
        local data, data_why = take(lb, math.tointeger(size))
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
        if not ok then
          if fill_why ~= "" then return nil, fill_why end
          break
        end
      end
      body = lb.buf
      lb.buf = ""
    end
  end
  return response_of(status, lines, body), ""
end

local function loopback_raw(self: Testing.Loopback, bytes: string, method?: string): Response | nil, string
  local sent, why = self.conn:write(bytes)
  if not sent then return nil, why end
  return read_reply(self, method or "GET")
end

local function loopback_request(self: Testing.Loopback, method: string, path: string,
                                opts?: Options): Response | nil, string
  local prepared = prepare(method, path, opts or {})
  prepared.headers["host"] = self.host
  local head: {string} = { ("%s %s HTTP/1.1"):format(method, prepared.target) }
  for _, name in ipairs(sorted_names(prepared.headers)) do
    head[#head + 1] = name .. ": " .. prepared.headers[name]
  end
  return loopback_raw(self, table.concat(head, "\r\n") .. "\r\n\r\n" .. prepared.body, method)
end

local function loopback_verb(method: string): function(Testing.Loopback, string, Options | nil): Response | nil, string
  return function(self: Testing.Loopback, path: string, opts?: Options): Response | nil, string
    return self:request(method, path, opts)
  end
end

local loopback_mt: metatable<Testing.Loopback> = {
  __index = {
    request = loopback_request, raw = loopback_raw, get = loopback_verb("GET"),
    post = loopback_verb("POST"), head = loopback_verb("HEAD"),
  },
}

--- Serves `app` through [`Web.serve`] on 127.0.0.1 at a port the kernel
--- chooses, calls `fn` with a client of it over one kept-alive connection,
--- and stops the server when `fn` returns. What `fn` raises is raised
--- again once the server has stopped. It is for what the in-process client
--- cannot see: real framing, `Connection: close`, what the server answers
--- itself, and graceful stop. It runs a [`Poll.run`] of its own, so it
--- cannot be called in a task, and a test using it declares
--- `Test.policy{ loopback = { "127.0.0.1" } }`.
--- @param app Types.App The app
--- @param fn function(client: Testing.Loopback) The test
function Testing.with_server(app: Types.App, fn: function(client: Testing.Loopback))
  local failure: string = nil
  local ok, why = App.serve(app, {
    listeners = { Net.tcp("127.0.0.1", 0) },
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local conn, connect_why = Net.connect(addresses[1], { timeout_ns = IO_TIMEOUT_NS })
      if conn == nil then
        failure = "web: with_server: connecting: " .. connect_why
        server:stop()
        return
      end
      conn:set_timeout(IO_TIMEOUT_NS)
      local client: Testing.Loopback = setmetatable({ conn = conn, buf = "",
        host = "127.0.0.1:" .. addresses[1].port }, loopback_mt)
      local ran, raised = pcall(function() fn(client) end)
      if not ran then failure = tostring(raised) end
      local _, _ = conn:close()
      server:stop()
    end,
  })
  if failure ~= nil then error(failure, 0) end
  if not ok then error("web: with_server: " .. why, 2) end
end

return Testing
