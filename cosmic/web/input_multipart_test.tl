--- cosmic.web.input's multipart bodies: the text parts bind as a form's
--- fields do, file parts are spooled under random names and removed when
--- the request ends, and each limit and each malformed body has its status.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Input = require("cosmic.web.input")
local Poll = require("cosmic.poll")
local Server = require("cosmic.http.server")
local Shape = require("cosmic.shape")
local Stream = require("cosmic.stream")
local Types = require("cosmic.web.types")
local Url = require("cosmic.url")
local Web = require("cosmic.web")

--- Why `invalid` refuses, or nil for none.
local function message_of(invalid: Types.Invalid | nil): string | nil
  if invalid == nil then return nil end
  return invalid.message
end

local B <const> = "----boundary123"
local FORM_TYPE <const> = "multipart/form-data; boundary=" .. B

local record Signup
  email: string
  age: integer | nil
  tags: {string}
  news: boolean
end
local SIGNUP <const> = Shape.record_of("Signup")

local function field(name: string, value: string, extra?: string): string
  return "--" .. B .. '\r\nContent-Disposition: form-data; name="' .. name .. '"\r\n' .. (extra or "") .. "\r\n" ..
    value .. "\r\n"
end

local function file(name: string, filename: string, data: string, content_type?: string): string
  return "--" .. B .. '\r\nContent-Disposition: form-data; name="' .. name .. '"; filename="' .. filename ..
    '"\r\nContent-Type: ' .. (content_type or "application/octet-stream") .. "\r\n\r\n" .. data .. "\r\n"
end

local function body_of(...: string): string
  return table.concat({ ... }) .. "--" .. B .. "--\r\n"
end

