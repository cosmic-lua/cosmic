--- The native connector's public classifier at the edge of every prefix
--- the relay refuses, asked through the real, confined connector with
--- port 0 (the decision alone: no socket is made, no host is reached) and
--- held to what [`relay_address.check`] says of the same address. The
--- vectors are written out here, not computed from the list under test.
local type raw_process = require("cosmic.internal.process")
local type _ = require("cosmic.child")
local type _net = require("cosmic.net")
local Test = require("cosmic.test")
local relay_address = require("cosmic.relay_address")
local sys = require("cosmic.sys")
local DENIED <const> = 65536 -- a refusal by the lists, past any errno
Test.policy{ promises = { "fork" } }
local type Searcher = function(string): any, any
local function process_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: a loader's extra is the raw table
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then return extra as raw_process end -- cast: core/process.h's table
  end
  error("no raw table")
end
local process = process_table()

local function require_native_connector()
  local result, why, number = process.connector_probe({ host = "127.0.0.1", port = 9 }, "pointer")
  if result == nil and (number == sys.ENOSYS or number == sys.EOPNOTSUPP) then
    Test.skip("this host has no native connector confinement: " .. why)
  end
  assert(result == sys.EPERM, "native connector setup failed: " .. (why or ""))
end

local OWN <const>: {string} = { "8.8.4.4", "2606:4700::6810:84e5" }

--- A public connector over the relay's own list and `OWN`, whose decision
--- `decide` reads for an address.
local function start(): {integer}, integer
  local pair = assert(process.connector_pair())
  local child, why = process.connector_start({}, pair[2], 500, { deny = relay_address.deny_cidrs(), own = OWN })
  assert(sys.close(pair[2]))
  assert(child, why)
  return pair, child
end

