# web forms and uploads

<!-- policy: loopback = { "127.0.0.1" }, profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

A form is text that a person typed, and the binder in [`cosmic.web`] turns
it into a record your handler can trust: a route names the shape of its
path parameters, its query and its body, and input that does not fit is
answered before the handler runs. This guide builds `signup`, a form that
checks its fields and shows what was wrong, and an upload route with its
limits. It starts from an empty directory and needs only what the first
guide, [web apps](web.md), says about routes and templates: a route is a
method, a pattern and a handler, and a `.tmpl` file is a typed template.

## typed routes

A route made with [`Web.post_typed`] and its siblings names
[`cosmic.shape`] specs for its path parameters, its query and its body
([`Web.input`]). The handler is then given checked records in that order,
after the request: the spec `SIGNUP` below is `Shape.record_of("Signup")`,
so the handler reads `form.email` as a `string` that is certainly there. A
slot a route does not read is [`Web.NONE`] (or [`Web.no_body`]) and its
parameter is an empty [`Web.None`].

A form is text, so the binder reads by the spec: `integer` from digits, a
`boolean` from its presence, a list from a name sent twice, an empty
optional field as nil. [`Web.form_body`] reads a urlencoded form,
[`Web.json_body`] a JSON body ([the API guide](web-api.md) uses it) and
[`Web.multipart_body`] an upload. A route that wants to read for itself
calls [`Input.form`], [`Input.json`] or [`Input.multipart`] on its request.

## what a refusal is

The statuses keep four failures apart:

- **400**: input that cannot be decoded at all (a bad percent-escape,
  malformed JSON).
- **415**: a wrong `Content-Type`, such as JSON posted to a form route.
- **413**: a body over its limit (below).
- **422**: a value that decodes but fails its spec.

A form re-renders on 422 with every field's error; an API answers
`application/problem+json`, each error with the JSON Pointer of the value
that failed (a JSON body reports its first failure). A route's `on_invalid`
turns the refusal into whatever the route wants, as `refuse` does below;
[`Input.errors_by_field`] gives the messages and [`Input.value`] the text the
person typed (leave a password out with `secret`). A rule no spec can state,
such as an email already taken, is the handler's, reported the same way with
[`Input.fail`].

## re-rendering a form

The page is the form: each field shows the text that was typed and the
message beside it. It is a plain form, which works with or without htmx;
the first guide shows the htmx attributes. A page that changes state also
needs a CSRF token, which [the security guide](web-security.md) adds; this
project leaves it out so the form stays the subject.

```teal file=pages/data.tl
--- What the templates beside it render.
local record data
  record Form
    email: string
    age: string
    email_error: string | nil
    age_error: string | nil
  end
end

return data
```

```teal file=pages/signup.tmpl
{{type Form from pages.data}}
<form method="post" action="/signup">
  <label>email <input name="email" value="{{.email}}"></label>
  {{if .email_error}}<p class="error">{{.email_error}}</p>{{end}}
  <label>age <input name="age" value="{{.age}}"></label>
  {{if .age_error}}<p class="error">{{.age_error}}</p>{{end}}
  <button>sign up</button>
</form>
```

The routes show the form, bind a post to `Signup` and, whatever the
refusal, answer it with the same form. `age` is optional, so a form that
leaves it empty binds it as nil.

```teal file=signup.tl
--- The signup form: a page, and a post that binds, checks and answers.

local Input = require("cosmic.web.input")
local Shape = require("cosmic.shape")
local Web = require("cosmic.web")
local page = require("pages.signup")

local record Site
end

local record Signup
  email: string
  age: integer | nil
end
local SIGNUP <const> = Shape.record_of("Signup")

--- The form again, each field with what was typed and what was wrong.
local function refuse(_req: Web.Request, bad: Web.Invalid): Web.Response
  local errors = Input.errors_by_field(bad)
  return Web.html(page.render({
    email = Input.value(bad, "email"), age = Input.value(bad, "age"),
    email_error = errors.email, age_error = errors.age,
  }), { status = bad.status })
end

local function join(req: Web.Request, _p: Web.None, _q: Web.None, b: Signup): Web.Response
  -- A rule no spec can state is the handler's, reported the same way.
  if not b.email:find("@", 1, true) then
    return refuse(req, Input.fail(req, "email", "that is not an email address"))
  end
  return Web.text("welcome " .. b.email, { status = 201 })
end

--- The routes of the signup form.
function Site.routes(): {Web.Route}
  return {
    Web.get("/signup", function(_req: Web.Request): Web.Response
      return Web.html(page.render({ email = "", age = "" }))
    end),
    Web.post_typed("/signup", Web.input(Web.NONE, Web.NONE, Web.form_body(SIGNUP)), join,
      { on_invalid = refuse }),
  }
end

return Site
```

