local Compress = require("cosmic.compress")
local Fixture = require("cosmic_ci.fixture")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

--- The zstd decode stub (core/unzstd.c) of the host's target, built by
--- `bin/zig build` into the build directory beside the core, run as the
--- launcher will run it: on a descriptor it inherits, a range of the
--- file, a decoded length. It is another build of zstd than the core's
--- (the decoder alone, one Huffman decoder, no legacy formats), so its
--- cases are its own. Run unsandboxed and sharing nothing
--- (cosmic_ci/orchestration.tl's `fixture`), its worker is given the
--- variables it names.
Test.policy{
  env = {
    "COSMIC_FIXTURE_BUILD",
    "COSMIC_FIXTURE_ROOT",
    "COSMIC_FIXTURE_TARGET",
    "PATH",
    "HOME",
    "XDG_CACHE_HOME",
    "TMPDIR",
    "COSMIC_PORTABLE_CACHE",
    "COSMIC_VERDICT_CACHE",
    "COSMIC_AUTO_BOOT",
    "COSMIC_TEST_SANDBOX",
    "COSMIC_SANDBOX",
    "COSMIC_TEST_HELD",
    "COSMIC_BOOTSTRAP", "COSMIC_BUILD_HOME",
    "COSMIC_ZIG",
    "COSMIC_ZIG_CACHE",
    "COSMIC_ZIG_GLOBAL_CACHE",
    "ZIG_LIB_DIR",
    "ZIG_GLOBAL_CACHE_DIR",
    "ZIG_LOCAL_CACHE_DIR",
    "SDKROOT",
    "DEVELOPER_DIR",
    "COSMIC_TEST_TIMEOUT",
    "FUZZ_ITERS",
    "MACOSX_DEPLOYMENT_TARGET",
    "COSMIC_BOOTSTRAP_ATTEMPTS",
    "COSMIC_BOOTSTRAP_VERIFY",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "CURL_CA_BUNDLE",
    "ALL_PROXY",
    "HTTPS_PROXY",
    "HTTP_PROXY",
    "NO_PROXY",
    "all_proxy",
    "https_proxy",
    "http_proxy",
    "no_proxy",
  },
}

local junk_before <const> = 1000
local junk_after <const> = 100

local function byte_at(data: string, at: integer): integer
  return (assert(data:byte(at), "a byte at " .. tostring(at)))
end

local function le32(n: integer): string
  return string.pack("<I4", n)
end

--- The frame the stub takes for `raw`: Compress.zstd's.
local function frame_of(raw: string): string
  return (assert(Compress.zstd(raw, 19)))
end

--- The frame a streaming encoder writes for `raw`: a checksum, and no
--- content size, since it takes its input a chunk at a time.
local function streamed(raw: string): string
  local encoder = assert(Compress.zstd_encoder(19))
  return (assert(Stream.run(encoder, raw)))
end

--- `frame`, a streamed one, with `size` declared as its content size and
--- the window descriptor `window` where given: the same blocks and
--- checksum, which neither field enters.
local function declared(frame: string, size: integer, window?: integer): string
  assert(frame:sub(1, 4) == "\40\181\47\253" and byte_at(frame, 5) == 0x04,
    "a streamed frame is checksummed and multi-segment, with no content size or dictionary")
  local descriptor: integer = window or byte_at(frame, 6)
  return frame:sub(1, 4) .. string.char(0x84, descriptor) .. le32(size) .. frame:sub(7)
end

--- Bytes that do not compress, and are the same every run.
local function noise(size: integer): string
  local parts: mut {string} = {}
  local state = 12345
  for i = 1, size do
    state = (state * 1103515245 + 12345) & 0x7fffffff
    parts[i] = string.char((state >> 16) & 0xff)
  end
  return table.concat(parts)
end

local function sentence(size: integer): string
  return (string.rep("the quick brown fox jumps over the lazy dog ", size // 44 + 1)):sub(1, size)
end

local function stub_path(): string
  return Fixture.required("COSMIC_FIXTURE_BUILD") .. "/core/" ..
    Fixture.required("COSMIC_FIXTURE_TARGET") .. "/cosmic-unzstd"
end

local function on_linux(): boolean
  local names = sys.uname()
  return names ~= nil and names.sysname == "Linux"
end

local record Run
  ok: boolean
  code: integer?
  output: string
  message: string
end

--- Runs the stub on `stored`, written into a file between other bytes, on
--- descriptor 3, for `length`; `words` replaces the arguments when given.
local function run(tmp: string, label: string, stored: string, length: integer,
                   words?: {string}, claimed?: integer, after?: boolean): Run
  local artifact = tmp .. "/" .. label .. ".artifact"
  Fixture.write(artifact, string.rep("x", junk_before) .. stored ..
      (if after == false then "" else string.rep("y", junk_after) end))
  local argv: mut {string} = { stub_path() }
  for _, word in ipairs(words or { "3", tostring(junk_before), tostring(claimed or #stored), tostring(length) }) do
    argv[#argv + 1] = word
  end
  local outcome = Fixture.call_with_descriptors(label, argv, tmp, tmp .. "/logs",
    Fixture.environment(), { [3] = artifact })
  local finished = outcome.result
  return { ok = finished.ok, code = finished.code,
    output = Fixture.read(outcome.out), message = Fixture.read(outcome.err) }
end

--- Asserts the stub refused with `code` and a one-line message holding
--- `text`, having written no more than `length` bytes.
local function refused(r: Run, code: integer, text: string, length: integer, what: string)
  assert(not r.ok and r.code == code, what .. ": exit " .. tostring(r.code) .. ": " .. r.message)
  assert(r.message:find(text, 1, true) ~= nil and r.message:match("^unzstd: [^\n]*\n$") ~= nil,
    what .. ": message " .. r.message)
  assert(#r.output <= length, what .. ": wrote " .. tostring(#r.output) .. " bytes")
end

local function test_a_frame_round_trips(tmp: string)
  -- Past the stub's read chunk and output buffer; an incompressible
  -- stream (stored blocks); and one byte.
  for name, raw in pairs({ text = sentence(300000), noise = noise(200000), one = "z" }) do
    local r = run(tmp, "round-" .. name, frame_of(raw), #raw)
    assert(r.ok and r.output == raw, name .. ": " .. r.message)
  end
end

local function test_the_hosts_core_round_trips(tmp: string)
  local core = Fixture.read(Fixture.required("COSMIC_FIXTURE_BUILD") .. "/core/" ..
      Fixture.required("COSMIC_FIXTURE_TARGET") .. "/cosmic-core")
  local frame = frame_of(core)
  local r = run(tmp, "core", frame, #core)
  assert(r.ok and r.output == core, "the core does not round trip: " .. r.message)
  -- The window the encoder chose for a core is within the stub's limit
  -- (core/unzstd.h), or the stub refused above.
  assert(#frame < #core)
end

local function test_the_content_size_must_be_declared_and_equal(tmp: string)
  local raw = sentence(5000)
  local frame = streamed(raw)
  refused(run(tmp, "no-size", frame, #raw), 1, "content size", #raw, "no content size")
  local good = frame_of(raw)
  refused(run(tmp, "long-arg", good, #raw + 1), 1, "content size", #raw + 1, "length past the declared")
  refused(run(tmp, "short-arg", good, #raw - 1), 1, "content size", #raw - 1, "length short of the declared")
  refused(run(tmp, "lying", declared(frame, #raw + 1), #raw + 1), 1, "", #raw + 1, "a declared size the blocks do not fill")
end

local function test_the_checksum_must_be_present_and_right(tmp: string)
  local raw = sentence(5000)
  local good = frame_of(raw)
  local unchecked = good:sub(1, 4) .. string.char(byte_at(good, 5) & ~0x04) .. good:sub(6, -5)
  refused(run(tmp, "no-checksum", unchecked, #raw), 1, "no checksum", #raw, "no checksum")
  local flipped = good:sub(1, -2) .. string.char(byte_at(good, -1) ~ 1)
  refused(run(tmp, "bad-checksum", flipped, #raw), 1, "checksum", #raw, "a wrong checksum")
end

local function test_exactly_one_frame_and_nothing_after_it(tmp: string)
  local first, second = sentence(3000), noise(2000)
  local one = frame_of(first)
  local skippable = "\80\42\77\24" .. le32(4) .. "abcd"
  refused(run(tmp, "two", one .. frame_of(second), #first), 1, "after the frame", #first, "a second frame")
  refused(run(tmp, "trailing", one .. "\0", #first), 1, "after the frame", #first, "a trailing byte")
  refused(run(tmp, "skippable-after", one .. skippable, #first), 1, "after the frame", #first, "a skippable frame after")
  refused(run(tmp, "skippable-first", skippable .. one, #first), 1, "skippable", #first, "a skippable frame first")
  refused(run(tmp, "garbage", "not a frame at all, not at all", 10), 1, "bad frame header", 10, "no frame")
end

local function test_a_short_or_cut_range_fails(tmp: string)
  local raw = sentence(20000)
  local good = frame_of(raw)
  refused(run(tmp, "past-eof", good, #raw, nil, #good + 5, false), 1, "ends inside", #raw, "a range past the end of the file")
  refused(run(tmp, "cut", good:sub(1, -5), #raw), 1, "truncated", #raw, "a frame cut before its checksum")
  refused(run(tmp, "cut-header", good:sub(1, 6), #raw), 1, "truncated", #raw, "a cut header")
  refused(run(tmp, "empty-range", good, #raw, nil, 0), 1, "empty", #raw, "an empty range")
  local hit = good:sub(1, 40) .. string.char(byte_at(good, 41) ~ 0xff) .. good:sub(42)
  local r = run(tmp, "corrupt", hit, #raw)
  assert(not r.ok and r.code == 1 and #r.output <= #raw, "a corrupt block: " .. r.message)
end

local function test_a_window_past_the_limit_is_refused_before_decoding(tmp: string)
  local source = Fixture.read(Fixture.required("COSMIC_FIXTURE_ROOT") .. "/core/unzstd.h")
  local log = assert(math.tointeger(tonumber(source:match("COSMIC_UNZSTD_WINDOW_LOG%s+(%d+)"))))
  local raw = sentence(5000)
  local frame = streamed(raw)
  local limit = (log - 10) << 3
  assert(byte_at(frame, 6) <= limit, "the encoder's window is within the stub's limit")
  assert(run(tmp, "window-at", declared(frame, #raw, limit), #raw).ok, "a window at the limit")
  refused(run(tmp, "window-over", declared(frame, #raw, limit + 8), #raw), 1, "window", #raw, "a window past the limit")
  refused(run(tmp, "window-huge", declared(frame, #raw, 0xf8), #raw), 1, "memory", #raw, "a window of 2^41")
end

local function test_bad_arguments_are_refused(tmp: string)
  local raw = sentence(1000)
  local good = frame_of(raw)
  local size, length = tostring(#good), tostring(#raw)
  local at = tostring(junk_before)
  local nothing: mut {string} = {}
  for name, words in pairs({
      none = nothing, few = { "3", at, size }, many = { "3", at, size, length, "1" },
      standard_input = { "0", at, size, length }, standard_error = { "2", at, size, length },
      high = { "10", at, size, length }, word = { "x", at, size, length },
      signed = { "3", "-1", size, length }, spaced = { "3", " " .. at, size, length },
      hex = { "3", "0x10", size, length }, empty = { "3", "", size, length },
      huge_offset = { "3", "9223372036854775808", size, length },
      huge_length = { "3", at, size, "9223372036854775808" },
      overflow = { "3", "9223372036854775807", "1", length },
      overflow_sum = { "3", "9223372036854775800", "9", length },
      long_number = { "3", at, size, string.rep("9", 40) },
      zero_length = { "3", at, size, "0" },
      over_the_ceiling = { "3", at, size, "268435457" },
  }) do
    local r = run(tmp, "args-" .. name, good, #raw, words)
    refused(r, 2, "", 0, "arguments " .. name)
    assert(#r.output == 0, name .. ": wrote output")
  end
  -- A descriptor nothing opened is a failed read, not a usage error.
  refused(run(tmp, "args-closed", good, #raw, { "5", at, size, length }), 3, "cannot examine", 0, "a closed descriptor")
end

--- A damaged copy of a good frame decodes to the original or fails: it
--- is never accepted with other bytes, whatever byte is hit or where the
--- range is cut.
local function test_a_damaged_frame_never_decodes_to_other_bytes(tmp: string)
  local raw = sentence(3000) .. noise(300)
  local good = frame_of(raw)
  local function holds(label: string, stored: string)
    local r = run(tmp, label, stored, #raw)
    assert(not r.ok or r.output == raw, label .. ": accepted other bytes")
    assert(#r.output <= #raw, label .. ": wrote past the length")
    if not r.ok then
      assert(r.code == 1, label .. ": exit " .. tostring(r.code) .. ": " .. r.message)
    end
  end
  local step = math.max(1, #good // 37)
  for at = 1, #good, step do
    holds("flip-" .. tostring(at), good:sub(1, at - 1) .. string.char(byte_at(good, at) ~ 0x55) .. good:sub(at + 1))
    holds("cut-" .. tostring(at), good:sub(1, at - 1))
  end
  for at = 1, 24 do
    holds("head-" .. tostring(at), good:sub(1, at - 1) .. string.char(byte_at(good, at) ~ 0x01) .. good:sub(at + 1))
  end
end

--- Runs `script` under sh with the stub and its words after it
--- (`"$@"`), the artifact on descriptor 3; answers its result.
local function shell(tmp: string, label: string, stored: string, length: integer, script: string): Run
  local artifact = tmp .. "/" .. label .. ".artifact"
  Fixture.write(artifact, string.rep("x", junk_before) .. stored .. string.rep("y", junk_after))
  local outcome = Fixture.call_with_descriptors(label, { "/bin/sh", "-c", script, "sh", stub_path(), "3",
    tostring(junk_before), tostring(#stored), tostring(length) }, tmp, tmp .. "/logs",
    Fixture.environment(), { [3] = artifact })
  return { ok = outcome.result.ok, code = outcome.result.code,
    output = Fixture.read(outcome.out), message = Fixture.read(outcome.err) }
end

local function test_a_descriptor_that_is_no_regular_file_is_refused(tmp: string)
  local raw = sentence(1000)
  local good = frame_of(raw)
  local outcome = Fixture.call_with_descriptors("directory", { stub_path(), "3", "0", tostring(#good),
    tostring(#raw) }, tmp, tmp .. "/logs", Fixture.environment(), { [3] = tmp })
  assert(not outcome.result.ok and outcome.result.code == 2, "a directory: " .. Fixture.read(outcome.err))
  assert(Fixture.read(outcome.err):find("regular file", 1, true), Fixture.read(outcome.err))
  assert(Fixture.read(outcome.out) == "", "a directory: wrote output")
end

local function test_a_full_output_device_fails(tmp: string)
  if not on_linux() then
    Test.skip("/dev/full is Linux's")
    return
  end
  local raw = sentence(300000)
  local r = shell(tmp, "full", frame_of(raw), #raw, 'exec "$@" > /dev/full')
  assert(not r.ok and r.code == 3 and r.message:find("cannot write", 1, true) ~= nil,
    "a full device: exit " .. tostring(r.code) .. ": " .. r.message)
end

--- The stub reads with pread, so a descriptor another reader moved, or
--- one it is run on twice, gives the same bytes.
local function test_the_descriptors_offset_neither_matters_nor_moves(tmp: string)
  local raw = noise(70000)
  local r = shell(tmp, "offset", frame_of(raw), #raw,
    'head -c 5 <&3 > /dev/null; "$@" > "$0.a" || exit 1; head -c 9 <&3 > /dev/null; "$@" > "$0.b" || exit 1; ' ..
      'cat "$0.a" "$0.b"')
  assert(r.ok, "two runs: " .. r.message)
  assert(r.output == raw .. raw, "two runs on one descriptor differ")
end

--- The decode fits the workspace of the stub's window and no more: a
--- virtual memory limit far under zstd's default window (128 MiB), which
--- a decoder that allocated for a hostile header would fail. The limit is 24
--- MB and not a fraction of the core: the stub's static workspace for its
--- 8 MiB window alone is larger than the core, so a limit well under the
--- core's size cannot be met. It holds the stub to the workspace plus the
--- core, and to nothing sized by the frame header.
local function test_the_decode_fits_a_small_memory_limit(tmp: string)
  if not on_linux() then
    Test.skip("ulimit -v is not enforced on macOS")
    return
  end
  local core = Fixture.read(Fixture.required("COSMIC_FIXTURE_BUILD") .. "/core/" ..
      Fixture.required("COSMIC_FIXTURE_TARGET") .. "/cosmic-core")
  local r = shell(tmp, "limited", frame_of(core), #core, 'ulimit -v 24576 && exec "$@"')
  assert(r.ok and r.output == core, "under 24 MiB: " .. r.message)
end

--- The ceiling on each stub's size: the figures of the plan, with room
--- to grow by a little and not by a library.
local ceilings <const>: {string:integer} = {
  ["x86_64-linux-musl"] = 100 * 1024,
  ["aarch64-linux-musl"] = 100 * 1024,
  ["aarch64-macos"] = 160 * 1024,
}

local function test_each_stub_is_small(_: string)
  local build = Fixture.required("COSMIC_FIXTURE_BUILD")
  for name, ceiling in pairs(ceilings) do
    local path = build .. "/core/" .. name .. "/cosmic-unzstd"
    if name == Fixture.required("COSMIC_FIXTURE_TARGET") then
      assert(#Fixture.read(path) <= ceiling, name .. ": the stub is over " .. tostring(ceiling) .. " bytes")
    end
  end
end
