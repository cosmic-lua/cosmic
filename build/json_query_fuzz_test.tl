--- Fuzz properties for [`json_query.parse_path`] and [`json_query.parse_pattern`], which
--- read a path a person typed: they are total on any bytes, `parse_path`
--- reads back the steps [`json_query.child_path`] spelled, for any keys (bytes that
--- are not UTF-8, dots, brackets, quotes, control characters) and any
--- integers, `parse_pattern` those [`json_query.spell_pattern`] spelled, and
--- [`json_query.select`] finds what a plain walk of the document does.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Json = require("cosmic.json")
local json_query = require("build.json_query")

--- Keys that need quoting, and one that does not, drawn more often than
--- chance would.
local KEYS <const> = { "a", "rows", "_x1", "a key", "", "a.b", "[0]", "]", "[", '"', "\\", '\\"', "$",
  "*", "..", ".*", "\n", "\0", "\x7f", "\xc3\xa9", "\xe2\x82\xac", "\xf0\x9f\x98\x80", "\xff\xfe", "\xed\xa0\x80", "1", "-1" }

local INTEGERS <const>: {integer} = { 1, 2, 10, 0, -1, 9223372036854775807, math.mininteger }

local function render(steps: {string | integer}): string
  local text = "$"
  for _, step in ipairs(steps) do text = json_query.child_path(text, step) end
  return text
end

local function same(a: {string | integer}, b: {string | integer}): boolean
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] or math.type(a[i] as number) ~= math.type(b[i] as number) then return false end
  end
  return true
end

