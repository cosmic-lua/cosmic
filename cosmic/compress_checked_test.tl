--- What the compress library does where the checked core's instruments
--- reach it: a decoder that stops consuming meets the ratio check, and a
--- refused allocation in the middle of a decode leaves its stream
--- finished. Another core has neither instrument, so this module requires
--- `checked`.

local Compress = require("cosmic.compress")
local testing = require("cosmic.internal.testing")
local Test = require("cosmic.test")

Test.policy{ requires = { "checked" } }

local function gzip_decoder(): Compress.Stream return (assert(Compress.inflater("gzip"))) end

--- The ratio check, reached through the checked core's fault point: a
--- tinfl that stops consuming, as upstream's did on a block with no
--- codes, gives out a full window per call for nothing, and the stream
--- fails once that passes deflate's largest ratio rather than spinning.
local function test_a_decoder_that_stops_consuming_fails_the_ratio_check()
  local packed = assert(Compress.deflate("raw", "hello, cosmic!"))
  testing.fail_at("tinfl_decompress")
  local dec = assert(Compress.inflater("raw"))
  local out, trouble: string, string
  for _ = 1, 64 do
    out, trouble = dec:update(packed)
    if out == nil or not dec:pending() then break end
    packed = ""
  end
  assert(not testing.fail_at(), "the fault fired")
  assert(out == nil and trouble:find("more output than deflate codes", 1, true) ~= nil, tostring(trouble))
end

local function test_a_raise_inside_update_leaves_the_stream_finished()
  local input = string.rep("the quick brown fox ", 5000)
  local enc = assert(Compress.deflater("gzip"))
  local packed = assert(enc:update(input)) .. assert(enc:finish())
  local raised = 0
  for after = 0, 100000 do
    local dec = gzip_decoder()
    testing.fail_allocations(after)
    local ok = pcall(dec.update, dec, packed, 1 << 20)
    local refused = testing.allow_allocations()
    if refused == 0 then
      assert(ok)
      break
    end
    if not ok then
      raised = raised + 1
      local again, why = pcall(dec.update, dec, "")
      assert(not again and tostring(why):find("finished", 1, true), tostring(why))
    end
  end
  assert(raised > 0)
end
