--- Worked examples for [`cosmic.web.session`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test.

local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")
local SessionSqlite = require("cosmic.web.session.sqlite")
local Sqlite = require("cosmic.sqlite")
local Web = require("cosmic.web")

local Example = {}

--- A visit counter in a signed cookie. A request that only reads the
--- session sends no cookie; one that changes it sends one.
function Example.middleware()
  local app = Web.app{
    routes = {
      Web.get("/", function(req: Web.Request): Web.Response
        local session = Session.of(req)
        local visits = (session:get_integer("visits") or 0) + 1
        session:set("visits", visits)
        return Web.text("visit " .. visits)
      end),
    },
    middleware = { Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } } },
  }
  local client = Web.test_client(app)
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
        local out: {string} = {}
        for _, each in ipairs(Session.of(req):take_flashes()) do out[#out + 1] = each.text end
        return Web.text(table.concat(out, ","))
      end),
    },
    middleware = { Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } } },
  }
  local client = Web.test_client(app)
  client:post("/save", { follow_redirects = true })
  local first = client:get("/"):text()
  print(first == "" and "(none)" or first)
  assert(first == "" and client:get("/"):text() == "")
end

--- A middleware outside [`Session.middleware`] reads the handle by
--- [`Session.KEY`]; it is nil where the middleware is not installed, and
--- [`Session.of`] raises there.
function Example.key()
  local installed: boolean = nil
  local app = Web.app{
    routes = { Web.get("/", function(_req: Web.Request): Web.Response return Web.text("ok") end) },
    middleware = {
      Session.middleware{ store = SessionCookie.store{ keys = { Secret.generate() } } },
      function(inner: Web.Handler): Web.Handler
        return function(req: Web.Request): Web.Response
          installed = req:get(Session.KEY) ~= nil
          return inner(req)
        end
      end,
    },
  }
  Web.test_client(app):get("/")
  print(installed)
  assert(installed == true)
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
  laptop:post("/login")
  phone:post("/login")
  print(SessionSqlite.destroy_subject(store, "ada"), laptop:get("/me"):text())
  assert(laptop:get("/me"):text() == "anonymous" and phone:get("/me"):text() == "anonymous")
  -- Rows past their expiry are swept by a save; a lifespan task can sweep on a timer.
  print(SessionSqlite.sweep(store, 0))
  assert(SessionSqlite.sweep(store, 0) == 0)
end

return Example
