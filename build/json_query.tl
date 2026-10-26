--- What `cosmic json` prints of a decoded JSON document beyond the
--- value at a path: every leaf as a `path = value` line ([`flatten`],
--- [`flat_line`]), and a document's shape at a glance ([`describe`]). A
--- line's place is a JSONPath query in shorthand form (`$.users[1].name`,
--- `$["a key"][0]`), which `cosmic json` reads back, and a failure names a
--- place by its JSON Pointer, as `cosmic.json`'s messages do.

local Json = require("cosmic.json")

local record json_query
  --- What `describe` may be told. Every field is optional.
  record DescribeOptions
    --- How many arrays and objects may nest in the summary before the
    --- rest is shown as `...` (default 6). 0 shows only the outermost
    --- value's kind.
    max_depth: integer
  end

  --- What `flatten` may be told. Every field is optional.
  record FlattenOptions
    --- How many arrays and objects may nest below the value walked,
    --- 1 to [`Json.depth_limit`] (default [`Json.default_depth`], 64), as
    --- [`Json.EncodeOptions.max_depth`] counts. Deeper fails the walk.
    max_depth?: integer
    --- The steps the value was found at (default none), each position
    --- counted from 1, so its leaves' steps run from the document.
    root?: Json.Steps
  end
end

--- `given`, a `max_depth`, when it is an integer from `least` to `most`
--- (no upper bound when `most` is nil); otherwise raises, naming the
--- caller `level` frames above the function that calls this one.
local function checked_depth(given: any, least: integer, most: integer?, level: integer): integer
  if not (given is integer) or given < least or (most ~= nil and given > most) then
    local range = if most ~= nil then "from " .. least .. " to " .. most else "of at least " .. least end
    error("json: max_depth must be an integer " .. range, level + 1)
  end
  return given
end

--- `steps` as a JSON Pointer in quotes, for a message: `pointer "/a/0"`.
local function at_pointer(steps: Json.Steps): string
  local pointer, _ = Json.pointer(steps)
  if pointer == nil then return "a place no JSON Pointer names" end
  return "pointer " .. Json.quote(pointer)
end

