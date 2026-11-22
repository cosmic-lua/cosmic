--- [`cosmic.tls`] without a socket: what a leaf says of itself, what a
--- load takes and refuses, and how [`Tls.Certs.keep`] renews and
--- retries. The fixtures are testdata/tls's; its README says how they
--- were made.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Tls = require("cosmic.tls")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "testdata/tls", letters = "r" } } }

--- The fixture `name` of testdata/tls.
local function fixture(name: string): string
  return (assert(Fs.read("testdata/tls/" .. name)))
end

local function test_a_leaf_names_its_hosts_and_its_dates()
  local leaf = assert(Tls.leaf(fixture("a.pem")))
  assert(#leaf.names == 2 and leaf.names[1] == "localhost" and leaf.names[2] == "*.a.test",
    table.concat(leaf.names, ","))
  assert(leaf.not_before_ns == 1767225600 * 1000000000, tostring(leaf.not_before_ns))
  assert(leaf.not_after_ns == 4922899200 * 1000000000, tostring(leaf.not_after_ns))
  -- An IP address among the names is no DNS name.
  local b = assert(Tls.leaf(fixture("b.pem")))
  assert(#b.names == 1 and b.names[1] == "b.test")
  local none, why = Tls.leaf("not a certificate")
  assert(none == nil and why:find("^tls: the certificate: ") ~= nil, why)
end

local function test_a_load_serves_the_pairs_and_says_when_they_renew()
  local certs = Tls.certs(Tls.static({
    { cert = fixture("a.pem"), key = fixture("a.key") },
    { cert = fixture("b.pem"), key = fixture("b.key") },
  }), { alpn = { "http/1.1" } })
  assert(certs:config() == nil and certs:renews_at() == nil and #certs:leaves() == 0)
  assert(certs:load())
  assert(certs:config() ~= nil and #certs:leaves() == 2)
  -- A third of the hundred years before the end.
  local life = (4922899200 - 1767225600) * 1000000000
  assert(certs:renews_at() == 4922899200 * 1000000000 - life // 3, tostring(certs:renews_at()))
end

local function test_a_load_refuses_what_cannot_be_served_and_keeps_what_it_had()
  local a: Tls.Pair = { cert = fixture("a.pem"), key = fixture("a.key") }
  local given: {Tls.Pair} = { a }
  local certs = Tls.certs(function(_?: integer): {Tls.Pair}?, string return given, "" end)
  assert(certs:load())
  local served = certs:config()
  local cases: {{string: {Tls.Pair}}} = {
    { ["no pair"] = {} },
    { ["is not the certificate's"] = { { cert = fixture("a.pem"), key = fixture("b.key") } } },
    { ["pair 1's key"] = { { cert = fixture("a.pem"), key = "not a key" } } },
    { ["tls: pair 2: tls: the certificate"] = { a, { cert = "not a certificate", key = fixture("a.key") } } },
    { ["has expired"] = { { cert = fixture("c.pem"), key = fixture("a.key") } } },
    { ["is not valid yet"] = { { cert = fixture("e.pem"), key = fixture("a.key") } } },
  }
  for _, case in ipairs(cases) do
    for want, pairs_given in pairs(case) do
      given = pairs_given
      local ok, why = certs:load()
      assert(not ok and why:find(want, 1, true) ~= nil, want .. ": " .. why)
      assert(certs:config() == served, want .. ": the pairs before are served still")
    end
  end
  local raising = Tls.certs(function(_?: integer): {Tls.Pair}?, string error("no daemon") end)
  local ok, why = raising:load()
  assert(not ok and why:find("^tls: the source raised: .*no daemon") ~= nil, why)
end

local function test_certs_refuses_options_out_of_range()
  local source = Tls.static({})
  Test.raises(function() Tls.certs(source, { alpn = { "" } }) end, "1 to 255 bytes")
  Test.raises(function()
    Tls.certs(source, { alpn = { "a", "b", "c", "d", "e", "f", "g", "h", "i" } })
  end, "at most 8")
  Test.raises(function() Tls.certs(source, { retry_ns = 0 }) end, "retry_ns")
  local ok, why = Tls.certs(source):load()
  assert(not ok and why == "tls: static holds no pair", why)
end

--- `keep` loads at once where nothing is loaded, retries a failure
--- after `retry_ns`, doubling it, reports each, and ends once
--- `stopping` says so.
local function test_keep_loads_retries_and_stops()
  local a: Tls.Pair = { cert = fixture("a.pem"), key = fixture("a.key") }
  local calls = 0
  local asked: mut {integer} = {}
  local certs = Tls.certs(function(min_validity_ns?: integer): {Tls.Pair}?, string
    calls = calls + 1
    asked[#asked + 1] = min_validity_ns or -1
    if calls <= 2 then return nil, "not yet " .. tostring(calls) end
    return { a }, ""
  end, { retry_ns = Clock.ms(1) })
  local reports: mut {string} = {}
  local started = Clock.monotonic_ns()
  Poll.run(function()
    local keeper = Poll.spawn(function()
      certs:keep(function(trouble: string) reports[#reports + 1] = trouble end,
        function(): boolean return certs:config() ~= nil end)
    end)
    assert(keeper:join(Clock.seconds(10)), "keep ends once stopping says so")
  end)
  assert(calls == 3 and certs:config() ~= nil, tostring(calls))
  assert(#reports == 2 and reports[1] == "not yet 1" and reports[2] == "not yet 2", table.concat(reports, "; "))
  -- Nothing was loaded before, so nothing bounds the first asks.
  assert(asked[1] == -1 and asked[3] == -1)
  -- One millisecond, then two.
  assert(Clock.monotonic_ns() - started >= Clock.ms(3))
end

--- A renewal asks for leaves valid for half the life of those held, and
--- `keep` ends where its wait is cancelled.
local function test_a_renewal_asks_for_half_the_life_and_a_cancel_ends_keep()
  local a: Tls.Pair = { cert = fixture("a.pem"), key = fixture("a.key") }
  local asked: mut {integer} = {}
  local certs = Tls.certs(function(min_validity_ns?: integer): {Tls.Pair}?, string
    asked[#asked + 1] = min_validity_ns or -1
    return { a }, ""
  end)
  assert(certs:load())
  -- Due now: as though a third of the life were left.
  certs.due_ns = 0
  local reports: mut {string} = {}
  Poll.run(function()
    local keeper = Poll.spawn(function()
      certs:keep(function(trouble: string) reports[#reports + 1] = trouble end, function(): boolean
        return false
      end)
    end)
    -- The renewal happens before the first wait; the next is years away.
    local _, _ = Poll.delay(Clock.ms(10))
    keeper:cancel()
    assert(keeper:join(Clock.seconds(10)), "a cancelled wait ends keep")
  end)
  local life = (4922899200 - 1767225600) * 1000000000
  assert(#asked == 2 and asked[2] == life // 2, tostring(asked[2]))
  assert(#reports == 0, table.concat(reports, "; "))
end

--- A configuration no session holds is freed by the collector, and the
--- pairs loaded after it are served.
local function test_a_replaced_configuration_is_collected()
  local certs = Tls.certs(Tls.static({ { cert = fixture("a.pem"), key = fixture("a.key") } }))
  assert(certs:load())
  local before = collectgarbage("count")
  for _ = 1, 20 do assert(certs:load()) end
  collectgarbage("collect")
  collectgarbage("collect")
  -- Twenty configurations held would be more than this.
  assert(collectgarbage("count") - before < 64, "the replaced configurations were collected")
  assert(certs:config() ~= nil)
end
