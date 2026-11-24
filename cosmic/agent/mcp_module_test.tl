--- `McpModule.made`: the Teal of an MCP server's module, of its tools' schemas.
local Json = require("cosmic.json")
local Lexer = require("lang.lexer")
local McpModule = require("cosmic.agent.mcp_module")

local function has(text: string, part: string)
  assert(text:find(part, 1, true) ~= nil, "missing " .. part .. " in:\n" .. text)
end

local function test_a_tools_schemas_are_records_of_its_members()
  local made = McpModule.made("notes", { {
    name = "search",
    description = "Finds notes.\n  Many.",
    inputSchema = {
      type = "object",
      required = Json.array({ "query" }),
      properties = {
        query = { type = "string", description = "What to find." },
        limit = { type = Json.array({ "integer", "null" }) },
        tags = { type = "array", items = { type = "string" } },
        filter = { type = "object", properties = { after = { type = "number" }, done = { type = "boolean" } } },
        extra = { type = "object", additionalProperties = { type = "integer" } },
        loose = { type = "object" },
        either = { anyOf = Json.array({ { type = "string" }, { type = "integer" } }) },
      },
    },
  } })
  assert(made.module == "mcp.notes")
  local teal = made.teal
  has(teal, "local record notes\n")
  has(teal, "  record SearchInput\n")
  has(teal, "    --- What to find.\n    query: string\n")
  has(teal, "    limit?: integer\n")
  has(teal, "    tags?: {string}\n")
  has(teal, "  record SearchInputFilter\n    after?: number\n    done?: boolean\n  end\n")
  has(teal, "    filter?: SearchInputFilter\n")
  has(teal, "    extra?: {string: integer}\n")
  has(teal, "    loose?: {string: Json.Value}\n")
  has(teal, "    either?: Json.Value\n")
  has(teal, "  --- Finds notes. Many.\n  search: function(arguments: SearchInput): Host.Result\n")
  has(teal, "return notes\n")
  local f = assert(made.functions[1])
  assert(f.name == "search" and f.tool == "search" and not f.structured)
end

local function test_a_tool_with_an_output_schema_answers_its_record()
  local made = McpModule.made("box", { {
    name = "weigh",
    inputSchema = { type = "object" },
    outputSchema = { type = "object", properties = { grams = { type = "integer" } }, required = Json.array({ "grams" }) },
  }, {
    name = "loose",
    inputSchema = { type = "object" },
    outputSchema = { type = "object" },
  } })
  has(made.teal, "  record WeighOutput\n    grams: integer\n  end\n")
  has(made.teal, "  weigh: function(arguments?: {string: Json.Value}): WeighOutput\n")
  -- An output that is no record is read from the result, as a tool with none.
  has(made.teal, "  loose: function(arguments?: {string: Json.Value}): Host.Result\n")
  assert(assert(made.functions[1]).structured and not assert(made.functions[2]).structured)
end

local function test_a_name_teal_cannot_hold_is_renamed_or_read_as_a_map()
  local made = McpModule.made("end", { {
    name = "get-file", inputSchema = { type = "object", properties = { ["file-name"] = { type = "string" } } },
  }, { name = "get_file", inputSchema = { type = "object" } }, { name = "2fa", inputSchema = { type = "object" } } })
  has(made.teal, "local record server\n")
  has(made.teal, "  --- The tool \"get-file\".\n  get_file: function(arguments?: {string: Json.Value})")
  has(made.teal, "  get_file_2: function(")
  has(made.teal, "  _2fa: function(")
  local f = assert(made.functions[2])
  assert(f.name == "get_file_2" and f.tool == "get_file")
end

