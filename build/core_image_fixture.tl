--- Small ELF executables for the tests of build.core_image and what
--- keys by it: as a linker lays one out, a header, one loaded segment
--- holding the header and the code, then the sections no segment holds
--- -- a DWARF section where one is given -- and the section headers.

local record fixture
end

--- A 64-bit little-endian x86-64 executable whose loaded segment holds
--- `text`, carrying a `.debug_str` section holding `debug` where one is
--- given, as a checked core carries its DWARF.
function fixture.elf(text: string, debug?: string): string
  local text_at = 64 + 56
  local names = "\0.text\0.shstrtab\0" .. (debug ~= nil and ".debug_str\0" or "")
  local debug_at = text_at + #text
  local names_at = debug_at + #(debug or "")
  local headers_at = names_at + #names
  local sections: {string} = {
    ("\0"):rep(64),
    string.pack("<I4I4i8i8i8i8I4I4i8i8", 1, 1, 6, 0x400000 + text_at, text_at, #text,
      0, 0, 16, 0),
    string.pack("<I4I4i8i8i8i8I4I4i8i8", 7, 3, 0, 0, names_at, #names, 0, 0, 1, 0),
  }
  if debug ~= nil then
    sections[#sections + 1] = string.pack("<I4I4i8i8i8i8I4I4i8i8", 17, 1, 0, 0, debug_at,
      #debug, 0, 0, 1, 0)
  end
  local header = "\127ELF\2\1\1\0" .. ("\0"):rep(8) ..
    string.pack("<I2I2I4i8i8i8I4I2I2I2I2I2I2", 2, 62, 1, 0x400000 + text_at, 64,
      headers_at, 0, 64, 56, 1, 64, #sections, 2)
  local segment = string.pack("<I4I4i8i8i8i8i8i8", 1, 5, 0, 0x400000, 0x400000,
    text_at + #text, text_at + #text, 0x1000)
  return header .. segment .. text .. (debug or "") .. names .. table.concat(sections)
end

return fixture
