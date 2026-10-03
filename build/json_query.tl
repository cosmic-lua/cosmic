--- The queries `cosmic json` and `cosmic sql --at` make of a decoded JSON
--- document: a path or a pattern read from text ([`parse_path`],
--- [`parse_pattern`]), the value at a path ([`get`], [`entries`],
--- [`items`]), the values a pattern matches ([`select`]), every leaf as a
--- `path = value` line ([`flatten`], [`flat_line`]) and a document's shape
--- at a glance ([`describe`]). A path is spelled as [`child_path`] spells
--- it, its indices counted from 1.
-- TODO: this path is no JSONPath: `$.users[1]` is the first user here and
-- the second to Json.query, and the messages of cosmic.json name a JSON
-- Pointer. Read paths and patterns with Json.query, select with
-- Json.select, and print each match's place as Json.path writes it.

local Json = require("cosmic.json")

--- What a walk calls a table whose keys are neither an object's nor an
--- array's, in the message it fails with.
local MIXED <const> = "table with mixed keys"

local record json_query
  --- What `describe` may be told. Every field is optional.
  record DescribeOptions
    --- How many arrays and objects may nest in the summary before the
    --- rest is shown as `...` (default 6). 0 shows only the outermost
    --- value's kind.
    max_depth: integer
  end

  --- What kind of step a pattern step is: `key` and `index` are the
  --- steps of a plain path (`.name`, `["a key"]`, `[3]`); `any` is `*`,
  --- every member of an object or element of an array; the `deep_`
  --- kinds are `..`: the same key, index or `*` at any depth below,
  --- the current level included.
  enum StepKind
    "key"
    "index"
    "any"
    "deep_key"
    "deep_index"
    "deep_any"
  end

  --- One step of a pattern ([`json_query.parse_pattern`]): `key` is set for
  --- `key` and `deep_key`, `index` for `index` and `deep_index`.
  record Step
    --- Which step this is.
    kind: StepKind
    --- The object key to take, for a `key` or `deep_key` step.
    key: string
    --- The array position to take, for an `index` or `deep_index` step.
    index: integer
  end

  --- A value and the path it was found at, spelled as [`child_path`]
  --- spells it: what `flatten` and `select` answer.
  record Located
    --- Where the value was found.
    path: string
    --- The value itself.
    value: any
  end

  --- What `flatten` and `select` may be told. Every field is optional.
  record WalkOptions
    --- How many arrays and objects may nest below the value walked,
    --- 1 to [`Json.depth_limit`] (default [`Json.default_depth`], 64), as
    --- [`Json.EncodeOptions.max_depth`] counts. Deeper fails the walk.
    max_depth: integer
    --- The path to spell for the value itself (default `"$"`): give
    --- the path a value was found at, so its leaves spell in full.
    root: string
  end
end

--- The path of `step` under `path`, as `encode` writes where it failed:
--- `.name` for a key that is a word, `["a key"]` (quoted as [`Json.quote`]
--- does) for one that is not, and `[3]` for an array index, counted from
--- 1. `path` is `"$"` for the document itself, so
--- `json_query.child_path(json_query.child_path("$", "rows"), 2)` is `$.rows[2]`.
function json_query.child_path(path: string, step: string | integer): string
  if step is string then
    if step:match("^[%a_][%w_]*$") then
      return path .. "." .. step
    end
    return path .. "[" .. Json.quote(step) .. "]"
  end
  return path .. "[" .. step .. "]"
end

--- What `v` is, for a message: JSON's name for it, with a table of neither
--- shape named for what is wrong with it.
local function shape_kind(v: any): string
  if v == nil or rawequal(v, Json.null) then
    return "null"
  end
  if v is {any:any} then
    local layout = Json.layout(v)
    if layout == "mixed" then
      return MIXED
    elseif layout == "hole" then
      return "array with a hole"
    end
    return layout
  end
  return type(v)
end

--- Where `descend` got to: the value, the message ("" on success) and
--- the path reached.
local record Reached
  value: any
  err: string
  at: string
end