--- Steps as packed fields: `i` and an integer, or `s` and a key.
local function gen_steps(src: Fuzz.Source): string
  local fields: {string} = {}
  while Fuzz.more(src, #fields // 2, 6) do
    local kind = src:int(0, 3)
    if kind == 0 then
      fields[#fields + 1] = "i"
      fields[#fields + 1] = tostring(src:int(0, 3) == 0 and Fuzz.pick(src, INTEGERS) or src:int(-5, 100000))
    else
      fields[#fields + 1] = "s"
      fields[#fields + 1] = kind == 1 and Fuzz.pick(src, KEYS) or Fuzz.bytes(src, 6)
    end
  end
  return Fuzz.pack(fields)
end

-- Drawn paths render and read back as themselves: about half the steps
-- are keys that need `["..."]`, and a few are integers at the edges.
local function test_a_rendered_path_reads_back(tmp: string)
  Fuzz.run({
    name = "json path round trip",
    dir = tmp,
    gen = gen_steps,
    requires = { "quoted key", "bare key", "index", "empty path" },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local steps: {string | integer} = {}
      for i = 1, #fields - 1, 2 do
        if fields[i] == "i" then
          steps[#steps + 1] = math.tointeger(tonumber(fields[i + 1]) as number)
          Fuzz.label("index")
        else
          local key = fields[i + 1]
          steps[#steps + 1] = key
          Fuzz.label(key:match("^[%a_][%w_]*$") and "bare key" or "quoted key")
        end
      end
      if #steps == 0 then Fuzz.label("empty path") end
      local text = render(steps)
      local ok, got, err = pcall(json_query.parse_path, text)
      if not ok then return false, "raised on " .. Json.quote(text) .. ": " .. tostring(got) end
      if got == nil then return false, "refused " .. Json.quote(text) .. ": " .. err end
      if not same(got as {string | integer}, steps) then
        return false, "read " .. render(got as {string | integer}) .. " for " .. Json.quote(text)
      end
      -- The same path with no leading `$` and no first dot reads the same.
      local first = steps[1]
      if first is string and first:match("^[%a_][%w_]*$") then
        local bare = text:sub(3)
        local again = json_query.parse_path(bare)
        if again == nil or not same(again, steps) then
          return false, "bare " .. Json.quote(bare) .. " read differently"
        end
      end
      return true, ""
    end,
  })
end

--- Well-formed and nearly well-formed paths to mutate: the forms the
--- parser reads, each escape, and the refusals.
local SAMPLES <const> = {
  "$", "$.a", "a.b", ".a.b", "[1]", "$[1][2]", '$["a key"]', '["a"]["b"]', "$.rows[2].name",
  '$["\\u00e9\\ud83d\\ude00"]', '$["\\"\\\\\\/\\b\\f\\n\\r\\t"]', "$[-3]", "$[9223372036854775808]",
  '$["\\ud83d"]', '$["\\ude00"]', '$["\\x"]', '$["a', '$["a"', "$.", "$..a", "$[", "$[]", "$[1", "$[1.5]",
  "$a", "", "a..b", "$.*", "$[*]", "*", "$.a..b", '$["*"]', "$.a*", "$[ 1 ]", '$["a"]x',
  "$..*", "$..[*]", "$..[1]", '$..["k k"].x', "$..", "$...a", "..a", "$.a..[", "$[*].b[*]", "$..a..b..c",
}

local TOKENS <const> = { "$", ".", "[", "]", '"', "\\", "\\u", "d83d", "de00", "0", "1", "-", "a", " ",
  "*", "..", "[*]", "..[", "\0", "\xc3", "\xff", "9223372036854775808" }

local function gen_text(src: Fuzz.Source): string
  if src:int(0, 3) == 0 then
    local parts: {string} = {}
    while Fuzz.more(src, #parts, 20) do
      parts[#parts + 1] = src:int(0, 3) == 0 and Fuzz.bytes(src, 3) or Fuzz.pick(src, TOKENS)
    end
    return table.concat(parts)
  end
  return Fuzz.mutate(src, Fuzz.pick(src, SAMPLES), src:int(0, 1) == 0 and 0 or 4)
end

-- Any text is a path or a message, never a raise; a path it reads
-- renders and reads back as itself. About a third of drawn texts read.
local function test_parse_path_is_total_on_any_text(tmp: string)
  Fuzz.run({
    name = "json path total",
    dir = tmp,
    gen = gen_text,
    requires = { "read", "refused" },
    shares = { read = 0.15, refused = 0.15 },
    check = function(input: string): boolean, string
      local ok, got, err = pcall(json_query.parse_path, input)
      if not ok then return false, "raised: " .. tostring(got) end
      if got == nil then
        Fuzz.label("refused")
        if not (err is string) or err == "" then return false, "a refusal with no message" end
        return true, ""
      end
      if err ~= "" then return false, "a path with a message: " .. err end
      Fuzz.label("read")
      local steps = got as {string | integer}
      local again, why = json_query.parse_path(render(steps))
      if again == nil then return false, "did not read back its own spelling: " .. why end
      if not same(again, steps) then
        return false, "spelling " .. render(steps) .. " read differently"
      end
      return true, ""
    end,
  })
end

--- The steps of `pattern` as a plain path's, or nil when one is not
--- a plain key or index.
local function plain_steps(pattern: {json_query.Step}): {string | integer} | nil
  local out: {string | integer} = {}
  for i, step in ipairs(pattern) do
    local plain: string | integer | nil = step.kind == "key" and step.key or step.kind == "index" and step.index or nil
    if plain == nil then return nil end
    out[i] = plain
  end
  return out
end

local function test_parse_pattern_is_total_and_agrees_with_parse_path(tmp: string)
  Fuzz.run({
    name = "json pattern total",
    dir = tmp,
    gen = gen_text,
    requires = { "plain", "wild", "refused" },
    shares = { plain = 0.1, wild = 0.03, refused = 0.15 },
    check = function(input: string): boolean, string
      local ok, pattern, err = pcall(json_query.parse_pattern, input)
      if not ok then return false, "raised: " .. tostring(pattern) end
      local path, path_err = json_query.parse_path(input)
      if pattern == nil then
        Fuzz.label("refused")
        if not (err is string) or err == "" then return false, "a refusal with no message" end
        if path ~= nil then return false, "parse_path read what parse_pattern refused: " .. err end
        return true, ""
      end
      local steps = pattern as {json_query.Step}
      local plain = plain_steps(steps)
      if plain ~= nil then
        Fuzz.label("plain")
        if path == nil or not same(path as {string | integer}, plain) then
          return false, "pattern and path disagree on " .. Json.quote(input)
        end
      else
        Fuzz.label("wild")
        if path ~= nil then return false, "parse_path read a wildcard: " .. Json.quote(input) end
        if not path_err:find("is a pattern, not a path", 1, true) then
          return false, "parse_path refused a pattern without saying it is one: " .. path_err
        end
      end
      local again = json_query.parse_pattern(json_query.spell_pattern(steps))
      if again == nil or json_query.spell_pattern(again) ~= json_query.spell_pattern(steps) then
        return false, "spelling of " .. Json.quote(input) .. " read differently"
      end
      return true, ""
    end,
  })
end

--- The five kinds of step a pattern draws, as packed fields.
local function gen_pattern_steps(src: Fuzz.Source): string
  local fields: {string} = {}
  while Fuzz.more(src, #fields // 2, 5) do
    local kind = Fuzz.pick(src, { "key", "index", "any", "deep_key", "deep_index", "deep_any" })
    fields[#fields + 1] = kind
    if kind == "key" or kind == "deep_key" then
      fields[#fields + 1] = src:int(0, 2) == 0 and Fuzz.bytes(src, 4) or Fuzz.pick(src, KEYS)
    elseif kind == "index" or kind == "deep_index" then
      fields[#fields + 1] = tostring(src:int(0, 3) == 0 and Fuzz.pick(src, INTEGERS) or src:int(-2, 5))
    else
      fields[#fields + 1] = ""
    end
  end
  return Fuzz.pack(fields)
end

local function steps_of(packed: string): {json_query.Step}
  local fields = Fuzz.unpack(packed)
  local steps: {json_query.Step} = {}
  for i = 1, #fields - 1, 2 do
    local kind = fields[i] as json_query.StepKind
    local step: json_query.Step = { kind = kind }
    if kind == "key" or kind == "deep_key" then
      step.key = fields[i + 1]
    elseif kind == "index" or kind == "deep_index" then
      step.index = math.tointeger(tonumber(fields[i + 1]) as number)
    end
    steps[#steps + 1] = step
  end
  return steps
end

local function same_steps(a: {json_query.Step}, b: {json_query.Step}): boolean
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i].kind ~= b[i].kind or a[i].key ~= b[i].key or a[i].index ~= b[i].index then
      return false
    end
  end
  return true
end

-- Drawn patterns, over any keys, spell and read back as the same steps,
-- and `parse_path` refuses one exactly when it has a wildcard or a `..`.
local function test_a_spelled_pattern_reads_back(tmp: string)
  Fuzz.run({
    name = "json pattern round trip",
    dir = tmp,
    gen = gen_pattern_steps,
    requires = { "deep key", "deep index", "any", "deep any", "plain", "wild", "empty" },
    check = function(input: string): boolean, string
      local steps = steps_of(input)
      if #steps == 0 then Fuzz.label("empty") end
      for _, step in ipairs(steps) do
        Fuzz.label(step.kind == "deep_key" and "deep key" or step.kind == "deep_index" and "deep index" or
            step.kind == "deep_any" and "deep any" or step.kind == "any" and "any" or "plain step")
      end
      local text = json_query.spell_pattern(steps)
      local ok, read, err = pcall(json_query.parse_pattern, text)
      if not ok then return false, "raised on " .. Json.quote(text) .. ": " .. tostring(read) end
      if read == nil then return false, "refused " .. Json.quote(text) .. ": " .. err end
      if not same_steps(read as {json_query.Step}, steps) then
        return false, "read " .. json_query.spell_pattern(read as {json_query.Step}) .. " for " .. Json.quote(text)
      end
      local plain = plain_steps(steps)
      local path = json_query.parse_path(text)
      if (plain == nil) ~= (path == nil) then
        return false, "parse_path and the pattern's kinds disagree on " .. Json.quote(text)
      end
      Fuzz.label(plain == nil and "wild" or "plain")
      return true, ""
    end,
  })
end

--- One value of a small drawn document, as JSON text: keys from a few
--- names so patterns meet them, arrays and objects nested a few deep.
local function gen_doc(src: Fuzz.Source, depth: integer): string
  local kind = src:int(0, depth >= 3 and 0 or 5)
  if kind == 0 then
    return Fuzz.pick(src, { "1", '"s"', "true", "null", "2.5" })
  elseif kind <= 2 then
    local parts: {string} = {}
    while Fuzz.more(src, #parts, depth == 0 and 6 or 4) do
      parts[#parts + 1] = gen_doc(src, depth + 1)
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local names: {string} = { "a", "b", "c", "1" }
  local parts: {string} = {}
  local used: {string:boolean} = {}
  while Fuzz.more(src, #parts, 4) do
    local name = Fuzz.pick(src, names)
    if not used[name] then
      used[name] = true
      parts[#parts + 1] = '"' .. name .. '":' .. gen_doc(src, depth + 1)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local record Node
  steps: {string | integer}
  value: any
end

local function spelled(steps: {string | integer}): string
  local text = "$"
  for _, step in ipairs(steps) do text = json_query.child_path(text, step) end
  return text
end

--- The children of `node`, in document order.
local function children(node: Node): {Node}
  local out: {Node} = {}
  local function child(step: string | integer, value: any)
    local steps: {string | integer} = {}
    for i, s in ipairs(node.steps) do steps[i] = s end
    steps[#steps + 1] = step
    out[#out + 1] = { steps = steps, value = value }
  end
  local items = json_query.items(node.value)
  if items ~= nil then
    -- A decoded array may have holes where a null was dropped: its
    -- elements are the integer keys, in order.
    local indexes: {integer} = {}
    local loose: {any:any} = items as {any:any}
    for index in pairs(loose) do indexes[#indexes + 1] = index as integer end
    table.sort(indexes)
    for _, index in ipairs(indexes) do child(index, items[index]) end
    return out
  end
  local members = json_query.entries(node.value)
  if members ~= nil then
    local names: {string} = {}
    for name in pairs(members) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do child(name, members[name]) end
  end
  return out
end

--- Every value below `node`, each before what is inside it: the order a
--- match list has to keep.
local function below(node: Node, out: {Node}): {Node}
  for _, kid in ipairs(children(node)) do
    out[#out + 1] = kid
    below(kid, out)
  end
  return out
end

--- What `pattern` matches, found the slow way: one step at a time over
--- the values so far, `..` over everything below each, a value kept once.
local function reference(root: Node, pattern: {json_query.Step}): {string}
  local now: {Node} = { root }
  for _, step in ipairs(pattern) do
    local next_nodes: {Node} = {}
    local seen: {string:boolean} = {}
    for _, node in ipairs(now) do
      local candidates: {Node}
      if step.kind == "deep_key" or step.kind == "deep_index" or step.kind == "deep_any" then
        candidates = below(node, {})
      else
        candidates = children(node)
      end
      for _, cand in ipairs(candidates) do
        local last = cand.steps[#cand.steps]
        local hit = step.kind == "any" or step.kind == "deep_any" or
          ((step.kind == "key" or step.kind == "deep_key") and last == step.key) or
          ((step.kind == "index" or step.kind == "deep_index") and last == step.index)
        local at = spelled(cand.steps)
        if hit and not seen[at] then
          seen[at] = true
          next_nodes[#next_nodes + 1] = cand
        end
      end
    end
    now = next_nodes
  end
  local wanted: {string:boolean} = {}
  for _, node in ipairs(now) do wanted[spelled(node.steps)] = true end
  local ordered: {string} = {}
  if wanted["$"] then ordered[1] = "$" end
  for _, node in ipairs(below(root, {})) do
    local at = spelled(node.steps)
    if wanted[at] then ordered[#ordered + 1] = at end
  end
  return ordered
end

-- `select` lists what the step-by-step reference does, each value once
-- and in document order, whatever the pattern and the document.
local function test_select_matches_a_step_by_step_reference(tmp: string)
  Fuzz.run({
    name = "json select reference",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      local fields: {string} = {}
      local steps: {string} = {}
      while Fuzz.more(src, #steps // 2, 8) do
        local kind = Fuzz.pick(src, { "key", "index", "any", "any", "deep_key", "deep_key", "deep_index", "deep_any" })
        steps[#steps + 1] = kind
        if kind == "key" or kind == "deep_key" then
          steps[#steps + 1] = Fuzz.pick(src, { "a", "b", "c", "1" })
        elseif kind == "index" or kind == "deep_index" then
          steps[#steps + 1] = tostring(src:int(1, 6))
        else
          steps[#steps + 1] = ""
        end
      end
      fields[1] = gen_doc(src, 0)
      fields[2] = Fuzz.pack(steps)
      -- Without `null_value`, a null in an array is a hole.
      fields[3] = src:int(0, 1) == 0 and "nulls" or "holes"
      return Fuzz.pack(fields)
    end,
    requires = { "matched", "unmatched", "descent", "several", "holes" },
    shares = { matched = 0.2, unmatched = 0.1, descent = 0.3, several = 0.02, holes = 0.1 },
    check = function(input: string): boolean, string
      local fields = Fuzz.unpack(input)
      local doc = Json.decode(fields[1], { null_value = fields[3] == "nulls" and Json.null or nil })
      local pattern = steps_of(fields[2])
      local want = reference({ steps = {}, value = doc }, pattern)
      local ok, found, err = pcall(json_query.select, doc, pattern, { max_depth = 100 })
      if not ok then return false, "raised: " .. tostring(found) end
      if found == nil then return false, "failed: " .. err end
      local got_paths: {string} = {}
      for i, match in ipairs(found as {json_query.Located}) do got_paths[i] = match.path end
      local text = json_query.spell_pattern(pattern)
      if table.concat(got_paths, " ") ~= table.concat(want, " ") then
        return false, text .. " on " .. fields[1] .. ": got [" .. table.concat(got_paths, " ") ..
          "], want [" .. table.concat(want, " ") .. "]"
      end
      Fuzz.label(#want > 0 and "matched" or "unmatched")
      if #want > 1 then Fuzz.label("several") end
      if fields[3] == "holes" then Fuzz.label("holes") end
      if text:find("..", 1, true) then Fuzz.label("descent") end
      return true, ""
    end,
  })
end

-- Every path `flatten` lists reads back through `parse_path` and `get` to
-- its leaf, and is a path `select` of `$..*` finds (or is `$` itself).
local function test_every_flattened_path_reads_back_and_is_selectable(tmp: string)
  Fuzz.run({
    name = "json flatten read back",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack({ gen_doc(src, 0), src:int(0, 1) == 0 and "nulls" or "holes" })
    end,
    requires = { "leaves", "empty container" },
    check = function(packed: string): boolean, string
      local fields = Fuzz.unpack(packed)
      local doc = Json.decode(fields[1], { null_value = fields[2] == "nulls" and Json.null or nil })
      local ok, leaves, err = pcall(json_query.flatten, doc)
      if not ok then return false, "raised: " .. tostring(leaves) end
      if leaves == nil then return false, "failed: " .. err end
      local every = json_query.select(doc, { { kind = "deep_any" } }, { max_depth = 100 })
      local selectable: {string:boolean} = { ["$"] = true }
      for _, match in ipairs(every or {}) do selectable[match.path] = true end
      local previous = ""
      for _, leaf in ipairs(leaves as {json_query.Located}) do
        Fuzz.label("leaves")
        local steps, why = json_query.parse_path(leaf.path)
        if steps == nil then return false, leaf.path .. " does not read: " .. why end
        local value, get_err = json_query.get(doc, steps)
        if get_err ~= "" then return false, leaf.path .. ": " .. get_err end
        local a, b = Json.encode(value), Json.encode(leaf.value)
        if a ~= b then
          return false, leaf.path .. " reads back as " .. tostring(a) .. ", not " .. tostring(b)
        end
        if a == "{}" or a == "[]" then Fuzz.label("empty container") end
        if not selectable[leaf.path] then return false, leaf.path .. " is not selected by $..*" end
        if leaf.path == previous then return false, leaf.path .. " twice" end
        previous = leaf.path
      end
      return true, ""
    end,
  })
end
