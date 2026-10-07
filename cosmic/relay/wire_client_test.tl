--- The client's side of [`cosmic.relay.wire`]'s SOCKS5: the greeting and
--- the request a client writes, and the readers of the server's method
--- choice and of its answer. The request is checked against the relay's
--- own reader of it, and each reader at every cut of its input.

local Fixture = require("build.relay_wire_fixture")
local Wire = require("cosmic.relay.wire")

--- What `feed`, a fresh reader's, answers to `input` fed whole, in every
--- cut into two pieces and a byte at a time, which must all be the same.
local function same_in_pieces(fresh: function(): function(string): string, input: string): string
  local whole = fresh()(input)
  for cut = 0, #input do
    local feed = fresh()
    local _ = feed(input:sub(1, cut))
    local split = feed(input:sub(cut + 1))
    assert(split == whole, ("%q cut at %d answers %s, whole %s"):format(input, cut, split, whole))
  end
  local feed = fresh()
  local last = ""
  for at = 1, #input do last = feed(input:sub(at, at)) end
  assert(#input == 0 or last == whole, ("%q a byte at a time answers %s, whole %s"):format(input, last, whole))
  return whole
end

local function method_fresh(): function(string): string
  local reader = Wire.socks_method_reader()
  return function(chunk: string): string
    local seen = reader:feed(chunk)
    return ("%s|%d|%s|%s"):format(seen.status, seen.consumed, tostring(seen.reason), tostring(seen.method))
  end
end

local function method_password_fresh(): function(string): string
  local reader = Wire.socks_method_reader(true)
  return function(chunk: string): string
    local seen = reader:feed(chunk)
    return ("%s|%d|%s|%s"):format(seen.status, seen.consumed, tostring(seen.reason), tostring(seen.method))
  end
end

local function auth_status_fresh(): function(string): string
  local reader = Wire.socks_auth_status_reader()
  return function(chunk: string): string
    local seen = reader:feed(chunk)
    return ("%s|%d|%s|%s"):format(seen.status, seen.consumed, tostring(seen.reason), tostring(seen.accepted))
  end
end

local function answer_fresh(): function(string): string
  local reader = Wire.socks_answer_reader()
  return function(chunk: string): string
    local seen = reader:feed(chunk)
    return ("%s|%d|%s|%s|%s"):format(seen.status, seen.consumed, tostring(seen.reason), tostring(seen.code),
      tostring(seen.reply))
  end
end

local function test_the_greeting_offers_no_authentication_and_the_relay_takes_it()
  local greeting = Wire.socks_client_greeting()
  assert(greeting == "\5\1\0", "version 5, one method, none")
  local seen = Wire.socks_greeting_reader():feed(greeting)
  assert(seen.status == "done" and seen.method == 0 and seen.consumed == 3, tostring(seen.status))
end

local function test_the_greeting_with_a_password_offers_it_alone_and_a_relay_with_a_token_selects_it()
  local greeting = Wire.socks_client_greeting(true)
  assert(greeting == "\5\1\2", "version 5, one method, username and password")
  local seen = Wire.socks_greeting_reader(true):feed(greeting)
  assert(seen.status == "done" and seen.method == 2 and seen.consumed == 3, tostring(seen.reason))
  local without = Wire.socks_greeting_reader():feed(greeting)
  assert(without.status == "refused" and without.method == 255, "a relay with no token takes no password")
  assert(Wire.socks_client_greeting(false) == "\5\1\0")
end

local function test_a_username_and_password_are_written_for_the_relay_to_read()
  local message = assert(Wire.socks_client_auth("user", "pw"))
  assert(message == "\1\4user\2pw", "version 1, each with its length first")
  local seen = Wire.socks_auth_reader():feed(message)
  assert(seen.status == "done" and seen.username == "user" and seen.password == "pw" and seen.consumed == #message,
    tostring(seen.reason))
  local widest = assert(Wire.socks_client_auth(("u"):rep(255), ("p"):rep(255)))
  local read = Wire.socks_auth_reader():feed(widest)
  assert(read.status == "done" and #read.username == 255 and #read.password == 255, "255 bytes each fit")
  for _, case in ipairs({ { "", "pw", "username is empty" }, { "u", "", "password is empty" },
      { ("u"):rep(256), "pw", "username is longer than 255" }, { "u", ("p"):rep(256), "password is longer than 255" } }) do
    local refused, why = Wire.socks_client_auth(case[1], case[2])
    assert(refused == nil and why:find(case[3], 1, true), tostring(why))
    assert(not why:find("pp", 1, true), "the reason holds no password")
  end
end

local function test_a_name_is_sent_as_a_domain_for_the_relay_to_resolve()
  local request = assert(Wire.socks_client_request("api.github.com", 443))
  assert(request == Fixture.socks_request(1, 3, "\14api.github.com", 443), "address type 3, the name's length first")
  local seen = Wire.socks_request_reader():feed(request)
  assert(seen.status == "done" and seen.host == "api.github.com" and seen.kind == "name" and seen.port == 443 and
      seen.consumed == #request, tostring(seen.reason))
end

local function test_an_address_literal_is_sent_as_an_address()
  local four = assert(Wire.socks_client_request("127.0.0.2", 22))
  assert(four == Fixture.socks_request(1, 1, "\127\0\0\2", 22), "address type 1")
  local seen = Wire.socks_request_reader():feed(four)
  assert(seen.host == "127.0.0.2" and seen.kind == "ipv4" and seen.port == 22, tostring(seen.reason))
  local six = assert(Wire.socks_client_request("2001:db8::1", 65535))
  assert(six == Fixture.socks_request(1, 4, Fixture.ipv6_bytes("2001:db8::1"), 65535), "address type 4")
  local seen_six = Wire.socks_request_reader():feed(six)
  assert(seen_six.host == "2001:db8::1" and seen_six.kind == "ipv6" and seen_six.port == 65535, tostring(seen_six.reason))
  -- A dotted quad that is no address is a name, which the relay refuses by its own rules.
  local odd = assert(Wire.socks_client_request("1.2.3.256", 1))
  assert(odd:byte(4) == 3, "300 is not an octet")
end

local function test_a_request_that_cannot_be_encoded_is_refused_naming_why()
  local empty, empty_why = Wire.socks_client_request("", 22)
  assert(empty == nil and empty_why:find("empty", 1, true), tostring(empty_why))
  local long, long_why = Wire.socks_client_request(("a"):rep(256), 22)
  assert(long == nil and long_why:find("255", 1, true), tostring(long_why))
  assert(Wire.socks_client_request(("a"):rep(255), 22) ~= nil, "255 bytes fit")
  for _, port in ipairs({ 0, 65536, -1 }) do
    local request, why = Wire.socks_client_request("host", port)
    assert(request == nil and why:find("port", 1, true), tostring(port))
  end
end

local function test_the_method_choice_is_read_whole_in_pieces_and_a_byte_at_a_time()
  assert(same_in_pieces(method_fresh, "\5\0") == "done|2|nil|0")
  assert(same_in_pieces(method_fresh, "\5\0tunnel") == "done|2|nil|0", "what follows is not read")
  assert(same_in_pieces(method_fresh, "\5\255"):find("^refused|0|no authentication method offered is accepted|255"))
  assert(same_in_pieces(method_fresh, "\5\2"):find("^refused|0|the method 2 chosen is not one offered"))
  assert(same_in_pieces(method_fresh, "\4\0"):find("^refused|0|SOCKS version 4"))
  assert(same_in_pieces(method_fresh, "\5") == "more|0|nil|nil")
  assert(same_in_pieces(method_fresh, "") == "more|0|nil|nil")
end

local function test_the_method_choice_of_a_password_is_read_whole_in_pieces_and_a_byte_at_a_time()
  assert(same_in_pieces(method_password_fresh, "\5\2") == "done|2|nil|2")
  assert(same_in_pieces(method_password_fresh, "\5\2tunnel") == "done|2|nil|2", "what follows is not read")
  assert(same_in_pieces(method_password_fresh, "\5\0"):find("^refused|0|the method 0 chosen is not one offered %(only 2%)"),
    "no authentication was not offered")
  assert(same_in_pieces(method_password_fresh, "\5\255"):find("^refused|0|no authentication method offered is accepted|255"))
  assert(same_in_pieces(method_password_fresh, "\4\2"):find("^refused|0|SOCKS version 4"))
  assert(same_in_pieces(method_password_fresh, "\5") == "more|0|nil|nil")
end

local function test_the_verdict_on_a_password_is_read_whole_in_pieces_and_a_byte_at_a_time()
  assert(same_in_pieces(auth_status_fresh, "\1\0") == "done|2|nil|true")
  assert(same_in_pieces(auth_status_fresh, "\1\0tunnel") == "done|2|nil|true", "what follows is not read")
  assert(same_in_pieces(auth_status_fresh, "\1\1") == "done|2|nil|false")
  assert(same_in_pieces(auth_status_fresh, "\1\200") == "done|2|nil|false", "any status but 0 is a refusal")
  assert(same_in_pieces(auth_status_fresh, "\5\0"):find("^refused|0|username/password version 5 in the answer"))
  assert(same_in_pieces(auth_status_fresh, "\1") == "more|0|nil|nil")
  assert(same_in_pieces(auth_status_fresh, "") == "more|0|nil|nil")
  assert(Wire.socks_auth_reply(true) == "\1\0" and Wire.socks_auth_reply(false) == "\1\1", "the relay's own words")
end

local function test_an_answer_is_read_through_its_bound_address_in_every_cut()
  local ipv4 = Wire.socks_reply("succeeded")
  assert(#ipv4 == 10)
  assert(same_in_pieces(answer_fresh, ipv4) == "done|10|nil|0|succeeded")
  assert(same_in_pieces(answer_fresh, ipv4 .. "SSH-2.0") == "done|10|nil|0|succeeded", "the tunnel's bytes are left")
  local ipv6 = "\5\0\0\4" .. ("\1"):rep(16) .. "\0\80"
  assert(same_in_pieces(answer_fresh, ipv6) == "done|22|nil|0|succeeded")
  local domain = "\5\0\0\3\11example.com\1\187"
  assert(same_in_pieces(answer_fresh, domain .. "x") == "done|18|nil|0|succeeded")
  assert(same_in_pieces(answer_fresh, "\5\0\0\3\0\0\0") == "done|7|nil|0|succeeded", "an empty name is read as it is")
end

local function test_a_reply_that_is_no_success_is_an_answer_with_its_code()
  local names = { "succeeded", "failure", "not_allowed", "network_unreachable", "host_unreachable", "refused",
    "ttl_expired", "command_not_supported", "address_type_not_supported" }
  for code, name in ipairs(names) do
    local expected = ("done|10|nil|%d|%s"):format(code - 1, name)
    assert(same_in_pieces(answer_fresh, Wire.socks_reply(name as Wire.SocksReply)) == expected, name)
  end
  -- A code the protocol does not define is still the server's answer.
  assert(same_in_pieces(answer_fresh, "\5\99\0\1\0\0\0\0\0\0") == "done|10|nil|99|nil")
end

local function test_an_answer_that_breaks_the_protocol_is_refused()
  assert(same_in_pieces(answer_fresh, "\4\0\0\1\0\0\0\0\0\0"):find("^refused|0|SOCKS version 4 in the reply"))
  assert(same_in_pieces(answer_fresh, "\5\0\1\1\0\0\0\0\0\0"):find("^refused|0|the reserved byte"))
  assert(same_in_pieces(answer_fresh, "\5\0\0\2\0\0\0\0\0\0"):find("^refused|0|SOCKS address type 2"))
  assert(same_in_pieces(answer_fresh, "\5\0\0\5"):find("^refused|0|SOCKS address type 5"))
  assert(same_in_pieces(answer_fresh, "\5\0") == "more|0|nil|nil|nil")
end

local function test_each_reply_code_means_something_a_person_can_read()
  assert(Wire.socks_reply_meaning(2) == "connection not allowed by ruleset")
  assert(Wire.socks_reply_meaning(5) == "connection refused")
  assert(Wire.socks_reply_meaning(4) == "host unreachable")
  assert(Wire.socks_reply_meaning(99) == "unknown reply code 99")
  for code = 0, 8 do
    assert(not Wire.socks_reply_meaning(code):find("unknown", 1, true), tostring(code))
  end
end
