--- The SQL functions the core's SQLite is built with beyond its
--- defaults: each must be callable from a fresh connection, with no
--- loading step.

local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

Test.policy{ profiles = { "cosmic" } }

--- The one row `sql` yields, each value as SQLite's text.
local function row(sql: string): {string}
  local handle = assert(Sqlite.memory())
  local rows, trouble = Sqlite.text_rows(handle, sql)
  handle:close()
  assert(rows ~= nil, trouble)
  assert(#rows == 1, sql .. ": expected one row, got " .. #rows)
  return rows[1]
end

local function test_math_functions_are_built_in()
  local got = row("SELECT sqrt(16), pow(2, 10), floor(-1.5), ceil(1.2), " ..
      "ln(1), log10(1000), log2(8), round(pi(), 5), mod(7, 3), trunc(-2.7), acosh(1), " ..
      "sqrt(-1) IS NULL, ln(0) IS NULL")
  local want = { "4.0", "1024.0", "-2.0", "2.0", "0.0", "3.0", "3.0", "3.14159", "1.0",
    "-2.0", "0.0", "1", "1" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end

local function test_percentile_aggregates_are_built_in()
  local values = "(SELECT 1 AS x UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 10)"
  local got = row("SELECT median(x), percentile(x, 50), percentile_cont(x, 0.25), " ..
      "percentile_disc(x, 0.5) FROM " .. values)
  local want = { "2.5", "2.5", "1.75", "2.0" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end

local function test_generate_series_is_built_in()
  local got = row("SELECT group_concat(value) FROM generate_series(1, 9, 4)")
  assert(got[1] == "1,5,9", got[1])
end

local function test_regexp_is_built_in()
  local got = row("SELECT 'abc123' REGEXP '^[a-z]+[0-9]+$', 'abc' REGEXP '\\d'")
  assert(got[1] == "1" and got[2] == "0", got[1] .. " " .. got[2])
end

local function test_decimal_arithmetic_is_exact()
  local got = row("SELECT decimal_add('0.1', '0.2'), decimal_cmp('1.10', '1.1'), " ..
      "decimal_mul('1.5', '-2'), decimal_sum(x) FROM (SELECT '0.1' AS x UNION ALL SELECT '0.2')")
  local want = { "0.3", "0", "-3", "0.3" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end

local function test_uuid_is_built_in()
  local id = "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  local got = row("SELECT length(uuid()), uuid() <> uuid(), " ..
      "uuid_str(uuid_blob('" .. id .. "')), length(uuid_blob('" .. id .. "'))")
  local want = { "36", "1", id, "16" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end

local function test_sha1_and_sha3_answer_their_test_vectors()
  local got = row("SELECT sha1('abc'), hex(sha3('abc')), hex(sha3('abc', 512))")
  assert(got[1] == "a9993e364706816aba3e25717850c26c9cd0d89d", got[1])
  assert(got[2] == "3A985DA74FE225B2045C172D6BD390BD855F086E3E9D525B46BFE24511431532", got[2])
  assert(got[3] == "B751850B1A57168A5693CD924B6B096E08F621827444F70D884F5D0240D2712E" ..
      "10E116E9192AF3C91A7EC57647E3934057340B4CF408D5A56592F8274EEC53F0", got[3])
end

local function test_base64_and_base85_round_trip()
  local got = row("SELECT base64(x'4d616e'), hex(base64(base64(x'00ff10'))), " ..
      "hex(base85(base85(x'00ff10e0'))), is_base85(base85(x'00ff10e0'))")
  assert(got[1]:match("^TWFu%s*$") ~= nil, got[1])
  assert(got[2] == "00FF10", got[2])
  assert(got[3] == "00FF10E0", got[3])
  assert(got[4] == "1", got[4])
end

local function test_compress_round_trips_through_uncompress()
  local got = row("WITH t(x) AS (SELECT replace(printf('%.500c', 'x'), 'x', 'abc')) " ..
      "SELECT CAST(uncompress(compress(x)) AS TEXT) = x, length(compress(x)) < length(x) FROM t")
  assert(got[1] == "1" and got[2] == "1", got[1] .. " " .. got[2])
end

--- compress.c's length prefix: seven bits a byte, most significant
--- first, the last byte's top bit set.
local function length_prefix(n: integer): string
  local bytes: {integer} = {}
  repeat
    table.insert(bytes, 1, n & 0x7f)
    n = n >> 7
  until n == 0
  bytes[#bytes] = bytes[#bytes] | 0x80
  return string.char(table.unpack(bytes))
end

local function test_uncompress_bounds_a_claimed_length_by_deflates_ratio()
  local handle = assert(Sqlite.memory())
  -- Zeros compress about as far as deflate goes, near 1029:1.
  local size = 10000000
  local packed = assert(Sqlite.rows(handle, "SELECT compress(zeroblob(?1))",
    { { integer = size } }))[1][1].blob
  assert(packed ~= nil)
  local prefix = #length_prefix(size)
  local stream = packed:sub(prefix + 1)
  local function read(claim: integer): string
    local rows = assert(Sqlite.text_rows(handle,
      "SELECT ifnull(length(uncompress(?1)), 'NULL')",
      { { blob = length_prefix(claim) .. stream } }))
    return rows[1][1]
  end
  assert(read(size) == tostring(size), "a stream at deflate's ratio must read back")
  assert(read(#stream * 1032) == tostring(size), "a claim at the bound must be read")
  assert(read(#stream * 1032 + 1) == "NULL", "a claim past the bound must be NULL")
  assert(read((1 << 35) - 1) == "NULL", "the largest claim must be NULL, not a failure")
  handle:close()
end

local function test_ieee754_takes_a_double_apart_and_back()
  local got = row("SELECT ieee754(45.25), ieee754_mantissa(45.25), ieee754_exponent(45.25), " ..
      "ieee754(181, -2), hex(ieee754_to_blob(1.0)), ieee754_from_blob(x'3ff0000000000000'), " ..
      "ieee754_to_int(1.0), ieee754_from_int(4607182418800017408), ieee754_inc(1.0, 1) > 1.0")
  local want = { "ieee754(181,-2)", "181", "-2", "45.25", "3FF0000000000000", "1.0",
    "4607182418800017408", "1.0", "1" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end

local function test_tointeger_and_toreal_convert_only_without_loss()
  local got = row("SELECT tointeger('42'), tointeger(3.0), tointeger(3.5) IS NULL, " ..
      "tointeger('x') IS NULL, toreal('2.5'), toreal(7), toreal('x') IS NULL")
  local want = { "42", "3", "1", "1", "2.5", "7.0", "1" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end

local function test_uint_orders_embedded_numbers_by_value()
  local got = row("SELECT group_concat(x, ' ') FROM (SELECT x FROM " ..
      "(SELECT 'file10' AS x UNION ALL SELECT 'file2' UNION ALL SELECT 'file1') " ..
      "ORDER BY x COLLATE uint)")
  assert(got[1] == "file1 file2 file10", got[1])
  assert(row("SELECT 'x00123y' = 'x123y' COLLATE uint")[1] == "1")
end

local function test_toreal_reads_text_as_cast_does_and_refuses_a_loss()
  local got = row("SELECT toreal('1.7976931348623157e308') = CAST('1.7976931348623157e308' AS REAL), " ..
      "toreal('2.2250738585072011e-308') = CAST('2.2250738585072011e-308' AS REAL), " ..
      "toreal('1e400') IS NULL, toreal('1e-400') IS NULL, toreal('0e-400'), " ..
      "toreal('9007199254740993') IS NULL, toreal(9007199254740993) IS NULL, " ..
      "toreal(' 2') IS NULL, toreal(x'3ff0000000000000')")
  local want = { "1", "1", "1", "1", "0.0", "1", "1", "1", "1.0" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end

local function test_tointeger_takes_an_integer_literal_alone()
  local got = row("SELECT tointeger('3.0') IS NULL, tointeger('1.00000000000000001') IS NULL, " ..
      "tointeger(CAST(x'31320078' AS TEXT)) IS NULL, tointeger('9223372036854775808') IS NULL, " ..
      "tointeger('-9223372036854775808'), tointeger('3 ') IS NULL, tointeger(x'0100000000000000')")
  local want = { "1", "1", "1", "1", "-9223372036854775808", "1", "1" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end

local function test_ieee754_answers_zero_and_overflow_at_any_exponent()
  local got = row("SELECT ieee754(0, 1000), ieee754(0, -1074), ieee754(1, 2000), " ..
      "ieee754(3, 2000), ieee754(-3, 2000), ieee754(9007199254740995, 0), " ..
      "ieee754_inc(-1.0, 1) < -1.0, ieee754_inc(0.0, -1) IS NULL")
  local want = { "0.0", "0.0", "Inf", "Inf", "-Inf", "9007199254740994.0", "1", "1" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end

local function test_uint_compares_signs_and_points_as_bytes()
  local got = row("SELECT 'a1.05' = 'a1.5' COLLATE uint, '-5' = '5' COLLATE uint")
  assert(got[1] == "1" and got[2] == "0", got[1] .. " " .. got[2])
end

local function test_totype_holds_the_least_integer()
  local got = row("SELECT tointeger(-9223372036854775808.0), tointeger('-9223372036854775808'), " ..
      "toreal(-9223372036854775808) = -9223372036854775808.0, " ..
      "toreal('-9223372036854775808') = -9223372036854775808.0, tointeger(9223372036854775808.0) IS NULL")
  local want = { "-9223372036854775808", "-9223372036854775808", "1", "1", "1" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end

local function test_ieee754_writes_and_reads_its_edges()
  local got = row("SELECT ieee754(2.0), ieee754(0.0), ieee754(3, 1023), ieee754(5, 1022), " ..
      "ieee754(-9223372036854775808, 0) IS NULL, ieee754('3', 1.9), " ..
      "ieee754_from_blob(x'7ff8000000000000') IS NULL")
  local want = { "ieee754(2,0)", "ieee754(0,-1075)", "Inf", "Inf", "1", "6.0", "1" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end

local function test_ieee754_and_toreal_read_other_values_as_sqlite_does()
  local got = row("SELECT ieee754('12abc'), ieee754(NULL), ieee754_inc(x'3ff0000000000000', 0), " ..
      "toreal('18446744073709551617'), ieee754_to_blob('1.5') IS NULL")
  local want = { "ieee754(12,0)", "ieee754(0,-1075)", "0.0", "1.8446744073709552e+19", "1" }
  for i, value in ipairs(want) do
    assert(got[i] == value, "column " .. i .. ": " .. tostring(got[i]))
  end
end
