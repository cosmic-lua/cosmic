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

local function test_tables_used_and_bytecode_read_a_statement_without_running_it()
  local handle = assert(Sqlite.memory())
  assert(handle:exec("CREATE TABLE t (a); CREATE TABLE u (b); CREATE INDEX ub ON u (b)"))
  local rows = assert(Sqlite.text_rows(handle,
    "SELECT type, name, wr FROM tables_used('INSERT INTO t SELECT b FROM u WHERE b > 1') " ..
      "ORDER BY name"))
  local got: {string} = {}
  for _, r in ipairs(rows) do got[#got + 1] = table.concat(r, " ") end
  -- The index covers the query, so SQLite reads it in place of u.
  assert(table.concat(got, ", ") == "table t 1, index ub 0", table.concat(got, ", "))
  assert(handle:exec("INSERT INTO t VALUES (1)"))
  rows = assert(Sqlite.text_rows(handle,
    "SELECT opcode FROM bytecode('DELETE FROM t') WHERE addr = 0"))
  assert(rows[1][1] == "Init", rows[1][1])
  rows = assert(Sqlite.text_rows(handle, "SELECT count(*) FROM t"))
  assert(rows[1][1] == "1", "compiling a statement must not run it")
  handle:close()
end

local function test_bytecode_and_tables_used_refuse_a_view_and_a_trigger()
  local handle = assert(Sqlite.memory())
  assert(handle:exec("CREATE TABLE t (a); " ..
      "CREATE VIEW v AS SELECT count(*) FROM bytecode('PRAGMA query_only = 1'); " ..
      "CREATE VIEW w AS SELECT count(*) FROM tables_used('SELECT * FROM t'); " ..
      "CREATE TRIGGER tr AFTER INSERT ON t BEGIN " ..
      "SELECT count(*) FROM bytecode('PRAGMA query_only = 1'); END"))
  for _, sql in ipairs({ "SELECT * FROM v", "SELECT * FROM w", "INSERT INTO t VALUES (1)" }) do
    local ok, trouble = handle:exec(sql)
    assert(not ok, sql .. " must be refused")
    assert(trouble:find("unsafe use of virtual table", 1, true) ~= nil, trouble)
  end
  local rows = assert(Sqlite.text_rows(handle, "PRAGMA query_only"))
  assert(rows[1][1] == "0", "a view or trigger set query_only")
  handle:close()
end

local function test_a_database_s_own_schema_is_not_trusted()
  local handle = assert(Sqlite.memory())
  local rows = assert(Sqlite.text_rows(handle, "PRAGMA trusted_schema"))
  assert(rows[1][1] == "0", "trusted_schema must be off")
  assert(handle:exec([[CREATE TABLE todos (id INTEGER PRIMARY KEY, text TEXT);
    CREATE VIRTUAL TABLE todos_fts USING fts5(text, content=todos, content_rowid=id);
    CREATE TRIGGER todos_inserted AFTER INSERT ON todos BEGIN
      INSERT INTO todos_fts (rowid, text) VALUES (new.id, new.text); END;
    CREATE TRIGGER todos_updated AFTER UPDATE ON todos BEGIN
      INSERT INTO todos_fts (todos_fts, rowid, text) VALUES ('delete', old.id, old.text);
      INSERT INTO todos_fts (rowid, text) VALUES (new.id, new.text); END;
    CREATE TRIGGER todos_deleted AFTER DELETE ON todos BEGIN
      INSERT INTO todos_fts (todos_fts, rowid, text) VALUES ('delete', old.id, old.text); END;
    CREATE VIEW plain AS SELECT upper(substr(text, 1, 3)) AS head FROM todos;
    CREATE VIEW pragmas AS SELECT count(*) FROM pragma_table_info('todos');
    CREATE VIEW middle AS SELECT median(id) FROM todos;]]))
  -- A trigger still writes to an FTS5 table, as build/work.tl's do, and a
  -- view still uses the built-in functions.
  assert(handle:exec("INSERT INTO todos (text) VALUES ('fix the thing')"))
  rows = assert(Sqlite.text_rows(handle,
    "SELECT rowid FROM todos_fts WHERE todos_fts MATCH 'thing'"))
  assert(rows[1][1] == "1", "the insert trigger must have indexed the row")
  assert(handle:exec("UPDATE todos SET text = 'mend the other'"))
  rows = assert(Sqlite.text_rows(handle, "SELECT " ..
      "(SELECT count(*) FROM todos_fts WHERE todos_fts MATCH 'thing'), " ..
      "(SELECT count(*) FROM todos_fts WHERE todos_fts MATCH 'other')"))
  assert(rows[1][1] == "0" and rows[1][2] == "1", "the update trigger must have reindexed the row")
  assert(handle:exec("DELETE FROM todos; INSERT INTO todos (text) VALUES ('fix the thing')"))
  rows = assert(Sqlite.text_rows(handle, "SELECT * FROM plain"))
  assert(rows[1][1] == "FIX", rows[1][1])
  -- A pragma_* table and a function SQLite does not mark innocuous are
  -- refused from a view.
  local _, why = Sqlite.text_rows(handle, "SELECT * FROM pragmas")
  assert(why:find("unsafe use of virtual table", 1, true) ~= nil, why)
  _, why = Sqlite.text_rows(handle, "SELECT * FROM middle")
  assert(why:find("unsafe use of median()", 1, true) ~= nil, why)
  -- The caller's own SQL may use both.
  rows = assert(Sqlite.text_rows(handle, "SELECT count(*) FROM pragma_table_info('todos')"))
  assert(rows[1][1] == "2", rows[1][1])
  handle:close()
end

local function test_rtree_finds_the_boxes_a_box_overlaps()
  local handle = assert(Sqlite.memory())
  assert(handle:exec([[CREATE VIRTUAL TABLE boxes USING rtree(id, x0, x1, y0, y1);
    INSERT INTO boxes VALUES (1, 0, 10, 0, 10), (2, 5, 15, 5, 15), (3, 20, 30, 20, 30);
    CREATE VIRTUAL TABLE spans USING rtree_i32(id, start, stop);
    INSERT INTO spans VALUES (1, 100, 200), (2, 150, 300);]]))
  local rows = assert(Sqlite.text_rows(handle, "SELECT group_concat(id) FROM " ..
      "(SELECT id FROM boxes WHERE x1 >= 8 AND x0 <= 12 AND y1 >= 8 AND y0 <= 12 ORDER BY id)"))
  assert(rows[1][1] == "1,2", rows[1][1])
  rows = assert(Sqlite.text_rows(handle, "SELECT group_concat(id) FROM " ..
      "(SELECT id FROM spans WHERE start <= 250 AND stop >= 250 ORDER BY id)"))
  assert(rows[1][1] == "2", rows[1][1])
  -- A coordinate a 32-bit real cannot hold is rounded outward.
  assert(handle:exec("INSERT INTO boxes VALUES (4, 0.1, 0.1, 0.1, 0.1)"))
  rows = assert(Sqlite.text_rows(handle,
    "SELECT x0 <= 0.1, x1 >= 0.1, x0 < x1 FROM boxes WHERE id = 4"))
  assert(table.concat(rows[1], " ") == "1 1 1", table.concat(rows[1], " "))
  rows = assert(Sqlite.text_rows(handle, "SELECT rtreecheck('boxes'), rtreecheck('spans')"))
  assert(rows[1][1] == "ok" and rows[1][2] == "ok", rows[1][1] .. " " .. rows[1][2])
  handle:close()
end

local function test_rtree_checks_a_lying_depth_in_bounded_time()
  local handle = assert(Sqlite.memory())
  assert(handle:exec("CREATE VIRTUAL TABLE b USING rtree_i32(id, x0, x1, y0, y1)"))
  for i = 1, 60 do
    assert(Sqlite.run(handle, "INSERT INTO b VALUES (?1, ?1, ?1 + 1, ?1, ?1 + 1)", { { integer = i } }))
  end
  -- A root whose depth header claims 40 levels sends the walk from leaf
  -- rowids back to node 1, doubling the work at each level.
  assert(Sqlite.run(handle, "UPDATE b_node SET data = ?1 || substr(data, length(?1) + 1) " ..
      "WHERE nodeno = 1", { { blob = string.pack(">I2", 40) } }))
  for _, sql in ipairs({ "SELECT rtreecheck('b')", "PRAGMA integrity_check" }) do
    local rows = assert(Sqlite.text_rows(handle, sql))
    local report = table.concat(rows[1], " ")
    assert(report:find("Nodes are reached more often than the 3 the table holds", 1, true) ~= nil,
      sql .. ": " .. report:sub(1, 200))
  end
  handle:close()
end
