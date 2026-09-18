--- Reading and rewriting the few Mach-O load commands the attach needs.
---
--- A cosmic binary carries its database inside an extended `__LINKEDIT`
--- segment, followed by a fresh signature that covers it, because arm64
--- macOS refuses a binary with bytes after its signature. Only three
--- numbers move: the segment's size, the signature's offset, and the
--- signature itself.

local record macho
  record Segment
    --- Where the load command sits in the file.
    at: integer
    name: string
    vmaddr: integer
    vmsize: integer
    fileoff: integer
    filesize: integer
  end

  record Signature
    at: integer
    dataoff: integer
    datasize: integer
  end

  record Image
    bytes: string
    segments: {Segment}
    signature: Signature | nil
    --- The text segment, which the signature's execute range describes.
    text: Segment | nil
    linkedit: Segment | nil
  end
end

local magic_64 = 0xfeedfacf
local lc_segment_64 = 0x19
local lc_code_signature = 0x1d
local header_size = 32

--- Reads the load commands of a thin 64-bit Mach-O.
function macho.read(bytes: string): macho.Image | nil, string
  if #bytes < header_size then
    return nil, "too short to be a Mach-O"
  end
  local magic = string.unpack("<I4", bytes)
  if magic ~= magic_64 then
    return nil, "not a thin 64-bit Mach-O"
  end
  local ncmds = string.unpack("<I4", bytes, 17)
  local image: macho.Image = {
    bytes = bytes,
    segments = {},
    signature = nil,
    text = nil,
    linkedit = nil,
  }

  local at = header_size
  for _ = 1, ncmds do
    if at + 8 > #bytes then
      return nil, "the load commands run past the end of the file"
    end
    local cmd, cmdsize = string.unpack("<I4I4", bytes, at + 1)
    if cmdsize < 8 then
      return nil, "a load command declares no size"
    end
    if cmd == lc_segment_64 then
      local name = string.unpack("z", bytes, at + 9)
      local vmaddr, vmsize, fileoff, filesize =
        string.unpack("<I8I8I8I8", bytes, at + 25)
      local segment: macho.Segment = {
        at = at,
        name = name,
        vmaddr = vmaddr,
        vmsize = vmsize,
        fileoff = fileoff,
        filesize = filesize,
      }
      image.segments[#image.segments + 1] = segment
      if name == "__TEXT" then
        image.text = segment
      elseif name == "__LINKEDIT" then
        image.linkedit = segment
      end
    elseif cmd == lc_code_signature then
      local dataoff, datasize = string.unpack("<I4I4", bytes, at + 9)
      image.signature = { at = at, dataoff = dataoff, datasize = datasize }
    end
    at = at + cmdsize
  end

  if image.text == nil then
    return nil, "the image has no __TEXT segment"
  end
  if image.linkedit == nil then
    return nil, "the image has no __LINKEDIT segment"
  end
  if image.signature == nil then
    return nil, "the image carries no signature to replace"
  end
  return image
end

--- Replaces a run of bytes, one-based and inclusive.
local function splice(bytes: string, at: integer, replacement: string): string
  return bytes:sub(1, at - 1) .. replacement .. bytes:sub(at + #replacement)
end

--- Writes the segment's file and memory sizes back into its load
--- command. Everything else in the command is left alone.
function macho.set_segment_size(bytes: string, segment: macho.Segment,
                                filesize: integer, vmsize: integer): string
  local out = splice(bytes, segment.at + 25 + 8, string.pack("<I8", vmsize))
  return splice(out, segment.at + 25 + 24, string.pack("<I8", filesize))
end

--- Writes the signature's offset and size back into its load command.
function macho.set_signature(bytes: string, signature: macho.Signature,
                              dataoff: integer, datasize: integer): string
  return splice(bytes, signature.at + 9,
                string.pack("<I4I4", dataoff, datasize))
end

return macho
