--- DNS messages (RFC 1035): bytes in and records out, and back. This is the codec alone. It opens no socket and
--- looks nothing up: [`cosmic.net.resolve`] asks the system's resolver for a host's addresses, and this module is
--- for a program that speaks DNS itself, such as a server, a test's stand-in for one, or multicast DNS.
---
--- [`Dns.decode`] reads a message and [`Dns.encode`] writes one. [`Dns.query`] makes the message that asks one
--- question and [`Dns.reply`] the empty answer to a query.
---
--- A name is text: its labels joined by dots, with no dot at the end, and `.` alone for the root. A label is 1 to
--- 63 bytes of any value, so the text escapes what would not read back, as a master file does (RFC 1035 section
--- 5.1): `\.` is a dot inside a label, `\\` a backslash, and `\DDD` the byte of that decimal value, written for the
--- control bytes (0 to 31 and 127). Every other byte stands for itself, so a label of UTF-8 reads as its text. The
--- text of a name reads back as the same labels, whatever their bytes. [`Dns.labels`] and [`Dns.name`] go between
--- the text and the labels. Nothing here changes the case of a name or reads Punycode: names that differ only in
--- the case of ASCII letters are the same name to DNS, and comparing them is the caller's.
---
--- A record of the internet class holds the data of its type in a field: `address` for A and AAAA, `target` for
--- NS, CNAME and PTR, and `mx`, `txt`, `srv` and `soa`. A record of another type or class has `rdata` alone, the
--- bytes of its data. [`Dns.attributes`] reads the strings of a TXT record as the keys and values of DNS-SD.
---
--- [`Dns.decode`] takes bytes from anywhere. It never raises and reads no byte outside the message. A compression
--- pointer leads only to an earlier place than the labels before it, past the header, and a name follows 127 of
--- them at most, so no name loops. A header that counts more questions and records than the bytes could hold is
--- refused before any is read. It is strict: a name over 255 bytes, a record whose data is not the shape of its
--- type, or bytes after the last record refuse the whole message, with nil and why.
---
--- [`Dns.encode`] writes every name in full, with no compression, so a message it writes may be longer than the
--- one that was read.

local Array = require("cosmic.array")
local String = require("cosmic.string")

