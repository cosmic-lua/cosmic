--- [`cosmic.mcp.server`] as an OAuth 2.1 resource server over HTTP on the worker's loopback: its protected
--- resource metadata, the 401 that points a client at it, a JWT access token for this endpoint and no other, and
--- the 403 that names the scopes a tool needs.

local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local Http = require("cosmic.http")
local HttpServer = require("cosmic.http.server")
local Jose = require("cosmic.jose")
local Json = require("cosmic.json")
local Key = require("cosmic.key")
local Mcp = require("cosmic.mcp")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Server = require("cosmic.mcp.server")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" } }

local WAIT <const> = Clock.seconds(20)
local ISSUER <const> = "https://auth.example.com"

local signer = Key.generate("p256")
local published = assert(Jose.key(Jose.jwk(signer.public, "k")))

--- An access token from the issuer for `audience`, granting `scope`, of `typ` "at+jwt" unless `typ` says otherwise.
local function token(audience: string, scope: string, issuer?: string, typ?: string, life?: integer): string
  local now = Clock.now_ns() // 1000000000
  return Jose.sign(signer, { iss = issuer or ISSUER, sub = "ada", aud = audience, scope = scope, exp = now + (life or 300),
    iat = now }, { typ = typ or "at+jwt", kid = "k" })
end

