--- A policy as JSON text, read and written: [`PolicyJson.decode`] reads a
--- [`Sandbox.Policy`] strictly -- a key it does not know, a value of the
--- wrong type or a letter outside "rwxcu" is refused, naming the field by
--- its JSON Pointer -- and [`PolicyJson.encode`] writes a merged policy
--- as canonical JSON, the same text for the same policy, with `set_env`'s
--- values as digests. It is apart from [`cosmic.sandbox`], the policy's
--- data and merge, so that a program that only runs a child under a
--- policy does not carry a JSON reader and a schema checker.
---
---     local PolicyJson = require("cosmic.policy")
---
---     local policy = assert(PolicyJson.decode('{"grants":[{"path":"data","letters":"r"}],"tmp":true}'))
---     print(policy.grants[1].path, policy.tmp) -- data  true

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Sandbox = require("cosmic.sandbox")
local Shape = require("cosmic.shape")

local record PolicyJson
end

--- The SHA-256 of `value`, in lowercase hex, as [`Sandbox.merge`] holds a
--- `set_env` value to its digest.
local function digest_of(value: string): string
  return Codec.hex(Hash.sha256(value))
end

local LIMITS_SPEC <const> = Shape.strict_record({
  open_files = Shape.optional(Shape.integer),
  file_bytes = Shape.optional(Shape.integer),
  cpu_seconds = Shape.optional(Shape.integer),
  processes = Shape.optional(Shape.integer),
})

local GRANT_SPEC <const> = Shape.strict_record({
  path = Shape.string,
  letters = Shape.string,
  from = Shape.optional(Shape.string),
})

--- A database as the text writes it: where it is and what it is.
local DATABASE_SPEC <const> = Shape.strict_record({
  path = Shape.string,
  sha256 = Shape.string,
})

local POLICY_SPEC <const> = Shape.strict_record({
  profiles = Shape.optional(Shape.list(Shape.string)),
  grants = Shape.optional(Shape.list(GRANT_SPEC)),
  isolate = Shape.optional(Shape.list(Shape.one_of("file", "proc"))),
  promises = Shape.optional(Shape.list(Shape.one_of("fork", "jit", "fattr", "nest"))),
  connect = Shape.optional(Shape.list(Shape.string)),
  loopback = Shape.optional(Shape.list(Shape.string)),
  env = Shape.optional(Shape.list(Shape.string)),
  set_env = Shape.optional(Shape.map(Shape.string)),
  set_env_digests = Shape.optional(Shape.map(Shape.string)),
  tmp = Shape.optional(Shape.boolean),
  limits = Shape.optional(LIMITS_SPEC),
  user = Shape.optional(Shape.integer),
  group = Shape.optional(Shape.integer),
  database = Shape.optional(DATABASE_SPEC),
})

--- The policy `json` holds. Strict: a key this module does not know, a
--- value of the wrong type, an `isolate` or a promise it does not name,
--- a profile it has not, and a grant whose `letters` are not in the order
--- of "rwxcu", each once, are refused, naming the field by its JSON
--- Pointer (`pointer "/grants/0/letters": ...`, arrays counted from 0).
--- A hand-built [`Sandbox.Policy`] is judged by [`Sandbox.merge`]
--- instead, which takes any order of letters and writes them in this one.
--- A `database` is `{"path": ..., "sha256": ...}`: the file must be there
--- and hash to that, or the policy is refused. The digest is kept with the
--- policy as the `sha256` of its `database`, and [`Child.start`] hashes the
--- file again just before it starts the core on it, refusing one that has
--- changed; the core opens it by its path after that, so a file swapped in
--- that instant is not caught.
---
---     local policy = assert(PolicyJson.decode('{"env":["HOME"],"tmp":true}'))
---     print(policy.env[1], policy.tmp) -- HOME  true
---     local bad, why = PolicyJson.decode('{"grants":[{"path":"x","letters":"xr"}]}')
---     print(why) -- sandbox: pointer "/grants/0/letters": "xr" is not in the order of "rwxcu", each letter once: "rx"
function PolicyJson.decode(json: string): Sandbox.Policy | nil, string
  local policy, why: Sandbox.Policy | nil, string = Shape.decode_into(json, POLICY_SPEC)
  if policy == nil then return nil, "sandbox: " .. why end
  local ok, bad = Sandbox.check(policy, true)
  if not ok then return nil, bad end
  local database = policy.database
  if database ~= nil then
    local bytes, trouble = Fs.read(database.path)
    if bytes == nil then
      return nil, "sandbox: pointer \"/database/path\": " .. trouble
    end
    if Hash.hex_sha256(bytes) ~= database.sha256 then
      return nil, "sandbox: pointer \"/database/sha256\": " .. database.path ..
        " is not the database the text names: its SHA-256 differs"
    end
  end
  return policy, ""