local record Dns
  --- The data of an MX record.
  record Mx
    --- The preference of the exchange; the lowest is tried first.
    preference: integer
    --- The name of the host that takes the mail.
    exchange: string
  end

  --- The data of an SRV record (RFC 2782).
  record Srv
    --- The priority of the target; the lowest is tried first.
    priority: integer
    --- The weight among targets of one priority.
    weight: integer
    --- The port of the service.
    port: integer
    --- The name of the host of the service.
    target: string
  end

  --- The data of an SOA record. Each time is in seconds, from 0 to 4294967295.
  record Soa
    --- The name of the zone's primary server.
    mname: string
    --- The mailbox of the zone's administrator, as a name: its first label is the part before the `@`.
    rname: string
    --- The version of the zone, from 0 to 4294967295.
    serial: integer
    --- How long a secondary waits before it asks for the zone again.
    refresh: integer
    --- How long a secondary waits after a refresh that failed.
    retry: integer
    --- How long a secondary answers for the zone without a refresh.
    expire: integer
    --- How long the answer that a name does not exist may be kept.
    minimum: integer
  end

  --- One question of a message.
  record Question
    --- The name asked about.
    name: string
    --- The type asked for, as [`Dns.A`], from 0 to 65535.
    type: integer
    --- The class, [`Dns.IN`] for the internet, from 0 to 32767: the low 15 bits of the class on the wire, so a
    --- class of 0xFFFF there reads as 32767 with `unicast_response` true.
    class: integer
    --- Whether the answer is wanted by unicast. It is the top bit of the class on the wire, which multicast DNS
    --- alone gives a meaning (RFC 6762 section 5.4): any other query leaves it false.
    unicast_response: boolean
  end

  --- One resource record of a message.
  record Record
    --- The name the record is about.
    name: string
    --- The type of the record, as [`Dns.TXT`], from 0 to 65535.
    type: integer
    --- The class, [`Dns.IN`] for the internet, from 0 to 32767: the low 15 bits of the class on the wire, so a
    --- class of 0xFFFF there reads as 32767 with `cache_flush` true.
    class: integer
    --- Whether the record replaces what a cache holds for its name and type. It is the top bit of the class on
    --- the wire, which multicast DNS alone gives a meaning (RFC 6762 section 10.2): any other record leaves it
    --- false.
    cache_flush: boolean
    --- The seconds the record may be kept, from 0 to 4294967295.
    ttl: integer
    --- The data of the record as it is on the wire. [`Dns.decode`] sets it on every record; there, a name
    --- inside it may be a pointer into the message it came from. [`Dns.encode`] writes it for a record that has
    --- no field of its type, and refuses one over 65535 bytes.
    rdata?: string
    --- The address of an A record as four decimal numbers (`192.0.2.1`), or of an AAAA record in the text of
    --- RFC 5952 (`2001:db8::1`), with an IPv4-mapped address as `::ffff:192.0.2.1`. [`Dns.encode`] also reads
    --- an AAAA address in any other spelling of RFC 4291.
    address?: string
    --- The name an NS, CNAME or PTR record gives.
    target?: string
    --- The data of an MX record.
    mx?: Dns.Mx
    --- The character strings of a TXT record, in order, each of 0 to 255 bytes. [`Dns.decode`] reads data of
    --- no bytes as one empty string, and [`Dns.encode`] writes an empty list as one. [`Dns.attributes`] reads
    --- the strings as keys and values.
    txt?: {string}
    --- The data of an SRV record.
    srv?: Dns.Srv
    --- The data of an SOA record.
    soa?: Dns.Soa
  end

  --- A whole message. The header's reserved bit is read as nothing and written as 0.
  record Message
    --- The identifier a reply repeats, from 0 to 65535.
    id: integer
    --- Whether the message is a response, not a query.
    response: boolean
    --- The kind of query, from 0 to 15: 0 is a standard query, 2 a server's status, 4 a notify, 5 an update.
    opcode: integer
    --- Whether the server that answers is an authority for the name.
    authoritative: boolean
    --- Whether the message was cut to fit its transport.
    truncated: boolean
    --- Whether the server is asked to follow the question to its answer.
    recursion_desired: boolean
    --- Whether the server that answers follows questions.
    recursion_available: boolean
    --- Whether the server holds every record of the answer to be authentic (RFC 4035).
    authentic_data: boolean
    --- Whether the server is asked not to check signatures (RFC 4035).
    checking_disabled: boolean
    --- The response code, from 0 to 15: 0 is no error, 1 a query the server could not read, 2 a failure of the
    --- server, 3 a name that does not exist, 4 a kind of query it does not have, 5 a refusal.
    rcode: integer
    --- The questions.
    questions: {Dns.Question}
    --- The records that answer the questions.
    answers: {Dns.Record}
    --- The records that name the authorities.
    authorities: {Dns.Record}
    --- The additional records.
    additionals: {Dns.Record}
  end

  --- The type of an IPv4 address.
  A: integer
  --- The type of the name of a zone's server.
  NS: integer
  --- The type of the name another name stands for.
  CNAME: integer
  --- The type of the start of a zone of authority.
  SOA: integer
  --- The type of a pointer to a name.
  PTR: integer
  --- The type of a mail exchange.
  MX: integer
  --- The type of strings of text.
  TXT: integer
  --- The type of an IPv6 address (RFC 3596).
  AAAA: integer
  --- The type of the host and port of a service (RFC 2782).
  SRV: integer
  --- The type a question asks every record with.
  ANY: integer
  --- The class of the internet.
  IN: integer
end

Dns.A = 1
Dns.NS = 2
Dns.CNAME = 5
Dns.SOA = 6
Dns.PTR = 12
Dns.MX = 15
Dns.TXT = 16
Dns.AAAA = 28
Dns.SRV = 33
Dns.ANY = 255
Dns.IN = 1

--- The bytes RFC 1035 allows a whole name on the wire, the length byte of each label and of the root counted.
local MAX_NAME <const> = 255

--- The bytes one label holds: a length byte's two top bits say what follows is no label.
local MAX_LABEL <const> = 63

--- The compression pointers followed in one name. A name holds 127 labels at most, so a longer chain adds no
--- label, and without a limit a message of pointers to pointers costs the square of its length to read.
local MAX_JUMPS <const> = 127

--- The bytes of a header.
local HEADER <const> = 12

--- The bytes a message holds over TCP, where two bytes give its length.
local MAX_MESSAGE <const> = 65535

--- What a byte that would not read back is written as in the text of a name.
local escapes: mut {string: string} = { ["."] = "\\.", ["\\"] = "\\\\" }
for byte = 0, 31 do
  escapes[string.char(byte)] = ("\\%03d"):format(byte)
end
escapes["\x7f"] = "\\127"

--- `label` as it stands in the text of a name.
local function escaped(label: string): string
  return (label:gsub("[%c.\\]", escapes))
end

