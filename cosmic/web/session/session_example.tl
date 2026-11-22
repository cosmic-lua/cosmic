--- Worked examples for [`cosmic.web.session`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test.

local Clock = require("cosmic.clock")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local SessionSqlite = require("cosmic.web.session.sqlite")
local Sqlite = require("cosmic.sqlite")
local Web = require("cosmic.web")

local Example = {} -- checked: literal_needs_type

--- A visit counter in a signed cookie. A request that only reads the
--- session sends no cookie; one that changes it sends one.
function Example.middleware()
  local app = Web.app{
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        local session = Session.of(req)
        local visits = (session:get_integer("visits") or 0) + 1
        session:set("visits", visits)
        return Web.text("visit " .. tostring(visits))
      end),
    },
    middleware = { Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } } },
  }
  local client = Web.test_client(app)
  -- A browser on an https page: the session cookie is Secure.
  client.scheme = "https"
  client:get("/")
  local second = client:get("/")
  print(second:text(), second.headers["vary"])
  assert(second:text() == "visit 2" and second.headers["vary"] == "Cookie")
end

--- A flash message after a redirect, shown once.
function Example.flash()
  local app = Web.app{
    routes = {
      Web.post("/save", function(req: Web.Request): Web.Response
        Session.of(req):flash("success", "Saved")
        return Web.redirect("/")
      end),
      Web.get("/", function(req: Web.Request): Web.Response
        local out: mut {string} = {}
        for _, each in ipairs(Session.of(req):take_flashes()) do out[#out + 1] = each.text end
        return Web.text(table.concat(out, ","))
      end),
    },
    middleware = { Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } } },
  }
  local client = Web.test_client(app)
  client.scheme = "https"
  client:post("/save", { follow_redirects = true })
  local first = client:get("/"):text()
  print(if first == "" then "(none)" else first end)
  assert(first == "" and client:get("/"):text() == "")
end

--- A middleware outside [`Session.middleware`] reads the handle by
--- [`Session.KEY`]; it is nil where the middleware is not installed, and
--- [`Session.of`] raises there.
function Example.key()
  local installed: mut {boolean} = {}
  local app = Web.app{
    routes = { Web.get("/", function(_req: Web.Request): Web.Response return Web.text("ok") end) },
    middleware = {
      Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } },
      function(inner: Web.Handler): Web.Handler
        return function(req: Web.Request): Web.Response
          installed[1] = req:get(Session.KEY) ~= nil
          return inner(req)
        end
      end,
    },
  }
  Web.test_client(app):get("/")
  print(installed[1])
  assert(installed[1] == true)
end

--- Sessions in SQLite are revocable: logging out ends the session on the
--- server, and [`SessionSqlite.destroy_subject`] ends all of a user's.
function Example.logout_everywhere()
  local db = assert(Sqlite.memory())
  local store = assert(SessionSqlite.store(db))
  local app = Web.app{
    routes = {
      Web.post("/login", function(req: Web.Request): Web.Response
        local session = Session.of(req)
        session:regenerate()
        session:set("user", "ada")
        session:bind_subject("ada")
        return Web.text("in")
      end),
      Web.get("/me", function(req: Web.Request): Web.Response
        return Web.text(Session.of(req):get_string("user") or "anonymous")
      end),
    },
    middleware = { Session.middleware{ store = store } },
  }
  local laptop, phone = Web.test_client(app), Web.test_client(app)
  laptop.scheme, phone.scheme = "https", "https"
  laptop:post("/login")
  phone:post("/login")
  print(SessionSqlite.destroy_subject(store, "ada"), laptop:get("/me"):text())
  assert(laptop:get("/me"):text() == "anonymous" and phone:get("/me"):text() == "anonymous")
  -- Rows past their expiry are swept by a save; a lifespan task can sweep on a timer.
  print(SessionSqlite.sweep(store, 0))
  assert(SessionSqlite.sweep(store, 0) == 0)
end

--- A page of "your devices": [`SessionSqlite.list`] answers a user's
--- sessions with a label each and when and from where each was last seen,
--- never a token; [`SessionSqlite.info`] finds the request's own, and
--- [`SessionSqlite.destroy_id`] forgets one by its public id.
function Example.devices()
  local store = assert(SessionSqlite.store(assert(Sqlite.memory()), { seen_interval = 60 }))
  local app = Web.app{
    routes = {
      Web.post("/pair/:name", function(req: Web.Request): Web.Response
        local session = Session.of(req)
        session:regenerate()
        session:bind_subject("home")
        session:label(assert(req.params["name"]))
        return Web.text("paired")
      end),
      Web.get("/devices", function(req: Web.Request): Web.Response
        local now = Clock.now_ns() // 1000000000
        local mine = SessionSqlite.info(store, Session.of(req):id(), now)
        local lines: mut {string} = {}
        for _, device in ipairs((assert(SessionSqlite.list(store, now, { subject = "home" })))) do
          local this = if mine ~= nil and mine.id == device.id then " (this one)" else "" end
          lines[#lines + 1] = (device.label or device.id) .. this
        end
        return Web.text(table.concat(lines, "\n"))
      end),
    },
    middleware = { Session.middleware{ store = store } },
  }
  local ipad, phone = Web.test_client(app), Web.test_client(app)
  ipad.scheme, phone.scheme = "https", "https"
  ipad:post("/pair/iPad")
  phone:post("/pair/phone")
  print(ipad:get("/devices"):text())
  local listed = assert(SessionSqlite.list(store, Clock.now_ns() // 1000000000, { subject = "home" }))
  for _, device in ipairs(listed) do
    if device.label == "phone" then
      assert(SessionSqlite.label(store, device.id, "old phone", "home") == 1)
      assert(SessionSqlite.destroy_id(store, device.id, "home") == 1)
    end
  end
  assert(ipad:get("/devices"):text() == "iPad (this one)")
end

return Example -- checked: export_not_declared
