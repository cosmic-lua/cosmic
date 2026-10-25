--- Fuzz properties for the form binder, which reads text a client chose:
--- binding never raises, and what it answers is either a value the spec
--- accepts or a refusal that lists its errors; a Content-Type header of
--- any bytes parses to something total.

local Fuzz = require("build.fuzz")
local Input = require("cosmic.web.input")
local Shape = require("cosmic.shape")
local Server = require("cosmic.http.server")
local Stream = require("cosmic.stream")
local Types = require("cosmic.web.types")
local Web = require("cosmic.web")
local Url = require("cosmic.url")

local record Inner
  city: string
  zip: integer?
end
local SPECS <const>: {Shape.Spec} = {
  Shape.record({
    name = Shape.string, age = Shape.integer, score = Shape.number, on = Shape.boolean,
    color = Shape.one_of("red", "green"), nick = Shape.optional(Shape.string),
    limit = Shape.optional(Shape.integer), tags = Shape.list(Shape.string), nums = Shape.list(Shape.integer),
    inner = Shape.record({ city = Shape.string, zip = Shape.optional(Shape.integer) }),
    maybe = Shape.optional(Shape.record({ city = Shape.string, zip = Shape.optional(Shape.integer) })),
  }),
  Shape.strict_record({ a = Shape.optional(Shape.boolean), b = Shape.optional(Shape.number),
    c = Shape.optional(Shape.list(Shape.one_of(1, 2.5, true, "x"))) }),
  Shape.record({ id = Shape.integer, kind = Shape.one_of("a", "b"), live = Shape.boolean }),
}

local NAMES <const>: {{string}} = {
  { "name", "age", "score", "on", "color", "nick", "limit", "tags", "nums", "inner.city", "inner.zip",
    "maybe.city", "maybe.zip", "inner", "is_admin", "csrf_token", "tags.0", "", ".", "a.b.c.d.e" },
  { "a", "b", "c", "d", "csrf_token", "c.0" },
  { "id", "kind", "live", "other" },
}

local VALUES <const>: {string} = { "", "0", "1", "-1", "42", " 7 ", "+5", "1.5", "1e3", "1e999", ".5", "1.", "x",
  "true", "false", "on", "off", "yes", "no", "TRUE", "red", "green", "a", "b", "2.5",
  "9223372036854775807", "9223372036854775808", "-9223372036854775808", "99999999999999999999",
  "0x10", "inf", "nan", "a\0b", "\xff", "é" }