The test goes through each kind of refusal. A form that binds reaches the
handler; an `age` that is no integer is a 422 that shows the message beside
the field and keeps what was typed; undecodable input is a 400 and JSON
posted to a form route a 415. A form over 64 KiB is a 413, the default for
every body but an upload.

```teal file=signup_test.tl
local Signup = require("signup")
local Web = require("cosmic.web")

local function client(): Web.TestClient
  return Web.test_client(Web.app{ routes = Signup.routes() })
end

local function test_a_form_that_binds_reaches_the_handler()
  local reply = client():post("/signup", { form = { email = "ada@example.org", age = "36" } })
  assert(reply.status == 201 and reply:text() == "welcome ada@example.org")
  assert(client():post("/signup", { form = { email = "ada@example.org" } }).status == 201, "age is optional")
end

local function test_a_value_that_fails_its_spec_is_422_and_the_form_comes_back()
  local reply = client():post("/signup", { form = { email = "ada@example.org", age = "old" } })
  assert(reply.status == 422)
  assert(reply.body:find('value="old"', 1, true), "what was typed is kept")
  assert(reply.body:find('<p class="error">', 1, true), "and the message is beside the field")
end

local function test_a_rule_of_the_handler_is_reported_like_a_spec()
  local reply = client():post("/signup", { form = { email = "ada" } })
  assert(reply.status == 422 and reply.body:find("not an email address", 1, true))
end

local function test_input_that_cannot_be_decoded_is_400()
  local reply = client():post("/signup", { body = "email=%zz",
    content_type = "application/x-www-form-urlencoded" })
  assert(reply.status == 400)
end

local function test_a_form_route_reads_no_json()
  assert(client():post("/signup", { json = { email = "x" } }).status == 415)
end

local function test_a_form_is_limited_to_64_kib()
  local reply = client():post("/signup", { form = { email = ("x"):rep(70 * 1024) } })
  assert(reply.status == 413)
end
```

## uploads

An upload is a multipart form. Its text parts bind to the record and each
file part is spooled to a private file under a random name, removed when the
handler returns unless it moves the file. The client's file name is for
display only: it is cut to its last component.

Three limits apply, and the smallest wins:

- **`max_bytes`**, the largest body a route reads. It is 64 KiB for a form
  or a JSON body and 16 MiB for a multipart one. A route changes it in its
  `input_options`.
- **`max_file_bytes`**, the largest single file part: 8 MiB by default,
  also an `input_options` field. A file over it is a 413.
- **`limits.body_bytes`**, the server's own limit on every request, 1 MiB
  by default. The server answers 413 past it before the route is known, so
  a route that allows more than that cannot receive it: a larger upload
  needs [`Web.serve`] given a higher `limits.body_bytes`, for the whole app
  ([the deployment guide](web-deploy.md) shows where).

The test client calls the app in-process and does not meet the server's
limit; [`Web.with_server`] serves the app on the loopback and does. A test
that opens a socket declares `loopback` in its [`Test.policy`].

```teal file=upload.tl
--- An avatar upload: a text part bound to a record, a file part spooled.

local Input = require("cosmic.web.input")
local Shape = require("cosmic.shape")
local Web = require("cosmic.web")

local record Upload
end

local record Avatar
  name: string
end
local AVATAR <const> = Shape.record_of("Avatar")

--- The upload route. A file may be 1 MiB; the body as a whole 2 MiB, which
--- the server's own limit (1 MiB by default) still comes before.
function Upload.routes(): {Web.Route}
  return {
    Web.post_typed("/avatar", Web.input(Web.NONE, Web.NONE, Web.multipart_body(AVATAR)),
      function(req: Web.Request, _p: Web.None, _q: Web.None, form: Avatar): Web.Response
        local file = assert(Input.multipart(req).value).files["avatar"][1]
        return Web.text(form.name .. ":" .. file.filename .. ":" .. file.size)
      end, { input_options = { max_bytes = 2 * 1024 * 1024, max_file_bytes = 1024 * 1024 } }),
  }
end

return Upload
```

