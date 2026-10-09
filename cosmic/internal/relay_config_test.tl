--- What [`Child.start`] and the relay's process agree on
--- (cosmic/internal/relay_config.tl): the proxy environment a program is given, the
--- variables a policy with `connect` may not set, the host's own addresses
--- read from Linux's tables, and the config the relay is handed. These are
--- pure: the live relay is in cosmic/child_relay_test.tl.

local Json = require("cosmic.json")
local RelayConfig = require("cosmic.internal.relay_config")

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

--- A relay on the host's loopback serves both protocols at one port, and
--- each variable carries its token as the password of the user "cosmic".
local function test_a_relay_on_the_hosts_loopback_is_named_with_its_port_and_token()
  local token = string.rep("ab", 32)
  local env = RelayConfig.proxy_env({}, 49152, token)
  for _, name in ipairs({ "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy" }) do
    assert(env[name] == "http://cosmic:" .. token .. "@127.0.0.1:49152", name .. " is " .. tostring(env[name]))
  end
  for _, name in ipairs({ "ALL_PROXY", "all_proxy" }) do
    assert(env[name] == "socks5h://cosmic:" .. token .. "@127.0.0.1:49152", name .. " is " .. tostring(env[name]))
  end
  assert(env.NO_PROXY == "localhost,127.0.0.1,::1" and env.NODE_USE_ENV_PROXY == "1")
end

local function test_a_policys_loopback_addresses_are_direct_too_each_once()
  local env = RelayConfig.proxy_env({ "127.0.0.1", "127.0.0.2", "127.0.0.9", "127.0.0.2" })
  assert(env.NO_PROXY == "localhost,127.0.0.1,::1,127.0.0.2,127.0.0.9", env.NO_PROXY)
  assert(env.no_proxy == env.NO_PROXY)
end

--- A loopback address a `connect` target names is the host's service, which
--- a client must send to the relay: it leaves `NO_PROXY`, by its bytes
--- whatever its spelling or port. `localhost` leaves with 127.0.0.1 only: a
--- granted ::1 is not the sandbox's own 127.0.0.1 that `localhost` names.
local function test_a_granted_loopback_address_is_not_direct()
  local function skipped(connect: {string}, loopback?: {string}): string
    return RelayConfig.proxy_env(loopback or {}, nil, nil, connect).NO_PROXY
  end
  assert(skipped({ "127.0.0.1:8080" }) == "::1", skipped({ "127.0.0.1:8080" }))
  assert(skipped({ "127.0.0.1:*" }) == "::1")
  assert(skipped({ "[::1]:8080" }) == "localhost,127.0.0.1", skipped({ "[::1]:8080" }))
  assert(skipped({ "[0:0:0:0:0:0:0:1]:80" }) == "localhost,127.0.0.1", "a spelling of ::1 is ::1")
  assert(skipped({ "[::ffff:127.0.0.1]:80" }) == "::1", "an IPv4-mapped address is the IPv4 address")
  assert(skipped({ "127.0.0.1:1", "[::1]:2" }) == "", skipped({ "127.0.0.1:1", "[::1]:2" }))
  -- Another 127.x host is not in the default list, and stays direct where the policy declares it.
  assert(skipped({ "127.0.0.2:80" }) == "localhost,127.0.0.1,::1")
  assert(skipped({ "127.0.0.2:80" }, { "127.0.0.9" }) == "localhost,127.0.0.1,::1,127.0.0.9")
  assert(skipped({ "api.example.com:443", "10.0.0.1:80", "*:443" }) == "localhost,127.0.0.1,::1",
    "a name, another address and \"*\" leave it as it was")
  assert(RelayConfig.naming({ "127.0.0.1:80", "[::1]:*" }, "::1") == "[::1]:*")
  assert(RelayConfig.naming({ "127.0.0.1:80" }, "127.0.0.2") == "")
end

--- Without a connect target at a loopback address the environment is what
--- it was.
local function test_a_policy_without_a_loopback_grant_has_the_same_environment()
  local plain = RelayConfig.proxy_env({ "127.0.0.2" })
  local given = RelayConfig.proxy_env({ "127.0.0.2" }, nil, nil, { "api.example.com:443", "192.0.2.1:80" })
  for name, value in pairs(plain) do assert(given[name] == value, name) end
  assert(plain.NO_PROXY == "localhost,127.0.0.1,::1,127.0.0.2")
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

local function test_an_upstream_is_read_from_the_environment()
  local up = assert(RelayConfig.upstream({
    https_proxy = "http://user:p%40ss@Proxy.Example:3128/", no_proxy = "localhost, .internal.test,10.0.0.1,*.corp.test:8443",
  }))
  assert(up.host == "proxy.example" and up.port == 3128)
  assert(up.authorization == "Basic dXNlcjpwQHNz", up.authorization)
  assert(table.concat(up.no_proxy, "|") == "localhost|.internal.test|10.0.0.1|*.corp.test:8443")
  local bare = assert(RelayConfig.upstream({ HTTPS_PROXY = "proxy.example", NO_PROXY = "*" }))
  assert(bare.host == "proxy.example" and bare.port == 80 and bare.authorization == nil and bare.no_proxy[1] == "*")
  local v6 = assert(RelayConfig.upstream({ https_proxy = "http://[::1]:8080" }))
  assert(v6.host == "::1" and v6.port == 8080)
  assert(RelayConfig.upstream({}) == nil and RelayConfig.upstream({ https_proxy = "" }) == nil)
  for _, bad in ipairs({ "https://proxy.example:443", "socks5://proxy.example:1080", "http://:80", "http://host:0",
      "http://host:99999", "http://host:x" }) do
    local none, why = RelayConfig.upstream({ https_proxy = bad })
    assert(none == nil and why:find("https_proxy", 1, true), bad .. ": " .. tostring(why))
  end
  -- The credentials are never in the reason, whichever way the value is wrong.
  for _, value in ipairs({ "http://user:secret@host:0", "https://user:secret@host:443", "socks5://user:secret@host:1080",
      "user:secret@host:0", "http://user:secret@:80", "http://u:p@secret@host:x", "http://u:pa/secret@host:x",
      "socks5://u:p@secret@host", "socks5://u:pa/secret@host", "http://u:pa/secret@host:x/path", "u:p@secret@host:x" }) do
    local _, why = RelayConfig.upstream({ https_proxy = value })
    assert(why ~= "" and not why:find("secret", 1, true), value .. ": " .. why)
  end