--- Every leaf of `value`, each as its steps and its value, in a list,
--- and "": a scalar, [`Json.null`], or an empty object or array, which
--- is itself a leaf (that value, whose [`flat_line`] is `{}` or `[]`).
--- The steps run from `opts.root`, so [`Json.get`] follows a leaf's from
--- the document to it. The order is fixed: an object's keys in byte
--- order, an array's elements by position, and a container's leaves
--- before the next one's, so the same value always flattens to the same
--- list. A hole in an array (a decoded `null` without `null_value`) is
--- not a leaf, and its neighbours keep their positions. A scalar `value`
--- is one leaf, at `opts.root`. nil and a message naming the place by
--- its JSON Pointer when nesting passes `max_depth` (default
--- [`Json.default_depth`]), a table contains itself, or a table's keys
--- mix strings and integers or are neither, as `encode` would refuse
--- it. Raises when `max_depth` is not an integer from 1 to
--- [`Json.depth_limit`].
---
---     local doc = assert(Json.decode('{"a": [1, {"b": []}]}'))
---     for _, leaf in ipairs((assert(json_query.flatten(doc)))) do
---       print(assert(json_query.flat_line(leaf.steps, leaf.value)))
---     end
---     -- $.a[0] = 1
---     -- $.a[1].b = []
function json_query.flatten(value: any, opts?: json_query.FlattenOptions): {Json.Match}?, string
  local limit = Json.default_depth
  local root: Json.Steps = {}
  if opts ~= nil then
    local max_depth = opts.max_depth
    if max_depth ~= nil then
      limit = checked_depth(max_depth, 1, Json.depth_limit, 2)
    end
    local opts_root = opts.root
    if opts_root ~= nil then root = opts_root end
  end
  local leaves: mut {Json.Match} = {}
  local open: {any:boolean} = {}
  local steps: Json.Steps = table.move(root, 1, #root, 1, {})
  local function leaf(v: any)
    leaves[#leaves + 1] = { steps = table.move(steps, 1, #steps, 1, {}), value = v }
  end
  -- Walks `v`, answering why it cannot be read, if it cannot.
  local function walk(v: any, depth: integer): string?
    if not (v is {any:any}) then
      leaf(v)
      return nil
    end
    local t: {any:any} = v
    local members = Json.members(t)
    local shape, keys, extent = members.layout, members.keys, members.extent
    if shape == "mixed" then
      return "the value at " .. at_pointer(steps) .. " is a table with mixed keys"
    end
    if depth >= limit then
      return "the value at " .. at_pointer(steps) .. " nests deeper than max_depth " .. limit
    end
    if open[v] then
      return "the value at " .. at_pointer(steps) .. " contains itself"
    end
    open[v] = true
    local before = #leaves
    local function child(step: string | integer, member: any): string?
      if member == nil then return nil end
      steps[#steps + 1] = step
      local why = walk(member, depth + 1)
      steps[#steps] = nil
      return why
    end
    local failed: string? = nil
    if shape == "array" then
      for i = 1, extent do
        failed = child(i, t[i])
        if failed ~= nil then break end
      end
    else
      for _, key in ipairs(keys) do
        failed = child(key, t[key])
        if failed ~= nil then break end
      end
    end
    open[v] = nil
    if failed ~= nil then return failed end
    if #leaves == before then leaf(v) end
    return nil
  end
  local failed = walk(value, 0)
  if failed ~= nil then return nil, failed end
  return leaves, ""
end

--- `steps` as a JSONPath query for a person to paste into a shell in
--- single quotes: `.name` for a name that is a word, `["a key"]` (in
--- JSON's escapes, which JSONPath reads) for any other, and `[1]` for a
--- position, counted from 0. Unlike [`Json.path`]'s normalized form it
--- starts `$[` only before a name that is no word or a position, and
--- holds a `'` only where a name does, so a word-and-index path needs no
--- escape in single quotes. nil and why for a step [`Json.path`] refuses.
local function shorthand(steps: Json.Steps): string?, string
  local checked, bad = Json.path(steps)
  if checked == nil then return nil, bad end
  local parts: mut {string} = { "$" }
  for _, step in ipairs(steps) do
    if step is string then
      if step:match("^[%a_][%w_]*$") then
        parts[#parts + 1] = "." .. step
      else
        parts[#parts + 1] = "[" .. Json.quote(step) .. "]"
      end
    elseif step >= 1 then
      parts[#parts + 1] = "[" .. tostring(step - 1) .. "]"
    else
      parts[#parts + 1] = "[" .. tostring(step) .. "]"
    end
  end
  return table.concat(parts), ""
end

--- One line of `flatten`'s output: the place `steps` name as a JSONPath
--- query in shorthand form, ` = `, and `value` as compact
--- [`Json.encode`] writes it, so `$.a[0].b = 1200.5` and
--- `$["a key"] = true`. `cosmic json` reads the place back, so a line
--- found with `grep` gives its path to `cosmic json '$.a[0].b'`; the
--- place ends at the first ` = ` outside a quoted name. nil and a
--- message naming the place by its JSON Pointer when `value` cannot be
--- encoded, or a step is no step [`Json.path`] writes.
function json_query.flat_line(steps: Json.Steps, value: any): string?, string
  local path, bad = shorthand(steps)
  if path == nil then return nil, bad end
  local text, err = Json.encode_any(value)
  if text == nil then return nil, "the value at " .. at_pointer(steps) .. ": " .. err end
  return path .. " = " .. text, ""
end

--- What the values seen at one place look like, merged.
local record Node
  scalars: mut {string:boolean}
  mut objects: integer
  fields: mut {string:Node}
  seen: mut {string:integer}
  mut arrays: integer
  mut shortest: integer
  mut longest: integer
  mut elements?: Node
  mut cut: boolean
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
    if n > 0 then
      local elements = node.elements or new_node()
      node.elements = elements
      for i = 1, n do
        absorb(elements, v[i], depth + 1, limit)
      end
    end
  else
    node.objects = node.objects + 1
    if depth >= limit then
      node.cut = true
      return
    end
    for key, member in pairs(v) do
      local name: any = key
      if name is string then
        local field = node.fields[name]
        if field == nil then
          field = new_node()
          node.fields[name] = field
        end
        node.seen[name] = (node.seen[name] or 0) + 1
        absorb(field, member, depth + 1, limit)
      end
    end
  end
end

local function sorted_keys<T>(t: {string:T}): {string}
  local keys: mut {string} = {}
  for key in pairs(t) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

local function render(node: Node): string
  local parts: mut {string} = sorted_keys(node.scalars)
  if node.objects > 0 then
    if node.cut then
      parts[#parts + 1] = "{...}"
    else
      local members: mut {string} = {}
      for _, name in ipairs(sorted_keys(node.fields)) do
        local optional = if node.seen[name] < node.objects then "?" else "" end
        members[#members + 1] = (name:match("^[%a_][%w_]*$") and name or Json.quote(name)) .. optional .. ": " .. render(node.fields[name])
      end
      parts[#parts + 1] = "{" .. table.concat(members, ", ") .. "}"
    end
  end
  if node.arrays > 0 then
    local size = tostring(node.shortest)
    if node.longest ~= node.shortest then size = size .. ".." .. node.longest end
    local elements = node.elements
    if node.cut then
      parts[#parts + 1] = "[" .. size .. " x ...]"
    elseif elements == nil then
      parts[#parts + 1] = "[" .. size .. "]"
    else
      parts[#parts + 1] = "[" .. size .. " x " .. render(elements) .. "]"
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
