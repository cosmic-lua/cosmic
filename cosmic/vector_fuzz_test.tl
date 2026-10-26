--- Fuzz properties for the vectors of [`cosmic.vector`] and the SQL
--- functions beside them (core/vector.c): the text a vector is read from,
--- every SQL function over arbitrary blobs, the packing functions, the
--- corpus's search against a brute-force reference, and the centroid
--- search. Each is total -- an answer or a refusal, never a crash -- and
--- each answer is held to a reference written here in Teal, over the
--- bytes. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
---
--- The references use numbers a float holds exactly (small integers and
--- quarters) wherever an answer is compared for equality, so a mismatch
--- is a wrong answer and not a different rounding; sums of other numbers
--- are compared within a tolerance.

local Fuzz = require("build.fuzz")
local Sqlite = require("cosmic.sqlite")
local Vector = require("cosmic.vector")

-- The in-memory database the SQL-reading properties ask; each opens it
-- before its run and closes it after.
local held: mut {string: Sqlite.Handle} = {}

local function open_database()
  held["db"] = assert(Sqlite.memory())
end

local function close_database()
  assert(held["db"]):close()
  held["db"] = nil
end

--- The largest finite float, as a double.
local FLT_MAX <const> = 3.4028234663852886e38

local function finite(x: number): boolean
  return x == x and x ~= math.huge and x ~= -math.huge
end

--- A double rounded to the float nearest it.
local function f32(x: number): number
  return (string.unpack("<f", string.pack("<f", x)))
end

