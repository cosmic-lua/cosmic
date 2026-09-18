--- Joining a core image to a database, so one file holds both.
---
--- The database is appended and found again by a trailer: a marker, then
--- the database's start offset as eight big-endian bytes. On ELF the
--- trailer is the last bytes of the file. On Mach-O it sits immediately
--- before the code signature, because arm64 macOS refuses a binary with
--- bytes after its signature. Nothing else in the file moves.

local Fs = require("cosmic.Fs")
local codesign = require("build.codesign")
local macho = require("build.macho")

local record attach
end

--- Deliberately not SQLite's own appended-database marker, so a stray
--- appended database is never mistaken for one of ours.
local marker = "Start-Of-Cosmic--"
local identifier = "cosmic"
local linkedit_alignment = 1 << 14

local function trailer(offset: integer): string
  return marker .. string.pack(">I8", offset)
end

--- An ELF binary: the image, the database, the trailer.
function attach.elf(image: string, database: string): string
  return image .. database .. trailer(#image)
end

--- A Mach-O binary: everything up to the linker's own signature, then
--- the database and the trailer, then a fresh signature covering both.
function attach.macho(image: string, database: string): string | nil, string
  local parsed, trouble = macho.read(image)
  if parsed == nil then
    return nil, trouble
  end
  local signature = parsed.signature
  local linkedit = parsed.linkedit
  local text = parsed.text
  if signature == nil or linkedit == nil or text == nil then
    return nil, "the image is missing a part the attach needs"
  end

  -- The linker's ad-hoc signature is discarded, not appended to.
  local body = image:sub(1, signature.dataoff) .. database
  body = body .. trailer(signature.dataoff)
  while #body % 16 ~= 0 do
    body = body .. "\0"
  end

  local signature_offset = #body
  local signed_size = #codesign.sign(
    body, identifier, text.fileoff, text.filesize)
  local total = signature_offset + signed_size

  local filesize = total - linkedit.fileoff
  local vmsize = ((filesize + linkedit_alignment - 1) //
    linkedit_alignment) * linkedit_alignment

  -- The load commands move before the pages are hashed, so the hashes
  -- cover the file as it will be read.
  body = macho.set_segment_size(body, linkedit, filesize, vmsize)
  body = macho.set_signature(body, signature, signature_offset, signed_size)

  local final = codesign.sign(body, identifier, text.fileoff, text.filesize)
  if #final ~= signed_size then
    return nil, "the signature changed size after the offsets were written"
  end
  return body .. final
end

--- Writes one executable for one target.
--- @param target the target's name, which says which format to write
function attach.write(path: string, target: string, image: string,
                      database: string): boolean, string
  local bytes: string
  if target:match("%-macos$") ~= nil then
    local built, trouble = attach.macho(image, database)
    if built == nil then
      return false, trouble
    end
    bytes = built
  else
    bytes = attach.elf(image, database)
  end
  local ok, why = Fs.write(path, bytes, 0x1ed)
  if not ok then
    return false, why
  end
  return true, ""
end

return attach
