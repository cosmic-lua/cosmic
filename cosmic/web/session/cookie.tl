--- The signed-cookie store of [`cosmic.web.session`]: the whole session
--- travels in the cookie, signed with HMAC-SHA-256, so the server keeps
--- nothing and reads no database.
---
---     local store = SessionCookie.store{ keys = assert(Secret.keys_from_env("SESSION_KEYS")) }
---
--- **The cookie is signed, not encrypted.** Anyone holding it can read
--- what is in it (it is base64url of JSON), so never keep a secret, another
--- user's data or anything the user must not see. A signed cookie cannot be
--- revoked either: logout clears it in the browser, but a copy stays valid
--- until it expires. For sessions that gate authority, use
--- [`cosmic.web.session.sqlite`], or keep a per-user version in the session
--- and compare it with the database. cosmic has no authenticated cipher; an
--- encrypted store is the extension once it has one, and the token's `v`
--- field is its version hook.
---
--- The token is `base64url(payload) "." base64url(mac)`, the payload JSON
--- `{v, c = created, e = expires, d = values}`, the MAC over the store's
--- context, the cookie's name and the encoded payload, so a token minted for
--- one cookie is no good as another. The expiry is in the payload and
--- checked here; the cookie's `Max-Age` is advisory. `keys` rotates:
--- `{ new, old }` signs with `new` and verifies with both, and a session
--- read under `old` is signed again under `new` at once.

local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Secret = require("cosmic.web.secret")
local String = require("cosmic.string")
local Session = require("cosmic.web.session")

local record SessionCookie
  --- What [`SessionCookie.store`] takes.
  record Options
    --- Newest first: the first signs, all verify. One to five, each
    --- passing [`Secret.check`].
    keys: {string}
    --- The largest token in bytes (3800), so the cookie line stays under a
    --- browser's 4096.
    max_bytes?: integer
    --- Mixed into the MAC with the cookie's name ("cosmic.web.session").
    context?: string
  end
end

local VERSION <const> = 1
--- The payload nests the values one level down.
local DEPTH <const> = Session.MAX_DEPTH + 1

--- The store: see this module's description. Raises for no key, a key
--- [`Secret.check`] refuses, or more than five.
--- @param opts SessionCookie.Options The keys
--- @return Session.Store The store
function SessionCookie.store(opts: SessionCookie.Options): Session.Store
  local supplied = opts.keys
  if type(supplied) ~= "table" or #supplied < 1 or #supplied > 5 then
    error("session: the cookie store needs one to five keys", 2)
  end
  -- A copy, so changing the caller's list later changes no key in use.
  local keys: {string} = {}
  for i = 1, #supplied do
    local key = supplied[i]
    if type(key) ~= "string" then
      error(("session: key %d is a %s, not a string"):format(i, type(key)), 2)
    end
    local ok, why = Secret.check(key)
    if not ok then error(("session: key %d: %s"):format(i, why), 2) end
    keys[i] = key
  end
  local max_bytes = opts.max_bytes or 3800
  local context = opts.context or "cosmic.web.session"

  local function mac(key: string, cookie: string, payload: string): string
    return Hash.hmac("sha256", key, context .. "\0" .. cookie .. "\0" .. payload)
  end

  local store: Session.Store = { revocable = false }

  store.load = function(_: Session.Store, token: string, now: integer, cookie: string): Session.Data | nil, string
    if #token > max_bytes then return nil, "" end
    local payload, sent = token:match("^([^.]+)%.([^.]+)$")
    if payload == nil then return nil, "" end
    local given, _ = Codec.unbase64url(sent)
    if given == nil then return nil, "" end
    local verified: integer | nil = nil
    for i, key in ipairs(keys) do
      -- Every key is tried, so the time taken does not say which matched.
      if Hash.equal(mac(key, cookie, payload), given) and verified == nil then verified = i end
    end
    if verified == nil then return nil, "" end
    local bytes, _ = Codec.unbase64url(payload)
    if bytes == nil then return nil, "" end
    local body, _ = Json.decode(bytes, { max_depth = DEPTH })
    if not body is {string:any} then return nil, "" end
    local created, expires, values = body.c, body.e, body.d
    if body.v ~= VERSION or not created is integer or not expires is integer or
        not values is {string:any} then
      return nil, ""
    end
    if expires <= now then return nil, "" end
    return { values = values, created = created, expires = expires, stale = verified > 1 }, ""
  end

  store.save = function(_: Session.Store, _previous: string, data: Session.Data,
                        _changes: Session.Changes, _now: integer, cookie: string): string | nil, string
    local values: {string:any} = data.values
    local text, why = Json.encode_any({ v = VERSION, c = data.created, e = data.expires, d = values },
      { max_depth = DEPTH })
    if text == nil then return nil, "cannot encode the session: " .. why end
    local payload = Codec.base64url(text)
    local token = payload .. "." .. Codec.base64url(mac(keys[1], cookie, payload))
    if #token > max_bytes then
      return nil, ("cookie would be %s (limit %d); keep ids, not objects, in the session or use the SQLite store"):
        format(String.counted(#token, "byte"), max_bytes)
    end
    return token, ""
  end

  store.destroy = function(_: Session.Store, _token: string): boolean, string
    return true, ""
  end

  return store
end

return SessionCookie
