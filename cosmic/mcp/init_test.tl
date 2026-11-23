--- [`cosmic.mcp`]'s shared rules: header values and the tool arguments
--- mirrored into headers.

local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")

local function test_a_header_value_is_plain_where_it_can_be_and_base64_where_not()
  assert(Mcp.header_text("us-west1") == "us-west1")
  assert(Mcp.header_text("Hello, 世界") == "=?base64?SGVsbG8sIOS4lueVjA==?=")
  assert(Mcp.header_text(" padded ") == "=?base64?IHBhZGRlZCA=?=")
  assert(Mcp.header_text("line1\nline2") == "=?base64?bGluZTEKbGluZTI=?=")
  assert(Mcp.header_text("=?base64?literal?=") == "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")
  for _, text in ipairs({ "us-west1", "Hello, 世界", " padded ", "line1\nline2", "=?base64?literal?=", "" }) do
    assert(Mcp.header_read(Mcp.header_text(text)) == text, text)
  end
  assert(Mcp.header_read("a\rb") == nil, "a control byte is refused")
  assert(Mcp.header_read("=?base64?!!?=") == nil, "a sentinel that is not base64 is refused")
end

local function test_mirrors_are_found_by_properties_alone()
  local schema: {string: Json.Value} = {
    type = "object",
    properties = {
      region = { type = "string", ["x-mcp-header"] = "Region" },
      nested = { type = "object", properties = { id = { type = "integer", ["x-mcp-header"] = "Id" } } },
      plain = { type = "string" },
    },
  }
  local mirrors = assert(Mcp.mirrors(schema))
  assert(#mirrors == 2)
  local first, second = assert(mirrors[1]), assert(mirrors[2])
  assert(first.header == "Id" and table.concat(first.path, ".") == "nested.id")
  assert(second.header == "Region" and table.concat(second.path, ".") == "region")
  local id, _ = Mcp.mirror_value({ nested = { id = 42 } }, first.path)
  assert(id == "42")
  local absent, _ = Mcp.mirror_value({}, first.path)
  assert(absent == false)
  local yes, _ = Mcp.mirror_value({ region = true }, second.path)
  assert(yes == "true")
  local none, why = Mcp.mirror_value({ region = 1.5 }, second.path)
  assert(none == nil and tostring(why):find("not a string", 1, true) ~= nil)
  local big, bwhy = Mcp.mirror_value({ nested = { id = 9007199254740992 } }, first.path)
  assert(big == nil and tostring(bwhy):find("past", 1, true) ~= nil)
end

local function test_a_mirror_the_transport_refuses_is_refused()
  local function refused(schema: {string: Json.Value}, says: string)
    local got, why = Mcp.mirrors(schema)
    assert(got == nil and tostring(why):find(says, 1, true) ~= nil, tostring(why))
  end
  refused({ type = "object", properties = { n = { type = "number", ["x-mcp-header"] = "N" } } }, "not a string")
  refused({ type = "object", properties = { a = { type = "array", items = { type = "string", ["x-mcp-header"] = "A" } } } },
    "not reached by properties")
  refused({ type = "object", oneOf = Json.array({ { properties = { a = { type = "string", ["x-mcp-header"] = "A" } } } }) },
    "not reached by properties")
  refused({ type = "object", properties = { a = { type = "string", ["x-mcp-header"] = "A" }, b = { type = "string", ["x-mcp-header"] = "a" } } },
    "named twice")
  refused({ type = "object", properties = { a = { type = "string", ["x-mcp-header"] = "A B" } } }, "not an HTTP header name")
  local default: {string: Json.Value} = { type = "object", properties = { a = { type = "string", default = { ["x-mcp-header"] = "A" } } } }
  assert(#assert(Mcp.mirrors(default)) == 0, "a default's members are data")
end

local function test_a_result_turns_strings_into_text()
  local r = Mcp.result({ "a", Mcp.image("\x89PNG", "image/png") }, true)
  assert(r.isError == true and #r.content == 2)
  assert(assert(r.content[1]).text == "a" and assert(r.content[2]).data == "iVBORw==")
  assert(Mcp.result({}).isError == nil)
end
