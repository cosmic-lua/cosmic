--- Worked examples for `cosmic.json`, shown by `cosmic docs` and run by
--- `cosmic test`.

local Json = require("cosmic.json")

local Example = {}

--- Read an object from outside: `decode_object` checks the outermost
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

--- JSON Lines (NDJSON): one value to a line, as logs and CLI tools
--- write it.
function Example.decode_lines()
  local events, err = Json.decode_lines('{"level": "info"}\n{"level": "warn"}\n')
  assert(events ~= nil, err)
  assert(#events == 2)
  print(Json.encode_lines(events))
end

--- A value that cannot be encoded is named by where it is.
function Example.encode_failure()
  local _, why = Json.encode({ users = { { name = "ada" }, { name = print } } })
  print(why)
  assert(why == "cannot encode a function at $.users[2].name")
end

return Example
