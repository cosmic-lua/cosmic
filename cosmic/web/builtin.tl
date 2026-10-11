--- The files an app serves itself under `/_web/`: htmx and its SSE
--- extension, from the bytes the binary carries. A path holds the file's
--- version, so the content at a path never changes: the reply is
--- immutable, with the SHA-256 of the bytes as a strong ETag.

local Htmx = require("cosmic.web.htmx")
local Response = require("cosmic.web.response")
local Types = require("cosmic.web.types")

local record Builtin
end

--- The first segment of every path served here.
local PREFIX <const> = "_web"

--- Whether `header`, an If-None-Match value, matches `etag`: `*`, or one
--- of its entity tags by the weak comparison RFC 9110 13.1.2 gives it.
local function matches(header: string, etag: string): boolean
  if header:match("^%s*%*%s*$") then return true end
  for piece in header:gmatch("[^,]+") do
    local tag = piece:match("^%s*(.-)%s*$")
    if tag:sub(1, 2) == "W/" then tag = tag:sub(3) end
    if tag == etag then return true end
  end
  return false
end

--- Answers `req` where it is under `/_web/`, else nil.
--- @param req Types.Request The request
--- @return Types.Response | nil The reply, or nil for a path that is not ours
function Builtin.handle(req: Types.Request): Types.Response | nil
  local segments = req.segments
  if segments[1] ~= PREFIX then return nil end
  local asset = #segments == 2 and not req.trailing and
    Htmx.assets()["/" .. PREFIX .. "/" .. segments[2]] or nil
  if asset == nil then return Response.abort(404) end
  local method = req.method
  if method ~= "GET" and method ~= "HEAD" then
    local refusal = Response.problem(405)
    Response.set_header(refusal, "Allow", "GET, HEAD")
    return refusal
  end
  local etag = '"' .. asset.sha256 .. '"'
  local headers: {string: string} = {
    ["ETag"] = etag,
    ["Cache-Control"] = "public, max-age=31536000, immutable",
    ["Cross-Origin-Resource-Policy"] = "same-origin",
    ["X-Content-Type-Options"] = "nosniff",
  }
  local sent = req.headers["if-none-match"]
  if sent ~= nil and matches(sent, etag) then
    return Response.empty(304, { headers = headers })
  end
  headers["Content-Type"] = "text/javascript; charset=utf-8"
  return { status = 200, headers = headers, body = asset.data }
end

return Builtin
