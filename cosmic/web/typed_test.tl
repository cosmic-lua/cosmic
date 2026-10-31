local Shape = require("cosmic.shape")
local Web = require("cosmic.web")
local Test = require("cosmic.test")

local record ItemPath
  id: integer
end
local record Listing
  page: integer?
  tag: {string}?
end
local record NewItem
  title: string
  qty: integer
end
local record Settings
  name: string
  notify: boolean
  secret: string?
end
local record Rest
  rest: string
end
local record Mapped
  m: {string:string}
end
local PATH <const> = Shape.record_of("ItemPath")
local REST <const> = Shape.record_of("Rest")
local MAPPED <const> = Shape.record_of("Mapped")
local QUERY <const> = Shape.record_of("Listing")
local NEW <const> = Shape.record_of("NewItem")
local SETTINGS <const> = Shape.record_of("Settings")

--- The error a refused request got, as a test needs to read it.
local function problem(reply: Web.TestResponse): {string:any}
  assert(reply.headers["content-type"] == "application/problem+json", reply.headers["content-type"])
  return reply:json() as {string:any}
end

local function test_a_typed_get_is_given_its_path_and_query_as_records()
  local seen: mut {string} = {}
  local app = Web.app{ routes = {
    Web.get_typed("/items/:id", Web.input(PATH, QUERY, Web.no_body),
      function(_req: Web.Request, p: ItemPath, q: Listing, b: Web.None): Web.Response
        table.insert(seen, ("%d|%s|%s|%s"):format(p.id, tostring(q.page), table.concat(q.tag or {}, ","), if next(b) == nil then "empty" else "full" end))
        return Web.json({ id = p.id })
      end, { name = "item" }),
  } }
  local client = Web.test_client(app)
  local reply = client:get("/items/7?page=2&tag=a&tag=b&ignored=1")
  assert(reply.status == 200 and reply:json() ~= nil)
  assert(seen[1] == "7|2|a,b|empty", seen[1])
  assert(client:get("/items/7"):text() == '{"id":7}')
  assert(seen[2] == "7|nil||empty", "an optional query field is nil, a list empty")
  assert(client:head("/items/7").status == 200, "HEAD is answered by the GET")
  assert(app:url_for("item", { id = 7 }) == "/items/7")
end

local function test_a_json_body_binds_and_a_key_the_record_lacks_is_dropped()
  local app = Web.app{ routes = {
    Web.post_typed("/items", Web.input(Web.NONE, Web.NONE, Web.json_body(NEW)),
      function(_req: Web.Request, _p: Web.None, _q: Web.None, b: NewItem): Web.Response
        return Web.json({ title = b.title, qty = b.qty }, { status = 201 })
      end),
  } }
  local reply = Web.test_client(app):post("/items", { json = { title = "x", qty = 2, admin = true } })
  assert(reply.status == 201 and reply:text() == '{"qty":2,"title":"x"}', reply:text())
end