end

local function test_the_config_travels_as_one_line_and_reads_back()
  local text = RelayConfig.encode({ grants = { "api.example.com:443", "127.0.0.2:8080" },
    upstream = { host = "proxy", port = 3128, authorization = "Basic dXNlcjpwYXNz", no_proxy = { ".corp" },
      addresses = { "10.0.0.9", "::1" } },
    own_addresses = { "10.1.0.2" }, log = "stderr" })
  assert(not text:find("\n", 1, true), "one line")
  local read = assert(RelayConfig.decode(text))
  assert(table.concat(read.grants, ",") == "api.example.com:443,127.0.0.2:8080")
  local up = read.upstream
  assert(up.host == "proxy" and up.port == 3128 and up.authorization == "Basic dXNlcjpwYXNz" and
      table.concat(up.no_proxy, ",") == ".corp" and table.concat(up.addresses, ",") == "10.0.0.9,::1")
  assert(table.concat(read.own_addresses, ",") == "10.1.0.2" and read.log == "stderr")
  local bare = assert(RelayConfig.decode(RelayConfig.encode({ grants = { "a.test:1" },
    own_addresses = {}, log = "null" })))
  assert(bare.upstream == nil and #bare.own_addresses == 0 and bare.log == "null")
  assert(bare.public == false and bare.table == nil and bare.name_servers == nil, "nothing is handed")
  local handed = assert(RelayConfig.decode(RelayConfig.encode({ grants = { "a.test:1" }, own_addresses = {},
    log = "null", public = true, table = { { host = "127.0.0.1", port = 0 } },
    name_servers = { { host = "127.0.0.1", port = 53 } }, name_server_wait_ns = 2500000000,
    upstream = { host = "p.test", port = 80, no_proxy = {}, addresses = { "127.0.0.1" } } })))
  assert(handed.public == true and handed.table[1].port == 0 and handed.name_servers[1].port == 53 and
      handed.name_server_wait_ns == 2500000000 and handed.upstream.addresses[1] == "127.0.0.1" and
      handed.upstream.authorization == nil)
  assert(handed.direct == false and handed.token == nil, "Linux's relay is handed its listeners")
  local direct = assert(RelayConfig.decode(RelayConfig.encode({ grants = { "a.test:1" }, own_addresses = {},
    log = "null", direct = true, token = "0123456789abcdef0123" })))
  assert(direct.direct == true and direct.token == "0123456789abcdef0123")
  assert(RelayConfig.name_server_fd == 4 and RelayConfig.connector_fd == 5,
    "the name servers' connector, then the one that reaches the rest")
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
  local head = '{"grants":["a"],"own_addresses":[],"log":"null","upstream":'
  local ok = '"host":"p.test","port":80,"no_proxy":[],"addresses":["10.0.0.9"]'
  assert(RelayConfig.decode(head .. "{" .. ok .. "}}") ~= nil, "the fixture's record is whole")
  says(head .. "3}", "upstream is not an object")
  says(head .. '{"port":80,"no_proxy":[],"addresses":["10.0.0.9"]}}', "upstream.host")
  says(head .. '{"host":"p.test","port":0,"no_proxy":[],"addresses":["10.0.0.9"]}}', "upstream.port")
  says(head .. '{"host":"p.test","port":80,"authorization":"a\\nb","no_proxy":[],"addresses":["10.0.0.9"]}}',
    "upstream.authorization")
  says(head .. '{"host":"p.test","port":80,"authorization":5,"no_proxy":[],"addresses":["10.0.0.9"]}}',
    "upstream.authorization")
  says(head .. '{"host":"p.test","port":80,"addresses":["10.0.0.9"]}}', "upstream.no_proxy is not a list")
  says(head .. '{"host":"p.test","port":80,"no_proxy":[1],"addresses":["10.0.0.9"]}}', "upstream.no_proxy[1]")
  says(head .. '{"host":"p.test","port":80,"no_proxy":[]}}', "upstream.addresses is not given")
  says(head .. '{"host":"p.test","port":80,"no_proxy":[],"addresses":[]}}', "holds no address")
  says(head .. '{"host":"p.test","port":80,"no_proxy":[],"addresses":["p.test"]}}', "upstream.addresses[1]")
  says('{"grants":["a"],"own_addresses":[],"log":"null","public":4}', "public is not a boolean")
  says('{"grants":["a"],"own_addresses":[],"log":"null","direct":"yes"}', "direct is not a boolean")
  says('{"grants":["a"],"own_addresses":[],"log":"null","token":7}', "token is not a string")
  assert(Json.decode_object('{"grants":[]}') ~= nil, "the fixtures are JSON")
end
