--- Fuzz properties for the client's side of [`cosmic.relay_wire`], whose
--- readers take what a SOCKS5 server answers: none raises on any bytes,
--- none reports more bytes taken than it was given, a read in pieces agrees
--- with the read of the whole, and a request the client writes is read back
--- by the relay's own reader as the host and port it was written for.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fixture = require("build.relay_wire_fixture")
local Fuzz = require("build.fuzz")
local Wire = require("cosmic.relay_wire")

--- A reader of one format, made afresh, as a function that feeds the next
--- bytes and answers a status, a count of bytes taken and every field the
--- answer carries as one string, so that two answers compare whole.
local record Format
  name: string
  fresh: function(): function(string): string, integer, string
  gen: function(Fuzz.Source): string
end

local function method_fresh(): function(string): string, integer, string
  local reader = Wire.socks_method_reader()
  return function(chunk: string): string, integer, string
    local seen = reader:feed(chunk)
    return seen.status, seen.consumed, ("%s|%s|%s"):format(seen.status, tostring(seen.reason), tostring(seen.method))
  end
end

local function method_password_fresh(): function(string): string, integer, string
  local reader = Wire.socks_method_reader(true)
  return function(chunk: string): string, integer, string
    local seen = reader:feed(chunk)
    return seen.status, seen.consumed, ("%s|%s|%s"):format(seen.status, tostring(seen.reason), tostring(seen.method))
  end
end

local function auth_status_fresh(): function(string): string, integer, string
  local reader = Wire.socks_auth_status_reader()
  return function(chunk: string): string, integer, string
    local seen = reader:feed(chunk)
    return seen.status, seen.consumed, ("%s|%s|%s"):format(seen.status, tostring(seen.reason), tostring(seen.accepted))
  end
end

local function answer_fresh(): function(string): string, integer, string
  local reader = Wire.socks_answer_reader()
  return function(chunk: string): string, integer, string
    local seen = reader:feed(chunk)
    return seen.status, seen.consumed, ("%s|%s|%s|%s"):format(seen.status, tostring(seen.reason), tostring(seen.code),
      tostring(seen.reply))
  end
end

local function gen_method(src: Fuzz.Source): string
  local version = src:int(0, 9) == 0 and src:int(0, 255) or 5
  local method = src:int(0, 3) == 0 and src:int(0, 255) or Fuzz.pick(src, { 0, 0, 255 })
  local text = string.char(version, method)
  if src:int(0, 4) == 0 then text = text .. Fuzz.bytes(src, 4) end
  return Fuzz.mutate(src, text, src:int(0, 3) == 0 and 1 or 0)
end

local function gen_method_password(src: Fuzz.Source): string
  local version = src:int(0, 9) == 0 and src:int(0, 255) or 5
  local method = src:int(0, 3) == 0 and src:int(0, 255) or Fuzz.pick(src, { 2, 2, 0, 255 })
  local text = string.char(version, method)
  if src:int(0, 4) == 0 then text = text .. Fuzz.bytes(src, 4) end
  return Fuzz.mutate(src, text, src:int(0, 3) == 0 and 1 or 0)
end

local function gen_auth_status(src: Fuzz.Source): string
  local version = src:int(0, 2) == 0 and src:int(0, 255) or 1
  local status = src:int(0, 3) == 0 and src:int(0, 255) or Fuzz.pick(src, { 0, 0, 1 })
  local text = string.char(version, status)
  if src:int(0, 4) == 0 then text = text .. Fuzz.bytes(src, 4) end
  return Fuzz.mutate(src, text, src:int(0, 3) == 0 and 1 or 0)
end

