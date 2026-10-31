local Html = require("cosmic.html")
local Json = require("cosmic.json")
local Response = require("cosmic.web.response")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Types = require("cosmic.web.types")

--- The message of the error `fn` raises; fails where it raises none.
local function raised(fn: function()): string
  local ok, err = pcall(function(): any
    fn()
    return nil
  end)
  assert(not ok, "expected a raise")
  return tostring(err)
end

--- The string body of `res`.
local function body_of(res: Types.Response): string
  local body = res.body
  if body is string then return body end
  error("the body is not a string")
end

--- Fails unless the server would send `res`.
local function sendable(res: Types.Response, method?: string)
  assert(Server.check(res, method) == "", Server.check(res, method))
end

local function test_html_takes_safe_markup_and_sets_the_content_type()
  local res = Response.html(Html.escape("a < b"), { status = 201 })
  assert(res.status == 201 and res.body == "a &lt; b")
  assert(Response.header(res, "content-type") == "text/html; charset=utf-8")
  sendable(res)
end

local function test_json_encodes_and_marks_the_body_nosniff()
  local res = Response.json({ id = 7 })
  assert(res.status == 200 and res.body == '{"id":7}')
  assert(Response.header(res, "Content-Type") == "application/json")
  assert(Response.header(res, "X-Content-Type-Options") == "nosniff")
  sendable(res)
  local cycle: {string:any} = {}
  cycle.self = cycle
  assert(raised(function() Response.json(cycle) end):find("web: json:", 1, true))
end

local function test_text_is_plain_utf8_text()
  local res = Response.text("héllo\n")
  assert(Response.header(res, "content-type") == "text/plain; charset=utf-8")
  assert(res.body == "héllo\n")
  sendable(res)
end

