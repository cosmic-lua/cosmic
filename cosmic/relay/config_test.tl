--- What [`Child.start`] and the relay's process agree on
--- (cosmic/relay/config.tl): the proxy environment a program is given, the
--- variables a policy with `connect` may not set, the host's own addresses
--- read from Linux's tables, and the config the relay is handed. These are
--- pure: the live relay is in cosmic/child_relay_test.tl.

local Json = require("cosmic.json")
local RelayConfig = require("cosmic.relay.config")

local function test_the_environment_points_every_proxy_client_at_the_relay()
  local env = RelayConfig.proxy_env({})
  for _, name in ipairs({ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy" }) do
    assert(env[name] == "http://127.0.0.1:3128", name .. " is " .. tostring(env[name]))
  end
  for _, name in ipairs({ "ALL_PROXY", "all_proxy" }) do
    assert(env[name] == "socks5h://127.0.0.1:1080", name .. " is " .. tostring(env[name]))
  end
  assert(env.NODE_USE_ENV_PROXY == "1")
  assert(env.NO_PROXY == "localhost,127.0.0.1,::1" and env.no_proxy == env.NO_PROXY,
    "the sandbox's own network is direct: " .. tostring(env.NO_PROXY))
  assert(RelayConfig.http_port == 3128 and RelayConfig.socks_port == 1080)
end

local function test_a_policys_loopback_addresses_are_direct_too_each_once()
  local env = RelayConfig.proxy_env({ "127.0.0.1", "127.0.0.2", "127.0.0.9", "127.0.0.2" })
  assert(env.NO_PROXY == "localhost,127.0.0.1,::1,127.0.0.2,127.0.0.9", env.NO_PROXY)
  assert(env.no_proxy == env.NO_PROXY)
end

local function test_a_variable_the_relay_sets_is_reserved_by_name()
  for _, name in ipairs({ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY",
      "all_proxy", "NO_PROXY", "no_proxy", "NODE_USE_ENV_PROXY" }) do
    assert(RelayConfig.reserved({ "HOME", name }) == name, name .. " is not reserved")
  end
  assert(RelayConfig.reserved({}) == "" and RelayConfig.reserved({ "HOME", "PATH", "Https_Proxy" }) == "",
    "any other name is free")
end

--- What Linux's /proc/net/fib_trie holds of a host with a loopback and an
--- address on one interface, as the kernel writes it.
local FIB_TRIE <const> = [[
Main:
  +-- 0.0.0.0/0 3 0 5
     |-- 0.0.0.0
        /0 universe UNICAST
     +-- 10.1.0.0/16 2 0 2
        +-- 10.1.0.0/30 2 0 1
           |-- 10.1.0.0
              /32 link BROADCAST
              /16 link UNICAST
           |-- 10.1.0.2
              /32 host LOCAL
        |-- 10.1.255.255
           /32 link BROADCAST
     +-- 127.0.0.0/8 2 0 2
        +-- 127.0.0.0/31 1 0 0
           |-- 127.0.0.0
              /32 link BROADCAST
              /8 host LOCAL
           |-- 127.0.0.1
              /32 host LOCAL
        |-- 127.255.255.255
           /32 link BROADCAST
Local:
  +-- 0.0.0.0/0 3 0 5
     +-- 10.1.0.0/16 2 0 2
        +-- 10.1.0.0/30 2 0 1
           |-- 10.1.0.2
              /32 host LOCAL
     +-- 127.0.0.0/8 2 0 2
        +-- 127.0.0.0/31 1 0 0
           |-- 127.0.0.1
              /32 host LOCAL
]]

--- And of /proc/net/if_inet6: the address, the interface's index, its
--- prefix length, scope and flags, and its name.
local IF_INET6 <const> = [[
00000000000000000000000000000001 01 80 10 80       lo
fe80000000000000a00027fffe4e66a1 02 40 20 80     eth0
20010db8000000000000000000000abc 02 40 00 80     eth0
]]

local function test_the_hosts_addresses_are_the_local_host_entries_of_the_tables()
  local found = RelayConfig.parse_addresses(FIB_TRIE, IF_INET6)
  local seen: {string:boolean} = {}
  for _, address in ipairs(found) do
    assert(not seen[address], address .. " is listed twice")
    seen[address] = true
  end
  assert(#found == 5, table.concat(found, " "))
  for _, wanted in ipairs({ "10.1.0.2", "127.0.0.1", "0000:0000:0000:0000:0000:0000:0000:0001",
      "fe80:0000:0000:0000:a000:27ff:fe4e:66a1", "2001:0db8:0000:0000:0000:0000:0000:0abc" }) do
    assert(seen[wanted], wanted .. " is missing from " .. table.concat(found, " "))
  end
  assert(not seen["10.1.0.0"] and not seen["127.0.0.0"] and not seen["127.255.255.255"],
    "broadcast and network entries are no address of the host")
end

local function test_text_that_is_neither_table_names_no_address()
  assert(#RelayConfig.parse_addresses("", "") == 0)
  assert(#RelayConfig.parse_addresses("garbage\n  /32 host LOCAL\n", "short 01\nzz\n") == 0,
    "a LOCAL line with no address before it, and a short row, are passed over")
end

local function test_the_config_travels_as_one_line_and_reads_back()
  local text = RelayConfig.encode({ grants = { "api.example.com:443", "127.0.0.2:8080" },
    https_proxy = "http://user:pass@proxy:3128", no_proxy = ".corp", own_addresses = { "10.1.0.2" },
    log = "stderr" })
  assert(not text:find("\n", 1, true), "one line")
  local read = assert(RelayConfig.decode(text))
  assert(table.concat(read.grants, ",") == "api.example.com:443,127.0.0.2:8080")
  assert(read.https_proxy == "http://user:pass@proxy:3128" and read.no_proxy == ".corp")
  assert(table.concat(read.own_addresses, ",") == "10.1.0.2" and read.log == "stderr")
  local bare = assert(RelayConfig.decode(RelayConfig.encode({ grants = { "a.test:1" },
    own_addresses = {}, log = "null" })))
  assert(bare.https_proxy == nil and bare.no_proxy == nil and #bare.own_addresses == 0 and bare.log == "null")
  assert(bare.public == false and bare.table == nil and bare.name_servers == nil, "nothing is handed")
  local handed = assert(RelayConfig.decode(RelayConfig.encode({ grants = { "a.test:1" }, own_addresses = {},
    log = "null", public = true, table = { { host = "127.0.0.1", port = 0 } },
    name_servers = { { host = "127.0.0.1", port = 53 } }, name_server_wait_ns = 2500000000,
    upstream_addresses = { "127.0.0.1" } })))
  assert(handed.public == true and handed.table[1].port == 0 and handed.name_servers[1].port == 53 and
      handed.name_server_wait_ns == 2500000000 and handed.upstream_addresses[1] == "127.0.0.1")
  assert(RelayConfig.name_server_fd == 4 and RelayConfig.table_fd == 5 and RelayConfig.public_fd == 6,
    "the name servers' connector, then the table's, then the public one")
end

local function test_a_config_that_is_none_is_refused_naming_why()
  local function says(text: string, expected: string)
    local config, why = RelayConfig.decode(text)
    assert(config == nil and why:find(expected, 1, true), text .. ": " .. tostring(why))
  end
  says("not json", "")
  says("[]", "")
  says('{"own_addresses":[],"log":"null"}', "grants is not a list")
  says('{"grants":["a"],"log":"null"}', "own_addresses is not a list")
  says('{"grants":[1],"own_addresses":[],"log":"null"}', "grants[1] is not a string")
  says('{"grants":["a"],"own_addresses":[],"log":"loud"}', "log is not")
  says('{"grants":["a"],"own_addresses":[],"log":"null","https_proxy":3}', "https_proxy is not a string")
  says('{"grants":["a"],"own_addresses":[],"log":"null","no_proxy":{}}', "no_proxy is not a string")
  says('{"grants":["a"],"own_addresses":[],"log":"null","public":4}', "public is not a boolean")
  assert(Json.decode_object('{"grants":[]}') ~= nil, "the fixtures are JSON")
end
