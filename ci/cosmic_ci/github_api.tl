--- A small client of GitHub's REST API over [`cosmic.http`], for the CI
--- driver in place of the `gh` CLI.
---
--- A [`GithubApi.Client`] holds two functions the live one fills over
--- [`cosmic.http`], so a test can answer from a table instead. `send` makes
--- one request to the API and never follows a redirect. `fetch` downloads
--- one URL the API redirected to, and is never given the token.
---
--- The token goes only to the API's own origin, `GITHUB_API_URL`'s, and
--- to the one origin GitHub takes release assets on ([`GithubApi.upload`]):
--- a download takes the API's redirect by hand and fetches its `Location`
--- without it, since that URL is a signed link to another host.
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Http = require("cosmic.http")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")
local Url = require("cosmic.url")

local record GithubApi
  --- One request to the API. `url` is absolute; `headers` are the ones
  --- the caller adds to those every request carries.
  record Request
    method: string
    url: string
    headers: {string:string}
    body: string | nil
    --- How long the request may take, in nanoseconds; a minute where nil.
    timeout_ns: integer | nil
    --- Whether `url` is on the client's upload origin, not the API's.
    upload: boolean | nil
  end
  --- An answer, whatever its status; `headers` are keyed by lowercased name.
  record Reply
    status: integer
    headers: {string:string}
    body: string
  end
  --- Sends `request`; the answer, or nil and why none came.
  type Send = function(Request): Reply | nil, string
  --- Downloads `url`, a link the API gave, to `path`: true, or false and why.
  type Fetch = function(url: string, path: string): boolean, string
  record Client
    send: Send
    fetch: Fetch
    --- The API's origin and path prefix, without a trailing "/".
    base: string
    --- The origin release assets are uploaded to, as `upload` compares it:
    --- uploads.github.com for api.github.com, uploads.<x> for api.<x>
    --- (a data-residency host), and the API's own for an Enterprise
    --- Server's.
    upload_origin: string
    --- What precedes `/repos/` in an upload's path: "" on the hosts
    --- above, "/api/uploads" on an Enterprise Server.
    upload_path: string
  end
  --- What a test changes about [`GithubApi.live`]: `script` holds one
  --- list of canned replies ([`cosmic.http`]'s `script`) for each call
  --- of `send` or `fetch`, in order, and `sent` collects what each
  --- `send` wrote to its connection.
  record Live
    script: {{string}}
    sent: {string}
  end
end

local default_base <const> = "https://api.github.com"
local api_version <const> = "2022-11-28"
local user_agent <const> = "cosmic-ci"
local request_ns <const> = Clock.seconds(60)
local download_ns <const> = Clock.seconds(300)
--- The redirects a download follows after the API's own, all without
--- the token.
local download_redirects <const> = 3
local redirect_statuses: {integer:boolean} = { [301] = true, [302] = true, [303] = true,
  [307] = true, [308] = true }

local default_ports: {string:integer} = { https = 443, http = 80 }
local upload_ns <const> = Clock.seconds(600)

--- The origin of `url`, as one string that equals another's only when
--- scheme, host and port do: the port is the scheme's default where the
--- URL names none, and an IPv6 host is bracketed. Nil and why for a URL
--- that does not parse or has a scheme with no default port.
local function origin_of(url: string): string | nil, string
  local parts, why = Url.parse(url)
  if parts == nil then return nil, why end
  local port = parts.port or default_ports[parts.scheme]
  if port == nil then return nil, "the scheme " .. parts.scheme .. " has no default port" end
  local host = parts.host:find(":", 1, true) and ("[" .. parts.host .. "]") or parts.host
  return parts.scheme .. "://" .. host .. ":" .. port, ""
end

--- Where `base`'s API takes release uploads: the origin and the path that
--- precedes `/repos/`. An `api.` host's sibling is `uploads.`; any other
--- host (Enterprise Server) serves them itself under /api/uploads.
local function uploads_of(base: string): string | nil, string
  local parts, why = Url.parse(base)
  if parts == nil then return nil, why end
  local host, prefix = parts.host, "/api/uploads"
  if host:sub(1, 4) == "api." then host, prefix = "uploads." .. host:sub(5), "" end
  local authority = host:find(":", 1, true) and ("[" .. host .. "]") or host
  if parts.port then authority = authority .. ":" .. parts.port end
  local origin, trouble = origin_of(parts.scheme .. "://" .. authority)
  if origin == nil then return nil, trouble end
  return origin, prefix
end

--- Whether `path` is a release's assets under `prefix`:
--- `<prefix>/repos/<owner>/<repo>/releases/<digits>/assets`, no segment
--- of it a dot or two, written plain or percent-escaped.
local function is_assets_path(path: string, prefix: string): boolean
  if path:sub(1, #prefix) ~= prefix then return false end
  local owner, repo = path:sub(#prefix + 1):match("^/repos/([^/]+)/([^/]+)/releases/%d+/assets$")
  if owner == nil or repo == nil then return false end
  for _, segment in ipairs({ owner, repo }) do
    local plain = segment:lower():gsub("%%2e", ".")
    if plain == "." or plain == ".." then return false end
  end
  return true
end

--- GitHub's explanation in an error answer's body: its `message`, or "".
local function message_of(body: string): string
  local decoded = Json.decode_object(body)
  local message = decoded and decoded.message
  if message is string then return message end
  return ""
end

--- A client of the API for `env`: its token from `GH_TOKEN`, else
--- `GITHUB_TOKEN`, and its address from `GITHUB_API_URL` (api.github.com
--- by default). Nil and why where there is no token.
function GithubApi.live(env: {string:string}, test?: GithubApi.Live): GithubApi.Client | nil, string
  local token = env.GH_TOKEN
  if token == nil or token == "" then token = env.GITHUB_TOKEN end
  if token == nil or token == "" then
    -- A `gh auth login` is not read: the driver does not run gh, so a
    -- person with gh exports GH_TOKEN=$(gh auth token).
    return nil, "no GitHub token: set GH_TOKEN or GITHUB_TOKEN"
  end
  -- GITHUB_API_URL is trusted as given, plain http included: the tests'
  -- script transport cannot do TLS.
  local base = env.GITHUB_API_URL
  if base == nil or base == "" then base = default_base end
  base = (base:gsub("/+$", ""))
  local api_origin, why = origin_of(base)
  if api_origin == nil then return nil, "GITHUB_API_URL: " .. why end
  local upload_origin, upload_path = uploads_of(base)
  assert(upload_origin ~= nil, upload_path)
  local calls = 0
  local function script(): {string} | nil
    calls = calls + 1
    return test and test.script and test.script[calls] or nil
  end

  local function send(request: GithubApi.Request): GithubApi.Reply | nil, string
    -- The token is the one thing this function must not hand to any other host.
    local target = origin_of(request.url)
    if target ~= api_origin and not (request.upload and target == upload_origin) then
      return nil, "refusing to send the token to " .. tostring(target or request.url)
    end
    if target ~= api_origin then
      -- Only a release's assets take the token on the upload origin.
      local parts = Url.parse(request.url)
      if parts == nil or parts.userinfo ~= nil or parts.fragment ~= nil or
          not is_assets_path(parts.path, upload_path) then
        return nil, "refusing to send the token to " .. request.url
      end
    end
    local headers: {string:string} = {}
    for name, value in pairs(request.headers) do headers[name] = value end
    headers.Authorization = "Bearer " .. token
    headers.Accept = headers.Accept or "application/vnd.github+json"
    headers["X-GitHub-Api-Version"] = api_version
    headers["User-Agent"] = user_agent
    if request.body ~= nil then headers.Expect = "" end
    -- A redirect (a renamed repository's 301, say) fails the call rather
    -- than being followed: the token must not follow one.
    local response, trouble = Http.open(request.url, { method = request.method,
      headers = headers, body = request.body, follow = false,
      timeout_ns = request.timeout_ns or request_ns,
      script = script() })
    if response == nil then return nil, trouble end
    local body, read_trouble = Stream.read_all(response)
    if test and test.sent then test.sent[#test.sent + 1] = response:sent() end
    local status, reply_headers = response.status, response.headers
    response:close()
    if body == nil then return nil, read_trouble end
    return { status = status, headers = reply_headers, body = body }, ""
  end

  local function fetch(url: string, path: string): boolean, string
    local result = Http.download_result(url, path, { headers = { ["User-Agent"] = user_agent },
      redirect_protocols = { "https" }, max_redirects = download_redirects,
      timeout_ns = download_ns, script = script() })
    if result.kind == "downloaded" then return true, "" end
    -- The URL is a signed link, so it stays out of the message.
    if result.kind == "http_status" then return false, "HTTP " .. tostring(result.status) end
    return false, result.reason
  end

  return { send = send, fetch = fetch, base = base, upload_origin = upload_origin,
    upload_path = upload_path }, ""
end

local function request_for(client: GithubApi.Client, method: string, path: string,
                           seconds?: integer): GithubApi.Request
  return { method = method, url = client.base .. "/" .. path, headers = {},
    timeout_ns = seconds and Clock.seconds(seconds) or nil }
end

--- What `reply` to a request for `path` says of a refusal, as an error.
local function refused(method: string, path: string, reply: GithubApi.Reply): string
  local said = message_of(reply.body)
  return method .. " " .. path .. ": HTTP " .. reply.status .. (said ~= "" and (": " .. said) or "")
end

local function succeeded(reply: GithubApi.Reply): boolean
  return reply.status >= 200 and reply.status <= 299
end

--- The body of GitHub's answer to a GET of `path` (relative to the API,
--- as "repos/o/r/actions/runs"), JSON text. Nil and why where there is
--- none or its status is not 2xx, the why naming the request, the
--- status and GitHub's message. A request that takes longer than
--- `seconds` (a minute where nil) fails.
function GithubApi.get(client: GithubApi.Client, path: string, seconds?: integer): string | nil, string
  local reply, why = client.send(request_for(client, "GET", path, seconds))
  if reply == nil then return nil, "GET " .. path .. ": " .. why end
  if not succeeded(reply) then return nil, refused("GET", path, reply) end
  return reply.body, ""
end

--- The URL the `Link` header's `rel="next"` names, nil where it has none.
local function next_link(link: string | nil): string | nil
  for target, params in (link or ""):gmatch("<([^>]*)>([^<]*)") do
    for param in params:gmatch("[^;,]+") do
      if param:match('^%s*rel%s*=%s*"?next"?%s*$') then return target end
    end
  end
  return nil
end

--- A GET that cannot loop for ever on a `Link` that points to itself.
local max_pages <const> = 1000

--- Every page of the list at `path`, as `get` asks the first and the
--- `Link` header's `rel="next"` URLs name the rest, each page decoded
--- (an object or an array). Nil and why where a request fails, a page is
--- not JSON, or the list runs past 1000 pages. A next URL on another
--- origin than the API's is refused by `send`, so it fails the listing
--- and never receives the token. `seconds` bounds each request.
function GithubApi.pages(client: GithubApi.Client, path: string, seconds?: integer): {any} | nil, string
  local pages: {any} = {}
  local request = request_for(client, "GET", path, seconds)
  local seen: {string:boolean} = { [request.url] = true }
  for number = 1, max_pages do
    local label = number == 1 and path or (path .. " (page " .. number .. ")")
    local reply, why = client.send(request)
    if reply == nil then return nil, "GET " .. label .. ": " .. why end
    if not succeeded(reply) then return nil, refused("GET", label, reply) end
    local page, trouble = Json.decode(reply.body)
    if not (page is table) then
      return nil, "GET " .. label .. ": " .. (trouble ~= "" and trouble or "not an object or an array")
    end
    pages[#pages + 1] = page
    local target = next_link(reply.headers.link)
    if target == nil then return pages, "" end
    if seen[target] then return nil, "GET " .. label .. ": the next page repeats " .. target end
    seen[target] = true
    request = { method = "GET", url = target, headers = {}, timeout_ns = request.timeout_ns }
  end
  return nil, "GET " .. path .. ": more than " .. max_pages .. " pages"
end

--- Deletes `path` (relative to the API): true, or false and why, naming
--- the request, the status and GitHub's message where it is not 2xx. A
--- request that takes longer than `seconds` (a minute where nil) fails.
function GithubApi.delete(client: GithubApi.Client, path: string, seconds?: integer): boolean, string
  local reply, why = client.send(request_for(client, "DELETE", path, seconds))
  if reply == nil then return false, "DELETE " .. path .. ": " .. why end
  if not succeeded(reply) then return false, refused("DELETE", path, reply) end
  return true, ""
end

--- One request of `method` to `path`, its body `value` as JSON where it
--- is not nil: the answer whatever its status, so a caller can read a
--- refusal, or nil and why none came. A request that takes longer than
--- `seconds` (a minute where nil) fails.
function GithubApi.request(client: GithubApi.Client, method: string, path: string, value?: any,
                           seconds?: integer): GithubApi.Reply | nil, string
  local request = request_for(client, method, path, seconds)
  if value ~= nil then
    local body, trouble = Json.encode(value)
    if body == nil then return nil, method .. " " .. path .. ": " .. trouble end
    request.body = body
    request.headers["Content-Type"] = "application/json"
  end
  local reply, why = client.send(request)
  if reply == nil then return nil, method .. " " .. path .. ": " .. why end
  return reply, ""
end

--- The JSON object GitHub answers a `method` request to `path` with
--- ([`GithubApi.request`]'s `value`): nil and why where there is none,
--- its status is not 2xx or its body is no object, the why naming the
--- request, the status and GitHub's message.
function GithubApi.object(client: GithubApi.Client, method: string, path: string, value?: any,
                          seconds?: integer): {string:any} | nil, string
  local reply, why = GithubApi.request(client, method, path, value, seconds)
  if reply == nil then return nil, why end
  if not succeeded(reply) then return nil, refused(method, path, reply) end
  local object, trouble = Json.decode_object(reply.body)
  if object == nil then return nil, method .. " " .. path .. ": no JSON object: " .. trouble end
  return object, ""
end

--- Uploads `bytes` as the asset `name` of the release `upload_url`, the
--- `upload_url` field GitHub gives it, names: true, or false and why. The
--- token goes to this one origin besides the API's, so the URL must be
--- the client's upload origin's, with no credentials, query or fragment,
--- and the path of a release's assets; any other is refused with nothing
--- sent. The asset's type is `content_type`, application/octet-stream
--- where nil. A name the release holds already fails, as GitHub's 422.
function GithubApi.upload(client: GithubApi.Client, upload_url: string, name: string,
                          bytes: string, content_type?: string): boolean, string
  local url = (upload_url:gsub("{[^}]*}$", ""))
  local parts, why = Url.parse(url)
  if parts == nil then return false, "upload URL: " .. why end
  local path = parts.path
  if origin_of(url) ~= client.upload_origin or parts.userinfo ~= nil or parts.query ~= nil or
      parts.fragment ~= nil or not is_assets_path(path, client.upload_path) then
    return false, "refusing to upload to " .. url .. ": not a release's assets on the upload origin"
  end
  if name == "" then return false, "upload: no asset name" end
  local reply, trouble = client.send({ method = "POST", url = url .. "?name=" .. Url.escape(name),
    headers = { ["Content-Type"] = content_type or "application/octet-stream" }, body = bytes,
    timeout_ns = upload_ns, upload = true })
  if reply == nil then return false, "POST " .. path .. " (" .. name .. "): " .. trouble end
  if reply.status == 201 then return true, "" end
  local said = refused("POST", path .. " (" .. name .. ")", reply)
  if reply.status == 422 and reply.body:find("already_exists", 1, true) then
    said = said .. " (the release holds an asset of that name)"
  end
  return false, said
end

--- Downloads what the API serves at `path` (a redirect to a file, as an
--- artifact's `.../zip`, or a release asset's, asked for with `accept`
--- "application/octet-stream") to the file `to`: true, or false and why.
--- The API must answer with a redirect to an https URL, which is fetched
--- without the token; where `accept` is given the answer may instead be
--- the bytes, written whole.
function GithubApi.download(client: GithubApi.Client, path: string, to: string,
                            accept?: string): boolean, string
  local request = request_for(client, "GET", path)
  if accept then request.headers.Accept = accept end
  local reply, why = client.send(request)
  if reply == nil then return false, "GET " .. path .. ": " .. why end
  if not redirect_statuses[reply.status] then
    if reply.status >= 200 and reply.status <= 299 then
      -- Asked for as bytes, a file may come in the answer itself, as it
      -- may as a redirect: GitHub's documentation allows both.
      if accept then
        local written, trouble = Fs.write(to, reply.body)
        if not written then return false, "GET " .. path .. ": " .. trouble end
        return true, ""
      end
      return false, "GET " .. path .. ": HTTP " .. reply.status .. " with no redirect to a file"
    end
    return false, refused("GET", path, reply)
  end
  local location = reply.headers.location
  local parts = location and Url.parse(location)
  if parts == nil or parts.scheme ~= "https" then
    return false, "GET " .. path .. ": HTTP " .. reply.status ..
      " redirects somewhere other than an https URL"
  end
  local fetched, trouble = client.fetch(location, to)
  if not fetched then return false, "GET " .. path .. ": " .. trouble end
  return true, ""
end

return GithubApi
