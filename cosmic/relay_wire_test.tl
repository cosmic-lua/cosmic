local Clock = require("cosmic.clock")
local Fixture = require("build.relay_wire_fixture")
local Wire = require("cosmic.relay_wire")

local function connect_head(input: string): Wire.Connect
  return Wire.connect_reader():feed(input)
end

local function socks_greeting(input: string, password?: boolean): Wire.SocksGreeting
  return Wire.socks_greeting_reader(password):feed(input)
end

local function socks_auth(input: string): Wire.SocksAuth
  return Wire.socks_auth_reader():feed(input)
end

local function socks_request(input: string): Wire.SocksRequest
  return Wire.socks_request_reader():feed(input)
end

local function client_hello(input: string): Wire.Hello
  return Wire.hello_reader():feed(input)
end

--- ClientHellos captured from clients that connected to a loopback
--- listener that read the first record and closed: OpenSSL 3 with
--- `-servername api.github.com`, the same with `-noservername`, curl to
--- example.org and Python's ssl with `server_hostname` Python.Example.COM.
local OPENSSL_SNI <const> = Fixture.bytes(
  "1603010137010001330303077edd7980ae030c29b2cb4fc55d7222659cbcf22693fb40c7298e0d3455acda2067430af6" ..
    "04816e5dced29c6546b7a2219214af8fbd569b5dad99d452c8b785fa003e130213031301c02cc030009fcca9cca8ccaa" ..
    "c02bc02f009ec024c028006bc023c0270067c00ac0140039c009c0130033009d009c003d003c0035002f00ff010000ac" ..
    "00000013001100000e6170692e6769746875622e636f6d000b000403000102000a00160014001d0017001e0019001801" ..
    "000101010201030104002300000016000000170000000d002a0028040305030603080708080809080a080b0804080508" ..
    "06040105010601030303010302040205020602002b00050403040303002d00020101003300260024001d0020bddf2c83" ..
    "ab387520e47ad89592a85ad7dd685899cb147ddeb1120a3656367555"
)

local OPENSSL_NO_SNI <const> = Fixture.bytes(
  "16030101200100011c0303ee9426408c3ef3fd91c384384c8f535b4e4e9e09207385925d74ca6802119fbb20e754182d" ..
    "30024d3497b2cf717d117ca3dd612a105e0c4f3db64bc3bac4639737003e130213031301c02cc030009fcca9cca8ccaa" ..
    "c02bc02f009ec024c028006bc023c0270067c00ac0140039c009c0130033009d009c003d003c0035002f00ff01000095" ..
    "000b000403000102000a00160014001d0017001e0019001801000101010201030104002300000016000000170000000d" ..
    "002a0028040305030603080708080809080a080b080408050806040105010601030303010302040205020602002b0005" ..
    "0403040303002d00020101003300260024001d0020a1291f0a99a7357da132d03529b62df4039cfaf5a26d4b7b75b067" ..
    "7b95a3390f"
)

local CURL <const> = Fixture.bytes(
  "1603010200010001fc0303d700340caa073d97067f70cbad5a7548ad87a5177eee51911cea72374a034ad8205213a1a7" ..
    "864084324843932b7daf661ff43aa34c1cb17b714d793abd7eed6885003e130213031301c02cc030009fcca9cca8ccaa" ..
    "c02bc02f009ec024c028006bc023c0270067c00ac0140039c009c0130033009d009c003d003c0035002f00ff01000175" ..
    "00000010000e00000b6578616d706c652e6f7267000b000403000102000a00160014001d0017001e0019001801000101" ..
    "0102010301040010000e000c02683208687474702f312e31001600000017000000310000000d002a0028040305030603" ..
    "080708080809080a080b080408050806040105010601030303010302040205020602002b00050403040303002d000201" ..
    "01003300260024001d0020ea5ec3ba042aec67083a2ec9ce716f5e370ad6b41b917ba7f782b4ce0a086f50001500b600" ..
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" ..
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" ..
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" ..
    "00000000000000000000000000000000000000000000000000000000000000000000000000"
)

local PYTHON <const> = Fixture.bytes(
  "1603010200010001fc03030372d40805c7e17c804cc617e26e4dedd3be329991a553be423b5a89b939636420dfbbdaba" ..
    "c77e53032330d4720d1ff3a2efa928fe3eca003eb93cd28591fb70bf0024130213031301c02cc030c02bc02fcca9cca8" ..
    "c024c028c023c027009f009e006b006700ff0100018f000000170015000012507974686f6e2e4578616d706c652e434f" ..
    "4d000b000403000102000a00160014001d0017001e001900180100010101020103010400230000001600000017000000" ..
    "0d002a0028040305030603080708080809080a080b080408050806040105010601030303010302040205020602002b00" ..
    "050403040303002d00020101003300260024001d0020e3d06d0b42c196bce103ca9282ab703fbb535f1722f2ab93ec5b" ..
    "e4cc3d79fd71001500db0000000000000000000000000000000000000000000000000000000000000000000000000000" ..
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" ..
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" ..
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" ..
    "00000000000000000000000000000000000000000000000000000000000000000000000000"
)

--- The status and every field [`connect_head`] answers, as one line, so
--- that two answers compare and a failure shows both.
local function shown_connect(r: Wire.Connect): string
  return ("%s consumed=%d http=%s host=%s kind=%s port=%s auth=%s reason=%s"):format(r.status, r.consumed,
    tostring(r.http_status), tostring(r.host), tostring(r.kind), tostring(r.port), tostring(r.authorization),
    tostring(r.reason))
end

--- Whether [`connect_head`] reads every prefix of `input` as more, or as the
--- whole's refusal, and the prefix of the head's own length as the whole.
--- Whether a reader's answer to each prefix of `input` agrees with its
--- answer to the whole: undecided before the whole decides, then the same.
local function prefix_agrees(whole: Wire.Connect, wanted: string, cut: integer, part: Wire.Connect): boolean
  if whole.status == "done" and cut < whole.consumed then
    return part.status == "more"
  elseif whole.status == "done" and cut == whole.consumed then
    return shown_connect(part) == wanted
  elseif whole.status == "refused" then
    return part.status == "more" or shown_connect(part) == wanted
  end
  return true
end

local function connect_splits_agree(input: string)
  local whole = connect_head(input)
  assert(whole.status ~= "more", "the whole is undecided: " .. shown_connect(whole))
  local wanted = shown_connect(whole)
  -- One reader fed a byte at a time answers every prefix in linear work; a
  -- fresh reader per prefix is checked on a sample and near the end, since
  -- one for every prefix of a 16 KiB head is quadratic and timed out. Each
  -- message is built only on a failure, for the same reason.
  local reader = Wire.connect_reader()
  for cut = 0, #input do
    local part = cut == 0 and connect_head("") or reader:feed(input:sub(cut, cut))
    if not prefix_agrees(whole, wanted, cut, part) then
      assert(false, ("fed to %d of %q: %s"):format(cut, input, shown_connect(part)))
    end
    if cut % 97 == 0 or cut + 8 >= #input or math.abs(cut - whole.consumed) <= 8 then
      local fresh = connect_head(input:sub(1, cut))
      if not prefix_agrees(whole, wanted, cut, fresh) then
        assert(false, ("prefix %d of %q: %s"):format(cut, input, shown_connect(fresh)))
      end
    end
  end
