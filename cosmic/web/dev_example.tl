local Dev = require("cosmic.web.dev")
local Html = require("cosmic.html")
local Web = require("cosmic.web")

local record Example
end

--- An app with the development loop in it: in development mode (the
--- supervisor sets `COSMIC_WEB_DEV=1`) its pages reload when the program
--- is replaced and its stylesheets are swapped when they change; run
--- otherwise it is the plain app. A page served here shows no tag, as
--- this program is not in development mode.
function Example.app()
  local app = Dev.app{ routes = {
    Dev.static("/static"),
    Web.get("/", function(_req: Web.Request): Web.Response
      return Web.html(Html.trust("<html><body><h1>hello</h1></body></html>"))
    end),
  } }
  Web.with_client(app, function(client: Web.TestClient)
    local page = client:get("/")
    assert(page.status == 200 and not page.body:find("dev.js", 1, true))
  end)
end

--- The program of a `dev.tl` that runs `app.tl` and replaces it when a
--- file of the working directory changes; here it stops at once.
function Example.supervise()
  local ok = Dev.supervise{
    -- A stand-in for the default (this program on `app.tl`) that exits at once.
    command = { "true" }, watch = {}, interval_ns = 1000000, log = function(_text: string) end,
    stop = function(): boolean return true end,
  }
  assert(ok)
end

return Example
