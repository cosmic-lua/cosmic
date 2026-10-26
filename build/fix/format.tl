--- The formatter of a Teal file: the layer that makes [`build.fix.layout`] safe to write to disk. A source goes in, and
--- what comes out is its layout or a refusal, never a layout that has not been checked:
--- 1. the source is parsed, and refused in the parser's words if it has an error (a file with an error has no tree to
---    keep);
--- 2. it is laid out;
--- 3. the layout is read again and compared with the source ([`build.fix.equiv`]): the same tokens (but for the comma
---    a table ends with), comments, doc comments and syntax tree;
--- 4. the layout is laid out again by [`build.fix.layout`], and must come out as itself, so that a second run of
---    the formatter changes nothing.
--- A layout that fails 3 or 4 is a fault in the layout, not in the file; the file is refused and the refusal names
--- what differs.
---
--- A name that ends in `.d.tl` is a declaration file and is read as one (`decl`): its bodies are laid out as
--- any are.
---
--- Line breaks, the width of a line and what the layout adds or leaves alone are those of [`build.fix.layout`] and
--- [`build.fix.breaks`].
local Ast = require("lang.ast")
local Equiv = require("build.fix.equiv")
local Layout = require("build.fix.layout")

local record Format
  --- Why a source is refused: `syntax` for a lexical or syntax error of the file, `equivalence` for a layout that
  --- is not the same as the file, `unstable` for one that is not a fixed point.
  enum Kind
    "syntax"
    "equivalence"
    "unstable"
  end

  --- What formatting a source gave: its layout in `text`, or no `text` and the `kind` and the `why` of the refusal.
  record Result
    text?: string
    kind?: Kind
    --- "" with a `text`; otherwise `name:line:column: message` for a syntax error, `name: ...` for the others.
    why: string
  end

  --- How a layout is made: [`build.fix.layout`]'s `of`.
  type Layouter = function(source: string, name: string, dialect?: Ast.Dialect): string?, string

  --- The contents of the file `name`, `source`, laid out or refused. A name that ends in `.d.tl` is read as a
  --- declaration file. `layout` makes the layout that is checked, [`build.fix.layout`]'s by default: a test gives
  --- one that is faulty to show that it is refused. The layout of that layout, for the fixed point, is always
  --- [`build.fix.layout`]'s.
  format: function(source: string, name: string, layout?: Layouter): Result
end

--- How `name` is read: `decl` for a declaration file, `tl` for any other.
local function dialect_of(name: string): Ast.Dialect
  return if name:sub(-5) == ".d.tl" then "decl" else "tl" end
end

function Format.format(source: string, name: string, layout?: Format.Layouter): Format.Result
  local dialect = dialect_of(name)
  local laid, why = (layout or Layout.of)(source, name, dialect)
  if laid == nil then
    return { kind = "syntax", why = why }
  end
  local difference = Equiv.difference(Equiv.read(source, name, dialect), Equiv.read(laid, name, dialect))
  if difference ~= nil then
    return { kind = "equivalence", why = name .. ": the layout is not the same as the file: " .. difference }
  end
  local again, _ = Layout.of(laid, name, dialect)
  if again ~= laid then
    return { kind = "unstable", why = name .. ": the layout is not a fixed point: laying it out again changes it" }
  end
  return { text = laid, why = "" }
end

return Format
