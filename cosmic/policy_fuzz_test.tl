--- Fuzz properties for [`cosmic.policy`]'s `decode`, which reads a
--- policy from text that may come from anywhere: it is total on any
--- bytes, answering a policy or a refusal under the module's name; a
--- policy it takes merges and encodes, and its encoding decodes and
--- encodes to the same text again. `FUZZ_SEED` and `FUZZ_ITERS` pick
--- the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Json = require("cosmic.json")
local Sandbox = require("cosmic.sandbox")
local PolicyJson = require("cosmic.policy")

--- Values a field of a policy has to get right, valid and not.
local LETTERS <const> = { "r", "rw", "rwxcu", "x", "xr", "rr", "", "z", "RX", "cu", "wc" }
local PATHS <const> = { "a", "/", "/usr", "data dir", "..", "\0", "", "\xff", "/x\u{e9}" }
local TARGETS <const> = { "h:1", "*:*", "h:*", "h:0", "h:65536", ":1", "h", "[::1]:443", "a:b:c" }
local ADDRESSES <const> = { "127.0.0.1", "127.255.255.255", "127.0.0.01", "127.0.0.256", "10.0.0.1", "127.1" }
local NAMES <const> = { "A", "HOME", "", "A=B", "\0", "TMPDIR", "x y" }
local ISOLATES <const> = { "file", "proc", "net" }
local PROMISES <const> = { "fork", "jit", "fattr", "nest", "ptrace" }
local PROFILES <const> = { "system", "cosmic", "bogus" }
local NUMBERS <const> = { 0, 1, 2, 64, 1024, -1 }
local DIGESTS <const> = { string.rep("a", 64), string.rep("A", 64), "abc", string.rep("0", 63) }

--- A list of up to `max` draws from `pool`, or nil for none.
local function list(src: Fuzz.Source, pool: {string}, max: integer): {string} | nil
  if src:int(0, 2) == 0 then return nil end
  local out: {string} = {}
  while Fuzz.more(src, #out, max) do out[#out + 1] = Fuzz.pick(src, pool) end
  if #out == 0 then return nil end
  return out
end

--- A policy as a table of the fields it names, each a draw from the pools
--- above, mostly valid.
local function gen_policy(src: Fuzz.Source): {string:any}
  local fields: {string:any} = {}
  fields.profiles = list(src, PROFILES, 3)
  fields.isolate = list(src, ISOLATES, 3)
  fields.promises = list(src, PROMISES, 5)
  fields.connect = list(src, TARGETS, 4)
  fields.loopback = list(src, ADDRESSES, 3)
  fields.env = list(src, NAMES, 4)
  if src:int(0, 2) == 0 then
    local grants: {{string:string}} = {}
    while Fuzz.more(src, #grants, 4) do
      grants[#grants + 1] = { path = Fuzz.pick(src, PATHS), letters = Fuzz.pick(src, LETTERS),
        from = src:int(0, 3) == 0 and Fuzz.pick(src, PATHS) or nil }
    end
    if #grants > 0 then fields.grants = grants end
  end
  if src:int(0, 2) == 0 then
    local set_env: {string:string} = {}
    while Fuzz.more(src, 0, 3) do set_env[Fuzz.pick(src, NAMES)] = Fuzz.pick(src, PATHS) end
    if next(set_env) ~= nil then fields.set_env = set_env end
  end
  if src:int(0, 3) == 0 then
    fields.set_env_digests = { [Fuzz.pick(src, NAMES)] = Fuzz.pick(src, DIGESTS) }
  end
  if src:int(0, 2) == 0 then fields.tmp = src:int(0, 4) ~= 0 end
  if src:int(0, 2) == 0 then
    fields.limits = { open_files = Fuzz.pick(src, NUMBERS), file_bytes = Fuzz.pick(src, NUMBERS),
      cpu_seconds = src:int(0, 1) == 0 and Fuzz.pick(src, NUMBERS) or nil,
      processes = src:int(0, 1) == 0 and Fuzz.pick(src, NUMBERS) or nil }
  end
  if src:int(0, 6) == 0 then fields.extra = 1 end
  return fields
end

--- The text of such a policy, now and then with bytes mutated, or bytes alone.
local function gen_text(src: Fuzz.Source): string
  local kind = src:int(0, 5)
  if kind == 0 then return Fuzz.bytes(src, 64) end
  local text = Json.encode(gen_policy(src)) or "{}"
  if kind <= 2 then return Fuzz.mutate(src, text, 3) end
  return text
end

local function test_decode_is_total_and_refuses_under_its_name(tmp: string)
  Fuzz.run({
    name = "sandbox decode total",
    dir = tmp,
    gen = gen_text,
    requires = { "decoded", "refused" },
    shares = { decoded = 0.05, refused = 0.2 },
    check = function(input: string): boolean, string
      local policy, why = PolicyJson.decode(input)
      if policy == nil then
        if not why:find("^sandbox: ") and not why:find("^sandbox: json") then
          return false, "refused without its name: " .. why
        end
        Fuzz.label("refused")
        return true, ""
      end
      if why ~= "" then return false, "decoded with a reason: " .. why end
      Fuzz.label("decoded")
      return true, ""
    end,
  })
end

local function test_a_decoded_policy_encodes_to_text_that_encodes_the_same(tmp: string)
  Fuzz.run({
    name = "sandbox encode round trip",
    dir = tmp,
    gen = gen_text,
    requires = { "merged", "round tripped" },
    shares = { merged = 0.02 },
    check = function(input: string): boolean, string
      local policy = PolicyJson.decode(input)
      if policy == nil then return true, "" end
      -- A policy naming "cosmic" merges here; one naming a profile this
      -- host cannot give is refused by merge, which says why.
      local merged, why = Sandbox.merge(policy)
      if merged == nil then
        if not why:find("^sandbox: ") then
          return false, "merge refused without its name: " .. why
        end
        return true, ""
      end
      Fuzz.label("merged")
      local text = PolicyJson.encode(merged)
      local back, trouble = PolicyJson.decode(text)
      if back == nil then return false, "its encoding " .. text .. " was refused: " .. trouble end
      if PolicyJson.encode(back) ~= text then
        return false, ("encoding %s decoded and encoded as %s"):format(text, PolicyJson.encode(back))
      end
      Fuzz.label("round tripped")
      return true, ""
    end,
  })
end
