-- JSON at the Lua boundary, as the core (core/json.c, over yyjson)
-- provides it. cosmic/json.tl documents the contract. A fallible
-- function answers `value, ""` on success and `nil, error` on failure.

local record json
  -- The value `text` holds. JSON `null` is `null` when given, and nil
  -- when not. nil and a message, naming the line and column, when the
  -- text is not one RFC 8259 JSON value (JSON5 when `json5`; either
  -- with `#` line comments when `hash_comments`) or nests
  -- past `max_depth` (`default_depth` when absent). With
  -- `big_as_string`, an integer past 64 bits, or a number past a
  -- double's range, decodes as its text. With `lone_surrogates`, a lone
  -- surrogate escape decodes as U+FFFD. An object with a key twice is
  -- refused, naming where, unless `duplicate_keys`: then the last of its
  -- members stands. Raises when `max_depth` is
  -- outside 1 to `depth_limit`. With `record`, the text is that line
  -- of a JSON Lines text: a failure names that line, its column
  -- counted from the text's start, whatever line ends the text holds;
  -- one out of memory or holding no value names that line alone.
  -- Raises when `record` is negative. With `line` and `column` (each
  -- from 1), the text starts there in a larger text, and a failure counts
  -- from there; with `prefix`, the JSON Pointer of the value the text is,
  -- the pointer a failure names is put under it; with `opened`, that many
  -- arrays and objects are open
  -- around it there, and count toward `max_depth`, which they must be
  -- fewer than.
  decode: function(text: string, null?: any, max_depth?: integer,
                   json5?: boolean, big_as_string?: boolean,
                   lone_surrogates?: boolean, record?: integer,
                   hash_comments?: boolean,
                   duplicate_keys?: boolean, line?: integer, column?: integer,
                   prefix?: string, opened?: integer): any | nil, string
  -- true and "" when `decode` would read `text` under the same
  -- options; else false and the message it would fail with. It builds
  -- no value.
  check: function(text: string, max_depth?: integer, json5?: boolean,
                  lone_surrogates?: boolean, hash_comments?: boolean,
                  duplicate_keys?: boolean, big_as_string?: boolean): boolean, string
  -- The value `text` holds, read as `check` reads it, written again as
  -- RFC 8259 text: its members in the text's order and its numbers as
  -- written (a JSON5 form as RFC 8259 writes the number), laid out
  -- two spaces a level with `pretty`; or, with `canonical`, in RFC
  -- 8785's form. nil and a message when the text does not read, or
  -- holds NaN or an infinity.
  format: function(text: string, max_depth?: integer, json5?: boolean,
                   lone_surrogates?: boolean, hash_comments?: boolean,
                   duplicate_keys?: boolean, pretty?: boolean,
                   canonical?: boolean): string | nil, string
  -- `value` as JSON text. nil and a message when it holds something
  -- JSON cannot say, naming where: `... at pointer "/users/2/name"`. Keys are
  -- sorted by their bytes; `pretty` lays it out two spaces a level. Raises
  -- when `max_depth` is outside 1 to `depth_limit`.
  encode: function(value: any, pretty?: boolean, max_depth?: integer, ascii?: boolean): string | nil, string
  -- Marks `t`, or a new table, as a JSON array and answers it. Raises
  -- when `t` has another metatable.
  array: function(t?: {any}): {any}
  -- Whether `v` is a table carrying the array mark.
  is_array: function(v: any): boolean
  -- The stand-in for JSON `null`: a userdata that encodes as `null`.
  null: any
  -- How many arrays and objects may nest when the caller names no
  -- limit, and the most a caller may name.
  default_depth: integer
  depth_limit: integer
end

return json
