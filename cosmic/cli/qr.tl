--- `cosmic qr [options] [text...]`: prints the QR code of a text, to show
--- an address to a phone with nothing installed. The text is the words,
--- joined by spaces. With no words, it is standard input, less one newline
--- at its end. A text that starts with `-` goes after `--`
--- (`cosmic qr -- -x`).
---
---     cosmic qr https://example.com/
---     echo https://example.com/ | cosmic qr --invert
---     cosmic qr --svg code.svg --level H https://example.com/
---
--- Drawing:
---
--- - It prints the code for the terminal in half blocks (`▀`, `▄`, `█`),
---   two rows of modules on each line, with the standard's quiet zone of
---   four modules (`--quiet N`, 0 to 16).
--- - By default the blocks show the light modules, for light text on a
---   dark background, which is the common terminal. `--invert` draws the
---   dark modules instead, for a light background or paper. A reader
---   needs dark modules on light, so if a phone does not read the code,
---   try the other one.
--- - `--ascii` draws each module as `##` or two spaces, one line for each
---   row, for a font with no block characters.
--- - `--svg <file|->` writes an SVG image to the file, or prints it. It is
---   8 pixels for each module (`--scale N`, 1 to 1000), with a `viewBox`,
---   so it shows at a size and scales without blur. `--title T` says what
---   it shows, for a screen reader.
--- - `--level L|M|Q|H` is the error correction (default M: 15% of the code
---   can be lost). `--max-version N` refuses a text that needs a code
---   larger than version N (1 to 40, default 40), to keep the code small
---   enough to scan.
---
--- Reading:
---
--- `--read [file|-]` reads a code back from the file or standard input,
--- and prints what it holds and a newline (`cosmic qr hello | cosmic qr
--- --read` prints `hello`). It reads the text or SVG that `cosmic qr`
--- drew, either way round and with any quiet zone, and mends what its
--- level allows. It reads those drawings only, not photos or other
--- programs' images. A program draws and reads its own codes with
--- [`cosmic.qr`].
---
--- Its standard output is the code, or the text that it read, and it
--- prints no summary. It exits 0 when it printed or wrote. It exits 1
--- when the text is too large for a code of the allowed versions at the
--- level, or when a drawing holds no code that it can read. It exits 2
--- for a command line or an input that it refuses, or a failed write.
--- @public

local Flags = require("cosmic.flags")

local command: Flags.Command = {
  about = "draw a QR code, or read one back",
  usage = "[options] [text...]",
  examples = {
    { line = "https://example.com/", about = "a QR code in the terminal" },
    { line = "--svg code.svg https://example.com/", about = "an SVG image" },
    { line = "--read code.svg", about = "read one back" },
  },
  spec = {
    ["--level"] = { value = "L|M|Q|H", about = "the error correction level (default M)" },
    ["--max-version"] = { value = "n", about = "the largest code, 1 to 40 (default 40)" },
    ["--quiet"] = { value = "n", about = "the light border in modules, 0 to 16 (default 4)" },
    ["--invert"] = { about = "draw the dark modules, for a light terminal or paper" },
    ["--ascii"] = { about = "draw with `##` and spaces, not block characters" },
    ["--color"] = { about = "paint it black on white with ANSI escapes, clear on a terminal of either theme" },
    ["--svg"] = { value = "file|-", about = "write an SVG image to the file, or print it" },
    ["--scale"] = { value = "n", about = "svg: pixels a module, 1 to 1000 (default 8)" },
    ["--title"] = { value = "text", about = "svg: what it shows, for a screen reader" },
    ["--read"] = { about = "read back a code `cosmic qr` drew, from a file or standard input" },
  },
}

return command
