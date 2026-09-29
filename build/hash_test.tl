--- `cosmic hash` (build/hash.tl), run in this process with its standard
--- input and output stood in for: each algorithm's digest, standard input,
--- several files, names that need escaping, `--check` and `--quiet`,
--- HMAC (RFC 4231 for SHA-256, and every algorithm against `Hash.hmac`),
--- `--json`, a lost write, and a large input in bounded memory.
--- build/hash_tool_test.tl starts the program for what a process alone
--- shows. The sums-file parser's fuzz properties are in
--- build/hash_sums_fuzz_test.tl.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")
local hash = require("build.hash")

local record Ran
  code: integer
  out: string
  err: string
end

--- One run: `words` after `cosmic hash`, and `stdin` standing in for
--- standard input; `out` replaces the write to standard output.
local function run(words: {string}, stdin?: string | Stream.Reader,
    out?: function(text: string): boolean, string): Ran
  local argv: {integer:string} = { [0] = "cosmic", [1] = "hash" }
  for index, word in ipairs(words) do argv[index + 1] = word end
  local ran: Ran = { code = -1, out = "", err = "" }
  ran.code = hash.run(argv, {
    out = out or function(text: string): boolean, string
      ran.out = ran.out .. text
      return true, ""
    end,
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
    stdin = function(): Stream.Reader | nil, string
      if stdin == nil then return nil, "no standard input in this test" end
      if stdin is string then return Stream.from_string(stdin), "" end
      return stdin, ""
    end,
  })
  return ran
end

local function file(tmp: string, name: string, text: string): string
  local path = tmp .. "/" .. name
  assert(Fs.write(path, text))
  return path
end

local ABC <const>: {string:string} = {
  ["md5"] = "900150983cd24fb0d6963f7d28e17f72",
  ["sha1"] = "a9993e364706816aba3e25717850c26c9cd0d89d",
  ["sha224"] = "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7",
  ["sha256"] = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  ["sha384"] = "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7",
  ["sha512"] = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
  ["sha3-224"] = "e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf",
  ["sha3-256"] = "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532",
  ["sha3-384"] = "ec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25",
  ["sha3-512"] = "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0",
}

local ALGORITHMS <const>: {Hash.Algorithm} = {
  "md5", "sha1", "sha224", "sha256", "sha384", "sha512",
  "sha3-224", "sha3-256", "sha3-384", "sha3-512",
}

local function test_each_algorithm_has_its_known_digest(tmp: string)
  local path = file(tmp, "abc", "abc")
  for _, algorithm in ipairs(ALGORITHMS) do
    local ran = run({ "--" .. algorithm, path })
    assert(ran.code == 0 and ran.err == "", algorithm .. ": " .. ran.err)
    assert(ran.out == ABC[algorithm] .. "  " .. path .. "\n", algorithm .. ": " .. ran.out)
  end
end

