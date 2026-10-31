--- The files an app serves itself under `/_web/`: htmx and its SSE
--- extension, from the bytes the binary carries. A path holds the file's
--- version, so the content at a path never changes: the reply is
--- immutable. [`StaticFiles`] answers, so the files have its ETag, Range and
--- gzip handling.

local Assets = require("cosmic.web.assets")
local Htmx = require("cosmic.web.htmx")
local StaticFiles = require("cosmic.web.static")
local Types = require("cosmic.web.types")

local record Builtin
end

--- The first segment of every path served here.
local PREFIX <const> = "_web"

--- The handler over the files, built on first use: the bytes never change,
--- and gzipping them is paid by a program that serves them only.
local served: mut {Types.Handler} = {}

local function handler(): Types.Handler
  local built = served[1]
  if built == nil then
    local held: mut {string:string} = {}
    for path, file in pairs(Htmx.assets()) do held[path:sub(#PREFIX + 3)] = file.data end
    built = StaticFiles.handler{
      source = Assets.memory(held, { gzip = true }),
      cache_control = "public, max-age=31536000, immutable",
      headers = { ["Cross-Origin-Resource-Policy"] = "same-origin" },
    }
    served[1] = built
  end
  return built
end

--- Answers `req` where it is under `/_web/`, else nil.
--- @param req Types.Request The request
--- @return Types.Response | nil The reply, or nil for a path that is not ours
function Builtin.handle(req: Types.Request): Types.Response?
  if req.segments[1] ~= PREFIX then return nil end
  req.mount_path = "/" .. PREFIX
  return handler()(req)
end

return Builtin
