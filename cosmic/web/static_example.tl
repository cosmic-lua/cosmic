--- Worked examples for [`cosmic.web.static`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Assets = require("cosmic.web.assets")
local StaticFiles = require("cosmic.web.static")
local Web = require("cosmic.web")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

local Example = {}

--- A mount serves the files of a source under its prefix, named
--- "static", and `url_for` names a file by its fingerprint: the page that
--- links `/static/app.<digits>.css` may cache it for a year, since other
--- content has another name.
function Example.mount()
  local source = Assets.memory({ ["app.css"] = "body { margin: 0 }" })
  local app = Web.app{ routes = { StaticFiles.mount("/static", { source = source }) } }
  local url = assert(app:url_for("static", { path = "app.css" }))
  print(url)
  local client = Web.test_client(app)
  local reply = client:get(url)
  assert(reply.status == 200 and reply.body == "body { margin: 0 }")
  assert(reply.headers["cache-control"] == "public, max-age=31536000, immutable")
  local again = client:get("/static/app.css", { headers = { ["If-None-Match"] = assert(reply.headers["etag"]) } })
  assert(again.status == 304 and again.body == "")
end

--- A handler serves a source wherever a route puts it, so an app can
--- choose its own name and reverse lookup.
function Example.handler()
  local source = Assets.memory({ ["hello.txt"] = "hello" })
  local app = Web.app{ routes = { Web.mount_handler("/files",
    StaticFiles.handler({ source = source, cache_control = "no-store" })) } }
  local reply = Web.test_client(app):get("/files/hello.txt")
  assert(reply.body == "hello" and reply.headers["cache-control"] == "no-store")
  print(reply.headers["content-type"])
end

--- `url` computes the same fingerprinted name without an app, for a
--- program that writes pages itself.
function Example.url()
  local source = Assets.memory({ ["css/app.css"] = "a{}" })
  local url = assert(StaticFiles.url(source, "/static", "css/app.css"))
  print(url)
  assert(url:find("^/static/css/app%.%x+%.css$"))
  local missing, why = StaticFiles.url(source, "/static", "nope.css")
  assert(missing == nil)
  assert(why:find("no such asset", 1, true))
end

return Example
