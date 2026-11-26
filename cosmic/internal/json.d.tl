-- JSON at the Lua boundary, as the core (core/json.c, over yyjson)
-- provides it. cosmic/json.tl documents the contract. A fallible
-- function returns `value, ""` on success and `nil, error` on failure.
--- @kind binding

local record json
  -- The type of `null`: JSON `null`'s stand-in, a userdata with nothing to
  -- read or call.
  record Null
    userdata
  end

  -- What JSON can say as a Lua value, as [`decode_lines`] builds it:
  -- cosmic/json.tl's [`Json.Value`], which is this type.
  type Value = string | number | boolean | Null | {Value} | {string: Value}

  -- What `decode` builds of a value, for `only`: all of it when
  -- `whole`, else, in an object, the members `names` holds and, in an
  -- array, the elements at `positions` (from 1), each selected in turn.
  record Selection
    mut whole: boolean
    names: mut {string: Selection}
    positions: mut {integer: Selection}
  end

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
  -- fewer than. With `only`, the text is checked whole as `check`
  -- checks it, then only the values it selects are built (see
  -- [`Selection`]); what a step does not reach is left out, and an array
  -- keeps its elements' positions, marked as one with holes. A text that
  -- is no array or object is the value whole.
  decode: function(text: string, null?: any, max_depth?: integer,
                   json5?: boolean, big_as_string?: boolean,
                   lone_surrogates?: boolean, record?: integer,
                   hash_comments?: boolean,
                   duplicate_keys?: boolean, line?: integer, column?: integer,
                   prefix?: string, opened?: integer, only?: Selection): any?, string
  -- The values of the JSON Lines text `text` from byte `at` (1 when
  -- absent), which begins line `line` (1 when absent): one to each line
  -- that holds more than the bytes `%s` matches, `most` of them at most
  -- (all when absent), in an array marked as `array` marks one; then
  -- "", and the byte and line to read on from, or nil and nil where the
  -- text is done. Each line is read as `decode` reads it with `record`
  -- set to its line's number, under the options of the same names; a
  -- `null` line with no `null` leaves a hole. nil and the first refused
  -- line's message when one does not decode. Raises when `at` is past
  -- the byte after the text, `line` is below 1 or `most` below 1.
  decode_lines: function(text: string, null?: any, max_depth?: integer,
                         json5?: boolean, big_as_string?: boolean,
                         lone_surrogates?: boolean, hash_comments?: boolean,
                         duplicate_keys?: boolean, only?: Selection, at?: integer,
                         line?: integer, most?: integer): any?, string, integer?, integer?
  -- true and "" when `decode` would read `text` under the same
  -- options; else false and the message it would fail with. It builds
  -- no value.
  check: function(text: string, max_depth?: integer, json5?: boolean,
                  lone_surrogates?: boolean, hash_comments?: boolean,
                  duplicate_keys?: boolean, big_as_string?: boolean): boolean, string
  -- The value `text` holds, read as `check` reads it, written again as
  -- RFC 8259 text: its members in the text's order and its numbers as
  -- written (a JSON5 form as RFC 8259 writes the number), laid out as
  -- `encode` lays it out by `layout` and `width`; or, with `canonical`,
  -- in RFC 8785's form. nil and a message when the text does not read,
  -- or holds NaN or an infinity.
  format: function(text: string, max_depth?: integer, json5?: boolean,
                   lone_surrogates?: boolean, hash_comments?: boolean,
                   duplicate_keys?: boolean, layout?: string,
                   canonical?: boolean, width?: integer): string?, string
  -- `value` as JSON text. nil and a message when it holds something
  -- JSON cannot say, naming where: `... at pointer "/users/2/name"`. Keys are
  -- sorted by their bytes. `layout` is "compact" (the default), "expanded"
  -- (two spaces a level) or "fractured" (FracturedJson's layout, in lines
  -- of `width` characters, 120 when absent). Raises when `max_depth` is
  -- outside 1 to `depth_limit`, `layout` is another word, or `width` is
  -- less than 1.
  encode: function(value: any, layout?: string, max_depth?: integer, ascii?: boolean,
                   width?: integer): string?, string
  -- Marks `t`, or a new table, as a JSON array and gives it back. Raises
  -- when `t` has another metatable.
  array: function(): {any}
  array: function<T>(t: {T}): {T}
  -- The same for a table kept by position, which may hold a hole (JSON
  -- Lines with a `null` line).
  array: function(t: {integer: any}): {any}
  array: function<T>(t: {integer: T}): {T}
  -- Marks `t`, a table with no metatable, as an array that may have
  -- holes when `holey` is true, else as an array, and gives it back.
  with_holes: function<T>(t: {integer: T}, holey: boolean): {integer: T}
  -- Whether `v` is a table carrying either array mark.
  is_array: function(v: any): boolean
  -- The stand-in for JSON `null`: a userdata that encodes as `null`.
  null: Null
  -- How many arrays and objects may nest when the caller names no
  -- limit, and the most a caller may name.
  default_depth: integer
  depth_limit: integer
end

return json
