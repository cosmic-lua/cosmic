--- Fuzz properties for [`build.relay_wire`], whose readers take the bytes
--- an untrusted program sends the relay: none raises on any bytes, none
--- reports more bytes consumed than it was given, a read in pieces
--- (every prefix of an input) agrees with the read of the whole, and a
--- request built from what a read answered reads back as the same
--- answer. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs
--- (build/fuzz/init.tl).

local Fixture = require("build.relay_wire_fixture")
local Fuzz = require("build.fuzz")
local Wire = require("build.relay_wire")

--- What a reader answered, reduced to what the properties compare.
local record Answer
  --- `more`, `done` or `refused` (a hello's `name` and `no_sni` are done,
  --- and its `not_tls` and `malformed` refused).
  status: string
  consumed: integer
  --- Every field the answer carries, so that two answers compare whole.
  key: string
end

--- A format of bytes, and a generator of them.
local record Format
  name: string
  read: function(string): Answer
  gen: function(Fuzz.Source): string
end

local function shown(fields: {any}): string
  local out: {string} = {}
  for i = 1, #fields do
    out[i] = tostring(fields[i])
  end
  return table.concat(out, "|")
end

local function answer_connect(input: string): Answer
  local r = Wire.connect_head(input)
  return { status = r.status, consumed = r.consumed,
    key = shown({ r.status, r.consumed, r.reason, r.http_status, r.host, r.kind, r.port, r.authorization }) }
end

local function answer_greeting(password: boolean): function(string): Answer
  return function(input: string): Answer
    local r = Wire.socks_greeting(input, password)
    return { status = r.status, consumed = r.consumed, key = shown({ r.status, r.consumed, r.reason, r.method }) }
  end
end

local function answer_auth(input: string): Answer
  local r = Wire.socks_auth(input)
  return { status = r.status, consumed = r.consumed,
    key = shown({ r.status, r.consumed, r.reason, r.username, r.password }) }
end

local function answer_request(input: string): Answer
  local r = Wire.socks_request(input)
  return { status = r.status, consumed = r.consumed,
    key = shown({ r.status, r.consumed, r.reason, r.reply, r.host, r.kind, r.port }) }
end

local function answer_hello(input: string): Answer
  local r = Wire.client_hello(input)
  local status = r.status == "more" and "more" or (r.status == "name" or r.status == "no_sni") and "done" or "refused"
  return { status = status, consumed = r.consumed, key = shown({ r.status, r.consumed, r.reason, r.name }) }
end

--- Characters a name's labels are drawn from: valid ones, and those the
--- rules refuse (an underscore, a space, a high byte, a NUL).
local LABEL_CHARS <const> = { "a", "b", "z", "A", "Z", "0", "7", "-", "a", "b", "c", "x", "_", " ", "\xc3", "\0" }

--- Whole labels that need care.
local LABELS <const> = { "com", "example", "localhost", "xn--a", "1", "0x7f", "127", "a-", "-a", "", ("a"):rep(63),
  ("a"):rep(64) }

--- Characters of a label the rules accept, and the ends one may start
--- and finish with.
local SOUND_INNER <const> = { "a", "b", "z", "A", "0", "7", "-", "x" }
local SOUND_ENDS <const> = { "a", "b", "z", "Q", "0", "7" }