local function gen_pairs(src: Fuzz.Source): string
  local which = src:int(1, #SPECS)
  local fields: mut {string} = { tostring(which) }
  while Fuzz.more(src, #fields // 2, 12) do
    local name = src:int(0, 9) == 0 and Fuzz.bytes(src, 6) or Fuzz.pick(src, NAMES[which])
    local value = src:int(0, 5) == 0 and Fuzz.bytes(src, 8) or Fuzz.pick(src, VALUES)
    fields[#fields + 1] = name
    fields[#fields + 1] = value
  end
  return Fuzz.pack(fields)
end

local KNOWN_CODES <const>: {string:boolean} = { required = true, integer = true, number = true, boolean = true,
  one_of = true, type = true, unknown = true, repeated = true }

local function test_binding_never_raises_and_answers_a_value_or_every_error(tmp: string)
  Fuzz.run({
    name = "web form binder",
    dir = tmp,
    gen = gen_pairs,
    requires = { "bound", "invalid", "many_errors" },
    shares = { bound = 0.02, invalid = 0.2 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local which = math.tointeger(tonumber(fields[1])) or 1
      local spec = SPECS[which]
      local q: Url.Query = { pairs = {}, by_name = {} }
      for i = 2, #fields - 1, 2 do
        local name, value = fields[i], fields[i + 1]
        q.pairs[#q.pairs + 1] = { name = name, value = value }
        local list = q.by_name[name]
        if list == nil then
          list = {}
          q.by_name[name] = list
        end
        list[#list + 1] = value
      end
      local ok, r = pcall(function(): Types.Parsed<{string:any}>
        return Input.bind_strings(q, spec, { secret = { "name" }, repeated = if which == 2 then "error" else nil end })
      end)
      if not ok then return false, "raised: " .. tostring(r) end
      local invalid = r.invalid
      if invalid == nil then
        local r_value = r.value
        if r_value == nil then return false, "neither a value nor a refusal" end
        local again, why = Shape.into(r_value, spec)
        if again == nil then return false, "the value fails its own spec: " .. why end
        Fuzz.label("bound")
        return true, ""
      end
      local bad = invalid
      if r.value ~= nil then return false, "both a value and a refusal" end
      if bad.status ~= 422 or #bad.errors == 0 or bad.message == "" then
        return false, ("a refusal of status %d with %d errors"):format(bad.status, #bad.errors)
      end
      for _, e in ipairs(bad.errors) do
        if e.source ~= "form" or e.message == "" or not KNOWN_CODES[e.code] or e.pointer ~= nil then
          return false, ("a bad error: %s/%s/%s"):format(e.source, e.field, e.code)
        end
      end
      if assert(bad.submitted).by_name["name"] ~= nil then return false, "a secret was kept" end
      Fuzz.label("invalid")
      if #bad.errors > 2 then Fuzz.label("many_errors") end
      return true, ""
    end,
  })
end

local function test_a_content_type_of_any_bytes_parses(tmp: string)
  local HEADS <const>: {string} = { "application/json", "multipart/form-data; boundary=", "text/plain;charset=",
    'a/b; c="', "a/b;;;", ";", "", "a/b; c=d; e=\"f\\", "\"", "a/b ; c = d" }
  Fuzz.run({
    name = "web media type",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      if src:int(0, 2) == 0 then return Fuzz.bytes(src, 24) end
      return Fuzz.mutate(src, Fuzz.pick(src, HEADS), 4)
    end,
    requires = { "typed", "empty" },
    shares = { typed = 0.1 },
    check = function(input: string): boolean, string
      local req = { headers = { ["content-type"] = input } } as Types.Request
      local ok, m = pcall(Input.media_type, req)
      if not ok then return false, "raised: " .. tostring(m) end
      if m.essence ~= m.essence:lower() then return false, "essence not lowercase" end
      for name in pairs(m.params) do
        if name ~= name:lower() then return false, "parameter name not lowercase" end
      end
      Fuzz.label(if m.essence:find("/", 1, true) then "typed" else "empty" end)
      return true, ""
    end,
  })
end

local record Doc
  title: string
  qty: integer
  tags: {string}?
  address: Inner?
end
local DOC <const> = Shape.record_of("Doc")

local function test_json_refusals_point_at_the_field_they_name(tmp: string)
  local TEXTS <const>: {string} = { '{"title":"t","qty":1}', '{"qty":"x"}', '{"title":null}', "[]", "null", '"s"',
    '{"title":1,"qty":1.5,"tags":[1]}', '{"address":{"city":3}}', "{", "", '{"tags":{"a":1}}',
    '{"title":"t","qty":1,"address":{"city":"c","zip":"z"}}' }
  local last = { value = nil as Types.Parsed<Doc>? }
  local app = Web.app{ routes = { Web.post("/x", function(req: Web.Request): Web.Response
    last.value = Input.json_into(req, DOC)
    return Web.empty()
  end) }, sink = { line = function(_self: Web.Sink, _text: string) end } }
  Fuzz.run({
    name = "web json pointer",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.mutate(src, Fuzz.pick(src, TEXTS), 3)
    end,
    requires = { "bound", "pointed", "unreadable" },
    shares = { pointed = 0.1 },
    check = function(input: string): boolean, string
      last.value = nil
      local raw: Server.Request = { method = "POST", target = "/x", path = "/x", query = "", version = "HTTP/1.1",
        headers = { host = "x", ["content-type"] = "application/json" }, body = Stream.from_string(input),
        length = #input }
      local res = app.handle(raw)
      if res.status ~= 204 then return false, "the handler faulted: " .. res.status end
      local parsed = last.value
      if parsed == nil then return false, "the handler parsed nothing" end
      local invalid = parsed.invalid
      if invalid == nil then
        if parsed.value == nil then return false, "neither a value nor a refusal" end
        Fuzz.label("bound")
        return true, ""
      end
      local bad = invalid
      if bad.status ~= 400 and bad.status ~= 422 then return false, "status " .. bad.status end
      local e = bad.errors[1]
      if #bad.errors ~= 1 or e.message == "" or e.source ~= "body" then return false, "errors" end
      if bad.status == 400 then
        Fuzz.label("unreadable")
        return true, ""
      end
      local pointer = e.pointer
      if pointer == nil then return false, "a JSON refusal without a pointer" end
      if pointer ~= "" and "/" .. e.field:gsub("%.", "/") ~= pointer then
        return false, ("field %q is not pointer %q"):format(e.field, pointer)
      end
      if pointer == "" and e.field ~= "" then return false, "a field beside the root pointer" end
      Fuzz.label("pointed")
      return true, ""
    end,
  })
end
