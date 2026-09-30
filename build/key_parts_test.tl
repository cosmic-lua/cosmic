--- The parts of a key a worker spells (build/key_parts.tl): hexadecimal
--- as [`cosmic.codec`] spells it, a fixed framing, and a fixed name for the
--- tree, so a key does not change with them. build.declared_key answers
--- the compiler's readers too.

local Codec = require("cosmic.codec")
local declared_key = require("build.declared_key")
local key_parts = require("build.key_parts")

--- Every byte alone, and strings of every length to 64 over a spread
--- of bytes, hex-encode as [`Codec.hex`] does and decode back.
local function test_hex_is_codec_hex_and_unhex_inverts_it()
  local samples: {string} = { "" }
  for byte = 0, 255 do samples[#samples + 1] = string.char(byte) end
  for length = 1, 64 do
    local bytes: {string} = {}
    for i = 1, length do bytes[i] = string.char((i * 37 + length * 11) % 256) end
    samples[#samples + 1] = table.concat(bytes)
  end
  for _, sample in ipairs(samples) do
    local text = key_parts.hex(sample)
    assert(text == Codec.hex(sample), sample)
    assert(key_parts.unhex(text) == sample, text)
    assert(key_parts.unhex(text:upper()) == sample, text)
    assert(key_parts.unhex(text:upper()) == Codec.unhex(text:upper()), text)
  end
  for _, bad in ipairs({ "a", "abc", "0g", "zz", "0 " }) do
    local decoded, why = key_parts.unhex(bad)
    assert(decoded == nil and Codec.unhex(bad) == nil and why ~= "", bad)
  end
end

--- A contribution is framed as the kind, then the path and the answer
--- in lowercase hex, a space between each.
local function test_a_key_part_is_the_kind_then_path_and_answer_in_hex()
  local edges = "\0\n\x7f\xff"
  assert(key_parts.key_part("s", edges, "") == "s 000a7fff ")
  assert(key_parts.key_part("d", "caf\xc3\xa9", "x") == "d 636166c3a9 78")
  for _, case in ipairs({ { "i", "build.a_test test_b", "" }, { "r", "/tree/x", "ok 12" } }) do
    assert(key_parts.key_part(case[1], case[2], case[3]) ==
      case[1] .. " " .. Codec.hex(case[2]) .. " " .. Codec.hex(case[3]))
  end
end

--- A path under the tree is named below a marker no path holds; one
--- outside it, or climbing with "..", as it is.
local function test_tree_name_names_the_tree_by_a_marker()
  assert(key_parts.tree_name("/w/tree", "/w/tree") == "\0tree")
  assert(key_parts.tree_name("/w/tree/a/b.tl", "/w/tree") == "\0tree/a/b.tl")
  assert(key_parts.tree_name("/w/treehouse/a", "/w/tree") == "/w/treehouse/a")
  assert(key_parts.tree_name("/w/tree/../x", "/w/tree") == "/w/tree/../x")
  assert(key_parts.tree_name("/etc/passwd", "/w/tree") == "/etc/passwd")
end

--- build.declared_key answers the compiler's readers as its own, so its
--- callers need not name build.key_parts.
local function test_declared_key_answers_the_compiler_readers()
  assert(declared_key.compiler_readers == key_parts.compiler_readers)
  assert(declared_key.reads_compiler == key_parts.reads_compiler)
  assert(key_parts.reads_compiler({ "build.a", key_parts.compiler_readers[1] }))
  assert(not key_parts.reads_compiler({ "build.a" }))
end
