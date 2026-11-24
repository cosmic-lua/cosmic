--- The client side of MCP authorization (revision 2026-07-28): how
--- [`McpClient.http`] signs in to a server that is an OAuth 2.1
--- resource server, as [`McpClient.HttpOptions.oauth`] asks.
---
--- A 401 from the server starts a sign-in:
---
--- 1. The server's protected resource metadata (RFC 9728), from the
---    `resource_metadata` its challenge names, or its well-known URL.
---    Its `resource` must be the endpoint's URL, as the client uses it.
--- 2. The metadata of its first authorization server (RFC 8414, or
---    OpenID Connect discovery), whose `issuer` must be the one named,
---    and which must take PKCE's S256: a server that does not say so is
---    refused.
--- 3. An authorization code, with PKCE and a `state`, at a redirect
---    to a listener of this client on 127.0.0.1: [`Options.open`] shows
---    the person the authorization URL. The redirect's `state` must be
---    the one sent, and its `iss` (RFC 9207) the issuer's.
--- 4. Tokens for that code, asked for with the endpoint as `resource`
---    (RFC 8707), so they are good at this server and no other.
---
--- A 401 that says the token is refused (`invalid_token`) refreshes it
--- first, where there is a refresh token; a refresh that fails drops
--- the refresh token, and signs in. A token the refresh gave that is
--- refused too signs in. A sign-in asks for the scopes already granted
--- with those the challenge names, so a 403 of `insufficient_scope`
--- steps up. A request is sent again once after a refresh, once after a
--- 401's sign-in and once after a 403's, so a server that takes no
--- token ends it.
--- Requests of a session in flight at once sign in once: the others
--- wait for that sign-in, and use what it got.
---
--- The client has a `client_id` already: one the authorization server
--- registered, or a client ID metadata document's URL. It neither
--- registers itself nor serves the document. The redirect URI is
--- `http://127.0.0.1:<port>/callback`, on a port the kernel chooses, so
--- the authorization server must take any port for a loopback redirect,
--- as RFC 8252 says. Only the first authorization server the metadata
--- names is used.
---
--- Security: every URL of the flow must be https; http, and any URL on
--- this machine, only where the endpoint is on a loopback address, so
--- a remote server cannot aim the client at this machine's services.
--- The access token is sent only to the endpoint, and the refresh token
--- only to the token endpoint of the issuer that gave it; no redirect is
--- followed. The listener for the redirect responds to a request at another
--- path, or one with another `state` (a page that guesses the port), and
--- keeps waiting; each connection has 5 seconds to send its request.
--- [`McpOAuth.Options.store`] keeps tokens between runs: what it writes is a
--- secret, to keep where only this user reads it.
--- @public

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Failure = require("cosmic.failure")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Message = require("cosmic.http.message")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Rand = require("cosmic.rand")
local Url = require("cosmic.url")
local wire = require("cosmic.mcp.wire")

local record McpOAuth
  --- What a sign-in got for one endpoint.
  record Tokens
    --- The access token, sent as `Authorization: Bearer`.
    access_token: string
    --- The refresh token, where the authorization server gave one.
    refresh_token?: string
    --- When the access token expires, in seconds since the epoch; nil
    --- where the authorization server did not say.
    expires?: integer
    --- The scopes granted: what the server said, or what was asked for.
    scopes: {string}
    --- The authorization server that issued them.
    issuer: string
    --- Its token endpoint, where `refresh_token` goes.
    token_endpoint: string
  end

  --- Where a client keeps tokens between runs.
  record Store
    --- The tokens kept for the endpoint `resource`, or nil.
    load: function(resource: string): Tokens?
    --- Keeps `tokens` for the endpoint `resource`, in place of any.
    save: function(resource: string, tokens: Tokens)
  end

  --- How a client signs in ([`McpClient.HttpOptions.oauth`]).
  record Options
    --- The client's ID at the authorization server: one registered
    --- there, or the https URL of its client ID metadata document.
    client_id: string
    --- Shows the person `url`, where they sign in and consent: print
    --- it, or open it in a browser. It returns once shown, before the
    --- person is done; the redirect comes to the client.
    open: function(url: string): (true) | (false, Failure)
    --- The scopes to ask for where neither the challenge nor the
    --- server's metadata names any.
    scopes?: {string}
    --- Keeps tokens between runs; nil keeps them only in this session.
    store?: Store
    --- How long each request of the flow may take (30 s).
    timeout_ns?: integer
    --- How long to wait for the person to sign in (5 minutes).
    wait_ns?: integer
  end

  --- What [`McpOAuth.new`] makes: the sign-in state of one endpoint.
  record Auth
    --- The `Authorization` header to send, or nil before a sign-in.
    authorization: function(): string?
    --- After a response of `status` (401 or 403) with the challenge
    --- `header`: refreshes (where `may_refresh`), signs in or steps up,
    --- for the request to be sent again; how, or why it cannot be.
    challenged: function(status: integer, header?: string, may_refresh?: boolean): (Remedy) | (nil, Failure)
  end

  --- How a refusal was met: the token refreshed, or a sign-in (this
  --- request's or another's it waited for).
  enum Remedy
    "refreshed"
    "signed_in"
  end