--- A POST of `body` to an app whose one route is `fn`; the reply.
local function post(body: string, fn: function(req: Web.Request): Web.Response, content_type?: string,
                    chunked?: boolean): Web.Response
  local app = Web.app{ routes = { Web.post("/x", fn) }, sink = { line = function(_self: Web.Sink, _text: string)
  end } }
  local raw: Server.Request = { method = "POST", target = "/x", path = "/x", query = "", version = "HTTP/1.1",
    headers = { host = "x", ["content-type"] = content_type or FORM_TYPE },
    body = Stream.from_string(body), length = not chunked and #body or nil }
  return app.handle(raw)
end

--- The refusal reading `body` with `opts` gives, failing where it is read.
local function refusal(body: string, opts?: Types.InputOptions, content_type?: string, chunked?: boolean): Types.Invalid
  local got: Types.Invalid | nil = nil
  local reply = post(body, function(req: Web.Request): Web.Response
    local read = Input.multipart(req, opts)
    got = read.invalid
    return Web.empty()
  end, content_type, chunked)
  assert(reply.status == 204, reply.status)
  assert(got ~= nil, "read: " .. body:sub(1, 80))
  return got
end

local function test_text_and_file_parts_are_read_and_the_file_is_spooled(tmp: string)
  local seen: Input.Multipart | nil = nil
  local contents: string
  local listing: {string}
  local stat_mode: integer
  local reply = post(body_of(
    field("email", "a@b.test"), field("tags", "x"), field("tags", "y"),
    file("avatar", "../../etc/passwd", "PNG\0\r\n--data", "image/png")), function(req: Web.Request): Web.Response
      local read = Input.multipart(req, { dir = tmp })
      assert(read.invalid == nil, message_of(read.invalid))
      local value = assert(read.value)
      seen = value
      local up = value.files["avatar"][1]
      contents = assert(Fs.read(up.path))
      listing = assert(Fs.list(tmp))
      stat_mode = assert(Fs.stat(up.path)).mode & 0x1ff
      return Web.empty()
    end)
  assert(reply.status == 204)
  local read = assert(seen, "the handler never ran")
  assert(read.fields.by_name["email"][1] == "a@b.test" and #read.fields.by_name["tags"] == 2)
  local up = read.files["avatar"][1]
  assert(up.filename == "passwd" and up.content_type == "image/png" and up.size == 12 and up.field == "avatar")
  assert(contents == "PNG\0\r\n--data")
  assert(#listing == 1 and listing[1]:find("^%x+$") and #listing[1] == 32, "a random name: " .. tostring(listing[1]))
  assert(up.path == tmp .. "/" .. listing[1], "the client's name is no part of the path")
  assert(stat_mode == 384, "mode 0600")
  assert(read.size > 100)
  assert(#assert(Fs.list(tmp)) == 0, "removed when the request ended")
  assert(Fs.exists(up.path) == false)
end

local function test_without_a_dir_a_private_directory_is_made_and_removed()
  local where: string
  post(body_of(file("f", "a.txt", "hello")), function(req: Web.Request): Web.Response
    local up = assert(Input.multipart(req).value).files["f"][1]
    where = up.path
    assert(Fs.exists(where) == true)
    return Web.empty()
  end)
  assert(where:find("cosmic%-upload%-") ~= nil, where)
  assert(Fs.exists(where) == false)
  local dir = where:match("^(.*)/[^/]+$")
  assert(Fs.exists(dir) == false, "the directory went with its files")
end

local function test_a_handler_that_keeps_a_file_moves_it(tmp: string)
  local kept = tmp .. "/kept.bin"
  post(body_of(file("f", "a.txt", "keep me")), function(req: Web.Request): Web.Response
    local up = assert(Input.multipart(req).value).files["f"][1]
    assert(Fs.rename(up.path, kept))
    return Web.empty()
  end)
  assert(assert(Fs.read(kept)) == "keep me")
end

local function test_files_are_removed_when_the_handler_raises_or_discards(tmp: string)
  local reply = post(body_of(file("f", "a", "x"), file("g", "b", "y")), function(req: Web.Request): Web.Response
    local m = assert(Input.multipart(req, { dir = tmp }).value)
    assert(#assert(Fs.list(tmp)) == 2)
    m:discard()
    assert(#assert(Fs.list(tmp)) == 0)
    m:discard()
    error("handler fault")
  end)
  assert(reply.status == 500)
  reply = post(body_of(file("f", "a", "x")), function(req: Web.Request): Web.Response
    assert(Input.multipart(req, { dir = tmp }).value)
    error("handler fault")
  end)
  assert(reply.status == 500 and #assert(Fs.list(tmp)) == 0, "removed though the handler raised")
end

local function test_a_blank_file_input_is_not_a_file(tmp: string)
  local m: Input.Multipart
  post(body_of(file("none", "", ""), file("empty", "e.txt", ""), file("noname", "", "data")),
    function(req: Web.Request): Web.Response
      m = assert(Input.multipart(req, { dir = tmp }).value)
      return Web.empty()
    end)
  assert(m.files["none"] == nil)
  assert(m.files["empty"][1].size == 0 and m.files["empty"][1].filename == "e.txt")
  assert(m.files["noname"][1].filename == "" and m.files["noname"][1].size == 4)
end

local function test_the_text_parts_bind_as_a_forms_fields_do()
  local bound: Signup
  local reply = post(body_of(field("email", "a@b.test"), field("age", " 42 "), field("tags", "x"), field("tags", "y"),
    field("news", "on"), field("is_admin", "1"), file("avatar", "me.png", "x")), function(req: Web.Request): Web.Response
      local read = Input.form_into(req, SIGNUP)
      bound = assert(read.value, message_of(read.invalid))
      assert(assert(Input.multipart(req).value).files["avatar"][1].filename == "me.png", "the files are still there")
      return Web.empty()
    end)
  assert(reply.status == 204)
  assert(bound.email == "a@b.test" and bound.age == 42 and #bound.tags == 2 and bound.news)
end

local function test_a_multipart_form_fails_its_spec_with_a_forms_errors()
  local function errors_of(read: function(req: Web.Request): Types.Parsed<Signup>): Types.Invalid
    local bad: Types.Invalid
    post(body_of(field("age", "x"), field("password", "hunter2")), function(req: Web.Request): Web.Response
      bad = read(req).invalid
      return Web.empty()
    end)
    return bad
  end
  local via_form = errors_of(function(req: Web.Request): Types.Parsed<Signup>
    return Input.form_into(req, SIGNUP, { secret = { "password" } })
  end)
  local via_multipart = errors_of(function(req: Web.Request): Types.Parsed<Signup>
    return Input.multipart_into(req, SIGNUP, { secret = { "password" } })
  end)
  for _, bad in ipairs({ via_form, via_multipart }) do
    assert(bad.status == 422 and #bad.errors == 2 and bad.errors[1].source == "form", bad.message)
    assert(bad.errors[1].field == "age" and bad.errors[1].code == "integer", bad.errors[1].field)
    assert(bad.errors[2].field == "email" and bad.errors[2].code == "required")
    assert(Input.value(bad, "age") == "x" and Input.value(bad, "password") == "", "the secret is left out")
  end
end

local function test_a_typed_multipart_route_binds_and_answers_problems(tmp: string)
  local got: Signup
  local files = 0
  local app = Web.app{ routes = {
    Web.post_typed("/up", Web.input(Web.NONE, Web.NONE, Web.multipart_body(SIGNUP)),
      function(req: Web.Request, _p: Web.None, _q: Web.None, b: Signup): Web.Response
        got = b
        files = #assert(Input.multipart(req).value).files["pic"]
        return Web.empty()
      end, { input_options = { dir = tmp, max_file_bytes = 10 } }),
  }, sink = { line = function(_self: Web.Sink, _text: string) end } }
  local client = Web.test_client(app)
  local ok_body = body_of(field("email", "e"), field("news", "0"), file("pic", "p.png", "0123456789"))
  local reply = client:post("/up", { body = ok_body, headers = { ["Content-Type"] = FORM_TYPE } })
  assert(reply.status == 204 and got.email == "e" and files == 1, reply.status)
  assert(#assert(Fs.list(tmp)) == 0)
  reply = client:post("/up", { body = body_of(field("age", "x")), headers = { ["Content-Type"] = FORM_TYPE,
    Accept = "application/json" } })
  assert(reply.status == 422 and reply:text():find('"field":"age"', 1, true), reply:text())
  reply = client:post("/up", { form = { email = "e" } })
  assert(reply.status == 415, "a urlencoded body is not multipart: " .. reply.status)
  reply = client:post("/up", { body = body_of(field("email", "e"), file("pic", "p.png", "0123456789A")),
    headers = { ["Content-Type"] = FORM_TYPE } })
  assert(reply.status == 413, reply.status)
  reply = client:post("/up", { body = "--" .. B .. "\r\n", headers = { ["Content-Type"] = FORM_TYPE } })
  assert(reply.status == 400, reply.status)
  assert(#assert(Fs.list(tmp)) == 0, "nothing is left by a refusal")
end

local function test_a_typed_route_registers_a_multipart_spec_text_can_carry()
  local ok = pcall(Web.post_typed, "/up", Web.input(Web.NONE, Web.NONE,
    Web.multipart_body(Shape.record_of("Signup"))), function(_req: Web.Request): Web.Response
      return Web.empty()
    end)
  assert(ok)
  local bad = pcall(Web.get_typed, "/up", Web.input(Web.NONE, Web.NONE, Web.multipart_body(SIGNUP)),
    function(_req: Web.Request): Web.Response return Web.empty() end)
  assert(not bad, "GET takes no body")
end

local function test_a_form_route_takes_multipart_within_its_own_small_limit(tmp: string)
  local text = body_of(field("email", "e"), file("f", "a", ("x"):rep(70000)))
  local status = 0
  post(text, function(req: Web.Request): Web.Response
    status = assert(Input.form(req, { dir = tmp }).invalid).status
    return Web.empty()
  end)
  assert(status == 413, "a form's 64 KiB default is not the upload's")
  local fields: Types.Parsed<Url.Query>
  post(text, function(req: Web.Request): Web.Response
    fields = Input.form(req, { dir = tmp, max_bytes = 100000 })
    return Web.empty()
  end)
  assert(fields.invalid == nil)
  assert(#assert(Fs.list(tmp)) == 0)
end

local function test_a_file_over_its_cap_is_413_and_leaves_nothing(tmp: string)
  local bad = refusal(body_of(field("a", "1"), file("f", "big", ("z"):rep(2000))), { dir = tmp, max_file_bytes = 1999 })
  assert(bad.status == 413 and bad.errors[1].code == "too_large", bad.message)
  assert(#assert(Fs.list(tmp)) == 0, "the partial file and the staging file are gone")
  local fits = post(body_of(file("f", "big", ("z"):rep(2000))), function(req: Web.Request): Web.Response
    assert(Input.multipart(req, { dir = tmp, max_file_bytes = 2000 }).invalid == nil)
    return Web.empty()
  end)
  assert(fits.status == 204)
  local earlier = refusal(body_of(file("f", "ok", "fine"), file("g", "big", ("z"):rep(50))), { dir = tmp, max_file_bytes = 10 })
  assert(earlier.status == 413 and #assert(Fs.list(tmp)) == 0, "an earlier file went too")
end

local function test_a_text_part_over_its_cap_is_413_before_it_is_all_held()
  local bad = refusal(body_of(field("t", ("z"):rep(1000))), { max_field_bytes = 999 })
  assert(bad.status == 413 and bad.errors[1].code == "too_large")
  assert(#bad.message < 200 and not bad.message:find("zzz"), "no user data echoed")
end

local function test_the_part_and_file_counts_are_capped(tmp: string)
  local text = ""
  for i = 1, 4 do text = text .. field("f" .. i, "v") end
  local bad = refusal(body_of(text), { max_parts = 3 })
  assert(bad.status == 413 and bad.errors[1].code == "too_many")
  local two = refusal(body_of(file("a", "a", "1"), file("b", "b", "2"), file("c", "c", "3")), { dir = tmp, max_files = 2 })
  assert(two.status == 413 and two.errors[1].code == "too_many" and #assert(Fs.list(tmp)) == 0)
end

local function test_the_total_is_capped_by_length_and_when_chunked(tmp: string)
  local text = body_of(field("a", ("x"):rep(500)), file("f", "f", ("y"):rep(500)))
  local by_length = refusal(text, { dir = tmp, max_bytes = 900 })
  assert(by_length.status == 413 and by_length.errors[1].code == "too_large")
  local chunked = refusal(text, { dir = tmp, max_bytes = 900 }, nil, true)
  assert(chunked.status == 413 and #assert(Fs.list(tmp)) == 0)
  local exact = post(text, function(req: Web.Request): Web.Response
    assert(Input.multipart(req, { dir = tmp, max_bytes = #text }).invalid == nil)
    return Web.empty()
  end, nil, true)
  assert(exact.status == 204, "a body of exactly the limit is read")
end

local function test_a_body_not_read_by_length_is_not_pulled_past_the_limit()
  local pulled = 0
  local body: Stream.Reader = {
    read = function(_self: Stream.Reader, max?: integer): string | nil, string
      pulled = pulled + (max or 0)
      return ("a"):rep(math.min(max or 100, 100)), ""
    end,
    close = function(_self: Stream.Reader): boolean, string return true, "" end,
  }
  local app = Web.app{ routes = { Web.post("/x", function(req: Web.Request): Web.Response
    local bad = Input.multipart(req, { max_bytes = 1000 }).invalid
    assert(bad ~= nil and bad.status == 413, "the limit comes before the preamble cap")
    return Web.empty()
  end) } }
  local raw: Server.Request = { method = "POST", target = "/x", path = "/x", query = "", version = "HTTP/1.1",
    headers = { host = "x", ["content-type"] = FORM_TYPE }, body = body }
  assert(app.handle(raw).status == 204)
  assert(pulled <= 20000, pulled)
end

local function test_the_content_type_decides_415_and_a_bad_boundary_400()
  local ok_body = body_of(field("a", "1"))
  assert(refusal(ok_body, nil, "application/x-www-form-urlencoded").status == 415)
  assert(refusal(ok_body, nil, "multipart/mixed; boundary=" .. B).status == 415)
  local none = refusal(ok_body, nil, "")
  assert(none.status == 415)
  for _, ct in ipairs({ "multipart/form-data", "multipart/form-data; boundary=", "multipart/form-data; charset=utf-8",
      "multipart/form-data; boundary=" .. B .. "; boundary=other", 'multipart/form-data; boundary="' .. B .. '"; Boundary=x',
      "multipart/form-data; boundary=" .. ("b"):rep(71) }) do
    local bad = refusal(ok_body, nil, ct)
    assert(bad.status == 400, ct)
  end
  local quoted = post(ok_body, function(req: Web.Request): Web.Response
    assert(Input.multipart(req).invalid == nil)
    return Web.empty()
  end, 'MULTIPART/Form-Data; Boundary="' .. B .. '"')
  assert(quoted.status == 204, "a quoted boundary and any case")
end

local function test_a_malformed_body_is_400(tmp: string)
  local cases: {string} = {
    "--" .. B .. "\r\n",
    body_of(field("a", "1")):sub(1, -6),
    "no boundary here",
    body_of(field("t", "\255\254")),
    body_of(file("f", "a\0.jpg", "x")),
    body_of(file("f", "a%0Ab.jpg", "x")),
    body_of('--' .. B .. '\r\nContent-Disposition: attachment; name="a"\r\n\r\nx\r\n'),
    body_of(field("a", "1", "Content-Transfer-Encoding: base64\r\n")),
    "--" .. B .. "\nContent-Disposition: form-data; name=\"a\"\n\n1\n--" .. B .. "--\n",
  }
  for i, text in ipairs(cases) do
    local bad = refusal(text, { dir = tmp })
    assert(bad.status == 400, ("case %d: %d %s"):format(i, bad.status, bad.message))
    assert(bad.errors[1].code == "malformed" or bad.errors[1].code == "utf8")
  end
  assert(#assert(Fs.list(tmp)) == 0)
end

local function test_charsets_of_text_parts()
  local latin = post(body_of(field("a", "caf\233", "Content-Type: text/plain; charset=ISO-8859-1\r\n"),
    field("b", "plain", "Content-Type: text/plain; charset=utf-8\r\n")), function(req: Web.Request): Web.Response
      local m = assert(Input.multipart(req).value)
      assert(m.fields.by_name["a"][1] == "caf\195\169" and m.fields.by_name["b"][1] == "plain")
      return Web.empty()
    end)
  assert(latin.status == 204)
  local bad = refusal(body_of(field("a", "x", "Content-Type: text/plain; charset=utf-16\r\n")))
  assert(bad.status == 415 and bad.errors[1].code == "content_type")
end

local function test_a_field_name_is_not_echoed_raw_in_a_message()
  local name = "<script>alert(1)</script>" .. ("n"):rep(100)
  local bad = refusal(body_of(field(name, ("z"):rep(2000))), { max_field_bytes = 10 })
  assert(bad.status == 413 and not bad.message:find("<", 1, true) and #bad.message < 200, bad.message)
end

local function test_the_body_is_read_once_and_kept()
  post(body_of(field("a", "1"), file("f", "x", "y")), function(req: Web.Request): Web.Response
    local first = Input.multipart(req)
    local again = Input.multipart(req)
    assert(first.value == again.value, "one read")
    assert(Input.form(req).value == assert(first.value).fields, "the form is its text parts")
    assert(Input.form(req).value == Input.form(req).value)
    local bytes, why = req:bytes()
    assert(bytes == nil and why:find("already read"), "the spent body is no empty body")
    assert(assert(Input.multipart(req, { max_bytes = 5 }).invalid).status == 413, "held to a later, smaller limit")
    return Web.empty()
  end)
  local failed = post("junk", function(req: Web.Request): Web.Response
    local first = Input.multipart(req).invalid
    local again = Input.multipart(req).invalid
    assert(first ~= nil and first == again, "a refusal is kept too")
    return Web.empty()
  end)
  assert(failed.status == 204)
end

local function test_a_slow_or_failing_source_is_408_or_400(tmp: string)
  local function with_source(why: string): Types.Invalid
    local sent = false
    local body: Stream.Reader = {
      read = function(_self: Stream.Reader, _max?: integer): string | nil, string
        if sent then return nil, why end
        sent = true
        return "--" .. B .. '\r\nContent-Disposition: form-data; name="f"; filename="a"\r\n\r\npartial', ""
      end,
      close = function(_self: Stream.Reader): boolean, string return true, "" end,
    }
    local got: Types.Invalid
    local app = Web.app{ routes = { Web.post("/x", function(req: Web.Request): Web.Response
      got = Input.multipart(req, { dir = tmp }).invalid
      return Web.empty()
    end) } }
    local raw: Server.Request = { method = "POST", target = "/x", path = "/x", query = "", version = "HTTP/1.1",
      headers = { host = "x", ["content-type"] = FORM_TYPE }, body = body }
    assert(app.handle(raw).status == 204)
    return got
  end
  assert(with_source(Poll.TIMEOUT).status == 408)
  assert(with_source("connection reset").status == 400)
  assert(with_source("http: the body is longer than limits.body_bytes").status == 413)
  assert(#assert(Fs.list(tmp)) == 0, "a part cut off mid-file leaves nothing")
end

local function test_a_directory_that_cannot_be_written_is_a_server_fault()
  local reply = post(body_of(file("f", "a", "x")), function(req: Web.Request): Web.Response
    Input.multipart(req, { dir = "/nonexistent-dir-for-uploads" })
    return Web.empty()
  end)
  assert(reply.status == 500, reply.status)
end

local function test_a_request_with_no_body_is_not_multipart()
  local bad = refusal("", nil, "multipart/form-data; boundary=" .. B)
  assert(bad.status == 400)
  local form = post("", function(req: Web.Request): Web.Response
    assert(Input.form(req).invalid == nil)
    return Web.empty()
  end, "multipart/form-data; boundary=" .. B)
  assert(form.status == 204, "an empty body is an empty form")
end

--- How many private upload directories the temp directory holds.
local function upload_dirs(): integer
  local probe = (assert(Fs.mkdtemp("probe-")))
  local base = probe:match("^(.*)/[^/]+$")
  assert(Fs.remove_tree(probe))
  local count = 0
  local names = assert(Fs.list(base))
  for _, name in ipairs(names) do
    if name:find("^cosmic%-upload%-") then count = count + 1 end
  end
  return count
end

local function test_a_blank_file_input_makes_no_directory()
  local before = upload_dirs()
  post(body_of(field("a", "1"), file("none", "", "")), function(req: Web.Request): Web.Response
    local m = assert(Input.multipart(req).value)
    assert(m.files["none"] == nil and m.fields.by_name["a"][1] == "1")
    return Web.empty()
  end)
  assert(upload_dirs() == before, "a blank file input leaked its directory")
  post(body_of(file("none", "", ""), file("f", "x.txt", "data")), function(req: Web.Request): Web.Response
    assert(assert(Input.multipart(req).value).files["f"][1].size == 4)
    return Web.empty()
  end)
  assert(upload_dirs() == before, "the directory goes with the files")
end

local function test_a_limit_failure_is_not_kept_for_a_reader_with_a_higher_limit(tmp: string)
  local text = body_of(field("email", "e"), file("f", "a", ("x"):rep(70000)))
  local seen: Input.Multipart | nil = nil
  post(text, function(req: Web.Request): Web.Response
    assert(assert(Input.form(req, { dir = tmp }).invalid).status == 413)
    seen = assert(Input.multipart(req, { dir = tmp }).value)
    return Web.empty()
  end)
  assert(seen ~= nil and seen.files["f"][1].size == 70000, "the upload's own limit took the body")
  local again: Types.Invalid | nil = nil
  post(text, function(req: Web.Request): Web.Response
    local first = Input.form(req, { dir = tmp })
    assert(assert(first.invalid).status == 413)
    again = Input.multipart(req, { dir = tmp }).invalid
    return Web.empty()
  end, nil, true)
  assert(again ~= nil and again.status == 413 and again.message:find("max_bytes = 65536", 1, true),
    "a body spent past a lower limit says whose limit it was")
  assert(#assert(Fs.list(tmp)) == 0)
end

local function test_trailing_blanks_in_parameters_cost_time_linear_in_their_run()
  local spaces = (" "):rep(8000)
  local parts: {string} = {}
  for i = 1, 100 do
    parts[i] = "--" .. B .. '\r\nContent-Disposition: form-data; name="n' .. i .. '"; x=a' .. spaces .. "y\r\n\r\nv\r\n"
  end
  local start = Clock.monotonic_ns()
  local count = 0
  post(body_of(table.concat(parts)), function(req: Web.Request): Web.Response
    count = #assert(Input.multipart(req).value).fields.pairs
    return Web.empty()
  end)
  local took = Clock.monotonic_ns() - start
  assert(count == 100)
  assert(took < Clock.seconds(2), "took " .. took // 1000000 .. " ms")
  start = Clock.monotonic_ns()
  local type_header = "application/x-www-form-urlencoded; x=a" .. (" "):rep(60000) .. "y"
  post("a=1", function(req: Web.Request): Web.Response
    assert(Input.form(req).invalid == nil)
    return Web.empty()
  end, type_header)
  assert(Clock.monotonic_ns() - start < Clock.seconds(2), "a Content-Type's blanks are scanned once")
end

--- A POST whose body arrives as `first`, then waits; the reply never comes
--- because the task running it is killed there.
local function killed_while_waiting(fn: function(req: Web.Request), first: string)
  local app = Web.app{ routes = { Web.post("/x", function(req: Web.Request): Web.Response
    fn(req)
    local _, _ = Poll.delay(Clock.seconds(30))
    return Web.empty()
  end) } }
  local at = 0
  local body: Stream.Reader = {
    read = function(_self: Stream.Reader, _max?: integer): string | nil, string
      at = at + 1
      if at == 1 then return first, "" end
      local _, _ = Poll.delay(Clock.seconds(30))
      return nil, "gone"
    end,
    close = function(_self: Stream.Reader): boolean, string return true, "" end,
  }
  local raw: Server.Request = { method = "POST", target = "/x", path = "/x", query = "", version = "HTTP/1.1",
    headers = { host = "x", ["content-type"] = FORM_TYPE }, body = body }
  Poll.run(function()
    local task = Poll.spawn(function() app.handle(raw) end)
    assert(Poll.delay(0))
    task:kill()
  end)
end

local function test_a_task_killed_mid_upload_or_in_the_handler_leaves_no_files(tmp: string)
  killed_while_waiting(function(req: Web.Request)
    local _ = Input.multipart(req, { dir = tmp })
  end, "--" .. B .. '\r\nContent-Disposition: form-data; name="f"; filename="a"\r\n\r\n' .. ("x"):rep(100))
  assert(#assert(Fs.list(tmp)) == 0, "files of a read cut off by a kill")
  killed_while_waiting(function(req: Web.Request)
    assert(Input.multipart(req, { dir = tmp }).invalid ~= nil)
  end, "--" .. B .. '\r\nContent-Disposition: form-data; name="f"; filename="a"\r\n\r\n' .. ("x"):rep(100))
  assert(#assert(Fs.list(tmp)) == 0)
end

local function test_a_task_killed_in_the_handler_after_the_read_leaves_no_files(tmp: string)
  local text = body_of(file("f", "a", "data"))
  local app = Web.app{ routes = { Web.post("/x", function(req: Web.Request): Web.Response
    local m = assert(Input.multipart(req, { dir = tmp }).value)
    assert(#assert(Fs.list(tmp)) == 1 and m.files["f"] ~= nil)
    local _, _ = Poll.delay(Clock.seconds(30))
    return Web.empty()
  end) } }
  local raw: Server.Request = { method = "POST", target = "/x", path = "/x", query = "", version = "HTTP/1.1",
    headers = { host = "x", ["content-type"] = FORM_TYPE }, body = Stream.from_string(text), length = #text }
  Poll.run(function()
    local task = Poll.spawn(function() app.handle(raw) end)
    assert(Poll.delay(0))
    task:kill()
  end)
  assert(#assert(Fs.list(tmp)) == 0, "the app closes a request's bodies when its task is killed")
end

local function test_a_long_filename_is_cut_to_its_last_component_in_linear_time(tmp: string)
  local name = ("a"):rep(3000) .. "/" .. ("b"):rep(3000) .. "/c.txt"
  local parts: {string} = {}
  for i = 1, 100 do parts[i] = file("f", name, "data") end
  local start = Clock.monotonic_ns()
  local names: {string} = {}
  post(body_of(table.concat(parts)), function(req: Web.Request): Web.Response
    local read = Input.multipart(req, { dir = tmp, max_parts = 200, max_files = 200 })
    assert(read.value ~= nil, read.invalid ~= nil and read.invalid.message or "no value")
    for _, up in ipairs(read.value.files["f"]) do names[#names + 1] = up.filename end
    return Web.empty()
  end)
  local took = Clock.monotonic_ns() - start
  assert(#names == 100 and names[1] == "c.txt" and names[100] == "c.txt", #names)
  assert(took < Clock.seconds(1), "took " .. took // 1000000 .. " ms")
end
