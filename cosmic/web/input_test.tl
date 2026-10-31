local Input = require("cosmic.web.input")
local Json = require("cosmic.json")
local Poll = require("cosmic.poll")
local Server = require("cosmic.http.server")
local Shape = require("cosmic.shape")
local Stream = require("cosmic.stream")
local Types = require("cosmic.web.types")
local Url = require("cosmic.url")
local Web = require("cosmic.web")

--- A record node read as a map of untrusted values, which is all a hand-written record says of its type.
local function dynamic(node: Shape.Node): Shape.Spec<{string:any}>
  return Shape.raw.table_of(node)
end

--- Why `invalid` refuses, or nil for none.
local function message_of(invalid: Types.Invalid?): string?
  if invalid == nil then return nil end
  return invalid.message
end

local enum Color
  "red"
  "green"
end

local record Address
  city: string
  zip: integer?
end

local record Everything
  name: string
  age: integer
  score: number
  admin: boolean
  color: Color
  nick: string?
  limit: integer?
  ratio: number?
  flag: boolean?
  tags: {string}
  nums: {integer}
  address: Address
end
local EVERYTHING <const> = Shape.record_of("Everything")

local record Counts
  n: integer
  big: integer?
end
local COUNTS <const> = Shape.record_of("Counts")

--- The first error of `invalid`, which every refusal here lists.
local function first_error(invalid: Types.Invalid): Types.FieldError
  local first = assert(invalid.errors[1], "a refusal lists an error")
  return first
end