end

local TIMEOUT_NS <const> = Clock.seconds(30)
local WAIT_NS <const> = Clock.minutes(5)
--- The most bytes a metadata document or a token response may hold.
local MAX_DOC_BYTES <const> = 64 * 1024
local CALLBACK <const> = "/callback"

--- Whether `host` is this machine's loopback, as an address: a name could be resolved elsewhere.
local function loopback(host: string): boolean
  return host == "127.0.0.1" or host == "::1" or host == "[::1]"
end

--- `text` as untrusted words in a message: at most `n` bytes, cut where a character starts, and quoted.
local function clip(text: string, n: integer): string
  if #text <= n then return Json.quote(text) end
  local at = n
  while at > 0 do
    local b = assert(text:byte(at + 1))
    if b < 0x80 or b >= 0xC0 then break end
    at = at - 1
  end
  return Json.quote(text:sub(1, at)) .. "..."
end

--- `text`'s parts where it is a URL the flow may use: https, or http for a loopback address where `local_ok`
--- (the endpoint is itself on loopback, so a remote server cannot aim the client at this machine); no user, no
--- fragment.
local function secure(text: string, what: string, local_ok: boolean): (Url.Parts) | (nil, Failure)
  local parts, why = Url.parse(text)
  if parts == nil then return nil, Failure.new("mcp: oauth: " .. what .. ": " .. why.message) end
  local is_loopback = loopback(parts.host)
  if parts.scheme == "http" and not is_loopback then
    return nil, Failure.new("mcp: oauth: " .. what .. " " .. clip(text, 200) .. " is not https")
  end
  if parts.scheme ~= "https" and parts.scheme ~= "http" then
    return nil, Failure.new("mcp: oauth: " .. what .. " " .. clip(text, 200) .. " is not https")
  end
  if is_loopback and not local_ok then
    return nil, Failure.new("mcp: oauth: " .. what .. " " .. clip(text, 200) ..
        " is on this machine, and the endpoint is not")
  end
  if parts.userinfo ~= nil or parts.fragment ~= nil then
    return nil, Failure.new("mcp: oauth: " .. what .. " " .. clip(text, 200) .. " has a user or a fragment")
  end
  return parts
end

--- `parts`' scheme, host and port.
local function origin_of(parts: Url.Parts): string
  local host = if parts.host:find(":", 1, true) ~= nil and parts.host:sub(1, 1) ~= "[" then
    "[" .. parts.host .. "]" else parts.host end
  return parts.scheme .. "://" .. host .. (if parts.port ~= nil then ":" .. tostring(parts.port) else "" end)
end

--- What a GET of a metadata document found: the document, or none there (a 4xx: many servers respond 401 or
--- 403 for a path they do not serve, and the next URL is to be tried).
local record Fetched
  doc?: {string: Json.Value}
end

