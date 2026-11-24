--- @public
--- The HTTP request a snippet of cosmic agent's `run` tool makes with [`Host.fetch`], in its worker; it follows
--- no redirect:
---
---     local AgentFetch = require("cosmic.agent.fetch")
---     local got = assert(AgentFetch.fetch({ url = "https://example.com/" }))
---     print(got.status, #got.body)
---
--- A status of 400 or more fails, as `curl -f` does, with the method, URL, status and the start of the body, unless
--- the request asks for any status: a snippet that reads an error's body as data asks for it. It takes http and https
--- alone, and a 3xx is answered, its `location` header with it: a snippet that follows it makes a new call. Where it may connect is the worker's sandbox's to say, as for any of its connections: a session
--- with no network reaches none, and with --network the sandbox's relay refuses loopback, private, link-local and
--- the host's own addresses, whatever a name resolves to, but an address --connect names, and reaches the rest through
--- any proxy the agent was given.

local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local Http = require("cosmic.http")
local Stream = require("cosmic.stream")

local record AgentFetch
  --- What a snippet asks for.
  record Request
    --- The URL, http or https.
    url: string
    --- The method: GET by default, POST where there is a body.
    method?: string
    --- Request headers, name to value.
    headers?: {string: string}
    --- The request body.
    body?: string
    --- How long the request may take, in seconds: 30 by default, at most [`AgentFetch.MOST_SECONDS`].
    timeout?: integer
    --- Whether a status of 400 or more is answered, in place of failing.
    any_status?: boolean
  end

  --- What came back.
  record Response
    --- The HTTP status.
    status: integer
    --- The headers, keyed by lower-case name.
    headers: {string: string}
    --- The body, its bytes as sent.
    body: string
    --- Whether the body was longer than [`AgentFetch.MOST_BYTES`], and cut there.
    cut: boolean
  end

  --- Tests only: how a request is made.
  record Options
    --- Canned replies in place of the network ([`Http.Options.script`]).
    script?: {string}
  end

  --- The most bytes of a body answered, which keeps a snippet that prints or returns one within its reply.
  MOST_BYTES: integer
  --- The most seconds one request may take.
  MOST_SECONDS: integer
end

AgentFetch.MOST_BYTES = 384 * 1024
AgentFetch.MOST_SECONDS = 120

--- The response to `request`, made as `options` allow, or why there is none.
function AgentFetch.fetch(request: AgentFetch.Request, options?: AgentFetch.Options): (AgentFetch.Response) | (nil, Failure)
  local scheme = request.url:match("^(%a[%w+.-]*):")
  if scheme == nil or (scheme:lower() ~= "http" and scheme:lower() ~= "https") then
    return nil, Failure.new("host: fetch: " .. request.url .. ": give an http or https URL")
  end
  local seconds = request.timeout or 30
  if seconds < 1 or seconds > AgentFetch.MOST_SECONDS then
    return nil, Failure.new("host: fetch: timeout is " .. tostring(seconds) .. ": give 1 to " ..
        tostring(AgentFetch.MOST_SECONDS))
  end
  local script = if options ~= nil then options.script else nil end
  local res, why = Http.open(request.url, { method = request.method, headers = request.headers, body = request.body,
    follow = false, timeout_ns = Clock.seconds(seconds), script = script })
  if res == nil then
    return nil, Failure.new("host: fetch: " .. request.url .. ": " .. tostring(why))
  end
  -- One byte past the most tells a body that is longer from one that is just so long.
  local body, read_why = Stream.read_up_to(res, AgentFetch.MOST_BYTES + 1)
  local _, _ = res:close()
  if body == nil then
    return nil, Failure.new("host: fetch: " .. request.url .. ": " .. tostring(read_why))
  end
  local cut = #body > AgentFetch.MOST_BYTES
  if cut then body = body:sub(1, AgentFetch.MOST_BYTES) end
  if res.status >= 400 and request.any_status ~= true then
    local start = body:gsub("[%z\1-\8\14-\31\127]", ""):gsub("%s+", " "):gsub("^ ", ""):sub(1, 200):gsub(" $", "")
    return nil, Failure.new("host: fetch: " .. (request.method or (if request.body ~= nil then "POST" else "GET" end)) ..
        " " .. request.url .. ": status " .. tostring(res.status) .. (if start ~= "" then ": " .. start else "" end) ..
        "; give {any_status = true} to read the response as a value")
  end
  return { status = res.status, headers = res.headers, body = body, cut = cut }
end

return AgentFetch