local function decide(fd: integer, address: string): boolean
  local bytes = assert(relay_address.parse(address))
  assert(sys.write(fd, string.pack(">I4I4I4", 0xffffffff, 0, #bytes == 4 and 4 or 6) ..
      string.char(table.unpack(bytes)) .. string.rep("\0", 16 - #bytes)) == 28)
  local got = ""
  while #got < 4 do
    local more = assert(sys.read(fd, 4 - #got))
    assert(more ~= "", "the connector ended before it replied")
    got = got .. more
  end
  local errno = string.unpack(">I4", got)
  assert(errno == 0 or errno == DENIED, address .. ": errno " .. errno)
  return errno == 0
end

--- One refused prefix and its edges: `first` and `last` are in it;
--- `below` and `above` are the neighbours, allowed where `*_ok`.
local record Edge
  cidr: string
  first: string
  last: string
  below: string
  below_ok: boolean
  above: string
  above_ok: boolean
end

local function edge(cidr: string, first: string, last: string, below?: string, below_ok?: boolean,
                    above?: string, above_ok?: boolean): Edge
  return { cidr = cidr, first = first, last = last, below = below, below_ok = below_ok or false,
    above = above, above_ok = above_ok or false }
end

local EDGES <const>: {Edge} = {
  edge("169.254.169.254/32", "169.254.169.254", "169.254.169.254", "169.254.169.253", false, "169.254.169.255", false),
  edge("100.100.100.200/32", "100.100.100.200", "100.100.100.200", "100.100.100.199", false, "100.100.100.201", false),
  edge("168.63.129.16/32", "168.63.129.16", "168.63.129.16", "168.63.129.15", true, "168.63.129.17", true),
  edge("fd00:ec2::254/128", "fd00:ec2::254", "fd00:ec2::254"),
  edge("0.0.0.0/8", "0.0.0.0", "0.255.255.255", nil, nil, "1.0.0.0", true),
  edge("192.0.0.0/24", "192.0.0.0", "192.0.0.255", "191.255.255.255", true, "192.0.1.0", true),
  edge("192.88.99.0/24", "192.88.99.0", "192.88.99.255", "192.88.98.255", true, "192.88.100.0", true),
  edge("10.0.0.0/8", "10.0.0.0", "10.255.255.255", "9.255.255.255", true, "11.0.0.0", true),
  edge("100.64.0.0/10", "100.64.0.0", "100.127.255.255", "100.63.255.255", true, "100.128.0.0", true),
  edge("127.0.0.0/8", "127.0.0.0", "127.255.255.255", "126.255.255.255", true, "128.0.0.0", true),
  edge("169.254.0.0/16", "169.254.0.0", "169.254.255.255", "169.253.255.255", true, "169.255.0.0", true),
  edge("172.16.0.0/12", "172.16.0.0", "172.31.255.255", "172.15.255.255", true, "172.32.0.0", true),
  edge("192.168.0.0/16", "192.168.0.0", "192.168.255.255", "192.167.255.255", true, "192.169.0.0", true),
  edge("192.0.2.0/24", "192.0.2.0", "192.0.2.255", "192.0.1.255", true, "192.0.3.0", true),
  edge("198.18.0.0/15", "198.18.0.0", "198.19.255.255", "198.17.255.255", true, "198.20.0.0", true),
  edge("198.51.100.0/24", "198.51.100.0", "198.51.100.255", "198.51.99.255", true, "198.51.101.0", true),
  edge("203.0.113.0/24", "203.0.113.0", "203.0.113.255", "203.0.112.255", true, "203.0.114.0", true),
  edge("224.0.0.0/4", "224.0.0.0", "239.255.255.255", "223.255.255.255", true, "240.0.0.0", false),
  edge("255.255.255.255/32", "255.255.255.255", "255.255.255.255", "255.255.255.254", false),
  edge("240.0.0.0/4", "240.0.0.0", "255.255.255.255", "239.255.255.255", false),
  -- The IPv6 prefixes outside 2000::/3 are refused as it is, and their edges as well.
  edge("::/128", "::", "::"),
  edge("::1/128", "::1", "::1"),
  edge("::/96", "::", "::ffff:ffff"),
  edge("::ffff:0:0/96", "::ffff:0:0", "::ffff:ffff:ffff"),
  edge("0:0:0:0:ffff:0::/96", "::ffff:0:0:0", "::ffff:0:ffff:ffff"),
  edge("64:ff9b::/96", "64:ff9b::", "64:ff9b::ffff:ffff"),
  edge("64:ff9b:1::/48", "64:ff9b:1::", "64:ff9b:1:ffff:ffff:ffff:ffff:ffff"),
  edge("fe80::/10", "fe80::", "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "fe7f:ffff:ffff:ffff:ffff:ffff:ffff:ffff", false,
    "fec0::", false),
  edge("fec0::/10", "fec0::", "feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff", false,
    "ff00::", false),
  edge("fc00::/7", "fc00::", "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "fbff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", false,
    "fe00::", false),
  edge("ff00::/8", "ff00::", "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", false),
  edge("100::/64", "100::", "100::ffff:ffff:ffff:ffff", "ff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", false, "100:0:0:1::", false),
  edge("5f00::/16", "5f00::", "5f00:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "5eff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", false,
    "5f01::", false),
  -- Inside 2000::/3: the neighbours are allowed unless another prefix holds them.
  edge("2002::/16", "2002::", "2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "2001:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true,
    "2003::", true),
  edge("2001::/32", "2001::", "2001:0:ffff:ffff:ffff:ffff:ffff:ffff", "2000:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true,
    "2001:1::", false),
  edge("2001:db8::/32", "2001:db8::", "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff", "2001:db7:ffff:ffff:ffff:ffff:ffff:ffff", true,
    "2001:db9::", true),
  edge("3fff::/20", "3fff::", "3fff:fff:ffff:ffff:ffff:ffff:ffff:ffff", "3ffe:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true,
    "3fff:1000::", true),
  edge("2001:2::/48", "2001:2::", "2001:2:0:ffff:ffff:ffff:ffff:ffff", "2001:1:ffff:ffff:ffff:ffff:ffff:ffff", false,
    "2001:2:1::", false),
  edge("2001::/23", "2001::", "2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff", "2000:ffff:ffff:ffff:ffff:ffff:ffff:ffff", true,
    "2001:200::", true),
}

--- Asserts that both the connector and the relay's own check say `allowed`
--- of `address`.
local function expect(fd: integer, address: string, allowed: boolean, what: string)
  assert(decide(fd, address) == allowed, what .. " " .. address .. ": the connector should " ..
      (allowed and "allow" or "refuse") .. " it")
  local own = relay_address.own_addresses(OWN)
  local ok = relay_address.check(address, 443, {}, own)
  assert(ok == allowed, what .. " " .. address .. ": the relay's check disagrees")
end

local function test_every_refused_prefix_is_refused_at_both_ends_and_its_neighbours_follow_their_own_prefix()
  require_native_connector()
  local pair, child = start()
  local named: {string: boolean} = {}
  for _, row in ipairs(EDGES) do
    named[row.cidr] = true
    expect(pair[1], row.first, false, row.cidr .. " first")
    expect(pair[1], row.last, false, row.cidr .. " last")
    if row.below ~= nil then expect(pair[1], row.below, row.below_ok, row.cidr .. " below") end
    if row.above ~= nil then expect(pair[1], row.above, row.above_ok, row.cidr .. " above") end
  end
  -- A prefix added to the list is a prefix added here.
  for _, cidr in ipairs(relay_address.deny_cidrs()) do
    assert(named[cidr], cidr .. " has no boundary vectors")
  end
  assert(sys.close(pair[1]))
  assert(assert(process.waitpid(child, false)).code == 0)
end

local function test_ipv6_is_allowed_only_inside_2000_slash_3_and_the_forms_that_carry_ipv4_are_never_decoded()
  require_native_connector()
  local pair, child = start()
  for _, address in ipairs({ "2000::", "2000::1", "2606:4700:4700::1111", "2a00:1450:4001:81b::200e",
      "3fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "2003::", "3ffe::" }) do
    expect(pair[1], address, true, "global unicast")
  end
  for _, address in ipairs({ "::", "1fff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "4000::", "8000::", "a000::",
      "e000::", "1::", "100:0:0:1::", "::ffff:8.8.8.8", "::ffff:0808:0808", "::ffff:10.0.0.1", "::ffff:127.0.0.1",
      "64:ff9b::808:808", "64:ff9b::8.8.8.8", "64:ff9b:1:808:0:0:a9fe:a9fe", "::8.8.8.8", "::808:808",
      "::ffff:0:808:808", "2002:808:808::", "2001:0:808:808::" }) do
    expect(pair[1], address, false, "outside what is allowed")
  end
  -- An IPv4-mapped spelling of an own address is the IPv4 address it carries, for the IPv4 form.
  expect(pair[1], "8.8.4.4", false, "own")
  expect(pair[1], "8.8.4.5", true, "next to an own address")
  expect(pair[1], "2606:4700::6810:84e5", false, "own")
  expect(pair[1], "2606:4700::6810:84e6", true, "next to an own address")
  assert(sys.close(pair[1]))
  assert(assert(process.waitpid(child, false)).code == 0)
end

--- `bytes` with bit `at` (1 is the most significant) flipped.
local function flipped(bytes: {integer}, at: integer): {integer}
  local copy: {integer} = { table.unpack(bytes) }
  local index = (at - 1) // 8 + 1
  copy[index] = copy[index] ~ (1 << (7 - (at - 1) % 8))
  return copy
end

local function spelled(bytes: {integer}): string
  if #bytes == 4 then return table.concat(bytes, ".") end
  local groups: {string} = {}
  for i = 1, 16, 2 do groups[#groups + 1] = ("%x"):format(bytes[i] * 256 + bytes[i + 1]) end
  return table.concat(groups, ":")
end

local function test_a_prefix_of_any_length_holds_exactly_the_addresses_that_share_its_bits()
  require_native_connector()
  for _, base in ipairs({ "93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946" }) do
    local bytes = assert(relay_address.parse(base))
    local width = #bytes * 8
    for bits = 0, width do
      local pair = assert(process.connector_pair())
      local child, why = process.connector_start({}, pair[2], 500, { deny = { base .. "/" .. bits } })
      assert(sys.close(pair[2]))
      assert(child, why)
      assert(not decide(pair[1], base), base .. "/" .. bits .. " does not hold its own address")
      for _, at in ipairs({ 1, 3, 4, bits - 1, bits, bits + 1, bits + 2, width }) do
        if at >= 1 and at <= width then
          -- Flipping bit `at` leaves the first at - 1 bits, so the prefix holds the
          -- result exactly when it is no longer than that. IPv6 outside 2000::/3 is
          -- refused whatever the prefix says: the first three bits of this one are 001.
          local held = bits < at
          local outside = #bytes == 16 and at <= 3
          local other = spelled(flipped(bytes, at))
          assert(decide(pair[1], other) == not (held or outside),
            base .. "/" .. bits .. " with bit " .. at .. " flipped: " .. other)
        end
      end
      assert(sys.close(pair[1]))
      assert(assert(process.waitpid(child, false)).code == 0)
    end
  end
end
