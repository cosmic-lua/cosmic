-- JSON at the Lua boundary, as the core (core/json.c, over yyjson)
-- provides it. cosmic/json.tl documents the contract. A fallible
-- function answers `value, ""` on success and `nil, error` on failure.

local record json
  -- The value `text` holds. JSON `null` is `null` when given, and nil
  -- when not. nil and a message, naming the line and column, when the
  -- text is not one RFC 8259 JSON value or nests past `max_depth`
  -- (64 by default). Raises when `max_depth` is outside 1 to 1000.
  decode: function(text: string, null?: any, max_depth?: integer): any | nil, string
  -- `value` as JSON text. nil and a message when it holds something
  -- JSON cannot say. Raises when `indent` is not spaces and tabs, or
  -- `max_depth` is outside 1 to 1000.
  encode: function(value: any, pretty?: boolean, indent?: string, sorted?: boolean,
                   max_depth?: integer, nan_as_null?: boolean,
                   sparse_as_null?: boolean): string | nil, string
  -- Marks `t`, or a new table, as a JSON array and answers it. Raises
  -- when `t` has another metatable.
  array: function(t?: {any}): {any}
  -- Whether `v` is a table carrying the array mark.
  is_array: function(v: any): boolean
  -- The stand-in for JSON `null`: a userdata that encodes as `null`.
  null: any
end

return json
