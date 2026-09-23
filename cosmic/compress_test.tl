--- Proves the streaming codecs round-trip, decode published vectors,
--- and refuse corrupt or truncated input rather than answering with
--- something wrong.

local Compress = require("cosmic.compress")

-- Feeds `data` through `stream` in pieces of `size` bytes (the whole of
-- it in one piece when `size` is nil), collecting every update's output
-- plus finish's, and returns it with the error `finish` gives, if any.
local function drive(stream: Compress.Stream, data: string, size?: integer): string, string
  local parts: {string} = {}
  local step = size or #data
  if step < 1 then step = 1 end
  local pos = 1
  while pos <= #data do
    local piece = data:sub(pos, pos + step - 1)
    local out, trouble = stream:update(piece)
    if out == nil then
      return "", trouble
    end
    parts[#parts + 1] = out
    pos = pos + #piece
  end
  local last, trouble = stream:finish()
  if last == nil then
    return table.concat(parts), trouble
  end
  parts[#parts + 1] = last
  return table.concat(parts), ""
end

local function roundtrip(format: string, plain: string, chunk_size?: integer)
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
  for _, format in ipairs({ "raw", "zlib", "gzip" }) do
    roundtrip(format, plain, 7)
  end
end

local function test_raw_zlib_gzip_roundtrip_one_big_chunk()
  -- 8 MB of semi-compressible data: large enough that the codec cannot
  -- know its size up front and must stream through its output buffer
  -- more than once.
  local piece = string.rep("cosmic ", 97) .. "\0\1\2\3"
  local plain = string.rep(piece, (8 * 1024 * 1024) // #piece + 1)
  for _, format in ipairs({ "raw", "zlib", "gzip" }) do
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
  for _, format in ipairs({ "raw", "zlib" }) do
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
  assert(Compress.crc32("") == 0)
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
