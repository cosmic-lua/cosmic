--- Fuzz properties for the SQL vector functions (core/vector.c): the
--- text a vector is read from, and every SQL function over arbitrary
--- blobs. Each is total -- an answer or a refusal, never a crash -- and
--- each answer is held to a reference written here in Teal, over the
--- bytes. `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).
---
--- The references use numbers a float holds exactly (small integers and
--- quarters) wherever an answer is compared for equality, so a mismatch
--- is a wrong answer and not a different rounding; sums of other numbers
--- are compared within a tolerance.

local Fuzz = require("build.fuzz")
local Sqlite = require("cosmic.sqlite")

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
  if blob.kind ~= "error" and blob.kind ~= "blob" then
    return false, "vector() answered " .. blob.kind
  end
  if (blob.kind == "blob") ~= (as_text.kind == "text") or (blob.kind == "blob") ~= (dims.kind == "integer") then
    return false, ("vector %s, vector_text %s, vector_dims %s of %q"):format(
      blob.kind, as_text.kind, dims.kind, text)
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
    Fuzz.label("refused")
    return true, ""
  end
  Fuzz.label("read")
  if text:find("[xX]") then Fuzz.label("hex") end
  if text:find("[eE]") then Fuzz.label("exponent") end
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
