--- The authenticated GitHub REST core the board's calls are built on:
--- one request function, its error rendering, and the success test.
--- `_work.gh` holds the board-shaped calls; this holds the transport
--- they share. Every call the board makes is a GET — the board reads
--- GitHub and never writes to it — so a request carries no body at
--- all. Auth is a GITHUB_TOKEN (or GH_TOKEN) env var; HTTPS_PROXY is
--- honored, and behind a TLS-intercepting proxy set
--- SSL_USE_SYSTEM_CERTS=1 SSL_CERT_FILE=<bundle> (read by the cosmos
--- TLS root loader).

local env = require("cosmic.env")
local fetch = require("cosmic.fetch")

--- One API exchange that got a response: its status and decoded body.
local record ApiResult
  status: integer
  value: any
end

local API < const > = "https://api.github.com"

--- One authenticated REST call. nil only when no response arrived
--- (missing token, transport failure); an HTTP error status is a
--- result — callers branch on res.status.
--- @param method string HTTP method
--- @param path string Path under api.github.com, leading slash
--- @return ApiResult | nil The exchange
--- @return string Error message when no response arrived
local function api(method: string, path: string): ApiResult, string
  local token = env.get("GITHUB_TOKEN") or env.get("GH_TOKEN")
  if token == nil or token == "" then
    return nil, "no GitHub token: set GITHUB_TOKEN (or GH_TOKEN)"
  end
  local resp, err = fetch.fetch(API .. path, {
      method = method,
      proxy = env.get("HTTPS_PROXY") or env.get("https_proxy"),
      headers = {
        ["authorization"] = "Bearer " .. token,
        ["accept"] = "application/vnd.github+json",
        ["x-github-api-version"] = "2022-11-28",
        ["user-agent"] = "cosmic-work-board",
      },
    })
  if resp == nil then
    return nil, ("%s %s: %s"):format(method, path, tostring(err))
  end
  local value: any = nil
  if resp.body and #resp.body > 0 then
    value = resp:json()
  end
  return {status = resp.status, value = value}, nil
end

--- Render a non-2xx exchange as an error message, using GitHub's own
--- "message" field when it sent one.
--- @param method string HTTP method
--- @param path string Request path
--- @param res ApiResult The exchange
--- @return string The message
local function api_error(method: string, path: string, res: ApiResult): string
  local detail = ""
  local v = res.value
  if v is {string: any} then
    detail = ": " .. tostring(v["message"])
  end
  return ("%s %s: HTTP %d%s"):format(method, path, res.status, detail)
end

--- Whether a status is a 2xx.
--- @param status integer HTTP status
--- @return boolean True for 2xx
local function is_success(status: integer): boolean
  return status >= 200 and status < 300
end

local record api_module
  type ApiResult = ApiResult
  call: function(method: string, path: string): ApiResult, string
  error_of: function(method: string, path: string, res: ApiResult): string
  is_success: function(status: integer): boolean
end

local M: api_module = {
  call = api,
  error_of = api_error,
  is_success = is_success,
}

return M