--- `get`'s walk, shared with `entries` and `items`. A failure names the
--- value at fault, and `at` is the path of the value reached. A string
--- step on an unmarked table with no array part is indexed directly, so
--- a lookup in a large decoded object is not a scan of it; the scan
--- that names what is wrong runs only for a failure.
local function descend(value: any, path: {string | integer}): Reached
  local steps = 0
  local loose: any = path
  if loose is {any:any} then
    for _ in pairs(loose) do steps = steps + 1 end
  end
  if steps ~= rawlen(path) then
    error("json: a path must be a sequence, with no nil hole in it", 3)
  end
  local at = "$"
  local here = value
  for _, step in ipairs(path) do
    local step_value: any = step
    if step_value is integer then
      if not (here is {any:any}) or Json.layout(here) ~= "array" then
        return { err = at .. ": expected an array to look up " .. json_query.child_path("", step_value) ..
            ", got " .. shape_kind(here), at = at }
      end
      local size = rawlen(here)
      if step_value > size and Json.is_array(here) then
        -- A decoded array with holes: `rawlen` is any border of it.
        size = Json.members(here).extent
      end
      if step_value < 1 or step_value > size then
        return { err = at .. ": index " .. step_value .. " out of range, the array has " .. size, at = at }
      end
      here = here[step_value]
    elseif step_value is string then
      local found: any
      if here is {any:any} and rawlen(here) == 0 and not Json.is_array(here) then
        found = here[step_value]
      elseif not (here is {any:any}) or Json.layout(here) ~= "object" then
        return { err = at .. ": expected an object to look up " .. Json.quote(step_value) ..
            ", got " .. shape_kind(here), at = at }
      else
        found = here[step_value]
      end
      if found == nil then
        if here is {any:any} and Json.layout(here) ~= "object" then
          return { err = at .. ": expected an object to look up " .. Json.quote(step_value) ..
              ", got " .. shape_kind(here), at = at }
        end
        return { err = at .. ": no key " .. Json.quote(step_value), at = at }
      end
      here = found
    else
      local what = math.type(step_value) or type(step_value)
      error("json: a path step must be a string or an integer, got " .. what, 3)
    end
    at = json_query.child_path(at, step)
  end
  return { value = here, err = "", at = at }
end

--- The value at `path` under `value`, and "". A string step is an
--- object's key and an integer step an array's index, counted from 1
--- as Lua counts and as `encode`'s messages do:
--- `{ "users", 3, "name" }` is `$.users[3].name`. An empty path is
--- `value` itself. nil and a message naming the path reached, in that
--- style, when a key is missing, a step meets a value that is not an
--- object or array as the step needs (by the rules `entries` and
--- `items` apply), or an index is out of range:
--- `$.users[5]: index out of range, the array has 3`. [`Json.null`] is a
--- value like any other at the end of the path, and reaching through
--- it is an error: `$.a: expected an object, got null`. A key whose
--- value decoded to nil (a `null` without `null_value`) is missing, as
--- an array's hole is nil with an empty message; decode with
--- `null_value = Json.null` to tell them from an absent key. A path with
--- a nil hole in it raises. Test the
--- message, not the value: a leaf of `false` or `nil` answers
--- `false, ""` or `nil, ""`. A step that is neither a string nor an
--- integer (a float such as `1.0` too) raises.
---
---     local doc = assert(Json.decode('{"rows": [{"id": "a"}]}'))
---     local id, err = json_query.get(doc, { "rows", 1, "id" })
---     assert(err == "" and id == "a")
function json_query.get(value: any, path: {string | integer}): any | nil, string
  local reached = descend(value, path)
  if reached.err ~= "" then
    return nil, reached.err
  end
  return reached.value, ""
end

--- The object `value` is, or the one at `path` under it as `get` finds
--- it, as a map to loop over with `pairs`, and "". nil and a message
--- when it is anything else, naming the path when one is given
--- (`$.a: expected a JSON object, got array`). An empty table that no
--- [`Json.array`] mark or decoded `[]` made an array is an object, as
--- `encode` writes it.
function json_query.entries(value: any, path?: {string | integer}): {string:any} | nil, string
  local at = ""
  local here = value
  if path ~= nil then
    local reached = descend(value, path)
    if reached.err ~= "" then
      return nil, reached.err
    end
    here = reached.value
    at = reached.at .. ": "
  end
  if here is {string:any} and Json.layout(here) == "object" then
    return here, ""
  end
  return nil, at .. "expected a JSON object, got " .. shape_kind(here)
end