--- A query of the pairs, names and values as given (a NUL included, which
--- the text decoder would pass anyway).
local function pairs_of(list: {{string}}): Url.Query
  local q: Url.Query = { pairs = {}, by_name = {} }
  for _, pair in ipairs(list) do
    local name = assert(pair[1], "expected a name")
    local value = assert(pair[2], "expected a value")
    q.pairs[#q.pairs + 1] = { name = name, value = value }
    local values = q.by_name[name]
    if values == nil then
      values = {}
      q.by_name[name] = values
    end
    values[#values + 1] = value
  end
  return q
end

local function decoded(text: string): Url.Query
  return (assert(Url.decode_query(text)))
end

local GOOD <const> = "name=Ada&age=36&score=1.5&admin=on&color=red&tags=a&tags=b&nums=1&nums=2&address.city=Oslo"

local function test_every_kind_is_read_from_text()
  local r: Types.Parsed<Everything> = Input.bind_strings(decoded(GOOD .. "&nick=&limit=&ratio=&flag="),
    EVERYTHING.spec)
  assert(r.invalid == nil, message_of(r.invalid))
  local e = assert(r.value)
  assert(e.name == "Ada" and e.age == 36 and math.type(e.age) == "integer")
  assert(e.score == 1.5 and e.admin == true and e.color == "red")
  assert(e.tags[1] == "a" and e.tags[2] == "b" and #e.tags == 2)
  assert(e.nums[1] == 1 and e.nums[2] == 2)
  assert(e.address.city == "Oslo" and e.address.zip == nil)
  assert(e.nick == "", "an optional string keeps its empty text")
  assert(e.limit == nil and e.ratio == nil and e.flag == nil, "an empty optional of another kind is nil")
end

local function bound_count(text: string): integer?, string
  local r: Types.Parsed<Counts> = Input.bind_strings(decoded(text), COUNTS.spec)
  local invalid = r.invalid
  if invalid ~= nil then return nil, first_error(invalid).code end
  return assert(r.value).n, ""
end

local function test_an_integer_is_digits_with_a_sign_that_fit()
  assert(bound_count("n=42") == 42)
  assert(bound_count("n=%20%097%09") == 7, "spaces and tabs are trimmed")
  assert(bound_count("n=%2B5") == 5 and bound_count("n=-0") == 0)
  assert(bound_count("n=00012") == 12)
  assert(bound_count("n=9223372036854775807") == math.maxinteger)
  assert(bound_count("n=-9223372036854775808") == math.mininteger)
  for _, bad in ipairs({ "9223372036854775808", "-9223372036854775809", "99999999999999999999", "1.0",
      "1e3", "0x10", "1,000", "--1", "+", "1%202", "abc", "%C2%BD" }) do
    local n, code = bound_count("n=" .. bad)
    assert(n == nil and code == "integer", bad .. " gave " .. tostring(n) .. " " .. code)
  end
  local n, code = bound_count("n=")
  assert(n == nil and code == "required", "an empty required integer is missing")
  n, code = bound_count("x=1")
  assert(n == nil and code == "required")
end

local record Nums
  x: number
end
local NUMS <const> = Shape.record_of("Nums")

local function number_of(text: string): number?
  local r: Types.Parsed<Nums> = Input.bind_strings(decoded("x=" .. text), NUMS.spec)
  if r.invalid ~= nil then return nil end
  return assert(r.value).x
end

local function test_a_number_is_a_finite_decimal()
  assert(number_of("1.5") == 1.5 and number_of("-2") == -2 and math.type(number_of("5")) == "integer")
  assert(number_of("1e3") == 1000 and number_of(".5") == 0.5 and number_of("2E-1") == 0.2)
  assert(number_of("%2B1.25") == 1.25)
  for _, bad in ipairs({ "1.", ".", "inf", "-inf", "nan", "0x10", "1e", "1e999", "1e+", "1_000", "1 2", "--1",
      "1e9999999" }) do
    assert(number_of(bad) == nil, bad .. " is no number")
  end
end

local record Flags
  a: boolean
  b: boolean?
end
local FLAGS <const> = Shape.record_of("Flags")

local function flags(text: string): Flags?, string
  local r: Types.Parsed<Flags> = Input.bind_strings(decoded(text), FLAGS.spec)
  local invalid = r.invalid
  if invalid ~= nil then return nil, first_error(invalid).code end
  return r.value, ""
end

local function test_a_boolean_follows_the_html_rule()
  for _, yes in ipairs({ "true", "on", "1", "yes", "TRUE", "On", "YeS" }) do
    local f = assert(flags("a=" .. yes))
    assert(f.a == true, yes)
  end
  for _, no in ipairs({ "false", "off", "0", "no", "", "FALSE" }) do
    local f = assert(flags("a=" .. no))
    assert(f.a == false, no)
  end
  local f, code = flags("a=maybe")
  assert(f == nil and code == "boolean")
  f, code = flags("a=%20true")
  assert(f == nil and code == "boolean", "a boolean is exact, not trimmed")
end

local function test_an_absent_boolean_is_false_but_an_optional_one_is_nil()
  local f = assert(flags(""))
  assert(f.a == false and f.b == nil)
  f = assert(flags("b="))
  assert(f.b == nil, "an empty optional boolean is nil")
  f = assert(flags("b=off&a=1"))
  assert(f.b == false and f.a == true)
end

local function test_the_last_of_a_repeated_name_wins()
  local f = assert(flags("a=0&a=1"))
  assert(f.a == true, "the checkbox after its hidden zero")
  assert(bound_count("n=1&n=2&n=3") == 3)
end

local function test_repeated_error_refuses_a_repeated_scalar()
  local r: Types.Parsed<Counts> = Input.bind_strings(decoded("n=1&n=2"), COUNTS.spec, { repeated = "error" })
  local invalid = r.invalid
  assert(invalid ~= nil, "a repeated scalar is refused")
  assert(first_error(invalid).code == "repeated" and first_error(invalid).field == "n")
  r = Input.bind_strings(decoded("n=1"), COUNTS.spec, { repeated = "error" })
  assert(r.invalid == nil and assert(r.value).n == 1)
end

local record Pick
  color: Color
  n: integer?
end
local PICK <const> = Shape.record_of("Pick")

local function test_one_of_compares_text_or_the_listed_kind()
  local spec = dynamic(Shape.raw.record({ c = Shape.raw.one_of("red", "green"), n = Shape.raw.one_of(1, 2.5), t = Shape.raw.one_of(true) }))
  local r: Types.Parsed<{string:any}> = Input.bind_strings(decoded("c=green&n=2.50&t=on"), spec)
  assert(r.invalid == nil, message_of(r.invalid))
  assert(assert(r.value).c == "green" and assert(r.value).n == 2.5 and assert(r.value).t == true)
  r = Input.bind_strings(decoded("c=blue&n=3&t=no"), spec)
  local invalid = r.invalid
  assert(invalid ~= nil and #invalid.errors == 3)
  for _, e in ipairs(invalid.errors) do assert(e.code == "one_of", e.field) end
  assert(first_error(invalid).message == "must be one of red, green")
  local p: Types.Parsed<Pick> = Input.bind_strings(decoded("color=red"), PICK.spec)
  assert(p.invalid == nil and assert(p.value).color == "red")
end

local function test_a_string_with_a_nul_is_refused()
  local spec = dynamic(Shape.raw.record({ s = Shape.raw.string, t = Shape.raw.optional(Shape.raw.string) }))
  local r: Types.Parsed<{string:any}> = Input.bind_strings(pairs_of({ { "s", "a\0b" }, { "t", "ok" } }), spec)
  local invalid = r.invalid
  assert(invalid ~= nil and #invalid.errors == 1)
  assert(invalid.errors[1].field == "s" and invalid.errors[1].code == "type")
  r = Input.bind_strings(pairs_of({ { "s", "" } }), spec)
  assert(r.invalid == nil and assert(r.value).s == "", "an empty string is a string")
end

local function test_a_list_takes_every_value_and_names_the_bad_element()
  local spec = dynamic(Shape.raw.record({ nums = Shape.raw.list(Shape.raw.integer), tags = Shape.raw.optional(Shape.raw.list(Shape.raw.string)) }))
  local r: Types.Parsed<{string:any}> = Input.bind_strings(decoded("nums=1"), spec)
  assert(r.invalid == nil)
  local nums = assert(r.value).nums as {integer}
  assert(#nums == 1 and nums[1] == 1 and assert(r.value).tags == nil)
  r = Input.bind_strings(decoded(""), spec)
  assert(r.invalid == nil and Json.is_array(assert(r.value).nums), "no value is the empty list")
  r = Input.bind_strings(decoded("nums=1&nums=x&nums=3&nums=y"), spec)
  local invalid = r.invalid
  assert(invalid ~= nil and #invalid.errors == 2)
  assert(invalid.errors[1].field == "nums.1" and invalid.errors[2].field == "nums.3")
end

local function test_unknown_names_are_dropped_and_a_strict_record_refuses_them()
  local r: Types.Parsed<Counts> = Input.bind_strings(decoded("n=1&is_admin=1"), COUNTS.spec)
  assert(r.invalid == nil)
  local bound = r.value as {string:any}
  assert(bound["is_admin"] == nil, "the spec is the allow-list")
  local strict = dynamic(Shape.raw.strict_record({ n = Shape.raw.integer }))
  local s: Types.Parsed<{string:any}> = Input.bind_strings(decoded("n=1&zz=1&aa=2&csrf_token=t"), strict)
  local invalid = s.invalid
  assert(invalid ~= nil and #invalid.errors == 2, "csrf_token is the web layer's")
  assert(invalid.errors[1].field == "aa" and invalid.errors[1].code == "unknown")
  assert(invalid.errors[2].field == "zz")
  s = Input.bind_strings(decoded("n=1&csrf_token=t"), strict)
  assert(s.invalid == nil)
end

local function test_nested_records_read_dotted_names()
  local r: Types.Parsed<Everything> = Input.bind_strings(decoded(GOOD .. "&address.zip=0123"), EVERYTHING.spec)
  assert(r.invalid == nil and assert(r.value).address.zip == 123)
  local spec = dynamic(Shape.raw.record({ a = Shape.raw.record({ b = Shape.raw.record({ c = Shape.raw.record({ d = Shape.raw.string }) }) }) }))
  local deep: Types.Parsed<{string:any}> = Input.bind_strings(decoded("a.b.c.d=x"), spec)
  assert(deep.invalid == nil, "three levels below the top are read")
  local opt = dynamic(Shape.raw.record({ a = Shape.raw.optional(Shape.raw.record({ x = Shape.raw.integer })) }))
  local none: Types.Parsed<{string:any}> = Input.bind_strings(decoded("y=1"), opt)
  assert(none.invalid == nil and assert(none.value).a == nil, "no name under a. leaves the optional record nil")
  local some: Types.Parsed<{string:any}> = Input.bind_strings(decoded("a.x="), opt)
  local invalid = some.invalid
  assert(invalid ~= nil, "one name under it asks for the rest")
  assert(first_error(invalid).field == "a.x")
end

local function test_every_field_error_is_collected_in_field_order()
  local r: Types.Parsed<Everything> = Input.bind_strings(
    decoded("name=&age=x&score=y&admin=maybe&color=blue&nums=1&nums=z&password=hunter2&token=t"),
    EVERYTHING.spec, { secret = { "password", "token" }, source = "query" })
  local bad = assert(r.invalid)
  assert(bad.status == 422)
  local fields: mut {string} = {}
  for i, e in ipairs(bad.errors) do
    fields[i] = e.field
    assert(e.source == "query" and e.pointer == nil)
  end
  assert(table.concat(fields, ",") == "address.city,admin,age,color,nums.1,score", table.concat(fields, ","))
  assert(bad.message == "address.city: is required (and 5 more)", bad.message)
  assert(Input.value(bad, "password") == "" and Input.value(bad, "name") == "")
  assert(Input.value(bad, "age") == "x", "what was submitted comes back")
  local by_field = Input.errors_by_field(bad)
  assert(by_field.age == "must be a whole number" and by_field["address.city"] == "is required")
  assert(#assert(bad.submitted).pairs == 7 and assert(bad.submitted).by_name.password == nil, "secret names are left out")
end

local function test_errors_by_field_joins_several_messages()
  local bad: Types.Invalid = { status = 422, message = "m", errors = {
    { source = "form", field = "a", code = "x", message = "one" },
    { source = "form", field = "a", code = "y", message = "two" },
    { source = "form", field = "b", code = "x", message = "three" },
  } }
  local by = Input.errors_by_field(bad)
  assert(by.a == "one; two" and by.b == "three")
  assert(Input.value(bad, "a") == "", "a JSON refusal submitted nothing")
end

local function test_check_spec_refuses_what_text_cannot_carry()
  local function refuses(spec: Shape.Node, source: string, needle: string)
    local ok, err = pcall(function(): any
      Input.check_spec(spec, source)
      return nil
    end)
    assert(not ok and tostring(err):find(needle, 1, true) ~= nil, tostring(err))
  end
  refuses(Shape.raw.record({ m = Shape.raw.map(Shape.raw.string) }), "form", "m of a form is a map")
  refuses(Shape.raw.record({ l = Shape.raw.list(Shape.raw.record({ x = Shape.raw.string })) }), "query", "list of records")
  refuses(Shape.raw.record({ a = Shape.raw.record({ b = Shape.raw.record({ c = Shape.raw.record({ d = Shape.raw.record({
    e = Shape.raw.string }) }) }) }) }), "form", "deeper than 3")
  refuses(Shape.raw.record({ n = Shape.raw.number }), "path", "must be a string, integer, boolean or one_of")
  refuses(Shape.raw.record({ n = Shape.raw.optional(Shape.raw.integer) }), "path", "and present")
  refuses(Shape.raw.record({ l = Shape.raw.list(Shape.raw.string) }), "path", "a list")
  refuses(Shape.raw.string, "form", "binds to a record")
  -- Shape.record refuses a hand-built kind, so corrupt a built spec.
  local odd = Shape.raw.record({ x = Shape.raw.optional(Shape.raw.string) })
  local leaf = assert(odd.fields).x as any as {string:any}
  leaf["kind"] = "bogus"
  refuses(odd, "form", "x of a form is of kind bogus")
  local listing = Shape.raw.record({ x = Shape.raw.list(Shape.raw.optional(Shape.raw.string)) })
  local element = assert(assert(listing.fields).x.of) as any as {string:any}
  element["kind"] = "bogus"
  refuses(listing, "query", "list of kind bogus")
  refuses(Shape.raw.record({}), "cookie", "is not a source")
  Input.check_spec(Shape.raw.record({ m = Shape.raw.map(Shape.raw.string) }), "body")
  Input.check_spec(EVERYTHING.spec.node, "form")
  Input.check_spec(Shape.raw.record({ id = Shape.raw.integer, kind = Shape.raw.one_of("a"), s = Shape.raw.string }), "path")
end

local function test_bind_strings_refuses_a_spec_that_is_no_record()
  local ok, _ = pcall(function()
    local _ = Input.bind_strings(decoded("a=1"), Shape.string)
  end)
  assert(not ok)
  local m = dynamic(Shape.raw.record({ m = Shape.raw.map(Shape.raw.string) }))
  ok, _ = pcall(function()
    local _ = Input.bind_strings(decoded("a=1"), m)
  end)
  assert(not ok, "a map is a programming error, found while binding")
end

--- Runs `fn` on the request the test client sends to an app that has one route.
local function with_request(method: string, opts: Web.TestOptions, fn: function(req: Web.Request))
  local app = Web.app{ routes = { Web.route(method, "/x", function(req: Web.Request): Web.Response
    fn(req)
    return Web.text("ok")
  end) } }
  local client = Web.test_client(app)
  local reply = method == "GET" and client:get("/x", opts) or client:post("/x", opts)
  assert(reply.status == 200, reply.status)
end

local function test_media_type_parses_parameters()
  local function of(content_type: string?): Input.MediaType
    local got: Input.MediaType? = nil
    local headers: mut {string:string} = {}
    local opts: Web.TestOptions = { headers = headers }
    if content_type ~= nil then headers["content-type"] = content_type end
    with_request("GET", opts, function(req: Web.Request)
      got = Input.media_type(req)
    end)
    local read = assert(got, "the handler never ran")
    return read
  end
  local m = of('Multipart/Form-Data; Boundary="a b\\"c"; charset=UTF-8')
  assert(m.essence == "multipart/form-data" and m.params.boundary == 'a b"c' and m.params.charset == "UTF-8")
  m = of("text/plain;charset=latin1 ; x=1")
  assert(m.essence == "text/plain" and m.params.charset == "latin1" and m.params.x == "1")
  assert(of(nil).essence == "" and next(of(nil).params) == nil)
  assert(of("application/json;").essence == "application/json")
  assert(of('a/b; q="unterminated').params.q == "unterminated")
end

local function test_a_form_body_is_decoded_once_and_kept()
  with_request("POST", { form = { a = "1", b = { "x y", "z" } } }, function(req: Web.Request)
    local first = Input.form(req)
    assert(first.invalid == nil and Url.query_last(assert(first.value), "b") == "z")
    local second = Input.form(req)
    assert(rawequal(second.value, first.value), "the decode is the cached one")
    assert(req:get(Input.FORM) == first.value)
    assert(req:bytes() == "a=1&b=x+y&b=z")
    assert(Stream.read_all(req.raw.body) == "a=1&b=x+y&b=z", "the bytes are still there to read")
  end)
end

local function test_a_form_after_json_is_415()
  with_request("POST", { json = { a = 1 } }, function(req: Web.Request)
    local read = Input.json(req)
    assert(read.invalid == nil)
    local form = Input.form(req)
    local invalid = form.invalid
    assert(invalid ~= nil and invalid.status == 415)
  end)
end

local function test_a_wrong_content_type_is_415()
  local function status_of(content_type: string?, body: string, kind: string): integer
    local got: integer = 0
    local opts: Web.TestOptions = { body = body, content_type = content_type }
    with_request("POST", opts, function(req: Web.Request)
      local bad = if kind == "form" then Input.form(req).invalid else Input.json(req).invalid end
      if bad ~= nil then
        got = bad.status
        assert(first_error(bad).code == "content_type" and first_error(bad).source == "body")
      end
    end)
    return got
  end
  assert(status_of("text/plain", "a=1", "form") == 415, "a cross-site form can send text/plain")
  assert(status_of(nil, "a=1", "form") == 415, "a body with no type")
  assert(status_of("application/x-www-form-urlencoded; charset=latin1", "a=1", "form") == 415)
  assert(status_of("application/x-www-form-urlencoded; charset=UTF-8", "a=1", "form") == 0)
  assert(status_of("text/plain", "{}", "json") == 415)
  assert(status_of("application/x-www-form-urlencoded", "{}", "json") == 415)
  assert(status_of("application/json; charset=utf-16", "{}", "json") == 415)
  assert(status_of("application/vnd.api+json", "{}", "json") == 0)
  assert(status_of("APPLICATION/JSON", "{}", "json") == 0)
  assert(status_of("application/+json", "{}", "json") == 415)
end

local function test_a_request_with_no_body_is_an_empty_form_and_no_json()
  with_request("GET", {}, function(req: Web.Request)
    local form = Input.form(req)
    assert(form.invalid == nil and #assert(form.value).pairs == 0, "no type is asked of no body")
    local json = Input.json(req)
    local invalid = json.invalid
    assert(invalid ~= nil and invalid.status == 422 and first_error(invalid).code == "required")
  end)
end

local function test_a_body_over_the_limit_is_413()
  with_request("POST", { form = { a = ("x"):rep(100) } }, function(req: Web.Request)
    local bad = Input.form(req, { max_bytes = 50 }).invalid
    assert(bad ~= nil and bad.status == 413 and first_error(bad).code == "too_large")
    assert(Input.form(req, { max_bytes = 200 }).invalid == nil, "the limit is the call's")
    local again = Input.form(req, { max_bytes = 50 }).invalid
    assert(again ~= nil and again.status == 413, "a kept body is held to a later, smaller limit")
  end)
end

local function test_a_chunked_body_over_the_limit_is_413_without_reading_it_all()
  local pulled: integer = 0
  local reader: Stream.Reader = {
    read = function(_self: Stream.Reader, max_bytes?: integer): string?, string
      pulled = pulled + 1
      if pulled > 100 then return nil, "" end
      return ("y"):rep(math.min(max_bytes or 10, 10)), ""
    end,
    close = function(_self: Stream.Reader): boolean, string
      return true, ""
    end,
  }
  local status: integer = 0
  local app = Web.app{ routes = { Web.post("/x", function(req: Web.Request): Web.Response
    local bad = Input.form(req, { max_bytes = 25 }).invalid
    status = bad and bad.status or 0
    return Web.text("ok")
  end) } }
  local raw: Server.Request = { method = "POST", target = "/x", path = "/x", query = "", version = "HTTP/1.1",
    headers = { host = "x", ["content-type"] = "application/x-www-form-urlencoded" }, body = reader }
  assert(app.handle(raw).status == 200)
  assert(status == 413)
  assert(pulled < 10, "the read stopped one byte past the limit")
end

--- The status [`Input.form`] answers for a chunked request whose body reader
--- fails with `why` on its first read, and the body_failure left after, and
--- what a second read with a larger limit answers.
local function failing_body(why: string): integer, integer
  local reader: Stream.Reader = {
    read = function(_self: Stream.Reader, _max_bytes?: integer): string?, string
      return nil, why
    end,
    close = function(_self: Stream.Reader): boolean, string
      return true, ""
    end,
  }
  local first: integer = 0
  local second: integer = 0
  local app = Web.app{ routes = { Web.post("/x", function(req: Web.Request): Web.Response
    local bad = Input.form(req).invalid
    first = bad and bad.status or 0
    bad = Input.form(req, { max_bytes = 1 << 20 }).invalid
    second = bad and bad.status or 0
    return Web.text("ok")
  end) } }
  local raw: Server.Request = { method = "POST", target = "/x", path = "/x", query = "", version = "HTTP/1.1",
    headers = { host = "x", ["content-type"] = "application/x-www-form-urlencoded" }, body = reader }
  assert(app.handle(raw).status == 200)
  return first, second
end

local function test_the_servers_over_limit_failure_is_413()
  local first, second = failing_body("http: the body is longer than limits.body_bytes")
  assert(first == 413 and second == 413, "413 both times: " .. tostring(first) .. " " .. tostring(second))
end

local function test_a_body_read_that_times_out_is_408()
  local first, second = failing_body(Poll.TIMEOUT)
  assert(first == 408 and second == 408, "408 both times: " .. tostring(first) .. " " .. tostring(second))
end

local function test_a_body_read_over_the_limit_stays_failed_for_a_later_reader()
  local pulled: integer = 0
  local reader: Stream.Reader = {
    read = function(_self: Stream.Reader, max_bytes?: integer): string?, string
      pulled = pulled + 1
      if pulled > 100 then return nil, "" end
      return ("y"):rep(math.min(max_bytes or 10, 10)), ""
    end,
    close = function(_self: Stream.Reader): boolean, string
      return true, ""
    end,
  }
  local statuses: {integer} = {}
  local bytes_status: string = ""
  local app = Web.app{ routes = { Web.post("/x", function(req: Web.Request): Web.Response
    statuses[1] = assert(Input.form(req, { max_bytes = 25 }).invalid).status
    local larger = Input.form(req, { max_bytes = 1 << 20 }).invalid
    statuses[2] = larger and larger.status or 0
    local data = req:bytes()
    bytes_status = if data == nil then "failed" else "truncated" end
    return Web.text("ok")
  end) } }
  local raw: Server.Request = { method = "POST", target = "/x", path = "/x", query = "", version = "HTTP/1.1",
    headers = { host = "x", ["content-type"] = "application/x-www-form-urlencoded" }, body = reader }
  assert(app.handle(raw).status == 200)
  assert(statuses[1] == 413 and statuses[2] == 413, "a larger limit later is still 413")
  assert(bytes_status == "failed", "req:bytes() does not hand out the truncated body")
end

local function test_a_wrong_charset_names_the_charset()
  with_request("POST", { body = "{}", content_type = "application/json; charset=utf-16" }, function(req: Web.Request)
    local bad = Input.json(req).invalid
    assert(bad ~= nil and bad.status == 415)
    assert(bad.message:find("utf-16", 1, true) and bad.message:find("charset", 1, true), bad.message)
    assert(not bad.message:find("not application/json", 1, true), bad.message)
  end)
end

local function test_json_that_does_not_parse_is_400_with_the_decoders_position()
  with_request("POST", { body = '{"a": ', content_type = "application/json" }, function(req: Web.Request)
    local bad = Input.json(req).invalid
    assert(bad ~= nil, "a body that does not parse is refused")
    assert(bad.status == 400 and first_error(bad).code == "json", bad.message)
    assert(first_error(bad).message:find("line", 1, true) ~= nil, first_error(bad).message)
  end)
end

local function test_a_body_that_is_not_utf8_is_400()
  with_request("POST", { body = '{"a":"\xff"}', content_type = "application/json" }, function(req: Web.Request)
    local bad = Input.json(req).invalid
    assert(bad ~= nil and bad.status == 400 and first_error(bad).code == "utf8")
  end)
end

local function test_a_bad_percent_escape_is_400_for_a_form_and_a_query()
  with_request("POST", { body = "a=%zz", content_type = "application/x-www-form-urlencoded" }, function(req: Web.Request)
    local bad = Input.form(req).invalid
    assert(bad ~= nil and bad.status == 400 and first_error(bad).source == "form")
  end)
  local app = Web.app{ routes = { Web.get("/q", function(req: Web.Request): Web.Response
    local bad = Input.query(req).invalid
    assert(bad ~= nil and bad.status == 400 and first_error(bad).source == "query" and first_error(bad).code == "malformed")
    return Web.text("seen")
  end) } }
  assert(Web.test_client(app):get("/q?a=%zz"):text() == "seen")
end

local function test_a_query_is_shared_with_the_request()
  local app = Web.app{ routes = { Web.get("/q", function(req: Web.Request): Web.Response
    local a = Input.query(req).value
    assert(rawequal(a, (assert(req:query()))), "one decode")
    local b = Input.query(req, { max_pairs = 1 })
    local invalid = b.invalid
    assert(invalid ~= nil and invalid.status == 400, "options decode afresh, and refuse")
    return Web.text("seen")
  end) } }
  assert(Web.test_client(app):get("/q?a=1&b=2"):text() == "seen")
end

local record Item
  title: string
  qty: integer
  address: Address?
  tags: {string}?
end
local ITEM <const> = Shape.record_of("Item")

local function json_error(text: string): Types.FieldError
  local got: Types.FieldError? = nil
  with_request("POST", { body = text, content_type = "application/json" }, function(req: Web.Request)
    local read = Input.json_into(req, ITEM)
    local invalid = read.invalid
    assert(invalid ~= nil and invalid.status == 422, text)
    assert(#invalid.errors == 1 and invalid.submitted == nil)
    got = invalid.errors[1]
  end)
  local read = assert(got, "the handler never ran")
  return read
end

local function test_a_json_body_reports_where_it_failed()
  local e = json_error('{"title":"t","qty":"x"}')
  assert(e.source == "body" and e.field == "qty" and e.pointer == "/qty" and e.code == "integer")
  assert(e.message == 'want integer, got string', e.message)
  e = json_error('{"title":"t","qty":1,"address":{"city":5}}')
  assert(e.field == "address.city" and e.pointer == "/address/city" and e.code == "type", e.field)
  e = json_error('{"title":"t","qty":1,"tags":["a",2]}')
  assert(e.field == "tags.1" and e.pointer == "/tags/1")
  e = json_error('{"qty":1}')
  assert(e.field == "title" and e.code == "required")
  e = json_error('{"title":null,"qty":1}')
  assert(e.field == "title" and e.code == "required", "null is missing")
  e = json_error('[1]')
  assert(e.field == "" and e.pointer == "" and e.code == "type")
  e = json_error('{"title":"t","qty":1.5}')
  assert(e.code == "integer" and e.message:find("1.5", 1, true) ~= nil)
end

local function test_a_json_pointer_with_escapes_is_one_dotted_field()
  local spec = dynamic(Shape.raw.record({ ["a/b"] = Shape.raw.record({ ["c~d"] = Shape.raw.integer }) }))
  local typed: Shape.Typed<{string:any}> = { name = "Escapes", spec = spec, strict = function(self: Shape.Typed<{string:any}>): Shape.Typed<{string:any}>
    return self
  end,
    into = function(_self: Shape.Typed<{string:any}>, _v: any): {string:any}?, string
      return nil, ""
    end,
    decode_into = function(_self: Shape.Typed<{string:any}>, _t: string): {string:any}?, string
      return nil, ""
    end }
  with_request("POST", { json = { ["a/b"] = { ["c~d"] = "x" } } }, function(req: Web.Request)
    local read = Input.json_into(req, typed)
    local e = first_error(assert(read.invalid))
    assert(e.pointer == "/a~1b/c~0d" and e.field == "a/b.c~d", tostring(e.pointer) .. " " .. tostring(e.field))
  end)
end

local function test_a_json_body_failure_at_an_odd_key_keeps_its_pointer()
  local cases: {{string}} = {
    { 'a"b', '/a"b/1', 'a"b.1' },
    { "", "//1", ".1" },
    { "x\\y", "/x\\y/1", "x\\y.1" },
    { "caf\u{e9} 1st", "/caf\u{e9} 1st/1", "caf\u{e9} 1st.1" },
  }
  for _, case in ipairs(cases) do
    local key, want_pointer, want_field = assert(case[1]), assert(case[2]), assert(case[3])
    local spec = dynamic(Shape.raw.record({ [key] = Shape.raw.list(Shape.raw.integer) }))
    local typed: Shape.Typed<{string:any}> = { name = "Odd", spec = spec, strict = function(self: Shape.Typed<{string:any}>): Shape.Typed<{string:any}>
      return self
    end,
      into = function(_self: Shape.Typed<{string:any}>, _v: any): {string:any}?, string
        return nil, ""
      end,
      decode_into = function(_self: Shape.Typed<{string:any}>, _t: string, _o?: Json.DecodeOptions): {string:any}?, string
        return nil, ""
      end }
    with_request("POST", { json = { [key] = { 1, "x" } } }, function(req: Web.Request)
      local read = Input.json_into(req, typed)
      local e = assert(assert(read.invalid).errors[1])
      assert(e.pointer == want_pointer and e.field == want_field, key .. ": " .. tostring(e.pointer) .. " " .. tostring(e.field))
      assert(e.code == "integer" and e.message == "want integer, got string", tostring(e.message))
    end)
  end
end

local function test_a_valid_json_body_is_a_record()
  with_request("POST", { json = { title = "t", qty = 3, extra = true, tags = { "x" } } }, function(req: Web.Request)
    local read = Input.json_into(req, ITEM)
    assert(read.invalid == nil)
    assert(assert(read.value).title == "t" and assert(read.value).qty == 3 and assert(assert(read.value).tags)[1] == "x")
    assert((read.value as {string:any})["extra"] == nil)
    assert(req:get(Input.JSON) ~= nil)
    assert(assert(Input.json_into(req, ITEM).value).qty == 3, "bound again from the cache")
  end)
end

local function test_fail_builds_a_refusal_over_the_submitted_form()
  with_request("POST", { form = { email = "a@b", password = "pw" } }, function(req: Web.Request)
    local bad = Input.fail(req, "email", "is already registered")
    assert(bad.status == 422 and first_error(bad).code == "invalid" and bad.submitted == nil)
    local form = Input.form(req)
    assert(form.invalid == nil)
    bad = Input.fail(req, "email", "is already registered", { secret = { "password" } })
    assert(Input.value(bad, "email") == "a@b" and Input.value(bad, "password") == "")
    assert(bad.message == "email: is already registered")
  end)
end

local function test_form_into_and_query_into_bind_a_request()
  local app = Web.app{ routes = { Web.post("/x", function(req: Web.Request): Web.Response
    local q = Input.query_into(req, COUNTS)
    assert(q.invalid == nil and assert(q.value).n == 4)
    local f = Input.form_into(req, COUNTS)
    local invalid = f.invalid
    assert(invalid ~= nil and first_error(invalid).source == "form")
    local g = assert(Input.form_into(req, COUNTS, { source = "path" }).invalid, "the form's n is not an integer")
    assert(first_error(g).source == "form", "the entry points choose the source")
    return Web.text("ok")
  end) } }
  assert(Web.test_client(app):post("/x?n=4", { form = { n = "z" } }).status == 200)
end

--- The list `xs` of a bound record, read as what it is: a map from the indexes that are there.
local SPARSE <const> = Shape.sparse_list(Shape.optional(Shape.integer))

local function xs_of(r: Types.Parsed<{string:any}>): {integer: integer}
  local bound = assert(r.value)
  local xs, why = Shape.into(bound["xs"], SPARSE)
  if xs == nil then error(why) end
  return xs
end

local function test_a_list_item_that_is_absent_stays_a_hole_at_its_position()
  local spec = dynamic(Shape.raw.record({ xs = Shape.raw.list(Shape.raw.optional(Shape.raw.integer)) }))
  local r = Input.bind_strings(decoded("xs=1&xs=&xs=3"), spec)
  assert(r.invalid == nil, message_of(r.invalid))
  local xs = xs_of(r)
  assert(xs[1] == 1 and xs[2] == nil and xs[3] == 3, "the third item keeps its position")
  assert(Json.is_array(xs), "the list is marked as an array")
  assert(Json.encode_any(xs) == "[1,null,3]", "and a handler that encodes it writes the hole as null")
  r = Input.bind_strings(decoded("xs=1&xs="), spec)
  assert(r.invalid == nil, message_of(r.invalid))
  local short = xs_of(r)
  assert(short[1] == 1 and short[2] == nil and Json.is_array(short), "a hole at the end leaves the list as long as before")
  r = Input.bind_strings(decoded("xs=1&xs=x"), spec)
  local invalid = r.invalid
  assert(invalid ~= nil and #invalid.errors == 1 and assert(invalid.errors[1]).field == "xs.1",
    "a bad item is refused by its position")
end
