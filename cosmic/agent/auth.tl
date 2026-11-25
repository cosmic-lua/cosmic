--- @public
--- How `cosmic agent` signs its requests, in the order the SDKs look:
--- ANTHROPIC_API_KEY, else ANTHROPIC_AUTH_TOKEN, else Workload Identity
--- Federation, whose identity token (a JWT from the workload's identity
--- provider) is exchanged at /v1/oauth/token for a short-lived access
--- token, and exchanged again before that one expires.
---
--- cosmic agent calls the Claude API, signed with the first of these that
--- is set:
---
---     ANTHROPIC_API_KEY      an API key, sent as x-api-key
---     ANTHROPIC_AUTH_TOKEN   an OAuth token, sent as a bearer token
---     federation             Workload Identity Federation, below
---
--- Federation exchanges an identity token from the workload's identity
--- provider (a JWT) at /v1/oauth/token for a short-lived access token,
--- and exchanges again two minutes before that one expires. It needs:
---
---     ANTHROPIC_FEDERATION_RULE_ID    the rule (fdrl_...)
---     ANTHROPIC_ORGANIZATION_ID       the organization's UUID
---     ANTHROPIC_IDENTITY_TOKEN_FILE   the JWT's file, read at each exchange,
---       or ANTHROPIC_IDENTITY_TOKEN   the JWT itself
---     ANTHROPIC_WORKSPACE_ID          the workspace (wrkspc_...), where the
---                                     rule has more than one
---     ANTHROPIC_SERVICE_ACCOUNT_ID    the service account (svac_...), optional
---
--- ANTHROPIC_BASE_URL, where set, replaces https://api.anthropic.com.
---
--- --model opus (the default) is claude-opus-5-5, --model sonnet is
--- claude-sonnet-5-5, and --model haiku is claude-haiku-5-5: the latest
--- of each. --effort is medium unless it says low, high, xhigh or max.
--- Thinking is adaptive, and a refusal falls back to another model on
--- the server.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Json = require("cosmic.json")

local record Auth
  --- Sends one request: Http.request's shape, so a test can stand in.
  type Send = function(method: string, url: string, opts: Http.Options): Http.Body?, string
  --- The headers that sign the next request, or nil and why.
  type Sign = function(): {string: string}?, string
  --- The clock, in nanoseconds. A test stands in for it.
  mut now_ns: function(): integer
end

Auth.now_ns = Clock.now_ns

-- An access token is exchanged again this long before it expires.
local MARGIN_NS <const> = Clock.minutes(2)

--- An access token, and when it expires (nanoseconds).
local record Held
  token: string
  until_ns: integer
end

--- Exchanges the identity token for an access token, or nil and why.
local function exchange(env: function(string): string?, base: string, send: Auth.Send): Held?, string
  local jwt = env("ANTHROPIC_IDENTITY_TOKEN")
  local file = env("ANTHROPIC_IDENTITY_TOKEN_FILE")
  if file ~= nil and file ~= "" then
    -- Read again at each exchange: a projected token turns over on disk.
    local read, why = Fs.read(file)
    if read == nil then return nil, "ANTHROPIC_IDENTITY_TOKEN_FILE: " .. tostring(why) end
    jwt = read:match("^%s*(.-)%s*$")
  end
  local body: mut {string: Json.Value} = {
    grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer",
    assertion = jwt or "",
    federation_rule_id = env("ANTHROPIC_FEDERATION_RULE_ID") or "",
    organization_id = env("ANTHROPIC_ORGANIZATION_ID") or "",
  }
  local account, workspace = env("ANTHROPIC_SERVICE_ACCOUNT_ID"), env("ANTHROPIC_WORKSPACE_ID")
  if account ~= nil and account ~= "" then body["service_account_id"] = account end
  if workspace ~= nil and workspace ~= "" then body["workspace_id"] = workspace end
  local text, why = Json.encode(body)
  if text == nil then return nil, tostring(why) end
  local started = Auth.now_ns()
  local got, send_why = send("POST", base .. "/v1/oauth/token", { headers = { ["content-type"] = "application/json" },
    body = text, timeout_ns = Clock.seconds(60), retry = { attempts = 3, statuses = { 429, 500, 502, 503, 529 } } })
  if got == nil then return nil, "federation: " .. send_why end
  if got.status ~= 200 then
    return nil, "federation: HTTP " .. tostring(got.status) .. ": " .. got.body
  end
  local reply, bad = Json.decode_object(got.body)
  if reply == nil then return nil, "federation: the reply is not JSON: " .. tostring(bad) end
  local token, expires = reply["access_token"], reply["expires_in"]
  if not (token is string) then return nil, "federation: the reply has no access_token" end
  local seconds = if expires is number then math.tointeger(math.floor(expires)) or 3600 else 3600 end
  return { token = token, until_ns = started + Clock.seconds(seconds) }, ""
end

--- What signs every request with `headers`.
local function fixed(headers?: {string: string}): Auth.Sign
  return function(): {string: string}?, string
    if headers == nil then return nil, "no credential" end
    return headers, ""
  end
end

--- What signs requests, from the environment `env` reads: nil and why
--- where it holds no credential. `send` makes federation's exchange.
function Auth.from(env: function(string): string?, base: string, send?: Auth.Send): Auth.Sign?, string
  local key = env("ANTHROPIC_API_KEY")
  if key ~= nil and key ~= "" then
    return fixed({ ["x-api-key"] = key }), ""
  end
  local token = env("ANTHROPIC_AUTH_TOKEN")
  if token ~= nil and token ~= "" then
    return fixed({ authorization = "Bearer " .. token, ["anthropic-beta"] = "oauth-2025-04-20" }), ""
  end
  local rule, org = env("ANTHROPIC_FEDERATION_RULE_ID"), env("ANTHROPIC_ORGANIZATION_ID")
  local jwt, file = env("ANTHROPIC_IDENTITY_TOKEN"), env("ANTHROPIC_IDENTITY_TOKEN_FILE")
  if rule == nil or rule == "" or org == nil or org == "" or ((jwt == nil or jwt == "") and (file == nil or file == "")) then
    return nil, "no credential: set ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, or federation's variables " ..
      "(cosmic docs cosmic.agent.auth)"
  end
  local go: Auth.Send = send or function(method: string, url: string, opts: Http.Options): Http.Body?, string
    local body, why = Http.request(method, url, opts)
    if body == nil then return nil, tostring(why) end
    return body, ""
  end
  local held: Held? = nil
  return function(): {string: string}?, string
    local now = held
    if now == nil or Auth.now_ns() >= now.until_ns - MARGIN_NS then
      local got, why = exchange(env, base, go)
      if got == nil then return nil, why end
      held, now = got, got
    end
    return { authorization = "Bearer " .. now.token }, ""
  end, ""
end

return Auth