```teal file=upload_test.tl
local Test = require("cosmic.test")
local Upload = require("upload")
local Web = require("cosmic.web")

Test.policy{ loopback = { "127.0.0.1" } }

local BOUNDARY <const> = "multipart/form-data; boundary=xyz"

local function app(): Web.App
  return Web.app{ routes = Upload.routes() }
end

--- A multipart body with a text part and one file part of `size` bytes.
local function body(size: integer): string
  return '--xyz\r\nContent-Disposition: form-data; name="name"\r\n\r\nAda\r\n' ..
    '--xyz\r\nContent-Disposition: form-data; name="avatar"; filename="../a.png"\r\n' ..
    'Content-Type: image/png\r\n\r\n' .. ("x"):rep(size) .. '\r\n--xyz--\r\n'
end

local function test_a_file_part_is_spooled_and_the_text_part_bound()
  local sent = Web.test_client(app()):post("/avatar", { body = body(3), content_type = BOUNDARY })
  assert(sent:text() == "Ada:a.png:3", "the client's path is cut to its last component")
end

local function test_a_file_over_max_file_bytes_is_413()
  local sent = Web.test_client(app()):post("/avatar", { body = body(1024 * 1024 + 1), content_type = BOUNDARY })
  assert(sent.status == 413)
end

local function test_the_servers_body_limit_comes_before_the_route_allows_more()
  Web.with_server(app(), function(client: Web.LoopbackClient)
    local refused = assert(client:post("/avatar", { body = body(1024 * 1024), content_type = BOUNDARY }))
    assert(refused.status == 413, "1 MiB of file and a little more is past limits.body_bytes")
  end)
end
```

`cosmic test` builds the project and runs both test files. The next block
does it through [`cosmic.child`], as the guide for the command line does,
and prints the verdict line, or everything the run said when it did not pass.

```teal
local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local Clock = require("cosmic.clock")

local relaunch = assert(Proc.relaunch())
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
env["COSMIC_TEST_SANDBOX"] = "0"
local argv = { table.unpack(relaunch.argv) }
argv[#argv + 1] = "test"
local said = assert(Child.run(argv,
  { env = env, fds = relaunch.fds, cwd = tmp, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(120) }))
local out = (said.stderr or "") .. (said.stdout or "")
local passed = out:match("test: %d+ tests? passed")
-- The whole run where it did not pass, so a failure says which test and why.
print(passed or out)
```

```output
test: 9 tests passed
```

[`cosmic.child`]: ../../cosmic/child.tl
[`cosmic.shape`]: ../../cosmic/shape.tl
[`cosmic.web`]: ../../cosmic/web/init.tl
[`Input.errors_by_field`]: ../../cosmic/web/input.tl
[`Input.fail`]: ../../cosmic/web/input.tl
[`Input.form`]: ../../cosmic/web/input.tl
[`Input.json`]: ../../cosmic/web/input.tl
[`Input.multipart`]: ../../cosmic/web/input.tl
[`Input.value`]: ../../cosmic/web/input.tl
[`Test.policy`]: ../../cosmic/test.tl
[`Web.form_body`]: ../../cosmic/web/init.tl
[`Web.input`]: ../../cosmic/web/init.tl
[`Web.json_body`]: ../../cosmic/web/init.tl
[`Web.multipart_body`]: ../../cosmic/web/init.tl
[`Web.no_body`]: ../../cosmic/web/init.tl
[`Web.NONE`]: ../../cosmic/web/init.tl
[`Web.post_typed`]: ../../cosmic/web/init.tl
[`Web.serve`]: ../../cosmic/web/init.tl
[`Web.with_server`]: ../../cosmic/web/init.tl