end

--- A merged policy as canonical JSON: keys in byte order, lists sorted,
--- a field with nothing in it left out, `profiles` resolved away, and
--- `set_env`'s values written as `set_env_digests`, so the text names a
--- variable and shows its value changed without showing it. The same
--- policy is the same text, and [`PolicyJson.decode`] reads it back to a
--- policy that encodes to the same text again. A digest is the SHA-256 of
--- the value, unsalted: one of a value that can be guessed (a short
--- password, a flag) can be found by trying guesses, so a printed policy
--- keeps a value's change from view, not a secret from a reader who can
--- guess it. A `database` is written as its path and its `sha256`, which
--- must be there: a path alone raises, naming [`Sandbox.database`], the
--- one way a file is given a digest, since hashing at encode would bless
--- whatever is there at that moment. It also raises if the file no longer
--- hashes to the digest, so encoding never rebases a checked database, or
--- if it is unreadable. What a profile names is a path of this host, so an
--- encoding that resolved one is one host's. Raises for a policy that
--- is not merged -- one with `profiles`, or [`Sandbox.merge`] would refuse
--- -- since text cannot say what was dropped.
---
---     local text = PolicyJson.encode(assert(Sandbox.merge({ tmp = true, set_env = { MODE = "fast" } })))
---     print(text) -- {"set_env_digests":{"MODE":"..."},"tmp":true}
function PolicyJson.encode(p: Sandbox.Policy): string
  if p.profiles ~= nil and #p.profiles > 0 then
    error("sandbox: encode takes a merged policy: resolve profiles with Sandbox.merge first", 2)
  end
  local made, why = Sandbox.merge(p)
  if made == nil then error(why, 2) end
  local merged: Sandbox.Policy = made
  local digests: {string:string} = {}
  for name, digest in pairs(merged.set_env_digests) do digests[name] = digest end
  for name, value in pairs(merged.set_env) do digests[name] = digest_of(value) end
  local fields: {string:any} = {}
  local function put(name: string, list: {any})
    if #list > 0 then fields[name] = list end
  end
  put("isolate", merged.isolate)
  put("promises", merged.promises)
  put("connect", merged.connect)
  put("loopback", merged.loopback)
  put("env", merged.env)
  local grants: {{string:string}} = {}
  for _, grant in ipairs(merged.grants) do
    grants[#grants + 1] = { path = grant.path, letters = grant.letters, from = grant.from }
  end
  put("grants", grants)
  if next(digests) ~= nil then fields.set_env_digests = digests end
  if merged.tmp then fields.tmp = true end
  fields.user, fields.group = merged.user, merged.group
  local database = merged.database
  if database ~= nil then
    if database.sha256 == nil then
      error("sandbox: encode: database " .. database.path .. " names no digest: give it one " ..
          "with Sandbox.database(path), which hashes the file now", 2)
    end
    local bytes, trouble = Fs.read(database.path)
    if bytes == nil then error("sandbox: encode: database " .. trouble, 2) end
    local digest = Hash.hex_sha256(bytes)
    if database.sha256 ~= digest then
      error("sandbox: encode: database " .. database.path .. " is not the one the policy " ..
          "names: its SHA-256 has changed since", 2)
    end
    fields.database = { path = database.path, sha256 = database.sha256 }
  end
  local limits = merged.limits
  if limits.open_files ~= nil or limits.file_bytes ~= nil or limits.cpu_seconds ~= nil or
      limits.processes ~= nil then
    fields.limits = limits
  end
  return (assert(Json.encode(fields)))
end

return PolicyJson