--- The JSON object at `url`, none where it is not found (404), or why there is neither.
local function fetch(url: string, timeout_ns: integer, what: string): (Fetched) | (nil, Failure)
  local got, why = Http.request("GET", url, { timeout_ns = timeout_ns, follow = false, max_bytes = MAX_DOC_BYTES,
    headers = { Accept = "application/json" } })
  if got == nil then return nil, Failure.new("mcp: oauth: " .. what .. ": " .. tostring(why)) end
  if got.status >= 400 and got.status < 500 then return { doc = nil } end
  if got.status ~= 200 then
    return nil, Failure.new("mcp: oauth: " .. what .. ": HTTP " .. tostring(got.status) .. " from " .. url)
  end
  local decoded, bad = Json.decode(got.body)
  if decoded == nil then
    return nil, Failure.new("mcp: oauth: " .. what .. ": " .. tostring(bad))
  end
  local doc = Json.object_of(decoded)
  if doc == nil then return nil, Failure.new("mcp: oauth: " .. what .. " is not a JSON object") end
  return { doc = doc }
end

--- The strings of `v`, a JSON array; nil where it is none or holds another value.
local function strings_of(v?: Json.Value): {string}?
  local array = Json.array_of(v)
  if array == nil then return nil end
  local out: mut {string} = {}
  for _, each in ipairs(array) do
    if not each is string then return nil end
    out[#out + 1] = each
  end
  return out
end

--- What the flow needs of a server's protected resource metadata.
local record Resource
  resource: string
  authorization_servers: {string}
  scopes?: {string}
end

--- The protected resource metadata of the endpoint `url`: at `named`, or at its well-known URLs.
local function resource_of(url: string, named: string?, timeout_ns: integer, local_ok: boolean):
    (Resource) | (nil, Failure)
  local parts, why = secure(url, "the endpoint", local_ok)
  if parts == nil then return nil, why end
  local tries: mut {string} = {}
  if named ~= nil then
    local at, bad = secure(named, "resource_metadata", local_ok)
    if at == nil then return nil, bad end
    tries[1] = named
  else
    local origin = origin_of(parts)
    local path = if parts.path == "/" then "" else parts.path end
    if path ~= "" then
      tries[#tries + 1] = origin .. "/.well-known/oauth-protected-resource" .. path
    end
    tries[#tries + 1] = origin .. "/.well-known/oauth-protected-resource"
  end
  for _, each in ipairs(tries) do
    local fetched, fwhy = fetch(each, timeout_ns, "protected resource metadata")
    if fetched == nil then return nil, fwhy end
    local doc = fetched.doc
    if doc ~= nil then
      local resource = doc["resource"]
      if resource ~= url then
        return nil, Failure.new("mcp: oauth: the protected resource metadata at " .. each .. " is for " ..
            clip(tostring(resource), 200) .. ", not " .. Json.quote(url))
      end
      local servers = strings_of(doc["authorization_servers"])
      if servers == nil or #servers < 1 then
        return nil, Failure.new("mcp: oauth: the protected resource metadata at " .. each .. " names no authorization server")
      end
      return { resource = url, authorization_servers = servers, scopes = strings_of(doc["scopes_supported"]) }
    end
  end
  return nil, Failure.new("mcp: oauth: no protected resource metadata for " .. url)
end

--- What the flow needs of an authorization server's metadata.
local record Issuer
  issuer: string
  authorization_endpoint: string
  token_endpoint: string
  --- Whether the redirect carries `iss`, which must then be there.
  iss_required: boolean
end

--- The metadata of the authorization server `issuer`, its URLs tried in the order the spec gives.
local function issuer_of(issuer: string, timeout_ns: integer, local_ok: boolean): (Issuer) | (nil, Failure)
  local parts, why = secure(issuer, "the issuer", local_ok)
  if parts == nil then return nil, why end
  if parts.query ~= nil then
    return nil, Failure.new("mcp: oauth: the issuer " .. Json.quote(issuer) .. " has a query")
  end
  local origin = origin_of(parts)
  local path = if parts.path == "/" then "" else parts.path end
  local tries: {string} = if path ~= "" then {
    origin .. "/.well-known/oauth-authorization-server" .. path,
    origin .. "/.well-known/openid-configuration" .. path,
    origin .. path .. "/.well-known/openid-configuration",
  } else {
    origin .. "/.well-known/oauth-authorization-server",
    origin .. "/.well-known/openid-configuration",
  } end
  for _, each in ipairs(tries) do
    local fetched, fwhy = fetch(each, timeout_ns, "authorization server metadata")
    if fetched == nil then return nil, fwhy end
    local doc = fetched.doc
    if doc ~= nil then
      if doc["issuer"] ~= issuer then
        return nil, Failure.new("mcp: oauth: the metadata at " .. each .. " is for the issuer " ..
            clip(tostring(doc["issuer"]), 200) .. ", not " .. Json.quote(issuer))
      end
      local methods = strings_of(doc["code_challenge_methods_supported"]) or {}
      local s256 = false
      for _, m in ipairs(methods) do
        if m == "S256" then s256 = true end
      end
      if not s256 then
        return nil, Failure.new("mcp: oauth: the authorization server " .. issuer .. " does not say it takes PKCE's S256")
      end
      local authorize, token = doc["authorization_endpoint"], doc["token_endpoint"]
      if not authorize is string or not token is string then
        return nil, Failure.new("mcp: oauth: the authorization server " .. issuer .. " names no authorization or token endpoint")
      end
      local a, awhy = secure(authorize, "authorization_endpoint", local_ok)
      if a == nil then return nil, awhy end
      local t, twhy = secure(token, "token_endpoint", local_ok)
      if t == nil then return nil, twhy end
      return { issuer = issuer, authorization_endpoint = authorize, token_endpoint = token,
        iss_required = doc["authorization_response_iss_parameter_supported"] == true }
    end
  end
  return nil, Failure.new("mcp: oauth: no authorization server metadata for " .. issuer)
end

--- `count` random bytes as base64url.
local function random(count: integer): (string) | (nil, Failure)
  local bytes, why = Rand.entropy(count)
  if bytes == nil then return nil, Failure.new("mcp: oauth: " .. why) end
  return Codec.base64url(bytes)
end

--- Writes a plain-text reply of `status` with `text` on `conn`, and closes it.
local function reply(conn: Net.Conn, status: integer, text: string)
  local reason = if status == 200 then "OK" elseif status == 400 then "Bad Request" else "Not Found" end
  local head = "HTTP/1.1 " .. tostring(status) .. " " .. reason ..
    "\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: " .. tostring(#text) ..
    "\r\nConnection: close\r\n\r\n"
  local _, _ = conn:write(head .. text)
  local _, _ = conn:close()
end

--- How long one connection to the listener may take to send its request.
local HEAD_NS <const> = Clock.seconds(5)

--- The request one connection `conn` sends, read within `HEAD_NS`; nil where it sends none in time.
local function request_of(conn: Net.Conn): Message.Request?
  local until_ns = Clock.monotonic_ns() + HEAD_NS
  local reader = Message.request_reader({ head_bytes = 16 * 1024, body_bytes = 1 })
  local read = reader:feed("")
  while read.status == "more" and Clock.monotonic_ns() < until_ns do
    local bytes, _ = conn:read(4096)
    if bytes == nil or bytes == "" then break end
    read = reader:feed(bytes)
  end
  return read.request
end

--- The code of the redirect to `listener` that carries `state`, taken before `deadline_ns`. A request at another
--- path, or with another state (a page that guesses the port), gets a response and the wait goes on; the
--- redirect with this state ends it, its `iss` checked against `server`.
local function callback(listener: Net.Listener, deadline_ns: integer, state: string, server: Issuer):
    (string) | (nil, Failure)
  while true do
    local left = deadline_ns - Clock.monotonic_ns()
    if left <= 0 then return nil, Failure.timeout("mcp: oauth: no sign-in came back in time") end
    -- A connection accepted takes the listener's limit for each of its reads.
    listener:set_timeout(if left < HEAD_NS then left else HEAD_NS end)
    local conn, why = listener:accept(left)
    if conn == nil then
      if why.kind == "cancelled" then
        return nil, Failure.cancelled("mcp: oauth: the sign-in was cancelled")
      end
      if why.kind == "timeout" then
        return nil, Failure.timeout("mcp: oauth: no sign-in came back in time")
      end
      return nil, Failure.new("mcp: oauth: waiting for the sign-in: " .. tostring(why))
    end
    local request = request_of(conn)
    local target = if request ~= nil then request.target else "" end
    local path, query_text = target:match("^([^?]*)%??(.*)$")
    local query: Url.Query? = nil
    if request ~= nil and request.method == "GET" and path == CALLBACK then
      local decoded, _ = Url.decode_query(query_text or "")
      query = decoded
    end
    if query == nil then
      reply(conn, 404, "Not found.\n")
    elseif not Hash.equal(Url.query_first(query, "state") or "", state) then
      reply(conn, 400, "This is not the sign-in this program waits for.\n")
    else
      local iss = Url.query_first(query, "iss")
      if (iss == nil and server.iss_required) or (iss ~= nil and iss ~= server.issuer) then
        reply(conn, 400, "The sign-in came from another authorization server.\n")
        return nil, Failure.new("mcp: oauth: the redirect's iss is not " .. Json.quote(server.issuer))
      end
      local err = Url.query_first(query, "error")
      if err ~= nil then
        reply(conn, 400, "The sign-in was refused.\n")
        local said = Url.query_first(query, "error_description")
        return nil, Failure.new("mcp: oauth: the authorization server refused: " .. clip(err, 100) ..
            (if said ~= nil then " (" .. clip(said, 200) .. ")" else "" end))
      end
      local code = Url.query_first(query, "code")
      if code == nil or code == "" then
        reply(conn, 400, "The sign-in came back with no code.\n")
        return nil, Failure.new("mcp: oauth: the redirect has no code")
      end
      reply(conn, 200, "Signed in. You may close this window.\n")
      return code
    end
  end
end

--- The scopes in `a` and then those in `b`, each once.
local function union(a: {string}, b: {string}): {string}
  local out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  for _, list in ipairs({ a, b }) do
    for _, each in ipairs(list) do
      if seen[each] == nil then
        seen[each] = true
        out[#out + 1] = each
      end
    end
  end
  return out
end

--- The tokens a token endpoint's response `got` holds, asked for with `scopes`.
local function tokens_of(got: Http.Body, scopes: {string}, server: Issuer, refresh?: string): (McpOAuth.Tokens) | (nil, Failure)
  local decoded, bad = Json.decode(got.body)
  local doc = if decoded ~= nil then Json.object_of(decoded) else nil end
  if doc == nil then
    return nil, Failure.new("mcp: oauth: the token endpoint answered HTTP " .. tostring(got.status) ..
        " with no JSON object" .. (if bad ~= nil then ": " .. tostring(bad) else "" end))
  end
  if got.status ~= 200 then
    local err, said = doc["error"], doc["error_description"]
    return nil, Failure.new("mcp: oauth: the token endpoint refused: " .. clip(tostring(err), 100) ..
        (if said is string then " (" .. clip(said, 200) .. ")" else "" end))
  end
  local access, kind = doc["access_token"], doc["token_type"]
  if not access is string or access == "" then
    return nil, Failure.new("mcp: oauth: the token endpoint gave no access_token")
  end
  if not kind is string or kind:lower() ~= "bearer" then
    return nil, Failure.new("mcp: oauth: the token endpoint gave a token_type that is not Bearer")
  end
  local expires: integer? = nil
  local life = doc["expires_in"]
  if life is number then
    local whole = math.tointeger(life)
    if whole ~= nil and whole > 0 then expires = Clock.now_ns() // 1000000000 + whole end
  end
  local granted = scopes
  local scope = doc["scope"]
  if scope is string then
    local list: mut {string} = {}
    for each in scope:gmatch("%S+") do list[#list + 1] = each end
    granted = list
  end
  local new_refresh = doc["refresh_token"]
  return { access_token = access, refresh_token = if new_refresh is string then new_refresh else refresh end,
    expires = expires, scopes = granted, issuer = server.issuer, token_endpoint = server.token_endpoint }
end

--- Posts the form `pairs` to the token endpoint of `server`.
local function token_request(server: Issuer, pairs_: {Url.Pair}, timeout_ns: integer): (Http.Body) | (nil, Failure)
  local got, why = Http.request("POST", server.token_endpoint, { timeout_ns = timeout_ns, follow = false,
    max_bytes = MAX_DOC_BYTES, body = Url.encode_query(pairs_),
    headers = { ["Content-Type"] = "application/x-www-form-urlencoded", Accept = "application/json" } })
  if got == nil then
    return nil, Failure.new("mcp: oauth: the token endpoint: " .. tostring(why))
  end
  return got
end

--- Signs in at `server` for `resource` with `scopes`: the person consents, and the code is traded for tokens.
local function sign_in(opts: McpOAuth.Options, resource: string, server: Issuer, scopes: {string}):
    (McpOAuth.Tokens) | (nil, Failure)
  local timeout_ns = opts.timeout_ns or TIMEOUT_NS
  local verifier, vwhy = random(32)
  if verifier == nil then return nil, vwhy end
  local state, swhy = random(16)
  if state == nil then return nil, swhy end
  local listener, lwhy = Net.listen(Net.tcp("127.0.0.1", 0))
  if listener == nil then
    return nil, Failure.new("mcp: oauth: listening for the redirect: " .. lwhy.message)
  end
  local port = assert(listener.address.port)
  local redirect = "http://127.0.0.1:" .. tostring(port) .. CALLBACK
  local query: mut {Url.Pair} = {
    { name = "response_type", value = "code" },
    { name = "client_id", value = opts.client_id },
    { name = "redirect_uri", value = redirect },
    { name = "code_challenge", value = Codec.base64url(Hash.sha256(verifier)) },
    { name = "code_challenge_method", value = "S256" },
    { name = "state", value = state },
    { name = "resource", value = resource },
  }
  if #scopes > 0 then query[#query + 1] = { name = "scope", value = table.concat(scopes, " ") } end
  local sep = if server.authorization_endpoint:find("?", 1, true) ~= nil then "&" else "?" end
  local shown, owhy = opts.open(server.authorization_endpoint .. sep .. Url.encode_query(query))
  if not shown then
    local _, _ = listener:close()
    return nil, owhy
  end
  local code, cwhy = callback(listener, Clock.monotonic_ns() + (opts.wait_ns or WAIT_NS), state, server)
  local _, _ = listener:close()
  if code == nil then return nil, cwhy end
  local got, twhy = token_request(server, {
    { name = "grant_type", value = "authorization_code" },
    { name = "code", value = code },
    { name = "redirect_uri", value = redirect },
    { name = "client_id", value = opts.client_id },
    { name = "code_verifier", value = verifier },
    { name = "resource", value = resource },
  }, timeout_ns)
  if got == nil then return nil, twhy end
  return tokens_of(got, scopes, server)
end

--- The sign-in state of the endpoint `resource` (its URL, as the client uses it), signing in as `opts` says.
function McpOAuth.new(resource: string, opts: McpOAuth.Options): McpOAuth.Auth
  if opts.client_id == "" then error("mcp: oauth: opts.client_id is empty", 2) end
  local timeout_ns = opts.timeout_ns or TIMEOUT_NS
  local endpoint, ewhy = Url.parse(resource)
  if endpoint == nil then error("mcp: oauth: " .. ewhy.message, 2) end
  -- http, and URLs on this machine, only for an endpoint on this machine.
  local local_ok = loopback(endpoint.host)
  local usable, uwhy = secure(resource, "the endpoint", local_ok)
  if usable == nil then error(uwhy.message, 2) end
  local store = opts.store
  local tokens: McpOAuth.Tokens? = if store ~= nil then store.load(resource) else nil end
  -- A sign-in under way, and what the requests that came during it wait on (nil outside a task).
  local busy = false
  local finished: Poll.Notifier? = nil
  -- How the last sign-in or refresh went, for the requests that waited on it.
  local last: McpOAuth.Remedy? = nil

  local function keep(got: McpOAuth.Tokens)
    tokens = got
    if store ~= nil then store.save(resource, got) end
  end

  --- Refreshes the tokens: false where there is no refresh token or the server refused it.
  local function refreshed(): boolean
    local held = tokens
    if held == nil then return false end
    local refresh = held.refresh_token
    if refresh == nil then return false end
    -- What the store gave is checked as discovery would have: the refresh token goes nowhere else.
    local at, _ = secure(held.token_endpoint, "token_endpoint", local_ok)
    if at == nil then return false end
    local server: Issuer = { issuer = held.issuer, token_endpoint = held.token_endpoint, authorization_endpoint = "",
      iss_required = false }
    local got, _ = token_request(server, {
      { name = "grant_type", value = "refresh_token" },
      { name = "refresh_token", value = refresh },
      { name = "client_id", value = opts.client_id },
      { name = "resource", value = resource },
    }, timeout_ns)
    local fresh: McpOAuth.Tokens? = nil
    if got ~= nil then
      local made, _ = tokens_of(got, held.scopes, server, refresh)
      fresh = made
    end
    if fresh == nil then
      -- Not tried again on every request: the next challenge signs in.
      tokens = { access_token = held.access_token, refresh_token = nil, expires = held.expires, scopes = held.scopes,
        issuer = held.issuer, token_endpoint = held.token_endpoint }
      return false
    end
    keep(fresh)
    return true
  end

  local function authorization(): string?
    local held = tokens
    if held == nil then return nil end
    local expires = held.expires
    if expires ~= nil and Clock.now_ns() // 1000000000 >= expires - 30 then
      if not refreshed() then return nil end
      held = assert(tokens)
    end
    return "Bearer " .. held.access_token
  end

  local function answer(status: integer, header: string?, may_refresh: boolean): (McpOAuth.Remedy) | (nil, Failure)
    local said = if header ~= nil then wire.challenge(header) else nil end
    if said == nil then
      return nil, Failure.new("mcp: oauth: the server answered HTTP " .. tostring(status) .. " with no Bearer challenge")
    end
    if status == 401 and said.error == "invalid_token" and may_refresh and refreshed() then
      return "refreshed"
    end
    if status == 403 and said.error ~= "insufficient_scope" then
      return nil, Failure.new("mcp: oauth: the server refused the token (HTTP 403)")
    end
    local found, why = resource_of(resource, said.resource_metadata, timeout_ns, local_ok)
    if found == nil then return nil, why end
    local server, swhy = issuer_of(assert(found.authorization_servers[1]), timeout_ns, local_ok)
    if server == nil then return nil, swhy end
    local none: {string} = {}
    local wanted = said.scope or found.scopes or opts.scopes or none
    -- With the scopes already granted, so a new token does not lose them.
    local held = tokens
    if held ~= nil then wanted = union(held.scopes, wanted) end
    local got, gwhy = sign_in(opts, resource, server, wanted)
    if got == nil then return nil, gwhy end
    keep(got)
    return "signed_in"
  end

  local function challenged(status: integer, header?: string, may_refresh?: boolean): (McpOAuth.Remedy) | (nil, Failure)
    if busy then
      -- Another request of the session signs in now: wait for it, and send again with what it got.
      local wait = finished
      while busy and wait ~= nil do
        local ok, why = wait:wait()
        if not ok then return nil, why end
      end
      -- What the other did: a refresh lets this request, too, sign in if the token it gave is refused.
      return last or "signed_in"
    end
    busy = true
    finished = if Poll.in_task() then Poll.notifier() else nil end
    local remedy: McpOAuth.Remedy? = nil
    local why = Failure.new("mcp: oauth: the sign-in failed")
    -- Whatever `open` or the store raises, the requests waiting are woken.
    local ran, raised = pcall(function()
      local got, failure = answer(status, header, may_refresh ~= false)
      if got ~= nil then remedy = got else why = failure end
    end)
    last = remedy
    busy = false
    local wait = finished
    finished = nil
    if wait ~= nil then wait:notify_all() end
    if not ran then error(raised, 0) end
    local got = remedy
    if got == nil then return nil, why end
    return got
  end

  return { authorization = authorization, challenged = challenged }
end

return McpOAuth
