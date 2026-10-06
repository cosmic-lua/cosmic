--- A fuzz property for [`json_query.flatten`] and [`json_query.flat_line`]:
--- over any drawn document, every leaf's line begins with a path that
--- [`Json.from_path`] reads back to steps that [`Json.get`] follows to
--- the leaf, at a place a `$..*` query selects. The paths
--- themselves are read by cosmic.json, fuzzed in
--- cosmic/json_path_fuzz_test.tl. `FUZZ_SEED` and `FUZZ_ITERS` pick the
--- inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local Json = require("cosmic.json")
local json_query = require("build.json_query")

--- One value of a small drawn document, as JSON text: keys from a few
--- names, among them ones a path must quote, and arrays and objects
--- nested a few deep.
local function gen_doc(src: Fuzz.Source, depth: integer): string
  local kind = src:int(0, depth >= 3 and 0 or 5)
  if kind == 0 then
    return Fuzz.pick(src, { "1", '"s"', "true", "null", "2.5", '"x = y"' })
  elseif kind <= 2 then
    local parts: {string} = {}
    while Fuzz.more(src, #parts, depth == 0 and 6 or 4) do
      parts[#parts + 1] = gen_doc(src, depth + 1)
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local names: {string} = { "a", "b", "1", "a b", "it's", "k = v", "" }
  local parts: {string} = {}
  local used: {string:boolean} = {}
  while Fuzz.more(src, #parts, 4) do
    local name = Fuzz.pick(src, names)
    if not used[name] then
      used[name] = true
      parts[#parts + 1] = Json.quote(name) .. ":" .. gen_doc(src, depth + 1)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Every leaf `flatten` lists reads back from its line's path to itself,
-- and is a place a `$..*` query selects (or is the document itself).
local function test_every_flattened_path_reads_back_and_is_selectable(tmp: string)
  Fuzz.run({
    name = "json flatten read back",
    dir = tmp,
    gen = function(src: Fuzz.Source): string
      return Fuzz.pack({ gen_doc(src, 0), src:int(0, 1) == 0 and "nulls" or "holes" })
    end,
    requires = { "leaves", "empty container", "quoted" },
    check = function(packed: string): boolean, string
      local fields = Fuzz.unpack(packed)
      -- Without `null_value`, a null in an array is a hole.
      local doc = Json.decode(fields[1], { null_value = fields[2] == "nulls" and Json.null or nil })
      local ok, leaves, err = pcall(json_query.flatten, doc)
      if not ok then return false, "raised: " .. tostring(leaves) end
      if leaves == nil then return false, "failed: " .. err end
      local every = assert(Json.select(doc, (assert(Json.query("$..*")))))
      local selectable: {string:boolean} = { ["$"] = true }
      for _, match in ipairs(every) do selectable[assert(Json.path(match.steps))] = true end
      local seen: {string:boolean} = {}
      for _, leaf in ipairs(leaves as {Json.Match}) do
        Fuzz.label("leaves")
        local normal = assert(Json.path(leaf.steps))
        local line, line_err = json_query.flat_line(leaf.steps, leaf.value)
        if line == nil then return false, normal .. ": " .. line_err end
        local tail = " = " .. assert(Json.encode(leaf.value))
        if line:sub(-#tail) ~= tail then return false, line .. " does not end with" .. tail end
        local path = line:sub(1, #line - #tail)
        local steps, why = Json.from_path(path)
        if steps == nil then return false, path .. " does not read: " .. why end
        if Json.path(steps) ~= normal then
          return false, path .. " reads back as " .. Json.path(steps)
        end
        local value, get_err = Json.get(doc, steps)
        if get_err ~= "" then return false, path .. ": " .. get_err end
        local a, b = Json.encode(value), Json.encode(leaf.value)
        if a ~= b then
          return false, path .. " reads back as " .. tostring(a) .. ", not " .. tostring(b)
        end
        if a == "{}" or a == "[]" then Fuzz.label("empty container") end
        if path:find('["', 1, true) ~= nil then Fuzz.label("quoted") end
        if not selectable[normal] then return false, path .. " is not selected by $..*" end
        if seen[path] then return false, path .. " twice" end
        seen[path] = true
      end
      return true, ""
    end,
  })
end
