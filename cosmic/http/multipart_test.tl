--- cosmic.http.multipart: browser-shaped bodies, the delimiter split across
--- reads, and each way a hostile body is refused.

local Clock = require("cosmic.clock")
local Multipart = require("cosmic.http.multipart")
local Stream = require("cosmic.stream")

local B <const> = "----WebKitFormBoundary7MA4YWxkTrZu0gW"

--- A Reader over `text` that hands out at most `n` bytes a read.
local function drip(text: string, n: integer): Stream.Reader
  local inner = Stream.from_string(text)
  local r: Stream.Reader = {
    read = function(_self: Stream.Reader, max?: integer): string?, string
      return inner:read(math.min(n, max or n))
    end,
    close = function(_self: Stream.Reader): boolean, string return inner:close() end,
  }
  return r
end

--- One part as a browser writes it.
local function part(disposition: string, body: string, extra?: string): string
  return "--" .. B .. "\r\nContent-Disposition: " .. disposition .. "\r\n" .. (extra or "") .. "\r\n" .. body .. "\r\n"
end

local function close_it(): string return "--" .. B .. "--\r\n" end

local record Seen
  name: string
  filename?: string
  content_type: string
  body: string
end

--- Every part of `text` read to the end, or the reason the body is refused.
local function parse(text: string, n?: integer, opts?: Multipart.Options): {Seen}?, string
  local given = opts or {}
  local o: Multipart.Options = { boundary = given.boundary or B, max_parts = given.max_parts,
    max_header_bytes = given.max_header_bytes, max_header_lines = given.max_header_lines }
  local reader, bad = Multipart.reader(drip(text, n or 7), o)
  if reader == nil then return nil, bad end
  local out: mut {Seen} = {}
  while true do
    local got, why = reader:next_part()
    if got == nil then
      if why ~= "" then return nil, why end
      return out, ""
    end
    local data, trouble = Stream.read_all(got.body)
    if data == nil then return nil, trouble end
    out[#out + 1] = { name = got.name, filename = got.filename, content_type = got.content_type, body = data }
  end
end

--- The reason `text` is refused for, failing when it parses.
local function refused(text: string, opts?: Multipart.Options): string
  local got, why = parse(text, 5, opts)
  assert(got == nil, "parsed: " .. text)
  assert(why:find("^multipart: "), why)
  return why
end

local function test_a_browser_body_is_read_whole()
  local text = part('form-data; name="title"', "hello") ..
    part('form-data; name="pic"; filename="a b.png"', "\0\1\255\r\n--x\r\n", "Content-Type: image/png\r\n") ..
    close_it()
  for _, n in ipairs({ 1, 2, 3, 7, 64, 100000 }) do
    local got = assert(parse(text, n))
    assert(#got == 2, n)
    assert(got[1].name == "title" and got[1].filename == nil and got[1].body == "hello")
    assert(got[1].content_type == "text/plain")
    assert(got[2].name == "pic" and got[2].filename == "a b.png" and got[2].content_type == "image/png")
    assert(got[2].body == "\0\1\255\r\n--x\r\n", n)
  end
end

local function test_a_part_may_be_empty_and_a_body_may_have_no_parts()
  local got = assert(parse(part('form-data; name="e"', "") .. close_it()))
  assert(#got == 1 and got[1].body == "")
  local none = assert(parse(close_it()))
  assert(#none == 0)
end

local function test_a_preamble_and_an_epilogue_are_ignored()
  local text = "this is a preamble\r\nwith lines\r\n" .. part('form-data; name="a"', "1") .. close_it() ..
    "epilogue --" .. B .. " junk"
  local got = assert(parse(text))
  assert(#got == 1 and got[1].body == "1")
  assert(refused(string.rep("p", 200) .. part('form-data; name="a"', "1"), { max_header_bytes = 64 }):find("no boundary"))
  assert(parse(string.rep("p", 64) .. "\r\n" .. part('form-data; name="a"', "1") .. close_it(), 100, { max_header_bytes = 64 }))
  assert(refused(string.rep("p", 65) .. "\r\n" .. part('form-data; name="a"', "1"), { max_header_bytes = 64 }):find("no boundary"))
end

local function test_the_boundary_inside_data_is_data_but_a_delimiter_line_is_not()
  local inside = "x--" .. B .. "y\r\n--" .. B:sub(1, -2) .. "\r\n-" .. B
  local got = assert(parse(part('form-data; name="a"', inside) .. close_it(), 3))
  local only = assert(got[1], "expected a part")
  assert(only.body == inside)
  refused(part('form-data; name="a"', "data\r\n--" .. B .. "x more") .. close_it())
end

local function test_a_boundary_must_be_short_and_plain()
  local ok = {
    "a", string.rep("b", 70), "a b", "'()+_,-./:=?", B,
  }
  for _, b in ipairs(ok) do
    assert(Multipart.reader(Stream.from_string(""), { boundary = b }), b)
  end
  local bad = { "", string.rep("b", 71), "a ", "a\r\nb", "a\0b", 'a"b', "a;b", "é", "a<b" }
  for _, b in ipairs(bad) do
    local r, why = Multipart.reader(Stream.from_string(""), { boundary = b })
    assert(r == nil and why:find("boundary") ~= nil, b)
  end
  assert(not pcall(Multipart.reader, Stream.from_string(""), { boundary = "a", max_parts = 0 }))
end

local function test_a_body_without_its_closing_boundary_is_truncated()
  assert(refused(part('form-data; name="a"', "1")):find("before the closing boundary"))
  assert(refused("--" .. B .. "\r\nContent-Disposition: form-data; name=\"a\"\r\n"):find("before the closing"))
  assert(refused("--" .. B .. "\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nabc\r\n--" .. B:sub(1, 5)))
  assert(refused(""):find("no boundary"))
  assert(refused("--" .. B):find("before the closing"))
  assert(refused("--" .. B .. "xx"):find("neither"))
end

local function test_lines_end_in_crlf_only()
  local lf = "--" .. B .. "\nContent-Disposition: form-data; name=\"a\"\n\n1\n--" .. B .. "--\n"
  refused(lf)
  refused("--" .. B .. "\r\nContent-Disposition: form-data; name=\"a\"\n\r\n1\r\n--" .. B .. "--")
  refused("--" .. B .. "\r\nContent-Disposition: form-data; name=\"a\"\rX: y\r\n\r\n1\r\n--" .. B .. "--")
end

local function test_part_headers_that_could_smuggle_are_refused()
  local function with(headers: string): string
    return "--" .. B .. "\r\n" .. headers .. "\r\n\r\nv\r\n--" .. B .. "--"
  end
  local cd = 'Content-Disposition: form-data; name="a"'
  assert(parse(with(cd)))
  assert(refused(with(cd .. "\r\n" .. cd)):find("twice"))
  assert(refused(with(cd .. "\r\ncontent-disposition: form-data; name=\"b\"")):find("twice"))
  assert(refused(with(cd .. "\r\n folded")):find("folded"))
  assert(refused(with(cd .. "\r\n\tfolded")):find("folded"))
  assert(refused(with(cd .. "\r\nX-A: b\0c")):find("control"))
  assert(refused(with(cd .. "\r\nX-A: b\127")):find("control"))
  assert(refused(with(cd .. "\r\nno colon")):find("malformed"))
  assert(refused(with(cd .. "\r\nX A: b")):find("malformed"))
  assert(refused(with("X-A: b")):find("no Content%-Disposition"))
  assert(refused(with("")):find("no headers"))
  assert(refused(with("Content-Disposition: attachment; name=\"a\"")):find("not form%-data"))
  assert(refused(with("Content-Disposition: form-data")):find("no name"))
  assert(refused(with(cd .. "\r\nContent-Transfer-Encoding: base64")):find("retired"))
  assert(refused(with(cd .. "\r\nContent-Transfer-Encoding: quoted-printable")):find("retired"))
  assert(parse(with(cd .. "\r\nContent-Transfer-Encoding: 8BIT")))
  local many = cd
  for i = 1, 15 do many = many .. ("\r\nX-%d: b"):format(i) end
  assert(parse(with(many)))
  assert(refused(with(many .. "\r\nX-B: c")):find("too many header lines"))
  assert(refused(with(cd .. "\r\nX-A: " .. string.rep("z", 9000))):find("longer than max_header_bytes"))
  assert(refused(with(cd .. "\r\nX-A: " .. string.rep("z", 100)), { max_header_bytes = 64 }):find("max_header_bytes"))
end

local function test_disposition_parameters_are_read_as_browsers_write_them()
  local function one(disposition: string): Seen
    local got = assert(parse(part(disposition, "v") .. close_it()))
    local only = assert(got[1], "expected a part")
    return only
  end
  assert(one('form-data; name="a"').name == "a")
  assert(one('FORM-DATA;NAME=a').name == "a")
  assert(one('form-data;  name = "a b" ;filename="x"').filename == "x")
  assert(one('form-data; name="q%22uote"').name == 'q"uote')
  assert(one('form-data; name="a\\b"').name == "a\\b")
  assert(one('form-data; name="a;b=c"; filename="x"').name == "a;b=c")
  assert(one('form-data; name=""').name == "")
  assert(one('form-data; name="é"').name == "é")
  assert(refused(part('form-data; name="a"; name="b"', "v")):find("twice"))
  assert(refused(part('form-data; name="a"; filename="x"; FileName="y"', "v")):find("twice"))
  assert(refused(part('form-data; name="a', "v")):find("quote"))
  assert(refused(part('form-data; name="a"x', "v")):find("malformed"))
  assert(refused(part('form-data; name="a";', "v")):find("malformed"))
  assert(refused(part('form-data; name', "v")):find("malformed"))
  assert(refused(part('form-data; name="a%0Ab"', "v")):find("control"))
  assert(refused(part('form-data; name="a\1b"', "v")):find("control"))
  assert(refused(part('form-data; name="\255"', "v")):find("UTF%-8"))
end

local function test_a_filename_is_metadata_reduced_to_a_basename()
  local function name_of(disposition: string): string?
    local got = assert(parse(part('form-data; name="f"; ' .. disposition, "v") .. close_it()))
    local only = assert(got[1], "expected a part")
    return only.filename
  end
  assert(name_of('filename="report.pdf"') == "report.pdf")
  assert(name_of('filename="../../etc/passwd"') == "passwd")
  assert(name_of('filename="..\\..\\windows\\system32\\x.dll"') == "x.dll")
  assert(name_of('filename="C:\\fakepath\\a.txt"') == "a.txt")
  assert(name_of('filename="/abs/path/a.txt"') == "a.txt")
  assert(name_of('filename=""') == "")
  assert(name_of('filename=".htaccess"') == ".htaccess")
  assert(name_of('filename="..%22"') == '..' .. '"')
  assert(name_of('filename="é.txt"') == "é.txt")
  assert(name_of('filename=a.txt') == "a.txt")
  assert(name_of("filename*=UTF-8''%E2%82%AC%20rates.txt") == "€ rates.txt")
  assert(name_of("filename*=iso-8859-1'en'%E9.txt") == "é.txt")
  assert(name_of("filename*=UTF-8''..%2F..%2Fx.txt") == "x.txt")
  assert(name_of("filename*=UTF-8''100%25.txt") == "100%.txt", "a decoded percent is a percent")
  assert(name_of("filename=\"plain.txt\"; filename*=UTF-8''other.txt") == "plain.txt")
  assert(name_of('filename="' .. string.rep("a", 255) .. '"') == string.rep("a", 255))
  assert(name_of("filename*=UTF-8''" .. string.rep("a", 255)) == string.rep("a", 255))
  local function bad(disposition: string, wanted: string)
    local why = refused(part('form-data; name="f"; ' .. disposition, "v") .. close_it())
    assert(why:find(wanted), why)
  end
  bad('filename="a\0.jpg"', "control")
  bad('filename="a%0Ab"', "control")
  bad('filename="a%0Db"', "control")
  bad('filename="a\1b"', "control")
  bad('filename="a\127b"', "control")
  bad('filename="a\tb"', "control")
  bad('filename="' .. string.rep("a", 256) .. '"', "255")
  bad('filename="\255"', "UTF%-8")
  bad("filename*=UTF-8''a%00.jpg", "control")
  bad("filename*=UTF-8''a%0Ab", "control")
  bad("filename*=UTF-8''%ff", "UTF%-8")
  bad("filename*=UTF-8''a%2", "escape")
  bad('filename="dir/"', "directory")
  bad('filename="C:\\dir\\"', "directory")
  bad("filename*=UTF-8''dir%2F", "directory")
  bad("filename*=UTF-8''a%zz", "escape")
  bad("filename*=utf-16''a", "charset other")
  bad("filename*=a.txt", "charset'language'value")
end

local function test_the_part_count_is_capped()
  local text = ""
  for i = 1, 5 do text = text .. part(('form-data; name="f%d"'):format(i), "v") end
  text = text .. close_it()
  assert(#assert(parse(text, 9, { max_parts = 5 })) == 5)
  assert(refused(text, { max_parts = 4 }):find("max_parts"))
end

local function test_an_unread_part_is_skipped_and_a_passed_one_is_dead()
  local text = part('form-data; name="big"; filename="b"', string.rep("0123456789", 5000)) ..
    part('form-data; name="next"', "n") .. close_it()
  local reader = assert(Multipart.reader(drip(text, 100), { boundary = B }))
  local first = assert(reader:next_part())
  assert(first.name == "big")
  local head = assert(first.body:read(10))
  assert(head == "0123456789")
  local second = assert(reader:next_part())
  assert(second.name == "next")
  local nothing, why = first.body:read()
  assert(nothing == nil and why:find("passed by next_part") ~= nil, why)
  assert(assert(Stream.read_all(second.body)) == "n")
  assert(reader:next_part() == nil)
  local again, ended = reader:next_part()
  assert(again == nil and ended == "")
  local done = assert(Multipart.reader(drip(part('form-data; name="a"', "x") .. close_it(), 3), { boundary = B }))
  local only = assert(done:next_part())
  assert(assert(Stream.read_all(only.body)) == "x")
  assert(done:next_part() == nil)
  local eof, eof_why = only.body:read()
  assert(eof == nil and eof_why == "")
end

local function test_a_failed_parser_stays_failed_and_a_part_body_reports_it()
  local text = "--" .. B .. "\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nabc"
  local reader = assert(Multipart.reader(drip(text, 4), { boundary = B }))
  local got = assert(reader:next_part())
  local data, why = Stream.read_all(got.body)
  assert(data == nil and why:find("before the closing") ~= nil, why)
  local next_got, again = reader:next_part()
  assert(next_got == nil and again:find("before the closing") ~= nil)
  assert(reader:close())
  assert(not pcall(got.body.read, got.body, 0))
end

local function test_a_source_failure_is_passed_on_as_it_was_given()
  local sent: boolean = false
  local source: Stream.Reader = {
    read = function(_self: Stream.Reader, _max?: integer): string?, string
      if sent then return nil, "boom" end
      sent = true
      return "--" .. B .. "\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nab", ""
    end,
    close = function(_self: Stream.Reader): boolean, string return true, "" end,
  }
  local reader = assert(Multipart.reader(source, { boundary = B }))
  local got = assert(reader:next_part())
  local data, why = got.body:read(100)
  assert(data == nil and why == "boom", tostring(why))
  local _, again = reader:next_part()
  assert(again == "boom", again)
end

local function test_a_large_part_streams_in_bounded_pieces()
  local size = 1024 * 1024
  local body = string.rep("abcdefghijklmnop", size // 16)
  local text = part('form-data; name="f"; filename="big"', body) .. close_it()
  local reader = assert(Multipart.reader(drip(text, 65536), { boundary = B }))
  local got = assert(reader:next_part())
  local total, largest = 0, 0
  while true do
    local chunk = got.body:read()
    if chunk == nil then break end
    total = total + #chunk
    largest = math.max(largest, #chunk)
  end
  assert(total == size, total)
  assert(largest <= 16384, largest)
end

local function test_trailing_whitespace_is_trimmed_in_time_linear_in_the_run()
  local spaces = string.rep(" ", 8000)
  local one = part('form-data; name="a"; x=a' .. spaces .. "y", "v", "X-Pad: v" .. spaces .. "y\r\n")
  local start = Clock.monotonic_ns()
  for _ = 1, 100 do
    local got, why = parse(one .. close_it(), 100000, { max_header_bytes = 20000 })
    assert(got ~= nil and #got == 1, why)
  end
  local took = Clock.monotonic_ns() - start
  assert(took < Clock.seconds(2), "trailing blanks cost " .. tostring(took // 1000000) .. " ms")
  local padded = assert(parse(part('form-data; name="a"; x=b   ', "v", "X-Pad: v \t \r\n") .. close_it()))
  local only = assert(padded[1], "expected a part")
  assert(only.name == "a")
end

local function test_a_closed_parser_hands_out_no_more_of_a_part()
  local reader = assert(Multipart.reader(Stream.from_string(part('form-data; name="a"', "value") .. close_it()),
    { boundary = B }))
  local first = assert(reader:next_part())
  assert(reader:close())
  local data, why = first.body:read()
  assert(data == nil and why:find("closed") ~= nil, why)
end
