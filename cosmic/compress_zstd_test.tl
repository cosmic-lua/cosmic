--- Compress.zstd writes what the portable artifact's decode stub
--- (core/unzstd.c) takes: the content size and a checksum, and no window
--- over core/unzstd.h's. A streaming encoder names no size.

local Compress = require("cosmic.compress")
local Stream = require("cosmic.stream")

local record FrameHeader
  checksum: boolean
  content_size: integer?
  window: integer
end

local function byte_at(data: string, at: integer): integer
  return (assert(data:byte(at), "a byte at " .. tostring(at)))
end

--- The header of `frame`, read back.
local function frame_header(frame: string): FrameHeader
  assert(frame:sub(1, 4) == "\40\181\47\253", "a zstd frame starts with its magic")
  local descriptor = byte_at(frame, 5)
  local single = descriptor & 0x20 ~= 0
  assert(descriptor & 0x03 == 0, "no dictionary id")
  local at = 6
  local window = 0
  if not single then
    local byte = byte_at(frame, at)
    local log = 10 + (byte >> 3)
    window = (1 << log) + (byte & 7) * ((1 << log) >> 3)
    at = at + 1
  end
  local flag = descriptor >> 6
  local width = 0
  if flag == 0 then
    if single then width = 1 end
  else
    width = 1 << flag
  end
  local content_size: integer? = nil
  if width ~= 0 then
    local value = 0
    for i = width, 1, -1 do value = (value << 8) | byte_at(frame, at + i - 1) end
    content_size = if flag == 1 then value + 256 else value end
  end
  if single then window = assert(content_size) end
  return { checksum = descriptor & 0x04 ~= 0, content_size = content_size, window = window }
end

local function decode(frame: string): string
  local decoder = assert(Compress.zstd_decoder())
  return (assert(Stream.run(decoder, frame)))
end

local function test_zstd_declares_its_size_and_keeps_its_window(_: string)
  local small = string.rep("cosmic ", 200)
  local frame = assert(Compress.zstd(small, 19))
  local header = frame_header(frame)
  assert(header.content_size == #small and header.checksum, "a small frame names its size and checksum")
  assert(header.window <= 1 << 23)
  assert(decode(frame) == small)
  assert(assert(Compress.zstd(small, 19)) == frame, "the same bytes every run")

  -- Past the window the frame is not single-segment, and its window is the fixed one.
  local parts: mut {string} = {}
  for i = 1, 9 * 1024 do
    parts[i] = string.format("%07d:", i) .. string.rep(string.char(65 + i % 26), 1016)
  end
  local large = table.concat(parts)
  local big = assert(Compress.zstd(large, 1))
  local big_header = frame_header(big)
  assert(big_header.content_size == #large and big_header.checksum)
  assert(big_header.window == 1 << 23, "the window is the shared constant: " .. tostring(big_header.window))
  assert(decode(big) == large)
end

local function test_a_streaming_encoder_names_no_size(_: string)
  local encoder = assert(Compress.zstd_encoder(19))
  local streamed = frame_header((assert(Stream.run(encoder, string.rep("cosmic ", 200)))))
  assert(streamed.content_size == nil and streamed.checksum, "a streaming encoder pledges no size")
end
