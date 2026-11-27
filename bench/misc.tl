--- Run-time microbenchmarks of the smaller modules: `bin/cosmic bench/misc.tl [name...]`.
--- JSON Schema and JWT checks, key generation, QR codes, property lists, dates and times, DNS messages, and the start of
--- the built binary. Each case is one line on [`bench.harness`], which takes `--json`, `--rounds` and
--- `--against <old-binary>`. It measures; it gates nothing, and no test reads its numbers.
local Bench = require("bench.harness")
local Clock = require("cosmic.clock")
local Dns = require("cosmic.dns")
local Jose = require("cosmic.jose")
local Json = require("cosmic.json")
local JsonSchema = require("cosmic.jsonschema")
local Key = require("cosmic.key")
local Plist = require("cosmic.plist")
local Qr = require("cosmic.qr")
local Time = require("cosmic.time")

local bench = Bench.new("misc")
local case = bench.case

-- JSON Schema: 1000 records checked against a schema of five properties.
local schema_text = [[{"type":"object","required":["id","name"],"properties":{
  "id":{"type":"integer","minimum":1},"name":{"type":"string","minLength":1,"maxLength":40},
  "score":{"type":"number"},"active":{"type":"boolean"},
  "tags":{"type":"array","items":{"type":"string"},"maxItems":8}}}]]