local function instance(): Server.Instance
  return Server.new{ info = { name = "guarded", version = "1" }, tools = {
    {
      tool = { name = "read", inputSchema = Mcp.object_schema({}) },
      call = function(_: {string: Json.Value}, call: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        local grant = assert(call.grant)
        return Mcp.result({ "read for " .. grant.subject })
      end,
    },
    {
      tool = { name = "wait", inputSchema = Mcp.object_schema({}) },
      call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        local _, _ = Poll.notifier():wait(Clock.seconds(30))
        return Mcp.result({ "waited" })
      end,
    },
    {
      tool = { name = "write", inputSchema = Mcp.object_schema({}) },
      scopes = { "files:read", "files:write" },
      call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        return Mcp.result({ "written" })
      end,
    },
  } }
end

--- A hand-written call of `tool` to `url` with `bearer`, where given; with `progress`, asked for as a stream.
local function call(url: string, tool: string, bearer?: string, progress?: boolean): Http.Body
  local headers: mut {string: string} = { ["Content-Type"] = "application/json",
    Accept = "application/json, text/event-stream", ["MCP-Protocol-Version"] = Mcp.VERSION, ["Mcp-Method"] = "tools/call",
    ["Mcp-Name"] = tool }
  if bearer ~= nil then headers["Authorization"] = "Bearer " .. bearer end
  local token_part = if progress == true then '"progressToken":"p",' else "" end
  local body = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":' .. Json.quote(tool) .. ',"arguments":{},' ..
    '"_meta":{' .. token_part .. '"io.modelcontextprotocol/protocolVersion":"2026-07-28",' ..
    '"io.modelcontextprotocol/clientCapabilities":{}}}}'
  local got = assert(Http.request("POST", url, { timeout_ns = WAIT, headers = headers, body = body }))
  return got
end

local function test_a_resource_server_points_at_its_metadata_and_takes_only_its_tokens()
  local handle: (function(HttpServer.Request): HttpServer.Reply)? = nil
  assert(HttpServer.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    handle = function(req: HttpServer.Request): HttpServer.Reply return assert(handle)(req) end,
    on_ready = function(addresses: {Net.Address}, running: Net.Server)
      local base = "http://127.0.0.1:" .. tostring(assert(addresses[1]).port)
      local resource = base .. "/mcp"
      handle = instance():handler{ oauth = { resource = resource, authorization_servers = { ISSUER },
        scopes = { "files:read" }, verify = Server.jwt{ issuer = ISSUER, keys = { published } } } }
      -- The metadata, at the well-known path with the endpoint's path after it.
      local meta = assert(Http.request("GET", base .. "/.well-known/oauth-protected-resource/mcp", { timeout_ns = WAIT }))
      local decoded, dwhy = Json.decode(meta.body)
      assert(decoded ~= nil, tostring(dwhy))
      local doc = assert(Json.object_of(decoded))
      assert(meta.status == 200 and doc["resource"] == resource, meta.body)
      assert(assert(Json.array_of(doc["authorization_servers"]))[1] == ISSUER)
      -- No token: 401, and where to look.
      local none = call(resource, "read")
      local challenge = none.headers["www-authenticate"] or ""
      assert(none.status == 401 and challenge:find('resource_metadata="' .. base .. '/.well-known/oauth-protected-resource/mcp"', 1,
        true) ~= nil and challenge:find('scope="files:read"', 1, true) ~= nil, challenge)
      -- A token for another audience, or from another issuer: 401 invalid_token.
      for _, bad in ipairs({ token("https://other.example.com/mcp", "files:read"), token(resource, "files:read", "https://evil.example.com"),
          token(resource, "files:read", nil, "JWT"), "not-a-token" }) do
        local refused = call(resource, "read", bad)
        assert(refused.status == 401 and (refused.headers["www-authenticate"] or ""):find('error="invalid_token"', 1, true) ~= nil)
      end
      -- A good token: the call runs, and the handler sees whose it is.
      local good = call(resource, "read", token(resource, "files:read"))
      assert(good.status == 200 and good.body:find("read for ada", 1, true) ~= nil, good.body)
      -- Too few scopes: 403, naming every scope the tool needs.
      local short = call(resource, "write", token(resource, "files:read"))
      local said = short.headers["www-authenticate"] or ""
      assert(short.status == 403 and said:find('error="insufficient_scope"', 1, true) ~= nil and
          said:find('scope="files:read files:write"', 1, true) ~= nil, said)
      -- Asked for with what the token already grants, so the new token keeps it.
      local other = call(resource, "write", token(resource, "mail:send"))
      assert((other.headers["www-authenticate"] or ""):find('scope="mail:send files:read files:write"', 1, true) ~= nil)
      local enough = call(resource, "write", token(resource, "files:read files:write"))
      assert(enough.status == 200 and enough.body:find("written", 1, true) ~= nil, enough.body)
      -- A stream ends when the token it was opened with is past its time, before its response.
      local started = Clock.monotonic_ns()
      local streamed = call(resource, "wait", token(resource, "files:read", nil, nil, 1), true)
      assert(streamed.status == 200 and streamed.body:find("waited", 1, true) == nil, streamed.body)
      assert(Clock.monotonic_ns() - started < Clock.seconds(10))
      running:stop()
    end,
  })
end

local function test_a_resource_server_that_does_not_hold_raises()
  local verify = Server.jwt{ issuer = ISSUER, keys = { published } }
  local function raises(oauth: Server.OAuth, says: string)
    Test.raises(function() instance():handler{ oauth = oauth } end, says)
  end
  raises({ resource = "http://mcp.example.com/mcp", authorization_servers = { ISSUER }, verify = verify }, "https")
  raises({ resource = "https://mcp.example.com/other", authorization_servers = { ISSUER }, verify = verify }, "path")
  raises({ resource = "https://mcp.example.com/mcp#x", authorization_servers = { ISSUER }, verify = verify }, "fragment")
  raises({ resource = "https://mcp.example.com/mcp", authorization_servers = {}, verify = verify }, "empty")
  raises({ resource = "https://mcp.example.com/mcp", authorization_servers = { ISSUER }, scopes = { "a b" },
    verify = verify }, "scope token")
  Test.raises(function()
    instance():handler{ authorize = Server.anyone, oauth = { resource = "https://mcp.example.com/mcp",
      authorization_servers = { ISSUER }, verify = verify } }
  end, "one of")
  Test.raises(function() instance():handler{} end, "one of")
end
