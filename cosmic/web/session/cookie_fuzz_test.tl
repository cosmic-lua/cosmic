--- Fuzz properties for the signed-cookie store, which reads a token the
--- browser chose: no token that the store did not sign loads, none makes it
--- raise, and a token it signed loads back what it held.

local Fuzz = require("build.fuzz")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")

local KEY <const> = "k3Jf9Lq0Zx7Rw2Ub8Tn5Vc1Hd6Ym4Ga0"

local store = SessionCookie.store{ keys = { KEY } }

local function test_an_arbitrary_token_never_loads_and_never_raises(tmp: string)
  local good = assert(store:save("", { values = { user = "ada" }, created = 1, expires = 100 },
    { set = {}, removed = {} }, 1, "session"))
  Fuzz.run({
    name = "session cookie token",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local kind = src:int(0, 3)
      if kind == 0 then return Fuzz.bytes(src, 60) end
      if kind == 1 then return Fuzz.mutate(src, good, 3) end
      return good
    end,
    requires = { "mac_bad", "mac_ok" },
    shares = { mac_bad = 0.2, mac_ok = 0.1 },
    check = function(input: string): boolean, string
      local got, why = store:load(input, 50, "session")
      if got == nil then
        if why ~= "" then return false, "a bad token is a failure of the store: " .. why end
        Fuzz.label("mac_bad")
        return true, ""
      end
      if input ~= good then return false, ("%q loaded as a session"):format(input) end
      Fuzz.label("mac_ok")
      return true, ""
    end,
  })
end

local function test_what_the_store_signs_it_loads_back(tmp: string)
  Fuzz.run({
    name = "session cookie round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack({ Fuzz.bytes(src, 20), tostring(src:int(1, 1000)) })
    end,
    requires = { "saved" },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local text, n = fields[1], math.tointeger(tonumber(fields[2])) or 1
      local data: Session.Data = { values = { text = text, n = n }, created = 1, expires = 100 }
      local token = store:save("", data, { set = {}, removed = {} }, 1, "session")
      if token == nil then
        -- Bytes that are not UTF-8 are not JSON: refused, never signed.
        return true, ""
      end
      Fuzz.label("saved")
      local got = store:load(token, 50, "session")
      if got == nil or got.values.text ~= text or got.values.n ~= n then
        return false, "the session did not come back"
      end
      return true, ""
    end,
  })
end