local function floats_of(blob: string): {number}
  local out: mut {number} = {}
  for at = 1, #blob - 3, 4 do
    out[#out + 1] = (string.unpack("<f", blob, at))
  end
  return out
end

local function blob_of(numbers: {number}): string
  local parts: mut {string} = {}
  for _, x in ipairs(numbers) do
    parts[#parts + 1] = string.pack("<f", x)
  end
  return table.concat(parts)
end

local function to_int(text: string): integer
  return assert(math.tointeger(assert(tonumber(text))))
end

local function hex_of(s: string): string
  return (s:gsub(".", function(c: string): string
    return string.format("%02x", assert(c:byte()))
  end))
end

--- What a statement answered: its kind (`error` for a failed statement,
--- else the SQLite type of its one cell), and the cell's bytes or number.
local record Answer
  kind: string
  bytes: string
  number: number
  why: string
end

local function ask(sql: string, values: {Sqlite.Value}): Answer
  local rows, why = Sqlite.rows(assert(held["db"], "no database open"), sql, values)
  if rows == nil then
    return { kind = "error", bytes = "", number = 0, why = why }
  end
  local row = assert(rows[1], "no row")
  local kind = row:kind(1)
  if kind == "blob" then
    return { kind = "blob", bytes = row:blob(1), number = 0, why = "" }
  elseif kind == "text" then
    return { kind = "text", bytes = row:text(1), number = 0, why = "" }
  elseif kind == "integer" or kind == "number" then
    return { kind = kind, bytes = "", number = row:number(1), why = "" }
  end
  return { kind = "null", bytes = "", number = 0, why = "" }
end

--------------------------------------------------------------------------
-- The text a vector is read from
--------------------------------------------------------------------------

--- Numbers whose spelling Lua's `tonumber` and the core's reader agree on.
local VALID_TOKENS <const>: {string} = {
  "0", "1", "-1", "+2", ".5", "1.", "1e3", "1E-3", "1e+2", "0x1p3", "0x.8", "0X1.8P-1", "0x10",
  "007", "3.4028235e38", "3.4028236e38", "1e-50", "-0.0", "1e-45", "1.4e-45", "5e-324",
  "123456789.123456789", "0.1", "-2.5e-3", "1e38", "340282346638528859811704183484516925440",
}

--- Spellings neither reads as a number a float holds.
local INVALID_TOKENS <const>: {string} = {
  "1e39", "1e400", "-1e39", "nan", "NaN", "inf", "-inf", "Infinity", "", "e5", "1e", "0x", "--1",
  "1.2.3", "1_0", "0b1", "1 2", "\xd9\xa3", "-", "+", ".", "0x1p", "1e+", "3.5e38",
}

local SPACES <const>: {string} = { "", "", "", " ", "\t", "\n", "\r", "  ", " \n " }
local SEPARATORS <const>: {string} = { ",", ",", ",", ", ", " ,", ",\n", ",,", "", ";", "\f,", ",\v" }

--- What `tonumber` reads of a token, as a float, or nil when it is not a
--- finite one.
local function token_value(token: string): number?
  local x = tonumber(token)
  if x == nil then return nil end
  -- Lua reads "-0" as the integer 0, which has no sign.
  if x == 0 and math.type(x) == "integer" and token:sub(1, 1) == "-" then x = -0.0 end
  local rounded = f32(x)
  if not finite(rounded) then return nil end
  return rounded
end

local function gen_token(src: Fuzz.Source, invalid: boolean): string
  local r = src:int(0, 9)
  if invalid and r < 3 then return Fuzz.pick(src, INVALID_TOKENS) end
  if r == 9 then
    -- digits, a point and an exponent, drawn one at a time
    local out: mut {string} = {}
    while Fuzz.more(src, #out, 24) do
      out[#out + 1] = Fuzz.pick(src, { "0", "1", "5", "9", ".", "e", "-", "+", "x", "p" })
    end
    return table.concat(out)
  end
  return Fuzz.pick(src, VALID_TOKENS)
end

local function gen_clean_text(src: Fuzz.Source, invalid: boolean): string
  local out: mut {string} = {}
  local first = Fuzz.pick(src, SPACES)
  while Fuzz.more(src, #out, 12) do
    out[#out + 1] = Fuzz.pick(src, SPACES) .. gen_token(src, invalid) .. Fuzz.pick(src, SPACES)
  end
  return first .. "[" .. table.concat(out, ",") .. "]" .. Fuzz.pick(src, SPACES)
end

local function gen_dirty_text(src: Fuzz.Source): string
  local out: mut {string} = {}
  while Fuzz.more(src, #out, 12) do
    out[#out + 1] = Fuzz.pick(src, SPACES) .. gen_token(src, true)
  end
  local open, close = "[", "]"
  if src:int(0, 5) == 0 then open = Fuzz.pick(src, { "", "(", "[[", " " }) end
  if src:int(0, 5) == 0 then close = Fuzz.pick(src, { "", ")", "]]", "] ", "]x" }) end
  local text = Fuzz.pick(src, SPACES) .. open .. table.concat(out, Fuzz.pick(src, SEPARATORS))
    .. close .. Fuzz.pick(src, SPACES)
  if src:int(0, 4) == 0 then
    local at = src:int(0, #text)
    text = text:sub(1, at) .. "\0" .. text:sub(at + 1)
  end
  return text
end

local function gen_text_input(src: Fuzz.Source): string
  local mode = src:int(0, 9)
  if mode <= 3 then
    return Fuzz.pack({ "clean", gen_clean_text(src, true) })
  elseif mode <= 5 then
    return Fuzz.pack({ "any", gen_dirty_text(src) })
  elseif mode <= 7 then
    return Fuzz.pack({ "any", Fuzz.mutate(src, gen_clean_text(src, false), 3) })
  elseif mode == 8 then
    local count = Fuzz.pick(src, { 15999, 16000, 16001, 16002 })
    return Fuzz.pack({ "clean", "[" .. string.rep("0,", count - 1) .. "1]" })
  end
  return Fuzz.pack({ "any", Fuzz.bytes(src, 24) })
end

--- The blob a clean text spells, or nil when it spells no vector.
local function clean_reference(text: string): string?
  local body = text:match("^%s*%[(.*)%]%s*$")
  if body == nil then return nil end
  local numbers: mut {number} = {}
  local start = 1
  while true do
    local comma = body:find(",", start, true)
    local token = body:sub(start, (comma or #body + 1) - 1):match("^%s*(.-)%s*$")
    local x = token_value(assert(token))
    if x == nil then return nil end
    numbers[#numbers + 1] = x
    if comma == nil then break end
    start = comma + 1
  end
  if #numbers > 16000 then return nil end
  return blob_of(numbers)
end

local function check_text(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local mode, text = assert(fields[1]), assert(fields[2])
  local param: Sqlite.Value = { text = text }
  local blob = ask("SELECT vector(?1)", { param })
  local as_text = ask("SELECT vector_text(?1)", { param })
  local dims = ask("SELECT vector_dims(?1)", { param })
  local json, json_why = Vector.from_json(text)
  if blob.kind ~= "error" and blob.kind ~= "blob" then
    return false, "vector() answered " .. blob.kind
  end
  if (blob.kind == "blob") ~= (as_text.kind == "text") or (blob.kind == "blob") ~= (dims.kind == "integer") then
    return false, ("vector %s, vector_text %s, vector_dims %s of %q"):format(
      blob.kind, as_text.kind, dims.kind, text)
  end
  if (blob.kind == "blob") ~= (json ~= nil) then
    return false, ("vector() %s but from_json answered %s %s of %q"):format(
      blob.kind, tostring(json ~= nil), json_why, text)
  end
  if text:find("\0", 1, true) then
    Fuzz.label("nul")
    if blob.kind == "blob" then
      return false, ("a text with a NUL read as the vector %s: %q"):format(hex_of(blob.bytes), text)
    end
  end
  if mode == "clean" then
    local want = clean_reference(text)
    if want == nil then
      if blob.kind == "blob" then
        return false, ("%q read as %s, which no reading of its numbers gives"):format(text, hex_of(blob.bytes))
      end
    elseif blob.kind ~= "blob" or blob.bytes ~= want then
      return false, ("%q should read as %s, not %s %s"):format(text, hex_of(want), blob.kind,
        hex_of(blob.bytes) .. blob.why)
    end
    Fuzz.label(if want == nil then "clean refused" else "clean read" end)
  end
  if blob.kind ~= "blob" then
    if json_why == "" then return false, "from_json refused without a reason" end
    Fuzz.label("refused")
    return true, ""
  end
  Fuzz.label("read")
  if text:find("[xX]") then Fuzz.label("hex") end
  if text:find("[eE]") then Fuzz.label("exponent") end
  if json ~= blob.bytes then return false, "from_json and vector() read " .. text .. " differently" end
  local n = #blob.bytes // 4
  if #blob.bytes % 4 ~= 0 or n < 1 or n > 16000 or dims.number ~= n then
    return false, ("a vector of %d bytes, %s dimensions"):format(#blob.bytes, tostring(dims.number))
  end
  for _, x in ipairs(floats_of(blob.bytes)) do
    if not finite(x) then return false, "vector() answered a number that is not finite" end
  end
  -- The text a vector is written as reads back as the same vector.
  local written: Sqlite.Value = { blob = blob.bytes }
  local out = ask("SELECT vector_text(?1)", { written })
  if out.kind ~= "text" then return false, "vector_text of a vector answered " .. out.kind end
  local back_param: Sqlite.Value = { text = out.bytes }
  local back = ask("SELECT vector(?1)", { back_param })
  if back.kind ~= "blob" or back.bytes ~= blob.bytes then
    return false, ("%s was written as %s, which reads back as %s %s"):format(
      hex_of(blob.bytes), out.bytes, back.kind, hex_of(back.bytes) .. back.why)
  end
  if as_text.bytes ~= out.bytes then
    return false, "vector_text of the text and of its blob differ: " .. as_text.bytes .. " " .. out.bytes
  end
  return true, ""
end

local function test_vector_reads_text_exactly_or_refuses(tmp: string)
  open_database()
  Fuzz.run({
    name = "vector text",
    dir = tmp,
    gen = gen_text_input,
    check = check_text,
    requires = { "read", "refused", "clean read", "clean refused", "hex", "exponent", "nul" },
    shares = { read = 0.1, refused = 0.1, ["clean read"] = 0.05, ["clean refused"] = 0.1 },
  })
  close_database()
end

--------------------------------------------------------------------------
-- Every SQL function over arbitrary arguments
--------------------------------------------------------------------------

--- Floats a vector is made of: ones a sum of ordinary size holds, then
--- ones it does not, then the bit patterns of not-a-number and infinity.
local ORDINARY <const>: {number} = { 0, 0, -0.0, 1, -1, 2, 0.5, -0.5, 3, 7, 1e-3, 100, 1e6, -1e6 }
local EXTREME <const>: {number} = { 1e-30, -1e-30, 1e-40, 1e19, 1e20, -1e20, 1e30, 3.4e38, -3.4e38,
  1.17549435e-38 }
local ODD_BITS <const>: {string} = { "\0\0\xc0\x7f", "\0\0\x80\x7f", "\0\0\x80\xff", "\x01\0\x80\x7f",
  "\0\0\xc0\xff" }

--- Four bytes: one float.
local function gen_chunk(src: Fuzz.Source, extreme: boolean, finite_only: boolean): string
  local r = src:int(0, 9)
  if r <= 6 or not extreme then return string.pack("<f", Fuzz.pick(src, ORDINARY)) end
  if r <= 8 or finite_only then return string.pack("<f", Fuzz.pick(src, EXTREME)) end
  if src:int(0, 1) == 0 then return Fuzz.pick(src, ODD_BITS) end
  return string.char(src:int(0, 255), src:int(0, 255), src:int(0, 255), src:int(0, 255))
end

--- The floats of a vector: `want` of them, or as many as the source
--- draws.
local function gen_chunks(src: Fuzz.Source, extreme: boolean, finite_only: boolean, want: integer?): string
  local out: mut {string} = {}
  if want ~= nil then
    for _ = 1, want do out[#out + 1] = gen_chunk(src, extreme, finite_only) end
  else
    while Fuzz.more(src, #out, 12) do out[#out + 1] = gen_chunk(src, extreme, finite_only) end
  end
  return table.concat(out)
end

--- One argument, spelled `<kind><payload>`: `n` NULL, `i` an integer, `t`
--- the text of a vector (the payload is its floats), `x` text that is no
--- vector, `b` a blob, `z` a zeroblob of the payload's length.
local function gen_arg(src: Fuzz.Source, extreme: boolean, want: integer?): string
  local r = src:int(0, 21)
  if r == 0 then return "n" end
  if r == 1 then return "i" .. tostring(src:int(-3, 40)) end
  if r <= 3 then return "t" .. gen_chunks(src, extreme, true, want) end
  if r == 4 then return "x" .. Fuzz.pick(src, { "", "[]", "abc", "[1,", "1,2", "[nan]", "[1] x" }) end
  if r <= 6 then return "b" .. Fuzz.bytes(src, 30) end
  if r == 7 then return "z" .. tostring(Fuzz.pick(src, { 0, 1, 3, 4, 8, 12, 64000, 64004, 100000 })) end
  if r == 8 then return "b" .. string.rep("\0\0\0\0", want or src:int(1, 6)) end
  return "b" .. gen_chunks(src, extreme, false, want)
end

local INT_EDGES <const>: {integer} = { math.mininteger, math.mininteger + 1, -(1 << 62), -1000, math.maxinteger,
  math.maxinteger - 1, 1 << 62, 1000 }

local function gen_int_arg(src: Fuzz.Source): string
  local r = src:int(0, 9)
  if r == 0 then return "n" end
  if r == 1 then return "i" .. tostring(Fuzz.pick(src, INT_EDGES)) end
  return "i" .. tostring(src:int(-3, 10))
end

local function gen_functions_input(src: Fuzz.Source): string
  local extreme = src:int(0, 2) == 0
  local a = gen_arg(src, extreme, nil)
  -- Most pairs share a length, as the pairs of a search do.
  local want: integer? = nil
  if a:sub(1, 1) == "b" or a:sub(1, 1) == "t" then
    if #a % 4 == 1 and src:int(0, 3) > 0 then want = (#a - 1) // 4 end
  end
  return Fuzz.pack({ a, gen_arg(src, extreme, want), gen_int_arg(src), gen_int_arg(src) })
end

local record Arg
  kind: string
  payload: string
end

local function parse_arg(field: string): Arg
  return { kind = field:sub(1, 1), payload = field:sub(2) }
end

--- The text a `t` argument stands for.
local function render_text(blob: string): string
  local parts: mut {string} = {}
  for _, x in ipairs(floats_of(blob)) do
    parts[#parts + 1] = string.format("%.17g", x)
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

--- Adds an argument's value to `values` and answers how a statement
--- names it.
local function bind(argument: Arg, values: mut {Sqlite.Value}): string
  local k = argument.kind
  if k == "z" then return "zeroblob(" .. argument.payload .. ")" end
  if k == "n" then
    local null: Sqlite.Value = {}
    values[#values + 1] = null
  elseif k == "i" then
    values[#values + 1] = { integer = to_int(argument.payload) }
  elseif k == "t" then
    values[#values + 1] = { text = render_text(argument.payload) }
  elseif k == "x" then
    values[#values + 1] = { text = argument.payload }
  else
    values[#values + 1] = { blob = argument.payload }
  end
  return "?" .. tostring(#values)
end

local function call(fn: string, args: {Arg}): Answer
  local values: mut {Sqlite.Value} = {}
  local names: mut {string} = {}
  for _, a in ipairs(args) do
    names[#names + 1] = bind(a, values)
  end
  return ask("SELECT " .. fn .. "(" .. table.concat(names, ", ") .. ")", values)
end

--- The bytes of an argument that is a blob.
local function blob_bytes(a: Arg): string?
  if a.kind == "b" then return a.payload end
  if a.kind == "z" then return string.rep("\0", to_int(a.payload)) end
  return nil
end

--- The floats of an argument that is a vector: a blob of 1 to 16000, or
--- the text of one.
local function vector_floats(a: Arg): {number}?
  if a.kind == "t" then
    local floats = floats_of(a.payload)
    if #floats == 0 then return nil end
    return floats
  end
  local bytes = blob_bytes(a)
  if bytes == nil or #bytes % 4 ~= 0 or #bytes == 0 or #bytes // 4 > 16000 then return nil end
  return floats_of(bytes)
end

--- What a function of these arguments must do: answer NULL (any argument
--- is), refuse (an argument that should be a vector or a bit vector is
--- not, or two differ in length), or answer.
local function expected_state(args: {Arg}, vectors: {integer}, bits: boolean): string
  for _, a in ipairs(args) do
    if a.kind == "n" then return "null" end
  end
  local length = -1
  for _, at in ipairs(vectors) do
    local a = assert(args[at])
    local n: integer
    if bits then
      local bytes = blob_bytes(a)
      if bytes == nil then return "error" end
      n = #bytes
    else
      local floats = vector_floats(a)
      if floats == nil then return "error" end
      n = #floats
    end
    if length == -1 then
      length = n
    elseif length ~= n then
      return "error"
    end
  end
  return "answer"
end

--- True when the answer is the kind the state names; `answer` also needs
--- a kind from `kinds`.
local function holds_state(fn: string, state: string, ans: Answer, kinds: {string}): boolean, string
  if state == "null" then
    if ans.kind ~= "null" then return false, fn .. " of a NULL answered " .. ans.kind end
  elseif state == "error" then
    if ans.kind ~= "error" then return false, fn .. " should refuse, and answered " .. ans.kind end
  elseif ans.kind == "error" then
    return false, fn .. " refused: " .. ans.why
  else
    for _, kind in ipairs(kinds) do
      if ans.kind == kind then return true, "" end
    end
    return false, fn .. " answered " .. ans.kind
  end
  return true, ""
end

local function all_finite(floats: {number}): boolean
  for _, x in ipairs(floats) do
    if not finite(x) then return false end
  end
  return true
end

local function all_zero(floats: {number}): boolean
  for _, x in ipairs(floats) do
    if x ~= 0 then return false end
  end
  return true
end

--- Whether every number is zero or of a size where a sum of float
--- products is within a small tolerance of the exact one.
local function ordinary(floats: {number}): boolean
  for _, x in ipairs(floats) do
    local m = math.abs(x)
    if m ~= 0 and (m < 1e-3 or m > 1e6) then return false end
  end
  return true
end

local function check_distance(fn: string, a: Arg, b: Arg): boolean, string
  local args = { a, b }
  local state = expected_state(args, { 1, 2 }, false)
  local ans = call(fn, args)
  local ok, why = holds_state(fn, state, ans, { "number", "null" })
  if not ok then return false, why end
  if state ~= "answer" then
    Fuzz.label(state)
    return true, ""
  end
  local fa, fb = assert(vector_floats(a)), assert(vector_floats(b))
  if not (all_finite(fa) and all_finite(fb)) then
    Fuzz.label("not finite")
    return true, ""
  end
  local zero = all_zero(fa) or all_zero(fb)
  if fn == "cosine_distance" and zero then
    if ans.kind ~= "null" then return false, "cosine_distance of a vector of zeros answered a number" end
    return true, ""
  end
  if ans.kind == "null" then return false, fn .. " answered NULL for finite vectors" end
  if not finite(ans.number) then
    return false, fn .. " answered " .. tostring(ans.number) .. " for finite vectors"
  end
  if fn == "cosine_distance" and (ans.number < 0 or ans.number > 2) then
    return false, "cosine_distance answered " .. tostring(ans.number)
  end
  if fn == "l2_distance" or fn == "l1_distance" then
    if ans.number < 0 then return false, fn .. " answered " .. tostring(ans.number) end
  end
  -- Past the ordinary band the reference is the same sums in double,
  -- which the float ones may not match (they overflow or underflow, and
  -- the function redoes them in double): a wrong but finite answer fails
  -- here, as does one that underflowed to zero. A result near zero is
  -- held to the relative tolerance alone, with no absolute floor.
  local band = ordinary(fa) and ordinary(fb)
  local floor = if band then 1e-9 else 0.0 end
  local dot, abs_dot, squares, l1, na, nb = 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
  for i = 1, #fa do
    local x, y = assert(fa[i]), assert(fb[i])
    dot = dot + x * y
    abs_dot = abs_dot + math.abs(x * y)
    squares = squares + (x - y) * (x - y)
    l1 = l1 + math.abs(x - y)
    na = na + x * x
    nb = nb + y * y
  end
  local want: number
  local tolerance: number
  if fn == "inner_product" then
    want, tolerance = dot, 1e-5 * abs_dot + floor
  elseif fn == "l2_distance" then
    want = math.sqrt(squares)
    tolerance = 1e-5 * want + floor
  elseif fn == "l1_distance" then
    want, tolerance = l1, 1e-5 * l1 + floor
  else
    want = 1 - math.max(-1, math.min(1, dot / math.sqrt(na * nb)))
    tolerance = 1e-4
  end
  if math.abs(ans.number - want) > tolerance then
    return false, ("%s answered %.9g, not %.9g"):format(fn, ans.number, want)
  end
  Fuzz.label(if band then "distance compared" else "distance of extremes" end)
  return true, ""
end

local function check_normalize(a: Arg): boolean, string
  local state = expected_state({ a }, { 1 }, false)
  local ans = call("l2_normalize", { a })
  local ok, why = holds_state("l2_normalize", state, ans, { "blob" })
  if not ok then return false, why end
  if state ~= "answer" then return true, "" end
  local floats = assert(vector_floats(a))
  if #ans.bytes ~= 4 * #floats then return false, "l2_normalize changed the length" end
  if not all_finite(floats) then return true, "" end
  local squares = 0.0
  for _, x in ipairs(floats) do squares = squares + x * x end
  local norm = math.sqrt(squares)
  local want: mut {number} = {}
  for _, x in ipairs(floats) do
    if norm == 0 then want[#want + 1] = 0.0 else want[#want + 1] = x / norm end
  end
  if ans.bytes ~= blob_of(want) then
    return false, ("l2_normalize of %s answered %s, not %s"):format(
      hex_of(blob_of(floats)), hex_of(ans.bytes), hex_of(blob_of(want)))
  end
  if norm ~= 0 then
    local length = 0.0
    for _, x in ipairs(floats_of(ans.bytes)) do length = length + x * x end
    if math.abs(length - 1) > 1e-4 then return false, "l2_normalize answered a vector of length^2 " .. tostring(length) end
    Fuzz.label("normalized")
  else
    Fuzz.label("normalized zeros")
  end
  return true, ""
end

--- Whether dimension `i` (from 1) is in SQL's substring of `count`
--- dimensions from `start`, whatever their size.
local function in_range(i: integer, start: integer, count: integer): boolean
  if count < 1 or i < start then return false end
  -- i - start would pass the largest integer, which is more than any count
  if start < 0 and i > math.maxinteger + start then return false end
  return i - start < count
end

local function check_subvector(a: Arg, s: Arg, n: Arg): boolean, string
  local args = { a, s, n }
  local state = expected_state(args, { 1 }, false)
  local ans = call("subvector", args)
  if state ~= "answer" then
    local ok, why = holds_state("subvector", state, ans, { "blob" })
    return ok, why
  end
  local floats = assert(vector_floats(a))
  local start, count = to_int(s.payload), to_int(n.payload)
  local whole = a.payload
  if a.kind == "z" then whole = assert(blob_bytes(a)) end
  local keep: mut {string} = {}
  for i = 1, #floats do
    if in_range(i, start, count) then keep[#keep + 1] = whole:sub(4 * i - 3, 4 * i) end
  end
  local who = ("subvector of %d dimensions from %d, %d"):format(#floats, start, count)
  if #keep == 0 then
    if ans.kind ~= "error" then return false, who .. " should refuse, and answered " .. ans.kind end
    Fuzz.label("subvector refused")
    return true, ""
  end
  if ans.kind ~= "blob" then return false, who .. " answered " .. ans.kind .. " " .. ans.why end
  if ans.bytes ~= table.concat(keep) then
    return false, ("%s answered %s, not %s"):format(who, hex_of(ans.bytes), hex_of(table.concat(keep)))
  end
  Fuzz.label("subvector clipped")
  return true, ""
end

local function check_quantize(a: Arg): boolean, string
  local state = expected_state({ a }, { 1 }, false)
  local ans = call("binary_quantize", { a })
  local ok, why = holds_state("binary_quantize", state, ans, { "blob" })
  if not ok then return false, why end
  if state ~= "answer" then return true, "" end
  local floats = assert(vector_floats(a))
  local want: mut {string} = {}
  for first = 1, #floats, 8 do
    local byte = 0
    for bit = 0, 7 do
      local x = floats[first + bit]
      if x ~= nil and x > 0 then byte = byte | (0x80 >> bit) end
    end
    want[#want + 1] = string.char(byte)
  end
  if ans.bytes ~= table.concat(want) then
    return false, ("binary_quantize of %s answered %s, not %s"):format(
      hex_of(blob_of(floats)), hex_of(ans.bytes), hex_of(table.concat(want)))
  end
  Fuzz.label("quantized")
  return true, ""
end

local function popcount(byte: integer): integer
  local count = 0
  while byte ~= 0 do
    count = count + (byte & 1)
    byte = byte >> 1
  end
  return count
end

local function check_bits(a: Arg, b: Arg): boolean, string
  local args = { a, b }
  local state = expected_state(args, { 1, 2 }, true)
  local hamming = call("hamming_distance", args)
  local jaccard = call("jaccard_distance", args)
  local ok, why = holds_state("hamming_distance", state, hamming, { "integer" })
  if not ok then return false, why end
  ok, why = holds_state("jaccard_distance", state, jaccard, { "number" })
  if not ok then return false, why end
  if state ~= "answer" then return true, "" end
  local x, y = assert(blob_bytes(a)), assert(blob_bytes(b))
  local both, either, differ = 0, 0, 0
  for i = 1, #x do
    local p, q = assert(x:byte(i)), assert(y:byte(i))
    both = both + popcount(p & q)
    either = either + popcount(p | q)
    differ = differ + popcount(p ~ q)
  end
  if hamming.number ~= differ then
    return false, ("hamming_distance answered %s, not %d"):format(tostring(hamming.number), differ)
  end
  local want = 0.0
  if either ~= 0 then want = 1.0 - both / either end
  if math.abs(jaccard.number - want) > 1e-12 then
    return false, ("jaccard_distance answered %.17g, not %.17g"):format(jaccard.number, want)
  end
  Fuzz.label("bits compared")
  return true, ""
end

local function check_conversions(a: Arg): boolean, string
  local state = expected_state({ a }, { 1 }, false)
  local floats: {number}? = nil
  if state == "answer" then floats = vector_floats(a) end
  local dims = call("vector_dims", { a })
  local ok, why = holds_state("vector_dims", state, dims, { "integer" })
  if not ok then return false, why end
  if floats ~= nil and dims.number ~= #floats then return false, "vector_dims counted wrongly" end
  local written = call("vector_text", { a })
  ok, why = holds_state("vector_text", state, written, { "text" })
  if not ok then return false, why end
  -- vector() also refuses a blob that holds a number that is not finite.
  local converted_state = state
  if floats ~= nil and not all_finite(floats) then converted_state = "error" end
  local converted = call("vector", { a })
  ok, why = holds_state("vector", converted_state, converted, { "blob" })
  if not ok then return false, why end
  if converted_state ~= "answer" then return true, "" end
  local bytes = a.payload
  if a.kind == "z" then bytes = assert(blob_bytes(a)) end
  if converted.bytes ~= bytes then return false, "vector() changed a vector" end
  local back_param: Sqlite.Value = { text = written.bytes }
  local back = ask("SELECT vector(?1)", { back_param })
  if back.kind ~= "blob" or back.bytes ~= bytes then
    return false, ("vector_text wrote %s for %s, which reads as %s"):format(
      written.bytes, hex_of(bytes), hex_of(back.bytes) .. back.why)
  end
  Fuzz.label("converted")
  return true, ""
end

local function check_functions(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local a, b = parse_arg(assert(fields[1])), parse_arg(assert(fields[2]))
  local s, n = parse_arg(assert(fields[3])), parse_arg(assert(fields[4]))
  for _, fn in ipairs({ "l2_distance", "inner_product", "cosine_distance", "l1_distance" }) do
    local ok, why = check_distance(fn, a, b)
    if not ok then return false, why end
  end
  local ok, why = check_normalize(a)
  if not ok then return false, why end
  ok, why = check_subvector(a, s, n)
  if not ok then return false, why end
  ok, why = check_quantize(a)
  if not ok then return false, why end
  ok, why = check_bits(a, b)
  if not ok then return false, why end
  ok, why = check_conversions(a)
  if not ok then return false, why end
  return true, ""
end

local function test_sql_functions_answer_or_refuse_by_a_reference(tmp: string)
  open_database()
  Fuzz.run({
    name = "vector sql functions",
    dir = tmp,
    gen = gen_functions_input,
    check = check_functions,
    requires = { "distance compared", "distance of extremes", "normalized", "normalized zeros",
      "subvector clipped", "subvector refused", "quantized", "bits compared", "converted", "error",
      "null", "not finite" },
    shares = { ["distance compared"] = 0.1, quantized = 0.1, converted = 0.1, ["subvector clipped"] = 0.05,
      ["bits compared"] = 0.05 },
  })
  close_database()
end

--------------------------------------------------------------------------
-- Vector.pack, unpack and normalize
--------------------------------------------------------------------------

local function describe(floats: {number}): string
  local parts: mut {string} = {}
  for _, x in ipairs(floats) do
    if x ~= x then
      parts[#parts + 1] = "nan"
    else
      parts[#parts + 1] = string.format("%.9g", x)
    end
  end
  return table.concat(parts, ",")
end

--- The vector scaled to length 1 as [`Vector.normalize`] is: the squares
--- are summed in double, and a length of zero or not finite gives zeros.
local function normalize_reference(blob: string): string
  local floats = floats_of(blob)
  local squares = 0.0
  for _, x in ipairs(floats) do squares = squares + x * x end
  local norm = math.sqrt(squares)
  local out: mut {number} = {}
  for _, x in ipairs(floats) do
    if norm == 0 or not finite(norm) then out[#out + 1] = 0.0 else out[#out + 1] = x / norm end
  end
  return blob_of(out)
end

--- Calls [`Vector.pack`] on a list built here from kinds, in a chunk of
--- plain Lua since a typed caller cannot build a list of mixed things.
local PACK_CHUNK <const> = [[
  local Vector = require("cosmic.vector")
  local kinds, tokens = ...
  local list = {}
  for i = 1, #kinds do
    local kind, token = kinds[i], tokens[i]
    if kind == "n" then
      if token == "nan" then list[i] = 0 / 0
      elseif token == "inf" then list[i] = math.huge
      elseif token == "-inf" then list[i] = -math.huge
      else list[i] = tonumber(token) end
    elseif kind == "i" then list[i] = math.tointeger(tonumber(token))
    elseif kind == "s" then list[i] = token
    elseif kind == "b" then list[i] = true
    else list[i] = {} end
  end
  local ok, packed = pcall(Vector.pack, list)
  return ok, tostring(packed)
]]

local run_pack = assert(load(PACK_CHUNK, "=vector_fuzz_pack", "t"))

local NUMBER_TOKENS <const>: {string} = { "0", "1", "-1", "0.1", "-0.5", "3.4028234663852886e38",
  "-3.4028234663852886e38", "3.4028235e38", "1e39", "-1e39", "1e-50", "1e-45", "123456.789", "nan",
  "inf", "-inf", "65504", "1e30", "0.30000000000000004" }
local INTEGER_TOKENS <const>: {string} = { "0", "7", "-3", "9007199254740993", "2147483647",
  "9223372036854775807", "-9223372036854775807" }
local ODD_KINDS <const>: {string} = { "s", "b", "t" }

local function gen_pack_input(src: Fuzz.Source): string
  local kinds: mut {string} = {}
  local tokens: mut {string} = {}
  if src:int(0, 29) == 0 then
    for _ = 1, Fuzz.pick(src, { 16000, 16001 }) do
      kinds[#kinds + 1] = "n"
      tokens[#tokens + 1] = "0"
    end
  else
    while Fuzz.more(src, #kinds, 16) do
      local r = src:int(0, 9)
      if r <= 5 then
        kinds[#kinds + 1] = "n"
        tokens[#tokens + 1] = Fuzz.pick(src, NUMBER_TOKENS)
      elseif r <= 7 then
        kinds[#kinds + 1] = "i"
        tokens[#tokens + 1] = Fuzz.pick(src, INTEGER_TOKENS)
      elseif r == 8 then
        kinds[#kinds + 1] = "n"
        tokens[#tokens + 1] = tostring(src:int(-9, 9))
      else
        kinds[#kinds + 1] = Fuzz.pick(src, ODD_KINDS)
        tokens[#tokens + 1] = Fuzz.pick(src, { "1", "1.5", "abc", "" })
      end
    end
  end
  return Fuzz.pack({ table.concat(kinds, ","), table.concat(tokens, "|") })
end

local function split(text: string, separator: string): {string}
  local out: mut {string} = {}
  local start = 1
  while true do
    local at = text:find(separator, start, true)
    if at == nil then
      out[#out + 1] = text:sub(start)
      return out
    end
    out[#out + 1] = text:sub(start, at - 1)
    start = at + #separator
  end
end

local function check_pack(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local kinds_text, tokens_text = assert(fields[1]), assert(fields[2])
  local kinds, tokens = split(kinds_text, ","), split(tokens_text, "|")
  if kinds_text == "" then
    kinds, tokens = {}, {}
  end
  -- What each entry should be, or nil for an entry no vector holds.
  local want: mut {number} = {}
  local refuses = #kinds == 0 or #kinds > 16000
  for i, kind in ipairs(kinds) do
    local token = assert(tokens[i])
    local x: number? = nil
    if kind == "n" then
      if token == "nan" then
        x = 0 / 0
      elseif token == "inf" then
        x = math.huge
      elseif token == "-inf" then
        x = -math.huge
      else
        x = tonumber(token)
      end
    elseif kind == "i" then
      x = to_int(token) * 1.0
    end
    if x == nil or not finite(x) or math.abs(x) > FLT_MAX then
      refuses = true
    else
      want[#want + 1] = f32(x)
    end
  end
  local ok, packed = run_pack(kinds, tokens)
  if not (ok is boolean and packed is string) then return false, "the chunk answered oddly" end
  if ok == refuses then
    return false, ("Vector.pack %s a list of %d (%s)"):format(
      if ok then "took" else "refused" end, #kinds, kinds_text .. " " .. tokens_text .. ": " .. packed:sub(1, 80))
  end
  if refuses then
    Fuzz.label("pack refused")
    return true, ""
  end
  Fuzz.label("packed")
  if packed ~= blob_of(want) then
    return false, ("Vector.pack answered %s, not %s"):format(hex_of(packed), hex_of(blob_of(want)))
  end
  if describe(Vector.unpack(packed)) ~= describe(want) then
    return false, "Vector.unpack did not take back what pack made"
  end
  local spelled: mut {string} = {}
  for _, x in ipairs(want) do spelled[#spelled + 1] = string.format("%.17g", x) end
  local text: Sqlite.Value = { text = "[" .. table.concat(spelled, ",") .. "]" }
  local sql = ask("SELECT vector(?1)", { text })
  if sql.kind ~= "blob" or sql.bytes ~= packed then
    return false, "Vector.pack and SQL vector() of its text differ: " .. hex_of(sql.bytes) .. sql.why
  end
  local norm = Vector.normalize(packed)
  if norm ~= normalize_reference(packed) then
    return false, "Vector.normalize differs from its reference on " .. hex_of(packed)
  end
  local blob: Sqlite.Value = { blob = packed }
  local sql_norm = ask("SELECT l2_normalize(?1)", { blob })
  if sql_norm.kind ~= "blob" or sql_norm.bytes ~= norm then
    return false, "Vector.normalize and SQL l2_normalize differ on " .. hex_of(packed)
  end
  return true, ""
end

local function test_pack_takes_numbers_and_nothing_else(tmp: string)
  open_database()
  Fuzz.run({
    name = "vector pack",
    dir = tmp,
    gen = gen_pack_input,
    check = check_pack,
    requires = { "pack refused", "packed" },
    shares = { ["pack refused"] = 0.2, packed = 0.1 },
  })
  close_database()
end

local function gen_bytes_input(src: Fuzz.Source): string
  if src:int(0, 2) == 0 then return Fuzz.bytes(src, 40) end
  local out = gen_chunks(src, true, false, nil)
  if src:int(0, 5) == 0 then out = out .. Fuzz.bytes(src, 3) end
  return out
end

local function check_bytes(blob: string): boolean, string
  local aligned = #blob % 4 == 0
  local unpacked_ok, unpacked = pcall(function(): string
    return describe(Vector.unpack(blob))
  end)
  local normalized_ok, normalized = pcall(function(): string
    return Vector.normalize(blob)
  end)
  if unpacked_ok ~= aligned or normalized_ok ~= aligned then
    return false, ("unpack %s and normalize %s a blob of %d bytes"):format(
      if unpacked_ok then "took" else "refused" end, if normalized_ok then "took" else "refused" end, #blob)
  end
  if not aligned then
    Fuzz.label("unaligned")
    return true, ""
  end
  if not (unpacked is string and normalized is string) then return false, "pcall answered oddly" end
  local floats = floats_of(blob)
  if unpacked ~= describe(floats) then
    return false, "Vector.unpack answered " .. unpacked .. ", not " .. describe(floats)
  end
  if normalized ~= normalize_reference(blob) then
    return false, ("Vector.normalize of %s answered %s"):format(hex_of(blob), hex_of(normalized))
  end
  if #floats >= 1 and #floats <= 16000 and all_finite(floats) then
    local param: Sqlite.Value = { blob = blob }
    local sql = ask("SELECT l2_normalize(?1)", { param })
    if sql.kind ~= "blob" or sql.bytes ~= normalized then
      return false, "SQL l2_normalize and Vector.normalize differ on " .. hex_of(blob)
    end
    Fuzz.label("agreed with sql")
  end
  Fuzz.label("aligned")
  return true, ""
end

local function test_unpack_and_normalize_read_any_whole_floats(tmp: string)
  open_database()
  Fuzz.run({
    name = "vector unpack and normalize",
    dir = tmp,
    gen = gen_bytes_input,
    check = check_bytes,
    requires = { "unaligned", "aligned", "agreed with sql" },
    shares = { unaligned = 0.05, aligned = 0.2 },
  })
  close_database()
end

--------------------------------------------------------------------------
-- The corpus's search against a brute-force reference
--------------------------------------------------------------------------

--- The numbers a corpus's vectors are drawn from. All but the last are
--- ones a float sum holds exactly; the last overflows a float's sums.
local function alphabet(kind: integer): {number}
  if kind == 0 then return { 0, 1 } end
  if kind == 1 then return { -1, 0, 1 } end
  if kind == 2 then return { -3, -2, -1, 0, 1, 2, 3 } end
  if kind == 3 then return { 0.25, -0.25, 0.5, 1, -1.5, 0, 2 } end
  return { 1e30, -1e30, 3e38, -3e38, 1e-30, 1, 0 }
end

local function csv(numbers: {number}): string
  local parts: mut {string} = {}
  for _, x in ipairs(numbers) do parts[#parts + 1] = string.format("%.17g", x) end
  return table.concat(parts, ",")
end

local function numbers_of(text: string): {number}
  local out: mut {number} = {}
  for token in text:gmatch("[^,]+") do out[#out + 1] = assert(tonumber(token)) end
  return out
end

local function gen_numbers(src: Fuzz.Source, letters: {number}, dims: integer): {number}
  local out: mut {number} = {}
  for _ = 1, dims do out[#out + 1] = Fuzz.pick(src, letters) end
  return out
end

local ID_EDGES <const>: {integer} = { math.mininteger, math.maxinteger, 0, -1, 1 << 40 }

local function gen_search_input(src: Fuzz.Source): string
  local kind = src:int(0, 11)
  if kind > 4 then kind = kind % 4 end
  local letters = alphabet(kind)
  local dims = Fuzz.pick(src, { 1, 1, 2, 3, 3, 4, 5, 9, 17 })
  local fields: mut {string} = { tostring(kind), tostring(dims) }
  fields[#fields + 1] = Fuzz.pick(src, { "1", "1", "2", "3", "5", "10", "40", "9223372036854775807" })
  fields[#fields + 1] = Fuzz.pick(src, { "inner_product", "cosine", "l2" })
  if src:int(0, 1) == 0 then
    fields[#fields + 1] = ""
  else
    fields[#fields + 1] = tostring(src:int(1, 30))
  end
  local allow = src:int(0, 5)
  if allow <= 2 then
    fields[#fields + 1] = "none"
  elseif allow == 3 then
    fields[#fields + 1] = "list:"
  else
    local ids: mut {string} = {}
    while Fuzz.more(src, #ids, 12) do ids[#ids + 1] = tostring(src:int(-4, 30)) end
    fields[#fields + 1] = "list:" .. table.concat(ids, ",")
  end
  fields[#fields + 1] = csv(gen_numbers(src, letters, dims))
  local rows = 0
  while Fuzz.more(src, rows, 24) do
    rows = rows + 1
    local id = src:int(-4, 30)
    if src:int(0, 14) == 0 then id = Fuzz.pick(src, ID_EDGES) end
    fields[#fields + 1] = tostring(id) .. "|" .. csv(gen_numbers(src, letters, dims))
  end
  return Fuzz.pack(fields)
end

local function metric_of(name: string): Vector.Metric
  if name == "cosine" then return "cosine" end
  if name == "l2" then return "l2" end
  return "inner_product"
end

local record Scored
  id: integer
  key: number
  row: integer
end

local function dot_of(a: {number}, b: {number}): number
  local total = 0.0
  for i, x in ipairs(a) do total = total + x * assert(b[i]) end
  return total
end

--- How near a row is, higher nearer, as the corpus ranks it.
local function key_of(metric: string, row: {number}, query: {number}): number
  if metric == "inner_product" then return dot_of(row, query) end
  if metric == "l2" then
    local total = 0.0
    for i, x in ipairs(row) do
      local d = x - assert(query[i])
      total = total + d * d
    end
    return -total
  end
  local rows, queries = dot_of(row, row), dot_of(query, query)
  if rows == 0 or queries == 0 then return -math.huge end
  return dot_of(row, query) / (math.sqrt(rows) * math.sqrt(queries))
end

local function ranked(pool: {Scored}): {Scored}
  local copy: mut {Scored} = {}
  for _, s in ipairs(pool) do copy[#copy + 1] = s end
  table.sort(copy, function(a: Scored, b: Scored): boolean
    if a.key ~= b.key then return a.key > b.key end
    return a.id < b.id
  end)
  return copy
end

local function shown(ids: {integer}, scores: {number}): string
  local parts: mut {string} = {}
  for i, id in ipairs(ids) do
    parts[#parts + 1] = tostring(id) .. ":" .. string.format("%.9g", assert(scores[i]))
  end
  return "[" .. table.concat(parts, " ") .. "]"
end

local function check_search(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local kind, dims = to_int(assert(fields[1])), to_int(assert(fields[2]))
  local k = to_int(assert(fields[3]))
  local metric = assert(fields[4])
  local candidates: integer? = nil
  if assert(fields[5]) ~= "" then candidates = to_int(assert(fields[5])) end
  local allow_field = assert(fields[6])
  local allow: {integer}? = nil
  local allowed: mut {integer: boolean} = {}
  if allow_field ~= "none" then
    local list: mut {integer} = {}
    for token in allow_field:sub(6):gmatch("[^,]+") do
      list[#list + 1] = to_int(token)
      allowed[to_int(token)] = true
    end
    allow = list
  end
  local query = numbers_of(assert(fields[7]))
  local corpus = Vector.corpus(dims)
  local pool: mut {Scored} = {}
  local rows: mut {{number}} = {}
  for at = 8, #fields do
    local id_text, numbers_text = assert(fields[at]):match("^(.-)|(.*)$")
    local id, numbers = to_int(assert(id_text)), numbers_of(assert(numbers_text))
    corpus:add(id, Vector.pack(numbers))
    rows[#rows + 1] = numbers
    if allow == nil or allowed[id] == true then
      pool[#pool + 1] = { id = id, key = key_of(metric, numbers, query), row = #rows }
    end
  end
  if corpus:count() ~= #rows then return false, "count is " .. tostring(corpus:count()) end
  local hits = assert(corpus:search(Vector.pack(query), k, { metric = metric_of(metric), candidates = candidates, allow = allow }))
  local who = ("%s k=%d candidates=%s of %d rows (%d eligible), query %s"):format(
    metric, k, tostring(candidates), #rows, #pool, csv(query))
  if #hits.ids ~= #hits.scores then return false, who .. ": ids and scores differ in length" end
  if kind == 4 then
    -- Sums that overflow: no reference, but an answer still holds together.
    -- TODO: once the corpus kernels redo a non-finite sum in double (see
    -- the TODO at the score loop in core/vector.c), hold this to a
    -- reference too; until then only the structure is checked.
    Fuzz.label("overflowing")
    local seen: mut {integer: boolean} = {}
    for _, id in ipairs(hits.ids) do seen[id] = true end
    for i, score in ipairs(hits.scores) do
      if score ~= score then return false, who .. ": a score is not a number" end
      local before = hits.scores[i - 1]
      if before ~= nil and ((metric == "l2" and before > score) or (metric ~= "l2" and before < score)) then
        return false, who .. ": scores out of order " .. shown(hits.ids, hits.scores)
      end
    end
    if #hits.ids > k or #hits.ids > #pool then return false, who .. ": too many hits" end
    return true, ""
  end

  -- The rows the binary first pass keeps, nearest in sign bits, earliest first.
  if candidates ~= nil and candidates < #pool then
    local near: mut {Scored} = {}
    local distance: mut {integer: integer} = {}
    for _, s in ipairs(pool) do
      local row = assert(rows[s.row])
      local differ = 0
      for d, x in ipairs(row) do
        if (x > 0) ~= (assert(query[d]) > 0) then differ = differ + 1 end
      end
      distance[s.row] = differ
      near[#near + 1] = s
    end
    table.sort(near, function(a: Scored, b: Scored): boolean
      local da, db = assert(distance[a.row]), assert(distance[b.row])
      if da ~= db then return da < db end
      return a.row < b.row
    end)
    local kept: mut {Scored} = {}
    for i = 1, candidates do kept[#kept + 1] = assert(near[i]) end
    pool = kept
    Fuzz.label("candidates")
  end
  local order = ranked(pool)
  local want = math.min(k, #order)
  if #hits.ids ~= want then
    return false, ("%s: %d hits, not %d: %s"):format(who, #hits.ids, want, shown(hits.ids, hits.scores))
  end
  local function score_of(s: Scored): number
    if metric == "l2" then return math.sqrt(-s.key) end
    return s.key
  end
  if metric == "cosine" then
    local used: mut {integer: boolean} = {}
    for i = 1, want do
      local expected = assert(order[i])
      local got = assert(hits.scores[i])
      if not (got == score_of(expected) or math.abs(got - score_of(expected)) <= 1e-5) then
        return false, ("%s: score %d is %.9g, not %.9g: %s"):format(who, i, got, score_of(expected),
          shown(hits.ids, hits.scores))
      end
      local before = hits.scores[i - 1]
      if before ~= nil and (before < got or (before == got and assert(hits.ids[i - 1]) > assert(hits.ids[i]))) then
        return false, who .. ": out of order " .. shown(hits.ids, hits.scores)
      end
      local found = false
      for _, s in ipairs(pool) do
        local near = s.key == got or math.abs(s.key - got) <= 1e-5
        if used[s.row] == nil and s.id == hits.ids[i] and near then
          used[s.row] = true
          found = true
          break
        end
      end
      if not found then return false, who .. ": a hit is no row's: " .. shown(hits.ids, hits.scores) end
    end
  else
    for i = 1, want do
      local expected = assert(order[i])
      if hits.ids[i] ~= expected.id or hits.scores[i] ~= score_of(expected) then
        local wanted_ids: mut {integer} = {}
        local wanted_scores: mut {number} = {}
        for j = 1, want do
          wanted_ids[#wanted_ids + 1] = assert(order[j]).id
          wanted_scores[#wanted_scores + 1] = score_of(assert(order[j]))
        end
        return false, ("%s: answered %s, not %s"):format(who, shown(hits.ids, hits.scores),
          shown(wanted_ids, wanted_scores))
      end
    end
  end
  Fuzz.label(metric)
  if want == 0 then Fuzz.label("no hits") end
  if allow ~= nil then Fuzz.label("allowed") end
  if k > #order then Fuzz.label("k outruns the rows") end
  if metric == "cosine" and want > 0 and assert(hits.scores[want]) == -math.huge then
    Fuzz.label("zero vectors last")
  end
  return true, ""
end

local function test_search_matches_a_brute_force_reference(tmp: string)
  Fuzz.run({
    name = "corpus search",
    dir = tmp,
    gen = gen_search_input,
    check = check_search,
    requires = { "inner_product", "cosine", "l2", "no hits", "allowed", "candidates", "k outruns the rows",
      "zero vectors last", "overflowing" },
    shares = { inner_product = 0.1, cosine = 0.1, l2 = 0.1, allowed = 0.1 },
  })
end

--------------------------------------------------------------------------
-- What a corpus refuses
--------------------------------------------------------------------------

--- Hostile calls, in plain Lua so that a typed caller need not build
--- their arguments. Each case says whether it raises.
local REFUSAL_CHUNK <const> = [[
  local Vector = require("cosmic.vector")
  local dims, ops = ...
  local good = {}
  for i = 1, dims do good[i] = 1 end
  good = Vector.pack(good)
  local nan = string.pack("<f", 0 / 0)
  local inf = string.pack("<f", math.huge)
  local corpus = Vector.corpus(dims)
  corpus:add(7, good)
  local count = 1
  local cases = {
    add_short = { true, function() corpus:add(1, good:sub(5)) end },
    add_long = { true, function() corpus:add(1, good .. good:sub(1, 4)) end },
    add_nan = { true, function() corpus:add(1, nan .. good:sub(5)) end },
    add_inf = { true, function() corpus:add(1, inf .. good:sub(5)) end },
    add_float_id = { true, function() corpus:add(1.5, good) end },
    add_string_id = { true, function() corpus:add("x", good) end },
    add_table = { true, function() corpus:add(1, {}) end },
    add_nil = { true, function() corpus:add(1, nil) end },
    add_ok = { false, function() corpus:add(-3, good) end },
    add_ok_again = { false, function() corpus:add(7, good) end },
    search_k0 = { true, function() corpus:search(good, 0) end },
    search_kneg = { true, function() corpus:search(good, -5) end },
    search_kfloat = { true, function() corpus:search(good, 1.5) end },
    search_kstring = { true, function() corpus:search(good, "x") end },
    search_knil = { true, function() corpus:search(good, nil) end },
    search_metric = { true, function() corpus:search(good, 1, { metric = "L2" }) end },
    search_metric_number = { true, function() corpus:search(good, 1, { metric = 5 }) end },
    search_cand0 = { true, function() corpus:search(good, 1, { candidates = 0 }) end },
    search_candneg = { true, function() corpus:search(good, 1, { candidates = -1 }) end },
    search_candfloat = { true, function() corpus:search(good, 1, { candidates = 1.5 }) end },
    search_allow_word = { true, function() corpus:search(good, 1, { allow = { "a" } }) end },
    search_allow_float = { true, function() corpus:search(good, 1, { allow = { 1.5 } }) end },
    search_allow_table = { true, function() corpus:search(good, 1, { allow = { {} } }) end },
    search_allow_number = { true, function() corpus:search(good, 1, { allow = 5 }) end },
    search_short = { true, function() corpus:search(good:sub(5), 1) end },
    search_nan = { true, function() corpus:search(nan .. good:sub(5), 1) end },
    search_number = { true, function() corpus:search(5, 1) end },
    search_ok = { false, function() corpus:search(good, 1) end },
    search_big_k = { false, function() corpus:search(good, math.maxinteger) end },
    search_everything = { false, function() corpus:search(good, 3, { metric = "cosine", candidates = 1, allow = { 7, -3 } }) end },
    search_allow_empty = { false, function()
      assert(#assert(corpus:search(good, 3, { allow = {} })).ids == 0)
    end },
    search_allow_whole_float = { false, function() corpus:search(good, 1, { allow = { 7.0 } }) end },
    corpus_dims0 = { true, function() Vector.corpus(0) end },
    corpus_dims_neg = { true, function() Vector.corpus(-1) end },
    corpus_dims_big = { true, function() Vector.corpus(16001) end },
    corpus_dims_float = { true, function() Vector.corpus(1.5) end },
    corpus_dims_nil = { true, function() Vector.corpus(nil) end },
    corpus_dims_max = { false, function() Vector.corpus(16000) end },
    kmeans_k0 = { true, function() Vector.kmeans(corpus, 0) end },
    kmeans_k_big = { true, function() Vector.kmeans(corpus, corpus:count() + 1) end },
    kmeans_iterations0 = { true, function() Vector.kmeans(corpus, 1, { iterations = 0 }) end },
    kmeans_ok = { false, function() Vector.kmeans(corpus, 1) end },
    method_on_nothing = { true, function() corpus.search(nil, good, 1) end },
    method_on_table = { true, function() corpus.add({}, 1, good) end },
  }
  for i, op in ipairs(ops) do
    local case = cases[op]
    if case == nil then return "no case " .. tostring(op) end
    local ok, why = pcall(case[2])
    if ok == case[1] then
      return op .. (ok and " should have raised" or " raised: " .. tostring(why))
    end
    if ok and op == "add_ok" then count = count + 1 end
    if ok and op == "add_ok_again" then count = count + 1 end
    if corpus:count() ~= count then
      return op .. " left a count of " .. corpus:count() .. ", not " .. count
    end
  end
  local hits = assert(corpus:search(good, 1))
  if #hits.ids ~= 1 then return "a search after the refusals answered " .. #hits.ids end
  return "ok"
]]

local run_refusals = assert(load(REFUSAL_CHUNK, "=vector_fuzz_refusals", "t"))

local REFUSAL_OPS <const>: {string} = { "add_short", "add_long", "add_nan", "add_inf", "add_float_id",
  "add_string_id", "add_table", "add_nil", "add_ok", "add_ok_again", "search_k0", "search_kneg",
  "search_kfloat", "search_kstring", "search_knil", "search_metric", "search_metric_number",
  "search_cand0", "search_candneg", "search_candfloat", "search_allow_word", "search_allow_float",
  "search_allow_table", "search_allow_number", "search_short", "search_nan", "search_number",
  "search_ok", "search_big_k", "search_everything", "search_allow_empty", "search_allow_whole_float",
  "corpus_dims0", "corpus_dims_neg", "corpus_dims_big", "corpus_dims_float", "corpus_dims_nil",
  "corpus_dims_max", "kmeans_k0", "kmeans_k_big", "kmeans_iterations0", "kmeans_ok",
  "method_on_nothing", "method_on_table" }

local function gen_refusals_input(src: Fuzz.Source): string
  local fields: mut {string} = { tostring(Fuzz.pick(src, { 1, 1, 2, 3, 9, 17 })) }
  while Fuzz.more(src, #fields - 1, 14) do
    fields[#fields + 1] = Fuzz.pick(src, REFUSAL_OPS)
  end
  return Fuzz.pack(fields)
end

local function check_refusals(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local dims = to_int(assert(fields[1]))
  local ops: mut {string} = {}
  for at = 2, #fields do ops[#ops + 1] = assert(fields[at]) end
  local answer = run_refusals(dims, ops)
  if not (answer is string) then return false, "the chunk answered oddly" end
  if answer ~= "ok" then return false, ("dims %d, %s: %s"):format(dims, table.concat(ops, " "), answer) end
  Fuzz.label("refused")
  return true, ""
end

local function test_a_corpus_refuses_what_is_not_a_vector_or_a_request(tmp: string)
  Fuzz.run({
    name = "corpus refusals",
    dir = tmp,
    gen = gen_refusals_input,
    check = check_refusals,
    requires = { "refused" },
  })
end

--------------------------------------------------------------------------
-- Vector.nearest and Vector.nearest_n
--------------------------------------------------------------------------

--- Calls the centroid search on a list built from kinds: `s` a string, or
--- a thing that is no vector.
local NEAREST_CHUNK <const> = [[
  local Vector = require("cosmic.vector")
  local kinds, blobs, v, n = ...
  local list = {}
  for i = 1, #kinds do
    local kind = kinds[i]
    if kind == "s" then list[i] = blobs[i]
    elseif kind == "num" then list[i] = 1.5
    elseif kind == "tbl" then list[i] = {}
    else list[i] = true end
  end
  local ok, many = pcall(Vector.nearest_n, list, v, n)
  local one_ok, one = pcall(Vector.nearest, list, v)
  if ok then many = table.concat(many, ",") else many = tostring(many) end
  if not one_ok then one = -1 end
  return ok, many, one_ok, one
]]

local run_nearest = assert(load(NEAREST_CHUNK, "=vector_fuzz_nearest", "t"))

local function gen_nearest_input(src: Fuzz.Source): string
  local kind = src:int(0, 4)
  if kind == 3 then kind = 0 end
  local letters = alphabet(kind)
  local dims = Fuzz.pick(src, { 1, 1, 2, 3, 5 })
  local hostile = src:int(0, 2) == 0
  local kinds: mut {string} = {}
  local blobs: mut {string} = {}
  while Fuzz.more(src, #kinds, 8) do
    local r = 99
    if hostile then r = src:int(0, 15) end
    if r == 0 then
      kinds[#kinds + 1] = Fuzz.pick(src, { "num", "tbl", "bool" })
      blobs[#blobs + 1] = ""
    else
      kinds[#kinds + 1] = "s"
      if r == 1 then
        blobs[#blobs + 1] = blob_of(gen_numbers(src, letters, Fuzz.pick(src, { 0, dims + 1, 2 * dims })))
      elseif r == 2 then
        blobs[#blobs + 1] = gen_chunks(src, true, false, dims)
      elseif r == 3 then
        blobs[#blobs + 1] = blob_of(gen_numbers(src, letters, dims)):sub(1, 4 * dims - 1)
      else
        blobs[#blobs + 1] = blob_of(gen_numbers(src, letters, dims))
      end
    end
  end
  local query = blob_of(gen_numbers(src, letters, dims))
  if hostile and src:int(0, 4) == 0 then
    query = Fuzz.pick(src, { "", "abc", gen_chunks(src, true, false, dims), query .. "x" })
  end
  local n = Fuzz.pick(src, { 1, 1, 2, 3, 5, 100, 0, -1 })
  return Fuzz.pack({ table.concat(kinds, ","), Fuzz.pack(blobs), query, tostring(n) })
end

local function check_nearest(input: string): boolean, string
  local fields = Fuzz.unpack(input)
  local kinds_text = assert(fields[1])
  local kinds = split(kinds_text, ",")
  if kinds_text == "" then kinds = {} end
  local blobs = Fuzz.unpack(assert(fields[2]))
  local query = assert(fields[3])
  local n = to_int(assert(fields[4]))
  local refuses = #kinds == 0 or #query == 0 or #query % 4 ~= 0 or not all_finite(floats_of(query))
  for i, kind in ipairs(kinds) do
    local blob = assert(blobs[i])
    if kind ~= "s" or #blob ~= #query or not all_finite(floats_of(blob)) then refuses = true end
  end
  local ok, many, one_ok, one = run_nearest(kinds, blobs, query, n)
  if not (ok is boolean and many is string and one_ok is boolean and one is integer) then
    return false, "the chunk answered oddly"
  end
  if ok == (refuses or n < 1) or one_ok == refuses then
    return false, ("nearest_n %s and nearest %s with %d centroids (%s), n=%d: %s"):format(
      if ok then "took it" else "refused" end, if one_ok then "took it" else "refused" end, #kinds, kinds_text, n, many)
  end
  if refuses or n < 1 then
    Fuzz.label("refused")
    return true, ""
  end
  local q = floats_of(query)
  local pool: mut {Scored} = {}
  local overflow = false
  for i = 1, #kinds do
    local centroid = floats_of(assert(blobs[i]))
    local sim = dot_of(centroid, q)
    -- A product past a float's range is the only way to a sum that differs.
    if math.abs(sim) > 1e30 or not ordinary(centroid) then overflow = true end
    pool[#pool + 1] = { id = i, key = sim, row = i }
  end
  local order = ranked(pool)
  local want: mut {string} = {}
  for i = 1, math.min(n, #order) do want[#want + 1] = tostring(assert(order[i]).id) end
  if overflow then
    -- Scores that overflow in float have no reference here: the answer must
    -- still be distinct indexes of centroids. They await the TODO at the
    -- score loop in core/vector.c (the corpus kernels sum in float).
    local seen: mut {integer: boolean} = {}
    local count = 0
    for token in many:gmatch("[^,]+") do
      local at = to_int(token)
      if seen[at] == true or at < 1 or at > #kinds then return false, "nearest_n answered " .. many end
      seen[at] = true
      count = count + 1
    end
    if count ~= math.min(n, #kinds) then return false, "nearest_n answered " .. many end
    Fuzz.label("overflowing")
    return true, ""
  end
  if many ~= table.concat(want, ",") then
    return false, ("nearest_n answered %s, not %s, for %d centroids and n=%d"):format(many,
      table.concat(want, ","), #kinds, n)
  end
  if one ~= assert(order[1]).id then
    return false, ("nearest answered %d, not %d"):format(one, assert(order[1]).id)
  end
  Fuzz.label("ranked")
  if #order > 1 and assert(order[1]).key == assert(order[2]).key then Fuzz.label("tie") end
  return true, ""
end

local function test_nearest_matches_a_reference_and_refuses_hostile_lists(tmp: string)
  Fuzz.run({
    name = "vector nearest",
    dir = tmp,
    gen = gen_nearest_input,
    check = check_nearest,
    requires = { "ranked", "tie", "refused", "overflowing" },
    shares = { ranked = 0.1, refused = 0.1 },
  })
end
