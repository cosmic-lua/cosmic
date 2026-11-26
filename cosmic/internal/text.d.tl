-- Text cut into lines, lists sorted by their bytes, and base64 decoded, as the core
-- provides them for [`cosmic.shell`] and [`cosmic.codec`].
--- @kind binding

local record text
  -- A new list of the lines of `text`, each without its newline: a last line with no
  -- newline is one too, and none follows a last newline. Where `bare`, a
  -- `\r` at the end of a line goes too.
  lines: function(text: string, bare: boolean): mut {string}
  -- How many newlines bytes `i` through `j` of `text` hold (from 1, as
  -- string.sub counts, clamped to the text), and where the last of them
  -- is, or 0 where none is.
  newlines: function(text: string, i: integer, j: integer): integer, integer
  -- A new list of the strings of `list`, sorted by their bytes as
  -- `LC_ALL=C sort` orders them.
  sort: function(list: {string}): mut {string}
  -- Why [`unbase64`] refused a text: a length not a multiple of 4, one
  -- character over (unpadded), `=` out of place, a byte outside the
  -- alphabet, or nonzero bits in the last character.
  enum Refusal
    "length"
    "over"
    "padding"
    "byte"
    "bits"
  end
  -- The bytes `text` spells in base64: the URL-safe alphabet where `url`,
  -- else the standard one. `padded` says `text` must carry `=` padding to a
  -- multiple of four characters, or must carry none; where `lines`, every
  -- `\r` and `\n` is skipped first. Else nil, the 1-based place in `text`
  -- the refusal names (for `length`, `over` and `bits`, the length without
  -- line breaks) and why.
  unbase64: function(text: string, url: boolean, padded: boolean, lines: boolean): string?, integer, Refusal
end

return text
