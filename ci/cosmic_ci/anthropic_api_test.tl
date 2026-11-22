local AnthropicApi = require("cosmic_ci.anthropic_api")
local TestSupport = require("cosmic_ci.test_support")

-- The live client's transport runs over [`cosmic.http`]'s `script`, whose
-- connections are socket pairs: no network is reached.

local key <const> = "sk-test"
local reply <const> = TestSupport.reply

--- The live client over a plain-HTTP API, its calls answered by `script`
--- in order; `sent` collects what each `send` wrote.
local function live(script: {{string}}): AnthropicApi.Client, {string}
  local sent: mut {string} = {}
  local client, why = AnthropicApi.live({ ANTHROPIC_API_KEY = key, ANTHROPIC_BASE_URL = "http://api.test/" },
    { script = script, sent = function(text: string) sent[#sent + 1] = text end })
  assert(client ~= nil, why)
  return client, sent
end

local function has(text: string, needle: string)
  assert(text:find(needle, 1, true), "lacks " .. needle .. ":\n" .. text)
end

local function test_a_post_sends_the_key_the_version_the_beta_and_the_body()
  local client, sent = live({ { reply("200 OK", "", '{"id":"agent_1"}') } })
  local object, why = AnthropicApi.object(client, "POST", "v1/agents", { name = "n" })
  assert(object == '{"id":"agent_1"}', why)
  local wrote = assert(sent[1])
  assert(wrote:find("POST /v1/agents HTTP/1.1\r\n", 1, true) == 1, wrote)
  has(wrote, "\r\nx-api-key: " .. key .. "\r\n")
  has(wrote, "\r\nanthropic-version: 2026-10-21\r\n")
  has(wrote, "\r\nanthropic-beta: managed-agents-2026-04-01\r\n")
  has(wrote, "\r\nContent-Type: application/json\r\n")
  has(wrote, '\r\n\r\n{"name":"n"}')
end

local function test_there_is_no_client_without_a_key()
  local client, why = AnthropicApi.live({})
  assert(client == nil and why:find("ANTHROPIC_API_KEY", 1, true) ~= nil, tostring(why))
  client, why = AnthropicApi.live({ ANTHROPIC_API_KEY = "" })
  assert(client == nil, "an empty key was taken")
  client, why = AnthropicApi.live({ ANTHROPIC_API_KEY = key, ANTHROPIC_BASE_URL = "not a url" })
  assert(client == nil and why:find("ANTHROPIC_BASE_URL", 1, true) ~= nil, tostring(why))
end

local function test_a_refusal_names_the_request_the_status_and_the_apis_message()
  local client = live({ { reply("400 Bad Request", "",
    '{"type":"error","error":{"type":"invalid_request_error","message":"name: required"}}') },
    { reply("500 Internal Server Error", "", "<html>oops</html>") },
    { reply("200 OK", "", "[1]") } })
  local nothing: {string:string} = {}
  local object, why = AnthropicApi.object(client, "POST", "v1/agents", nothing)
  assert(object == nil and why == "POST v1/agents: HTTP 400: name: required", why)
  object, why = AnthropicApi.object(client, "GET", "v1/agents")
  assert(object == nil and why == "GET v1/agents: HTTP 500", why)
  object, why = AnthropicApi.object(client, "GET", "v1/agents")
  assert(object == nil and why:find("GET v1/agents: no JSON object", 1, true) == 1, why)
end

local function test_a_redirect_fails_the_call_and_is_not_followed_with_the_key()
  local client, sent = live({ { reply("307 Temporary Redirect", "Location: http://elsewhere.test/v1/agents\r\n") } })
  local object, why = AnthropicApi.object(client, "GET", "v1/agents")
  assert(object == nil and why == "GET v1/agents: HTTP 307", why)
  assert(#sent == 1)
end
