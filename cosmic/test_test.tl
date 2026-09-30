--- [`cosmic.test`]'s `Needs`, in this process: each field is one `fields`
--- names. cosmic/test_tool_test.tl holds `needs` as it runs, which a
--- script run by this program shows.

local Test = require("cosmic.test")

--- Each field `Needs` has is one `fields` names, taking what the type
--- does, so the checks the build and `needs` make keep to the type.
local function test_every_field_of_needs_is_one_fields_names()
  local every: Test.Needs = {
    reads = {}, host = {}, env = {}, network = {}, tool = true,
    nests = true, store = true, system = true, caches = {},
  }
  local want: {string:string} = {
    reads = "list", host = "list", env = "list", network = "list",
    tool = "flag", nests = "flag", store = "flag", system = "flag",
    caches = "list",
  }
  local count = 0
  for name in pairs(every as {string:any}) do
    count = count + 1
    assert(Test.fields[name] == want[name], name)
  end
  for _ in pairs(Test.fields) do count = count - 1 end
  assert(count == 0, "fields names one Needs does not have")
end

--- A test reaches loopback alone (R1), and loopback is 127/8, written
--- as a request names it (R2): a strict dotted quad `127.a.b.c` may be
--- declared; `::1`, `localhost`, any other name or address, and any
--- other spelling of one of 127/8 are refused, naming the rule.
local function test_network_takes_loopback_addresses_alone()
  for _, host in ipairs({ "127.0.0.1", "127.0.0.2", "127.255.255.255", "127.1.20.0" }) do
    assert(Test.network_trouble(host) == "", host)
  end
  for _, host in ipairs({ "*", "0.0.0.0", "128.0.0.1", "10.0.0.1", "127.1", "127.0.1",
    "1270.0.0.1", "127.0.0.256", "127.0.0.1000", "127.0.0.01", "127.00.0.1", "0127.0.0.1",
    "127.0.0.1:8080", "127.0.0.0/8", "127.0.0.1.", " 127.0.0.1", "127.0.0.1 ", "::", "::1",
    "::ffff:127.0.0.1", "[::1]", "[::1]:80", "0:0:0:0:0:0:0:1", "localhost", "LOCALHOST",
    "localhost.", "localhost:80", "a.localhost", "example.com", "no-host-here", "" }) do
    local refused = Test.network_trouble(host)
    assert(refused:find(string.format("network %q: network takes loopback addresses " ..
      "127.a.b.c only", host), 1, true) ~= nil, host .. ": " .. refused)
  end
  assert(Test.any_host_refusal:find("^network = true: network takes loopback addresses"))
end

--- `skip` takes a reason: none, or an empty one, raises before the test
--- is counted skipped, so this test, which passes, is not.
local function test_skip_takes_a_reason()
  for _, reason in ipairs({ "", 1, false, nil } as {any}) do
    local ok, trouble: boolean, any = pcall(Test.skip as function(any), reason)
    assert(not ok and tostring(trouble):find("skip takes a reason", 1, true), tostring(trouble))
  end
  local ok, trouble: boolean, any = pcall(Test.skip as function(any), nil)
  assert(not ok and tostring(trouble):find("skip takes a reason", 1, true), tostring(trouble))
end
