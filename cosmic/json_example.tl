--- Worked examples for `cosmic.json`, shown by `cosmic docs` and run by
--- `cosmic test`.

local Json = require("cosmic.json")
local Stream = require("cosmic.stream")

local Example = {}

--- Read an object from outside: [`decode_object`] checks the outermost
--- shape, and `is` narrows each field before it is trusted.
function Example.decode_object()
  local config, err = Json.decode_object('{"name": "cosmic", "retries": 3}')
  assert(config ~= nil, err)
  local name = config.name
  local retries = config.retries
  assert(name is string and name == "cosmic")
  assert(retries is integer and retries == 3)
end

--- Test the message, not the value: `null` is a document too, and it
--- decodes to nil with an empty message.
function Example.decode_failure()
  local value, err = Json.decode("null")
  assert(value == nil and err == "")
  local bad, why = Json.decode('{"a": 1,}')
  assert(bad == nil)
  print(why)
end

--- The same value always encodes to the same text: keys in byte order.
function Example.encode()
  local text = assert(Json.encode({ name = "cosmic", tags = { "lua", "teal" } }))
  print(text)
  assert(text == '{"name":"cosmic","tags":["lua","teal"]}')
end

--- Laid out for a person to read.
function Example.encode_pretty()
  local text = assert(Json.encode({ b = { 1, 2 }, a = true }, { pretty = true }))
  print(text)
end

--- Keep a document's nulls and empty arrays through a round trip.
function Example.null_value()
  local text = '{"note": null, "tags": []}'
  local value = Json.decode(text, { null_value = Json.null })
  assert(Json.encode(value) == text:gsub(" ", ""))
  local plain = Json.decode_object(text)
  assert(plain ~= nil and plain.note == nil)
  assert(Json.encode(plain) == '{"tags":[]}')
end

--- An empty table encodes as an object unless it is marked an array.
function Example.array()
  assert(Json.encode({}) == "{}")
  assert(Json.encode(Json.array()) == "[]")
end

--- Explore a document whose shape is not known: [`decode_object`] checks
--- the outermost value, and `is` narrows what a key holds before a
--- loop reads it, so `pairs` and `ipairs` need no cast.
function Example.explore()
  local doc = assert(Json.decode_object('{"rows": [{"id": "a", "n": 1}, {"id": "b"}], "ok": true}'))
  local rows = doc.rows
  assert(rows is {any} and Json.is_array(rows))
  assert(rows[3] == nil)
  for _, row in ipairs(rows) do
    assert(row is {string:any})
    for key in pairs(row) do print(key) end
  end
end

--- JSON Lines (NDJSON): one value to a line, as logs and CLI tools
--- write it.
function Example.decode_lines()
  local events, err = Json.decode_lines('{"level": "info"}\n{"level": "warn"}\n')
  assert(events ~= nil, err)
  assert(#events == 2)
  for _, event in ipairs(events) do print(assert(Json.encode(event))) end
end

--- JSON Lines read from a stream a value at a time, in bounded memory
--- however long it runs -- here a string, as well as a file
--- (`Stream.open(path)`), a child's output or an HTTP response --
--- and written back a line at a time to any Writer.
function Example.lines()
  local reader = Stream.from_string('{"level":"info"}\n\n{"level":"warn"}\n')
  local lines = Stream.lines(reader)
  local out = Stream.collect()
  for line in lines:each() do
    if line:find("%S") then
      local record = assert(Json.decode_object(line))
      if record.level == "warn" then assert(out:write(assert(Json.encode(record)) .. "\n")) end
    end
  end
  assert(lines:failure() == "", lines:failure())
  print(out:result())
  assert(out:result() == '{"level":"warn"}\n')
end

--- A value that cannot be encoded is named by where it is.
function Example.encode_failure()
  local _, why = Json.encode({ users = { { name = "ada" }, { name = print } } })
  print(why)
  assert(why == "json: cannot encode a function at $.users[2].name")
end

--- Read a list from outside: [`decode_array`] checks the outermost shape.
function Example.decode_array()
  local tags, err = Json.decode_array('["lua", "teal"]')
  assert(tags ~= nil, err)
  print(#tags, tags[1])
  assert(#tags == 2 and tags[1] == "lua")
  local _, why = Json.decode_array('{"tags": []}')
  print(why)
  assert(why == "json: expected a JSON array, got object", why)
end

--- Nesting is bounded: [`max_depth`] is [`Json.default_depth`] unless
--- given, and may be raised as far as [`Json.depth_limit`].
function Example.max_depth()
  local deep = string.rep("[", 100) .. string.rep("]", 100)
  local refused, why = Json.decode(deep)
  print(Json.default_depth, why)
  assert(refused == nil and why ~= "")
  local value, err = Json.decode(deep, { max_depth = Json.depth_limit })
  assert(value ~= nil, err)
  print(Json.depth_limit)
end

--- Read YAML without a YAML parser: a GitHub workflow written in YAML's
--- flow style, kept to the subset JSON5 with `#` comments shares with
--- it -- double-quoted strings, a space after each `:` and before each
--- `#`, keys such as `on` that YAML reads as booleans quoted -- reads
--- with `json5` and `hash_comments`, and GitHub reads the same text as
--- YAML. build/workflows_test.tl holds the tree's own workflows to that
--- subset.
function Example.yaml_flow_style()
  local workflow = [[
# Runs on every push.
{
  name: "ci",
  "on": {push: {}},
  jobs: {
    test: {
      "runs-on": "ubuntu-24.04", # a hosted runner
      steps: [
        {run: "make test"},
      ],
    },
  },
}
]]
  local ci, err = Json.decode_object(workflow, { json5 = true, hash_comments = true })
  assert(ci ~= nil, err)
  local jobs = ci.jobs as {string: {string: any}}
  print(ci.name, jobs.test["runs-on"])
  assert(ci.name == "ci" and jobs.test["runs-on"] == "ubuntu-24.04")
end

--- How a table encodes: a marked or consecutive-keyed table is an array,
--- string keys make an object, and a table that is neither is named for
--- what is wrong with it.
function Example.layout()
  assert(Json.layout(Json.array()) == "array")
  assert(Json.layout({ 1, 2, 3 }) == "array")
  assert(Json.layout({ name = "cosmic" }) == "object")
  assert(Json.layout({ [1] = "a", [3] = "c" }) == "hole")
  assert(Json.layout({ 1, name = "cosmic" }) == "mixed")
end

return Example