--- The text of the name whose labels are `labels`, each of any bytes, or nil and why: a label is empty or over
--- 63 bytes, or the name is over 255 bytes on the wire. No labels are the root, `.`.
function Dns.name(labels: {string}): string?, string
  local parts: mut {string} = {}
  local size = 1
  for i, label in ipairs(labels) do
    if label == "" then return nil, ("dns: label %d of the name is empty"):format(i) end
    if #label > MAX_LABEL then
      return nil, ("dns: label %d of the name is %s, and a label holds 63"):format(i, String.counted(#label, "byte"))
    end
    size = size + 1 + #label
    parts[i] = escaped(label)
  end
  if size > MAX_NAME then
    return nil, ("dns: the name is %s on the wire, and a name holds 255"):format(String.counted(size, "byte"))
  end
  if #parts == 0 then return ".", "" end
  return table.concat(parts, "."), ""
end

--- The labels of the name `name`, each as its bytes with no escape, or nil and why: a label is empty or over 63
--- bytes, the name is over 255 bytes on the wire, or a backslash ends the text or has digits after it that are
--- not the three of a byte's value, `\000` to `\255`. A backslash before a character that is no digit gives that
--- character, and a dot at the end changes nothing. The root, `.` or the empty text, has no labels.
function Dns.labels(name: string): {string}?, string
  local labels: mut {string} = {}
  if name == "" or name == "." then return labels, "" end
  local pieces: mut {string} = {}
  local size = 1
  local pos = 1
  while true do
    local at = name:find("[.\\]", pos) or #name + 1
    if at > pos then
      local plain = name:sub(pos, at - 1)
      pieces[#pieces + 1] = plain
    end
    if at <= #name and name:sub(at, at) == "\\" then
      local digits = name:match("^%d%d%d", at + 1)
      local byte = if digits ~= nil then math.tointeger(tonumber(digits)) else nil end
      if byte ~= nil then
        if byte > 255 then
          return nil, ("dns: the escape \\%s in '%s' is no byte"):format(digits, name)
        end
        local char = string.char(byte)
        pieces[#pieces + 1] = char
        pos = at + 4
      elseif at == #name or name:find("^%d", at + 1) ~= nil then
        return nil, ("dns: a backslash in '%s' is followed by neither a character nor three digits"):format(name)
      else
        local char = name:sub(at + 1, at + 1)
        pieces[#pieces + 1] = char
        pos = at + 2
      end
    else
      local label = table.concat(pieces)
      if label == "" then return nil, ("dns: a label of '%s' is empty"):format(name) end
      if #label > MAX_LABEL then
        return nil, ("dns: label %d of '%s' is %s, and a label holds 63"):format(#labels + 1, name,
          String.counted(#label, "byte"))
      end
      size = size + 1 + #label
      labels[#labels + 1] = label
      pieces = {}
      -- A dot that ends the text is the root's, and starts no label.
      if at >= #name then break end
      pos = at + 1
    end
  end
  if size > MAX_NAME then
    return nil, ("dns: '%s' is %s on the wire, and a name holds 255"):format(name, String.counted(size, "byte"))
  end
  return labels, ""
end

--- The strings of a TXT record read as the keys and values of DNS-SD (RFC 6763 section 6): each string is a key,
--- an `=` and a value of any bytes. Keys are in lower case, since their case means nothing. Of a key given twice
--- the first stands, as the RFC has it. A string with no `=` is a key whose value is "", which a string that ends
--- in `=` gives too: a caller that must tell them apart reads `txt`. A string with no key, empty or starting with
--- `=`, is left out.
function Dns.attributes(txt: {string}): {string: string}
  local out: mut {string: string} = {}
  for _, text in ipairs(txt) do
    local equals = text:find("=", 1, true)
    local key = (if equals ~= nil then text:sub(1, equals - 1) else text end):lower()
    if key ~= "" and out[key] == nil then
      out[key] = if equals ~= nil then text:sub(equals + 1) else "" end
    end
  end
  return out
end

--- `name` as it is on the wire, each label after its length and the root's zero last, or nil and why.
local function wire_name(name: string): string?, string
  local labels, why = Dns.labels(name)
  if labels == nil then return nil, why end
  local parts: mut {string} = {}
  for i, label in ipairs(labels) do
    parts[i] = string.char(#label) .. label
  end
  parts[#parts + 1] = "\0"
  return table.concat(parts), ""
end

--- The 16 bits at index `pos` of `data`, which holds them: the high byte first, as every number of a message is.
local function u16(data: string, pos: integer): integer
  return String.byte_at(data, pos) << 8 | String.byte_at(data, pos + 1)
end

--- The 32 bits at index `pos` of `data`, which holds them.
local function u32(data: string, pos: integer): integer
  return u16(data, pos) << 16 | u16(data, pos + 2)
end

--- The four bytes of an IPv4 address as text.
local function ipv4_text(bytes: string): string
  local parts: mut {string} = {}
  for i = 1, 4 do
    parts[i] = tostring(String.byte_at(bytes, i))
  end
  return table.concat(parts, ".")
end

--- The four bytes of the IPv4 address `text`, or nil where it is none: four decimal numbers of 0 to 255, none
--- with a zero before it.
local function ipv4_bytes(text: string): string?
  if text:find("^%d+%.%d+%.%d+%.%d+$") == nil then return nil end
  local parts: mut {string} = {}
  for digits in text:gmatch("%d+") do
    local value = tonumber(digits, 10)
    if #digits > 3 or (#digits > 1 and digits:sub(1, 1) == "0") or value == nil or value > 255 then
      return nil
    end
    local char = string.char(value)
    parts[#parts + 1] = char
  end
  return table.concat(parts)
end

--- The 16 bytes of an IPv6 address in the text of RFC 5952: lower-case hexadecimal, no zero before a group, and
--- `::` for the longest run of two or more zero groups, the first of them where two are as long. An IPv4-mapped
--- address ends in the IPv4 address, as `inet_ntop` writes it.
local function ipv6_text(bytes: string): string
  if bytes:sub(1, 12) == ("\0"):rep(10) .. "\xff\xff" then
    return "::ffff:" .. ipv4_text(bytes:sub(13))
  end
  local groups: mut {string} = {}
  local run_at, run_length = 0, 1
  local zeros = 0
  for i = 1, 8 do
    local group = u16(bytes, 2 * i - 1)
    groups[i] = ("%x"):format(group)
    zeros = if group == 0 then zeros + 1 else 0 end
    if zeros > run_length then run_at, run_length = i - zeros + 1, zeros end
  end
  if run_at == 0 then return table.concat(groups, ":") end
  return table.concat(groups, ":", 1, run_at - 1) .. "::" .. table.concat(groups, ":", run_at + run_length)
end

--- Adds to `groups` the two bytes of each group of `side`, the groups of an IPv6 address on one side of its `::`,
--- and answers whether every one is a group. With `dotted`, the last may be an IPv4 address, which is two groups.
local function ipv6_groups(side: string, groups: mut {string}, dotted: boolean): boolean
  if side == "" then return true end
  local pos = 1
  while true do
    local colon = side:find(":", pos, true)
    local piece = side:sub(pos, (colon or #side + 1) - 1)
    if colon == nil and dotted and piece:find(".", 1, true) ~= nil then
      local four = ipv4_bytes(piece)
      if four == nil then return false end
      local high, low = four:sub(1, 2), four:sub(3, 4)
      groups[#groups + 1] = high
      groups[#groups + 1] = low
    else
      local value = if piece:find("^%x%x?%x?%x?$") ~= nil then tonumber(piece, 16) else nil end
      if value == nil then return false end
      local group = string.char(value >> 8, value & 0xff)
      groups[#groups + 1] = group
    end
    if colon == nil then return true end
    pos = colon + 1
  end
end

--- The 16 bytes of the IPv6 address `text`, or nil where it is none: eight groups of one to four hexadecimal
--- digits, of which one `::` may stand for one or more that are zero, and the last two may be an IPv4 address.
local function ipv6_bytes(text: string): string?
  local left: mut {string} = {}
  local gap = text:find("::", 1, true)
  if gap == nil then
    if not ipv6_groups(text, left, true) or #left ~= 8 then return nil end
    return table.concat(left)
  end
  local right: mut {string} = {}
  if text:find("::", gap + 1, true) ~= nil or not ipv6_groups(text:sub(1, gap - 1), left, false) or
      not ipv6_groups(text:sub(gap + 2), right, true) or #left + #right > 7 then
    return nil
  end
  return table.concat(left) .. ("\0\0"):rep(8 - #left - #right) .. table.concat(right)
end

--- A name read from a place of a message: what follows from there, labels and pointers, to the root.
local record Suffix
  --- The labels as text, or "" where there is none.
  text: string
  --- The bytes of the labels on the wire, each with its length byte, and the root's.
  size: integer
  --- The compression pointers followed from there to the root.
  jumps: integer
end

--- What [`Dns.decode`] reads and where it reads next.
local record Cursor
  data: string
  mut pos: integer
  --- What was read from each place a name began or a pointer led to. A message's pointers lead to a few
  --- places many times over, so each is read once and every name through it holds the one text: the work
  --- and the memory of a message stay near its size, not its size times the names a pointer stands for.
  names: mut {integer: Suffix}
end

--- A run of labels read in a row: from where a name begins or a pointer leads, to a pointer or the root.
local record Run
  start: integer
  --- The index in the labels read of its first, and of its last: one less where it has none.
  first: integer
  last: integer
  --- The bytes of its labels on the wire, each with its length byte.
  bytes: integer
end

local ROOT <const>: Suffix = { text = "", size = 1, jumps = 0 }

--- The name at the cursor as text, compression pointers followed, or nil and why. The cursor moves past the
--- name where it stands, not past what a pointer led to.
local function read_name(cursor: Cursor): string?, string
  local data = cursor.data
  local pos = cursor.pos
  local parts: mut {string} = {}
  local runs: mut {Run} = {}
  local after: integer? = nil
  -- Where the labels being read began. A pointer leads before it, so each jump goes further back and none
  -- returns to a place already read.
  local began = pos
  local first, bytes = 1, 0
  local size, jumps = 1, 0
  local rest = ROOT
  while true do
    local length = data:byte(pos)
    if length == nil then return nil, "dns: the message ends inside a name" end
    if length == 0 then
      pos = pos + 1
      break
    end
    if length >= 0xc0 then
      local low = data:byte(pos + 1)
      if low == nil then return nil, "dns: the message ends inside a name" end
      local target = ((length & 0x3f) << 8 | low) + 1
      if target >= began then return nil, "dns: a compression pointer does not lead back" end
      if target <= HEADER then return nil, "dns: a compression pointer leads into the header" end
      jumps = jumps + 1
      if after == nil then after = pos + 2 end
      local known = cursor.names[target]
      if known ~= nil then
        -- The limits hold for the whole name, what was read before as much as what is read now.
        jumps = jumps + known.jumps
        size = size + known.size - 1
        rest = known
      end
      if jumps > MAX_JUMPS then
        return nil, "dns: a name follows more than 127 compression pointers"
      end
      if size > MAX_NAME then return nil, "dns: a name is longer than 255 bytes" end
      if known ~= nil then break end
      local run: Run = { start = began, first = first, last = #parts, bytes = bytes }
      runs[#runs + 1] = run
      pos, began = target, target
      first, bytes = #parts + 1, 0
    elseif length > MAX_LABEL then
      return nil, "dns: a label starts with reserved bits"
    else
      if pos + length > #data then return nil, "dns: the message ends inside a name" end
      size = size + 1 + length
      bytes = bytes + 1 + length
      if size > MAX_NAME then return nil, "dns: a name is longer than 255 bytes" end
      local label = escaped(data:sub(pos + 1, pos + length))
      parts[#parts + 1] = label
      pos = pos + 1 + length
    end
  end
  cursor.pos = after or pos
  local last: Run = { start = began, first = first, last = #parts, bytes = bytes }
  runs[#runs + 1] = last
  -- From the last run to the first, each is its labels and what follows it. The run that ended at a place
  -- already read, or at the root, followed no pointer of its own but the one that led to that place.
  local text, wire = rest.text, rest.size
  local followed = jumps - (#runs - 1)
  for at = #runs, 1, -1 do
    local run = Array.at(runs, at)
    if run.last >= run.first then
      local labels = table.concat(parts, ".", run.first, run.last)
      text = if text == "" then labels else labels .. "." .. text end
    end
    wire = wire + run.bytes
    cursor.names[run.start] = { text = text, size = wire, jumps = followed }
    followed = followed + 1
  end
  if text == "" then return ".", "" end
  return text, ""
end

--- The fields of a [`Dns.Record`] that hold the data of its type.
local record Typed
  address?: string
  target?: string
  mx?: Dns.Mx
  txt?: {string}
  srv?: Dns.Srv
  soa?: Dns.Soa
end

--- `typed` where the cursor stands at `stop`, the end of the record's data, or nil and why.
local function ended(cursor: Cursor, stop: integer, typed: Typed): Typed?, string
  if cursor.pos ~= stop then
    return nil, "dns: the data of a record is not the length the record gives"
  end
  return typed, ""
end

--- The `length` bytes of data at the cursor, which the message holds, read as the type `type` of the internet
--- class, or nil and why. Another type reads as no field. The cursor moves past the data.
local function read_typed(cursor: Cursor, rtype: integer, length: integer): Typed?, string
  local data, start = cursor.data, cursor.pos
  local stop = start + length
  if rtype == Dns.A or rtype == Dns.AAAA then
    local want = if rtype == Dns.A then 4 else 16 end
    if length ~= want then
      return nil, ("dns: an address record has %s of data where its type has %d"):format(
        String.counted(length, "byte"), want)
    end
    local bytes = data:sub(start, stop - 1)
    cursor.pos = stop
    return { address = if rtype == Dns.A then ipv4_text(bytes) else ipv6_text(bytes) end }, ""
  end
  if rtype == Dns.NS or rtype == Dns.CNAME or rtype == Dns.PTR then
    local target, why = read_name(cursor)
    if target == nil then return nil, why end
    return ended(cursor, stop, { target = target })
  end
  if rtype == Dns.MX then
    if length < 3 then return nil, "dns: an MX record is shorter than its preference and a name" end
    cursor.pos = start + 2
    local exchange, why = read_name(cursor)
    if exchange == nil then return nil, why end
    return ended(cursor, stop, { mx = { preference = u16(data, start), exchange = exchange } })
  end
  if rtype == Dns.TXT then
    local txt: mut {string} = {}
    local pos = start
    while pos < stop do
      local size = String.byte_at(data, pos)
      if pos + size >= stop then return nil, "dns: a string runs past the end of its TXT record" end
      local text = data:sub(pos + 1, pos + size)
      txt[#txt + 1] = text
      pos = pos + 1 + size
    end
    if #txt == 0 then txt[1] = "" end
    cursor.pos = stop
    return { txt = txt }, ""
  end
  if rtype == Dns.SRV then
    if length < 7 then return nil, "dns: an SRV record is shorter than its numbers and a name" end
    cursor.pos = start + 6
    local target, why = read_name(cursor)
    if target == nil then return nil, why end
    return ended(cursor, stop, {
      srv = { priority = u16(data, start), weight = u16(data, start + 2), port = u16(data, start + 4), target = target },
    })
  end
  if rtype == Dns.SOA then
    local mname, mname_why = read_name(cursor)
    if mname == nil then return nil, mname_why end
    local rname, rname_why = read_name(cursor)
    if rname == nil then return nil, rname_why end
    local pos = cursor.pos
    if pos + 20 ~= stop then
      return nil, "dns: an SOA record is not its two names and five numbers"
    end
    cursor.pos = stop
    return {
      soa = {
        mname = mname,
        rname = rname,
        serial = u32(data, pos),
        refresh = u32(data, pos + 4),
        retry = u32(data, pos + 8),
        expire = u32(data, pos + 12),
        minimum = u32(data, pos + 16),
      },
    }, ""
  end
  cursor.pos = stop
  return {}, ""
end

--- The fewest bytes a question takes: the root's name, a type and a class.
local QUESTION_MIN <const> = 5

--- The fewest bytes a record takes: the root's name, a type, a class, a time and the length of no data.
local RECORD_MIN <const> = 11

local function read_records(cursor: Cursor, count: integer): {Dns.Record}?, string
  local data = cursor.data
  local out: mut {Dns.Record} = {}
  for _ = 1, count do
    local name, why = read_name(cursor)
    if name == nil then return nil, why end
    local fixed = cursor.pos
    if fixed + 9 > #data then return nil, "dns: the message ends inside a record" end
    local rtype, class, length = u16(data, fixed), u16(data, fixed + 2), u16(data, fixed + 8)
    local start = fixed + 10
    if start + length - 1 > #data then
      return nil, "dns: the message ends inside the data of a record"
    end
    cursor.pos = start
    local typed: Typed = {}
    if class & 0x7fff == Dns.IN then
      local read, read_why = read_typed(cursor, rtype, length)
      if read == nil then return nil, read_why end
      typed = read
    else
      cursor.pos = start + length
    end
    local record: Dns.Record = {
      name = name,
      type = rtype,
      class = class & 0x7fff,
      cache_flush = class & 0x8000 ~= 0,
      ttl = u32(data, fixed + 4),
      rdata = data:sub(start, start + length - 1),
      address = typed.address,
      target = typed.target,
      mx = typed.mx,
      txt = typed.txt,
      srv = typed.srv,
      soa = typed.soa,
    }
    out[#out + 1] = record
  end
  return out, ""
end

--- The message in the bytes `data`, which may come from anywhere, or nil and why: the bytes end early, the header
--- counts more than they hold, a name is malformed, the data of a record of the internet class is not the shape
--- of its type, or bytes follow the last record. It never raises. Every record has its `rdata`, and the field of
--- its type where the module doc lists one.
function Dns.decode(data: string): Dns.Message?, string
  if #data < HEADER then return nil, "dns: the message is shorter than a header" end
  local flags = u16(data, 3)
  local questions_count, answers_count, authorities_count, additionals_count =
    u16(data, 5), u16(data, 7), u16(data, 9), u16(data, 11)
  -- The counts are another's word: held to what the bytes could hold before anything is read for them.
  if questions_count * QUESTION_MIN + (answers_count + authorities_count + additionals_count) * RECORD_MIN >
      #data - HEADER then
    return nil, "dns: the header counts more questions and records than the message holds"
  end
  local cursor: Cursor = { data = data, pos = HEADER + 1, names = {} }
  local questions: mut {Dns.Question} = {}
  for _ = 1, questions_count do
    local name, why = read_name(cursor)
    if name == nil then return nil, why end
    local fixed = cursor.pos
    if fixed + 3 > #data then return nil, "dns: the message ends inside a question" end
    local class = u16(data, fixed + 2)
    local question: Dns.Question = {
      name = name,
      type = u16(data, fixed),
      class = class & 0x7fff,
      unicast_response = class & 0x8000 ~= 0,
    }
    questions[#questions + 1] = question
    cursor.pos = fixed + 4
  end
  local answers, answers_why = read_records(cursor, answers_count)
  if answers == nil then return nil, answers_why end
  local authorities, authorities_why = read_records(cursor, authorities_count)
  if authorities == nil then return nil, authorities_why end
  local additionals, additionals_why = read_records(cursor, additionals_count)
  if additionals == nil then return nil, additionals_why end
  if cursor.pos ~= #data + 1 then
    return nil, ("dns: the last record is followed by %s"):format(String.counted(#data + 1 - cursor.pos, "byte"))
  end
  return {
    id = u16(data, 1),
    response = flags & 0x8000 ~= 0,
    opcode = flags >> 11 & 0xf,
    authoritative = flags & 0x0400 ~= 0,
    truncated = flags & 0x0200 ~= 0,
    recursion_desired = flags & 0x0100 ~= 0,
    recursion_available = flags & 0x0080 ~= 0,
    authentic_data = flags & 0x0020 ~= 0,
    checking_disabled = flags & 0x0010 ~= 0,
    rcode = flags & 0xf,
    questions = questions,
    answers = answers,
    authorities = authorities,
    additionals = additionals,
  }, ""
end

--- Whether `value` is a number of `bits` bits.
local function fits(value: integer, bits: integer): boolean
  return value >= 0 and value >> bits == 0
end

--- `mask` where `set`, else no bit.
local function bit(set: boolean, mask: integer): integer
  return if set then mask else 0 end
end

--- `value` as two bytes, the high one first.
local function b16(value: integer): string
  return string.char(value >> 8 & 0xff, value & 0xff)
end

--- `value` as four bytes, the high one first.
local function b32(value: integer): string
  return b16(value >> 16) .. b16(value)
end

--- The `rdata` of `record`, or nil and why.
local function raw_rdata(record: Dns.Record): string?, string
  local rdata = record.rdata
  if rdata == nil then
    return nil, ("dns: a record of type %d and class %d has neither the field of its type nor rdata"):format(
      record.type, record.class)
  end
  return rdata, ""
end

--- The data of `record` on the wire: that of the field of its type where it is of the internet class and has
--- the field, else its `rdata`; or nil and why.
local function rdata_of(record: Dns.Record): string?, string
  local rtype = record.type
  local address, target, mx, txt, srv, soa = record.address, record.target, record.mx, record.txt, record.srv,
    record.soa
  -- Another class gives a type's data another shape, so only `rdata` is written for it.
  if record.class ~= Dns.IN then return raw_rdata(record) end
  if (rtype == Dns.A or rtype == Dns.AAAA) and address ~= nil then
    local bytes = if rtype == Dns.A then ipv4_bytes(address) else ipv6_bytes(address) end
    if bytes == nil then
      return nil, ("dns: '%s' is no %s address"):format(address, if rtype == Dns.A then "IPv4" else "IPv6" end)
    end
    return bytes, ""
  elseif (rtype == Dns.NS or rtype == Dns.CNAME or rtype == Dns.PTR) and target ~= nil then
    return wire_name(target)
  elseif rtype == Dns.MX and mx ~= nil then
    if not fits(mx.preference, 16) then
      return nil, "dns: the preference of an MX record is not 0 to 65535"
    end
    local exchange, why = wire_name(mx.exchange)
    if exchange == nil then return nil, why end
    return b16(mx.preference) .. exchange, ""
  elseif rtype == Dns.TXT and txt ~= nil then
    local parts: mut {string} = {}
    for i, text in ipairs(txt) do
      if #text > 255 then
        return nil, ("dns: string %d of a TXT record is %s, and a string holds 255"):format(i,
          String.counted(#text, "byte"))
      end
      parts[i] = string.char(#text) .. text
    end
    if #parts == 0 then return "\0", "" end
    return table.concat(parts), ""
  elseif rtype == Dns.SRV and srv ~= nil then
    if not (fits(srv.priority, 16) and fits(srv.weight, 16) and fits(srv.port, 16)) then
      return nil, "dns: a number of an SRV record is not 0 to 65535"
    end
    local host, why = wire_name(srv.target)
    if host == nil then return nil, why end
    return b16(srv.priority) .. b16(srv.weight) .. b16(srv.port) .. host, ""
  elseif rtype == Dns.SOA and soa ~= nil then
    if not (fits(soa.serial, 32) and fits(soa.refresh, 32) and fits(soa.retry, 32) and fits(soa.expire, 32) and
        fits(soa.minimum, 32)) then
      return nil, "dns: a number of an SOA record is not 0 to 4294967295"
    end
    local mname, mname_why = wire_name(soa.mname)
    if mname == nil then return nil, mname_why end
    local rname, rname_why = wire_name(soa.rname)
    if rname == nil then return nil, rname_why end
    return mname .. rname .. b32(soa.serial) .. b32(soa.refresh) .. b32(soa.retry) .. b32(soa.expire) ..
      b32(soa.minimum), ""
  end
  return raw_rdata(record)
end

--- `record` on the wire, or nil and why.
local function wire_record(record: Dns.Record): string?, string
  local name, why = wire_name(record.name)
  if name == nil then return nil, why end
  if not fits(record.type, 16) then return nil, "dns: the type is not 0 to 65535" end
  if not fits(record.class, 15) then return nil, "dns: the class is not 0 to 32767" end
  if not fits(record.ttl, 32) then return nil, "dns: the ttl is not 0 to 4294967295" end
  local rdata, rdata_why = rdata_of(record)
  if rdata == nil then return nil, rdata_why end
  if #rdata > 65535 then
    return nil, ("dns: the data is %s, and a record holds 65535"):format(String.counted(#rdata, "byte"))
  end
  return name .. b16(record.type) .. b16(record.class | bit(record.cache_flush, 0x8000)) ..
    b32(record.ttl) .. b16(#rdata) .. rdata, ""
end

--- A section of a message under the name a refusal gives it.
local record Section
  what: string
  records: {Dns.Record}
end

--- `message` as bytes, or nil and why: a number does not fit its field, a name is no name, an address is no
--- address of its record's type, a string of a TXT record is over 255 bytes, a record has neither the field of
--- its type nor `rdata`, or the whole is over 65535 bytes. A record of the internet class is written from the
--- field of its type where it has one, whatever its `rdata` says, so a decoded record with a field changed is
--- written as changed; any other record is written from `rdata` as it is. Names are written in full, with no
--- compression.
function Dns.encode(message: Dns.Message): string?, string
  if not fits(message.id, 16) then return nil, "dns: the id is not 0 to 65535" end
  if not fits(message.opcode, 4) then return nil, "dns: the opcode is not 0 to 15" end
  if not fits(message.rcode, 4) then return nil, "dns: the rcode is not 0 to 15" end
  local sections: {Section} = {
    { what = "answer", records = message.answers },
    { what = "authority", records = message.authorities },
    { what = "additional", records = message.additionals },
  }
  local flags = bit(message.response, 0x8000) | message.opcode << 11 | bit(message.authoritative, 0x0400) |
    bit(message.truncated, 0x0200) | bit(message.recursion_desired, 0x0100) |
    bit(message.recursion_available, 0x0080) | bit(message.authentic_data, 0x0020) |
    bit(message.checking_disabled, 0x0010) | message.rcode
  if #message.questions > 65535 then return nil, "dns: a message holds 65535 questions at most" end
  local parts: mut {string} = { b16(message.id) .. b16(flags) .. b16(#message.questions) }
  for _, section in ipairs(sections) do
    if #section.records > 65535 then
      return nil, ("dns: a message holds 65535 %s records at most"):format(section.what)
    end
    local count = b16(#section.records)
    parts[#parts + 1] = count
  end
  for i, question in ipairs(message.questions) do
    local name, why = wire_name(question.name)
    if name == nil then return nil, ("dns: question %d: %s"):format(i, why) end
    if not fits(question.type, 16) then
      return nil, ("dns: question %d: the type is not 0 to 65535"):format(i)
    end
    if not fits(question.class, 15) then
      return nil, ("dns: question %d: the class is not 0 to 32767"):format(i)
    end
    local bytes = name .. b16(question.type) .. b16(question.class | bit(question.unicast_response, 0x8000))
    parts[#parts + 1] = bytes
  end
  for _, section in ipairs(sections) do
    for i, record in ipairs(section.records) do
      local bytes, why = wire_record(record)
      if bytes == nil then return nil, ("dns: %s %d: %s"):format(section.what, i, why) end
      parts[#parts + 1] = bytes
    end
  end
  local out = table.concat(parts)
  if #out > MAX_MESSAGE then
    return nil, ("dns: the message is %s, and a message holds 65535"):format(String.counted(#out, "byte"))
  end
  return out, ""
end

--- The query that asks for the records of type `rtype` and the internet class at `name`, with the identifier
--- `id` and recursion desired, as a resolver's client sends it. Multicast DNS sends an `id` of 0; a query sent to a
--- server needs one that cannot be guessed, since the id is how its answer is told from a forged one.
function Dns.query(name: string, rtype: integer, id: integer): Dns.Message
  return {
    id = id,
    response = false,
    opcode = 0,
    authoritative = false,
    truncated = false,
    recursion_desired = true,
    recursion_available = false,
    authentic_data = false,
    checking_disabled = false,
    rcode = 0,
    questions = { { name = name, type = rtype, class = Dns.IN, unicast_response = false } },
    answers = {},
    authorities = {},
    additionals = {},
  }
end

--- The response to `query` with nothing in it yet: its id, opcode, its recursion-desired and checking-disabled
--- bits and its questions repeated, in a list of its own, with no error and no records. A server fills in the rest with a spread:
--- `{ ...Dns.reply(query), authoritative = true, answers = records }`.
function Dns.reply(query: Dns.Message): Dns.Message
  return {
    id = query.id,
    response = true,
    opcode = query.opcode,
    authoritative = false,
    truncated = false,
    recursion_desired = query.recursion_desired,
    recursion_available = false,
    authentic_data = false,
    checking_disabled = query.checking_disabled,
    rcode = 0,
    questions = table.move(query.questions, 1, #query.questions, 1, {}),
    answers = {},
    authorities = {},
    additionals = {},
  }
end

return Dns
