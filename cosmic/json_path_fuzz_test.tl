--- Fuzz properties for cosmic.json's path readers, which read text from
--- outside: `query` and `from_path` are total on any bytes and name a
--- byte inside the text when they refuse it; `from_pointer` is total
--- too; and steps written as a normalized path or a JSON Pointer read
--- back as the same steps, reaching the same value. `FUZZ_SEED` and
--- `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Json = require("cosmic.json")

--- Queries to mutate: every form the subset reads, and the forms it
--- refuses by name.
local SAMPLES <const> = {
  "$", "$.a.b", "$['a']['b']", '$["a\\"b"]', "$[0][-1]", "$.*", "$[*]", "$..a", "$..[0]", "$..*",
  "$['\\u00e9\\ud83d\\ude00\\n']", "$ .a [ 'b' ] [ 2 ]", "$.\u{e9}t\u{e9}", "$[9007199254740991]",
  "$[1:2]", "$[?@.a]", "$[0, 1]", "$['a", "$.users[*].name",
}

local TOKENS <const> = { "$", ".", "..", "[", "]", "'", '"', "\\", "\\u", "d83d", "dc00", "*", "-", "0", "1",
  "9", ":", ",", "?", " ", "\t", "\n", "a", "_", "\xc3\xa9", "\xff", "\0" }

local function gen_query(src: Fuzz.Source): string
  if src:int(0, 3) == 0 then
    local parts: {string} = {}
    while Fuzz.more(src, #parts, 20) do parts[#parts + 1] = Fuzz.pick(src, TOKENS) end
    return table.concat(parts)
  end
  return Fuzz.mutate(src, Fuzz.pick(src, SAMPLES), src:int(0, 4))
end

--- A query either reads, or is refused naming a column in the text (or
--- just past it); it never raises; and a singular one's steps write as
--- a normalized path that reads back as themselves.
local function query_holds(input: string): boolean, string
  local ok, q, err = pcall(Json.query, input)
  if not ok then return false, "query raised: " .. tostring(q) end
  if q == nil then
    local column = (err as string):match("^json: JSONPath byte (%d+): ")
    local at = math.tointeger(tonumber(column))
    if at == nil or at < 1 or at > #input + 1 then
      return false, "a refusal that names no byte: " .. tostring(err)
    end
    Fuzz.label("refused")
    return true, ""
  end
  Fuzz.label("read")
  local sok, steps, serr = pcall(Json.from_path, input)
  if not sok then return false, "from_path raised: " .. tostring(steps) end
  if steps == nil then
    if not (serr as string):match("selects many values") then
      return false, "from_path refused: " .. tostring(serr)
    end
    return true, ""
  end
  Fuzz.label("singular")
  local text, perr = Json.path(steps as Json.Steps)
  if text == nil then return false, "a path from_path read cannot be written: " .. perr end
  local back, berr = Json.from_path(text)
  if back == nil then return false, "a normalized path does not read: " .. text .. ": " .. berr end
  if Json.path(back) ~= text then
    return false, "a normalized path reads as other steps: " .. text
  end
  return true, ""
end

--- Draws steps and builds a value they reach, so a pointer to them names
--- a value: each name a member, each position an element of an array
--- long enough.
local NAMES <const> = { "a", "", "~", "/", "~1", "a/b~c", "it's", '"', "\\", "\n", "\0", "\u{e9}", "\u{1f600}",
  "0", "-", "01" }

local function gen_steps(src: Fuzz.Source): string
  local parts: {string} = {}
  while Fuzz.more(src, #parts, 6) do
    local kind = src:int(0, 3)
    if kind == 0 then
      parts[#parts + 1] = "n" .. Fuzz.pick(src, NAMES)
    elseif kind == 1 then
      parts[#parts + 1] = "i" .. tostring(src:int(1, 4))
    elseif kind == 2 then
      parts[#parts + 1] = "h" .. tostring(src:int(1, 4))
    else
      parts[#parts + 1] = "e" .. tostring(src:int(1, 4))
    end
  end
  return Fuzz.pack(parts)
end

--- The steps an input names, and how each array on the way is built:
--- "i" a marked array, "h" an unmarked table with a hole below the
--- position, "e" a marked array the step counts back from the end of.
local function steps_of(input: string): Json.Steps, {string}
  local steps: Json.Steps = {}
  local builds: {string} = {}
  for i, part in ipairs(Fuzz.unpack(input)) do
    local kind = part:sub(1, 1)
    builds[i] = kind
    if kind == "n" then
      steps[i] = part:sub(2)
    else
      local n = math.tointeger(tonumber(part:sub(2))) as integer
      steps[i] = kind == "e" and -n or n
    end
  end
  return steps, builds
end

--- A value holding "leaf" at `steps`, each array on the way built as
--- `builds` says: for a position, an element at every index below it
--- (but the one a hole leaves out); counted from the end, the leaf
--- first of as many elements as the step counts back.
local function holder(steps: Json.Steps, builds: {string}, i: integer): any
  if i > #steps then return "leaf" end
  local step = steps[i]
  if step is string then
    return { [step] = holder(steps, builds, i + 1), other = 0 }
  end
  local list: {any: any} = builds[i] == "h" and {} or Json.array() as {any: any}
  if step < 0 then
    list[1] = holder(steps, builds, i + 1)
    for k = 2, -step do list[k] = k end
    return list
  end
  for k = 1, step - 1 do
    if not (builds[i] == "h" and k == step - 1) then list[k] = k end
  end
  list[step] = holder(steps, builds, i + 1)
  return list
end

local function steps_hold(input: string): boolean, string
  local steps, builds = steps_of(input)
  local value = holder(steps, builds, 1)
  if Json.get(value, steps) ~= "leaf" then return false, "the steps reach another value" end
  local backward = false
  for _, step in ipairs(steps) do
    if not (step is string) and step < 0 then backward = true end
  end
  if backward then
    -- A pointer cannot count from the end: the path, and the query it
    -- is, must still reach the leaf.
    local path = assert(Json.path(steps))
    local again, aerr = Json.from_path(path)
    if again == nil or Json.path(again) ~= path then
      return false, "from_path read other steps: " .. path .. aerr
    end
    local found = assert(Json.select(value, (assert(Json.query(path)))))
    if #found ~= 1 or found[1].value ~= "leaf" then
      return false, "the query does not select the leaf: " .. path
    end
    Fuzz.label("from the end")
    return true, ""
  end
  local pointer, err = Json.pointer(steps)
  if pointer == nil then return false, "pointer refused: " .. err end
  local back, berr = Json.from_pointer(value, pointer)
  if back == nil then
    return false, "from_pointer refused its own pointer " .. Json.quote(pointer) .. ": " .. berr
  end
  if Json.pointer(back) ~= pointer then
    return false, "from_pointer read other steps: " .. pointer
  end
  if Json.get(value, back) ~= "leaf" then
    return false, "the steps reach another value: " .. pointer
  end
  local path, perr = Json.path(steps)
  if path == nil then return false, "path refused: " .. perr end
  local again, aerr = Json.from_path(path)
  if again == nil then return false, "from_path refused its own path " .. path .. ": " .. aerr end
  if Json.path(again) ~= path then return false, "from_path read other steps: " .. path end
  local found = assert(Json.select(value, (assert(Json.query(path)))))
  if #found ~= 1 or found[1].value ~= "leaf" then
    return false, "the query does not select the leaf: " .. path
  end
  Fuzz.label(#steps > 0 and "stepped" or "empty")
  return true, ""
end

--- `from_pointer` never raises on any bytes, and a pointer it reads
--- names a value `get` reaches.
local POINTED <const> = assert(Json.decode('{"a": [1, {"b": null, "": [true]}], "~": {"/": 2}, "0": "zero"}',
  { null_value = Json.null }))

local function pointer_holds(input: string): boolean, string
  local ok, steps, err = pcall(Json.from_pointer, POINTED, input)
  if not ok then return false, "from_pointer raised: " .. tostring(steps) end
  if steps == nil then
    if not (err as string):match("^json: ") then
      return false, "a refusal outside the module: " .. tostring(err)
    end
    Fuzz.label("refused")
    return true, ""
  end
  local _, gerr = Json.get(POINTED, steps as Json.Steps)
  if gerr ~= "" then return false, "a pointer read, its steps reach nothing: " .. gerr end
  Fuzz.label("read")
  return true, ""
end

local function gen_pointer(src: Fuzz.Source): string
  local samples = { "", "/a/1/b", "/a/1/", "/~0/~1", "/0", "/a/01", "/a/-", "/~2", "/a/0/x" }
  if src:int(0, 2) == 0 then return Fuzz.bytes(src, 12) end
  return Fuzz.mutate(src, Fuzz.pick(src, samples), src:int(0, 3))
end

local function test_queries_read_or_name_a_column(tmp: string)
  Fuzz.run({ name = "json query", dir = tmp, gen = gen_query, check = query_holds,
    requires = { "read", "refused", "singular" } })
end

local function test_steps_round_trip_through_both_texts(tmp: string)
  Fuzz.run({ name = "json steps", dir = tmp, gen = gen_steps, check = steps_hold,
    requires = { "stepped", "from the end" } })
end

local function test_pointers_read_or_refuse(tmp: string)
  Fuzz.run({ name = "json pointer", dir = tmp, gen = gen_pointer, check = pointer_holds,
    requires = { "read", "refused" } })
end

--- A drawn document, of objects keyed "a", "b" or "c", arrays and
--- scalars, as JSON text.
local function gen_document(src: Fuzz.Source, depth: integer): string
  local kind = src:int(0, depth >= 3 and 0 or 5)
  if kind == 0 then return Fuzz.pick(src, { "1", "null", '"s"' }) end
  local parts: {string} = {}
  if kind <= 2 then
    while Fuzz.more(src, #parts, 4) do parts[#parts + 1] = gen_document(src, depth + 1) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local used: {string: boolean} = {}
  while Fuzz.more(src, #parts, 3) do
    local name = Fuzz.pick(src, { "a", "b", "c" })
    if not used[name] then
      used[name] = true
      parts[#parts + 1] = '"' .. name .. '":' .. gen_document(src, depth + 1)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

--- A document, whether its nulls are holes, and a query of child and
--- descendant segments of names, indices and `*`.
local function gen_selection(src: Fuzz.Source): string
  local segments: {string} = {}
  repeat
    local selector: string
    local kind = src:int(1, 3)
    if kind == 1 then
      selector = "[*]"
    elseif kind == 2 then
      selector = "['" .. Fuzz.pick(src, { "a", "b", "c" }) .. "']"
    else
      selector = "[" .. src:int(-3, 3) .. "]"
    end
    segments[#segments + 1] = (src:int(0, 1) == 0 and ".." or "") .. selector
  until not Fuzz.more(src, #segments, 4)
  return Fuzz.pack({ gen_document(src, 0), src:int(0, 1) == 0 and "holes" or "nulls", "$" .. table.concat(segments) })
end

--- What a reference walk visits under a node: its children, an array's
--- in order to its highest position, an object's in byte order.
local function reference_children(node: Json.Match): {Json.Match}
  local out: {Json.Match} = {}
  local v = node.value
  if not (v is {any: any}) then return out end
  local t = v as {any: any}
  local layout = Json.layout(t)
  local function child(step: string | integer, value: any)
    local steps: Json.Steps = table.move(node.steps, 1, #node.steps, 1, {})
    steps[#steps + 1] = step
    out[#out + 1] = { steps = steps, value = value }
  end
  if layout == "array" or layout == "hole" then
    local top = 0
    for k in pairs(t) do
      if k is integer and k > top then top = k end
    end
    for i = 1, top do
      if t[i] ~= nil then child(i, t[i]) end
    end
  elseif layout == "object" then
    local names: {string} = {}
    for k in pairs(t) do names[#names + 1] = k as string end
    table.sort(names)
    for _, k in ipairs(names) do child(k, t[k]) end
  end
  return out
end

--- What `seg` selects under `node`, by the reference walk.
local function reference_select(seg: Json.Segment, node: Json.Match, out: {Json.Match})
  local kids = reference_children(node)
  local top = 0
  for _, kid in ipairs(kids) do
    local last = kid.steps[#kid.steps]
    if last is integer and last > top then top = last end
  end
  for _, kid in ipairs(kids) do
    local last = kid.steps[#kid.steps]
    local hit = seg.kind == "wildcard" or (seg.kind == "name" and last == seg.name)
    if seg.kind == "index" and last is integer then
      local want = seg.index >= 0 and seg.index + 1 or top + 1 + seg.index
      hit = last == want
    end
    if hit then out[#out + 1] = kid end
  end
  if seg.descendant then
    for _, kid in ipairs(kids) do reference_select(seg, kid, out) end
  end
end

--- [`Json.select`] selects what a step-by-step reference walk of RFC 9535
--- selects, in the same order, duplicates and all, with nulls as values
--- and as holes.
local function selection_holds(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local text, holes, query = fields[1], fields[2] == "holes", fields[3]
  -- A document of `null` alone decodes to nil: test the message.
  local doc, derr = Json.decode(text, { null_value = (not holes) and Json.null or nil })
  if derr ~= "" then return false, "a drawn document does not decode: " .. derr end
  local q, qerr = Json.query(query)
  if q == nil then return false, "a drawn query does not read: " .. qerr end
  local nodes: {Json.Match} = { { steps = {}, value = doc } }
  for _, seg in ipairs(q.segments) do
    local out: {Json.Match} = {}
    for _, node in ipairs(nodes) do
      if seg.descendant then
        -- A descendant segment applies its selector at the node itself
        -- and at every value beneath it.
        local visit: function(Json.Match)
        visit = function(n: Json.Match)
          reference_select({ descendant = false, kind = seg.kind, name = seg.name, index = seg.index }, n, out)
          for _, kid in ipairs(reference_children(n)) do visit(kid) end
        end
        visit(node)
      else
        reference_select(seg, node, out)
      end
    end
    nodes = out
  end
  local found, err = Json.select(doc, q)
  if found == nil then return false, "select refused: " .. err end
  local want, got: {string}, {string} = {}, {}
  for i, n in ipairs(nodes) do want[i] = assert(Json.path(n.steps)) end
  for i, m in ipairs(found) do got[i] = assert(Json.path(m.steps)) end
  local a, b = table.concat(got, " "), table.concat(want, " ")
  if a ~= b then return false, query .. " on " .. text .. ":\n got  " .. a .. "\n want " .. b end
  Fuzz.label(#found > 0 and "selected" or "selected nothing")
  return true, ""
end

local function test_select_matches_a_step_by_step_reference(tmp: string)
  Fuzz.run({ name = "json select", dir = tmp, gen = gen_selection, check = selection_holds,
    requires = { "selected", "selected nothing" } })
end