local function gen_answer(src: Fuzz.Source): string
  local atyp = src:int(0, 9) == 0 and src:int(0, 6) or Fuzz.pick(src, { 1, 1, 3, 4 })
  local address: string
  if atyp == 1 then
    address = Fuzz.bytes(src, 4)
    address = address .. ("\0"):rep(4 - #address)
  elseif atyp == 4 then
    address = Fuzz.bytes(src, 16)
    address = address .. ("\0"):rep(16 - #address)
  else
    local name = Fuzz.bytes(src, 20)
    address = string.char(src:int(0, 9) == 0 and src:int(0, 255) or #name) .. name
  end
  local code = src:int(0, 4) == 0 and src:int(0, 255) or src:int(0, 8)
  local text = "\5" .. string.char(code) .. (src:int(0, 9) == 0 and "\1" or "\0") .. string.char(atyp) .. address ..
    Fuzz.bytes(src, 2)
  if src:int(0, 4) == 0 then text = text .. Fuzz.bytes(src, 6) end
  return Fuzz.mutate(src, text, src:int(0, 3) == 0 and 2 or 0)
end

local READERS <const>: {Format} = {
  { name = "socks method choice", fresh = method_fresh, gen = gen_method },
  { name = "socks method choice of a password", fresh = method_password_fresh, gen = gen_method_password },
  { name = "socks auth verdict", fresh = auth_status_fresh, gen = gen_auth_status },
  { name = "socks answer", fresh = answer_fresh, gen = gen_answer },
}

local function test_no_client_reader_raises_or_takes_more_than_it_was_given(tmp: string)
  for _, format in ipairs(READERS) do
    Fuzz.run({
      name = format.name .. " is total and bounded",
      dir = tmp,
      gen = function(src: Fuzz.Source): string
        if src:int(0, 7) == 0 then return Fuzz.bytes(src, 40) end
        return format.gen(src)
      end,
      requires = { "more", "done", "refused" },
      shares = { more = 0.01, done = 0.05, refused = 0.1 },
      check = function(input: string): boolean, string
        local ok, status, consumed = pcall(function(): string, integer
          local s, c = format.fresh()(input)
          return s, c
        end)
        if not ok then return false, "raised " .. tostring(status) end
        if status ~= "more" and status ~= "done" and status ~= "refused" then
          return false, "answered " .. tostring(status)
        end
        if consumed > #input then return false, ("took %d of %d bytes"):format(consumed, #input) end
        if (status == "done") ~= (consumed > 0) then
          return false, ("%s having taken %d bytes"):format(status, consumed)
        end
        Fuzz.label(status as string)
        return true, ""
      end,
    })
  end
end

local function test_feeding_in_pieces_agrees_with_feeding_the_whole(tmp: string)
  for _, format in ipairs(READERS) do
    Fuzz.run({
      name = format.name .. " in pieces",
      dir = tmp,
      gen = format.gen,
      requires = { "done", "refused", "pieces" },
      shares = { done = 0.05, refused = 0.1 },
      check = function(input: string): boolean, string
        local status, _, key = format.fresh()(input)
        Fuzz.label(status)
        for cut = 0, #input do
          local feed = format.fresh()
          local first_status, _, first_key = feed(input:sub(1, cut))
          if first_status ~= "more" then
            if first_key ~= key then
              return false, ("the first %d bytes answer %s, not %s"):format(cut, first_key, key)
            end
          elseif status ~= "more" then
            Fuzz.label("pieces")
          end
          local _, _, second_key = feed(input:sub(cut + 1))
          if second_key ~= key then
            return false, ("fed %d bytes and then the rest, it answers %s, not %s"):format(cut, second_key, key)
          end
        end
        local feed = format.fresh()
        local last_key: string
        for at = 1, #input do
          local _, _, each = feed(input:sub(at, at))
          last_key = each
        end
        if last_key ~= nil and last_key ~= key then
          return false, ("fed a byte at a time it answers %s, not %s"):format(last_key, key)
        end
        return true, ""
      end,
    })
  end
end

--- Characters a host is drawn from when it is not meant to be sound: those of
--- a name, an address and some no host holds.
local HOST_CHARS <const> = { "a", "b", "z", "0", "9", "-", ".", ".", ":", "x", "F", "_", "\0", "\255" }

local function test_a_request_the_client_writes_is_read_back_by_the_relay(tmp: string)
  Fuzz.run({
    name = "client request round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local host: {string} = {}
      local kind = src:int(0, 3)
      if kind == 0 then
        for i = 1, 4 do host[i] = tostring(src:int(0, 255)) end
        return Fuzz.pack({ table.concat(host, "."), tostring(src:int(0, 65536)) })
      elseif kind == 1 then
        for i = 1, 8 do host[i] = ("%x"):format(src:int(0, 3) == 0 and src:int(0, 65535) or 0) end
        return Fuzz.pack({ table.concat(host, ":"), tostring(src:int(0, 65536)) })
      end
      if kind == 2 then
        while Fuzz.more(src, #host, 3) do
          host[#host + 1] = Fuzz.pick(src, { "api", "a-b", "x9", "github" })
        end
        host[#host + 1] = "com"
        return Fuzz.pack({ table.concat(host, "."), tostring(src:int(0, 65536)) })
      end
      while Fuzz.more(src, #host, 30) do host[#host + 1] = Fuzz.pick(src, HOST_CHARS) end
      return Fuzz.pack({ table.concat(host), tostring(src:int(0, 65536)) })
    end,
    requires = { "name", "ipv4", "ipv6", "read" },
    shares = { name = 0.05, ipv4 = 0.05, ipv6 = 0.05 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local host, port = fields[1], math.tointeger(tonumber(fields[2]))
      local request, why = Wire.socks_client_request(host, port)
      if request == nil then
        if why == "" then return false, "refused without saying why" end
        return true, ""
      end
      local seen = Wire.socks_request_reader():feed(request)
      if seen.status == "more" or seen.consumed > #request then
        return false, ("the relay's reader answers %s having taken %d of %d bytes"):format(seen.status, seen.consumed,
          #request)
      end
      -- The relay may refuse a name by its rules, but never reads another
      -- host or port than the one written, and an address literal it reads.
      if seen.status == "done" then
        if seen.port ~= port or seen.consumed ~= #request then
          return false, ("%q:%d was read as %s:%d"):format(host, port, seen.host, seen.port)
        end
        -- The host read is the host written, as its form has it.
        if seen.kind == "ipv4" then
          if seen.host ~= host then return false, ("%q was read as %s"):format(host, seen.host) end
        elseif seen.kind == "ipv6" then
          if Fixture.ipv6_bytes(seen.host) ~= request:sub(5, 20) then
            return false, ("%q was read as %s, other bytes"):format(host, seen.host)
          end
        elseif seen.host ~= (host:lower():gsub("%.$", "")) then
          return false, ("%q was read as %s"):format(host, seen.host)
        end
        Fuzz.label(seen.kind)
        Fuzz.label("read")
      elseif request:byte(4) ~= 3 then
        return false, ("an address of type %d was refused: %s"):format(request:byte(4), tostring(seen.reason))
      end
      return true, ""
    end,
  })
end

local function test_a_username_and_password_the_client_writes_are_read_back_by_the_relay(tmp: string)
  Fuzz.run({
    name = "client auth round trip",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local function field(): string
        -- Mostly sound lengths, with the edges (empty, 255, 256) drawn often.
        local size = Fuzz.pick(src, { 0, 1, 255, 256, src:int(1, 40), src:int(1, 40) })
        return (Fuzz.pick(src, { "a", "\0", "\255", ":", "@" })):rep(size) .. Fuzz.bytes(src, 3)
      end
      return Fuzz.pack({ field(), field() })
    end,
    requires = { "written", "refused" },
    shares = { written = 0.1, refused = 0.05 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local user, password = fields[1], fields[2]
      local message, why = Wire.socks_client_auth(user, password)
      local fits = #user >= 1 and #user <= 255 and #password >= 1 and #password <= 255
      if message == nil then
        if fits then return false, "refused what fits: " .. why end
        if why == "" then return false, "refused without saying why" end
        if why:find(password, 1, true) and #password > 3 then
          return false, "the reason holds the password"
        end
        Fuzz.label("refused")
        return true, ""
      end
      if not fits then return false, ("wrote %d and %d bytes"):format(#user, #password) end
      -- Fed whole and a byte at a time, the relay reads what was written.
      local whole = Wire.socks_auth_reader():feed(message)
      if whole.status ~= "done" or whole.username ~= user or whole.password ~= password or
          whole.consumed ~= #message then
        return false, ("read back as %s with %d bytes taken"):format(whole.status, whole.consumed)
      end
      local reader = Wire.socks_auth_reader()
      local last: Wire.SocksAuth
      for at = 1, #message do last = reader:feed(message:sub(at, at)) end
      if last.status ~= "done" or last.password ~= password then
        return false, "a byte at a time it reads another"
      end
      Fuzz.label("written")
      return true, ""
    end,
  })
end
