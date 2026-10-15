--- Worked examples for cosmic.web.input and the typed routes of
--- [`cosmic.web`], shown by `cosmic docs` and run by `cosmic test`.

local Fs = require("cosmic.fs")
local Input = require("cosmic.web.input")
local Shape = require("cosmic.shape")
local Url = require("cosmic.url")
local Web = require("cosmic.web")

local Example = {}

local record Signup
  email: string
  age: integer | nil
  news: boolean
  tags: {string}
end
local SIGNUP <const> = Shape.record_of("Signup")

--- A form carries text, so the binder reads each field as its spec says: a
--- number from digits, a checkbox from its presence, a list from a name
--- sent more than once, and an empty optional field as nil.
function Example.bind()
  local q = assert(Url.decode_query("email=ada%40example.org&age=&tags=a&tags=b"))
  local bound: Web.Parsed<Signup> = Input.bind_strings(q, SIGNUP.spec)
  assert(bound.invalid == nil)
  local form = assert(bound.value)
  assert(form.email == "ada@example.org" and form.age == nil)
  assert(form.news == false, "an unchecked box sends nothing")
  assert(#form.tags == 2 and form.tags[2] == "b")
end

--- Every field's error comes back at once, in the spec's field order, so a
--- form can re-render with all of its messages; `secret` names are left out
--- of the values it hands back.
function Example.every_error()
  local q = assert(Url.decode_query("email=&age=old&news=maybe&password=hunter2"))
  local bound: Web.Parsed<Signup> = Input.bind_strings(q, SIGNUP.spec, { secret = { "password" } })
  local bad = assert(bound.invalid)
  assert(bad.status == 422)
  local messages = Input.errors_by_field(bad)
  assert(messages.age == "must be a whole number")
  assert(messages.news == "must be true or false")
  assert(Input.value(bad, "age") == "old" and Input.value(bad, "password") == "")
  print(bad.message) -- age: must be a whole number (and 2 more)
end

--- A typed route binds before the handler runs; a handler that annotates
--- its parameters is checked against the specs, and one for a form can
--- re-render with `on_invalid`.
function Example.typed_route()
  local app = Web.app{ routes = {
    Web.post_typed("/signup", Web.input(Web.NONE, Web.NONE, Web.form_body(SIGNUP)),
      function(_req: Web.Request, _p: Web.None, _q: Web.None, form: Signup): Web.Response
        return Web.text("welcome " .. form.email, { status = 201 })
      end, {
        on_invalid = function(_req: Web.Request, bad: Web.Invalid): Web.Response
          return Web.text(Input.errors_by_field(bad).email or "", { status = bad.status })
        end,
      }),
  } }
  local client = Web.test_client(app)
  local created = client:post("/signup", { form = { email = "ada@example.org" } })
  assert(created.status == 201 and created:text() == "welcome ada@example.org")
  local refused = client:post("/signup", { form = { age = "3" } })
  assert(refused.status == 422 and refused:text() == "is required")
end

local record Note
  title: string
  tags: {string} | nil
end
local NOTE <const> = Shape.record_of("Note")

--- A JSON route answers a refusal as `application/problem+json`, each
--- error with the JSON Pointer of the value that failed.
function Example.json_body()
  local app = Web.app{ routes = {
    Web.post_typed("/notes", Web.input(Web.NONE, Web.NONE, Web.json_body(NOTE)),
      function(_req: Web.Request, _p: Web.None, _q: Web.None, note: Note): Web.Response
        return Web.json({ saved = note.title }, { status = 201 })
      end),
  } }
  local client = Web.test_client(app)
  local reply = client:post("/notes", { json = { title = "t", tags = { "a", 2 } } })
  assert(reply.status == 422 and reply.headers["content-type"] == "application/problem+json")
  local body = reply:json() as {string:any}
  local first = (body.errors as {{string:any}})[1]
  assert(first.pointer == "/tags/1" and first.field == "tags.1", tostring(first.pointer))
  print(body.detail) -- tags.1: expected string, got integer
  local wrong = client:post("/notes", { body = '{"title":"t"}', content_type = "text/plain" })
  assert(wrong.status == 415, "a cross-site form cannot send application/json")
end

--- A spec text cannot carry is refused when the route is made, not on the
--- first request.
function Example.check_spec()
  local ok, err = pcall(function(): any
    Input.check_spec(Shape.record({ extra = Shape.map(Shape.string) }), "form")
    return nil
  end)
  assert(not ok)
  print(err) -- input: field extra of a form is a map, which text cannot carry
end

local record Query
  page: integer | nil
end
local PAGE <const> = Shape.record_of("Query")

--- A route without specs reads its input itself: the form is decoded once
--- and shared with whatever else reads it, and a refusal of the handler's
--- own is built over the same values.
function Example.plain_route()
  local app = Web.app{ routes = {
    Web.post("/signup", function(req: Web.Request): Web.Response
      local read = Input.form(req)
      if read.invalid ~= nil then
        return Web.text(read.invalid.message, { status = read.invalid.status })
      end
      assert(rawequal(req:get(Input.FORM), read.value))
      if Url.query_last(assert(read.value), "email") == "taken@example.org" then
        local bad = Input.fail(req, "email", "is already registered", { secret = { "password" } })
        return Web.text(Input.errors_by_field(bad).email, { status = bad.status })
      end
      return Web.empty()
    end),
    Web.post("/json", function(req: Web.Request): Web.Response
      local read = Input.json(req)
      if read.invalid ~= nil then
        return Web.text(read.invalid.message, { status = read.invalid.status })
      end
      assert(rawequal(req:get(Input.JSON), read.value))
      return Web.text(Input.media_type(req).essence)
    end),
    Web.get("/page", function(req: Web.Request): Web.Response
      local q = Input.query(req)
      if q.invalid ~= nil then return Web.text(q.invalid.message, { status = q.invalid.status }) end
      return Web.text(tostring(#assert(q.value).pairs))
    end),
  } }
  local client = Web.test_client(app)
  assert(client:post("/signup", { form = { email = "taken@example.org" } }).status == 422)
  assert(client:post("/signup", { form = { email = "new@example.org" } }).status == 204)
  assert(client:post("/signup", { body = "email=x", content_type = "text/plain" }).status == 415)
  assert(client:post("/json", { json = { a = 1 } }):text() == "application/json")
  assert(client:get("/page?a=1&b=2"):text() == "2")
  assert(client:get("/page?a=%zz").status == 400)
end

local record Profile
  display_name: string
end
local PROFILE <const> = Shape.record_of("Profile")

--- A multipart route binds its text parts like a form's; each file part is
--- spooled under a random name, with the client's filename kept for display
--- alone, and removed when the handler returns unless it moves the file.
function Example.upload()
  local kept: {string} = {}
  local app = Web.app{ routes = {
    Web.post_typed("/profile", Web.input(Web.NONE, Web.NONE, Web.multipart_body(PROFILE)),
      function(req: Web.Request, _p: Web.None, _q: Web.None, form: Profile): Web.Response
        local avatar = assert(Input.multipart(req).value).files["avatar"][1]
        assert(avatar.path:find(avatar.filename, 1, true) == nil, "the client's name is no part of the path")
        kept[1] = assert(Fs.read(avatar.path))
        return Web.text(form.display_name .. ":" .. avatar.filename .. ":" .. avatar.size)
      end, { input_options = { max_file_bytes = 1024 } }),
  } }
  local boundary = "xyz"
  local body = '--xyz\r\nContent-Disposition: form-data; name="display_name"\r\n\r\nAda\r\n' ..
    '--xyz\r\nContent-Disposition: form-data; name="avatar"; filename="../../a.png"\r\n' ..
    'Content-Type: image/png\r\n\r\nPNG\r\n--xyz--\r\n'
  local reply = Web.test_client(app):post("/profile", { body = body,
    content_type = "multipart/form-data; boundary=" .. boundary })
  assert(reply:text() == "Ada:a.png:3" and kept[1] == "PNG", reply:text())
end

--- Each method has a typed constructor; a slot a route does not read is
--- [`Web.NONE`], or [`Web.no_body`], and its parameter is an empty [`Web.None`].
function Example.methods()
  local function show(_req: Web.Request, _p: Web.None, q: Query, _b: Web.None): Web.Response
    return Web.text(tostring(q.page))
  end
  local app = Web.app{ routes = {
    Web.get_typed("/get", Web.input(Web.NONE, PAGE, Web.no_body), show),
    Web.route_typed({ "GET", "POST" }, "/both", Web.input(Web.NONE, PAGE, Web.no_body), show),
    Web.put_typed("/put", Web.input(Web.NONE, PAGE, Web.no_body), show),
    Web.patch_typed("/patch", Web.input(Web.NONE, PAGE, Web.no_body), show),
    Web.delete_typed("/delete", Web.input(Web.NONE, PAGE, Web.form_body(Shape.record_of("Query"))),
      function(_req: Web.Request, _p: Web.None, q: Query, b: Query): Web.Response
        return Web.text(tostring(q.page) .. tostring(b.page))
      end),
  } }
  local client = Web.test_client(app)
  assert(client:get("/get?page=3"):text() == "3")
  assert(client:post("/both?page=4"):text() == "4")
  assert(client:put("/put?page=5"):text() == "5")
  assert(client:patch("/patch?page=6"):text() == "6")
  assert(client:delete("/delete?page=7", { form = { page = "8" } }):text() == "78")
end

return Example
