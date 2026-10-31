--- A policy as JSON text, read and written: [`PolicyJson.decode`] reads a
--- [`Sandbox.Policy`] strictly -- a key it does not know, a value of the
--- wrong type or a letter outside "rwxcu" is refused, naming the field by
--- its path -- and [`PolicyJson.encode`] writes a merged policy
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
local FieldPath = require("cosmic.internal.field_path")
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

local POLICY <const>: Shape.Typed<Sandbox.Policy> = Shape.record_of("cosmic.sandbox.Policy"):strict()

local DATABASE <const> = FieldPath.field(FieldPath.root, "database")

--- The policy `json` holds. Strict: a key this module does not know, a
--- value of the wrong type, an `isolate` or a promise it does not name,
--- a profile it has not, and a grant whose `letters` are not in the order
--- of "rwxcu", each once, are refused. The field is named by its path
--- in both cases, a shape that is wrong (`$.limits.open_files: want integer,
--- got string`) or a content that is (`$.grants[0].letters: ...`), arrays
--- counted from 0.
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
---     print(why) -- sandbox: $.grants[0].letters: "xr" is not in the order of "rwxcu", each letter once: "rx"
function PolicyJson.decode(json: string): Sandbox.Policy?, string
  local policy, why = Shape.decode_into(json, POLICY.spec)
  if policy == nil then return nil, "sandbox: " .. why end
  -- The type of a database may leave its digest out; the text may not.
  local database = policy.database
  if database ~= nil and database.sha256 == nil then
    return nil, "sandbox: " .. FieldPath.field(DATABASE, "sha256") .. ": missing"
  end
  local ok, bad = Sandbox.check(policy, true)
  if not ok then return nil, bad end
  if database ~= nil then
    local bytes, trouble = Fs.read(database.path)
    if bytes == nil then
      return nil, "sandbox: " .. FieldPath.field(DATABASE, "path") .. ": " .. trouble
    end
    if Hash.hex_sha256(bytes) ~= database.sha256 then
      return nil, "sandbox: " .. FieldPath.field(DATABASE, "sha256") .. ": " .. database.path ..
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
  local profiles = p.profiles
  if profiles ~= nil and #profiles > 0 then
    error("sandbox: encode takes a merged policy: resolve profiles with Sandbox.merge first", 2)
  end
  local made, why = Sandbox.merge(p)
  if made == nil then error(why, 2) end
  local merged: Sandbox.Policy = made
  local digests: mut {string:string} = {}
  for name, digest in pairs(merged.set_env_digests or {}) do digests[name] = digest end
  for name, value in pairs(merged.set_env or {}) do digests[name] = digest_of(value) end
  local fields: mut {string: Json.Value} = {}
  local function put(name: string, list: {string})
    if #list > 0 then fields[name] = Json.array(list) end
  end
  put("isolate", merged.isolate or {})
  put("promises", merged.promises or {})
  put("connect", merged.connect or {})
  put("loopback", merged.loopback or {})
  put("env", merged.env or {})
  local grants: mut {Json.Value} = {}
  for _, grant in ipairs(merged.grants or {}) do
    local written: mut {string: Json.Value} = { path = grant.path, letters = grant.letters }
    local from = grant.from
    if from ~= nil then written["from"] = from end
    grants[#grants + 1] = written
  end
  if #grants > 0 then fields["grants"] = Json.array(grants) end
  if next(digests) ~= nil then fields["set_env_digests"] = digests end
  if merged.tmp == true then fields["tmp"] = true end
  local user, group = merged.user, merged.group
  if user ~= nil then fields["user"] = user end
  if group ~= nil then fields["group"] = group end
  local database = merged.database
  if database ~= nil then
    local digest = database.sha256
    if digest == nil then
      error("sandbox: encode: database " .. database.path .. " names no digest: give it one " ..
          "with Sandbox.database(path), which hashes the file now", 2)
    end
    local bytes, trouble = Fs.read(database.path)
    if bytes == nil then error("sandbox: encode: database " .. trouble, 2) end
    if digest ~= Hash.hex_sha256(bytes) then
      error("sandbox: encode: database " .. database.path .. " is not the one the policy " ..
          "names: its SHA-256 has changed since", 2)
    end
    fields["database"] = { path = database.path, sha256 = digest }
  end
  local limits = merged.limits or {}
  if limits.open_files ~= nil or limits.file_bytes ~= nil or limits.cpu_seconds ~= nil or
      limits.processes ~= nil then
    local written: mut {string: Json.Value} = {}
    local open_files, file_bytes = limits.open_files, limits.file_bytes
    local cpu_seconds, processes = limits.cpu_seconds, limits.processes
    if open_files ~= nil then written["open_files"] = open_files end
    if file_bytes ~= nil then written["file_bytes"] = file_bytes end
    if cpu_seconds ~= nil then written["cpu_seconds"] = cpu_seconds end
    if processes ~= nil then written["processes"] = processes end
    fields["limits"] = written
  end
  return (assert(Json.encode(fields)))
end

return PolicyJson
