--- `cosmic codec <hex|base64|base64url> [-d] [--wrap N] [--lenient] [file|-]`:
--- bytes to text and back, for a token or a checksum, with no script
--- to write. It reads the file, or standard input when the file is `-`
--- or absent, and writes the encoding on one line and a newline; with
--- `-d` it writes the bytes the text spells, and no newline. The
--- encodings are those of [`cosmic.codec`] and no others; `-d` is the
--- one spelling of decode, `base64 -d` and `-D` differing between
--- platforms. Encoding does not wrap unless `--wrap N` gives the
--- columns, unlike GNU base64, which wraps at 76. Decoding ignores
--- ASCII whitespace, and is otherwise strict: an invalid character,
--- misplaced padding, a bad length or nonzero trailing bits exits 2
--- and names the byte offset, from 0, in the input as given. base64
--- must be padded with `=` and base64url must not be, as each is
--- written; `--lenient` accepts the other spelling (missing padding on
--- base64, `=` padding on base64url) and is refused for hex. The whole
--- input is read at once. It prints no summary: its output is the data
--- a pipe reads; exits 0 when done, 2 for a command line, an
--- input or a write it cannot honor
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "encode or decode base64, hex and the like",
  usage = "<encoding> [file]",
  examples = {
    { line = "base64 notes.txt", about = "encode a file" },
    { line = "base64 -d notes.b64", about = "decode it" },
  },
  spec = {
    ["-d"] = { about = "decode text to bytes, ignoring whitespace" },
    ["--decode"] = { about = "decode text to bytes, ignoring whitespace" },
    ["--wrap"] = { value = "n", about = "wrap encoded text at n columns; no wrapping by default" },
    ["--lenient"] = { about = "with -d, accept missing base64 padding, or base64url padding" },
  },
}

return command
