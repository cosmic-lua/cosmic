--- [`cosmic.mcp.oauth`] through [`McpClient.http`]: a client signs in to a resource server at a fake authorization
--- server on the worker's loopback, with PKCE and a redirect to its own listener; it refreshes a refused token, steps
--- up for a tool that needs more scopes, and refuses a redirect whose state is not its own.

local Client = require("cosmic.mcp.client")
local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Failure = require("cosmic.failure")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local HttpServer = require("cosmic.http.server")
local Jose = require("cosmic.jose")
local Json = require("cosmic.json")
local Key = require("cosmic.key")
local Mcp = require("cosmic.mcp")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Server = require("cosmic.mcp.server")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local Url = require("cosmic.url")

Test.policy{ loopback = { "127.0.0.1" } }

local WAIT <const> = Clock.seconds(20)

local signer = Key.generate("p256")
local published = assert(Jose.key(Jose.jwk(signer.public, "k")))

local function instance(): Server.Instance
  return Server.new{ info = { name = "guarded", version = "1" }, tools = {
    {
      tool = { name = "read", inputSchema = Mcp.object_schema({}) },
      scopes = { "files:read" },
      call = function(_: {string: Json.Value}, call: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        return Mcp.result({ "read for " .. assert(call.grant).subject })
      end,
    },
    {
      tool = { name = "write", inputSchema = Mcp.object_schema({}) },
      scopes = { "files:write" },
      call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        return Mcp.result({ "written" })
      end,
    },
  } }
end

--- A code the fake authorization server gave, and what it was given for.
local record Grant
  challenge: string
  scope: string
  redirect: string
  resource: string
end

--- What the fake authorization server saw.
local record Seen
  mut signins: integer
  mut refreshes: integer
  mut last_scope: string
  revoked: mut {string: boolean}
  --- Every access token issued, in order.
  issued: mut {string}
  --- Whether the metadata leaves out PKCE's S256.
  mut no_s256: boolean
  --- Whether a token a refresh gives is refused too.
  mut refuse_refreshed: boolean
end

local function json_reply(status: integer, value: {string: Json.Value}): HttpServer.Reply
  return { status = status, headers = { ["Content-Type"] = "application/json" }, body = assert(Json.encode(value)) }
end

--- A fake authorization server at `base` beside an MCP endpoint at `base .. "/mcp"`.
local function serving(base: string, seen: Seen): function(HttpServer.Request): HttpServer.Reply
  local resource = base .. "/mcp"
  local codes: mut {string: Grant} = {}
  local issued = 0
  local refresh_scopes: mut {string: string} = {}
  local from_refresh: mut {string: boolean} = {}
  local jwt = Server.jwt{ issuer = base, keys = { published } }
  local mcp = instance():handler{ oauth = { resource = resource, authorization_servers = { base }, scopes = { "files:read" },
    verify = function(token: string, aimed: string): (Server.Grant) | (nil, Failure)
      if seen.revoked[token] == true then return nil, Failure.new("revoked") end
      if seen.refuse_refreshed and from_refresh[token] == true then
        return nil, Failure.new("refused")
      end
      return jwt(token, aimed)
    end } }
  local function issue(scope: string, refreshing?: boolean): {string: Json.Value}
    local now = Clock.now_ns() // 1000000000
    issued = issued + 1
    -- A `jti` of its own, so a token issued again within the second is not the one refused.
    local token = Jose.sign(signer, { iss = base, sub = "ada", aud = resource, scope = scope, exp = now + 300, iat = now,
      jti = tostring(issued) }, { typ = "at+jwt", kid = "k" })
    local refresh = "refresh-" .. tostring(issued)
    refresh_scopes[refresh] = scope
    seen.issued[#seen.issued + 1] = token
    if refreshing == true then from_refresh[token] = true end
    return { access_token = token, token_type = "Bearer", expires_in = 300, refresh_token = refresh, scope = scope }
  end
  return function(req: HttpServer.Request): HttpServer.Reply
    if req.path == "/.well-known/oauth-authorization-server" then
      return json_reply(200, { issuer = base, authorization_endpoint = base .. "/authorize", token_endpoint = base .. "/token",
        code_challenge_methods_supported = Json.array(if seen.no_s256 then { "plain" } else { "S256" } end), authorization_response_iss_parameter_supported = true })
    end
    if req.path == "/authorize" then
      local q = assert(Url.decode_query(req.query))
      assert(Url.query_first(q, "code_challenge_method") == "S256" and Url.query_first(q, "client_id") == "test-client")
      assert(Url.query_first(q, "resource") == resource, "the client asks for this endpoint's tokens")
      local redirect = assert(Url.query_first(q, "redirect_uri"))
      assert(redirect:find("^http://127%.0%.0%.1:%d+/callback$") ~= nil, redirect)
      local code = "code-" .. tostring(seen.signins)
      seen.signins = seen.signins + 1
      seen.last_scope = Url.query_first(q, "scope") or ""
      codes[code] = { challenge = assert(Url.query_first(q, "code_challenge")), scope = seen.last_scope, redirect = redirect,
        resource = resource }
      local back = Url.encode_query({ { name = "code", value = code }, { name = "state", value = Url.query_first(q, "state") or "" },
        { name = "iss", value = base } })
      return { status = 302, headers = { Location = redirect .. "?" .. back } }
    end
    if req.path == "/token" then
      local body = assert(Stream.read_up_to(req.body, 65536))
      local form = assert(Url.decode_query(body))
      local kind = Url.query_first(form, "grant_type")
      assert(Url.query_first(form, "resource") == resource)
      if kind == "authorization_code" then
        local grant = codes[Url.query_first(form, "code") or ""]
        if grant == nil then return json_reply(400, { error = "invalid_grant" }) end
        codes[Url.query_first(form, "code") or ""] = nil
        local verifier = Url.query_first(form, "code_verifier") or ""
        if Codec.base64url(Hash.sha256(verifier)) ~= grant.challenge or Url.query_first(form, "redirect_uri") ~= grant.redirect then
          return json_reply(400, { error = "invalid_grant" })
        end
        return json_reply(200, issue(grant.scope))
      elseif kind == "refresh_token" then
        local scope = refresh_scopes[Url.query_first(form, "refresh_token") or ""]
        if scope == nil then return json_reply(400, { error = "invalid_grant" }) end
        seen.refreshes = seen.refreshes + 1
        return json_reply(200, issue(scope, true))
      end
      return json_reply(400, { error = "unsupported_grant_type" })
    end
    return mcp(req)
  end
end

--- A client of `resource` whose `open` follows the authorization URL to its redirect, as a browser would, with
--- `tamper` changing the redirect first where given; `opened` counts the sign-ins shown.
local function client(resource: string, opened: mut {integer}, tamper?: function(string): string): Client.Session
  return Client.http(resource, { timeout_ns = WAIT, oauth = { client_id = "test-client", timeout_ns = WAIT, wait_ns = WAIT,
    open = function(url: string): (true) | (nil, Failure)
      opened[1] = (opened[1] or 0) + 1
      Poll.spawn(function()
        local got = assert(Http.request("GET", url, { timeout_ns = WAIT, follow = false }))
        local location = assert(got.headers["location"], got.body)
        if tamper ~= nil then location = tamper(location) end
        -- Before the first client's first redirect: a connection that sends nothing (held 5 s), a request at another path, and one with a forged
        -- state; the listener responds to each and keeps waiting for the real one.
        if tamper ~= nil or opened[1] ~= 1 then
          local _, _ = Http.request("GET", location, { timeout_ns = WAIT })
          return
        end
        local port = assert(tonumber(location:match("^http://127%.0%.0%.1:(%d+)/")))
        local idle = assert(Net.connect(Net.tcp("127.0.0.1", math.tointeger(port) or 0)))
        local stray = assert(Http.request("GET", "http://127.0.0.1:" .. tostring(port) .. "/favicon.ico", { timeout_ns = WAIT }))
        assert(stray.status == 404)
        local forged = assert(Http.request("GET", (location:gsub("state=[^&]*", "state=forged")), { timeout_ns = WAIT }))
        assert(forged.status == 400)
        local _, _ = idle:close()
        local _, _ = Http.request("GET", location, { timeout_ns = WAIT })
      end)
      return true
    end } })
end

local function test_a_client_signs_in_refreshes_and_steps_up()
  local handle: (function(HttpServer.Request): HttpServer.Reply)? = nil
  local seen: Seen = { signins = 0, refreshes = 0, last_scope = "", revoked = {}, issued = {},
    no_s256 = false, refuse_refreshed = false }
  assert(HttpServer.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    handle = function(req: HttpServer.Request): HttpServer.Reply return assert(handle)(req) end,
    on_ready = function(addresses: {Net.Address}, running: Net.Server)
      local base = "http://127.0.0.1:" .. tostring(assert(addresses[1]).port)
      handle = serving(base, seen)
      local resource = base .. "/mcp"
      local opened: mut {integer} = { 0 }
      local session = client(resource, opened)
      -- The first call is refused 401; the client signs in for the scope the challenge names, and calls again.
      local said = assert(session:call("read", {}))
      assert(assert(said.content[1]).text == "read for ada")
      assert(opened[1] == 1 and seen.signins == 1)
      -- A tool that needs more: 403, and a sign-in for what the token held and what the tool needs.
      local wrote = assert(session:call("write", {}))
      assert(assert(wrote.content[1]).text == "written")
      assert(opened[1] == 2 and seen.last_scope == "files:read files:write", seen.last_scope)
      -- Every token refused: the client refreshes, with no sign-in shown.
      for _, token in ipairs(seen.issued) do seen.revoked[token] = true end
      local again = assert(session:call("read", {}))
      assert(assert(again.content[1]).text == "read for ada")
      assert(seen.refreshes == 1 and opened[1] == 2, tostring(seen.refreshes))
      -- Every token refused, and the one the refresh gives too: the client signs in after the refresh.
      seen.refuse_refreshed = true
      for _, token in ipairs(seen.issued) do seen.revoked[token] = true end
      local signed = assert(session:call("read", {}))
      assert(assert(signed.content[1]).text == "read for ada")
      assert(seen.refreshes == 2 and opened[1] == 3, tostring(seen.refreshes) .. " " .. tostring(opened[1]))
      seen.refuse_refreshed = false
      -- A redirect from another issuer than the one asked is refused, and no token is asked for.
      local mixed: mut {integer} = { 0 }
      local other = client(resource, mixed, function(location: string): string
        return (location:gsub("iss=[^&]*", "iss=https%%3A%%2F%%2Fevil.example.com"))
      end)
      local none, why = other:call("read", {})
      assert(none == nil and why.message:find("iss", 1, true) ~= nil, tostring(why))
      -- An authorization server that does not say it takes S256 is refused before the person is shown anything.
      seen.no_s256 = true
      local plain: mut {integer} = { 0 }
      local _, pwhy = client(resource, plain):call("read", {})
      assert(pwhy ~= nil and pwhy.message:find("S256", 1, true) ~= nil and plain[1] == 0, tostring(pwhy))
      running:stop()
    end,
  })
end
