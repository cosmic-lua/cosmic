--- Worked examples for [`cosmic.web.htmx`], shown by `cosmic docs` and run
--- by `cosmic test`.

local Html = require("cosmic.html")
local Htmx = require("cosmic.web.htmx")
local Web = require("cosmic.web")

local Example = {}

--- One handler answers a fragment to an htmx request and the whole page to
--- a browser, to a boosted link and to a history restore; both answers
--- vary on the headers that chose, so a cache keeps them apart.
function Example.page()
  local app = Web.app{ routes = { Web.get("/items", function(req: Web.Request): Web.Response
    local rows = Html.trust("<li>one</li><li>two</li>")
    return Htmx.page(req, rows, function(content: Html.SafeHtml): Html.SafeHtml
      return Html.concat({ Html.trust("<!doctype html><head>"), Htmx.head(),
        Html.trust("</head><body><ul>"), content, Html.trust("</ul></body>") })
    end)
  end) } }
  local client = Web.test_client(app)
  local fragment = client:get("/items", { headers = { ["HX-Request"] = "true" } })
  print(fragment.body) -- <li>one</li><li>two</li>
  assert(fragment.body == "<li>one</li><li>two</li>")
  local whole = client:get("/items")
  assert(whole.body:find("<script src=\"" .. Htmx.path() .. "\"", 1, true))
  assert(whole.headers["vary"] == "HX-Request, HX-History-Restore-Request, HX-Boosted")
end

--- A response says what htmx should do with it in `HX-*` headers. A
--- redirect to another origin is refused, since htmx navigates to it by
--- script.
function Example.reply()
  local res = Web.html(Html.trust("<p>saved</p>"))
  assert(Htmx.apply(res, { push_url = "/items/7", retarget = "#main", reswap = "outerHTML",
    trigger = { { name = "saved", detail = { id = 7 } } } }))
  print(Web.header(res, "HX-Trigger")) -- {"saved":{"id":7}}
  assert(Web.header(res, "HX-Trigger") == '{"saved":{"id":7}}')
  local refused, why = Htmx.apply(Web.empty(200), { redirect = "//evil.example/" })
  assert(refused == nil)
  assert(why:find("same-origin", 1, true))
end

--- After a POST an htmx request is redirected by header, as its XHR would
--- follow a 303 and swap the other page into the target.
function Example.redirect()
  local app = Web.app{ routes = { Web.post("/items", function(req: Web.Request): Web.Response
    return (assert(Htmx.redirect_to(req, "/items/7")))
  end) } }
  local client = Web.test_client(app)
  local htmx = client:post("/items", { headers = { ["HX-Request"] = "true" } })
  assert(htmx.status == 200 and htmx.headers["hx-redirect"] == "/items/7")
  local browser = client:post("/items")
  assert(browser.status == 303 and browser.redirect_location == "/items/7")
end

--- A page loads htmx with a subresource integrity value the binary
--- computed from the bytes it serves at the same path under `/_web/`.
function Example.head()
  local app = Web.app{}
  local served = Web.test_client(app):get(Htmx.path())
  assert(served.status == 200)
  print(Htmx.path(), Htmx.integrity())
  assert(Html.raw(Htmx.head({ sse = true })):find(Htmx.integrity("sse"), 1, true))
end

--- A handler reads what htmx says of the request; a poll that is done
--- answers 286, which htmx swaps in and then stops polling. The indicator
--- rules go in the app's stylesheet.
function Example.poll()
  local app = Web.app{ routes = { Web.get("/job", function(req: Web.Request): Web.Response
    local seen = Htmx.request(req)
    if seen.active and seen.trigger == "status" and Htmx.partial(req) then
      return Htmx.stop_polling(Html.trust("done"))
    end
    return Web.text("running")
  end) } }
  local client = Web.test_client(app)
  local polled = client:get("/job", { headers = { ["HX-Request"] = "true", ["HX-Trigger"] = "status" } })
  print(polled.status) -- 286
  assert(polled.status == 286 and client:get("/job").body == "running")
  assert(Htmx.indicator_css():find(".htmx-indicator", 1, true))
  print(Htmx.version, Htmx.sse_version)
  assert(Htmx.path():find(Htmx.version, 1, true) and Htmx.path("sse"):find(Htmx.sse_version, 1, true))
end

return Example
