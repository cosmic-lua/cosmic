--- Signing keys for [`cosmic.web`]: read from the environment, never from
--- source, and refused when weak. There is no default key: a published
--- default is how an app's sessions get forged.
---
---     local keys = assert(Secret.keys_from_env("COSMIC_SESSION_KEYS"))
---
--- The variable holds a comma-separated list, newest key first
--- (`new,old` while a key is rotated out). A key is the bytes of its
--- text, not decoded, so there is no encoding to get wrong; make one with
--- [`Secret.generate`]. No message here holds a key, only its length.

local Codec = require("cosmic.codec")
local String = require("cosmic.string")
local Env = require("cosmic.env")
local Rand = require("cosmic.rand")

local record Secret
end

local MIN_BYTES <const> = 32
local MAX_KEYS <const> = 5

--- Whether `key` is fit to sign with: at least 32 bytes holding at least
--- 10 distinct byte values. That rejects `"aaaa..."` and `"changeme"`
--- repeated; it is a floor, not a proof of entropy. The reason names the
--- length found and how to make a key, never the key.
--- @param key string The key
--- @return boolean Whether it passes
--- @return string Why not, or ""
function Secret.check(key: string): boolean, string
  if #key < MIN_BYTES then
    return false, ("secret: a key is %s; it must be at least %s (make one with Secret.generate)"):
      format(String.counted(#key, "byte"), String.counted(MIN_BYTES, "byte"))
  end
  local seen: {integer:boolean} = {}
  local distinct = 0
  for i = 1, #key do
    local byte = key:byte(i)
    if not seen[byte] then
      seen[byte] = true
      distinct = distinct + 1
    end
  end
  if distinct < 10 then
    return false, ("secret: a key of %s holds only %d distinct byte values; it must hold at least 10 (make one with Secret.generate)"):
      format(String.counted(#key, "byte"), distinct)
  end
  return true, ""
end

--- The keys in `text`, a comma-separated list, newest first, spaces
--- around an entry trimmed. Nil and why when `text` holds an empty entry,
--- more than 5 keys, or a key [`Secret.check`] refuses; `name` (the
--- variable it was read from) is put in the reason.
--- @param text string The list
--- @param name string | nil Where it came from, for the reason
--- @return {string} | nil The keys
--- @return string Why none, or ""
function Secret.parse_keys(text: string, name?: string): {string} | nil, string
  local where = name or "the key list"
  local keys: {string} = {}
  for piece in (text .. ","):gmatch("([^,]*),") do
    local key = piece:match("^%s*(.-)%s*$")
    local ok, why = Secret.check(key)
    if not ok then
      return nil, ("%s (entry %d of %s)"):format(why, #keys + 1, where)
    end
    keys[#keys + 1] = key
  end
  if #keys > MAX_KEYS then
    return nil, ("secret: %s holds %s; at most %d"):format(where, String.counted(#keys, "key"), MAX_KEYS)
  end
  return keys, ""
end

--- The keys in environment variable `name`: see [`Secret.parse_keys`].
--- Nil and why too when the variable is not set.
--- @param name string The variable's name
--- @return {string} | nil The keys
--- @return string Why none, or ""
function Secret.keys_from_env(name: string): {string} | nil, string
  local value = Env.get(name)
  if value == nil or value == "" then
    return nil, ("secret: %s is not set; generate a key with Secret.generate()"):format(name)
  end
  return Secret.parse_keys(value, name)
end

--- A fresh random key as text, 64 hex characters of 32 bytes from the
--- system's entropy source, to put in an environment variable. Raises
--- where the system gives no entropy.
--- @return string The key
function Secret.generate(): string
  local bytes, why = Rand.entropy(32)
  if bytes == nil then error("secret: no entropy: " .. why, 2) end
  return Codec.hex(bytes)
end

return Secret
