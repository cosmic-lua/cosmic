local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Test = require("cosmic.test")

--- c-ares opens a socket to a server only when a name is not in the
--- hosts file or a literal, which these tests never leave to it.
Test.policy{ loopback = { "127.0.0.1" } }

--- The addresses `found` holds, one "family address" each, sorted.
local function listed(found: {Net.Resolved}): {string}
  local lines: {string} = {}
  for _, resolved in ipairs(found) do
    lines[#lines + 1] = resolved.family .. " " .. resolved.address
  end
  table.sort(lines)
  return lines
end

local function test_a_hosts_file_answers_every_address_of_both_families(tmp: string)
  local hosts = tmp .. "/hosts"
  assert(Fs.write(hosts, table.concat({
    "192.0.2.1 multi.example.test",
    "2001:db8::1 multi.example.test",
    "192.0.2.2 multi.example.test",
    "2001:db8::2 multi.example.test",
    "198.51.100.7 single.example.test",
    "",
  }, "\n")))
  local found, why = Net.resolve("multi.example.test", { hosts_file = hosts })
  assert(found ~= nil and why == "", why)
  assert(table.concat(listed(found), ",") ==
      "ipv4 192.0.2.1,ipv4 192.0.2.2,ipv6 2001:db8::1,ipv6 2001:db8::2")
  local only = assert(Net.resolve("single.example.test", { hosts_file = hosts }))
  assert(#only == 1 and only[1].address == "198.51.100.7" and only[1].family == "ipv4")
end

local function test_a_numeric_literal_answers_itself_without_a_query()
  -- The only server is a port nothing listens at, so a query would fail.
  local opts: Net.ResolveOptions = { servers = { Net.udp("127.0.0.1", 9) }, timeout_ns = 1 }
  for _, case in ipairs({
      { "127.0.0.1", "ipv4" }, { "255.255.255.255", "ipv4" }, { "::1", "ipv6" },
      { "2001:db8::1", "ipv6" }, { "::ffff:192.0.2.1", "ipv6" },
  }) do
    local found, why = Net.resolve(case[1], opts)
    assert(found ~= nil and why == "", case[1] .. ": " .. why)
    assert(#found == 1 and found[1].address == case[1] and found[1].family == case[2], case[1])
  end
  -- Written back as inet_ntop writes it.
  assert(assert(Net.resolve("2001:0db8:0:0:0:0:0:1", opts))[1].address == "2001:db8::1")
end

local function test_a_name_the_resolver_cannot_take_fails_and_a_degenerate_argument_raises(tmp: string)
  for _, name in ipairs({ "", "a\0b.example", "fe80::1%lo", string.rep("a", 255) }) do
    local found, why = Net.resolve(name, { timeout_ns = 1 })
    assert(found == nil and why == "Invalid argument", string.format("%q: %s", name, tostring(why)))
  end
  local found, why = Net.resolve("example.test", { servers = { Net.udp("127.0.0.1,8.8.8.8", 53) } })
  assert(found == nil and why == "Invalid argument", why)
  found, why = Net.resolve("example.test", { servers = { Net.udp("localhost", 53) } })
  assert(found == nil and why == "Invalid argument", why)
  found, why = Net.resolve("example.test", { hosts_file = tmp .. "/x\0y" })
  assert(found == nil and why == "Invalid argument", why)
  local number: any = 7
  local text: any = "x"
  assert(not pcall(Net.resolve, number as string))
  assert(not pcall(Net.resolve, "example.test", text as Net.ResolveOptions))
  assert(not pcall(Net.resolve, "example.test", { timeout_ns = -1 }))
  assert(not pcall(Net.resolve, "example.test", { timeout_ns = 0.5 } as Net.ResolveOptions))
  assert(not pcall(Net.resolve, "example.test", { hosts_file = number } as Net.ResolveOptions))
  assert(not pcall(Net.resolve, "example.test", { servers = text } as Net.ResolveOptions))
  assert(not pcall(Net.resolve, "example.test", { servers = {} }))
  assert(not pcall(Net.resolve, "example.test", { servers = { Net.tcp("127.0.0.1", 53) } }))
end