local schema_value, schema_why = Json.decode(schema_text)
if schema_value == nil then error(tostring(schema_why)) end
local schema = JsonSchema.compile(schema_value)!
local records: mut {Json.Value} = {}
for i = 1, 1000 do
  local record: Json.Value = { id = i, name = "user" .. tostring(i), score = i / 7, active = i % 2 == 0,
    tags = Json.array({ "a", "b", "c" }) }
  records[#records + 1] = record
end
case("jsonschema.compile", function(n: integer)
  for _ = 1, n do local _ = JsonSchema.compile(schema_value)! end
end)
case("jsonschema.check 1000 records", function(n: integer)
  for _ = 1, n do
    for _, record in ipairs(records) do
      local ok, why = schema:check(record)
      if not ok then error(tostring(why)) end
    end
  end
end)

-- Keys and tokens: P-256 and Ed25519 sign and verify of a JWT.
local p256 = Key.generate("p256")
local ed = Key.generate("ed25519")
local claims: {string: Json.Value} = { iss = "https://id.example.com", sub = "ada", aud = "my-app",
  exp = Clock.now_ns() // 1000000000 + 3600 }
local p256_token = Jose.sign(p256, claims, { typ = "JWT", kid = "k" })
local ed_token = Jose.sign(ed, claims, { typ = "JWT", kid = "k" })
local p256_keys = Jose.keys({ keys = Json.array({ Jose.jwk(p256.public, "k") }) })!
local ed_keys = Jose.keys({ keys = Json.array({ Jose.jwk(ed.public, "k") }) })!
local jwt: Jose.JwtOptions = { issuer = "https://id.example.com", audience = "my-app" }
case("key.generate p256", function(n: integer)
  for _ = 1, n do local _ = Key.generate("p256") end
end)
case("key.generate ed25519", function(n: integer)
  for _ = 1, n do local _ = Key.generate("ed25519") end
end)
case("jose.sign p256", function(n: integer)
  for _ = 1, n do local _ = Jose.sign(p256, claims) end
end)
case("jose.sign ed25519", function(n: integer)
  for _ = 1, n do local _ = Jose.sign(ed, claims) end
end)
case("jose.verify_jwt p256", function(n: integer)
  for _ = 1, n do local _ = Jose.verify_jwt(p256_token, p256_keys, jwt)! end
end)
case("jose.verify_jwt ed25519", function(n: integer)
  for _ = 1, n do local _ = Jose.verify_jwt(ed_token, ed_keys, jwt)! end
end)

-- QR: a URL encoded to a code, then to an SVG and to text.
local url = "https://example.com/a/path?with=a&query=string&and=more-than-a-few-characters"
local code = Qr.encode(url)!
case("qr.encode url", function(n: integer)
  for _ = 1, n do local _ = Qr.encode(url)! end
end)
case("qr.svg url", function(n: integer)
  for _ = 1, n do local _ = Qr.svg(code) end
end)
case("qr.text url", function(n: integer)
  for _ = 1, n do local _ = Qr.text(code) end
end)

-- Property lists: 1000 dicts of three entries, written and read as binary and as XML.
local entries: mut {Plist.Value} = {}
for i = 1, 1000 do
  local item = Plist.dict({ { key = "id", value = Plist.integer(i) }, { key = "name", value = Plist.string("user" .. tostring(i)) },
    { key = "score", value = Plist.real(i / 7) } })
  entries[#entries + 1] = item
end
local plist_value = Plist.array(entries)
local plist_binary = Plist.encode(plist_value, { form = "binary" })!
local plist_xml = Plist.encode(plist_value, { form = "xml" })!
case("plist.encode binary 1000 dicts", function(n: integer)
  for _ = 1, n do local _ = Plist.encode(plist_value, { form = "binary" })! end
end, { bytes = #plist_binary })
case("plist.decode binary 1000 dicts", function(n: integer)
  for _ = 1, n do local _ = Plist.decode(plist_binary)! end
end, { bytes = #plist_binary })
case("plist.encode xml 1000 dicts", function(n: integer)
  for _ = 1, n do local _ = Plist.encode(plist_value, { form = "xml" })! end
end, { bytes = #plist_xml })
case("plist.decode xml 1000 dicts", function(n: integer)
  for _ = 1, n do local _ = Plist.decode(plist_xml)! end
end, { bytes = #plist_xml })

-- Time: RFC 3339 and HTTP dates, parsed and written, and civil fields in a named zone.
local now = Clock.now_ns()
local zone = Time.zone("America/Los_Angeles")!
local stamp = Time.format_rfc3339(now)
local http = Time.format_http(now)
case("time.format_rfc3339", function(n: integer)
  for _ = 1, n do local _ = Time.format_rfc3339(now) end
end)
case("time.parse_rfc3339", function(n: integer)
  for _ = 1, n do local _ = Time.parse_rfc3339(stamp)! end
end)
case("time.format_http", function(n: integer)
  for _ = 1, n do local _ = Time.format_http(now) end
end)
case("time.parse_http", function(n: integer)
  for _ = 1, n do local _ = Time.parse_http(http)! end
end)
case("time.civil in zone", function(n: integer)
  for _ = 1, n do local _ = Time.civil(now, zone) end
end)

-- DNS: a query encoded and a reply decoded.
local query = Dns.query("example.com", 1, 7)
local wire = Dns.encode(query)!
case("dns.encode query", function(n: integer)
  for _ = 1, n do local _ = Dns.encode(query)! end
end)
case("dns.decode reply", function(n: integer)
  for _ = 1, n do local _ = Dns.decode(wire)! end
end)

-- The built binary: how long a process takes from its start to its exit, for an empty program and for one that
-- loads the JSON module. `--against` compares two binaries on these, as each child runs its own.
local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
local exe = Proc.executable()!
local function start(snippet: string): function(n: integer)
  return function(n: integer)
    for _ = 1, n do
      local result = assert(Child.run({ exe, "-e", snippet }, { stdout = "capture", stderr = "capture",
        timeout_ns = Clock.seconds(60) }))
      assert(result.code == 0, "exit code " .. tostring(result.code))
    end
  end
end
case("startup empty program", start("local _ = 1"))
case("startup requires cosmic.json", start('local _ = require("cosmic.json")'))
case("startup requires cosmic.http", start('local _ = require("cosmic.http")'))

return function(argv: {string}): integer return bench.main(argv) end