local function test_options_replace_the_status_and_headers_in_any_case()
  local res = Response.text("x", { status = 202, headers = { ["content-type"] = "text/csv",
    ["X-One"] = "1", ["X-Many"] = { "a", "b" } }, close = true })
  assert(res.status == 202 and res.close == true)
  assert(Response.header(res, "Content-Type") == "text/csv")
  local count = 0
  for name in pairs(res.headers or {}) do
    if name:lower() == "content-type" then count = count + 1 end
  end
  assert(count == 1, "one Content-Type")
  local many = assert(res.headers)["X-Many"]
  assert(many is {string} and #many == 2 and many[2] == "b")
  sendable(res)
end

local function test_redirect_is_a_see_other_to_a_local_path_or_an_http_url()
  local res = Response.redirect("/items/7?x=1")
  assert(res.status == 303 and Response.header(res, "Location") == "/items/7?x=1")
  assert(Response.redirect("/a", { status = 308 }).status == 308)
  assert(Response.redirect("https://example.com/a").status == 303)
  assert(Response.redirect("/").status == 303)
  sendable(res)
  assert(raised(function() Response.redirect("/a", { status = 200 }) end):find("status", 1, true))
end

local function test_redirect_refuses_a_target_that_leaves_the_origin()
  for _, bad in ipairs({ "//evil.com", "//evil.com/x", "/\\evil.com", "\\\\evil.com", "evil.com",
      "javascript:alert(1)", "ftp://example.com/", "", "/a\r\nSet-Cookie: x=1", "/a\0b", "?next=/",
      "/a\tb", "https://exam ple.com/" }) do
    local message = raised(function() Response.redirect(bad) end)
    assert(message:find("web: redirect", 1, true), bad .. ": " .. message)
  end
end

local function test_safe_next_returns_a_local_path_or_the_default()
  assert(Response.safe_next("/items?x=1", "/") == "/items?x=1")
  assert(Response.safe_next("//evil.com", "/home") == "/home")
  assert(Response.safe_next("/\\evil.com", "/home") == "/home")
  assert(Response.safe_next("https://evil.com", "/home") == "/home")
  assert(Response.safe_next(nil, "/home") == "/home")
  assert(Response.local_path("/a") and not Response.local_path("a") and not Response.local_path("//a"))
end

local function test_empty_has_no_body_and_204_by_default()
  local res = Response.empty()
  assert(res.status == 204 and res.body == nil)
  sendable(res)
  local ok = Response.empty(200)
  assert(ok.status == 200 and ok.body == nil)
  sendable(ok)
end

local function test_stream_carries_a_reader_with_its_content_type()
  local res = Response.stream(Stream.from_string("abc"), "text/plain", { length = 3 })
  assert(Response.header(res, "Content-Type") == "text/plain" and res.length == 3)
  sendable(res)
end

local function test_problem_is_rfc_9457_json_with_the_reason_as_its_title()
  local res = Response.problem(404, "no such item", { errors = Json.array({ "x" }), status = 1 })
  assert(Response.header(res, "Content-Type") == "application/problem+json")
  local body = assert(Json.decode_object(body_of(res)))
  assert(body.type == "about:blank" and body.title == "Not Found" and body.status == 404)
  assert(body.detail == "no such item")
  local errors = body.errors
  assert(errors is {string} and errors[1] == "x")
  sendable(res)
  local unnamed = assert(Json.decode_object(body_of(Response.problem(499))))
  assert(unnamed.title == "Error" and unnamed.detail == nil)
end

local function test_add_header_appends_lines_and_keeps_the_first_as_a_string()
  local res = Response.text("x")
  Response.add_header(res, "Set-Cookie", "a=1")
  assert(assert(res.headers)["Set-Cookie"] == "a=1")
  Response.add_header(res, "set-cookie", "b=2; Expires=Wed, 21 Oct 2026 07:28:00 GMT")
  Response.add_header(res, "Set-Cookie", "c=3")
  local lines = assert(res.headers)["Set-Cookie"]
  assert(lines is {string} and #lines == 3 and lines[1] == "a=1" and lines[3] == "c=3")
  assert(assert(res.headers)["set-cookie"] == nil)
  sendable(res)
end

local function test_add_header_merges_vary_tokens_without_repeating_them()
  local res = Response.text("x")
  Response.add_header(res, "Vary", "Cookie")
  Response.add_header(res, "vary", "HX-Request, cookie")
  Response.add_header(res, "Vary", "Accept-Encoding")
  assert(assert(res.headers)["Vary"] == "Cookie, HX-Request, Accept-Encoding", tostring(assert(res.headers)["Vary"]))
  assert(assert(res.headers)["vary"] == nil)
  Response.add_header(res, "Vary", "*")
  assert(assert(res.headers)["Vary"] == "*")
  Response.add_header(res, "Vary", "Cookie")
  assert(assert(res.headers)["Vary"] == "*")
  local listed = Response.text("x", { headers = { Vary = { "Accept", "Origin" } } })
  Response.add_header(listed, "Vary", "origin")
  Response.add_header(listed, "Vary", "Cookie")
  assert(Response.header(listed, "vary") == "Accept, Origin, Cookie", tostring(Response.header(listed, "vary")))
end

local function test_add_header_gives_every_other_name_a_line_of_its_own()
  local res: Types.Response = { status = 200 }
  Response.add_header(res, "Link", "</a>; rel=preload")
  Response.add_header(res, "Link", "</b>; rel=preload")
  local lines = assert(res.headers)["Link"]
  assert(lines is {string} and #lines == 2)
end

local function test_set_header_replaces_every_case_and_refuses_set_cookie()
  local res: Types.Response = { status = 200, headers = { ["x-a"] = "1", ["X-A"] = "2" } }
  Response.set_header(res, "X-a", "3")
  assert(assert(res.headers)["X-a"] == "3" and assert(res.headers)["x-a"] == nil and assert(res.headers)["X-A"] == nil)
  assert(raised(function() Response.set_header(res, "set-cookie", "a=1") end):find("add_header", 1, true))
  local bare: Types.Response = { status = 200 }
  Response.set_header(bare, "X-B", "1")
  assert(assert(bare.headers)["X-B"] == "1")
end

local function test_header_reads_in_any_case_and_the_first_of_a_list()
  local res: Types.Response = { status = 200, headers = { ["Set-Cookie"] = { "a=1", "b=2" } } }
  assert(Response.header(res, "set-cookie") == "a=1")
  assert(Response.header(res, "Missing") == nil)
  assert(Response.header({ status = 200 }, "x") == nil)
end

local function test_abort_raises_a_tagged_table_the_exception_layer_reads()
  local ok, err = pcall(function(): any
    Response.abort(404, "gone", { code = "x" })
    return nil
  end)
  assert(not ok)
  local abort = Response.aborted(err)
  assert(abort ~= nil and abort.status == 404 and abort.detail == "gone" and assert(abort.extra).code == "x")
  assert(Response.aborted("an ordinary error") == nil)
  assert(Response.aborted({ web_abort = true }) == nil)
  assert(raised(function() Response.abort(200) end):find("400 to 599", 1, true))
end

local function test_a_constructor_refuses_a_status_the_server_cannot_send()
  for _, status in ipairs({ 199, 100, 1000, 0, -1 }) do
    assert(raised(function() Response.text("x", { status = status }) end):find("200 to 999", 1, true), tostring(status))
  end
  local fractional: any = { status = 200.5 }
  assert(raised(function() Response.json(1, fractional as Types.ResponseOptions) end):find("200 to 999", 1, true))
  assert(raised(function() Response.empty(150) end):find("200 to 999", 1, true))
  assert(raised(function() Response.problem(99) end):find("200 to 999", 1, true))
  local half: any = { status = 303.5 }
  assert(raised(function() Response.redirect("/x", half as Types.ResponseOptions) end):find("301", 1, true))
  assert(Response.text("x", { status = 999 }).status == 999 and Response.empty(200).status == 200)
end

local function test_a_json_failure_names_json_once()
  local cycle: {string:any} = {}
  cycle.self = cycle
  local message = raised(function() Response.json(cycle) end)
  assert(message:find("web: json: ", 1, true) and not message:find("json: json:", 1, true), message)
  local problem = raised(function() Response.problem(500, "x", { bad = cycle }) end)
  assert(problem:find("web: problem: ", 1, true) and not problem:find("json: json:", 1, true), problem)
end

local function test_stream_is_nosniff_like_the_other_constructors()
  local res = Response.stream(Stream.from_string("abc"), "text/plain")
  assert(Response.header(res, "x-content-type-options") == "nosniff")
  assert(Response.header(res, "content-type") == "text/plain")
end

local function test_copy_has_headers_of_its_own_and_every_field_of_a_reply()
  local lines: {string} = { "a=1" }
  local original: Types.Response = { status = 201, headers = { ["Set-Cookie"] = lines, Vary = "Accept" },
    body = "x", length = 1, close = true }
  local copy = Response.copy(original)
  assert(copy.status == 201 and copy.body == "x" and copy.length == 1 and copy.close == true)
  Response.add_header(copy, "Set-Cookie", "b=2")
  Response.add_header(copy, "Vary", "Origin")
  Response.set_header(copy, "X-New", "1")
  local original_headers = assert(original.headers)
  local copy_headers = assert(copy.headers)
  assert(#lines == 1 and original_headers["Vary"] == "Accept" and original_headers["X-New"] == nil,
    "the original is as it was")
  assert(#(copy_headers["Set-Cookie"] as {string}) == 2 and copy_headers["Vary"] == "Accept, Origin")
  local bare = Response.copy({ status = 204 })
  assert(bare.status == 204 and next(assert(bare.headers)) == nil)
end
