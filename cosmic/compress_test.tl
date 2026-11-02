--- Proves the streaming codecs round-trip, decode published vectors,
--- and refuse corrupt or truncated input rather than answering with
--- something wrong.

local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

local formats: {Compress.Format} = { "raw", "zlib", "gzip" }

-- Feeds `data` through `stream` in pieces of `size` bytes (the whole of
-- it in one piece when `size` is nil), draining each piece's held
-- output, collecting every update's output plus finish's, and returns
-- it with the error `finish` gives, if any.
local function drive(stream: Compress.Stream, data: string, size?: integer): string, string
  local parts: mut {string} = {}
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
  assert(out == plain, format .. ": " .. tostring(#out) .. " vs " .. tostring(#plain))
  assert(dec:done())
end

local function test_raw_zlib_gzip_roundtrip_many_small_chunks()
  local plain = string.rep("the quick brown fox jumps over the lazy dog. ", 500)
  for _, format in ipairs(formats) do
    roundtrip(format, plain, 7)
  end
end

local function test_raw_zlib_gzip_roundtrip_one_big_chunk()
  -- 8 MB of semi-compressible data: large enough that the codec cannot
  -- know its size up front and must stream through its output buffer
  -- more than once.
  local piece = string.rep("cosmic ", 97) .. "\0\1\2\3"
  local plain = string.rep(piece, (8 * 1024 * 1024) // #piece + 1)
  for _, format in ipairs(formats) do
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

-- A gzip member whose deflate body is a dynamic block with no codes at
-- all: every code-length code's length is zero, so every literal's is
-- too. tinfl decoded that as literal 0 of zero bits, forever, from
-- these bytes (the head of the input a fuzz run of cosmic.archive
-- found). The zeros after the block's first bytes are input to spare,
-- so the decoder takes its fast path rather than waiting for more.
local NO_CODES_GZIP <const> = "\31\139\8\0\0\0\0\0\0\255\237\211" .. string.rep("\0", 12)

-- A raw deflate dynamic block whose literal/length table holds one
-- code, end-of-block's, one bit long: `0` ends the block, `1` is no
-- code at all. This is the block's header and tables; the byte after
-- it holds the data: "\31" a well-formed empty block, "\95" the `1`.
local EOB_ONLY <const> = "\5\224\129\8\0\0\0\0\32\248\91"

local function test_a_block_with_no_codes_is_refused_rather_than_decoded_forever()
  for _, format in ipairs({ "gzip", "raw" } as {Compress.Format}) do
    local bytes = format == "gzip" and NO_CODES_GZIP or NO_CODES_GZIP:sub(11)
    local dec = assert(Compress.inflater(format))
    -- One update is enough: before, it answered a full megabyte of
    -- zeros, and every update after it another.
    local out, trouble = dec:update(bytes)
    assert(out == nil and trouble == "compress: corrupt compressed data", format .. ": " .. tostring(out and #out))
    local one_shot, why = Compress.inflate(format, bytes)
    assert(one_shot == nil and why ~= "", format)
  end
end

local function test_bits_that_name_no_code_are_refused()
  -- The one code the table holds decodes.
  local dec = assert(Compress.inflater("raw"))
  local out, trouble = drive(dec, EOB_ONLY .. "\31")
  assert(out == "" and trouble == "", trouble)
  -- The bits no code has, followed by 8 bytes (read on the fast
  -- path), 2 or 3 (the slow path, which has enough to decode with), or
  -- none: then the decoder waits for more, and `finish` finds the stream
  -- cut short. One update each, so a decoder answering zeros for them
  -- fails here rather than looping.
  local record Case
    tail: string
    want: string
  end
  local cases: {Case} = {
    { tail = string.rep("\0", 8), want = "compress: corrupt compressed data" },
    { tail = string.rep("\0", 2), want = "compress: corrupt compressed data" },
    { tail = string.rep("\0", 3), want = "compress: corrupt compressed data" },
    { tail = "", want = "truncated" },
  }
  for _, case in ipairs(cases) do
    local tail, want = case.tail, case.want
    dec = assert(Compress.inflater("raw"))
    out, trouble = dec:update(EOB_ONLY .. "\95" .. tail)
    if out ~= nil then
      assert(out == "" and not dec:pending(), tostring(#tail) .. ": " .. tostring(#out) .. " bytes out")
      out, trouble = dec:finish()
    end
    -- The patch's own words, not the ratio check's, which would also
    -- stop a decoder answering zeros, but only after a window of them.
    assert(out == nil and (trouble == want or want == "truncated" and trouble:find(want, 1, true) ~= nil),
      tostring(#tail) .. ": " .. trouble)
  end
end

--- Every piece of `packed` fed through `dec`, `size` bytes at a time,
--- counting what comes out rather than keeping it: the bytes out, or
--- nil and why not.
local function count_out(dec: Compress.Stream, packed: string, size: integer): integer?, string
  local total = 0
  for pos = 1, #packed, size do
    local piece = packed:sub(pos, pos + size - 1)
    repeat
      local out, trouble = dec:update(piece)
      if out == nil then return nil, trouble end
      total = total + #out
      piece = ""
    until not dec:pending()
  end
  local last, trouble = dec:finish()
  if last == nil then return nil, trouble end
  return total + #last, ""
end

local function test_the_ratio_check_passes_deflates_most_compressible_stream()
  -- Zeros at level 9 come near deflate's largest ratio (1032 to 1),
  -- which inflate_step refuses to pass; whole and a byte at a time, so
  -- tinfl's read-ahead meets the check at every split.
  local size = 100 << 20
  for _, format in ipairs({ "raw", "gzip" } as {Compress.Format}) do
    local enc = assert(Compress.deflater(format, 9))
    local parts: mut {string} = {}
    local zeros = string.rep("\0", 1 << 20)
    for _ = 1, size >> 20 do parts[#parts + 1] = assert(enc:update(zeros)) end
    parts[#parts + 1] = assert(enc:finish())
    local packed = table.concat(parts)
    assert(#packed * 1000 < size, format .. " packed to " .. tostring(#packed))
    for _, piece in ipairs({ #packed, 1 }) do
      local total, trouble = count_out(assert(Compress.inflater(format)), packed, piece)
      assert(total == size, format .. " in pieces of " .. tostring(piece) .. ": " .. tostring(total) .. " " .. trouble)
    end
  end
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
-- member and trailer rules the four multi-member decoders share.

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
-- `printf 'hello, cosmic!' | zstd -c`: one frame, its content's checksum
-- in the last four bytes.
local hello_zst = "\40\181\47\253\4\88\113\0\0\104\101\108\108\111\44\32\99\111\115\109\105\99\33\150\176\201\168"

-- The same 8 MiB of NULs as `zstd -19` writes it: 274 bytes.
local zstd_bomb = assert(Codec.unhex(
  "28b52ffd04684c000008000100fcff391002020010000200100002001000020010000200100002001000020010000200" ..
    "100002001000020010000200100002001000020010000200100002001000020010000200100002001000020010000200" ..
    "100002001000020010000200100002001000020010000200100002001000020010000200100002001000020010000200" ..
    "100002001000020010000200100002001000020010000200100002001000020010000200100002001000020010000200" ..
    "100002001000020010000200100002001000020010000200100002001000020010000200100002001000020010000200" ..
    "1000020010000200100002001000020010000200100002001000030010000fdff661"))

local type Maker = function(): Compress.Stream

--- A compressed bomb and the decoder that opens it.
local record Bomb
  packed: string
  make: Maker
end

local function gzip_decoder(): Compress.Stream return (assert(Compress.inflater("gzip"))) end
local function bz2_decoder(): Compress.Stream return (assert(Compress.bz2_decoder())) end
local function xz_decoder(): Compress.Stream return (assert(Compress.xz_decoder())) end
local function zstd_decoder(): Compress.Stream return (assert(Compress.zstd_decoder())) end

-- Feeds `data` in one update and drains it the way the contract asks,
-- asserting no call returns more than `max_bytes` bytes. Returns the whole
-- output, and what `finish` alone gave.
local function drain(stream: Compress.Stream, data: string, max_bytes: integer): string, string
  local parts: mut {string} = {}
  local out = assert(stream:update(data, max_bytes))
  while true do
    assert(#out <= max_bytes, tostring(#out) .. " bytes from one update, limit " .. tostring(max_bytes))
    parts[#parts + 1] = out
    if not stream:pending() then break end
    out = assert(stream:update("", max_bytes))
  end
  local last = assert(stream:finish())
  parts[#parts + 1] = last
  return table.concat(parts), last
end

local function test_a_decompression_bomb_comes_out_in_bounded_pieces()
  local zeros = string.rep("\0", 8 << 20)
  local cases: mut {Bomb} = {
    { packed = xz_bomb, make = xz_decoder },
    { packed = bz2_bomb, make = bz2_decoder },
    { packed = zstd_bomb, make = zstd_decoder },
  }
  for _, format in ipairs(formats) do
    local enc = assert(Compress.deflater(format, 9))
    local packed = assert(enc:update(zeros)) .. assert(enc:finish())
    assert(#packed < 16 * 1024, format .. " packed to " .. tostring(#packed))
    cases[#cases + 1] = { packed = packed, make = function(): Compress.Stream
      return (assert(Compress.inflater(format)))
    end }
  end
  for _, case in ipairs(cases) do
    local out, tail = drain(case.make(), case.packed, 1 << 20)
    assert(out == zeros, tostring(#out))
    assert(tail == "", "a drained stream left " .. tostring(#tail) .. " bytes for finish")
    -- The default limit bounds a plain update too.
    local first = assert(case.make():update(case.packed))
    assert(#first == 1 << 20, tostring(#first))
  end
end

local function test_a_tiny_output_limit_still_decodes_everything()
  local plain = string.rep("the quick brown fox jumps over the lazy dog. ", 300)
  for _, format in ipairs(formats) do
    local enc = assert(Compress.deflater(format))
    local packed = assert(enc:update(plain)) .. assert(enc:finish())
    local dec = assert(Compress.inflater(format))
    assert(drain(dec, packed, 7) == plain, format)
    assert(dec:done())
  end
  assert(drain(xz_decoder(), hello_xz, 3) == "hello, cosmic!")
  assert(drain(bz2_decoder(), hello_bz2, 3) == "hello, cosmic!")
  assert(drain(zstd_decoder(), hello_zst, 3) == "hello, cosmic!")
end

local function test_finish_refuses_while_output_is_pending()
  -- finish would otherwise hand over the whole held-back expansion at
  -- once: it raises instead, and the stream stays usable.
  local cases: {Bomb} = {
    { packed = bz2_bomb, make = bz2_decoder },
    { packed = xz_bomb, make = xz_decoder },
    { packed = zstd_bomb, make = zstd_decoder },
  }
  for _, case in ipairs(cases) do
    local dec = case.make()
    local total = #assert(dec:update(case.packed, 1024))
    assert(dec:pending())
    Test.raises(function() dec:finish() end, "pending")
    while dec:pending() do total = total + #assert(dec:update("", 1 << 20)) end
    local last = assert(dec:finish())
    assert(last == "" and total == 8 << 20, tostring(total))
  end
end

local function test_every_success_carries_an_empty_error()
  local constructors: {function(): Compress.Stream?, string} = {
    function(): Compress.Stream?, string return Compress.inflater("gzip") end,
    function(): Compress.Stream?, string return Compress.deflater("gzip") end,
    function(): Compress.Stream?, string return Compress.xz_decoder() end,
    function(): Compress.Stream?, string return Compress.bz2_decoder() end,
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
local record Kind
  mut stream: Compress.Stream
  chunk: string
end

local function every_kind(): {Kind}
  return {
    { stream = gzip_decoder(), chunk = hello_gz },
    { stream = bz2_decoder(), chunk = hello_bz2 },
    { stream = xz_decoder(), chunk = hello_xz },
    { stream = (assert(Compress.inflater("zlib"))), chunk = "x\156\203" },
    { stream = (assert(Compress.deflater("gzip"))), chunk = "hello" },
  }
end

local record Holder
  mut s: Compress.Stream
end

local function test_a_stream_revived_by_a_finalizer_is_finished()
  for _, case in ipairs(every_kind()) do
    local saved: Compress.Stream? = nil
    local holder: Holder = setmetatable({} as Holder, {
      __gc = function(self: Holder) saved = self.s end,
    } as metatable<Holder>)
    holder.s = case.stream
    -- The stream is collected in the same cycle as the table whose
    -- finalizer hands it back: an update on it must not read freed
    -- codec state.
    case.stream = nil
    holder = nil
    collectgarbage()
    collectgarbage()
    local kept = assert(saved, "the finalizer ran")
    Test.raises(function() kept:update(case.chunk) end, "compress: the stream is finished")
    assert(not pcall(kept.finish, kept))
    assert(not kept:pending())
    assert(kept:rest() == "")
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
    local s <close> = case.stream
    local closer = getmetatable(s as {any: any}).__close as function(any, any)
    closer(s, nil)
    closer(s, nil)
  end
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
    assert(last ~= nil, "cut " .. tostring(cut) .. ": " .. tostring(trouble))
    assert(out .. last == want, "cut " .. tostring(cut))
    assert(dec:rest() == rest, "cut " .. tostring(cut) .. ": rest " .. dec:rest())
    assert(dec:done())
  end
end

local function test_trailing_bytes_become_rest_however_the_input_is_split()
  -- For each format: a member, and trailers that begin with none of
  -- its magic, with part of it, and with all but its last byte.
  local record Member
    make: Maker
    member: string
    trailers: {string}
  end
  local cases: {Member} = {
    { make = gzip_decoder, member = hello_gz, trailers = { "TRAILER", "\31\0tar padding", "\31" } },
    { make = bz2_decoder, member = hello_bz2, trailers = { "TRAILER", "BZh0", "BZ" } },
    { make = xz_decoder, member = hello_xz, trailers = { "TRAILER", "\253\55\122\88\90\1", "\253\55" } },
    { make = zstd_decoder, member = hello_zst, trailers = { "TRAILER", "\40\181\47\0", "\40\181\47", "\80\42\77" } },
  }
  for _, case in ipairs(cases) do
    local make, member = case.make, case.member
    for _, trailer in ipairs(case.trailers) do
      every_split(make, member .. trailer, "hello, cosmic!", trailer)
      every_split(make, member .. member .. trailer, "hello, cosmic!hello, cosmic!", trailer)
    end
    every_split(make, member, "hello, cosmic!", "")
  end
end

local function test_trailing_bytes_in_the_same_chunk_mark_done_at_once()
  local record Member
    make: Maker
    member: string
  end
  local cases: {Member} = {
    { make = gzip_decoder, member = hello_gz },
    { make = bz2_decoder, member = hello_bz2 },
    { make = xz_decoder, member = hello_xz },
    { make = zstd_decoder, member = hello_zst },
  }
  for _, case in ipairs(cases) do
    local dec = case.make()
    assert(dec:update(case.member .. "TRAILER") == "hello, cosmic!")
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
  assert(out == nil and trouble == "compress: xz memory limit exceeded", trouble)
  -- hello_xz asks for a 64 MiB dictionary (`xz -9`), which fits in 80 MiB.
  assert(drain(assert(Compress.xz_decoder(80 << 20)), hello_xz, 100) == "hello, cosmic!")
end

local function test_raw_and_zlib_truncation_is_reported_as_truncation()
  local stream_formats: {Compress.Format} = { "raw", "zlib" }
  for _, format in ipairs(stream_formats) do
    local enc = assert(Compress.deflater(format))
    local packed = assert(enc:update(string.rep("abcdefgh", 200))) .. assert(enc:finish())
    for _, cut in ipairs({ 1, 4, #packed // 2 }) do
      local dec = assert(Compress.inflater(format))
      assert(dec:update(packed:sub(1, #packed - cut)))
      local last, trouble = dec:finish()
      assert(last == nil and trouble == "compress: truncated compressed stream",
        format .. ": " .. tostring(trouble))
    end
    local _, trouble = assert(Compress.inflater(format)):finish()
    assert(trouble == "compress: truncated compressed stream", trouble)
  end
end

local function test_the_first_member_must_carry_the_magic()
  local record Refusal
    make: Maker
    trouble: string
  end
  local cases: {Refusal} = {
    { make = gzip_decoder, trouble = "compress: not a gzip stream" },
    { make = bz2_decoder, trouble = "compress: not a bzip2 stream" },
    { make = xz_decoder, trouble = "compress: not an xz stream" },
    { make = zstd_decoder, trouble = "compress: not a zstd stream" },
  }
  for _, case in ipairs(cases) do
    local out, trouble = case.make():update("TRAILER")
    assert(out == nil and trouble == case.trouble, trouble)
  end
  -- A partial magic and nothing else is a truncated stream.
  local dec = gzip_decoder()
  assert(dec:update("\31"))
  local _, trouble = dec:finish()
  assert(trouble == "compress: truncated gzip stream", trouble)
end

local function test_argument_shape_errors_raise()
  assert(not pcall(Compress.inflater, "brotli" as Compress.Format))
  assert(not pcall(Compress.deflater, "brotli" as Compress.Format))
  assert(not pcall(Compress.deflater, "raw", 11))
  assert(not pcall(Compress.deflater, "raw", -1))
  assert(not pcall(Compress.xz_decoder, 0))
  local low_window, _ = pcall(Compress.zstd_decoder, 1023)
  assert(not low_window)
  local low_level, _ = pcall(Compress.zstd_encoder, 0)
  assert(not low_level)
  local high_level, _ = pcall(Compress.zstd_encoder, 20)
  assert(not high_level)
  assert((Compress.zstd_decoder(1024)))
  assert((Compress.zstd_encoder(1)))
  assert((Compress.zstd_encoder(19)))
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
  assert(out == nil and trouble == "compress: truncated compressed stream", trouble)
  assert(Compress.inflate("zlib", (assert(Compress.deflate("zlib", "")))) == "")
end

local function test_inflate_validates_max_bytes()
  local packed = assert(Compress.deflate("zlib", "abc"))
  assert(Compress.inflate("zlib", packed, 3) == "abc")
  local out, trouble = Compress.inflate("zlib", packed, 2)
  assert(out == nil and trouble == "stream: output is larger than 2 bytes", trouble)
  assert(Compress.inflate("zlib", (assert(Compress.deflate("zlib", ""))), 0) == "")
  Test.raises(function() Compress.inflate("zlib", packed, -1) end, "compress: max_bytes")
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
    local stored = rows[1]:blob(1)
    assert(stored == assert(Compress.deflate("raw", input)),
      "SQL and Compress deflate alike")
    assert(assert(Compress.inflate("raw", stored)) == input)
    assert(rows[1]:kind(2) == "blob" and rows[1]:blob(2) == input)
    local back = assert(Sqlite.rows(db, "SELECT inflate(?1)",
      { { blob = assert(Compress.deflate("raw", input)) } }))
    assert(back[1]:blob(1) == input, "SQL inflates what Compress deflated")
  end
  assert(#assert(Compress.deflate("raw", text)) < #text // 10)
  local nulls = assert(Sqlite.text_rows(db,
    "SELECT deflate(NULL) IS NULL, inflate(NULL) IS NULL"))
  assert(nulls[1]:text(1) == "1" and nulls[1]:text(2) == "1")
  local stream = assert(Compress.deflate("raw", text))
  for _, case in ipairs({
      { stream:sub(1, #stream - 4), "truncated deflate stream" },
      { stream .. "\0", "the deflate stream is followed by more bytes" },
      { "\xff\xff\xff\xff", "the deflate stream is damaged" },
  }) do
    local rows, trouble = Sqlite.rows(db, "SELECT inflate(?1)", { { blob = case[1] } })
    assert(rows == nil, case[2])
    assert(trouble:find(case[2], 1, true) ~= nil, trouble)
  end
  assert(db:close())
end

local function test_zstd_known_vector_decodes_one_byte_at_a_time()
  -- `printf 'hello, cosmic!' | zstd -c`
  local vector = "\40\181\47\253\4\88\113\0\0\104\101\108\108\111\44\32\99\111\115\109\105\99\33\150\176\201\168"
  local dec = assert(Compress.zstd_decoder())
  local out, trouble = drive(dec, vector, 1)
  assert(trouble == "", trouble)
  assert(out == "hello, cosmic!", out)
  assert(dec:done())
  assert(dec:rest() == "")
end

local function test_zstd_multi_frame_decodes_every_frame()
  -- `printf first | zstd -c` .. `printf second | zstd -c`
  local vector = "\40\181\47\253\4\88\41\0\0\102\105\114\115\116\90\143\190\228" ..
    "\40\181\47\253\4\88\49\0\0\115\101\99\111\110\100\55\0\94\77"
  local sizes: {integer} = { 1, 5 }
  for _, size in ipairs(sizes) do
    local out, trouble = drive(assert(Compress.zstd_decoder()), vector, size)
    assert(trouble == "", trouble)
    assert(out == "firstsecond", out)
  end
end

local function test_zstd_skippable_frames_are_skipped()
  -- A skippable frame: a magic from 0x184D2A50 to 0x184D2A5F, a
  -- little-endian length, and that many bytes, which decode to nothing.
  local skip = "\80\42\77\24\3\0\0\0abc"
  local last = "\95\42\77\24\0\0\0\0"
  local sizes: {integer} = { 1, 7 }
  for _, size in ipairs(sizes) do
    local dec = assert(Compress.zstd_decoder())
    local out, trouble = drive(dec, skip .. hello_zst .. last .. hello_zst, size)
    assert(trouble == "", trouble)
    assert(out == "hello, cosmic!hello, cosmic!", out)
    assert(dec:rest() == "")
  end
  -- A stream of skippable frames alone holds nothing, and is no error.
  local out, trouble = drive(assert(Compress.zstd_decoder()), skip)
  assert(out == "" and trouble == "", trouble)
end

local function test_zstd_frame_without_a_checksum_decodes()
  -- `printf 'hello, cosmic!' | zstd -c --no-check`
  local vector = "\40\181\47\253\0\88\113\0\0\104\101\108\108\111\44\32\99\111\115\109\105\99\33"
  local out, trouble = drive(assert(Compress.zstd_decoder()), vector)
  assert(trouble == "", trouble)
  assert(out == "hello, cosmic!", out)
end

local function test_zstd_corrupt_checksum_is_refused()
  local bad = hello_zst:sub(1, -2) .. string.char((assert(hello_zst:byte(-1)) + 1) % 256)
  local out, trouble = drive(assert(Compress.zstd_decoder()), bad)
  assert(trouble == "compress: corrupt zstd data", trouble)
  assert(out == "", out)
  -- A flipped byte in the content is caught by the same checksum.
  local flipped = hello_zst:sub(1, 9) .. "j" .. hello_zst:sub(11)
  local _, flipped_trouble = drive(assert(Compress.zstd_decoder()), flipped)
  assert(flipped_trouble == "compress: corrupt zstd data", flipped_trouble)
end

local function test_zstd_frame_short_of_its_declared_size_is_corrupt_however_split()
  -- A single-segment frame that declares 72 bytes of content and ends on an
  -- empty last block. zstd checks the size itself only when it decodes the
  -- frame whole or ends it on a block holding data, so the answer used to
  -- depend on how the input was split. Followed by a skippable frame, it
  -- is the same.
  local short = "\40\181\47\253\32\72\1\0\0"
  for _, frame in ipairs({ short, short .. "\80\42\77\24\0\0\0\0" }) do
    for size = 1, #frame do
      local out, trouble = drive(assert(Compress.zstd_decoder()), frame, size)
      assert(trouble == "compress: corrupt zstd data", ("split by %d: %q"):format(size, trouble))
      assert(out == "", out)
    end
  end
  -- Frames that keep their promise decode however they are split: an
  -- empty frame that declares none, and a block of data that declares all.
  local empty = "\40\181\47\253\32\0\1\0\0"
  local one = "\40\181\47\253\32\1\9\0\0x"
  for _, frame in ipairs({ empty, one }) do
    for size = 1, #frame do
      local out, trouble = drive(assert(Compress.zstd_decoder()), frame, size)
      assert(trouble == "", ("split by %d: %q"):format(size, trouble))
      assert(out == (if frame == one then "x" else "" end), out)
    end
  end
  -- What is held of one frame is not carried into the next: a skippable
  -- frame with a payload (whose length zstd reports as its content size),
  -- and a frame that declares no size, each after one that declared 1.
  local record Case
    frames: string
    want: string
  end
  local cases: {Case} = {
    { frames = one .. "\80\42\77\24\4\0\0\0abcd", want = "x" },
    { frames = one .. "\40\181\47\253\0\0\9\0\0y", want = "xy" },
  }
  for _, case in ipairs(cases) do
    for size = 1, #case.frames do
      local out, trouble = drive(assert(Compress.zstd_decoder()), case.frames, size)
      assert(trouble == "", ("split by %d: %q"):format(size, trouble))
      assert(out == case.want, ("split by %d: %q"):format(size, out))
    end
  end
  -- A second frame short of its declared size is corrupt as the first is.
  local twice = one .. short
  for size = 1, #twice do
    local _, trouble = drive(assert(Compress.zstd_decoder()), twice, size)
    assert(trouble == "compress: corrupt zstd data", ("split by %d: %q"):format(size, trouble))
  end
end

local function test_zstd_malformed_frame_header_is_corrupt()
  -- The frame header descriptor's bit 3 is reserved and must be zero:
  -- ZSTD_getFrameHeader refuses the header before any window is judged.
  local reserved = "\40\181\47\253\8\0\0\0\0\0"
  local out, trouble = assert(Compress.zstd_decoder()):update(reserved)
  assert(out == nil and trouble == "compress: corrupt zstd data", tostring(trouble))
end

local function test_zstd_header_window_log_over_the_maximum_is_refused()
  -- A window descriptor of 0xF8 has exponent 31, a window log of 41,
  -- over zstd's maximum: the header parse itself answers windowTooLarge,
  -- which reads as the window message, not as corrupt.
  local huge = "\40\181\47\253\0\248\1\0\0\0"
  local out, trouble = assert(Compress.zstd_decoder()):update(huge)
  assert(out == nil and trouble == "compress: zstd window larger than the limit", tostring(trouble))
end

local function test_zstd_truncated_input_errors_on_finish()
  local cuts: {integer} = { 1, 4, 20 }
  for _, cut in ipairs(cuts) do
    local dec = assert(Compress.zstd_decoder())
    assert(dec:update(hello_zst:sub(1, #hello_zst - cut)))
    local last, trouble = dec:finish()
    assert(last == nil and trouble == "compress: truncated zstd stream", tostring(trouble))
  end
end

local function test_zstd_window_limit_is_enforced()
  -- `printf 'hello, cosmic!' | zstd -c --long=28`: its header asks for a
  -- 256 MiB window, over the default limit of 128 MiB.
  local wide = "\40\181\47\253\4\144\113\0\0\104\101\108\108\111\44\32\99\111\115\109\105\99\33\150\176\201\168"
  local out, trouble = assert(Compress.zstd_decoder()):update(wide)
  assert(out == nil and trouble == "compress: zstd window larger than the limit", trouble)
  assert(drain(assert(Compress.zstd_decoder(1 << 28)), wide, 100) == "hello, cosmic!")
  -- The limit is compared as given, not rounded: 2^28 - 1 refuses 2^28.
  local _, rounded = assert(Compress.zstd_decoder((1 << 28) - 1)):update(wide)
  assert(rounded == "compress: zstd window larger than the limit", rounded)
  -- hello_zst asks for 2 MiB, which 1 MiB refuses.
  local _, small = assert(Compress.zstd_decoder(1 << 20)):update(hello_zst)
  assert(small == "compress: zstd window larger than the limit", small)
end

local function test_zstd_window_limit_holds_for_a_frame_decoded_in_one_pass()
  -- A frame whose header declares a 256 MiB window and 300 bytes of "a":
  -- zstd decodes it whole before it looks at the window, so the limit
  -- is judged from the header, however the bytes arrive.
  local frame = "\40\181\47\253\64\144\44\0\99\9\0\97"
  local refused = "compress: zstd window larger than the limit"
  local _, whole = assert(Compress.zstd_decoder()):update(frame)
  assert(whole == refused, whole)
  local _, bounded = assert(Compress.zstd_decoder()):update(frame, 100)
  assert(bounded == refused, bounded)
  local _, bytewise = drive(assert(Compress.zstd_decoder()), frame, 1)
  assert(bytewise == refused, bytewise)
  assert(drain(assert(Compress.zstd_decoder(1 << 28)), frame, 100) == string.rep("a", 300))
end

local function test_zstd_decoder_survives_many_empty_updates_mid_frame()
  local dec = assert(Compress.zstd_decoder())
  local first = assert(dec:update(hello_zst:sub(1, 10)))
  local parts: mut {string} = { first }
  for _ = 1, 40 do parts[#parts + 1] = assert(dec:update("")) end
  parts[#parts + 1] = assert(dec:update(hello_zst:sub(11)))
  parts[#parts + 1] = assert(dec:finish())
  assert(table.concat(parts) == "hello, cosmic!")
end

local function test_zstd_encoder_writes_what_the_zstd_command_writes()
  -- One frame, its window from the level and no content size (a stream
  -- does not know it), then the checksum: byte for byte the command's.
  local enc = assert(Compress.zstd_encoder())
  assert(assert(enc:update("hello, cosmic!")) .. assert(enc:finish()) == hello_zst)
  -- `zstd -19` differs only in the window its level asks for.
  local enc19 = assert(Compress.zstd_encoder(19))
  local packed = assert(enc19:update("hello, cosmic!")) .. assert(enc19:finish())
  assert(packed == hello_zst:sub(1, 5) .. "\104" .. hello_zst:sub(7), Codec.hex(packed))
end

local function test_zstd_round_trips_at_every_level_and_chunking()
  local noise: mut {string} = {}
  for i = 1, 4096 do noise[i] = string.char((i * 2654435761 >> 13) % 256) end
  local plain = string.rep("the quick brown fox jumps over the lazy dog. ", 2000) .. table.concat(noise)
  local levels: {integer} = { 1, 3, 9, 19 }
  local sizes: {integer} = { 1000, #plain }
  for _, level in ipairs(levels) do
    for _, size in ipairs(sizes) do
      local packed, enc_trouble = drive(assert(Compress.zstd_encoder(level)), plain, size)
      assert(enc_trouble == "", enc_trouble)
      assert(#packed < #plain, tostring(level) .. ": " .. tostring(#packed))
      local dec = assert(Compress.zstd_decoder())
      local out, dec_trouble = drive(dec, packed, size)
      assert(dec_trouble == "", dec_trouble)
      assert(out == plain, tostring(level) .. "/" .. tostring(size) .. ": " .. tostring(#out))
    end
  end
  -- Nothing in is one empty frame out, which decodes to nothing.
  local empty = assert(Compress.zstd_encoder())
  local packed = assert(empty:update("")) .. assert(empty:finish())
  assert(packed:sub(1, 4) == "\40\181\47\253", Codec.hex(packed))
  local out, trouble = drive(assert(Compress.zstd_decoder()), packed)
  assert(out == "" and trouble == "", trouble)
end

local function test_zstd_encoder_output_is_the_same_from_run_to_run()
  local plain = string.rep("reproducible ", 5000)
  local first = assert(Compress.zstd_encoder(12))
  local a = assert(first:update(plain)) .. assert(first:finish())
  local second = assert(Compress.zstd_encoder(12))
  local b = assert(second:update(plain:sub(1, 777))) .. assert(second:update(plain:sub(778))) ..
    assert(second:finish())
  assert(a == b, "the same input and level, split differently, came out differently")
end

local function test_zstd_encoder_throws_after_finish()
  local enc = assert(Compress.zstd_encoder())
  assert(enc:update("x"))
  assert(enc:finish())
  local updated, _ = pcall(enc.update, enc, "y")
  assert(not updated)
  local finished, _ = pcall(enc.finish, enc)
  assert(not finished)
  assert(enc:pending() == false)
end

-- The text `xz -c` was run over to make the digests below: 6000 words of
-- a twelve-word vocabulary from a fixed generator, 33483 bytes.
local function xz_sample(): string
  local words: {string} = { "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota",
    "kappa", "lambda", "mu" }
  local parts: mut {string} = {}
  local x = 12345
  for i = 1, 6000 do
    x = (x * 1103515245 + 12345) % 2147483648
    parts[#parts + 1] = assert(words[(x >> 8) % #words + 1]) .. (if i % 7 == 0 then "\n" else " " end)
  end
  return table.concat(parts)
end

local function xz_encode(plain: string, preset?: integer, opts?: Compress.XzOptions, size?: integer): string
  local packed, trouble = drive(assert(Compress.xz_encoder(preset, opts)), plain, size)
  assert(trouble == "", trouble)
  return packed
end

-- Everything `enc` writes for `data` cut into pieces of `size` bytes.
local function drive_bz2(enc: Compress.Stream, data: string, size?: integer): string
  local packed, trouble = drive(enc, data, size)
  assert(trouble == "", trouble)
  return packed
end

local function xz_decode(packed: string, size?: integer): string
  local dec = assert(Compress.xz_decoder())
  local out, trouble = drive(dec, packed, size)
  assert(trouble == "", trouble)
  assert(dec:done())
  return out
end

-- SHA-256 of `xz -c -<preset>` over xz_sample(), written once by the xz
-- command (5.4.5) and found byte for byte what the vendored liblzma
-- (5.8.4) writes at each preset.
local record XzDigest
  preset: integer
  extreme: boolean
  digest: string
end

local xz_digests: {XzDigest} = {
  { preset = 0, extreme = false, digest = "60043a2d7fb5322f26a19c484cd98eaa529d6fa64c89eab83ef4f772c7c93cf8" },
  { preset = 1, extreme = false, digest = "552a1b79e51063dd67a47790effa3c3bef25dcd75cb194bb1f7b2911220dd4a3" },
  { preset = 2, extreme = false, digest = "b4df7970e3ceb31cc94544e808c275936bd24e2d3d5c661146e7da46075c1865" },
  { preset = 3, extreme = false, digest = "1268f0b70004530c10da991bb3c4f4107f37ea60ad5b393ad85fce4689df49a1" },
  { preset = 4, extreme = false, digest = "ebb4aa35e852588b5b568b9c140e696ce74e406f8112b8f57173913314b68828" },
  { preset = 5, extreme = false, digest = "4e307496cf6a6ac04f85f8a2bb84a5f49192753926fef2649ffb8bd7b6e5812f" },
  { preset = 6, extreme = false, digest = "3ecce4929e0a4f5d206f698ab0abe78a755f4d16d9be4b6bb2f0c91609fd77d0" },
  { preset = 0, extreme = true, digest = "95f4d3684641589829d7176912c6c2bba39a1671936a455ef0fdd88f51cbb52b" },
  { preset = 3, extreme = true, digest = "7716bcef7cf13a3bc61e4b631531462616db0df8fa564479d7030e6077b6c840" },
  { preset = 5, extreme = true, digest = "0a65c82259390bc3839d8ec89f7d430657cf4fd29b15c450bebd8f2adbcd345c" },
}

local function test_xz_encoder_writes_what_the_xz_command_writes()
  local plain = xz_sample()
  assert(Hash.hex_sha256(plain) == "05da26ee65225954f8d39e6d9da87a97ab23490a73b7f31babc548a664d918c0")
  -- Presets 0 to 6 (the memory of 7 to 9 is left out of a test run), and
  -- the extremes that differ in what they change.
  for _, case in ipairs(xz_digests) do
    local packed = xz_encode(plain, case.preset, { extreme = case.extreme })
    assert(Hash.hex_sha256(packed) == case.digest,
      "preset " .. tostring(case.preset) .. (if case.extreme then "e" else "" end) .. ": " .. tostring(#packed) .. " bytes")
  end
  -- The default is `xz`'s, preset 6.
  assert(Hash.hex_sha256(xz_encode(plain)) == "3ecce4929e0a4f5d206f698ab0abe78a755f4d16d9be4b6bb2f0c91609fd77d0")
end

local function test_xz_encoder_empty_input_is_the_empty_stream()
  -- `xz -c </dev/null`: header, an index of no blocks, footer.
  local expected = assert(Codec.unhex(
    "fd377a585a000004e6d6b446000000001cdf44211fb6f37d010000000004595a"))
  local enc = assert(Compress.xz_encoder())
  assert(assert(enc:update("")) .. assert(enc:update("")) .. assert(enc:finish()) == expected)
  assert(xz_decode(expected) == "")
end

local function test_xz_encoder_round_trips_at_presets_and_chunkings()
  local noise: mut {string} = {}
  for i = 1, 4096 do noise[i] = string.char((i * 2654435761 >> 13) % 256) end
  local plain = xz_sample() .. table.concat(noise)
  local presets: {integer} = { 0, 1, 3, 4, 6 }
  local sizes: {integer} = { 100, 1000, #plain }
  for _, preset in ipairs(presets) do
    local whole = xz_encode(plain, preset)
    assert(#whole < #plain, tostring(preset))
    for _, size in ipairs(sizes) do
      -- However the input is split, the stream is the same.
      local packed = if size == #plain then whole else xz_encode(plain, preset, nil, size) end
      assert(packed == whole, "preset " .. tostring(preset) .. ", chunks of " .. tostring(size))
      assert(xz_decode(packed, size) == plain, tostring(preset) .. "/" .. tostring(size))
    end
  end
  -- A byte at a time over the whole input, at the default preset.
  local bytewise = xz_encode(plain, 6, nil, 1)
  assert(bytewise == xz_encode(plain, 6), "chunks of 1")
  assert(xz_decode(bytewise, 1) == plain)
  local extreme = xz_encode(plain, 1, { extreme = true })
  assert(xz_decode(extreme) == plain)
end

local function test_xz_encoder_slides_its_window_past_the_dictionary()
  -- Preset 0's dictionary is 256 KiB; ~600 KB of text drawn from a few
  -- hundred generated words repeats a lot but never exactly, so matches
  -- reach back across the window slide and the position normalisation.
  local syllables: {string} = { "ka", "to", "mi", "re", "su", "lan", "dor", "vex", "pi", "no" }
  local vocab: mut {string} = {}
  local x = 777
  for i = 1, 300 do
    local word: mut {string} = {}
    for _ = 1, 2 + i % 3 do
      x = (x * 1103515245 + 12345) % 2147483648
      word[#word + 1] = assert(syllables[(x >> 9) % #syllables + 1])
    end
    vocab[i] = table.concat(word)
  end
  local parts: mut {string} = {}
  local size = 0
  local n = 0
  while size < 600000 do
    n = n + 1
    x = (x * 1103515245 + 12345) % 2147483648
    local piece = assert(vocab[(x >> 8) % #vocab + 1]) .. (if n % 9 == 0 then "\n" else " " end)
    parts[#parts + 1] = piece
    size = size + #piece
  end
  local plain = table.concat(parts)
  assert(#plain > 2 * 262144)
  local whole = xz_encode(plain, 0)
  assert(#whole < #plain // 2, tostring(#whole))
  for _, chunk in ipairs({ 1000, 65536, 300000, #plain }) do
    assert(xz_decode(whole, chunk) == plain, "decode chunks of " .. tostring(chunk))
    assert(xz_encode(plain, 0, nil, chunk) == whole, "encode chunks of " .. tostring(chunk))
  end
end

local function test_xz_encoder_gives_output_past_one_slice()
  -- Noise does not compress, so the stream is longer than the 64 KiB
  -- slice the encoder is offered output room in: each call loops.
  local noise: mut {string} = {}
  local x = 1
  for i = 1, 300000 do
    x = (x * 1103515245 + 12345) % 2147483648
    noise[i] = string.char((x >> 16) % 256)
  end
  local plain = table.concat(noise)
  local enc = assert(Compress.xz_encoder(0))
  local first = assert(enc:update(plain))
  assert(#first >= 65536, tostring(#first))
  local packed = first .. assert(enc:finish())
  assert(#packed > 300000)
  assert(xz_decode(packed) == plain)
end

local function test_xz_encoder_throws_after_finish()
  local enc = assert(Compress.xz_encoder(0))
  assert(enc:update("x"))
  assert(enc:finish())
  local updated, _ = pcall(enc.update, enc, "y")
  assert(not updated)
  local finished, _ = pcall(enc.finish, enc)
  assert(not finished)
  assert(enc:pending() == false)
end

-- `bzip2 -c -1` and `bzip2 -c -9` of 40000 lines of "abcdefg", written
-- once by the command itself (bzip2 1.0.8) and embedded: -1 cuts three
-- full blocks of 100 kB and a fourth partial one, -9 one.
local abcdefg_bz2_1 = assert(Codec.unhex(
  "425a6831314159265359278494e30030d1410000103f8020007043020295007a1282c42505dd22505b44a0b889417512" ..
    "82dc2505e84a0be6282b24ca6b2d2390eea0124e9820000207f004000e08604052a00f22505844a0b289416a1282dc25" ..
    "05c84a0b3d84a0bc89417cc50564994d678a9569e40124e704000040fe008001c10c080a5401e84a0b10941661282cea" ..
    "1282da2505c44a0ba8941791282f98a0ac9329aca70c9939000272e08000081fc0100028430204d5401e250ac5142b24" ..
    "a15a250ad928570942ba4a15e250af8bb9229c284809829e2680"))
local abcdefg_bz2_9 = assert(Codec.unhex(
  "425a6839314159265359ea5990b9009c3fc10000103f8020007043020295007808546008546408546808546c08547008" ..
    "547408547808547c5dc914e14243a96642e4"))

local function test_bz2_encoder_writes_what_the_bzip2_command_writes()
  assert(drive_bz2(assert(Compress.bz2_encoder()), "hello, cosmic!") == hello_bz2)
  local plain = string.rep("abcdefg\n", 40000)
  assert(drive_bz2(assert(Compress.bz2_encoder(1)), plain) == abcdefg_bz2_1)
  assert(drive_bz2(assert(Compress.bz2_encoder(9)), plain) == abcdefg_bz2_9)
  -- However the input is cut, the bytes are the same.
  assert(drive_bz2(assert(Compress.bz2_encoder(1)), plain, 777) == abcdefg_bz2_1)
  -- Only the block size in the header differs for a small input.
  local five = drive_bz2(assert(Compress.bz2_encoder(5)), "hello, cosmic!")
  assert(five == hello_bz2:sub(1, 3) .. "5" .. hello_bz2:sub(5), Codec.hex(five))
end

local function test_bz2_round_trips_at_every_level_and_chunking()
  local noise: mut {string} = {}
  for i = 1, 4096 do noise[i] = string.char((i * 2654435761 >> 13) % 256) end
  -- Over 100 kB, so level 1 cuts it into blocks.
  local plain = string.rep("the quick brown fox jumps over the lazy dog. ", 3000) .. table.concat(noise)
  local levels: {integer} = { 1, 2, 5, 9 }
  local sizes: {integer} = { 1000, 70000, #plain }
  for _, level in ipairs(levels) do
    for _, size in ipairs(sizes) do
      local packed = drive_bz2(assert(Compress.bz2_encoder(level)), plain, size)
      assert(#packed < #plain, tostring(level) .. ": " .. tostring(#packed))
      local out, trouble = drive(assert(Compress.bz2_decoder()), packed, size)
      assert(trouble == "", trouble)
      assert(out == plain, tostring(level) .. "/" .. tostring(size) .. ": " .. tostring(#out))
    end
  end
  -- A byte at a time.
  local short = plain:sub(1, 3000)
  local packed = drive_bz2(assert(Compress.bz2_encoder(3)), short, 1)
  local out, trouble = drive(assert(Compress.bz2_decoder()), packed, 1)
  assert(trouble == "" and out == short, trouble)
end

local function test_bz2_encoder_of_nothing_is_an_empty_stream()
  -- `bzip2 -c < /dev/null`: the header, the end-of-stream magic, a zero CRC.
  local empty = drive_bz2(assert(Compress.bz2_encoder()), "")
  assert(empty == assert(Codec.unhex("425a683917724538509000000000")), Codec.hex(empty))
  local out, trouble = drive(assert(Compress.bz2_decoder()), empty)
  assert(out == "" and trouble == "", trouble)
end

local function test_bz2_encoder_update_of_nothing_is_not_a_failure()
  -- bzlib answers BZ_PARAM_ERROR to a BZ_RUN call that takes and emits
  -- nothing; an empty update must not surface it.
  local fresh = assert(Compress.bz2_encoder(1))
  assert(fresh:update("") == "")
  -- Only empty updates, then finish: the 14 bytes of an empty stream.
  assert(fresh:update("") == "")
  local empty = assert(fresh:finish())
  assert(empty == assert(Codec.unhex("425a683117724538509000000000")), Codec.hex(empty))
  -- Between chunks, the stream is the one without the empty updates.
  local enc = assert(Compress.bz2_encoder(1))
  local parts: mut {string} = {}
  for _, piece in ipairs({ "hello, ", "", "cosmic", "", "", "!" }) do
    parts[#parts + 1] = assert(enc:update(piece), piece)
  end
  parts[#parts + 1] = assert(enc:finish())
  local packed = table.concat(parts)
  assert(packed == drive_bz2(assert(Compress.bz2_encoder(1)), "hello, cosmic!"), Codec.hex(packed))
  local out, trouble = drive(assert(Compress.bz2_decoder()), packed)
  assert(out == "hello, cosmic!" and trouble == "", trouble)
end

local function test_bz2_encoder_update_whose_output_fills_the_slice_exactly()
  -- Found by search: at level 1 this input's first update emits exactly
  -- 65536 bytes, one whole output slice, with all its input taken. The
  -- call after that has nothing to do, which bzlib reports as an error.
  local noise: mut {string} = {}
  local x = 1
  for i = 1, 64778 do
    x = (x * 1103515245 + 12345) % 2147483648
    noise[i] = string.char((x >> 16) % 256)
  end
  local plain = table.concat(noise) .. string.rep("abcdefg\n", 25000)
  local enc = assert(Compress.bz2_encoder(1))
  local first, why = enc:update(plain)
  assert(first, why)
  assert(#first == 65536, "the input no longer fills a slice: " .. tostring(#first))
  local packed = first .. assert(enc:finish())
  local out, trouble = drive(assert(Compress.bz2_decoder()), packed)
  assert(trouble == "" and out == plain, trouble)
end

local function test_bz2_encoder_level_out_of_range_raises()
  local low_block, _ = pcall(Compress.bz2_encoder, 0)
  assert(not low_block)
  local high_block, _ = pcall(Compress.bz2_encoder, 10)
  assert(not high_block)
  assert((Compress.bz2_encoder(1)))
  assert((Compress.bz2_encoder(9)))
end

local function test_bz2_encoder_throws_after_finish()
  local enc = assert(Compress.bz2_encoder())
  assert(enc:update("x"))
  assert(enc:finish())
  local updated, _ = pcall(enc.update, enc, "y")
  assert(not updated)
  local finished, _ = pcall(enc.finish, enc)
  assert(not finished)
  assert(enc:pending() == false)
end

local function test_xz_encoder_closed_at_scope_end_frees_its_codec()
  do
    local enc <close> = assert(Compress.xz_encoder(0))
    assert(enc:update("abc"))
  end
  -- An encoder never finished is collected too.
  assert(Compress.xz_encoder(0))
  collectgarbage("collect")
end

local function test_xz_encoder_presets_out_of_range_raise()
  local low, _ = pcall(Compress.xz_encoder, -1)
  assert(not low)
  local high, _ = pcall(Compress.xz_encoder, 10)
  assert(not high)
  assert((Compress.xz_encoder(0)))
end