local function gen_label(src: Fuzz.Source, sound: boolean): string
  if sound then
    local out: {string} = { Fuzz.pick(src, SOUND_ENDS) }
    while Fuzz.more(src, #out, 8) do
      out[#out + 1] = Fuzz.pick(src, SOUND_INNER)
    end
    out[#out + 1] = Fuzz.pick(src, SOUND_ENDS)
    return table.concat(out)
  end
  if src:int(0, 3) == 0 then
    return Fuzz.pick(src, LABELS)
  end
  local out: {string} = {}
  while Fuzz.more(src, #out, 10) do
    out[#out + 1] = Fuzz.pick(src, LABEL_CHARS)
  end
  return table.concat(out)
end

--- A host name: one the rules accept when `sound`, else any of the above.
local function gen_name(src: Fuzz.Source, sound: boolean): string
  local labels: {string} = {}
  while Fuzz.more(src, #labels, 4) do
    labels[#labels + 1] = gen_label(src, sound)
  end
  labels[#labels + 1] = (not sound and src:int(0, 5) == 0) and gen_label(src, false) or
    Fuzz.pick(src, { "com", "example", "org", "Net" })
  return table.concat(labels, ".") .. (src:int(0, 6) == 0 and "." or "")
end

local OCTETS <const> = { "0", "1", "127", "255", "256", "010", "08", "9", "300", "", "1a" }

local function gen_ipv4(src: Fuzz.Source, sound: boolean): string
  local parts: {string} = {}
  for i = 1, (not sound and src:int(0, 9) == 0) and src:int(1, 5) or 4 do
    parts[i] = (not sound and src:int(0, 3) == 0) and Fuzz.pick(src, OCTETS) or tostring(src:int(0, 255))
  end
  return table.concat(parts, ".")
end

local GROUPS <const> = { "0", "0", "0", "1", "ff", "FFFF", "abcd", "0000", "12345", "g", "" }

--- An IPv6 address without brackets, in the forms the notation allows
--- (full, `::` for a run, a dotted tail) and some it does not.
local function gen_ipv6(src: Fuzz.Source, sound: boolean): string
  local groups: {string} = {}
  local count = (not sound and src:int(0, 9) == 0) and src:int(0, 9) or 8
  for i = 1, count do
    groups[i] = (not sound and src:int(0, 4) == 0) and Fuzz.pick(src, GROUPS) or
      ("%x"):format(src:int(0, 3) == 0 and src:int(0, 65535) or 0)
  end
  local form = src:int(0, 3)
  if (form == 0 and not sound) or #groups == 0 then
    return table.concat(groups, ":")
  end
  local at = src:int(1, #groups)
  local stop = src:int(at, #groups)
  local left = table.concat(groups, ":", 1, at - 1)
  local right = table.concat(groups, ":", stop + 1)
  if form == 1 and stop == #groups and at <= 6 then
    right = gen_ipv4(src, true)
  elseif form == 1 and right ~= "" then
    right = right:gsub("[^:]*$", "") .. gen_ipv4(src, sound)
  end
  return left .. "::" .. right
end

--- A `host:port` authority of every kind, valid or not.
local function gen_target(src: Fuzz.Source): string
  local kind = src:int(1, 8)
  local sound = src:int(0, 2) ~= 0
  local port = src:int(0, 5) == 0 and Fuzz.pick(src, { "0", "00", "080", "65535", "65536", "-1", "", "443x", "1" .. ("0"):rep(5) }) or
    tostring(src:int(1, 65535))
  if kind <= 4 then
    return gen_name(src, sound) .. ":" .. port
  elseif kind <= 6 then
    return gen_ipv4(src, sound) .. ":" .. port
  elseif kind == 7 then
    return "[" .. gen_ipv6(src, sound) .. "]:" .. port
  end
  return Fuzz.bytes(src, 12)
end

local HEADER_NAMES <const> = { "Host", "Proxy-Authorization", "proxy-authorization", "User-Agent", "X-A", "A B", "", "Bad:" }
local HEADER_VALUES <const> = { "x", "", "Basic YTpi", "  spaced \t", "\xff\xfe", "v", "v", ("v"):rep(100), "a\0b", "\1" }

--- A CONNECT request: its parts drawn (mostly sound ones), then damaged,
--- cut short or followed by what the tunnel carries.
local function gen_connect(src: Fuzz.Source): string
  local method = src:int(0, 9) == 0 and Fuzz.pick(src, { "GET", "connect", "POST", "" }) or "CONNECT"
  local version = src:int(0, 9) == 0 and Fuzz.pick(src, { "HTTP/2", "HTTP/1.0", "http/1.1", "" }) or "HTTP/1.1"
  local lines: {string} = { method .. " " .. gen_target(src) .. " " .. version }
  while Fuzz.more(src, #lines - 1, 6) do
    local name = src:int(0, 5) == 0 and Fuzz.pick(src, HEADER_NAMES) or Fuzz.pick(src, { "Host", "Proxy-Authorization", "User-Agent" })
    local value = src:int(0, 6) == 0 and Fuzz.pick(src, HEADER_VALUES) or Fuzz.pick(src, { "x", "Basic YTpi", "v" })
    lines[#lines + 1] = name .. ": " .. value
  end
  local text = table.concat(lines, "\r\n") .. "\r\n\r\n"
  local damaged = Fuzz.mutate(src, text, src:int(0, 2) == 0 and 2 or 0)
  if src:int(0, 3) == 0 then
    damaged = damaged .. "\22\3\1tunnel"
  end
  return damaged
end

local function gen_greeting(src: Fuzz.Source): string
  local out: {string} = { src:int(0, 9) == 0 and string.char(src:int(0, 255)) or "\5" }
  local methods: {string} = {}
  while Fuzz.more(src, #methods, 5) do
    methods[#methods + 1] = string.char(Fuzz.pick(src, { 0, 0, 1, 2, 2, 255, src:int(0, 255) }))
  end
  out[#out + 1] = string.char(src:int(0, 9) == 0 and src:int(0, 255) or #methods)
  out[#out + 1] = table.concat(methods)
  local text = table.concat(out)
  if src:int(0, 4) == 0 then
    text = text .. Fuzz.bytes(src, 4)
  end
  return Fuzz.mutate(src, text, src:int(0, 3) == 0 and 1 or 0)
end

local function gen_auth(src: Fuzz.Source): string
  local user = Fuzz.bytes(src, 8)
  local pass = Fuzz.bytes(src, 8)
  local text = (src:int(0, 9) == 0 and "\2" or "\1") .. string.char(#user) .. user .. string.char(#pass) .. pass
  if src:int(0, 4) == 0 then
    text = text .. Fuzz.bytes(src, 4)
  end
  return Fuzz.mutate(src, text, src:int(0, 3) == 0 and 2 or 0)
end

local function gen_socks_request(src: Fuzz.Source): string
  local atyp = src:int(0, 9) == 0 and src:int(0, 6) or Fuzz.pick(src, { 1, 3, 3, 4 })
  local address: string
  if atyp == 1 then
    address = Fuzz.bytes(src, 4)
    address = address .. ("\0"):rep(4 - #address)
  elseif atyp == 4 then
    address = src:int(0, 3) == 0 and Fuzz.bytes(src, 16) or Fixture.ipv6_bytes(("%x::%x"):format(src:int(0, 65535), src:int(0, 65535)))
  else
    local name = gen_name(src, src:int(0, 2) ~= 0)
    address = string.char(#name) .. name
  end
  local command = src:int(0, 6) == 0 and src:int(0, 4) or 1
  local port = src:int(0, 9) == 0 and 0 or src:int(1, 65535)
  local text = Fixture.socks_request(command, atyp, address, port)
  if src:int(0, 4) == 0 then
    text = text .. Fuzz.bytes(src, 4)
  end
  return Fuzz.mutate(src, text, src:int(0, 3) == 0 and 2 or 0)
end

--- Extensions a hello may carry besides its server name.
local function gen_extras(src: Fuzz.Source): {string}
  local out: {string} = {}
  while Fuzz.more(src, #out, 4) do
    out[#out + 1] = Fixture.extension(Fuzz.pick(src, { 0, 10, 11, 21, 43, 65535 }), Fuzz.bytes(src, 8))
  end
  return out
end

local function gen_hello(src: Fuzz.Source): string
  local kind = src:int(0, 11)
  if kind == 0 then
    return Fuzz.bytes(src, 24)
  end
  local name: string = nil
  if src:int(0, 4) ~= 0 then
    name = gen_name(src, src:int(0, 2) ~= 0)
  end
  local message = Fixture.hello({
    name = name,
    session = src:int(0, 9) == 0 and src:int(0, 40) or src:int(0, 32),
    suites = src:int(0, 9) == 0 and src:int(0, 3) or 2,
    extra = gen_extras(src),
    server_name = src:int(0, 14) == 0 and Fuzz.bytes(src, 12) or nil,
  })
  local sizes: {integer} = {}
  while Fuzz.more(src, #sizes, 4) do
    sizes[#sizes + 1] = src:int(1, 80)
  end
  local text = Fixture.records(message, sizes, Fuzz.pick(src, { 0x0301, 0x0303, 0x0301, 0x0304 }))
  if src:int(0, 4) == 0 then
    text = text .. Fuzz.bytes(src, 6)
  end
  return Fuzz.mutate(src, text, src:int(0, 3) == 0 and 2 or 0)
end

local READERS <const>: {Format} = {
  { name = "connect head", read = answer_connect, gen = gen_connect },
  { name = "socks greeting", read = answer_greeting(false), gen = gen_greeting },
  { name = "socks greeting with a password", read = answer_greeting(true), gen = gen_greeting },
  { name = "socks username and password", read = answer_auth, gen = gen_auth },
  { name = "socks request", read = answer_request, gen = gen_socks_request },
  { name = "client hello", read = answer_hello, gen = gen_hello },
}

local function test_no_reader_raises_or_consumes_past_its_input(tmp: string)
  for _, reader in ipairs(READERS) do
    Fuzz.run({
      name = reader.name .. " is total and bounded",
      dir = tmp,
      gen = function(src: Fuzz.Source): string
        if src:int(0, 7) == 0 then
          return Fuzz.bytes(src, 40)
        end
        return reader.gen(src)
      end,
      requires = { "more", "done", "refused" },
      shares = { more = 0.01, done = 0.05, refused = 0.1 },
      check = function(input: string): boolean, string
        local ok, got = pcall(reader.read, input)
        if not ok then
          return false, "raised " .. tostring(got)
        end
        local answer = got as Answer
        if answer.status ~= "more" and answer.status ~= "done" and answer.status ~= "refused" then
          return false, "answered " .. tostring(answer.status)
        end
        if answer.consumed > #input then
          return false, ("consumed %d of %d bytes"):format(answer.consumed, #input)
        end
        if (answer.status == "done") ~= (answer.consumed > 0) then
          return false, ("%s having consumed %d bytes"):format(answer.status, answer.consumed)
        end
        Fuzz.label(answer.status)
        return true, ""
      end,
    })
  end
end

local function test_reading_in_pieces_agrees_with_reading_the_whole(tmp: string)
  for _, reader in ipairs(READERS) do
    Fuzz.run({
      name = reader.name .. " in pieces",
      dir = tmp,
      gen = reader.gen,
      requires = { "done", "refused", "pieces" },
      shares = { done = 0.05, refused = 0.1 },
      check = function(input: string): boolean, string
        local whole = reader.read(input)
        if whole.status == "more" then
          -- Nothing is settled, so every prefix is as undecided.
          for cut = 0, #input do
            if reader.read(input:sub(1, cut)).status ~= "more" then
              return false, ("the whole is undecided but its first %d bytes are not"):format(cut)
            end
          end
          return true, ""
        end
        Fuzz.label(whole.status)
        for cut = 0, #input do
          local part = reader.read(input:sub(1, cut))
          if whole.status == "done" and cut < whole.consumed then
            if part.status ~= "more" then
              return false, ("the first %d bytes answer %s, short of the %d consumed"):format(cut, part.key, whole.consumed)
            end
            Fuzz.label("pieces")
          elseif whole.status == "done" and cut == whole.consumed then
            if part.key ~= whole.key then
              return false, ("the consumed %d bytes answer %s, not %s"):format(cut, part.key, whole.key)
            end
          elseif whole.status == "refused" and part.status ~= "more" then
            if part.key ~= whole.key then
              return false, ("the first %d bytes answer %s, not %s"):format(cut, part.key, whole.key)
            end
          end
          if whole.status == "refused" and part.status == "more" then
            Fuzz.label("pieces")
          end
        end
        return true, ""
      end,
    })
  end
end

local function authority_of(host: string, kind: string, port: integer): string
  return (kind == "ipv6" and "[" .. host .. "]" or host) .. ":" .. port
end

local function test_a_request_built_from_an_answer_reads_back_the_same(tmp: string)
  Fuzz.run({
    name = "connect head round trip",
    dir = tmp,
    gen = gen_connect,
    requires = { "name", "ipv4", "ipv6", "authorization", "rebuilt" },
    shares = { name = 0.05, ipv4 = 0.02, ipv6 = 0.02, authorization = 0.02 },
    check = function(input: string): boolean, string
      local first = Wire.connect_head(input)
      if first.status ~= "done" then
        return true, ""
      end
      Fuzz.label(first.kind)
      local headers: {string} = {}
      if first.authorization ~= nil then
        Fuzz.label("authorization")
        headers[1] = "Proxy-Authorization: " .. first.authorization
      end
      local rebuilt = Fixture.connect(authority_of(first.host, first.kind, first.port), headers)
      local second = Wire.connect_head(rebuilt)
      if second.status ~= "done" or second.host ~= first.host or second.kind ~= first.kind or second.port ~= first.port or
          second.authorization ~= first.authorization or second.consumed ~= #rebuilt then
        return false, ("%q read as %s %s %s and rebuilt as %q reads %s %s %s"):format(input, first.host, first.kind,
          first.port, rebuilt, tostring(second.host), tostring(second.kind), tostring(second.port))
      end
      Fuzz.label("rebuilt")
      return true, ""
    end,
  })
end

local function test_a_socks_request_built_from_an_answer_reads_back_the_same(tmp: string)
  Fuzz.run({
    name = "socks request round trip",
    dir = tmp,
    gen = gen_socks_request,
    requires = { "name", "ipv4", "ipv6", "rebuilt" },
    shares = { name = 0.05, ipv4 = 0.02, ipv6 = 0.02 },
    check = function(input: string): boolean, string
      local first = Wire.socks_request(input)
      if first.status ~= "done" then
        return true, ""
      end
      Fuzz.label(first.kind)
      local address: string
      if first.kind == "name" then
        address = string.char(#first.host) .. first.host
      elseif first.kind == "ipv4" then
        local a, b, c, d = first.host:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
        address = string.char(math.tointeger(tonumber(a)), math.tointeger(tonumber(b)), math.tointeger(tonumber(c)),
          math.tointeger(tonumber(d)))
      else
        address = Fixture.ipv6_bytes(first.host)
      end
      local atyp = first.kind == "name" and 3 or first.kind == "ipv4" and 1 or 4
      local rebuilt = Fixture.socks_request(1, atyp, address, first.port)
      local second = Wire.socks_request(rebuilt)
      if second.status ~= "done" or second.host ~= first.host or second.kind ~= first.kind or second.port ~= first.port or
          second.consumed ~= #rebuilt then
        return false, ("%q read as %s:%s and rebuilt as %q reads %s:%s"):format(input, first.host, first.port, rebuilt,
          tostring(second.host), tostring(second.port))
      end
      Fuzz.label("rebuilt")
      return true, ""
    end,
  })
end

local function test_a_hello_built_from_an_answer_reads_back_the_same(tmp: string)
  Fuzz.run({
    name = "client hello round trip",
    dir = tmp,
    gen = gen_hello,
    requires = { "name", "rebuilt" },
    shares = { name = 0.05 },
    check = function(input: string): boolean, string
      local first = Wire.client_hello(input)
      if first.status ~= "name" then
        return true, ""
      end
      Fuzz.label("name")
      local rebuilt = Fixture.records(Fixture.hello({ name = first.name }))
      local second = Wire.client_hello(rebuilt)
      if second.status ~= "name" or second.name ~= first.name or second.consumed ~= #rebuilt then
        return false, ("%q read as %s and rebuilt as %q reads %s"):format(input, first.name, rebuilt, tostring(second.name))
      end
      Fuzz.label("rebuilt")
      return true, ""
    end,
  })
end

local function test_a_username_and_password_built_from_an_answer_reads_back_the_same(tmp: string)
  Fuzz.run({
    name = "socks auth round trip",
    dir = tmp,
    gen = gen_auth,
    requires = { "rebuilt" },
    shares = { rebuilt = 0.02 },
    check = function(input: string): boolean, string
      local first = Wire.socks_auth(input)
      if first.status ~= "done" then
        return true, ""
      end
      local rebuilt = "\1" .. string.char(#first.username) .. first.username .. string.char(#first.password) .. first.password
      local second = Wire.socks_auth(rebuilt)
      if second.status ~= "done" or second.username ~= first.username or second.password ~= first.password or
          second.consumed ~= #rebuilt then
        return false, ("%q read as %q:%q and rebuilt as %q"):format(input, first.username, first.password, rebuilt)
      end
      Fuzz.label("rebuilt")
      return true, ""
    end,
  })
end

local function test_a_refusal_reply_is_one_status_line_of_visible_text(tmp: string)
  Fuzz.run({
    name = "connect refusal reply",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack({ tostring(src:int(400, 599)), src:int(0, 5) == 0 and ("x"):rep(src:int(190, 220)) or Fuzz.bytes(src, 30) })
    end,
    requires = { "controls", "visible" },
    shares = { controls = 0.1, visible = 0.1 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local status = math.tointeger(tonumber(fields[1]))
      local reply = Wire.connect_refusal(status, fields[2])
      local phrase = reply:match("^HTTP/1%.1 " .. status .. " ([^\r\n]*)\r\n")
      if phrase == nil or phrase == "" or #phrase > 200 or phrase:find("[^\32-\126]") then
        return false, ("%q gave the status line of %q"):format(fields[2], reply)
      end
      local rest = reply:sub(#phrase + #tostring(status) + 13)
      if rest ~= (status == 405 and "Allow: CONNECT\r\n" or "") .. "Connection: close\r\nContent-Length: 0\r\n\r\n" then
        return false, ("%q gave more than a status line: %q"):format(fields[2], reply)
      end
      Fuzz.label(fields[2]:find("[^\32-\126]") and "controls" or "visible")
      return true, ""
    end,
  })
end