local function test_sha256_is_the_default_and_stdin_is_a_dash(tmp: string)
  local bare = run({}, "abc")
  assert(bare.code == 0 and bare.out == ABC["sha256"] .. "  -\n", bare.out)
  local dash = run({ "--sha1", "-" }, "abc")
  assert(dash.out == ABC["sha1"] .. "  -\n", dash.out)
  local empty = run({ file(tmp, "empty", "") })
  assert(empty.out == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  " .. tmp .. "/empty\n", empty.out)
end

local function test_several_files_print_in_order_and_stdin_may_be_among_them(tmp: string)
  local a, b = file(tmp, "a", "abc"), file(tmp, "b", "")
  local ran = run({ "--md5", a, "-", b }, "abc")
  assert(ran.code == 0, ran.err)
  assert(ran.out == ABC["md5"] .. "  " .. a .. "\n" .. ABC["md5"] .. "  -\n" ..
    "d41d8cd98f00b204e9800998ecf8427e  " .. b .. "\n", ran.out)
end

local function test_an_unreadable_file_is_named_and_the_rest_still_print(tmp: string)
  local good = file(tmp, "good", "abc")
  local ran = run({ tmp .. "/missing", good })
  assert(ran.code == 2, ran.code)
  assert(ran.out == ABC["sha256"] .. "  " .. good .. "\n", ran.out)
  assert(ran.err:find("cosmic: hash: " .. tmp .. "/missing", 1, true), ran.err)
  local dir = run({ tmp })
  assert(dir.code == 2 and dir.out == "", dir.out .. dir.err)
end

local function test_names_with_a_backslash_or_newline_are_escaped_as_gnu_does(tmp: string)
  local odd = file(tmp, "a\nb", "abc")
  local slashed = file(tmp, "c\\d", "abc")
  local plain = file(tmp, "plain", "abc")
  local ran = run({ odd, slashed, plain })
  assert(ran.code == 0, ran.err)
  local prefix = tmp:gsub("\\", "\\\\")
  assert(ran.out == "\\" .. ABC["sha256"] .. "  " .. prefix .. "/a\\nb\n" ..
    "\\" .. ABC["sha256"] .. "  " .. prefix .. "/c\\\\d\n" ..
    ABC["sha256"] .. "  " .. plain .. "\n", ran.out)
  -- What it printed, it checks.
  local sums = file(tmp, "sums", ran.out)
  local checked = run({ "--check", sums })
  assert(checked.code == 0 and checked.err == "", checked.err)
  -- Names come back escaped, as GNU prints them.
  assert(checked.out == "\\" .. prefix .. "/a\\nb: OK\n\\" .. prefix .. "/c\\\\d: OK\n" .. plain .. ": OK\n", checked.out)
end

local function test_a_carriage_return_is_escaped_and_gnus_own_bytes_are_read(tmp: string)
  local cr = file(tmp, "a\rb", "abc")
  local ran = run({ "--md5", cr })
  local prefix = tmp:gsub("\\", "\\\\")
  assert(ran.out == "\\" .. ABC["md5"] .. "  " .. prefix .. "/a\\rb\n", ran.out)
  -- The bytes coreutils 9.4 writes for `a\rb`, `c\d`, and a newline in a name.
  local gnu = file(tmp, "gnu", "\\" .. ABC["md5"] .. "  a\\rb\n" .. "\\" .. ABC["md5"] .. "  c\\\\d\n" ..
    "\\" .. ABC["md5"] .. "  n\\nl\n")
  assert(Fs.write(tmp .. "/a\rb", "abc") and Fs.write(tmp .. "/c\\d", "abc") and Fs.write(tmp .. "/n\nl", "abc"))
  local checked = run({ "--md5", "--check", gnu }, nil)
  -- Run in the directory the names are relative to.
  assert(checked.code == 1 and checked.out:find("\\a\\rb: FAILED open or read", 1, true), checked.out)
  local absolute = file(tmp, "abs", "\\" .. ABC["md5"] .. "  " .. prefix .. "/a\\rb\n")
  local found = run({ "--md5", "--check", absolute })
  assert(found.code == 0 and found.out == "\\" .. prefix .. "/a\\rb: OK\n", found.out .. found.err)
  -- Any other escape is refused.
  local bad = run({ "--md5", "--check", file(tmp, "bad", "\\" .. ABC["md5"] .. "  a\\tb\n") })
  assert(bad.code == 2 and bad.err:find("bad escape", 1, true), bad.err)
end

local function test_json_refuses_a_path_it_cannot_write_and_exits_2(tmp: string)
  local good = file(tmp, "good", "abc")
  local odd = file(tmp, "bad\255", "abc")
  local ran = run({ "--json", odd, good })
  assert(ran.code == 2, ran.code)
  assert(ran.err:find("--json cannot write this path", 1, true), ran.err)
  local rows = assert(Json.decode(ran.out)) as {{string:string}}
  assert(#rows == 1 and rows[1].path == good)
end

local function test_check_refuses_a_path_that_is_not_a_regular_file(tmp: string)
  local sums = file(tmp, "sums", ABC["sha256"] .. "  " .. tmp .. "\n" .. ABC["sha256"] .. "  /dev/zero\n")
  local ran = run({ "--check", sums })
  assert(ran.code == 1, ran.code)
  assert(ran.out == tmp .. ": FAILED open or read\n/dev/zero: FAILED open or read\n", ran.out)
  assert(ran.err:find("not a regular file", 1, true), ran.err)
end

local function test_a_crlf_sums_file_leaves_the_cr_in_the_name(tmp: string)
  local a = file(tmp, "a", "abc")
  local ran = run({ "--check", file(tmp, "crlf", ABC["sha256"] .. "  " .. a .. "\r\n") })
  assert(ran.code == 1 and ran.out == "\\" .. a .. "\\r: FAILED open or read\n", ran.out)
end

local function test_a_key_file_ending_in_a_newline_warns_and_keeps_it(tmp: string)
  local ran = run({ "--hmac-file", file(tmp, "k", "secret\n") }, "abc")
  assert(ran.code == 0 and ran.err:find("ends in a newline", 1, true), ran.err)
  assert(ran.out == Codec.hex(Hash.hmac("sha256", "secret\n", "abc")) .. "  -\n", ran.out)
  assert(run({ "--hmac-file", file(tmp, "k2", "secret") }, "abc").err == "")
end

local function test_json_is_an_array_of_path_algorithm_digest(tmp: string)
  local a = file(tmp, "a", "abc")
  local ran = run({ "--json", "--sha1", a, "-" }, "abc")
  assert(ran.code == 0, ran.err)
  local rows = assert(Json.decode(ran.out)) as {{string:string}}
  assert(#rows == 2)
  assert(rows[1].path == a and rows[1].algorithm == "sha1" and rows[1].digest == ABC["sha1"])
  assert(rows[2].path == "-" and rows[2].digest == ABC["sha1"])
  local hmac = run({ "--json", "--hmac", "k", a })
  local row = (assert(Json.decode(hmac.out)) as {{string:string}})[1]
  assert(row.algorithm == "hmac-sha256", row.algorithm)
  assert(run({ "--json" }, "").out:find('"digest"', 1, true))
end

--- A sums file over `a` (right), `b` (wrong), a missing file and a bad line.
local function mixed(tmp: string): string
  local a = file(tmp, "a", "abc")
  local b = file(tmp, "b", "not abc")
  return file(tmp, "sums", ABC["sha256"] .. "  " .. a .. "\n" .. ABC["sha256"] .. "  " .. b .. "\n" ..
    ABC["sha256"] .. "  " .. tmp .. "/gone\n")
end

local function test_check_says_ok_failed_and_missing_and_exits_1(tmp: string)
  local sums = mixed(tmp)
  local ran = run({ "--check", sums })
  assert(ran.code == 1, ran.code)
  assert(ran.out == tmp .. "/a: OK\n" .. tmp .. "/b: FAILED\n" .. tmp .. "/gone: FAILED open or read\n", ran.out)
  assert(ran.err:find("1 of 3 computed checksum did NOT match", 1, true), ran.err)
  assert(ran.err:find("1 listed file could not be read", 1, true), ran.err)
end

local function test_check_of_only_matches_exits_0(tmp: string)
  local a = file(tmp, "a", "abc")
  local sums = file(tmp, "sums", ABC["sha256"] .. "  " .. a .. "\n")
  local ran = run({ "--check", sums })
  assert(ran.code == 0 and ran.out == a .. ": OK\n" and ran.err == "", ran.out .. ran.err)
end

local function test_quiet_prints_only_the_failures(tmp: string)
  local ran = run({ "--check", mixed(tmp), "--quiet" })
  assert(ran.code == 1)
  assert(ran.out == tmp .. "/b: FAILED\n" .. tmp .. "/gone: FAILED open or read\n", ran.out)
  local a = file(tmp, "a", "abc")
  local ok = run({ "--quiet", "--check", file(tmp, "ok", ABC["sha256"] .. "  " .. a .. "\n") })
  assert(ok.code == 0 and ok.out == "", ok.out)
end

local function test_check_reads_markers_uppercase_comments_and_the_algorithm(tmp: string)
  local a = file(tmp, "a", "abc")
  local sums = file(tmp, "sums", "# a comment\n\n" .. ABC["sha1"]:upper() .. " *" .. a .. "\n" ..
    ABC["sha1"] .. "  " .. a)
  local ran = run({ "--sha1", "--check", sums })
  assert(ran.code == 0, ran.err)
  assert(ran.out == a .. ": OK\n" .. a .. ": OK\n", ran.out)
  -- The same file is not a SHA-256 list: its digests are the wrong length.
  local wrong = run({ "--check", sums })
  assert(wrong.code == 2 and wrong.out == "", wrong.out)
end

local function test_a_malformed_line_is_reported_and_exits_2(tmp: string)
  local a = file(tmp, "a", "abc")
  local sums = file(tmp, "sums", ABC["sha256"] .. "  " .. a .. "\nthis is not a sum\n" ..
    ABC["sha256"] .. " " .. a .. "\n")
  local ran = run({ "--check", sums })
  assert(ran.code == 2, ran.code)
  assert(ran.out == a .. ": OK\n", ran.out)
  assert(ran.err:find(sums .. ":2: improperly formatted", 1, true), ran.err)
  assert(ran.err:find(sums .. ":3: improperly formatted", 1, true), ran.err)
  local none = run({ "--check", file(tmp, "empty", "") })
  assert(none.code == 2 and none.err:find("no checksum lines found", 1, true), none.err)
  assert(run({ "--check", tmp .. "/absent" }).code == 2)
end

local function test_check_reads_a_sums_file_from_stdin(tmp: string)
  local a = file(tmp, "a", "abc")
  local ran = run({ "--check", "-" }, ABC["sha256"] .. "  " .. a .. "\n")
  assert(ran.code == 0 and ran.out == a .. ": OK\n", ran.out .. ran.err)
  -- A `-` entry cannot read the standard input that holds the list.
  local self = run({ "--check", "-" }, ABC["sha256"] .. "  -\n")
  assert(self.code == 1 and self.out == "-: FAILED open or read\n", self.out)
  -- From a file, it reads standard input.
  local piped = run({ "--check", file(tmp, "s", ABC["sha256"] .. "  -\n") }, "abc")
  assert(piped.code == 0 and piped.out == "-: OK\n", piped.out)
end

local function test_hmac_sha256_matches_rfc_4231(tmp: string)
  local ones = file(tmp, "key1", string.rep("\x0b", 20))
  local first = run({ "--hmac-file", ones, file(tmp, "m1", "Hi There") })
  assert(first.out:sub(1, 64) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", first.out)
  local second = run({ "--hmac", "Jefe", "-" }, "what do ya want for nothing?")
  assert(second.out == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843  -\n", second.out)
  -- A key longer than the block is hashed first (test case 6).
  local long = file(tmp, "key6", string.rep("\xaa", 131))
  local sixth = run({ "--hmac-file", long }, "Test Using Larger Than Block-Size Key - Hash Key First")
  assert(sixth.out == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54  -\n", sixth.out)
end

local function test_hmac_of_every_algorithm_agrees_with_hash_hmac(tmp: string)
  local keys = { "", "k", string.rep("K", 64), string.rep("K", 65), string.rep("K", 72), string.rep("K", 73),
    string.rep("K", 104), string.rep("K", 105), string.rep("K", 128), string.rep("K", 129),
    string.rep("K", 136), string.rep("K", 137), string.rep("K", 144), string.rep("K", 145), string.rep("K", 200) }
  local messages = { "", "abc", string.rep("m", 300) }
  for _, algorithm in ipairs(ALGORITHMS) do
    for _, key in ipairs(keys) do
      local key_file = file(tmp, "key", key)
      for _, message in ipairs(messages) do
        local ran = run({ "--" .. algorithm, "--hmac-file", key_file }, message)
        local want = Codec.hex(Hash.hmac(algorithm, key, message))
        assert(ran.out == want .. "  -\n", algorithm .. " key " .. #key .. " message " .. #message)
      end
    end
  end
end

local function test_check_verifies_an_hmac_only_under_its_key(tmp: string)
  local a = file(tmp, "a", "abc")
  local sums = file(tmp, "sums", run({ "--hmac", "secret", a }).out)
  assert(run({ "--check", sums, "--hmac", "secret" }).code == 0)
  local wrong = run({ "--check", sums, "--hmac", "other" })
  assert(wrong.code == 1 and wrong.out == a .. ": FAILED\n", wrong.out)
  assert(run({ "--check", sums }).code == 1)
end

local function test_hmac_key_file_keeps_its_bytes_exactly(tmp: string)
  local with_newline = run({ "--hmac-file", file(tmp, "k", "secret\n") }, "abc")
  local without = run({ "--hmac", "secret" }, "abc")
  assert(with_newline.out ~= without.out)
  assert(without.out == Codec.hex(Hash.hmac("sha256", "secret", "abc")) .. "  -\n")
  local missing = run({ "--hmac-file", tmp .. "/nokey" }, "abc")
  assert(missing.code == 2 and missing.err:find("--hmac-file", 1, true), missing.err)
end

local function test_a_bad_command_line_exits_2_and_prints_nothing(tmp: string)
  local a = file(tmp, "a", "abc")
  local sums = file(tmp, "sums", ABC["sha256"] .. "  " .. a .. "\n")
  for _, words in ipairs({
    { "--sha1", "--sha256", a }, { "--quiet", a }, { "--json", "--check", sums },
    { "--check", sums, a }, { "--hmac", "a", "--hmac-file", a, a }, { "--bogus", a },
    { "--check", "" }, { "" },
  } as {{string}}) do
    local ran = run(words, "")
    assert(ran.code == 2 and ran.out == "", table.concat(words, " ") .. ": " .. ran.out)
    assert(ran.err:find("cosmic: hash: ", 1, true), table.concat(words, " "))
  end
  assert(run({ "--sha1", "--sha256", a }).err:find("name one algorithm", 1, true))
end

local function test_a_failed_write_exits_2_in_every_mode(tmp: string)
  local a = file(tmp, "a", "abc")
  local sums = file(tmp, "sums", ABC["sha256"] .. "  " .. a .. "\n")
  local function full(_: string): boolean, string return false, "No space left on device" end
  for _, words in ipairs({ { a }, { "--json", a }, { "--check", sums }, { "--check", "-" } } as {{string}}) do
    local ran = run(words, ABC["sha256"] .. "  " .. a .. "\n", full)
    assert(ran.code == 2, table.concat(words, " ") .. ": " .. ran.code)
    assert(ran.err == "cosmic: hash: standard output: No space left on device\n", ran.err)
  end
  -- A `--quiet` check that has nothing to say has nothing to lose.
  assert(run({ "--check", sums, "--quiet" }, nil, full).code == 0)
end

--- A Reader of `total` bytes of one repeating chunk, noting the most Lua
--- memory in use at any of its reads.
local function pattern(total: integer, chunk: string): Stream.Reader, function(): integer
  local left = total
  local peak = 0
  local reader: Stream.Reader = {}
  reader.read = function(_self: Stream.Reader, max?: integer): string | nil, string
    peak = math.max(peak, collectgarbage("count") as integer)
    if left == 0 then return nil, "" end
    local size = math.min(left, max or #chunk, #chunk)
    left = left - size
    return chunk:sub(1, size), ""
  end
  reader.close = function(): boolean, string return true, "" end
  return reader, function(): integer return peak end
end

local function test_a_large_input_streams_in_bounded_memory()
  local chunk = string.rep("0123456789abcdef", 4096)
  local total = 96 * 1024 * 1024
  local expected = (assert(Hash.hasher("sha256")))
  for _ = 1, total // #chunk do expected:update(chunk) end
  local raw = expected:digest()
  local want = Codec.hex(raw as string)
  collectgarbage()
  local before = collectgarbage("count") as integer
  local reader, peak = pattern(total, chunk)
  local ran = run({ "-" }, reader)
  assert(ran.code == 0 and ran.out == want .. "  -\n", ran.out .. ran.err)
  -- 96 MiB went through; Lua held a few chunks of it at a time, not it.
  local grew = peak() - before
  assert(grew < 8 * 1024, "Lua memory grew by " .. grew .. " KiB while hashing 96 MiB")
end
