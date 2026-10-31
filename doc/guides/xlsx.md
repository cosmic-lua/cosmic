# reading a spreadsheet

An `.xlsx` file is a zip of XML parts: the workbook names its sheets, a
relationships part says where each one is, a shared strings part holds
the text of the cells, and each sheet holds its rows. This guide reads one
with [`cosmic.zip`], [`cosmic.xml`], [`cosmic.url`] and [`cosmic.time`],
in about a hundred lines, dates included, and shows where a fuller
reader would go on from there.

## a workbook to read

The examples build a small workbook in memory, cut to the parts read
here, so they run anywhere. A real file is read the same way from
[`Zip.open`]. The names in each part are in a namespace, which the reader
drops with `local_names`.

```teal
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")
local Url = require("cosmic.url")
local Xml = require("cosmic.xml")
local Zip = require("cosmic.zip")

local main = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"'
local rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
local parts: {{string}} = {
  { "xl/workbook.xml", "<workbook " .. main .. ' xmlns:r="' .. rel .. '"><sheets>' ..
    '<sheet name="Sales" sheetId="1" r:id="rId1"/></sheets></workbook>' },
  { "xl/_rels/workbook.xml.rels",
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' ..
    '<Relationship Id="rId1" Type="' .. rel .. '/worksheet" Target="worksheets/sheet1.xml"/>' ..
    '<Relationship Id="rId2" Type="' .. rel .. '/sharedStrings" Target="sharedStrings.xml"/>' ..
    '<Relationship Id="rId3" Type="' .. rel .. '/styles" Target="styles.xml"/>' ..
    "</Relationships>" },
  { "xl/sharedStrings.xml", "<sst " .. main .. "><si><t>Region</t></si><si><t>Total</t></si>" ..
    "<si><r><t>North</t></r><r><t> East</t></r>" ..
    '<rPh sb="0" eb="5"><t>nosu</t></rPh></si></sst>' },
  { "xl/styles.xml", "<styleSheet " .. main .. '><numFmts><numFmt numFmtId="164" formatCode="yyyy-mm-dd hh:mm"/>' ..
    '</numFmts><cellXfs><xf numFmtId="0"/><xf numFmtId="14"/><xf numFmtId="164"/></cellXfs></styleSheet>' },
  { "xl/worksheets/sheet1.xml", "<worksheet " .. main .. "><sheetData>" ..
    '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>' ..
    '<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>1250.5</v></c><c r="D2" t="b"><v>1</v></c><c><v>7</v></c></row>' ..
    '<row r="3"><c r="A3" s="1"><v>45658</v></c><c r="B3" s="2"><v>45658.5</v></c></row>' ..
    "</sheetData></worksheet>" },
}
local out = Stream.collect()
local w = Zip.writer(out)
for _, p in ipairs(parts) do assert(w:add_file(assert(p[1]), assert(p[2]))) end
assert(w:close())
local book = assert(Zip.open_string(out:result()))
```

## parts and relationships

A part is named by its path from the package's root, `/xl/workbook.xml`,
and [`Zip.Reader`]'s `entry` opens it by that path less its first `/`.
Small parts are read whole with [`Xml.tree`].

A part's relationships sit beside it, in `_rels/<name>.rels`. Each
names a target relative to the part, which [`Url.resolve`] resolves as a
link is followed from a page. They are kept here by id, which a sheet
names, and by the last word of their type, which is how the shared
strings part is found.

```teal continue
local function part(name: string): Xml.Element
  local entry = assert(book:entry(name:sub(2)))
  local text = assert(Stream.read_all((assert(entry:open()))))
  return (assert(Xml.tree(text, { local_names = true })))
end

local function relationships(name: string): {string: string}
  local dir, file = name:match("^(.*/)([^/]*)$")
  local found: mut {string: string} = {}
  for _, r in ipairs(Xml.children(part(assert(dir) .. "_rels/" .. assert(file) .. ".rels"), "Relationship")) do
    local target = Url.resolve(name, assert(r.attributes["Target"]))
    found[assert(r.attributes["Id"])] = target
    found[assert(assert(r.attributes["Type"]):match("[^/]*$"))] = target
  end
  return found
end

local rels = relationships("/xl/workbook.xml")
```

## shared strings

A cell of text holds the index of its string in the shared strings
part, counted from 0. A string is one `t`, or runs of formatting, each
`r` holding a `t`. A string may also carry a phonetic reading in `rPh`,
which is not its text, so the `t` elements are joined by hand rather
than with [`Xml.text`], which would take in the reading and any
whitespace between runs. A workbook with no text in its cells has no
shared strings part.

```teal continue
local function string_of(si: Xml.Element): string
  local t = Xml.child(si, "t")
  if t ~= nil then return Xml.text(t) end
  local runs: mut {string} = {}
  for _, run in ipairs(Xml.children(si, "r")) do
    local text = Xml.text(assert(Xml.child(run, "t")))
    runs[#runs + 1] = text
  end
  return table.concat(runs)
end

local strings: mut {string} = {}
local shared = rels["sharedStrings"]
if shared ~= nil then
  for _, si in ipairs(Xml.children(part(shared), "si")) do
    local text = string_of(si)
    strings[#strings + 1] = text
  end
end
```

## dates

A date is a number, the days since 1899-12-30, with the time of day as
its fraction; only its cell's style says it is a date. A cell's `s`
indexes the `xf` elements of `cellXfs` in the styles part, and an `xf`'s
`numFmtId` names its number format: one built in, of which 14 to 22 and
45 to 47 are dates and times, or one of the part's own `numFmt`s. One of
those is a date when its code holds `d`, `m`, `y`, `h` or `s` outside
its quoted text and its `[...]` sections. [`Time.parse_date`] gives the
first moment of 1899-12-30, from which the days count.

