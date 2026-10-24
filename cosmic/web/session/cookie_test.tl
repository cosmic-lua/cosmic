local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Secret = require("cosmic.web.secret")
local Session = require("cosmic.web.session")
local SessionCookie = require("cosmic.web.session.cookie")

local NEW <const> = "k3Jf9Lq0Zx7Rw2Ub8Tn5Vc1Hd6Ym4Ga0"
local OLD <const> = "Qp8Ws2Ed5Rf7Tg1Yh3Uj6Ik9Ol0Pm4Nb"

local function data(values: {string:any}): Session.Data
  return { values = values, created = 1000, expires = 2000 }
end

local function unchanged(): Session.Changes
  return { set = {}, removed = {} }
end

local function sign(store: Session.Store, values: {string:any}): string
  return (assert(store:save("", data(values), unchanged(), 1500, "session")))
end

local function test_a_session_round_trips_with_its_dates()
  local store = SessionCookie.store{ keys = { NEW } }
  local token = sign(store, { user = "ada", n = 7, nested = { 1, 2 } })
  local got = assert(store:load(token, 1500, "session"))
  assert(got.values.user == "ada" and got.values.n == 7 and got.created == 1000 and got.expires == 2000)
  assert(not got.stale and not store.revocable)
  local empty = assert(store:load(sign(store, {}), 1500, "session"))
  assert(next(empty.values) == nil)
end

local function test_flipping_any_character_of_a_token_makes_it_anonymous()
  local store = SessionCookie.store{ keys = { NEW } }
  local token = sign(store, { user = "ada" })
  for i = 1, #token do
    local c = token:sub(i, i)
    local flipped = token:sub(1, i - 1) .. (c == "A" and "B" or "A") .. token:sub(i + 1)
    local got, why = store:load(flipped, 1500, "session")
    assert(got == nil and why == "", "character " .. i .. " was not covered by the MAC")
  end
  assert(store:load(token .. "x", 1500, "session") == nil)
  assert(store:load("", 1500, "session") == nil and store:load(".", 1500, "session") == nil)
  assert(store:load("a.b.c", 1500, "session") == nil)
end

local function test_an_expired_token_is_anonymous_at_the_instant_it_expires()
  local store = SessionCookie.store{ keys = { NEW } }
  local token = sign(store, { user = "ada" })
  assert(store:load(token, 1999, "session") ~= nil)
  assert(store:load(token, 2000, "session") == nil)
  assert(store:load(token, 9999, "session") == nil)
end

local function test_a_token_under_an_old_key_verifies_and_is_marked_stale()
  local old = SessionCookie.store{ keys = { OLD } }
  local rotated = SessionCookie.store{ keys = { NEW, OLD } }
  local token = sign(old, { user = "ada" })
  local got = assert(rotated:load(token, 1500, "session"))
  assert(got.stale and got.values.user == "ada")
  local fresh = sign(rotated, { user = "ada" })
  assert(not assert(rotated:load(fresh, 1500, "session")).stale)
  assert(old:load(fresh, 1500, "session") == nil, "a retired key cannot sign what is read as new")
  local retired = SessionCookie.store{ keys = { NEW } }
  assert(retired:load(token, 1500, "session") == nil, "a key left out of the list is not accepted")
end

local function test_a_token_is_bound_to_its_cookie_name_and_context()
  local store = SessionCookie.store{ keys = { NEW } }
  local token = assert(store:save("", data({ user = "ada" }), unchanged(), 1500, "session"))
  assert(store:load(token, 1500, "remember") == nil)
  local other = SessionCookie.store{ keys = { NEW }, context = "another" }
  assert(other:load(token, 1500, "session") == nil)
end

local function test_a_saved_session_over_the_limit_is_refused_with_the_size()
  local store = SessionCookie.store{ keys = { NEW }, max_bytes = 300 }
  local token, why = store:save("", data({ blob = ("x"):rep(500) }), unchanged(), 1500, "session")
  assert(token == nil and why:find("cookie would be %d+ bytes %(limit 300%)") ~= nil, why)
  assert(why:find("SQLite store", 1, true))