local function test_a_bad_path_value_is_422_before_the_query_or_body_is_read()
  local called: boolean = false
  local app = Web.app{ routes = {
    Web.put_typed("/items/:id", Web.input(PATH, QUERY, Web.json_body(NEW)),
      function(_req: Web.Request, _p: ItemPath, _q: Listing, _b: NewItem): Web.Response
        called = true
        return Web.empty()
      end),
  } }
  local client = Web.test_client(app)
  local reply = client:put("/items/abc?page=x", { json = { title = 1 } })
  assert(reply.status == 422 and not called)
  local errors = problem(reply).errors as {{string:any}}
  assert(#errors == 1 and errors[1].source == "path" and errors[1].field == "id" and errors[1].code == "integer")
  assert(errors[1].pointer == nil, "only a JSON body has a pointer")
  reply = client:put("/items/1?page=x", { json = { title = 1 } })
  errors = problem(reply).errors as {{string:any}}
  assert(errors[1].source == "query" and errors[1].field == "page", "then the query")
  reply = client:put("/items/1", { json = { title = 1 } })
  errors = problem(reply).errors as {{string:any}}
  assert(errors[1].source == "body" and errors[1].pointer == "/qty", "then the body")
  assert(not called)
end

local function test_a_json_route_answers_a_problem_body_with_every_error_listed()
  local app = Web.app{ routes = {
    Web.post_typed("/items", Web.input(Web.NONE, Web.NONE, Web.json_body(NEW)),
      function(_req: Web.Request, _p: Web.None, _q: Web.None, _b: NewItem): Web.Response
        return Web.empty()
      end),
  } }
  local client = Web.test_client(app)
  local reply = client:post("/items", { json = { title = "t", qty = "x" } })
  assert(reply.status == 422)
  local body = problem(reply)
  assert(body.type == "about:blank" and body.title == "Unprocessable Content" and body.status == 422)
  assert(body.detail == "qty: want integer, got string", tostring(body.detail))
  local errors = body.errors as {{string:any}}
  assert(#errors == 1 and errors[1].source == "body" and errors[1].field == "qty" and errors[1].pointer == "/qty")
  assert(errors[1].code == "integer" and errors[1].message == "want integer, got string")
  reply = client:post("/items", { json = { title = "t", qty = 1 }, headers = { Accept = "text/html" } })
  assert(reply.status == 204)
  reply = client:post("/items", { json = { title = 5 }, headers = { Accept = "text/html" } })
  local reply_headers_content_type = assert(reply.headers["content-type"], "expected reply.headers[\"content-type\"]")
  assert(reply.status == 422 and reply_headers_content_type:find("text/html", 1, true) ~= nil, "a browser is given a page")
  assert(reply:text():find("title", 1, true))
end

local function test_a_form_route_prefers_a_page_and_lists_all_errors_as_json_when_asked()
  local app = Web.app{ routes = {
    Web.post_typed("/items", Web.input(Web.NONE, Web.NONE, Web.form_body(NEW)),
      function(_req: Web.Request, _p: Web.None, _q: Web.None, _b: NewItem): Web.Response
        return Web.empty()
      end),
  } }
  local client = Web.test_client(app)
  local reply = client:post("/items", { form = { qty = "two" } })
  local reply_headers_content_type = assert(reply.headers["content-type"], "expected reply.headers[\"content-type\"]")
  assert(reply.status == 422 and reply_headers_content_type:find("text/html", 1, true) ~= nil)
  reply = client:post("/items", { form = { qty = "two" }, headers = { Accept = "application/json" } })
  assert(reply.status == 422)
  local errors = problem(reply).errors as {{string:any}}
  assert(#errors == 2 and errors[1].field == "qty" and errors[2].field == "title", "every field, in field order")
  assert(errors[1].source == "form" and errors[1].pointer == nil)
end

local function test_on_invalid_re_renders_in_place_of_the_handler()
  local called: boolean = false
  local seen: Web.Invalid? = nil
  local app = Web.app{ routes = {
    Web.post_typed("/settings", Web.input(Web.NONE, Web.NONE, Web.form_body(SETTINGS)),
      function(_req: Web.Request, _p: Web.None, _q: Web.None, _b: Settings): Web.Response
        called = true
        return Web.empty()
      end, {
        input_options = { secret = { "secret" } },
        on_invalid = function(req: Web.Request, bad: Web.Invalid): Web.Response
          seen = bad
          local bad_errors_1 = assert(bad.errors[1], "expected bad.errors[1]")
          return Web.text(("%s:%s:%s"):format(req.method, bad_errors_1.field, assert(bad.submitted).by_name.name[1]),
            { status = bad.status })
        end,
      }),
  } }
  local reply = Web.test_client(app):post("/settings", { form = { name = "Ada", notify = "perhaps", secret = "s3" } })
  assert(reply.status == 422 and reply:text() == "POST:notify:Ada", reply:text())
  assert(not called and assert(assert(seen).submitted).by_name.secret == nil, "the secret is not sent back")
  local ok = Web.test_client(app):post("/settings", { form = { name = "Ada" } })
  assert(ok.status == 204 and called, "an absent checkbox is false")
end

local function test_a_checkbox_form_binds_and_unknown_names_bind_nothing()
  local got: Settings? = nil
  local app = Web.app{ routes = {
    Web.post_typed("/settings", Web.input(Web.NONE, Web.NONE, Web.form_body(SETTINGS)),
      function(_req: Web.Request, _p: Web.None, _q: Web.None, b: Settings): Web.Response
        got = b
        return Web.empty()
      end),
  } }
  local client = Web.test_client(app)
  assert(client:post("/settings", { form = { name = "Ada", notify = { "0", "1" }, is_admin = "1" } }).status == 204)
  local bound = assert(got, "the handler never ran")
  assert(bound.name == "Ada" and bound.notify == true and bound.secret == nil)
  assert((bound as {string:any})["is_admin"] == nil)
end

local function test_the_wrong_content_type_is_415_and_a_big_body_413_and_bad_json_400()
  local app = Web.app{ routes = {
    Web.post_typed("/items", Web.input(Web.NONE, Web.NONE, Web.json_body(NEW)),
      function(_req: Web.Request, _p: Web.None, _q: Web.None, _b: NewItem): Web.Response
        return Web.empty()
      end, { input_options = { max_bytes = 40 } }),
  } }
  local client = Web.test_client(app)
  local reply = client:post("/items", { form = { title = "t", qty = "1" } })
  assert(reply.status == 415 and problem(reply).errors ~= nil)
  reply = client:post("/items", { body = '{"title":"t","qty":1}', content_type = "text/plain" })
  assert(reply.status == 415)
  reply = client:post("/items", { json = { title = ("x"):rep(60), qty = 1 } })
  assert(reply.status == 413)
  assert((problem(reply).errors as {{string:any}})[1].code == "too_large")
  reply = client:post("/items", { body = '{"title":', content_type = "application/json" })
  assert(reply.status == 400 and (problem(reply).errors as {{string:any}})[1].code == "json")
  reply = client:post("/items", { body = "", content_type = "application/json" })
  assert(reply.status == 422 and (problem(reply).errors as {{string:any}})[1].code == "required")
  assert(client:post("/items", { json = { title = "t", qty = 1 } }).status == 204)
end

local function test_a_route_records_what_it_binds()
  local function noop(_req: Web.Request, _p: Web.None, _q: Web.None, _b: Web.None): Web.Response
    return Web.empty()
  end
  local plain = Web.get_typed("/a", Web.input(Web.NONE, Web.NONE, Web.no_body), noop)
  local plain_input = assert(plain.input)
  assert(plain_input.body_kind == "none" and plain_input.path == nil and plain_input.body == nil)
  assert(plain_input.max_bytes == 64 * 1024)
  local big = Web.post_typed("/b", Web.input(Web.NONE, QUERY, Web.form_body(NEW)),
    function(_req: Web.Request, _p: Web.None, _q: Listing, _b: NewItem): Web.Response
      return Web.empty()
    end, { input_options = { max_bytes = 1 << 20 } })
  local big_input = assert(big.input)
  assert(big_input.body_kind == "form" and big_input.query == QUERY.spec and big_input.body == NEW.spec)
  assert(big_input.max_bytes == 1 << 20 and big.methods[1] == "POST")
  assert(Web.get("/c", noop as Web.Handler).input == nil)
end

local function empty_handler(_req: Web.Request, _p: Web.None, _q: Web.None, _b: Web.None): Web.Response
  return Web.empty()
end

local function test_registration_refuses_a_path_that_does_not_match_its_spec()
  local function none_handler(_req: Web.Request, _p: Web.None, _q: Web.None, _b: Web.None): Web.Response
    return Web.empty()
  end
  local why = Test.raises(function()
    Web.get_typed("/items/:name", Web.input(PATH, Web.NONE, Web.no_body), function(_req: Web.Request, _p: ItemPath,
                                                                                   _q: Web.None, _b: Web.None): Web.Response
      return Web.empty()
    end)
  end)
  assert(why:find('"name" is not a field of the path spec', 1, true), why)
  why = Test.raises(function()
    Web.get_typed("/items", Web.input(PATH, Web.NONE, Web.no_body), function(_req: Web.Request, _p: ItemPath,
                                                                             _q: Web.None, _b: Web.None): Web.Response
      return Web.empty()
    end)
  end)
  assert(why:find('"id" is not a parameter of the pattern', 1, true), why)
  why = Test.raises(function()
    Web.get_typed("/items/:id", Web.input(Web.NONE, Web.NONE, Web.no_body), none_handler)
  end)
  assert(why:find('"id" is not a field', 1, true), why)
  assert(#Web.get_typed("/static/*rest", Web.input(REST, Web.NONE, Web.no_body),
    function(_req: Web.Request, _p: Rest, _q: Web.None, _b: Web.None): Web.Response
      return Web.empty()
    end).methods == 1)
end

local function test_registration_refuses_a_body_on_get_and_a_spec_text_cannot_carry()
  local why = Test.raises(function()
    Web.get_typed("/x", Web.input(Web.NONE, Web.NONE, Web.json_body(NEW)),
      function(_req: Web.Request, _p: Web.None, _q: Web.None, _b: NewItem): Web.Response
        return Web.empty()
      end)
  end)
  assert(why:find("GET takes no body", 1, true), why)
  why = Test.raises(function()
    Web.get_typed("/x", Web.input(Web.NONE, MAPPED, Web.no_body),
      function(_req: Web.Request, _p: Web.None, _q: Mapped, _b: Web.None): Web.Response
        return Web.empty()
      end)
  end)
  assert(why:find("map", 1, true), why)
  assert(#Web.route_typed({ "POST", "PATCH" }, "/x", Web.input(Web.NONE, Web.NONE, Web.json_body(MAPPED)),
    function(_req: Web.Request, _p: Web.None, _q: Web.None, _b: Mapped): Web.Response
      return Web.empty()
    end).methods == 2, "JSON carries a map")
  Web.delete_typed("/x", Web.input(Web.NONE, Web.NONE, Web.form_body(NEW)),
    function(_req: Web.Request, _p: Web.None, _q: Web.None, _b: NewItem): Web.Response
      return Web.empty()
    end)
  Web.patch_typed("/x", Web.input(Web.NONE, Web.NONE, Web.no_body), empty_handler)
end

local function test_the_slots_refuse_what_is_not_a_spec()
  local nothing: any = {}
  local why = Test.raises(function()
    Web.json_body(nothing as Shape.Typed<NewItem>)
  end)
  assert(why:find("takes the result of Shape.record_of", 1, true), why)
  why = Test.raises(function()
    Web.input(PATH, Web.NONE, nothing as Web.Body<Web.None>)
  end)
  assert(why:find("Web.json_body", 1, true), why)
end

local function test_a_typed_route_sits_in_a_mount_and_is_found_by_name()
  local app = Web.app{ routes = {
    Web.mount("/api", {
      Web.get_typed("/items/:id", Web.input(PATH, Web.NONE, Web.no_body),
        function(_req: Web.Request, p: ItemPath, _q: Web.None, _b: Web.None): Web.Response
          return Web.json({ id = p.id })
        end, { name = "item" }),
    }, { name = "api" }),
  } }
  local client = Web.test_client(app)
  assert(client:get("/api/items/12"):text() == '{"id":12}')
  assert(app:url_for("api:item", { id = 3 }) == "/api/items/3")
  assert(client:post("/api/items/12").status == 405)
  assert(client:get("/api/items/x").status == 422)
end