--- The array `value` is, or the one at `path` under it as `get` finds
--- it, as a list to loop over with `ipairs`, and "". nil and a message
--- when it is anything else, naming the path when one is given. A
--- table counts as an array when it carries the mark ([`Json.is_array`])
--- or has integer keys from 1 up and no others; an unmarked empty
--- table is an object, so it fails here, as `encode` writes it `{}`.
---
---     for _, row in ipairs((assert(json_query.items(doc, { "rows" })))) do
---       print(row)
---     end
function json_query.items(value: any, path?: {string | integer}): {any} | nil, string
  local at = ""
  local here = value
  if path ~= nil then
    local reached = descend(value, path)
    if reached.err ~= "" then
      return nil, reached.err
    end
    here = reached.value
    at = reached.at .. ": "
  end
  if here is {any} and Json.layout(here) == "array" then
    return here, ""
  end
  return nil, at .. "expected a JSON array, got " .. shape_kind(here)
end

--- Four hex digits' value; the caller has matched them.
local function hex_value(digits: string): integer
  local value = tonumber(digits, 16)
  if value is integer then return value end
  error("json: not hex digits: " .. digits)
end

--- The steps of a path or a pattern, for [`parse_path`] and
--- `parse_pattern`: `wild` says whether `*` and `..` are read, or refused
--- as belonging to a pattern.
local function read_steps(text: string, wild: boolean): {json_query.Step} | nil, string
  local steps: {json_query.Step} = {}
  local size = #text
  local function refuse(at: integer, what: string): nil, string
    return nil, "path column " .. at .. ": " .. what
  end
  if size == 0 then
    return nil, "path is empty; `$` is the document"
  end
  local at = 1
  local rooted = text:sub(1, 1) == "$"
  if rooted then at = 2 end
  local first = true
  while at <= size do
    local begin = at
    local c = text:sub(at, at)
    local deep = false
    if c == "." and text:sub(at + 1, at + 1) == "." then
      if not wild then
        return refuse(begin, "`..` (recursive descent) is a pattern, not a path")
      end
      deep = true
      at = at + 2
      c = text:sub(at, at)
    end
    local key: string | nil
    local index: integer | nil
    local any = false
    local named = false
    local from = at
    if deep then
      named = c ~= "["
    elseif c == "." then
      named = true
      from = at + 1
    elseif first and not rooted and c ~= "[" then
      named = true
    end
    if named then
      local stop = text:find("[.%[]", from) or size + 1
      if stop == from then
        return refuse(from, "expected a key after `" .. (deep and ".." or ".") .. "`")
      end
      local name = text:sub(from, stop - 1)
      if name == "*" then
        if not wild then
          return refuse(begin, "`*` (a wildcard) is a pattern, not a path; " ..
              'a key named * is `["*"]`')
        end
        any = true
      else
        key = name
      end
      at = stop
    elseif c == "[" then
      if text:sub(at + 1, at + 1) == '"' then
        local parts: {string} = {}
        local here = at + 2
        while true do
          local stop = text:find('["\\]', here)
          if stop == nil then
            return refuse(at, "unclosed [")
          end
          parts[#parts + 1] = text:sub(here, stop - 1)
          if text:sub(stop, stop) == '"' then
            here = stop + 1
            break
          end
          local esc = text:sub(stop + 1, stop + 1)
          local plain: string | nil
          if esc == '"' or esc == "\\" or esc == "/" then
            plain = esc
          elseif esc == "b" then
            plain = "\b"
          elseif esc == "f" then
            plain = "\f"
          elseif esc == "n" then
            plain = "\n"
          elseif esc == "r" then
            plain = "\r"
          elseif esc == "t" then
            plain = "\t"
          end
          if plain ~= nil then
            parts[#parts + 1] = plain
            here = stop + 2
          elseif esc == "u" then
            local hex = text:match("^%x%x%x%x", stop + 2)
            if hex == nil then
              return refuse(stop, "expected four hex digits after \\u")
            end
            local code = hex_value(hex)
            here = stop + 6
            if code >= 0xD800 and code <= 0xDBFF then
              local low = text:match("^\\u([dD][c-fC-F]%x%x)", here)
              if low == nil then
                return refuse(stop, "a lone surrogate escape")
              end
              code = 0x10000 + ((code - 0xD800) << 10) + (hex_value(low) - 0xDC00)
              here = here + 6
            elseif code >= 0xDC00 and code <= 0xDFFF then
              return refuse(stop, "a lone surrogate escape")
            end
            parts[#parts + 1] = utf8.char(code)
          else
            return refuse(stop, "no such escape: \\" .. esc)
          end
        end
        if text:sub(here, here) ~= "]" then
          return refuse(here, "expected `]` after the key")
        end
        key = table.concat(parts)
        at = here + 1
      else
        local digits = text:match("^(%-?%d+)%]", at + 1)
        if text:sub(at + 1, at + 2) == "*]" then
          if not wild then
            return refuse(begin, "`[*]` (a wildcard) is a pattern, not a path; " ..
                'a key named * is `["*"]`')
          end
          any = true
          at = at + 3
        else
          if digits == nil then
            return refuse(at, "expected an integer or a quoted key inside [ ]")
          end
          local number = tonumber(digits)
          if not (number is integer) then
            return refuse(at, "index " .. digits .. " does not fit an integer")
          end
          index = number
          at = at + #digits + 2
        end
      end
    else
      return refuse(at, "expected `.` or `[`, got " .. Json.quote(c))
    end
    local step_kind: json_query.StepKind
    if any then
      step_kind = deep and "deep_any" or "any"
    elseif key ~= nil then
      step_kind = deep and "deep_key" or "key"
    else
      step_kind = deep and "deep_index" or "index"
    end
    steps[#steps + 1] = { kind = step_kind, key = key, index = index }
    first = false
  end
  return steps, ""
end

--- The steps of a path written as [`child_path`] spells one, for a
--- caller that takes a path as text (`cosmic json`): the steps for
--- [`json_query.get`], and "", or nil and a message naming the column where
--- the text stopped being a path. `$` is the document and may start
--- the text; then each step is `.name` (a key, up to the next `.` or
--- `[`), `[3]` (an array index, counted from 1 as `get` counts) or
--- `["a key"]` (a key in a JSON string, with JSON's escapes). Without
--- a leading `$`, the first step may drop its dot: `a.b` is `$.a.b`.
--- Whitespace is part of a key: `.a b` is the key `a b`.
--- `parse_path(json_query.child_path(...))` gives back the steps that built
--- it, for any keys and integers. A path that is empty, or ends in a
--- `.`, or has an unclosed `[`, or an index that does not fit an
--- integer, or a lone surrogate escape, is refused; it never raises.
--- `*` (as `.*` or `[*]`) and `..` are refused too, by name, since a
--- path names one value: [`parse_pattern`] reads them. A key named `*`
--- is `["*"]`.
---
---     local steps = assert(json_query.parse_path('$.rows[2]["a key"]'))
---     assert(steps[1] == "rows" and steps[2] == 2 and steps[3] == "a key")
function json_query.parse_path(text: string): {string | integer} | nil, string
  local read, err = read_steps(text, false)
  if read == nil then return nil, err end
  local steps: {string | integer} = {}
  for i, step in ipairs(read) do
    local plain: string | integer | nil = step.key
    if plain == nil then plain = step.index end
    if plain == nil then error("json: a plain step has neither a key nor an index") end
    steps[i] = plain
  end
  return steps, ""
end

--- A path that may name many values, as text: every form
--- [`parse_path`] reads, and `*` (as `.*` or `[*]`), every member of an
--- object or element of an array, and `..` (recursive descent):
--- `..name`, `..["a key"]`, `..[3]` and `..*` are that key, index or
--- every value at any depth below, the level the pattern has reached
--- included. `$..id` is every `id` in a document, wherever it is, and
--- `$.users[*].name` every user's name. A key named `*` is `["*"]`, and
--- a `*` inside a longer name is a key (`.a*`). The steps carry a kind
--- ([`json_query.Step`]), and [`json_query.select`] matches them. A text that is
--- no pattern is refused as [`parse_path`] refuses it, and it never
--- raises. [`json_query.spell_pattern`] writes steps as text that reads back as
--- themselves.
---
--- Only what is spelled above: JSONPath's filters (`[?(@.price < 10)]`),
--- slices (`[1:3]`) and unions (`[1,2]`) are left out on purpose, as
--- `cosmic json` is a lookup and no query language; `cosmic json --flat`
--- with `grep`, or a script over [`json_query.select`], does what they would.
---
---     local pattern = (assert(json_query.parse_pattern("$..price")))
---     assert(pattern[1].kind == "deep_key" and pattern[1].key == "price")
function json_query.parse_pattern(text: string): {json_query.Step} | nil, string
  return read_steps(text, true)
end

--- `pattern` as text [`parse_pattern`] reads back as the same steps, for
--- any keys and integers: `$.users[*]..["a key"]`, and `$` for no steps.
--- It is [`child_path`] for a plain step, `.*` for `any`, and for a `deep_`
--- step `..name` (or `..["a key"]` for a key that is not a word), `..[3]`
--- and `..*`. Raises for a step whose kind is not one of [`json_query.StepKind`],
--- or that lacks the key or index its kind needs.
function json_query.spell_pattern(pattern: {json_query.Step}): string
  local text = "$"
  for _, step in ipairs(pattern) do
    local step_kind = step.kind
    local key = step.key
    local index = step.index
    if step_kind == "key" and key ~= nil then
      text = json_query.child_path(text, key)
    elseif step_kind == "index" and index ~= nil then
      text = json_query.child_path(text, index)
    elseif step_kind == "any" then
      text = text .. ".*"
    elseif step_kind == "deep_any" then
      text = text .. "..*"
    elseif step_kind == "deep_key" and key ~= nil then
      local named = json_query.child_path("", key)
      text = text .. (named:sub(1, 1) == "." and "." or "..") .. named
    elseif step_kind == "deep_index" and index ~= nil then
      text = text .. ".." .. json_query.child_path("", index)
    else
      error("json: a pattern step of kind " .. tostring(step_kind) .. " lacks what it needs", 2)
    end
  end
  return text
end

--- `given`, a `max_depth`, when it is an integer from `least` to `most`
--- (no upper bound when `most` is nil); otherwise raises, naming the
--- caller `level` frames above the function that calls this one.
local function checked_depth(given: any, least: integer, most: integer | nil, level: integer): integer
  if not (given is integer) or given < least or (most ~= nil and given > most) then
    local range = most ~= nil and "from " .. least .. " to " .. most or "of at least " .. least
    error("json: max_depth must be an integer " .. range, level + 1)
  end
  return given
end

--- `opts` of `flatten` and `select`, checked: the depth limit and the
--- path spelled for the value itself.
local function walk_options(opts: json_query.WalkOptions | nil): integer, string
  local limit = Json.default_depth
  local root = "$"
  if opts ~= nil then
    if opts.max_depth ~= nil then
      limit = checked_depth(opts.max_depth, 1, Json.depth_limit, 3)
    end
    if opts.root ~= nil then root = opts.root end
  end
  return limit, root
end

--- Every leaf of `value` as a path and its value, in a list, and "":
--- a scalar, [`Json.null`], or an empty object or array, which is itself
--- a leaf (that value, whose [`flat_line`] is `{}` or `[]`). The paths
--- are [`child_path`]'s, from `$` (`opts.root`), so each one is what
--- [`parse_path`] reads and `get` follows back to its leaf. The order is
--- fixed: an object's keys sorted, an array's elements by index, and a
--- container's leaves before the next one's, so the same value always
--- flattens to the same list. A hole in an array (a decoded `null`
--- without `null_value`) is not a leaf, and its neighbours keep their
--- indexes. A scalar `value` is one leaf, at `$`. nil and a message
--- naming the path when nesting passes `max_depth` (default
--- [`Json.default_depth`]), a table contains itself, or a table's keys mix
--- strings and integers or are neither, as `encode` would refuse it.
--- Raises when `max_depth` is not an integer from 1 to [`Json.depth_limit`].
---
---     local doc = assert(Json.decode('{"a": [1, {"b": []}]}'))
---     for _, leaf in ipairs((assert(json_query.flatten(doc)))) do
---       print(assert(json_query.flat_line(leaf.path, leaf.value)))
---     end
---     -- $.a[1] = 1
---     -- $.a[2].b = []
function json_query.flatten(value: any, opts?: json_query.WalkOptions): {json_query.Located} | nil, string
  local limit, root = walk_options(opts)
  local leaves: {json_query.Located} = {}
  local open: {any:boolean} = {}
  local failed: string | nil
  local function walk(v: any, path: string, depth: integer)
    if not (v is {any:any}) then
      leaves[#leaves + 1] = { path = path, value = v }
      return
    end
    local members = Json.members(v)
    local shape, keys, extent = members.layout, members.keys, members.extent
    if shape == "mixed" then
      failed = path .. ": expected an object or an array, got " .. MIXED
      return
    end
    if depth >= limit then
      failed = path .. ": nested deeper than max_depth " .. limit
      return
    end
    if open[v] then
      failed = path .. ": the table contains itself"
      return
    end
    open[v] = true
    local before = #leaves
    if shape == "array" then
      for i = 1, extent do
        local child = v[i]
        if child ~= nil and failed == nil then walk(child, path .. "[" .. i .. "]", depth + 1) end
      end
    else
      for _, step in ipairs(keys) do
        if failed == nil then walk(v[step], json_query.child_path(path, step), depth + 1) end
      end
    end
    open[v] = nil
    if failed == nil and #leaves == before then
      leaves[#leaves + 1] = { path = path, value = v }
    end
  end
  walk(value, root, 0)
  if failed ~= nil then return nil, failed end
  return leaves, ""
end

--- One line of `flatten`'s output: `path`, ` = `, and `value` as
--- compact [`Json.encode`] writes it, so `$.a[1].b = 1200.5`. The path is
--- what [`json_query.parse_path`] reads and `cosmic json` takes, so a line found
--- with `grep` gives its path back to `cosmic json '<path>'`, and a
--- path ends where the first ` = ` outside a quoted key does. nil and
--- the message of `encode` when `value` cannot be encoded.
function json_query.flat_line(path: string, value: any): string | nil, string
  local text, err = Json.encode(value)
  if text == nil then return nil, path .. ": " .. err end
  return path .. " = " .. text, ""
end

--- Whether `sk` is one of the `deep_` kinds.
local function is_deep(sk: json_query.StepKind): boolean
  return sk == "deep_key" or sk == "deep_index" or sk == "deep_any"
end

--- Every value `pattern` (from [`parse_pattern`]) matches under `value`, as
--- a path and the value, in a list, and "": `[]` when nothing matches,
--- with no failure. Paths are concrete (`$.users[2].name`, never `*`),
--- as `flatten`'s are, and each value is listed once however many ways
--- the pattern reaches it. The order is document order: a value before
--- what is inside it, an object's keys sorted, an array's elements by
--- index, and a hole in an array matches nothing. The empty pattern
--- (`$`, no steps) selects `value` itself, once, and no other pattern
--- does. A step that meets a scalar, or a container of the other kind,
--- matches nothing there. The walk visits each value once, and each step
--- at most once per value, so `..` over a large document costs the size
--- of the document, however the pattern is spelled. nil and a message
--- naming the path when nesting passes `max_depth` where the pattern
--- goes, a table contains itself, or a table's keys mix strings and
--- integers, as `flatten` fails. Raises when `max_depth` is not an
--- integer from 1 to [`Json.depth_limit`], or a step is not one
--- [`parse_pattern`] makes.
---
---     local doc = assert(Json.decode('{"a": {"id": 1}, "b": [{"id": 2}]}'))
---     local found = assert(json_query.select(doc, (assert(json_query.parse_pattern("$..id")))))
---     assert(found[1].path == "$.a.id" and found[2].path == "$.b[1].id")
function json_query.select(value: any, pattern: {json_query.Step}, opts?: json_query.WalkOptions): {json_query.Located} | nil, string
  local limit, root = walk_options(opts)
  local count = #pattern
  if count > 62 then
    return nil, "a pattern has at most 62 steps, not " .. count
  end
  -- The steps still to match below a value are a set of positions in
  -- the pattern, kept as the bits of an integer (position p is bit p - 1,
  -- and bit `count` is "matched entirely"), so that advancing to a child
  -- allocates nothing.
  local keys: {string} = {}
  local indexes: {integer} = {}
  local deep: {boolean} = {}
  local kinds: {integer} = {}
  for position, step in ipairs(pattern) do
    local sk = step.kind
    local name, index = step.key, step.index
    deep[position] = is_deep(sk)
    keys[position] = ""
    indexes[position] = 0
    if (sk == "key" or sk == "deep_key") and name ~= nil then
      kinds[position] = 1
      keys[position] = name
    elseif (sk == "index" or sk == "deep_index") and index ~= nil then
      kinds[position] = 2
      indexes[position] = index
    elseif sk == "any" or sk == "deep_any" then
      kinds[position] = 3
    else
      error("json: a pattern step of kind " .. tostring(sk) .. " lacks what it needs", 2)
    end
  end
  local accepted = 1 << count
  local found: {json_query.Located} = {}
  local open: {any:boolean} = {}
  local failed: string | nil
  local stack: {string | integer} = {}
  -- `spelled_at[d]` is the path of the value `d` steps down, good for
  -- the first `cached` levels of `stack`: a path is spelled from the last
  -- one that was, a step at a time, and not again from the root.
  local spelled_at: {integer:string} = { [0] = root }
  local cached = 0
  local function spelled(): string
    for d = cached + 1, #stack do
      spelled_at[d] = json_query.child_path(spelled_at[d - 1], stack[d])
    end
    cached = #stack
    return spelled_at[cached]
  end
  local visit: function(v: any, mask: integer, depth: integer)
  --- Visits `child`, at `step` below a value that has matched up to
  --- `mask`, with the positions still to match below it: the steps
  --- `step` satisfies, each one's successor, and a `deep_` step itself,
  --- since it stays for everything below. A scalar is visited only to
  --- be listed, when the pattern is matched entirely at it.
  local function enter(mask: integer, step: string | integer, child: any, depth: integer)
    local following = 0
    for position = 1, count do
      local bit = 1 << (position - 1)
      if mask & bit ~= 0 then
        local kd = kinds[position]
        if kd == 3 or (kd == 1 and step == keys[position]) or (kd == 2 and step == indexes[position]) then
          following = following | (bit << 1)
        end
        if deep[position] then following = following | bit end
      end
    end
    if following & accepted ~= 0 or (following ~= 0 and type(child) == "table") then
      stack[#stack + 1] = step
      visit(child, following, depth + 1)
      stack[#stack] = nil
      if cached > #stack then cached = #stack end
    end
  end
  visit = function(v: any, mask: integer, depth: integer)
    if mask & accepted ~= 0 then found[#found + 1] = { path = spelled(), value = v } end
    local active = mask & (accepted - 1)
    if active == 0 or not (v is {any:any}) then return end
    if depth >= limit then
      failed = spelled() .. ": nested deeper than max_depth " .. limit
      return
    end
    if open[v] then
      failed = spelled() .. ": the table contains itself"
      return
    end
    open[v] = true
    local only = 0
    if active & (active - 1) == 0 then
      for position = 1, count do
        if active == 1 << (position - 1) then only = position end
      end
    end
    if only ~= 0 and not deep[only] and kinds[only] ~= 3 and Json.layout(v) == "mixed" then
      failed = spelled() .. ": expected an object or an array, got " .. MIXED
    elseif only ~= 0 and not deep[only] and kinds[only] == 1 then
      -- One plain step: look it up, as `get` does.
      local key = keys[only]
      local child = v[key]
      if child ~= nil then enter(mask, key, child, depth) end
    elseif only ~= 0 and not deep[only] and kinds[only] == 2 then
      local index = indexes[only]
      local child = v[index]
      if child ~= nil then enter(mask, index, child, depth) end
    else
      local members = Json.members(v)
      local shape, ordered, extent = members.layout, members.keys, members.extent
      if shape == "mixed" then
        failed = spelled() .. ": expected an object or an array, got " .. MIXED
      elseif shape == "array" then
        for i = 1, extent do
          local child = v[i]
          if child ~= nil and failed == nil then enter(mask, i, child, depth) end
        end
      else
        for _, step in ipairs(ordered) do
          if failed == nil then enter(mask, step, v[step], depth) end
        end
      end
    end
    open[v] = nil
  end
  visit(value, 1, 0)
  if failed ~= nil then return nil, failed end
  return found, ""
end

--- What the values seen at one place look like, merged.
local record Node
  scalars: {string:boolean}
  objects: integer
  fields: {string:Node}
  seen: {string:integer}
  arrays: integer
  shortest: integer
  longest: integer
  elements: Node
  cut: boolean
end

local function new_node(): Node
  return { scalars = {}, objects = 0, fields = {}, seen = {}, arrays = 0, shortest = 0, longest = 0, cut = false }
end

--- Folds `v` into `node`, `depth` containers below the top and no
--- deeper than `limit`: each value is visited once, so a long array costs
--- its length, not a summary apiece.
local function absorb(node: Node, v: any, depth: integer, limit: integer)
  if v == nil or rawequal(v, Json.null) then
    node.scalars["null"] = true
    return
  end
  if type(v) == "number" then
    node.scalars["number"] = true
    return
  end
  if not (v is {any:any}) then
    node.scalars[type(v)] = true
    return
  end
  local k = Json.layout(v)
  if k == "mixed" then
    node.scalars["table"] = true
  elseif k == "array" then
    local n = rawlen(v)
    if node.arrays == 0 or n < node.shortest then node.shortest = n end
    if node.arrays == 0 or n > node.longest then node.longest = n end
    node.arrays = node.arrays + 1
    if depth >= limit then
      node.cut = true
      return
    end
    if n > 0 and node.elements == nil then node.elements = new_node() end
    for i = 1, n do
      absorb(node.elements, v[i], depth + 1, limit)
    end
  else
    node.objects = node.objects + 1
    if depth >= limit then
      node.cut = true
      return
    end
    for key, member in pairs(v) do
      local name: any = key
      if not (name is string) then goto continue end
      local field = node.fields[name]
      if field == nil then
        field = new_node()
        node.fields[name] = field
      end
      node.seen[name] = (node.seen[name] or 0) + 1
      absorb(field, member, depth + 1, limit)
      ::continue::
    end
  end
end

local function sorted_keys<T>(t: {string:T}): {string}
  local keys: {string} = {}
  for key in pairs(t) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local function render(node: Node): string
  local parts: {string} = sorted_keys(node.scalars)
  if node.objects > 0 then
    if node.cut then
      parts[#parts + 1] = "{...}"
    else
      local members: {string} = {}
      for _, name in ipairs(sorted_keys(node.fields)) do
        local optional = node.seen[name] < node.objects and "?" or ""
        members[#members + 1] = (name:match("^[%a_][%w_]*$") and name or Json.quote(name)) .. optional .. ": " .. render(node.fields[name])
      end
      parts[#parts + 1] = "{" .. table.concat(members, ", ") .. "}"
    end
  end
  if node.arrays > 0 then
    local size = tostring(node.shortest)
    if node.longest ~= node.shortest then size = size .. ".." .. node.longest end
    if node.cut then
      parts[#parts + 1] = "[" .. size .. " x ...]"
    elseif node.elements == nil then
      parts[#parts + 1] = "[" .. size .. "]"
    else
      parts[#parts + 1] = "[" .. size .. " x " .. render(node.elements) .. "]"
    end
  end
  return table.concat(parts, "|")
end

--- A compact summary of `value`'s shape, for exploring a document whose
--- shape is not known: `{plans: [3 x {...}], today: {id: string}}`.
--- Object keys are sorted, and a key some of the objects merged at one
--- place lack is `key?`. An array is `[length x element]`, with every
--- element folded into one shape (`number|string` for a mix, the
--- length as `min..max` when merged arrays differ, `[0]` when empty),
--- so a long array costs no more to read than a short one. Scalars are
--- `string`, `number` (integer or float), `boolean` and `null`
--- ([`Json.null`], or a hole). Past `max_depth` nesting a container is
--- `{...}` or `[n x ...]`, and `max_depth` is bounded by the stack, as
--- the walk recurses once per level. Beyond `string`, `number`, `boolean`
--- and `null`, a Lua value that is no JSON prints as its type,
--- `function` or `userdata`, and a table of mixed keys as `table`. The
--- same value always gives the same text.
--- An array with holes (a decoded `null` without `null_value`) has no
--- reliable length: decode with `null_value = Json.null` to describe one.
--- Raises when `max_depth` is not an integer of at least 0.
---
---     print(json_query.describe(assert(Json.decode('{"ids": [1, 2], "ok": true}'))))
---     -- {ids: [2 x number], ok: boolean}
function json_query.describe(value: any, opts?: json_query.DescribeOptions): string
  local limit = 6
  if opts ~= nil and opts.max_depth ~= nil then
    limit = checked_depth(opts.max_depth, 0, nil, 2)
  end
  local node = new_node()
  absorb(node, value, 0, limit)
  return render(node)
end

return json_query
