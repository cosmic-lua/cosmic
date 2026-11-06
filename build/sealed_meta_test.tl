--- [`build.test_key`]'s `sealed_meta`: the meta rows of the sealed database
--- of a worker. One whose closure reads `image_hash` is given the value,
--- one that does not is given the marker that withholds it, as its closure
--- store holds it, and a process with no value to hand on to a worker that
--- reads it is refused, not recorded as a database without the row.

local test_key = require("build.test_key")

--- What a process with `rows` as its `meta` answers.
local function reader(rows: {string:string}): function(key: string): string?
  return function(key: string): string? return rows[key] end
end

--- The rows as text, one `key=value` a row.
local function spelled(rows: {{string}}): string
  local out: mut {string} = {}
  for _, row in ipairs(rows) do out[#out + 1] = tostring(row[1]) .. "=" .. tostring(row[2]) end
  return table.concat(out, " ")
end

local function test_a_reader_is_given_the_value_and_any_other_the_marker()
  local process = reader({ host_image = "core", runtime_basis = "basis", image_hash = "image",
    compiler = "tool" })
  local read = assert(test_key.sealed_meta(false, true, process))
  assert(spelled(read) == "core_sha256=core main=cmd.cosmic.main runtime_basis=basis image_hash=image",
    spelled(read))
  local other = assert(test_key.sealed_meta(true, false, process))
  assert(spelled(other) ==
      "core_sha256=core main=cmd.cosmic.main runtime_basis=basis withheld_meta=image_hash compiler=tool",
    spelled(other))
end

local function test_a_reader_is_refused_where_the_process_has_no_value_to_hand_on()
  local rows, why = test_key.sealed_meta(false, true, reader({ host_image = "core", runtime_basis = "basis" }))
  assert(rows == nil and why:find("no image_hash to record", 1, true) ~= nil, why)
  rows, why = test_key.sealed_meta(false, true, reader({ host_image = "core", runtime_basis = "basis", image_hash = "" }))
  assert(rows == nil and why:find("no image_hash to record", 1, true) ~= nil, why)
  local without, trouble = test_key.sealed_meta(false, false, reader({ host_image = "core" }))
  assert(without == nil and trouble:find("no core digest or runtime basis", 1, true) ~= nil, trouble)
  assert(test_key.sealed_meta(false, false, reader({ host_image = "core", runtime_basis = "basis" })) ~= nil)
end
