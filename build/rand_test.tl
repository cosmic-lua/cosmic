--- `cosmic rand` (build/rand.tl), run in this process with its input,
--- output, clock and entropy stood in for: UUID layout and bits, v7
--- ordering, tokens, integer bounds and fairness, and pick and shuffle,
--- seeded and not. build/rand_tool_test.tl starts the program for what
--- a process alone shows.

local Fs = require("cosmic.fs")
local Rand = require("cosmic.rand")
local rand = require("build.rand")

--- The element of `list` at `index`, which the case knows is there.
local function nth<T>(list: {T}, index: integer): T
  local found = list[index]
  assert(found ~= nil, "the list has an element at " .. tostring(index))
  return found
end

local record Ran
  mut code: integer
  mut out: string
  mut err: string
end

local record Stand
  stdin?: string
  entropy?: function(count: integer): string?, string
  now_ns?: function(): integer
  out?: function(text: string): boolean, string
end

local function run(words: {string}, stand?: Stand): Ran
  local argv: mut {string} = { "rand" }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local given: Stand = stand or {}
  local ran: Ran = { code = -1, out = "", err = "" }
  ran.code = rand.run(argv, {
    out = given.out or function(text: string): boolean, string
      ran.out = ran.out .. text
      return true, ""
    end,
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
    stdin = function(): string?, string
      local stdin = given.stdin
      if stdin == nil then return nil, "no standard input in this test" end
      return stdin, ""
    end,
    entropy = given.entropy or Rand.entropy,
    now_ns = given.now_ns or function(): integer return 1700000000123456789 end,
  })
  return ran
end

