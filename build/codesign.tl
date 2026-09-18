--- The ad-hoc code signature a cosmic binary carries on macOS.
---
--- arm64 macOS will not run an unsigned binary and will not run one
--- whose bytes moved after it was signed, so attaching a database means
--- signing the result. The signature is ad-hoc: it asserts nothing about
--- who produced the file, only that the file has not changed since.
---
--- It is one SuperBlob holding one CodeDirectory: a header, the
--- identifier, and one SHA-256 per 4096-byte page of everything before
--- the signature. The last page is hashed over its real length rather
--- than zero-padded.

local Hash = require("cosmic.hash")

local record codesign
end

local superblob_magic = 0xfade0cc0
local directory_magic = 0xfade0c02
local directory_version = 0x20400
local adhoc_flag = 0x2
local hash_type_sha256 = 2
local digest_size = 32
local page_shift = 12
local page_size = 1 << page_shift
local slot_code_directory = 0
local exec_segment_main_binary = 1

--- The fixed part of a CodeDirectory at version 0x20400.
local directory_header_size = 88

--- @param image the bytes the signature covers
--- @param identifier the name the signature carries, conventionally the
---   binary's own
--- @param text_offset where the executable segment starts in the file
--- @param text_size how long the executable segment is
function codesign.directory(image: string, identifier: string,
                            text_offset: integer, text_size: integer): string
  local pages = (#image + page_size - 1) // page_size
  local identifier_size = #identifier + 1
  local hash_offset = directory_header_size + identifier_size
  local length = hash_offset + pages * digest_size

  local out: {string} = {}
  out[#out + 1] = string.pack(">I4I4I4I4I4I4I4I4I4",
    directory_magic, length, directory_version, adhoc_flag,
    hash_offset, directory_header_size, 0, pages, #image)
  out[#out + 1] = string.pack(">I1I1I1I1I4",
    digest_size, hash_type_sha256, 0, page_shift, 0)
  -- scatterOffset, teamOffset, spare3, codeLimit64
  out[#out + 1] = string.pack(">I4I4I4I8", 0, 0, 0, 0)
  out[#out + 1] = string.pack(">I8I8I8",
    text_offset, text_size, exec_segment_main_binary)
  out[#out + 1] = identifier
  out[#out + 1] = "\0"

  for page = 0, pages - 1 do
    local from = page * page_size + 1
    local to = math.min(from + page_size - 1, #image)
    out[#out + 1] = Hash.sha256(image:sub(from, to))
  end

  return table.concat(out)
end

--- Wraps a CodeDirectory in the SuperBlob that the load command points
--- at.
function codesign.superblob(directory: string): string
  local index_size = 8
  local offset = 12 + index_size
  local length = offset + #directory
  return string.pack(">I4I4I4", superblob_magic, length, 1) ..
    string.pack(">I4I4", slot_code_directory, offset) ..
    directory
end

--- The whole signature for an image, ready to append.
function codesign.sign(image: string, identifier: string,
                        text_offset: integer, text_size: integer): string
  return codesign.superblob(
    codesign.directory(image, identifier, text_offset, text_size))
end

return codesign
