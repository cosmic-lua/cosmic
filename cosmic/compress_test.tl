--- Proves the streaming codecs round-trip, decode published vectors,
--- and refuse corrupt or truncated input rather than answering with
--- something wrong.

local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Sqlite = require("cosmic.sqlite")

-- Feeds `data` through `stream` in pieces of `size` bytes (the whole of
-- it in one piece when `size` is nil), draining each piece's held
-- output, collecting every update's output plus finish's, and returns
-- it with the error `finish` gives, if any.
local function drive(stream: Compress.Stream, data: string, size?: integer): string, string
  local parts: {string} = {}
  local step = size or #data
  if step < 1 then step = 1 end
  local pos = 1
  while pos <= #data do
    local piece = data:sub(pos, pos + step - 1)
    while true do
      local out, trouble = stream:update(piece)
      if out == nil then
        return "", trouble
      end
      assert(trouble == "", "a success carries \"\" in the error slot")
      parts[#parts + 1] = out
      if not stream:pending() then break end
      piece = ""
    end
    pos = pos + step
  end
  local last, trouble = stream:finish()
  if last == nil then
    return table.concat(parts), trouble
  end
  parts[#parts + 1] = last
  return table.concat(parts), ""
end

local function roundtrip(format: Compress.Format, plain: string, chunk_size?: integer)
  local enc = assert(Compress.deflater(format))
  local packed, enc_trouble = drive(enc, plain, chunk_size)
  assert(enc_trouble == "", enc_trouble)

  local dec = assert(Compress.inflater(format))
  local out, dec_trouble = drive(dec, packed, chunk_size)
  assert(dec_trouble == "", dec_trouble)
  assert(out == plain, format .. ": " .. #out .. " vs " .. #plain)
  assert(dec:done())
end

local function test_raw_zlib_gzip_roundtrip_many_small_chunks()
  local plain = string.rep("the quick brown fox jumps over the lazy dog. ", 500)
  for _, format in ipairs({ "raw", "zlib", "gzip" } as {Compress.Format}) do
    roundtrip(format, plain, 7)
  end
end

local function test_raw_zlib_gzip_roundtrip_one_big_chunk()
  -- 8 MB of semi-compressible data: large enough that the codec cannot
  -- know its size up front and must stream through its output buffer
  -- more than once.
  local piece = string.rep("cosmic ", 97) .. "\0\1\2\3"
  local plain = string.rep(piece, (8 * 1024 * 1024) // #piece + 1)
  for _, format in ipairs({ "raw", "zlib", "gzip" } as {Compress.Format}) do
    roundtrip(format, plain)
  end
end

local function test_gzip_known_vector_decodes()
  -- `printf 'hello, cosmic!' | gzip -9 -n`
  local vector = "\31\139\8\0\0\0\0\0\2\3\203\72\205\201\201\215\81\72\206\47\206\205\76\86\4\0\92\110\87\198\14\0\0\0"
  local dec = assert(Compress.inflater("gzip"))
  local out, trouble = drive(dec, vector, 1)
  assert(trouble == "", trouble)
  assert(out == "hello, cosmic!", out)
  assert(dec:done())
  assert(dec:rest() == "")
end

local function test_gzip_multi_member_decodes_every_member()
  -- gzip.compress(b"first") .. gzip.compress(b"second"), both mtime 0
  local vector = "\31\139\8\0\0\0\0\0\2\3\75\203\44\42\46\1\0\87\238\113\146\5\0\0\0" ..
    "\31\139\8\0\0\0\0\0\2\3\43\78\77\206\207\75\1\0\105\17\31\182\6\0\0\0"
  local dec = assert(Compress.inflater("gzip"))
  local out, trouble = drive(dec, vector)
  assert(trouble == "", trouble)
  assert(out == "firstsecond", out)
  assert(dec:done())
end

local function test_gzip_trailing_bytes_after_the_stream_become_rest()
  local member = "\31\139\8\0\0\0\0\0\2\3\203\72\205\201\201\215\81\72\206\47\206\205\76\86\4\0\92\110\87\198\14\0\0\0"
  local dec = assert(Compress.inflater("gzip"))
  local out1 = assert(dec:update(member))
  assert(not dec:done())
  local out2 = assert(dec:update("trailer bytes"))
  assert(dec:done())
  assert(dec:rest() == "trailer bytes")
  local last = assert(dec:finish())
  assert(out1 .. out2 .. last == "hello, cosmic!")
end

local function test_gzip_corrupt_crc_is_refused()
  local vector = "\31\139\8\0\0\0\0\0\2\3\203\72\205\201\201\215\81\72\206\47\206\205\76\86\4\0\92\110\87\199\14\0\0\0"
  local dec = assert(Compress.inflater("gzip"))
  local _, trouble = drive(dec, vector)
  assert(trouble ~= "" and trouble:find("CRC", 1, true), trouble)
end

local function test_zlib_and_raw_truncated_input_errors_on_finish()
  for _, format in ipairs({ "raw", "zlib" } as {Compress.Format}) do
    local enc = assert(Compress.deflater(format))
    local packed = assert(drive(enc, string.rep("abcdefgh", 200)))
    local dec = assert(Compress.inflater(format))
    assert(dec:update(packed:sub(1, #packed - 4)))
    local last, trouble = dec:finish()
    assert(last == nil and trouble ~= "", format)
  end
end

local function test_gzip_truncated_mid_header_errors_on_finish()
  local dec = assert(Compress.inflater("gzip"))
  assert(dec:update("\31\139\8"))
  local last, trouble = dec:finish()
  assert(last == nil and trouble ~= "")
end

local function test_corrupt_deflate_data_is_refused()
  local dec = assert(Compress.inflater("zlib"))
  local out, trouble = dec:update("not a zlib stream at all, just garbage")
  assert(out == nil and trouble ~= "")
end

local function test_crc32_matches_the_known_value_and_continues()
  -- crc32("hello, cosmic!") from Python's binascii.crc32.
  local whole = Compress.crc32("hello, cosmic!")
  local half = Compress.crc32("hello, ")
  local continued = Compress.crc32("cosmic!", half)
  assert(whole == continued)
  assert(whole == 3327618652, tostring(whole))
  assert(Compress.crc32("") == 0)
  -- Long, and at an unaligned start: the hardware paths fold 16 bytes
  -- at a time and handle the ragged ends apart (binascii.crc32 again).
  local bytes: {string} = {}
  for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
  local long = table.concat(bytes):rep(40)
  assert(Compress.crc32(long) == 3150855069)
  assert(Compress.crc32(long:sub(4, 1000)) == 2769185661)
  local folded = 0
  for i = 1, #long, 37 do folded = Compress.crc32(long:sub(i, i + 36), folded) end
  assert(folded == 3150855069)
end

local function test_bz2_known_vector_decodes_one_byte_at_a_time()
  -- `printf 'hello, cosmic!' | bzip2 -9`
  local vector = "\66\90\104\57\49\65\89\38\83\89\153\84\167\133\0\0\3\17\128\96\4\10\102\136\0\32\0\34\0\30\160\128\105\166\135\131\39\44\211\152\60\93\201\20\225\66\66\101\82\158\20"
  local dec = assert(Compress.bz2_decoder())
  local out, trouble = drive(dec, vector, 1)
  assert(trouble == "", trouble)
  assert(out == "hello, cosmic!", out)
  assert(dec:done())
end

local function test_bz2_multi_stream_decodes_every_stream()
  -- bz2.compress(b"first") .. bz2.compress(b"second")
  local vector = "\66\90\104\57\49\65\89\38\83\89\178\57\11\221\0\0\0\1\128\1\32\28\0\32\0\33\131\65\154\2\92\113\119\36\83\133\9\11\35\144\189\208" ..
    "\66\90\104\57\49\65\89\38\83\89\38\138\2\52\0\0\2\129\128\14\1\136\0\32\0\34\24\104\48\7\2\152\93\201\20\225\66\64\154\40\8\208"
  local dec = assert(Compress.bz2_decoder())
  local out, trouble = drive(dec, vector)
  assert(trouble == "", trouble)
  assert(out == "firstsecond", out)
  assert(dec:done())
end

local function test_bz2_truncated_input_errors_on_finish()
  local vector = "\66\90\104\57\49\65\89\38\83\89\153\84\167\133\0\0\3\17\128\96\4\10\102\136\0\32\0\34\0\30\160\128\105\166\135\131\39\44\211\152\60\93\201\20\225\66\66\101\82\158\20"
  local dec = assert(Compress.bz2_decoder())
  assert(dec:update(vector:sub(1, #vector - 5)))
  local last, trouble = dec:finish()
  assert(last == nil and trouble ~= "")
end

local function test_bz2_corrupt_magic_is_refused()
  local dec = assert(Compress.bz2_decoder())
  local out, trouble = dec:update("not a bzip2 stream")
  assert(out == nil and trouble ~= "")
end

local function test_xz_known_vector_decodes_one_byte_at_a_time()
  -- `printf 'hello, cosmic!' | xz -c`
  local vector = "\253\55\122\88\90\0\0\4\230\214\180\70\2\0\33\1\28\0\0\0\16\207\88\204\1\0\13\104\101\108\108\111\44\32\99\111\115\109\105\99\33\0\0\0\195\231\225\101\211\83\88\122\0\1\38\14\8\27\224\4\31\182\243\125\1\0\0\0\0\4\89\90"
  local dec = assert(Compress.xz_decoder())
  local out, trouble = drive(dec, vector, 1)
  assert(trouble == "", trouble)
  assert(out == "hello, cosmic!", out)
  assert(dec:done())
end

local function test_xz_multi_stream_decodes_every_stream()
  -- `xz -c <<<first` .. `xz -c <<<second`
  local vector = "\253\55\122\88\90\0\0\4\230\214\180\70\2\0\33\1\22\0\0\0\116\47\229\163\1\0\4\102\105\114\115\116\0\0\0\0\86\173\25\37\122\6\229\243\0\1\29\5\184\45\128\175\31\182\243\125\1\0\0\0\0\4\89\90" ..
    "\253\55\122\88\90\0\0\4\230\214\180\70\2\0\33\1\22\0\0\0\116\47\229\163\1\0\5\115\101\99\111\110\100\0\0\0\56\232\136\197\198\48\180\116\0\1\30\6\193\47\164\29\31\182\243\125\1\0\0\0\0\4\89\90"
  local dec = assert(Compress.xz_decoder())
  local out, trouble = drive(dec, vector)
  assert(trouble == "", trouble)
  assert(out == "firstsecond", out)
  assert(dec:done())
end

local function test_xz_decodes_the_x86_and_delta_filters()
  -- `xz --x86 --lzma2 -c` and `xz --delta=dist=1 --lzma2 -c`, both over
  -- "hello, cosmic!": proves the BCJ and delta filters this build
  -- vendors actually run, not just plain LZMA2.
  local x86 = "\253\55\122\88\90\0\0\4\230\214\180\70\2\1\4\0\33\1\22\0\13\134\53\31\1\0\13\104\101\108\108\111\44\32\99\111\115\109\105\99\33\0\0\0\195\231\225\101\211\83\88\122\0\1\38\14\8\27\224\4\31\182\243\125\1\0\0\0\0\4\89\90"
  local delta = "\253\55\122\88\90\0\0\4\230\214\180\70\2\1\3\1\0\33\1\22\121\32\196\238\1\0\13\104\253\7\0\3\189\244\67\12\4\250\252\250\190\0\0\0\195\231\225\101\211\83\88\122\0\1\38\14\8\27\224\4\31\182\243\125\1\0\0\0\0\4\89\90"
  for _, vector in ipairs({ x86, delta }) do
    local dec = assert(Compress.xz_decoder())
    local out, trouble = drive(dec, vector)
    assert(trouble == "", trouble)
    assert(out == "hello, cosmic!", out)
  end
end

local function test_xz_truncated_input_errors_on_finish()
  local vector = "\253\55\122\88\90\0\0\4\230\214\180\70\2\0\33\1\28\0\0\0\16\207\88\204\1\0\13\104\101\108\108\111\44\32\99\111\115\109\105\99\33\0\0\0\195\231\225\101\211\83\88\122\0\1\38\14\8\27\224\4\31\182\243\125\1\0\0\0\0\4\89\90"
  local dec = assert(Compress.xz_decoder())
  assert(dec:update(vector:sub(1, #vector - 10)))
  local last, trouble = dec:finish()
  assert(last == nil and trouble ~= "")
end

local function test_xz_corrupt_magic_is_refused()
  local dec = assert(Compress.xz_decoder())
  local out, trouble = dec:update("not an xz stream")
  assert(out == nil and trouble ~= "")
end

-- Everything below exercises the bounded-output contract and the
-- member and trailer rules the three multi-member decoders share.

-- 8 MiB of NUL bytes as `xz -0 --check=crc32` writes it: 1352 bytes.
local xz_bomb = assert(Codec.unhex(
  "fd377a585a0000016922de36020021010c0000008f98419cffff11016c5d00006ffdffffa3b7ff473e481572396151b8" ..
  "9228e6a38607f9eee41e82d32fc53a3c014bb17ec98a8a4d2fa30dd97fa6e38c231153e05918c5758ae277f8b6947f0c" ..
  "6ac0de744964e2e95c53b204d8f7440cab5f0d6d46e9e5c37688b79657acb64de1691d6ffb4b88106c42cb883f5c008f" ..
  "d04eaf262894711f3d8f24e1709ea7235fec28cb85d195988a7e2a91f22775f719c006984d98fdd8afd5900fc42553f8" ..
  "f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfc" ..
  "fb522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093f8717859f80b" ..
  "cdff9528460fa9fc7cdefb9a302e56c08f85f38381c065c42553f8f591363105a5b0ee6fc1704d470cd19111aaad601d" ..
  "baceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd533df82964093b80cb2a" ..
  "6cdfb53bf0c4bc4827e6589fff10012b00ec7353a7fdbeae7c311a9fb78d316e709ea7235fec28cb85d195988a7e2a91" ..
  "f22775f719c006984d98fdd8afd5900fc42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c59" ..
  "86e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd" ..
  "2e5faa0f3e4b664290130eff1093f8717859f80bcdff9528460fa9fc7cdefb9a302e56c08f85f38381c065c42553f8f5" ..
  "91363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb" ..
  "522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093f8717859f80bcd" ..
  "ff9528460fa9fc7cdefb9a302e56c08f85f38381c065c425510f3fb29fff10012b00ec7353a7fdbeae7c311a9fb78d31" ..
  "6e709ea7235fec28cb85d195988a7e2a91f22775f719c006984d98fdd8afd5900fc42553f8f591363105a5b0ee6fc170" ..
  "4d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd" ..
  "533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093f8717859f80bcdff9528460fa9fc7cdefb" ..
  "9a302e56c08f85f38381c065c42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e96652" ..
  "58bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f" ..
  "3e4b664290130eff1093f8717859f80bcdff9528460fa9fc7cdefb9a302e56c08f85f38381c065c425510f3fb29fff10" ..
  "012b00ec7353a7fdbeae7c311a9fb78d316e709ea7235fec28cb85d195988a7e2a91f22775f719c006984d98fdd8afd5" ..
  "900fc42553f8f591363105a5b0ee6fc1704d470cd19111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b05" ..
  "08f9c7daadfcfb522b74cd1e5b2042f9dd533df82964093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093" ..
  "f8717859f80bcdff9528460fa9fc7cdefb9a302e56c08f85f38381c065c42553f8f591363105a5b0ee6fc1704d470cd1" ..
  "9111aaad601dbaceb127185c5986e9665258bee976ac59e4e55b0508f9c7daadfcfb522b74cd1e5b2042f9dd533df829" ..
  "64093b80cb2a6cdfb53bf0c4bd2e5faa0f3e4b664290130eff1093f8717859f80bcdff9528460fa9fc7cdefb9a302e56" ..
  "c08f85f38381c065c425510f3fb28003ba0005007b61f7ef0000000045bcd21a0001a20a80808004708db3ed3e300d8b" ..
  "020000000001595a"))

-- The same 8 MiB of NULs as `bzip2 -9` writes it: 48 bytes.
local bz2_bomb = assert(Codec.unhex("425a6839314159265359a23d4b580040404080c00000040008200030cc0529a60100d8808078bb9229c2848511ea5ac0"))

local hello_gz = "\31\139\8\0\0\0\0\0\2\3\203\72\205\201\201\215\81\72\206\47\206\205\76\86\4\0\92\110\87\198\14\0\0\0"
local hello_bz2 = "\66\90\104\57\49\65\89\38\83\89\153\84\167\133\0\0\3\17\128\96\4\10\102\136\0\32\0\34\0\30\160\128\105\166\135\131\39\44\211\152\60\93\201\20\225\66\66\101\82\158\20"
local hello_xz = "\253\55\122\88\90\0\0\4\230\214\180\70\2\0\33\1\28\0\0\0\16\207\88\204\1\0\13\104\101\108\108\111\44\32\99\111\115\109\105\99\33\0\0\0\195\231\225\101\211\83\88\122\0\1\38\14\8\27\224\4\31\182\243\125\1\0\0\0\0\4\89\90"

local type Maker = function(): Compress.Stream

local function gzip_decoder(): Compress.Stream return (assert(Compress.inflater("gzip"))) end
local function bz2_decoder(): Compress.Stream return (assert(Compress.bz2_decoder())) end
local function xz_decoder(): Compress.Stream return (assert(Compress.xz_decoder())) end

-- Feeds `data` in one update and drains it the way the contract asks,
-- asserting no call returns more than `max` bytes. Returns the whole
-- output, and what `finish` alone gave.
local function drain(stream: Compress.Stream, data: string, max: integer): string, string
  local parts: {string} = {}
  local out = assert(stream:update(data, max))
  while true do
    assert(#out <= max, #out .. " bytes from one update, limit " .. max)
    parts[#parts + 1] = out
    if not stream:pending() then break end
    out = assert(stream:update("", max))
  end
  local last = assert(stream:finish())
  parts[#parts + 1] = last
  return table.concat(parts), last
end

local function test_a_decompression_bomb_comes_out_in_bounded_pieces()
  local zeros = string.rep("\0", 8 << 20)
  local cases: {{string, Maker}} = {
    { xz_bomb, xz_decoder },
    { bz2_bomb, bz2_decoder },
  }
  local formats: {Compress.Format} = { "raw", "zlib", "gzip" }
  for _, format in ipairs(formats) do
    local enc = assert(Compress.deflater(format, 9))
    local packed = assert(enc:update(zeros)) .. assert(enc:finish())
    assert(#packed < 16 * 1024, format .. " packed to " .. #packed)
    cases[#cases + 1] = { packed, function(): Compress.Stream
      return (assert(Compress.inflater(format)))
    end }
  end
  for _, case in ipairs(cases) do
    local out, tail = drain(case[2](), case[1], 1 << 20)
    assert(out == zeros, tostring(#out))
    assert(tail == "", "a drained stream left " .. #tail .. " bytes for finish")
    -- The default limit bounds a plain update too.
    local first = assert(case[2]():update(case[1]))
    assert(#first == 1 << 20, tostring(#first))
  end
end

local function test_a_tiny_output_limit_still_decodes_everything()
  local plain = string.rep("the quick brown fox jumps over the lazy dog. ", 300)
  local formats: {Compress.Format} = { "raw", "zlib", "gzip" }
  for _, format in ipairs(formats) do
    local enc = assert(Compress.deflater(format))
    local packed = assert(enc:update(plain)) .. assert(enc:finish())
    local dec = assert(Compress.inflater(format))
    assert(drain(dec, packed, 7) == plain, format)
    assert(dec:done())
  end
  assert(drain(xz_decoder(), hello_xz, 3) == "hello, cosmic!")
  assert(drain(bz2_decoder(), hello_bz2, 3) == "hello, cosmic!")
end

local function test_finish_refuses_while_output_is_pending()
  -- finish would otherwise hand over the whole held-back expansion at
  -- once: it raises instead, and the stream stays usable.
  local cases: {{string, Maker}} = {
    { bz2_bomb, bz2_decoder },
    { xz_bomb, xz_decoder },
  }
  for _, case in ipairs(cases) do
    local dec = case[2]()
    local total = #assert(dec:update(case[1], 1024))
    assert(dec:pending())
    local ok, why = pcall(dec.finish, dec)
    assert(not ok and tostring(why):find("pending", 1, true), tostring(why))
    while dec:pending() do total = total + #assert(dec:update("", 1 << 20)) end
    local last = assert(dec:finish())
    assert(last == "" and total == 8 << 20, tostring(total))
  end
end

local function test_every_success_carries_an_empty_error()
  local constructors: {function(): Compress.Stream | nil, string} = {
    function(): Compress.Stream | nil, string return Compress.inflater("gzip") end,
    function(): Compress.Stream | nil, string return Compress.deflater("gzip") end,
    function(): Compress.Stream | nil, string return Compress.xz_decoder() end,
    function(): Compress.Stream | nil, string return Compress.bz2_decoder() end,
  }
  for _, construct in ipairs(constructors) do
    local s, trouble = construct()
    assert(s ~= nil and trouble == "", trouble)
  end
  local enc, etrouble = Compress.deflater("gzip")
  assert(enc ~= nil and etrouble == "")
  local body, utrouble = enc:update("hello, cosmic!")
  assert(body ~= nil and utrouble == "")
  local tail, ftrouble = enc:finish()
  assert(tail ~= nil and ftrouble == "")
  local dec = gzip_decoder()
  local out, dtrouble = dec:update(body .. tail)
  assert(out == "hello, cosmic!" and dtrouble == "", dtrouble)
  local last, ltrouble = dec:finish()
  assert(last == "" and ltrouble == "", ltrouble)
end

-- Each kind of stream, freshly made, and a first chunk for it.
local function every_kind(): {{Compress.Stream, string}}
  return {
    { gzip_decoder(), hello_gz },
    { bz2_decoder(), hello_bz2 },
    { xz_decoder(), hello_xz },
    { (assert(Compress.inflater("zlib"))), "x\156\203" },
    { (assert(Compress.deflater("gzip"))), "hello" },
  }
end

local record Holder
  s: Compress.Stream
end

local function test_a_stream_revived_by_a_finalizer_is_finished()
  for _, case in ipairs(every_kind()) do
    local saved: Compress.Stream
    local holder: Holder = setmetatable({} as Holder, {
      __gc = function(self: Holder) saved = self.s end,
    } as metatable<Holder>)
    holder.s = case[1]
    -- The stream is collected in the same cycle as the table whose
    -- finalizer hands it back; before it was left "closed", this
    -- update read freed codec state.
    case[1] = nil
    holder = nil
    collectgarbage()
    collectgarbage()
    assert(saved ~= nil, "the finalizer ran")
    local ok, why = pcall(saved.update, saved, case[2])
    assert(not ok and tostring(why):find("finished", 1, true), tostring(why))
    assert(not pcall(saved.finish, saved))
    assert(not saved:pending())
    assert(saved:rest() == "")
  end
end

local function test_a_closed_stream_is_finished_and_keeps_rest()
  do
    local dec <close> = gzip_decoder()
    assert(dec:update(hello_gz .. "TRAILER") == "hello, cosmic!")
  end
  local kept: Compress.Stream
  do
    local dec <close> = gzip_decoder()
    kept = dec
    assert(dec:update(hello_gz .. "TRAILER") == "hello, cosmic!")
  end
  assert(kept:rest() == "TRAILER" and kept:done())
  assert(not pcall(kept.update, kept, ""))
  assert(not pcall(kept.finish, kept))
  -- Closing a finished stream, or closing twice, is harmless.
  for _, case in ipairs(every_kind()) do
    local s <close> = case[1]
    local closer = getmetatable(s as {any: any}).__close as function(any, any)
    closer(s, nil)
    closer(s, nil)
  end
end

local function test_a_raise_inside_update_leaves_the_stream_finished()
  -- Only the checked core can refuse an allocation, which is what makes
  -- a luaL_Buffer raise in the middle of a decode.
  local testing = require("cosmic.internal.testing")
  if testing.configuration ~= "sanitized" then return end
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

local function test_input_after_the_limit_queues_behind_the_backlog()
  local dec = gzip_decoder()
  local parts = { assert(dec:update(hello_gz, 2)) }
  assert(dec:pending())
  parts[#parts + 1] = assert(dec:update("trailer", 2))
  while dec:pending() do parts[#parts + 1] = assert(dec:update("", 2)) end
  assert(table.concat(parts) .. assert(dec:finish()) == "hello, cosmic!")
  assert(dec:rest() == "trailer", dec:rest())
end

local function test_xz_empty_updates_are_not_an_error()
  local dec = xz_decoder()
  assert(dec:update(hello_xz:sub(1, 20)))
  assert(dec:update(""))
  assert(dec:update(""))
  assert(dec:update(""))
  local out = assert(dec:update(hello_xz:sub(21)))
  assert(out .. assert(dec:finish()) == "hello, cosmic!")
end

-- Every way of splitting `data` in two gives the same output, the same
-- rest, and a finished, done decoder.
local function every_split(make: Maker, data: string, want: string, rest: string)
  for cut = 0, #data do
    local dec = make()
    local out = assert(dec:update(data:sub(1, cut))) .. assert(dec:update(data:sub(cut + 1)))
    local last, trouble = dec:finish()
    assert(last ~= nil, "cut " .. cut .. ": " .. tostring(trouble))
    assert(out .. last == want, "cut " .. cut)
    assert(dec:rest() == rest, "cut " .. cut .. ": rest " .. dec:rest())
    assert(dec:done())
  end
end

local function test_trailing_bytes_become_rest_however_the_input_is_split()
  -- For each format: a member, and trailers that begin with none of
  -- its magic, with part of it, and with all but its last byte.
  local cases: {{Maker, string, {string}}} = {
    { gzip_decoder, hello_gz, { "TRAILER", "\31\0tar padding", "\31" } },
    { bz2_decoder, hello_bz2, { "TRAILER", "BZh0", "BZ" } },
    { xz_decoder, hello_xz, { "TRAILER", "\253\55\122\88\90\1", "\253\55" } },
  }
  for _, case in ipairs(cases) do
    local make, member = case[1], case[2]
    for _, trailer in ipairs(case[3]) do
      every_split(make, member .. trailer, "hello, cosmic!", trailer)
      every_split(make, member .. member .. trailer, "hello, cosmic!hello, cosmic!", trailer)
    end
    every_split(make, member, "hello, cosmic!", "")
  end
end

local function test_trailing_bytes_in_the_same_chunk_mark_done_at_once()
  local cases: {{Maker, string}} = {
    { gzip_decoder, hello_gz },
    { bz2_decoder, hello_bz2 },
    { xz_decoder, hello_xz },
  }
  for _, case in ipairs(cases) do
    local dec = case[1]()
    assert(dec:update(case[2] .. "TRAILER") == "hello, cosmic!")
    assert(dec:done(), "done after a member and a trailer")
    assert(dec:rest() == "TRAILER")
    assert(dec:update("more") == "")
    assert(dec:rest() == "TRAILERmore")
  end
end

local function test_xz_stream_padding_is_skipped_but_ragged_nuls_are_rest()
  every_split(xz_decoder, hello_xz .. "\0\0\0\0" .. hello_xz .. "\0\0\0\0\0\0\0\0",
    "hello, cosmic!hello, cosmic!", "")
  every_split(xz_decoder, hello_xz .. "\0\0\0\0junk", "hello, cosmic!", "junk")
  every_split(xz_decoder, hello_xz .. "\0\0", "hello, cosmic!", "\0\0")
  local out, trouble = xz_decoder():update(hello_xz .. "\0\0" .. hello_xz)
  assert(out == nil and trouble:find("padding", 1, true), trouble)
end

local function test_xz_memory_limit_is_enforced()
  local out, trouble = assert(Compress.xz_decoder(1024)):update(hello_xz)
  assert(out == nil and trouble == "xz memory limit exceeded", trouble)
  -- hello_xz asks for a 64 MiB dictionary (`xz -9`), which fits in 80 MiB.
  assert(drain(assert(Compress.xz_decoder(80 << 20)), hello_xz, 100) == "hello, cosmic!")
end

local function test_raw_and_zlib_truncation_is_reported_as_truncation()
  local formats: {Compress.Format} = { "raw", "zlib" }
  for _, format in ipairs(formats) do
    local enc = assert(Compress.deflater(format))
    local packed = assert(enc:update(string.rep("abcdefgh", 200))) .. assert(enc:finish())
    for _, cut in ipairs({ 1, 4, #packed // 2 }) do
      local dec = assert(Compress.inflater(format))
      assert(dec:update(packed:sub(1, #packed - cut)))
      local last, trouble = dec:finish()
      assert(last == nil and trouble == "truncated compressed stream",
        format .. ": " .. tostring(trouble))
    end
    local _, trouble = assert(Compress.inflater(format)):finish()
    assert(trouble == "truncated compressed stream", trouble)
  end
end

local function test_the_first_member_must_carry_the_magic()
  local cases: {{Maker, string}} = {
    { gzip_decoder, "not a gzip stream" },
    { bz2_decoder, "not a bzip2 stream" },
    { xz_decoder, "not an xz stream" },
  }
  for _, case in ipairs(cases) do
    local out, trouble = case[1]():update("TRAILER")
    assert(out == nil and trouble == case[2], trouble)
  end
  -- A partial magic and nothing else is a truncated stream.
  local dec = gzip_decoder()
  assert(dec:update("\31"))
  local _, trouble = dec:finish()
  assert(trouble == "truncated gzip stream", trouble)
end

local function test_argument_shape_errors_raise()
  assert(not pcall(Compress.inflater, "brotli" as Compress.Format))
  assert(not pcall(Compress.deflater, "brotli" as Compress.Format))
  assert(not pcall(Compress.deflater, "raw", 11))
  assert(not pcall(Compress.deflater, "raw", -1))
  assert(not pcall(Compress.xz_decoder, 0))
  assert(not pcall(Compress.crc32, "x", -1))
  assert(not pcall(Compress.crc32, "x", 1 << 32))
  local dec = assert(Compress.inflater("raw"))
  assert(not pcall(dec.update, dec, "x", 0))
  assert((Compress.deflater("raw", 0)))
  assert((Compress.deflater("raw", 10)))
end

local function test_a_failed_stream_throws_afterward()
  local dec = bz2_decoder()
  assert(dec:update("garbage") == nil)
  assert(not pcall(dec.update, dec, ""))
  assert(not pcall(dec.finish, dec))
end

local function test_one_shot_deflate_and_inflate_round_trip()
  local plain = string.rep("cosmic one-shot ", 1000)
  local packed = assert(Compress.deflate("zlib", plain, 9))
  assert(#packed < #plain)
  assert(Compress.inflate("zlib", packed) == plain)
  assert(Compress.inflate("zlib", packed, #plain) == plain)
  local out, trouble = Compress.inflate("zlib", packed, #plain - 1)
  assert(out == nil and trouble:find("larger than", 1, true), trouble)
  out, trouble = Compress.inflate("zlib", packed .. "x")
  assert(out == nil and trouble:find("trailing", 1, true), trouble)
  out, trouble = Compress.inflate("zlib", packed:sub(1, -2))
  assert(out == nil and trouble == "truncated compressed stream", trouble)
  assert(Compress.inflate("zlib", (assert(Compress.deflate("zlib", "")))) == "")
end

--- Each one-shot call frames its bytes as `format` says, the same
--- framing the streaming codec for that format writes and reads.
local function test_one_shot_deflate_frames_as_its_format_says()
  local plain = string.rep("framed ", 200)
  local gz = assert(Compress.deflate("gzip", plain))
  assert(gz:sub(1, 2) == "\31\139", "no gzip magic")
  local raw = assert(Compress.deflate("raw", plain))
  local zl = assert(Compress.deflate("zlib", plain))
  assert(zl:byte(1) & 0x0F == 8, "no zlib header")
  for format, packed in pairs({ gzip = gz, raw = raw, zlib = zl } as {Compress.Format: string}) do
    assert(Compress.inflate(format, packed) == plain, format)
    local dec = assert(Compress.inflater(format))
    local out = assert(dec:update(packed))
    assert(out .. assert(dec:finish()) == plain, format)
  end
  -- A framing is not guessed: zlib bytes are neither a raw deflate
  -- stream nor a gzip one.
  assert(Compress.inflate("raw", zl) == nil)
  assert(Compress.inflate("gzip", zl) == nil)
  assert(not pcall(Compress.deflate, "lz4" as Compress.Format, plain))
end

--- Without a level, the one-shot deflate compresses as a streaming
--- deflater does without one.
local function test_one_shot_deflate_defaults_to_the_deflater_level()
  local plain = ("the quick brown fox jumps over the lazy dog "):rep(400) ..
    string.rep("0123456789", 300)
  local enc = assert(Compress.deflater("zlib"))
  local streamed = assert(enc:update(plain)) .. assert(enc:finish())
  assert(Compress.deflate("zlib", plain) == streamed)
end

--- A query's `deflate(X)` and `inflate(X)` speak the same raw deflate
--- `Compress` does, byte for byte, so the build can store text with one
--- and any reader decode it with the other; and `inflate` refuses a
--- stream that is damaged, cut short, or followed by more bytes, rather
--- than answering with part of one.
-- TODO: `inflate` refuses a stream that decodes past SQLite's length
-- limit, which no test reaches: a handle cannot lower that limit from
-- Teal. Test it once cosmic.sqlite carries sqlite3_limit.
local function test_sql_deflate_and_inflate_speak_raw_deflate()
  local db = assert(Sqlite.memory())
  local text = string.rep("the quick brown fox jumps over the lazy dog\n", 200)
  for _, input in ipairs({ text, "", "x" }) do
    local rows = assert(Sqlite.rows(db,
      "SELECT deflate(?1), inflate(deflate(?1))", { { text = input } }))
    local stored = rows[1][1].blob
    assert(stored == assert(Compress.deflate("raw", input)),
      "SQL and Compress deflate alike")
    assert(assert(Compress.inflate("raw", stored)) == input)
    assert(rows[1][2].kind == "blob" and rows[1][2].blob == input)
    local back = assert(Sqlite.rows(db, "SELECT inflate(?1)",
      { { blob = assert(Compress.deflate("raw", input)) } }))
    assert(back[1][1].blob == input, "SQL inflates what Compress deflated")
  end
  assert(#assert(Compress.deflate("raw", text)) < #text // 10)
  local nulls = assert(Sqlite.text_rows(db,
    "SELECT deflate(NULL) IS NULL, inflate(NULL) IS NULL"))
  assert(nulls[1][1] == "1" and nulls[1][2] == "1")
  local stream = assert(Compress.deflate("raw", text))
  for _, case in ipairs({
    { stream:sub(1, #stream - 4), "the deflate stream is truncated" },
    { stream .. "\0", "the deflate stream is followed by more bytes" },
    { "\xff\xff\xff\xff", "the deflate stream is damaged" },
  }) do
    local rows, trouble = Sqlite.rows(db, "SELECT inflate(?1)", { { blob = case[1] } })
    assert(rows == nil, case[2])
    assert(trouble:find(case[2], 1, true) ~= nil, trouble)
  end
  assert(db:close())
end