local function lines(text: string): {string}
  local out: mut {string} = {}
  for line in text:gmatch("[^\n]+") do out[#out + 1] = line end
  return out
end

local function test_uuid_v4_layout_and_bits()
  local ran = run({ "uuid", "-n", "50" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  local seen: mut {string:boolean} = {}
  for _, id in ipairs(lines(ran.out)) do
    assert(id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"), id)
    assert(id == id:lower(), id)
    seen[id] = true
  end
  assert(#lines(ran.out) == 50)
  local distinct = 0
  for _ in pairs(seen) do distinct = distinct + 1 end
  assert(distinct == 50, "entropy repeated")
  local explicit = run({ "uuid", "--v4" })
  assert(explicit.code == 0 and #lines(explicit.out) == 1)
end

local function test_uuid_v4_is_made_of_entropy_alone()
  -- All bits set: the version and variant bits are forced, the rest kept.
  local ran = run({ "uuid" }, { entropy = function(count: integer): string?, string
    return string.rep("\255", count), ""
  end })
  assert(ran.out == "ffffffff-ffff-4fff-bfff-ffffffffffff\n", ran.out)
  local zero = run({ "uuid" }, { entropy = function(count: integer): string?, string
    return string.rep("\0", count), ""
  end })
  assert(zero.out == "00000000-0000-4000-8000-000000000000\n", zero.out)
end

local function test_uuid_v7_layout_and_bits()
  -- 1700000000123 ms, 456789 ns into it: 456789 * 4096 // 1e6 = 1871.
  local ran = run({ "uuid", "--v7" }, { entropy = function(count: integer): string?, string
    return string.rep("\255", count), ""
  end })
  assert(ran.code == 0, ran.err)
  local head = ("%012x"):format(1700000000123)
  local want = head:sub(1, 8) .. "-" .. head:sub(9, 12) .. "-7" .. ("%03x"):format(1871) .. "-bfff-ffffffffffff\n"
  assert(ran.out == want, ran.out .. want)
  local real = run({ "uuid", "--v7", "-n", "20" })
  for _, id in ipairs(lines(real.out)) do
    assert(id:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-7%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"), id)
  end
end

local function test_uuid_v7_sorts_as_drawn_within_one_millisecond()
  -- A frozen clock, then one that steps back: every value still sorts
  -- after the one before.
  local ticks = { 5000000000, 5000000000, 5000000000, 4999000000, 5000000001 }
  local at = { value = 0 }
  local ran = run({ "uuid", "--v7", "-n", "300" }, { now_ns = function(): integer
    at.value = at.value + 1
    return ticks[at.value] or 5000000001
  end })
  local ids = lines(ran.out)
  assert(#ids == 300)
  for index = 2, #ids do
    assert(nth(ids, index - 1) < nth(ids, index), nth(ids, index - 1) .. " !< " .. nth(ids, index))
  end
  local real = lines(run({ "uuid", "--v7", "-n", "2000" }).out)
  for index = 2, #real do
    assert(nth(real, index - 1) < nth(real, index), nth(real, index - 1) .. " !< " .. nth(real, index))
  end
end

local function test_token_length_and_alphabet()
  local default = run({ "token" })
  local text = default.out:sub(1, -2)
  assert(default.code == 0 and #text == 43 and text:match("^[A-Za-z0-9_-]+$") ~= nil, text)
  assert(not text:find("=", 1, true))
  local url = run({ "token", "--bytes", "5", "--base64url" }).out:sub(1, -2)
  assert(#url == 7 and url:match("^[A-Za-z0-9_-]+$") ~= nil, url)
  local hex = run({ "token", "--hex", "--bytes", "16" }).out:sub(1, -2)
  assert(#hex == 32 and hex:match("^%x+$") ~= nil and hex == hex:lower(), hex)
  local one = run({ "token", "--bytes", "1" }).out:sub(1, -2)
  assert(#one == 2)
  local biggest = run({ "token", "--bytes", tostring(rand.MAX_BYTES), "--hex" })
  assert(biggest.code == 0 and #biggest.out == rand.MAX_BYTES * 2 + 1)
  assert(run({ "token" }).out ~= run({ "token" }).out)
end

local function test_token_refuses_what_it_cannot_give()
  local cases: {{string}} = {
    { "token", "--bytes", tostring(rand.MAX_BYTES + 1) }, { "token", "--bytes", "0" },
    { "token", "--bytes", "-3" }, { "token", "--bytes", "x" }, { "token", "--hex", "--base64url" },
    { "token", "--seed", "1" }, { "token", "extra" }, { "token", "-n", "2" },
  }
  for _, words in ipairs(cases) do
    local ran = run(words)
    assert(ran.code == 2 and ran.out == "", table.concat(words, " "))
    assert(ran.err:find("cosmic: rand: ", 1, true) == 1, ran.err)
  end
end

local function test_uuid_refuses_a_seed_and_the_rest()
  local seeded = run({ "uuid", "--seed", "1" })
  assert(seeded.code == 2 and seeded.out == "", seeded.out)
  assert(seeded.err:find("--seed is refused with uuid", 1, true), seeded.err)
  local cases: {{string}} = {
    { "uuid", "--v4", "--v7" }, { "uuid", "-n", "0" }, { "uuid", "-n", "x" },
    { "uuid", "-n", tostring(rand.MAX_COUNT + 1) }, { "uuid", "--bytes", "3" }, { "uuid", "x" },
    {}, { "bogus" },
  }
  for _, words in ipairs(cases) do
    local ran = run(words)
    assert(ran.code == 2 and ran.out == "", table.concat(words, " "))
  end
end

local function test_int_stays_in_bounds()
  local same = run({ "int", "7", "7", "-n", "5" })
  assert(same.code == 0 and same.out == "7\n7\n7\n7\n7\n", same.out)
  local negative = run({ "int", "-5", "-2", "-n", "200" })
  assert(negative.code == 0, negative.err)
  for _, line in ipairs(lines(negative.out)) do
    local value = assert(math.tointeger(tonumber(line)))
    assert(value >= -5 and value <= -2, line)
  end
  local across = run({ "int", "-n", "200", "--", "-3", "3" })
  assert(across.code == 0, across.err)
  for _, line in ipairs(lines(across.out)) do
    local value = assert(math.tointeger(tonumber(line)))
    assert(value >= -3 and value <= 3, line)
  end
  local wide = run({ "int", tostring(math.mininteger), tostring(math.maxinteger), "-n", "3" })
  assert(wide.code == 0 and #lines(wide.out) == 3, wide.err)
  local single = run({ "int", "1", "6" })
  assert(single.out:match("^[1-6]\n$"), single.out)
end

local function test_int_refuses_a_bad_range()
  local backwards = run({ "int", "5", "1" })
  assert(backwards.code == 2 and backwards.out == "", backwards.out)
  assert(backwards.err:find("above the high bound", 1, true), backwards.err)
  local cases: {{string}} = {
    { "int" }, { "int", "1" }, { "int", "1", "2", "3" }, { "int", "a", "3" }, { "int", "1.5", "3" },
    { "int", "1", "99999999999999999999" }, { "int", "1", "2", "--hex" },
  }
  for _, words in ipairs(cases) do
    local ran = run(words)
    assert(ran.code == 2 and ran.out == "", table.concat(words, " "))
  end
end

local function test_int_seeded_covers_the_range_evenly_enough()
  local ran = run({ "int", "1", "6", "-n", "600", "--seed", "1" })
  assert(ran.code == 0, ran.err)
  local counts: mut {integer:integer} = {}
  for _, line in ipairs(lines(ran.out)) do
    local value = assert(math.tointeger(tonumber(line)))
    counts[value] = (counts[value] or 0) + 1
  end
  -- A fixed seed draws one fixed sequence, so this cannot flake: every
  -- value turns up, and none is far from the 100 a fair die gives.
  for value = 1, 6 do
    local drawn = counts[value]
    assert(drawn ~= nil and drawn > 60 and drawn < 140, value)
  end
  assert(run({ "int", "1", "6", "-n", "600", "--seed", "1" }).out == ran.out)
  assert(run({ "int", "1", "6", "-n", "600", "--seed", "2" }).out ~= ran.out)
  assert(run({ "int", "1", "6", "-n", "8", "--seed", "7" }).out == "3\n3\n1\n1\n2\n5\n5\n1\n")
end

local function test_int_from_entropy_rejects_rather_than_wraps()
  -- Range 0..2 is masked to two bits: a draw of 3 is outside it and must
  -- be drawn again, not reduced modulo 3 to 0.
  local draws = { 3, 3, 1, 2, 0 }
  local calls = { value = 0 }
  local ran = run({ "int", "0", "2", "-n", "3" }, { entropy = function(count: integer): string?, string
    calls.value = calls.value + 1
    local parts: mut {string} = {}
    for index = 1, count // 8 do
      parts[index] = string.pack("<i8", nth(draws, (index - 1) % 5 + 1))
    end
    return table.concat(parts), ""
  end })
  assert(ran.out == "1\n2\n0\n" and calls.value == 1, ran.out .. calls.value)
end

local function test_int_from_entropy_reaches_every_value_and_no_seed_is_used()
  -- The entropy is a fixed stream, so the count below is fixed too.
  local source = Rand.new(11)
  local ran = run({ "int", "-1", "1", "-n", "300" }, { entropy = function(count: integer): string?, string
    return source:bytes(count), ""
  end })
  local counts: mut {integer:integer} = {}
  for _, line in ipairs(lines(ran.out)) do
    local value = assert(math.tointeger(tonumber(line)))
    counts[value] = (counts[value] or 0) + 1
  end
  for value = -1, 1 do
    local drawn = counts[value]
    assert(drawn ~= nil and drawn > 60, value)
  end
  -- Seeded runs never ask the entropy source.
  local untouched = run({ "int", "1", "9", "--seed", "3" }, { entropy = function(_count: integer): string?, string
    error("a seeded draw read the entropy source")
  end })
  assert(untouched.code == 0, untouched.err)
end

local function test_shuffle_and_pick_are_deterministic_with_a_seed()
  local input = "a\nb\nc\nd\n"
  local shuffled = run({ "shuffle", "--seed", "1" }, { stdin = input })
  assert(shuffled.code == 0 and shuffled.out == "b\nd\nc\na\n", shuffled.out)
  assert(run({ "shuffle", "--seed", "1", "-" }, { stdin = input }).out == shuffled.out)
  local picked = run({ "pick", "-n", "2", "--seed", "1" }, { stdin = input })
  assert(picked.code == 0 and picked.out == "b\nd\n", picked.out)
  local one = run({ "pick", "--seed", "1" }, { stdin = input })
  assert(one.out == "b\n", one.out)
  local all = run({ "pick", "-n", "4", "--seed", "1" }, { stdin = input })
  assert(all.out == shuffled.out, all.out)
end

local function test_shuffle_keeps_every_line_and_visits_every_order()
  local input = "x\ny\nz\n"
  local orders: mut {string:boolean} = {}
  for seed = 1, 60 do
    local ran = run({ "shuffle", "--seed", tostring(seed) }, { stdin = input })
    local got = lines(ran.out)
    table.sort(got)
    assert(table.concat(got) == "xyz", ran.out)
    orders[ran.out] = true
  end
  local count = 0
  for _ in pairs(orders) do count = count + 1 end
  assert(count == 6, "saw " .. tostring(count) .. " of the 6 orders")
  local entropic = run({ "shuffle" }, { stdin = "1\n2\n3\n4\n5\n6\n7\n8\n" })
  local got = lines(entropic.out)
  table.sort(got)
  assert(table.concat(got) == "12345678", entropic.out)
end

local function test_pick_from_entropy_gives_distinct_lines_of_the_input()
  local ran = run({ "pick", "-n", "3" }, { stdin = "a\nb\nc\nd\ne\n" })
  assert(ran.code == 0, ran.err)
  local got = lines(ran.out)
  assert(#got == 3 and got[1] ~= got[2] and got[2] ~= got[3] and got[1] ~= got[3], ran.out)
  for _, line in ipairs(got) do assert(line:match("^[a-e]$"), line) end
end

local function test_pick_asking_for_more_lines_than_there_are_is_refused()
  local ran = run({ "pick", "-n", "5" }, { stdin = "a\nb\n" })
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("cannot pick 5 of 2 lines", 1, true), ran.err)
end

local function test_empty_input()
  local shuffled = run({ "shuffle" }, { stdin = "" })
  assert(shuffled.code == 0 and shuffled.out == "" and shuffled.err == "", shuffled.err)
  local picked = run({ "pick" }, { stdin = "" })
  assert(picked.code == 2 and picked.out == "", picked.out)
  assert(picked.err:find("cannot pick 1 of 0 lines", 1, true), picked.err)
  -- One blank line is a line; a last newline ends a line, it starts none.
  local blank = run({ "shuffle" }, { stdin = "\n" })
  assert(blank.out == "\n", blank.out)
  local plain = run({ "pick", "-n", "3", "--seed", "1" }, { stdin = "a\n\nb" })
  assert(plain.code == 0 and #plain.out == 5, plain.out)
end

local function test_a_file_names_the_lines(tmp: string)
  local path = tmp .. "/lines.txt"
  assert(Fs.write(path, "a\nb\nc\nd\n"))
  local ran = run({ "shuffle", "--seed", "1", path })
  assert(ran.code == 0 and ran.out == "b\nd\nc\na\n", ran.out .. ran.err)
  local missing = run({ "shuffle", tmp .. "/nope.txt" })
  assert(missing.code == 2 and missing.out == "" and missing.err:find("cosmic: rand: ", 1, true) == 1)
  local unreadable = run({ "pick" })
  assert(unreadable.code == 2 and unreadable.err:find("no standard input", 1, true) ~= nil, unreadable.err)
  local two = run({ "shuffle", path, path })
  assert(two.code == 2, two.err)
end

local function test_a_failed_write_to_standard_output_is_exit_2()
  local function refuse(): Stand
    return { out = function(_text: string): boolean, string
      return false, "No space left on device"
    end }
  end
  local cases: {{string}} = {
    { "uuid" }, { "token" }, { "int", "1", "9" }, { "uuid", "--v7", "-n", "20000" },
  }
  for _, words in ipairs(cases) do
    local ran = run(words, refuse())
    assert(ran.code == 2, table.concat(words, " "))
    assert(ran.err == "cosmic: rand: standard output: No space left on device\n", ran.err)
  end
  local stand = refuse()
  stand.stdin = "a\nb\n"
  local shuffled = run({ "shuffle" }, stand)
  assert(shuffled.code == 2 and shuffled.err:find("standard output", 1, true) ~= nil, shuffled.err)
end

local function test_a_failing_entropy_source_is_exit_1_and_says_so()
  local ran = run({ "uuid" }, { entropy = function(_count: integer): string?, string
    return nil, "rand: entropy: no source"
  end })
  assert(ran.code == 1 and ran.out == "", ran.out)
  assert(ran.err:find("entropy source failed: rand: entropy: no source", 1, true), ran.err)
end

local function test_options_belong_to_their_subcommands()
  local cases: {{string}} = {
    { "pick", "--seed", "x" }, { "shuffle", "-n", "2" }, { "int", "1", "2", "--bogus" },
    { "pick", "-n", "0" }, { "shuffle", "--seed", "1.5" },
  }
  for _, words in ipairs(cases) do
    local ran = run(words, { stdin = "a\n" })
    assert(ran.code == 2 and ran.out == "", table.concat(words, " "))
  end
end

local function test_v7_counter_carries_into_the_milliseconds_at_4095()
  -- 4095/4096 of a millisecond in: fraction 4095. The next draw at the
  -- same instant would be fraction 4096, which carries into the ms.
  local ns = 7000000000 + 999756
  local ran = run({ "uuid", "--v7", "-n", "3" }, { now_ns = function(): integer return ns end,
    entropy = function(count: integer): string?, string return string.rep("\0", count), "" end })
  local ids = lines(ran.out)
  local ms = ("%012x"):format(7000)
  local next_ms = ("%012x"):format(7001)
  assert(ids[1] == ms:sub(1, 8) .. "-" .. ms:sub(9, 12) .. "-7fff-8000-000000000000", ids[1])
  assert(ids[2] == next_ms:sub(1, 8) .. "-" .. next_ms:sub(9, 12) .. "-7000-8000-000000000000", ids[2])
  assert(ids[3] == next_ms:sub(1, 8) .. "-" .. next_ms:sub(9, 12) .. "-7001-8000-000000000000", ids[3])
end

local function test_a_negative_count_is_refused_and_a_negative_bound_is_a_bound()
  local ran = run({ "uuid", "-n", "-5" })
  assert(ran.code == 2 and ran.out == "", ran.out)
  assert(ran.err:find("-n needs a whole number", 1, true), ran.err)
  local bound = run({ "int", "-n", "2", "-4", "-4" })
  assert(bound.code == 0 and bound.out == "-4\n-4\n", bound.out .. bound.err)
  -- Only int reads a word that begins with `-` as a number, not an option.
  local other = run({ "shuffle", "-5" }, { stdin = "a\n" })
  assert(other.code == 2, other.err)
end

local function test_crlf_input_reads_as_lf()
  local crlf = run({ "shuffle", "--seed", "1" }, { stdin = "a\r\nb\r\nc\r\nd\r\n" })
  assert(crlf.code == 0 and crlf.out == "b\nd\nc\na\n", crlf.out)
  local blank = run({ "shuffle" }, { stdin = "\r\n" })
  assert(blank.out == "\n", blank.out)
end

--- The entropy stand-in that hands out `Rand.new(seed)`'s words in
--- order, so a source made from the same seed draws what a run does.
local function entropy_of(seed: integer, reads?: mut {integer}): function(count: integer): string?, string
  local source = Rand.new(seed)
  return function(count: integer): string?, string
    if reads ~= nil then reads[#reads + 1] = count end
    return source:bytes(count), ""
  end
end

local function g17(value: number): string
  return ("%.17g"):format(value)
end

local function test_normal_seeded_replays_the_source_draw_for_draw()
  local ran = run({ "normal", "-n", "40", "--seed", "4" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  local source = Rand.new(4)
  local got = lines(ran.out)
  assert(#got == 40)
  for index, line in ipairs(got) do
    local want = source:normal(0.0, 1.0)
    assert(line == g17(want), line .. " vs " .. g17(want) .. " at " .. tostring(index))
    assert(tonumber(line) == want, "does not read back: " .. line)
  end
  assert(run({ "normal", "-n", "40", "--seed", "4" }).out == ran.out)
  assert(run({ "normal", "-n", "40", "--seed", "5" }).out ~= ran.out)
  local shifted = run({ "normal", "-n", "10", "--seed", "4", "--mean", "-5", "--stddev", "2.5" })
  source = Rand.new(4)
  for _, line in ipairs(lines(shifted.out)) do
    assert(line == g17(source:normal(-5.0, 2.5)), line)
  end
  local exact = run({ "normal", "--stddev", "0", "--mean", "1e-3", "--seed", "1" })
  assert(exact.out == g17(0.001) .. "\n", exact.out)
  local single = run({ "normal", "--seed", "4" })
  assert(single.out == g17(Rand.new(4):normal()) .. "\n", single.out)
end

local function test_gamma_seeded_replays_the_source_draw_for_draw()
  for _, case in ipairs({ { "0.5", "1" }, { "3", "2.5" }, { "1", "1e2" } }) do
    local shape, scale = nth(case, 1), nth(case, 2)
    local ran = run({ "gamma", "-n", "30", "--seed", "9", "--shape", shape, "--scale", scale })
    assert(ran.code == 0 and ran.err == "", ran.err)
    local source = Rand.new(9)
    for _, line in ipairs(lines(ran.out)) do
      local want = source:gamma(assert(tonumber(shape)), assert(tonumber(scale)))
      assert(line == g17(want), line .. " vs " .. g17(want))
      assert(tonumber(line) == want, "does not read back: " .. line)
    end
  end
  local default_scale = run({ "gamma", "--shape", "2", "--seed", "3" })
  assert(default_scale.out == g17(Rand.new(3):gamma(2.0, 1.0)) .. "\n", default_scale.out)
end

local function test_normal_and_gamma_from_entropy_use_its_words_as_they_come()
  do
    local reads: mut {integer} = {}
    local ran = run({ "normal", "-n", "25", "--mean", "-5", "--stddev", "2" },
      { entropy = entropy_of(11, reads) })
    assert(ran.code == 0 and ran.err == "", ran.err)
    -- Entropy is read once, in a block, and its words go to the samplers
    -- in order: a generator seeded from entropy would draw other values.
    assert(#reads == 1 and nth(reads, 1) == 8192, table.concat(reads, ","))
    local twin = Rand.new(11)
    for _, line in ipairs(lines(ran.out)) do
      assert(line == g17(twin:normal(-5.0, 2.0)), line)
    end
    local gamma = run({ "gamma", "-n", "25", "--shape", "0.7", "--scale", "3" },
      { entropy = entropy_of(12) })
    assert(gamma.code == 0 and gamma.err == "", gamma.err)
    twin = Rand.new(12)
    for _, line in ipairs(lines(gamma.out)) do
      assert(line == g17(twin:gamma(0.7, 3.0)), line)
    end
    assert(run({ "normal" }, { entropy = entropy_of(13) }).out ~=
        run({ "normal" }, { entropy = entropy_of(14) }).out)
    -- The real entropy gives different values each time.
    assert(run({ "normal", "-n", "3" }).out ~= run({ "normal", "-n", "3" }).out)
    assert(run({ "gamma", "-n", "3", "--shape", "2" }).out ~= run({ "gamma", "-n", "3", "--shape", "2" }).out)
  end
  -- Seeded runs never ask the entropy source.
  local function forbidden(_count: integer): string?, string
    error("a seeded draw read the entropy source")
  end
  assert(run({ "normal", "--seed", "3" }, { entropy = forbidden }).code == 0)
  assert(run({ "gamma", "--shape", "2", "--seed", "3" }, { entropy = forbidden }).code == 0)
end

local function test_normal_and_gamma_are_distributed_as_asked()
  -- A fixed entropy stream, so these cannot flake.
  local n = 4000
  local ran = run({ "normal", "-n", tostring(n), "--mean", "10", "--stddev", "3" },
    { entropy = entropy_of(21) })
  local sum, sq = 0.0, 0.0
  for _, line in ipairs(lines(ran.out)) do
    local x = assert(tonumber(line))
    sum, sq = sum + x, sq + x * x
  end
  local mean = sum / n
  local sd = math.sqrt(sq / n - mean * mean)
  assert(math.abs(mean - 10) < 0.3 and math.abs(sd - 3) < 0.25, tostring(mean) .. " " .. tostring(sd))
  local gamma = run({ "gamma", "-n", tostring(n), "--shape", "2", "--scale", "3" },
    { entropy = entropy_of(22) })
  sum = 0.0
  for _, line in ipairs(lines(gamma.out)) do
    local x = assert(tonumber(line))
    assert(x > 0)
    sum = sum + x
  end
  assert(math.abs(sum / n - 6) < 0.4, sum / n)
end

local function test_normal_and_gamma_refuse_bad_parameters()
  local cases: {{string}} = {
    { "normal", "--mean", "x" }, { "normal", "--mean", "inf" }, { "normal", "--mean", "nan" },
    { "normal", "--mean", "-inf" }, { "normal", "--mean", "1e999" }, { "normal", "--mean", "0x10" },
    { "normal", "--mean", "" }, { "normal", "--mean", "1.2.3" }, { "normal", "--mean" },
    { "normal", "--stddev", "-1" }, { "normal", "--stddev", "-0.5" }, { "normal", "--stddev", "inf" },
    { "normal", "--shape", "2" }, { "normal", "--scale", "2" }, { "normal", "5" },
    { "gamma" }, { "gamma", "--scale", "2" }, { "gamma", "--shape", "0" },
    { "gamma", "--shape", "-1" }, { "gamma", "--shape", "inf" }, { "gamma", "--shape", "nan" },
    { "gamma", "--shape", "1", "--scale", "0" }, { "gamma", "--shape", "1", "--scale", "-2" },
    { "gamma", "--shape", "1", "--scale", "1e999" }, { "gamma", "--shape", "1", "--mean", "1" },
    { "gamma", "--shape", "1", "--stddev", "1" }, { "gamma", "--shape", "1", "x" },
    { "gamma", "--shape", "1", "--hex" },
  }
  for _, words in ipairs(cases) do
    local ran = run(words, { entropy = function(_count: integer): string?, string
      error("a refused command line read the entropy source")
    end })
    assert(ran.code == 2 and ran.out == "", table.concat(words, " "))
    assert(ran.err:find("cosmic: rand: ", 1, true) == 1, ran.err)
  end
  local ran = run({ "normal", "--stddev", "-1" })
  assert(ran.err:find("--stddev must not be negative, not -1", 1, true), ran.err)
  ran = run({ "gamma" })
  assert(ran.err:find("gamma needs --shape", 1, true), ran.err)
  ran = run({ "gamma", "--shape", "nan" })
  assert(ran.err:find("--shape needs a finite number, not nan", 1, true), ran.err)
  -- Every refusal names the subcommands.
  assert(ran.err:find("normal [-n N]", 1, true) and ran.err:find("gamma [-n N]", 1, true), ran.err)
end

local function test_normal_and_gamma_take_negative_and_decimal_numbers_as_values()
  local cases: {{string}} = {
    { "normal", "--mean", "-5" }, { "normal", "--mean", "-5.5e1", "--stddev", "+.5" },
    { "normal", "--mean", "5.", "--stddev", "1E2" }, { "gamma", "--shape", ".5", "--scale", "2e-3" },
  }
  for _, words in ipairs(cases) do
    local ran = run(words, { entropy = entropy_of(2) })
    assert(ran.code == 0 and ran.err == "" and #lines(ran.out) == 1, table.concat(words, " ") .. ran.err)
  end
  local ran = run({ "normal", "--mean", "-5", "--stddev", "0" })
  assert(ran.out == "-5\n", ran.out)
end

local function test_normal_and_gamma_count_is_bounded_like_int()
  for _, command in ipairs({ "normal", "gamma" }) do
    local base: {string} = if command == "gamma" then { "gamma", "--shape", "2" } else { "normal" } end
    local function with(count: string): {string}
      local words: mut {string} = {}
      for _, word in ipairs(base) do words[#words + 1] = word end
      words[#words + 1] = "-n"
      words[#words + 1] = count
      return words
    end
    local three = run(with("3"), { entropy = entropy_of(1) })
    assert(three.code == 0 and #lines(three.out) == 3, three.out)
    for _, bad in ipairs({ "0", "-1", "x", "1.5", tostring(rand.MAX_COUNT + 1) }) do
      local ran = run(with(bad))
      assert(ran.code == 2 and ran.out == "", command .. " -n " .. bad)
      assert(ran.err:find("-n needs a whole number from 1 to", 1, true), ran.err)
    end
  end
  -- The most is allowed to parse; a failed write ends the run early.
  local stopped = run({ "normal", "-n", tostring(rand.MAX_COUNT) }, { entropy = entropy_of(1),
    out = function(_text: string): boolean, string return false, "closed" end })
  assert(stopped.code == 2, stopped.err)
  assert(stopped.err:find("standard output: closed", 1, true), stopped.err)
end

local function test_normal_and_gamma_report_an_entropy_failure_and_a_failed_write()
  local broken = function(_count: integer): string?, string
    return nil, "rand: entropy: no source"
  end
  local commands: {{string}} = { { "normal" }, { "gamma", "--shape", "3" } }
  for _, words in ipairs(commands) do
    local ran = run(words, { entropy = broken })
    assert(ran.code == 1 and ran.out == "", table.concat(words, " "))
    assert(ran.err:find("entropy source failed: rand: entropy: no source", 1, true), ran.err)
    local refused = run(words, { out = function(_text: string): boolean, string
      return false, "No space left on device"
    end })
    assert(refused.code == 2, table.concat(words, " "))
    assert(refused.err == "cosmic: rand: standard output: No space left on device\n", refused.err)
  end
end

local function test_a_seed_is_still_a_whole_number_for_normal_and_gamma()
  assert(run({ "normal", "--seed", "1.5" }).code == 2)
  assert(run({ "gamma", "--shape", "1", "--seed", "x" }).code == 2)
  assert(run({ "normal", "--seed", "-3" }).code == 0)
end
