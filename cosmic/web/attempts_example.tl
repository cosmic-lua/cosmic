--- Worked examples for [`cosmic.web.attempts`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test.

local Attempts = require("cosmic.web.attempts")
local Clock = require("cosmic.clock")
local Web = require("cosmic.web")

local record Example end

--- A login limited per client address: three wrong passwords in a minute,
--- then a 429 with `Retry-After` until the first of them is a minute old.
function Example.limiter()
  local login = Attempts.limiter{ limit = 3, window_ns = Clock.minutes(1) }
  local app = Web.app{
    sink = { line = function(_self: Web.Sink, _text: string) end },
    routes = { Web.post("/login", function(req: Web.Request): Web.Response
      local key = if req.client ~= nil then req.client.host else "-" end
      local password = req:text()
      local wait_ns = login:wait_ns(key)
      if wait_ns > 0 then return Attempts.too_many(wait_ns) end
      if password ~= "correct horse" then
        login:failed(key)
        return Web.text("wrong password", { status = 401 })
      end
      login:reset(key)
      return Web.text("welcome")
    end) },
  }
  local client = Web.test_client(app)
  for _ = 1, 3 do assert(client:post("/login", { body = "guess" }).status == 401) end
  local refused = client:post("/login", { body = "correct horse" })
  print(refused.status, refused.headers["retry-after"])
  assert(refused.status == 429 and refused.headers["retry-after"] == "60")
end

--- The header's value for a wait: whole seconds, rounded up.
function Example.retry_after()
  print(Attempts.retry_after(Clock.ms(1500)))
  assert(Attempts.retry_after(Clock.ms(1500)) == "2")
end

--- Bytes a client may upload in a minute, weighed as they come: the count
--- of a key's window is what it has sent since the window began, and
--- `wait_ns` says how long until a new window lets it send again.
function Example.tally()
  local uploaded = Attempts.tally{ window_ns = Clock.minutes(1) }
  local limit = 1000
  assert(uploaded:add("10.0.0.1", 600) == 600)
  local count = uploaded:add("10.0.0.1", 600)
  print(count, count > limit)
  assert(count == 1200 and uploaded:wait_ns("10.0.0.1") > 0)
  assert(uploaded:count("10.0.0.2") == 0, "another client counts alone")
end

return Example
