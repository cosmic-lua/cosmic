--- Workload Identity Federation: the identity token exchanged for an
--- access token, kept, and exchanged again before it ends.

local agent_fixture = require("build.agent_fixture")
local Auth = require("cosmic.agent.auth")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Test = require("cosmic.test")

Test.policy{ env = { "TMPDIR" } }

local scratch = agent_fixture.scratch

local function test_federation_exchanges_the_identity_token()
  local dir = scratch()
  assert(Fs.write(dir .. "/jwt", "eyJ.file.jwt\n"))
  local env: mut {string: string} = { ANTHROPIC_FEDERATION_RULE_ID = "fdrl_1", ANTHROPIC_ORGANIZATION_ID = "org",
    ANTHROPIC_IDENTITY_TOKEN_FILE = dir .. "/jwt", ANTHROPIC_WORKSPACE_ID = "wrkspc_1" }
  local function get(name: string): string? return env[name] end
  local bodies: mut {{string: Json.Value}} = {}
  local status = 200
  local send = function(method: string, url: string, opts: Http.RequestOptions): Http.Body?, string
    assert(method == "POST" and url == "https://api.test/v1/oauth/token", url)
    local decoded = assert(Json.decode_object(opts.body or ""))
    bodies[#bodies + 1] = decoded
    local reply = assert(Json.encode({ access_token = "sk-ant-oat01-" .. tostring(#bodies), expires_in = 600 }))
    return { status = status, headers = {}, body = reply }, ""
  end
  local now = 0
  Auth.now_ns = function(): integer return now end
  local sign = assert(Auth.from(get, "https://api.test", send))
  local h = assert(sign())
  assert(h["authorization"] == "Bearer sk-ant-oat01-1", h["authorization"])
  local b = assert(bodies[1])
  assert(b["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer" and b["assertion"] == "eyJ.file.jwt")
  assert(b["federation_rule_id"] == "fdrl_1" and b["organization_id"] == "org" and b["workspace_id"] == "wrkspc_1")
  assert(b["service_account_id"] == nil)
  -- The token is kept until it is near its end, then exchanged again.
  assert(assert(sign())["authorization"] == "Bearer sk-ant-oat01-1" and #bodies == 1)
  now = 590 * 1000000000
  assert(assert(sign())["authorization"] == "Bearer sk-ant-oat01-2" and #bodies == 2)
  now = 2000 * 1000000000
  status = 401
  local refused, why = sign()
  assert(refused == nil and why:find("federation: HTTP 401") ~= nil, why)
  env["ANTHROPIC_IDENTITY_TOKEN_FILE"] = dir .. "/none"
  local missing, missing_why = sign()
  assert(missing == nil and missing_why:find("ANTHROPIC_IDENTITY_TOKEN_FILE") ~= nil, missing_why)
  Auth.now_ns = function(): integer return 0 end
  local partial, partial_why = Auth.from(function(name: string): string?
    if name == "ANTHROPIC_FEDERATION_RULE_ID" then return "fdrl_1" end
    return nil
  end, "https://api.test")
  assert(partial == nil and partial_why:find("no credential") ~= nil)
end