--- Each function holds its tool's description and the Teal of a module of it alone, named as in the whole module, so
--- a tool with no name shifts no other tool's.
local function test_each_function_holds_its_description_and_its_own_teal()
  local made = McpModule.made("files", { { name = 7, description = "nameless" }, {
    name = "get-file", description = "Reads a file.",
    inputSchema = { type = "object", properties = { path = { type = "string" } }, required = { "path" } },
  }, { name = "get_file", description = "Reads another.", inputSchema = { type = "object",
    properties = { size = { type = "integer" } } } } })
  local first, second = assert(made.functions[1]), assert(made.functions[2])
  assert(#made.functions == 2 and first.description == "Reads a file." and second.description == "Reads another.")
  has(second.teal, "record GetFile2Input\n")
  has(second.teal, "  get_file_2: function(arguments?: GetFile2Input)")
  assert(second.teal:find("GetFileInput", 1, true) == nil and second.teal:find("get-file", 1, true) == nil, second.teal)
  has(first.teal, "  --- The tool \"get-file\".\n  get_file: function(arguments: GetFileInput)")
  assert(first.teal:find("get_file_2", 1, true) == nil, first.teal)
end

local function test_each_word_teal_reserves_is_no_member_or_function()
  local words: mut {string} = {}
  for w in pairs(Lexer.reserved) do words[#words + 1] = w end
  for _, w in ipairs(words) do
    local made = McpModule.made("s", { { name = w, inputSchema = { type = "object", properties = { [w] = { type = "string" } } } } })
    has(made.teal, "  " .. w .. "_: function(arguments?: {string: Json.Value})")
  end
  -- A word that begins a declaration names a member, as `type` of a content block does.
  for _, w in ipairs(Lexer.declaration_words) do
    local made = McpModule.made("s", { { name = w, inputSchema = { type = "object", properties = { [w] = { type = "string" } } } } })
    has(made.teal, "    " .. w .. "?: string\n")
    has(made.teal, "  " .. w .. ": function(arguments?: ")
  end
end

local function test_a_deep_schema_ends_in_json_values()
  local schema: Json.Value = { type = "string" }
  for _ = 1, 12 do schema = { type = "object", properties = { inner = schema } } end
  local made = McpModule.made("deep", { { name = "t", inputSchema = schema } })
  has(made.teal, "inner?: Json.Value\n")
end

local function test_an_outputs_nullable_member_is_optional_and_a_scalar_output_is_no_record()
  local made = McpModule.made("box", { {
    name = "weigh",
    inputSchema = { properties = { at = { type = Json.array({ "string", "null" }) } }, required = Json.array({ "at" }) },
    outputSchema = {
      type = "object",
      properties = { grams = { type = "integer" }, note = { type = Json.array({ "string", "null" }) } },
      required = Json.array({ "grams", "note" }),
    },
  }, { name = "name", inputSchema = { type = "object" }, outputSchema = { type = "string" } } })
  -- An input's required member is sent, null or not; an output's that may be null may be absent.
  has(made.teal, "  record WeighInput\n    at: string\n  end\n")
  has(made.teal, "  record WeighOutput\n    grams: integer\n    note?: string\n  end\n")
  has(made.teal, "  name: function(arguments?: {string: Json.Value}): Host.Result\n")
  assert(not assert(made.functions[2]).structured)
end

local function test_arguments_are_shaped_so_an_empty_list_is_an_array()
  local schema: Json.Value = {
    type = "object",
    properties = {
      tags = { type = "array", items = { type = "string" } },
      nested = { type = "object", properties = { ids = { type = "array" } } },
      more = { type = "object", additionalProperties = { type = "array" } },
    },
  }
  -- A snippet's `{}` typed as a list is a table no mark says is one.
  local function empty(): {Json.Value}
    local none: {Json.Value} = {}
    return none
  end
  local shaped = assert(Json.object_of(McpModule.shaped(schema, { tags = empty(), nested = { ids = empty() },
    more = { a = empty() }, name = "x" })))
  local function encoded(v?: Json.Value): string
    if v == nil then return "nil" end
    return assert(Json.encode(v))
  end
  assert(encoded(shaped["tags"]) == "[]" and encoded(shaped["nested"]) == '{"ids":[]}' and
      encoded(shaped["more"]) == '{"a":[]}' and shaped["name"] == "x", encoded(shaped))
end