end

local function test_a_token_over_the_limit_is_anonymous_without_decoding_it()
  local big = SessionCookie.store{ keys = { NEW }, max_bytes = 4000 }
  local small = SessionCookie.store{ keys = { NEW }, max_bytes = 100 }
  local token = sign(big, { blob = ("x"):rep(300) })
  assert(big:load(token, 1500, "session") ~= nil)
  assert(small:load(token, 1500, "session") == nil)
end

--- A token for `body` signed as the store signs, for a payload the store
--- would never write.
local function forge(key: string, body: any): string
  local text = assert(Json.encode_any(body))
  local payload = Codec.base64url(text)
  local mac = Hash.hmac("sha256", key, "cosmic.web.session" .. "\0" .. "session" .. "\0" .. payload)
  return payload .. "." .. Codec.base64url(mac)
end

local function test_a_correctly_signed_payload_of_the_wrong_shape_is_anonymous()
  local store = SessionCookie.store{ keys = { NEW } }
  local good = { v = 1, c = 1000, e = 2000, d = { user = "ada" } }
  assert(store:load(forge(NEW, good), 1500, "session") ~= nil, "the forgery helper signs as the store does")
  assert(store:load(forge(NEW, { v = 2, c = 1000, e = 2000, d = {} }), 1500, "session") == nil)
  assert(store:load(forge(NEW, { v = 1, c = "x", e = 2000, d = {} }), 1500, "session") == nil)
  assert(store:load(forge(NEW, { v = 1, c = 1000, e = 2000.5, d = {} }), 1500, "session") == nil)
  assert(store:load(forge(NEW, { v = 1, c = 1000, e = 2000, d = "text" }), 1500, "session") == nil)
  assert(store:load(forge(NEW, { 1, 2, 3 }), 1500, "session") == nil)
end

local function test_a_weak_or_missing_key_is_refused_when_the_store_is_made()
  local ok, why = pcall(SessionCookie.store, { keys = { "short" } })
  assert(not ok and tostring(why):find("key 1", 1, true) and not tostring(why):find("short,", 1, true))
  ok, why = pcall(SessionCookie.store, { keys = {} })
  assert(not ok and tostring(why):find("one to five keys", 1, true))
  local six: {string} = {}
  for i = 1, 6 do six[i] = Secret.generate() end
  ok = pcall(SessionCookie.store, { keys = six })
  assert(not ok)
end

local function test_destroy_does_nothing_because_a_cookie_cannot_be_revoked()
  local store = SessionCookie.store{ keys = { NEW } }
  local token = sign(store, { user = "ada" })
  assert(store:destroy(token))
  assert(store:load(token, 1500, "session") ~= nil, "the copy of the cookie is still good")
end

local function nest(levels: integer): any
  local value: any = 1
  for _ = 1, levels do value = { value } end
  return value
end

local function test_save_refuses_what_load_cannot_read()
  local store = SessionCookie.store{ keys = { NEW } }
  local at = sign(store, { deep = nest(Session.MAX_DEPTH - 1) })
  assert(store:load(at, 1500, "session") ~= nil, "a value at the limit loads back")
  local token, why = store:save("", data({ deep = nest(Session.MAX_DEPTH) }), unchanged(), 1500, "session")
  assert(token == nil and why:find("cannot encode", 1, true), why)
end

local function test_the_keys_are_copied_and_checked_as_strings_when_the_store_is_made()
  local keys = { NEW }
  local store = SessionCookie.store{ keys = keys }
  local token = sign(store, { user = "ada" })
  keys[1] = OLD
  assert(store:load(token, 1500, "session") ~= nil, "changing the list afterwards changes no key")
  assert(sign(store, { user = "ada" }) == token)
  local ok, why = pcall(SessionCookie.store, { keys = { NEW, 42 as any as string } })
  assert(not ok and tostring(why):find("key 2 is a number", 1, true), tostring(why))
end
