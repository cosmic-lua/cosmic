--- What the compress library does where the checked core's instruments
--- reach it: a decoder that stops consuming meets the ratio check, and a
--- refused allocation in the middle of a decode leaves its stream
--- finished. Another core has neither instrument, so this module requires
--- `checked`.

local Compress = require("cosmic.compress")
local testing = require("cosmic.internal.testing")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true, requires = { "checked" } }

local function gzip_decoder(): Compress.Stream return (assert(Compress.decoder("gzip"))) end

--- The ratio check, reached through the checked core's fault point: a
--- tinfl that stops consuming, as upstream's did on a block with no
--- codes, gives out a full window per call for nothing, and the stream
--- fails once that passes deflate's largest ratio rather than spinning.
local function test_a_decoder_that_stops_consuming_fails_the_ratio_check()
  local packed = assert(Compress.encode("raw", "hello, cosmic!"))
  testing.fail_at("tinfl_decompress")
  local dec = assert(Compress.decoder("raw"))
  local out, trouble: string?, string?
  for _ = 1, 64 do
    out, trouble = dec:update(packed)
    if out == nil or not dec:pending() then break end
    packed = ""
  end
  assert(not testing.fail_at(), "the fault fired")
  assert(out == nil and tostring(trouble):find("more output than deflate codes", 1, true) ~= nil, tostring(trouble))
end

local function test_a_raise_inside_update_leaves_the_stream_finished()
  local input = string.rep("the quick brown fox ", 5000)
  local enc = assert(Compress.encoder("gzip"))
  local packed = assert(enc:update(input)) .. assert(enc:finish())
  local raised = 0
  for after = 0, 100000 do
    local dec = gzip_decoder()
    testing.fail_allocations(after)
    local ok = pcall(dec.update, dec, packed, 1 << 20) -- checked: alternatives_as_value
    local refused = testing.allow_allocations()
    if refused == 0 then
      assert(ok)
      break
    end
    if not ok then
      raised = raised + 1
      local again, why = pcall(dec.update, dec, "")
      assert(not again and tostring(why):find("finished", 1, true) ~= nil, tostring(why))
    end
  end
  assert(raised > 0)
end

--- An xz or bzip2 decoder draws its codec's memory from the core's heap,
--- as the encoders do: a live decoder holds its codec's window there (8 MiB
--- for xz's default preset, over 2 MiB for bzip2's -9), a refusal there is
--- the decode's own "out of memory", and none of it is left live once the
--- stream is collected.
local function test_xz_and_bzip2_decoders_refuse_and_free_on_the_core_heap()
  local plain = string.rep("the quick brown fox ", 2000)
  local formats: {Compress.Format} = { "xz", "bz2" }
  for _, format in ipairs(formats) do
    local packed = assert(Compress.encode(format, plain))
    collectgarbage()
    local bytes_before, _ = testing.c_heap()
    do
      local live <close> = assert(Compress.decoder(format))
      assert(live:update(packed:sub(1, #packed // 2), 16))
      local bytes_live, _ = testing.c_heap()
      assert(bytes_live - bytes_before > 1 << 20, format .. ": the codec's window is not on the core heap")
    end
    local said = 0
    local why = ""
    -- Made before any refusal, so only the decode meets one.
    local function attempt(): string?
      local value, failure = Compress.decode(format, packed)
      if value == nil then why = assert(failure).message end
      return value
    end
    for after = 0, 100000 do
      why = ""
      -- Once: a walk refuses every allocation after the first too, so the
      -- message that reports the codec's refusal could not be built.
      testing.fail_allocations(after, true)
      local ok, out = pcall(attempt)
      local refused = testing.allow_allocations()
      if refused == 0 then
        assert(ok and out == plain, format)
        break
      end
      if ok and out == nil and why:find("out of memory", 1, true) ~= nil then said = said + 1 end
    end
    assert(said > 0, format .. ": no refusal reached the codec")
    collectgarbage()
    collectgarbage()
    local bytes_after, _ = testing.c_heap()
    assert(bytes_after <= bytes_before, format .. ": the core heap grew")
  end
end