end

local function test_connect_reads_each_kind_of_host()
  local cases: {{string}} = {
    { "example.com:443", "example.com", "name", "443" },
    { "EXAMPLE.Com:443", "example.com", "name", "443" },
    { "example.com.:443", "example.com", "name", "443" },
    { "localhost:1", "localhost", "name", "1" },
    { "xn--bcher-kva.example:65535", "xn--bcher-kva.example", "name", "65535" },
    { "a-b.c--d.e:80", "a-b.c--d.e", "name", "80" },
    { "1.2.3.4:80", "1.2.3.4", "ipv4", "80" },
    { "255.255.255.255:80", "255.255.255.255", "ipv4", "80" },
    { "0.0.0.0:80", "0.0.0.0", "ipv4", "80" },
    { "[::1]:8080", "::1", "ipv6", "8080" },
    { "[::]:1", "::", "ipv6", "1" },
    { "[1:2:3:4:5:6:7:8]:9", "1:2:3:4:5:6:7:8", "ipv6", "9" },
    { "[2001:DB8:0:0:0:0:0:1]:443", "2001:db8::1", "ipv6", "443" },
    { "[2001:db8::0:1]:443", "2001:db8::1", "ipv6", "443" },
    { "[2001:0db8:0000:0001:0000:0000:0000:0001]:443", "2001:db8:0:1::1", "ipv6", "443" },
    { "[1:0:2:0:3:0:4:0]:443", "1:0:2:0:3:0:4:0", "ipv6", "443" },
    { "[1::]:443", "1::", "ipv6", "443" },
    { "[::ffff:1.2.3.4]:443", "::ffff:102:304", "ipv6", "443" },
    { "[64:ff9b::7f00:1]:443", "64:ff9b::7f00:1", "ipv6", "443" },
    { "[1:2:3:4:5:6:1.2.3.4]:443", "1:2:3:4:5:6:102:304", "ipv6", "443" },
  }
  for _, case in ipairs(cases) do
    local input = Fixture.connect(case[1])
    local r = connect_head(input)
    assert(r.status == "done", case[1] .. ": " .. shown_connect(r))
    assert(r.host == case[2], case[1] .. " host " .. tostring(r.host))
    assert(tostring(r.kind) == case[3], case[1] .. " kind " .. tostring(r.kind))
    assert(r.port == math.tointeger(tonumber(case[4])), case[1] .. " port")
    assert(r.consumed == #input, case[1] .. " consumed")
    connect_splits_agree(input)
  end
end

local function test_connect_accepts_http_1_0_and_stops_at_the_head()
  local head = Fixture.connect("example.com:443", { "Host: example.com:443", "User-Agent: t" }, "HTTP/1.0")
  local r = connect_head(head .. "\22\3\1tunnel bytes")
  assert(r.status == "done" and r.consumed == #head, shown_connect(r))
  assert(r.authorization == nil)
  connect_splits_agree(head)
end

local function test_connect_keeps_only_proxy_authorization()
  local cases: {{string}} = {
    { "Proxy-Authorization: Basic dTpw", "Basic dTpw" },
    { "proxy-authorization:\t Bearer  tok \t", "Bearer  tok" },
    { "PROXY-AUTHORIZATION:", "" },
  }
  for _, case in ipairs(cases) do
    local input = Fixture.connect("a.example:1", { "Host: x", case[1], "X-Other: \xff\xfe" })
    local r = connect_head(input)
    assert(r.status == "done", case[1] .. ": " .. shown_connect(r))
    assert(r.authorization == case[2], case[1] .. " -> " .. tostring(r.authorization))
    connect_splits_agree(input)
  end
  local twice = connect_head(Fixture.connect("a.example:1", { "Proxy-Authorization: a", "proxy-authorization: b" }))
  assert(twice.status == "refused" and twice.reason:find("repeated Proxy%-Authorization"), shown_connect(twice))
end

local function test_connect_refuses_what_is_not_a_clean_connect()
  local long_label = ("a"):rep(64)
  local cases: {{string}} = {
    { "GET http://example.com/ HTTP/1.1\r\n\r\n", "plain HTTP is not relayed", "405" },
    { "get example.com:80 HTTP/1.1\r\n\r\n", "plain HTTP is not relayed", "405" },
    { "connect example.com:80 HTTP/1.1\r\n\r\n", "plain HTTP is not relayed", "405" },
    { "POST / HTTP/1.1\r\n\r\n", "plain HTTP is not relayed", "405" },
    { "\r\n", "plain HTTP is not relayed", "405" },
    { "CONNECT example.com:80 HTTP/2.0\r\n\r\n", "unsupported HTTP version", "505" },
    { "CONNECT example.com:80 http/1.1\r\n\r\n", "unsupported HTTP version", "505" },
    { "CONNECT example.com:80 HTTP/0.9\r\n\r\n", "unsupported HTTP version", "505" },
    { "CONNECT example.com:80\r\n\r\n", "malformed request line", "400" },
    { "CONNECT  example.com:80 HTTP/1.1\r\n\r\n", "malformed request line", "400" },
    { "CONNECT example.com:80  HTTP/1.1\r\n\r\n", "malformed request line", "400" },
    { "CONNECT example.com:80 HTTP/1.1 \r\n\r\n", "malformed request line", "400" },
    { "CONNECT\texample.com:80 HTTP/1.1\r\n\r\n", "malformed request line", "400" },
    { "CONNECT example.com:80 HTTP/1.1\n\n", "bare LF", "400" },
    { "CONNECT example.com:80 HTTP/1.1\r\nHost: x\n\r\n", "bare LF", "400" },
    { "CONNECT example.com:80 HTTP/1.1\r\rHost: x\r\n\r\n", "carriage return", "400" },
    { "CONNECT example.com:80 HTTP/1.1\r\nHost: x\r\r\n\r\n", "carriage return", "400" },
    { "CONNECT example.com:80 HTTP/1.1\r\nHost: a\0b\r\n\r\n", "control byte 0x00", "400" },
    { "CONNECT example.com:80 HTTP/1.1\r\nHost: a\1b\r\n\r\n", "control byte 0x01", "400" },
    { "CONNECT example.com:80 HTTP/1.1\r\nHost: a\127b\r\n\r\n", "control byte 0x7f", "400" },
    { "CONNECT exam\0ple.com:80 HTTP/1.1\r\n\r\n", "control byte 0x00", "400" },
    { "CONNECT example.com:80 HTTP/1.1\r\nHost: x\r\n y\r\n\r\n", "obsolete header line fold", "400" },
    { "CONNECT example.com:80 HTTP/1.1\r\nHost: x\r\n\ty\r\n\r\n", "obsolete header line fold", "400" },
    { "CONNECT example.com:80 HTTP/1.1\r\nNoColon\r\n\r\n", "without a colon", "400" },
    { "CONNECT example.com:80 HTTP/1.1\r\nHost : x\r\n\r\n", "not a token", "400" },
    { "CONNECT example.com:80 HTTP/1.1\r\n: x\r\n\r\n", "not a token", "400" },
    { "CONNECT example.com:80 HTTP/1.1\r\nA B: x\r\n\r\n", "not a token", "400" },
    { "CONNECT example.com HTTP/1.1\r\n\r\n", "no port", "400" },
    { "CONNECT example.com: HTTP/1.1\r\n\r\n", "port is not a decimal", "400" },
    { "CONNECT :443 HTTP/1.1\r\n\r\n", "empty host name", "400" },
    { "CONNECT example.com:0 HTTP/1.1\r\n\r\n", "port is not a decimal", "400" },
    { "CONNECT example.com:00080 HTTP/1.1\r\n\r\n", "port is not a decimal", "400" },
    { "CONNECT example.com:080 HTTP/1.1\r\n\r\n", "port is not a decimal", "400" },
    { "CONNECT example.com:65536 HTTP/1.1\r\n\r\n", "port is not a decimal", "400" },
    { "CONNECT example.com:123456 HTTP/1.1\r\n\r\n", "port is not a decimal", "400" },
    { "CONNECT example.com:+80 HTTP/1.1\r\n\r\n", "port is not a decimal", "400" },
    { "CONNECT example.com:8a HTTP/1.1\r\n\r\n", "port is not a decimal", "400" },
    { "CONNECT example.com:-1 HTTP/1.1\r\n\r\n", "port is not a decimal", "400" },
    { "CONNECT user@example.com:80 HTTP/1.1\r\n\r\n", "userinfo", "400" },
    { "CONNECT user:pw@example.com:80 HTTP/1.1\r\n\r\n", "userinfo", "400" },
    { "CONNECT http://example.com:80 HTTP/1.1\r\n\r\n", "an IPv6 address needs brackets", "400" },
    { "CONNECT example.com:80/x HTTP/1.1\r\n\r\n", "port is not a decimal", "400" },
    { "CONNECT a_b.example:80 HTTP/1.1\r\n\r\n", "letters, digits and inner hyphens", "400" },
    { "CONNECT -a.example:80 HTTP/1.1\r\n\r\n", "letters, digits and inner hyphens", "400" },
    { "CONNECT a-.example:80 HTTP/1.1\r\n\r\n", "letters, digits and inner hyphens", "400" },
    { "CONNECT a b.example:80 HTTP/1.1\r\n\r\n", "malformed request line", "400" },
    { "CONNECT \xc3\xa9.example:80 HTTP/1.1\r\n\r\n", "letters, digits and inner hyphens", "400" },
    { "CONNECT .example:80 HTTP/1.1\r\n\r\n", "empty label", "400" },
    { "CONNECT a..example:80 HTTP/1.1\r\n\r\n", "empty label", "400" },
    { "CONNECT example..:80 HTTP/1.1\r\n\r\n", "empty label", "400" },
    { "CONNECT .:80 HTTP/1.1\r\n\r\n", "empty host name", "400" },
    { "CONNECT " .. long_label .. ".example:80 HTTP/1.1\r\n\r\n", "label longer than 63", "400" },
    { "CONNECT " .. ("a."):rep(127) .. "bb:80 HTTP/1.1\r\n\r\n", "longer than 253", "400" },
    { "CONNECT 127.1:80 HTTP/1.1\r\n\r\n", "last label is a number", "400" },
    { "CONNECT 2130706433:80 HTTP/1.1\r\n\r\n", "last label is a number", "400" },
    { "CONNECT 0x7f.0.0.1:80 HTTP/1.1\r\n\r\n", "last label is a number", "400" },
    { "CONNECT 0x7f:80 HTTP/1.1\r\n\r\n", "last label is a number", "400" },
    { "CONNECT 0X7F000001:80 HTTP/1.1\r\n\r\n", "last label is a number", "400" },
    { "CONNECT 01.2.3.4:80 HTTP/1.1\r\n\r\n", "last label is a number", "400" },
    { "CONNECT 256.1.1.1:80 HTTP/1.1\r\n\r\n", "last label is a number", "400" },
    { "CONNECT 1.2.3.4.5:80 HTTP/1.1\r\n\r\n", "last label is a number", "400" },
    { "CONNECT 1.2.3.4.:80 HTTP/1.1\r\n\r\n", "last label is a number", "400" },
    { "CONNECT ::1:80 HTTP/1.1\r\n\r\n", "needs brackets", "400" },
    { "CONNECT [::1:80 HTTP/1.1\r\n\r\n", "unclosed [", "400" },
    { "CONNECT [::1]80 HTTP/1.1\r\n\r\n", "no port after the ]", "400" },
    { "CONNECT [::1] HTTP/1.1\r\n\r\n", "no port after the ]", "400" },
    { "CONNECT [::1]:80x HTTP/1.1\r\n\r\n", "port is not a decimal", "400" },
    { "CONNECT [example.com]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [::1%eth0]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [1:2:3:4:5:6:7:8:9]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [1:2:3:4:5:6:7]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [1::2::3]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [:::1]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [:1]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [1:]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [12345::]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [::1.2.3]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [::1.2.3.4:1]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [1:2:3:4:5:6:7::8]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [1:2:3:4:5:6:7:8::]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [::g]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT [1.2.3.4]:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
    { "CONNECT []:80 HTTP/1.1\r\n\r\n", "not an IPv6 address", "400" },
  }
  for _, case in ipairs(cases) do
    local r = connect_head(case[1])
    assert(r.status == "refused", ("%q: %s"):format(case[1], shown_connect(r)))
    assert(r.reason:find(case[2], 1, true), ("%q: reason %q lacks %q"):format(case[1], r.reason, case[2]))
    assert(r.http_status == math.tointeger(tonumber(case[3])), ("%q: status %s"):format(case[1], tostring(r.http_status)))
    assert(r.consumed == 0)
    connect_splits_agree(case[1])
  end
end

local function test_connect_waits_for_what_is_missing()
  local head = Fixture.connect("example.com:443", { "Host: x" })
  assert(connect_head("").status == "more")
  assert(connect_head(head:sub(1, -2)).status == "more")
  assert(connect_head("CONNECT example.com:443 HTTP/1.1\r\n").status == "more")
  assert(connect_head("CONNECT example.com:443 HTTP/1.1\r").status == "more")
  assert(connect_head("CONNECT example.com:443 HTTP/1.1\r\n\r").status == "more")
  assert(connect_head(head).status == "done")
end

--- A request line CONNECT ... HTTP/1.1 padded with a hyphenated tail to
--- exactly `length` bytes before its CRLF, as a line of bytes only the
--- caps judge (the target is not a valid host past 253 bytes).
local function padded_line(length: integer): string
  return "X" .. ("y"):rep(length - 1)
end

local function test_connect_caps_a_line_at_8192_bytes()
  -- A request line: at the cap it is read (and refused for its shape), past it for its length.
  local at_cap = padded_line(8192) .. "\r\n\r\n"
  local r = connect_head(at_cap)
  assert(r.status == "refused" and not r.reason:find("longer than"), shown_connect(r))
  local over = connect_head(padded_line(8193) .. "\r\n\r\n")
  assert(over.status == "refused" and over.http_status == 414 and over.reason:find("request line longer than 8192"),
    shown_connect(over))
  -- A line still being read is refused without waiting for its end.
  local open = connect_head(padded_line(8193))
  assert(open.status == "refused" and open.http_status == 414, shown_connect(open))
  assert(connect_head(padded_line(8192)).status == "more")
  assert(connect_head(padded_line(8192) .. "\r").status == "more")
  -- A header line, in a head whose total stays under its own cap.
  local first = "CONNECT example.com:80 HTTP/1.1\r\n"
  local fits = connect_head(first .. "X: " .. ("v"):rep(8192 - 3) .. "\r\n\r\n")
  assert(fits.status == "done", shown_connect(fits))
  local long = connect_head(first .. "X: " .. ("v"):rep(8192 - 2) .. "\r\n\r\n")
  assert(long.status == "refused" and long.http_status == 431 and long.reason:find("header line longer than 8192"),
    shown_connect(long))
  -- The control byte is found first when it comes first.
  local early = connect_head(first .. "X: \1" .. ("v"):rep(9000))
  assert(early.status == "refused" and early.reason:find("control byte 0x01"), shown_connect(early))
  local late = connect_head(first .. "X: " .. ("v"):rep(9000) .. "\1")
  assert(late.status == "refused" and late.reason:find("header line longer"), shown_connect(late))
end

local function test_connect_caps_the_head_at_16384_bytes()
  local first = "CONNECT example.com:80 HTTP/1.1\r\n"
  -- Lines of 8000 bytes, then a last one that brings the head to `total`.
  local function head_of(total: integer): string
    local body = first
    local filler = "A: " .. ("v"):rep(7000) .. "\r\n"
    while #body + #filler + 2 < total - 1000 do
      body = body .. filler
    end
    local left = total - #body - 2 - 5
    return body .. "B: " .. ("w"):rep(left) .. "\r\n\r\n"
  end
  local exact = head_of(16384)
  assert(#exact == 16384)
  local r = connect_head(exact)
  assert(r.status == "done" and r.consumed == 16384, shown_connect(r))
  local over = head_of(16385)
  assert(#over == 16385)
  local o = connect_head(over)
  assert(o.status == "refused" and o.http_status == 431 and o.reason:find("request head longer than 16384"),
    shown_connect(o))
  -- Without its final CRLF the head at the cap still waits for it.
  assert(connect_head(exact:sub(1, -2)).status == "more")
  assert(connect_head(exact:sub(1, -3)).status == "more")
  -- A CR in the last place the head has cannot be followed by its LF.
  assert(connect_head(exact:sub(1, -3) .. "\r").status == "more")
  -- A CR in the last place the head has waits for the byte that cannot be its LF.
  assert(connect_head(over:sub(1, -3) .. "\r").status == "more")
  assert(connect_head(over:sub(1, -3) .. "\r\n").status == "refused")
  connect_splits_agree(exact)
  connect_splits_agree(over)
end

local function test_connect_cap_refusal_does_not_depend_on_the_feeds()
  -- 16384 bytes of head, none of them a line end, and a control byte as the
  -- 16385th: it is past the cap whether it arrives with the run before it or
  -- alone.
  local first = "CONNECT example.com:80 HTTP/1.1\r\n"
  local lines = first .. "A: " .. ("v"):rep(7000) .. "\r\nB: " .. ("v"):rep(7000) .. "\r\nC: "
  local run = lines .. ("w"):rep(16384 - #lines)
  assert(#run == 16384)
  for _, byte in ipairs({ "\n", "\0", "\r", "\1", "\127" }) do
    local whole = shown_connect(connect_head(run .. byte))
    assert(connect_head(run .. byte).http_status == 431, whole)
    for _, cut in ipairs({ 1, 2, 50, 7000, 16383, 16384 }) do
      local reader = Wire.connect_reader()
      reader:feed((run .. byte):sub(1, cut))
      local split = shown_connect(reader:feed((run .. byte):sub(cut + 1)))
      assert(split == whole, ("%q cut at %d: %s, whole: %s"):format(byte, cut, split, whole))
    end
    -- The byte in the last place the head has is still its own.
    local inside = shown_connect(connect_head(run:sub(1, -2) .. byte))
    assert(not inside:find("431"), inside)
  end
end

local function test_connect_caps_headers_at_100()
  local function with(count: integer): string
    local lines: {string} = {}
    for i = 1, count do
      lines[i] = "H" .. i .. ": v"
    end
    return Fixture.connect("example.com:80", lines)
  end
  local ok = connect_head(with(100))
  assert(ok.status == "done" and ok.consumed == #with(100), shown_connect(ok))
  local over = connect_head(with(101))
  assert(over.status == "refused" and over.http_status == 431 and over.reason:find("more than 100 headers"),
    shown_connect(over))
  connect_splits_agree(with(100))
  connect_splits_agree(with(101))
end

local function test_connect_names_bound_by_their_lengths()
  local label63 = ("a"):rep(63)
  local name253 = label63 .. "." .. label63 .. "." .. label63 .. "." .. ("a"):rep(61)
  assert(#name253 == 253)
  for _, name in ipairs({ label63 .. ".com", name253, name253 .. "." }) do
    local r = connect_head(Fixture.connect(name .. ":80"))
    assert(r.status == "done" and r.host == (name:gsub("%.$", "")), shown_connect(r))
  end
  local r = connect_head(Fixture.connect(name253 .. "a:80"))
  assert(r.status == "refused" and r.reason:find("longer than 253"), shown_connect(r))
end

local function test_connect_reply_forms()
  assert(Wire.connect_ok() == "HTTP/1.1 200 Connection established\r\n\r\n")
  assert(Wire.connect_refusal(403, "not granted: --connect api.github.com:443") ==
      "HTTP/1.1 403 not granted: --connect api.github.com:443\r\nConnection: close\r\nContent-Length: 0\r\n\r\n")
  assert(Wire.connect_refusal(502, "x\r\nSet-Cookie: a\0\xffz"):find("^HTTP/1.1 502 x%?%?Set%-Cookie: a%?%?z\r\n"))
  assert(Wire.connect_refusal(400, "   "):find("^HTTP/1.1 400 Refused\r\n"))
  assert(Wire.connect_refusal(400, ""):find("^HTTP/1.1 400 Refused\r\n"))
  local long = Wire.connect_refusal(400, ("r"):rep(500))
  assert(long:find("^HTTP/1.1 400 r+\r\n") and #long:match("^HTTP/1.1 400 (r+)") == 200)
  assert(Wire.connect_refusal(405, "plain"):find("Allow: CONNECT\r\n", 1, true))
  assert(not Wire.connect_refusal(403, "plain"):find("Allow", 1, true))
  for _, status in ipairs({ 200, 399, 600, 0, -1 }) do
    local ok, why = pcall(Wire.connect_refusal, status, "x")
    assert(not ok and tostring(why):find("status must be an integer from 400 to 599"), tostring(status))
  end
  local ok = pcall(Wire.connect_refusal, 400.5 as integer, "x")
  assert(not ok)
  -- A refusal's text reads back as the program sees it: one status line.
  local reply = Wire.connect_refusal(400, "bad\r\n\r\nHTTP/1.1 200 OK")
  assert(select(2, reply:gsub("\r\n", "")) == 4, reply)
end

local record GreetingCase
  password: boolean
  input: string
  status: string
  method: integer
end

local function test_socks_greeting_picks_the_method()
  local cases: {GreetingCase} = {
    { password = false, input = "\5\1\0", status = "done", method = 0 },
    { password = false, input = "\5\2\2\0", status = "done", method = 0 },
    { password = false, input = "\5\3\1\2\0", status = "done", method = 0 },
    { password = true, input = "\5\2\0\2", status = "done", method = 2 },
    { password = true, input = "\5\1\2", status = "done", method = 2 },
    { password = false, input = "\5\1\2", status = "refused", method = 255 },
    { password = true, input = "\5\1\0", status = "refused", method = 255 },
    { password = false, input = "\5\0", status = "refused", method = 255 },
    { password = false, input = "\4\1\0", status = "refused" },
    { password = false, input = "\5\1\255", status = "refused", method = 255 },
  }
  for _, case in ipairs(cases) do
    local input = case.input
    local r = socks_greeting(input, case.password)
    assert(tostring(r.status) == case.status, ("%q: %s %s"):format(input, r.status, tostring(r.reason)))
    assert(r.method == case.method, ("%q: method %s"):format(input, tostring(r.method)))
    if r.status == "done" then
      assert(r.consumed == #input)
    end
    for cut = 0, #input - 1 do
      local part = socks_greeting(input:sub(1, cut), case.password)
      assert(part.status == "more" or (r.status == "refused" and part.reason == r.reason), ("%q at %d"):format(input, cut))
    end
  end
  assert(socks_greeting("\5\1\0\5\1\0\0").consumed == 3)
  assert(socks_greeting("").status == "more")
  assert(socks_greeting("\5").status == "more")
  assert(socks_greeting("\5\3\0").status == "more")
  assert(socks_greeting("\4\1\0").reason:find("version 4 is not supported"))
  assert(Wire.socks_method_reply(0) == "\5\0")
  assert(Wire.socks_method_reply(2) == "\5\2")
  assert(Wire.socks_method_reply(255) == "\5\255")
  assert(not pcall(Wire.socks_method_reply, 256))
  assert(not pcall(Wire.socks_method_reply, -1))
end

local function test_socks_username_password()
  local r = socks_auth("\1\4user\6secret" .. "tunnel")
  assert(r.status == "done" and r.consumed == 13 and r.username == "user" and r.password == "secret")
  local full = "\1\4user\6secret"
  for cut = 0, #full - 1 do
    assert(socks_auth(full:sub(1, cut)).status == "more", cut)
  end
  local bounds = "\1\255" .. ("u"):rep(255) .. "\255" .. ("p"):rep(255)
  local b = socks_auth(bounds)
  assert(b.status == "done" and #b.username == 255 and #b.password == 255 and b.consumed == #bounds)
  assert(socks_auth("\2\1u\1p").status == "refused")
  assert(socks_auth("\1\0").reason == "empty username")
  assert(socks_auth("\1\1u\0").reason == "empty password")
  assert(socks_auth("\1\1\0\1p").status == "done" and socks_auth("\1\1\0\1p").username == "\0")
  assert(Wire.socks_auth_reply(true) == "\1\0")
  assert(Wire.socks_auth_reply(false) == "\1\1")
end

local function test_socks_request_reads_each_address_type()
  local be = Fixture.be
  local cases: {{string, string, string, integer}} = {
    { Fixture.socks_request(1, 3, "\11example.com", 443), "example.com", "name", 443 },
    { Fixture.socks_request(1, 3, "\11Example.COM", 80), "example.com", "name", 80 },
    { Fixture.socks_request(1, 3, "\12example.com.", 1), "example.com", "name", 1 },
    { Fixture.socks_request(1, 1, "\127\0\0\1", 65535), "127.0.0.1", "ipv4", 65535 },
    { Fixture.socks_request(1, 4, ("\0"):rep(15) .. "\1", 22), "::1", "ipv6", 22 },
    { Fixture.socks_request(1, 4, ("\0"):rep(16), 22), "::", "ipv6", 22 },
    { Fixture.socks_request(1, 4, "\32\1\13\184" .. ("\0"):rep(11) .. "\1", 22), "2001:db8::1", "ipv6", 22 },
    { Fixture.socks_request(1, 4, be(0, 10) .. "\255\255\1\2\3\4", 22), "::ffff:102:304", "ipv6", 22 },
  }
  for _, case in ipairs(cases) do
    local input = case[1]
    local r = socks_request(input .. "tunnel")
    assert(r.status == "done", ("%q: %s %s"):format(input, r.status, tostring(r.reason)))
    assert(r.host == case[2] and tostring(r.kind) == case[3] and r.port == case[4], ("%q: %s %s %s"):format(input, r.host, r.kind, r.port))
    assert(r.consumed == #input)
    for cut = 0, #input - 1 do
      assert(socks_request(input:sub(1, cut)).status == "more", ("%q at %d"):format(input, cut))
    end
  end
end

local function test_socks_request_refusals_name_their_reply()
  local name = "\11example.com"
  local cases: {{string, string, string}} = {
    { "\4\1\0\1\1\2\3\4\0\80", "failure", "version 4" },
    { Fixture.socks_request(2, 1, "\1\2\3\4", 80), "command_not_supported", "command 2" },
    { Fixture.socks_request(3, 1, "\1\2\3\4", 80), "command_not_supported", "command 3" },
    { Fixture.socks_request(0, 1, "\1\2\3\4", 80), "command_not_supported", "command 0" },
    { Fixture.socks_request(255, 1, "\1\2\3\4", 80), "command_not_supported", "command 255" },
    { "\5\1\1\1\1\2\3\4\0\80", "failure", "reserved byte" },
    { Fixture.socks_request(1, 0, "\1\2\3\4", 80), "address_type_not_supported", "address type 0" },
    { Fixture.socks_request(1, 2, "\1\2\3\4", 80), "address_type_not_supported", "address type 2" },
    { Fixture.socks_request(1, 5, "\1\2\3\4", 80), "address_type_not_supported", "address type 5" },
    { Fixture.socks_request(1, 1, "\1\2\3\4", 0), "failure", "port 0" },
    { Fixture.socks_request(1, 3, name, 0), "failure", "port 0" },
    { Fixture.socks_request(1, 3, "\0", 80), "failure", "empty domain" },
    { Fixture.socks_request(1, 3, "\13exam_ple.com", 80), "failure", "letters, digits and inner hyphens" },
    { (Fixture.socks_request(1, 3, "\11example.com", 80):gsub("example", "exam\0le")), "failure", "letters, digits and inner hyphens" },
    { Fixture.socks_request(1, 3, "\x09127.0.0.1", 80), "failure", "last label is a number" },
    { Fixture.socks_request(1, 3, "\1.", 80), "failure", "empty host name" },
    { Fixture.socks_request(1, 3, "\7a..b.cd", 80), "failure", "empty label" },
    { Fixture.socks_request(1, 3, "\64" .. ("a"):rep(64), 80), "failure", "label longer than 63" },
    { Fixture.socks_request(1, 3, "\255" .. ("a"):rep(255), 80), "failure", "longer than 253" },
  }
  for _, case in ipairs(cases) do
    local input = case[1]
    local r = socks_request(input)
    assert(r.status == "refused", ("%q: %s"):format(input, r.status))
    assert(tostring(r.reply) == case[2], ("%q: reply %s"):format(input, tostring(r.reply)))
    assert(r.reason:find(case[3], 1, true), ("%q: reason %q"):format(input, r.reason))
    assert(r.consumed == 0)
    for cut = 0, #input do
      local part = socks_request(input:sub(1, cut))
      assert(part.status == "more" or (part.reason == r.reason and part.reply == r.reply), ("%q at %d"):format(input, cut))
    end
  end
  local max = socks_request(Fixture.socks_request(1, 3, "\253" .. ("a"):rep(61) .. ".a." .. ("b"):rep(63) .. "." .. ("c"):rep(63) .. "." .. ("d"):rep(61) .. ".e", 80))
  assert(max.status == "refused" or max.status == "done")
end

local function test_socks_replies_carry_their_codes()
  local codes: {{string, integer}} = {
    { "succeeded", 0 }, { "failure", 1 }, { "not_allowed", 2 }, { "network_unreachable", 3 },
    { "host_unreachable", 4 }, { "refused", 5 }, { "ttl_expired", 6 },
    { "command_not_supported", 7 }, { "address_type_not_supported", 8 },
  }
  for _, case in ipairs(codes) do
    local reply = Wire.socks_reply(case[1] as Wire.SocksReply)
    assert(reply == "\5" .. string.char(case[2]) .. "\0\1\0\0\0\0\0\0", case[1])
    assert(#reply == 10)
  end
  assert(not pcall(Wire.socks_reply, "bogus" as Wire.SocksReply))
end

local function sni_of(input: string): string
  local r = client_hello(input)
  return r.status == "name" and r.name or r.status
end

--- Every prefix of `input` is more, and the whole is `want` consumed.
local function hello_splits_agree(input: string, want: string)
  local whole = client_hello(input)
  assert(tostring(whole.status) == want, ("whole: %s %s"):format(whole.status, tostring(whole.reason)))
  assert(whole.consumed <= #input)
  for cut = 0, #input - 1 do
    local part = client_hello(input:sub(1, cut))
    if whole.status == "name" or whole.status == "no_sni" then
      if cut < whole.consumed then
        assert(part.status == "more", ("prefix %d: %s %s"):format(cut, part.status, tostring(part.reason)))
      end
    else
      assert(part.status == "more" or (part.status == whole.status and part.reason == whole.reason), ("prefix %d: %s"):format(cut, part.status))
    end
  end
end

local function test_client_hello_reads_captured_hellos()
  local cases: {{string, string, string}} = {
    { OPENSSL_SNI, "name", "api.github.com" },
    { OPENSSL_NO_SNI, "no_sni", "" },
    { CURL, "name", "example.org" },
    { PYTHON, "name", "python.example.com" },
  }
  for _, case in ipairs(cases) do
    local input, status, name = case[1], case[2], case[3]
    local r = client_hello(input)
    assert(tostring(r.status) == status, ("%s %s"):format(r.status, tostring(r.reason)))
    assert(r.consumed == #input)
    assert((r.name or "") == name)
    hello_splits_agree(input, status)
    local extra = client_hello(input .. "\23\3\3\0\1x")
    assert(tostring(extra.status) == status and extra.consumed == #input)
  end
end

local function test_client_hello_spans_records()
  local message = Fixture.hello({ name = "Split.Example.com", session = 32 })
  local whole = Fixture.records(message)
  assert(sni_of(whole) == "split.example.com")
  hello_splits_agree(whole, "name")
  for first = 1, #message - 1 do
    local split = Fixture.records(message, { first })
    local r = client_hello(split)
    assert(r.status == "name" and r.name == "split.example.com" and r.consumed == #split, ("split at %d"):format(first))
  end
  local three = Fixture.records(message, { 3, 50 })
  hello_splits_agree(three, "name")
  -- Records of the sizes a stack that fragments the hello writes.
  hello_splits_agree(Fixture.records(message, { 1, 1, 1, 1 }), "name")
  -- The record that ends the hello is the last consumed, with what follows it left.
  local trailing = Fixture.records(message, { 10 }) .. "\23\3\3\0\1x"
  assert(client_hello(trailing).consumed == #trailing - 6)
  -- A second message in the hello's last record is refused: nothing follows a ClientHello there.
  local two = client_hello(Fixture.records(message .. "\2\0\0\0"))
  assert(two.status == "malformed" and two.reason:find("bytes after the ClientHello"), two.status)
  local split_two = client_hello(Fixture.records(message .. "x", { #message - 3 }))
  assert(split_two.status == "malformed", split_two.status)
  -- Versions the legacy field takes.
  for _, version in ipairs({ 0x0300, 0x0301, 0x0302, 0x0303, 0x0304 }) do
    assert(sni_of(Fixture.records(message, nil, version)) == "split.example.com", version)
  end
end

local function test_client_hello_caps_records_and_size()
  local message = Fixture.hello({ name = "caps.example", size = 200 })
  assert(#message > 64)
  local sizes63: {integer} = {}
  for i = 1, 63 do
    sizes63[i] = 1
  end
  assert(sni_of(Fixture.records(message, sizes63)) == "caps.example")
  local sizes65: {integer} = {}
  for i = 1, 64 do
    sizes65[i] = 1
  end
  local r = client_hello(Fixture.records(message, sizes65))
  assert(r.status == "malformed" and r.reason:find("more than 64 records"), r.status .. tostring(r.reason))
  -- The hello at 16384 bytes of message body is read; one more is not.
  local exact = Fixture.hello({ name = "caps.example", size = 16384 })
  assert(#exact == 16388)
  local sizes: {integer} = { 16384 }
  assert(sni_of(Fixture.records(exact, sizes)) == "caps.example")
  assert(sni_of(Fixture.records(exact, { 1000 })) == "caps.example")
  local over = Fixture.hello({ name = "caps.example", size = 16385 })
  local o = client_hello(Fixture.records(over, sizes))
  assert(o.status == "malformed" and o.reason:find("16385 bytes"), o.status .. tostring(o.reason))
  -- A hello is judged only with its whole record.
  local early = client_hello(Fixture.records(over, sizes):sub(1, 12))
  assert(early.status == "more", early.status)
  -- A record of 16384 bytes is the most, and 16385 is refused on its header.
  assert(client_hello("\22\3\1\64\0").status == "more")
  assert(client_hello("\22\3\1\64\1").status == "malformed")
  assert(client_hello("\22\3\1\0\0").status == "malformed")
end

local function test_client_hello_says_what_is_not_tls()
  local cases: {string} = {
    "GET / HTTP/1.1\r\n",
    "CONNECT a.example:443 HTTP/1.1\r\n",
    "SSH-2.0-OpenSSH_9.6\r\n",
    "\0\0\0\0",
    "\128\46\1\3\1\0\21\0\0\0\16",
    "\23\3\3\0\5hello",
    "\21\3\3\0\2\2\40",
  }
  for _, input in ipairs(cases) do
    local r = client_hello(input)
    assert(r.status == "not_tls", ("%q: %s"):format(input, r.status))
    assert(r.reason ~= nil and r.reason ~= "")
    assert(r.consumed == 0)
    for cut = 0, #input do
      local part = client_hello(input:sub(1, cut))
      assert(part.status == "more" or part.status == "not_tls", ("%q at %d"):format(input, cut))
    end
  end
  assert(client_hello("").status == "more")
  assert(client_hello("\22").status == "more")
  assert(client_hello("\22\3\1").status == "more")
end

local function test_client_hello_refuses_broken_lengths()
  local good = Fixture.hello({ name = "ok.example" })
  local function records_of(message: string): string
    return Fixture.records(message)
  end
  local be = Fixture.be
  local sni = Fixture.server_name
  local ext = Fixture.extension
  local cases: {{string, string}} = {
    { records_of("\2" .. good:sub(2)), "not a ClientHello" },
    { records_of("\1\0\0\0"), "shorter than its fixed fields" },
    { records_of(Fixture.hello({ name = "a.example", session = 33 })), "session id" },
    { records_of("\1" .. be(40, 3) .. ("\3\3" .. ("r"):rep(32) .. "\32" .. ("s"):rep(5))), "session id past" },
    { records_of(Fixture.hello({ name = "a.example", suites = 0 })), "cipher suites" },
    { records_of((good:gsub("\0\47\1\0", "\0\47\0\0"))), "compression" },
    { records_of(Fixture.hello({ extra = { ext(0, sni("a.example")), ext(0, sni("b.example")) } })), "repeats an extension" },
    { records_of(Fixture.hello({ name = "a.example", extra = { ext(0, sni("b.example")) } })), "repeats an extension" },
    { records_of(Fixture.hello({ extra = { ext(21, ""), ext(21, "") } })), "repeats an extension" },
    { records_of(Fixture.hello({ server_name = "" })), "list length" },
    { records_of(Fixture.hello({ server_name = "\0" })), "list length" },
    { records_of(Fixture.hello({ server_name = "\0\0" })), "list length" },
    { records_of(Fixture.hello({ server_name = "\0\5\0\0\3abc" })), "list length" },
    { records_of(Fixture.hello({ server_name = "\0\6\0\0\9abc" })), "entry past its end" },
    { records_of(Fixture.hello({ server_name = "\0\3\0\0\3" })), "entry past its end" },
    { records_of(Fixture.hello({ server_name = "\0\2\0\0" })), "entry past its end" },
    { records_of(Fixture.hello({ server_name = "\0\6\1\0\3abc" })), "not host_name" },
    { records_of(Fixture.hello({ server_name = "\0\12\0\0\3abc\0\0\3def" })), "server_name names two hosts" },
    { records_of(Fixture.hello({ server_name = "\0\6\0\0\3a_c" })), "not a host name" },
    { records_of(Fixture.hello({ name = "127.0.0.1" })), "last label is a number" },
    { records_of(Fixture.hello({ name = "" })), "empty host name" },
    { records_of(Fixture.hello({ name = "a..b" })), "empty label" },
    { records_of(Fixture.hello({ name = "bad name.example" })), "not a host name" },
    { records_of(Fixture.hello({ name = ("a"):rep(64) .. ".example" })), "label longer" },
    { records_of(Fixture.hello({ name = "a\0b.example" })), "not a host name" },
  }
  -- Extensions that run past their own or the hello's end.
  local base = Fixture.hello({ name = "ok.example" })
  local at_ext_len = #base - #ext(0, sni("ok.example")) - 2 + 1
  local function patched(message: string, at: integer, bytes: string): string
    return message:sub(1, at - 1) .. bytes .. message:sub(at + #bytes)
  end
  local ext_len_at = #base - (#ext(0, sni("ok.example"))) - 1
  cases[#cases + 1] = { records_of(patched(base, ext_len_at, be(0xffff, 2))), "extensions length" }
  cases[#cases + 1] = { records_of(patched(base, ext_len_at, be(#ext(0, sni("ok.example")) - 1, 2))), "extensions length" }
  cases[#cases + 1] = { records_of(patched(base, #base - #ext(0, sni("ok.example")) + 3, be(0xffff, 2))), "extension past its end" }
  assert(at_ext_len > 0)
  for _, case in ipairs(cases) do
    local r = client_hello(case[1])
    assert(r.status == "malformed", ("%q: %s"):format(case[1], r.status))
    assert(r.reason:find(case[2], 1, true), ("%q: reason %q lacks %q"):format(case[1], r.reason, case[2]))
    assert(r.consumed == 0)
    hello_splits_agree(case[1], "malformed")
  end
end

local function test_client_hello_without_extensions_has_no_sni()
  local input = Fixture.records(Fixture.hello())
  local r = client_hello(input)
  assert(r.status == "no_sni" and r.consumed == #input, r.status)
  assert(sni_of(Fixture.records(Fixture.hello({ extra = { Fixture.extension(21, "\0\0") } }))) == "no_sni")
  assert(sni_of(Fixture.records(Fixture.hello({ session = 32, suites = 40 }))) == "no_sni")
end

local function test_client_hello_name_rules_match_connects()
  local names: {{string, string}} = {
    { "Example.COM", "example.com" },
    { "example.com.", "example.com" },
    { "a-b.example", "a-b.example" },
    { ("a"):rep(63) .. ".example", ("a"):rep(63) .. ".example" },
  }
  for _, case in ipairs(names) do
    assert(sni_of(Fixture.records(Fixture.hello({ name = case[1] }))) == case[2], case[1])
  end
end

local function test_a_handshake_record_of_an_unknown_version_is_refused_not_passed()
  local hello = Fixture.hello({ name = "version.example" })
  for _, version in ipairs({ 0x0305, 0x03ff, 0x0401, 0x0200, 0x0000, 0xffff }) do
    local input = Fixture.records(hello, nil, version)
    local r = client_hello(input)
    assert(r.status == "malformed", ("%04x: %s"):format(version, r.status))
    assert(r.reason:find("version", 1, true), r.reason)
    hello_splits_agree(input, "malformed")
  end
  -- Only a first byte that is no handshake's is not TLS.
  assert(client_hello(" x").status == "not_tls")
end

local function test_client_hello_waits_for_the_rest_of_a_short_message()
  local message = Fixture.hello({ name = "wait.example" })
  -- The record is whole but the message in it is not: the next record may carry the rest.
  local short = Fixture.records(message:sub(1, 20))
  assert(client_hello(short).status == "more")
  assert(client_hello(Fixture.records(message:sub(1, 3))).status == "more")
  assert(client_hello(short .. Fixture.records(message:sub(21))).status == "name")
  -- But not a record of another kind.
  local other = client_hello(short .. "\23\3\3\0\1x")
  assert(other.status == "malformed" and other.reason:find("not a TLS handshake record"), other.status)
  local version = client_hello(short .. "\22\3\9\0\1x")
  assert(version.status == "malformed", version.status)
  local empty = client_hello(short .. "\22\3\1\0\0")
  assert(empty.status == "malformed", empty.status)
end

--- `input` fed to `feed` a byte at a time, and the last answer.
local function dribbled<T>(feed: function(string): T, input: string): T
  local answer: T
  for at = 1, #input do
    answer = feed(input:sub(at, at))
  end
  return answer
end

--- The bytes `work` hands to the string library and `table.concat`: each
--- call counts the longer of its subject and its result, a scan counting from
--- where it starts, so a reader that joins the whole head again at each byte or
--- scans a literal from its start at each byte counts the square of the
--- bytes, and one that reads each byte once counts a few times their number.
--- (Time cannot tell the two apart on a small input without flaking on a
--- loaded host.)
local function string_work(work: function()): integer
  local total = 0
  local saved: {{{string: any}, string, any}} = {}
  --- Replaces `host[name]` with a wrapper that adds `cost(result, args)`.
  local function patch(host: {string: any}, name: string, cost: function({any}, {any}): integer)
    local original = host[name] as function(...: any): any...
    saved[#saved + 1] = { host, name, original }
    host[name] = function(...: any): any...
      local args = table.pack(...)
      local results = table.pack(original(...))
      total = total + cost(results, args)
      return table.unpack(results, 1, results.n)
    end
  end
  local function length(result: {any}): integer
    return #tostring(result[1])
  end
  --- A scan reads its subject from where it starts.
  local function scan(_: {any}, args: {any}): integer
    local subject = args[1]
    if type(subject) ~= "string" then
      return 0
    end
    local from = math.tointeger(args[3]) or 1
    return math.max(1, #subject - from + 1)
  end
  local lib = string as any as {string: any}
  patch(lib, "sub", length)
  patch(lib, "reverse", length)
  patch(lib, "gsub", length)
  patch(lib, "byte", function(): integer return 1 end)
  patch(lib, "find", scan)
  patch(lib, "match", scan)
  patch(table as any as {string: any}, "concat", length)
  local ok, trouble = pcall(function(): boolean
    work()
    return true
  end)
  for _, entry in ipairs(saved) do
    entry[1][entry[2]] = entry[3]
  end
  assert(ok, trouble)
  return total
end

--- Feeding a whole message a byte at a time costs a few times its length
--- in string work, where a re-joined buffer or a re-scan costs its square
--- (134 million for 16384 bytes).
local DRIBBLE_FACTOR <const> = 40

local function test_a_head_fed_a_byte_at_a_time_costs_its_length()
  local function head(total: integer): string
    local lines = { "A: " .. ("v"):rep(7000), "B: " .. ("v"):rep(7000), "C: " }
    local without = Fixture.connect("example.com:80", lines)
    lines[3] = "C: " .. ("w"):rep(total - #without)
    return Fixture.connect("example.com:80", lines)
  end
  local input = head(16384)
  assert(#input == 16384)
  local answer: Wire.Connect
  local work = string_work(function()
    local reader = Wire.connect_reader()
    answer = dribbled(function(chunk: string): Wire.Connect
      return reader:feed(chunk)
    end, input)
  end)
  assert(answer.status == "done" and answer.consumed == 16384, tostring(answer.reason))
  assert(work > 0 and work < DRIBBLE_FACTOR * #input, ("16384 single-byte feeds did %d bytes of string work"):format(work))
  -- A line of the most bytes costs the same.
  local line = "CONNECT example.com:80 HTTP/1.1\r\nX: " .. ("v"):rep(8192 - 3) .. "\r\n\r\n"
  local line_work = string_work(function()
    local reader = Wire.connect_reader()
    answer = dribbled(function(chunk: string): Wire.Connect
      return reader:feed(chunk)
    end, line)
  end)
  assert(answer.status == "done" and line_work < DRIBBLE_FACTOR * #line, line_work)
end

local function test_string_work_counts_a_reader_that_reads_its_buffer_again()
  -- The counter must see what the dribble tests exist to catch.
  local input = ("v"):rep(2000)
  local once = string_work(function()
    for at = 1, #input do
      local _ = input:sub(at, at)
    end
  end)
  local again = string_work(function()
    local held = ""
    for at = 1, #input do
      held = table.concat({ held, input:sub(at, at) })
    end
  end)
  assert(once < 3 * #input, once)
  assert(again > #input * #input / 4, again)
end

local function test_a_hello_fed_a_byte_at_a_time_costs_its_length()
  local hello = Fixture.hello({ name = "dribble.example", size = 16384 })
  local sizes: {integer} = {}
  for i = 1, 63 do
    sizes[i] = 1
  end
  for _, input in ipairs({ Fixture.records(hello, { 16000 }), Fixture.records(hello, sizes), Fixture.records(hello, { 300, 400 }) }) do
    local answer: Wire.Hello
    local work = string_work(function()
      local reader = Wire.hello_reader()
      answer = dribbled(function(chunk: string): Wire.Hello
        return reader:feed(chunk)
      end, input)
    end)
    assert(answer.status == "name" and answer.name == "dribble.example" and answer.consumed == #input, answer.status)
    assert(work > 0 and work < DRIBBLE_FACTOR * #input, ("%d single-byte feeds did %d bytes of string work"):format(#input, work))
  end
end

--- Seconds `work` takes.
local function seconds(work: function()): number
  local start = Clock.monotonic_ns()
  work()
  return (Clock.monotonic_ns() - start) / 1e9
end

local function test_blanks_around_a_header_value_cost_its_length()
  for _, blank in ipairs({ " ", "\t", " \t" }) do
    local value = "a" .. blank:rep(1500) .. "b" .. blank:rep(1500)
    local input = Fixture.connect("example.com:80", { "Proxy-Authorization: " .. blank:rep(100) .. value })
    local answer: Wire.Connect
    local took = seconds(function()
      answer = connect_head(input)
    end)
    assert(answer.status == "done", answer.status)
    assert(answer.authorization == "a" .. blank:rep(1500) .. "b", "the blanks inside stay")
    assert(took < 0.1, ("%.3f s"):format(took))
  end
  assert(connect_head(Fixture.connect("a.example:1", { "Proxy-Authorization:" .. (" \t"):rep(4000) })).authorization == "")
end

local function test_an_encrypted_server_name_extension_is_its_own_answer()
  for _, kind in ipairs({ 0xfe0d, 0xffce, 0xff02, 0xff03 }) do
    local ext = Fixture.extension(kind, "\0\1\2")
    for _, hello in ipairs({
        Fixture.hello({ name = "public.example", extra = { ext } }),
        Fixture.hello({ extra = { ext } }),
        Fixture.hello({ name = "public.example", extra = { Fixture.extension(21, "\0"), ext, Fixture.extension(43, "") } }),
        Fixture.hello({ extra = { ext } }),
    }) do
      local input = Fixture.records(hello)
      local r = client_hello(input)
      assert(r.status == "encrypted_sni", ("%x: %s"):format(kind, r.status))
      assert(r.name == nil and r.consumed == #input and r.reason:find("encrypted server name"), r.reason)
      hello_splits_agree(input, "encrypted_sni")
    end
  end
  -- Another extension type next to them is no such thing, and a broken one is still broken.
  assert(sni_of(Fixture.records(Fixture.hello({ name = "plain.example", extra = { Fixture.extension(0xfe0c, "") } }))) == "plain.example")
  local broken = client_hello(Fixture.records(Fixture.hello({ name = "bad_name.example", extra = { Fixture.extension(0xfe0d, "") } })))
  assert(broken.status == "malformed", broken.status)
end
