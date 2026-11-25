-- Text cut into lines and lists sorted by their bytes, as the core
-- provides them for [`cosmic.shell`].
--- @kind binding

local record text
  -- The lines of `text`, each without its newline: a last line with no
  -- newline is one too, and none follows a last newline. Where `bare`, a
  -- `\r` at the end of a line goes too.
  lines: function(text: string, bare: boolean): {string}
  -- How many newlines bytes `i` through `j` of `text` hold (from 1, as
  -- string.sub counts, clamped to the text), and where the last of them
  -- is, or 0 where none is.
  newlines: function(text: string, i: integer, j: integer): integer, integer
  -- A new list of the strings of `list`, sorted by their bytes as
  -- `LC_ALL=C sort` orders them.
  sort: function(list: {string}): mut {string}
end

return text