```teal continue
local date_styles: mut {integer: boolean} = {}
local styles = rels["styles"]
if styles ~= nil then
  local sheet = part(styles)
  local custom: mut {string: boolean} = {}
  for _, f in ipairs(Xml.children(Xml.child(sheet, "numFmts") or sheet, "numFmt")) do
    local code = (assert(f.attributes["formatCode"]):lower():gsub('"[^"]*"', ""):gsub("%[[^%]]*%]", ""))
    custom[assert(f.attributes["numFmtId"])] = code:find("[dmyhs]") ~= nil
  end
  for i, xf in ipairs(Xml.children(Xml.child(sheet, "cellXfs") or sheet, "xf")) do
    local id = xf.attributes["numFmtId"] or "0"
    local n = math.tointeger(id) or 0
    date_styles[i - 1] = (n >= 14 and n <= 22) or (n >= 45 and n <= 47) or custom[id] == true
  end
end

local epoch = assert(Time.parse_date("1899-12-30"))
local function date(serial: number): string
  local ns = epoch + math.floor(serial * 86400 + 0.5) * 1000000000
  if serial == math.floor(serial) then return Time.format_date(ns) end
  return Time.format_rfc3339(ns)
end
```

## cells

A cell's `r` names its place, `B2`: its letters are the column. Its
`t` says what its `v` holds: `s` an index into the shared strings, `b`
a boolean as 0 or 1, `inlineStr` text in an `is` element, and none at
all a number, which its style may say is a date. A cell left empty is left out of its row, so a row is
filled to each cell's column; a cell without an `r`, which a writer may
leave out, is in the column after the one before it.

```teal continue
local function column(ref: string): integer
  local n = 0
  for letter in ref:gmatch("%u") do n = n * 26 + assert(letter:byte()) - 64 end
  return n
end

local function value(c: Xml.Element): string
  local t = c.attributes["t"]
  if t == "inlineStr" then return string_of(assert(Xml.child(c, "is"))) end
  local v = Xml.child(c, "v")
  if v == nil then return "" end
  local raw = Xml.text(v)
  if t == "s" then return assert(strings[assert(math.tointeger(raw)) + 1]) end
  if t == "b" then return if raw == "1" then "TRUE" else "FALSE" end end
  local style = math.tointeger(c.attributes["s"] or "0")
  if style ~= nil and date_styles[style] == true then return date(assert(tonumber(raw))) end
  return raw
end
```

## rows

A sheet can hold a great many rows, so it is read a row at a time:
[`Xml.subtrees`] answers each `row` whole as the parser reaches its
end, from the sheet's body read in chunks.

```teal continue
local workbook = part("/xl/workbook.xml")
for _, sheet in ipairs(Xml.children(assert(Xml.child(workbook, "sheets")), "sheet")) do
  print(sheet.attributes["name"])
  local path = assert(rels[assert(sheet.attributes["id"])])
  local body = assert(assert(book:entry(path:sub(2))):open())
  local p <close> = assert(Xml.parser({ local_names = true }))
  local rows = Xml.subtrees("worksheet/sheetData/row")
  local function show(events: {Xml.Event})
    for _, row in ipairs(rows:take(events)) do
      local cells: mut {string} = {}
      for _, c in ipairs(Xml.children(row, "c")) do
        local ref = c.attributes["r"]
        local at = if ref ~= nil then column(ref) else #cells + 1 end
        while #cells < at - 1 do cells[#cells + 1] = "" end
        local text = value(c)
        cells[#cells + 1] = text
      end
      print(table.concat(cells, ","))
    end
  end
  while true do
    local chunk, trouble = body:read(64 * 1024)
    if chunk == nil then
      assert(trouble == "", trouble)
      break
    end
    show((assert(p:feed(chunk))))
  end
  show((assert(p:finish())))
end
assert(book:close())
```

```output
Sales
Region,Total
North East,1250.5,,TRUE,7
2025-01-01,2025-01-01T12:00:00Z
```

## going further

What this leaves out is the spreadsheet's own business, not the file's:

- A workbook may count its dates from 1904-01-01 instead: its
  `workbookPr` says so with `date1904="1"`. And Excel counts 1900 as a
  leap year, so a serial before 61 (1900-03-01) is a day off.
- A formula's cell holds an `f` beside the `v` it last computed.
- A sheet's `mergeCells` and `hyperlinks`, and the workbook's defined
  names, are each a few lines more of the same.

And some of what a reader of any file meets:

- An empty row is left out like an empty cell: a row's `r` is its
  number, and lines that must match row numbers are filled the same way.
- The workbook's path is read here as `/xl/workbook.xml`, where most
  writers put it. The package says where it is: `_rels/.rels` names it,
  as the relationship whose type ends in `officeDocument`.
- A part's name matches whatever its case, where an entry's path in a
  zip does not.
- A relationship with `TargetMode="External"` names a URL outside the
  package, such as a hyperlink's, and is never opened as a part.

[`cosmic.time`]: ../../cosmic/time.tl
[`cosmic.url`]: ../../cosmic/url.tl
[`cosmic.xml`]: ../../cosmic/xml.tl
[`cosmic.zip`]: ../../cosmic/zip.tl
[`Time.parse_date`]: ../../cosmic/time.tl
[`Url.resolve`]: ../../cosmic/url.tl
[`Xml.subtrees`]: ../../cosmic/xml.tl
[`Xml.text`]: ../../cosmic/xml.tl
[`Xml.tree`]: ../../cosmic/xml.tl
[`Zip.open`]: ../../cosmic/zip.tl
[`Zip.Reader`]: ../../cosmic/zip.tl
