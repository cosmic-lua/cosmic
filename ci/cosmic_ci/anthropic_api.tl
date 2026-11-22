--- A small client of the Claude API's Managed Agents endpoints over
--- [`cosmic.http`], for [`cosmic_ci.review_agent`] in place of Anthropic's
--- `ant` CLI.
---
--- An [`AnthropicApi.Client`] holds one `send` function, which the live
--- client fills over [`cosmic.http`], so a test can answer from a table
--- instead. The key goes only to the API's own origin, and a redirect
--- fails the call rather than being followed.
local Clock = require("cosmic.clock")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")
local Url = require("cosmic.url")

local record AnthropicApi
  --- One request to the API. `path` is below the API's address, as
  --- "v1/agents".
  record Request
    method: string
    path: string
    body?: string
  end
  --- An answer, whatever its status.
  record Reply
    status: integer
    body: string
  end
  --- Sends `request`; the answer, or nil and why none came.
  type Send = function(Request): Reply?, string
  record Client
    mut send: Send
  end
  --- What a test changes about [`AnthropicApi.live`]: `script` holds one
  --- list of canned replies ([`cosmic.http`]'s `script`) for each call
  --- of `send`, in order, and `sent` is given what each `send` wrote.
  record Live
    script?: {{string}}
    sent?: function(text: string)
  end
end

local default_base <const> = "https://api.anthropic.com"
--- The API version and the beta the Managed Agents endpoints take.
local api_version <const> = "2026-10-21"
local beta <const> = "managed-agents-2026-04-01"
local user_agent <const> = "cosmic-ci"
local request_ns <const> = Clock.seconds(60)

local default_ports: {string:integer} = { https = 443, http = 80 }

--- The origin of `url`: scheme, host and port, the port the scheme's
--- default where the URL names none. Nil and why for a URL that does not
--- parse or whose scheme has no default port.
local function origin_of(url: string): string?, string
  local parts, why = Url.parse(url)
  if parts == nil then return nil, why end
  local port = parts.port or default_ports[parts.scheme]
  if port == nil then return nil, "the scheme " .. parts.scheme .. " has no default port" end
  return parts.scheme .. "://" .. parts.host .. ":" .. tostring(port), ""
end

--- Counts the scripted replies [`AnthropicApi.live`] has handed out.
local record Handed
  mut calls: integer
end

--- A client of the API for `env`: its key from `ANTHROPIC_API_KEY`, its
--- address from `ANTHROPIC_BASE_URL` (api.anthropic.com by default). Nil
--- and why where there is no key.
function AnthropicApi.live(env: {string:string}, test?: AnthropicApi.Live): AnthropicApi.Client?, string
  local key = env["ANTHROPIC_API_KEY"]
  if key == nil or key == "" then return nil, "no Claude API key: set ANTHROPIC_API_KEY" end
  -- ANTHROPIC_BASE_URL is trusted as given, plain http included: the
  -- tests' script transport cannot do TLS.
  local base = env["ANTHROPIC_BASE_URL"]
  if base == nil or base == "" then base = default_base end
  base = (base:gsub("/+$", ""))
  local api_origin, why = origin_of(base)
  if api_origin == nil then return nil, "ANTHROPIC_BASE_URL: " .. why end
  local made: Handed = { calls = 0 }
  local function script(): {string}?
    made.calls = made.calls + 1
    local scripted = test and test.script
    return scripted and scripted[made.calls] or nil
  end

  local function send(request: AnthropicApi.Request): AnthropicApi.Reply?, string
    local url = base .. "/" .. request.path
    local headers: mut {string:string} = { ["x-api-key"] = key,
      ["anthropic-version"] = api_version, ["anthropic-beta"] = beta,
      ["User-Agent"] = user_agent }
    if request.body ~= nil then
      headers["Content-Type"] = "application/json"
      headers["Expect"] = ""
    end
    local response, trouble = Http.open(url, { method = request.method, headers = headers,
      body = request.body, follow = false, timeout_ns = request_ns, script = script() })
    if response == nil then return nil, trouble end
    local body, read_trouble = Stream.read_all(response)
    local on_sent = test and test.sent
    if on_sent ~= nil then on_sent(response:sent()) end
    local status = response.status
    local _, _ = response:close()
    if body == nil then return nil, read_trouble end
    return { status = status, body = body }, ""
  end

  return { send = send }, ""
end

--- The API's explanation in an error answer's body (`error.message`), or "".
local function message_of(body: string): string
  local decoded, _ = Json.decode_object(body)
  if decoded == nil then return "" end
  local message, _ = Json.get(decoded, { "error", "message" })
  if message is string then return message end
  return ""
end

--- The JSON object the API answers a `method` request to `path` with,
--- its body `value` as JSON where it is not nil, as its text: nil and why
--- where none came, the status is not 2xx or the body is no object, the
--- why naming the request, the status and the API's message.
function AnthropicApi.object(client: AnthropicApi.Client, method: string, path: string,
                             value?: any): string?, string
  local body: string? = nil
  if value ~= nil then
    local encoded, trouble = Json.encode_any(value)
    if encoded == nil then return nil, method .. " " .. path .. ": " .. trouble end
    body = encoded
  end
  local reply, why = client.send({ method = method, path = path, body = body })
  if reply == nil then return nil, method .. " " .. path .. ": " .. why end
  if reply.status < 200 or reply.status > 299 then
    local said = message_of(reply.body)
    if said ~= "" then said = ": " .. said end
    return nil, method .. " " .. path .. ": HTTP " .. tostring(reply.status) .. said
  end
  local object, trouble = Json.decode_object(reply.body)
  if object == nil then return nil, method .. " " .. path .. ": no JSON object: " .. trouble end
  return reply.body, ""
end

return AnthropicApi
