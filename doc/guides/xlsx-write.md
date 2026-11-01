# writing a spreadsheet

<!-- policy: cpu_features = true -->

An `.xlsx` file is a zip of XML parts, and the fewest a spreadsheet
program opens are five: the content types, the package's relationships,
the workbook, the workbook's relationships, and a sheet. This guide writes
a workbook of one sheet, with text, numbers, a boolean and a date, using
[`cosmic.zip`], [`cosmic.xml`] and [`cosmic.time`], and then reads it back
to show what it holds. [reading a spreadsheet](xlsx.md) reads one in
full.

## the rows

The sheet's rows are Lua values: a string is text, a number a number, a
boolean a boolean, and a date a table holding its `date`.

```teal
local Stream = require("cosmic.stream")
local Time = require("cosmic.time")
local Xml = require("cosmic.xml")
local Zip = require("cosmic.zip")

local record Date
  date: string
end
local type Value = string | number | boolean | Date

local rows: {{Value}} = {
  { "Region", "Total", "Closed", "When" },
  { "North & East", 1250.5, true, { date = "2025-01-01" } },
  { "South", 980, false, { date = "2025-02-14" } },
}
```

## the package's parts

Each part is written with [`Xml.write`] from events. The names are plain,
and each root declares its namespace with an `xmlns` attribute, as
spreadsheet programs write them. The content types say what each part
is, and the relationships say where the workbook and its sheet are.

```teal continue
local main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
local rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
local packaging = "http://schemas.openxmlformats.org/package/2006/relationships"
local office = "application/vnd.openxmlformats-officedocument.spreadsheetml."

local function element(name: string, attributes?: {string: string}): {Xml.Event}
  return { { kind = "start", name = name, attributes = attributes }, { kind = "end", name = name } }
end

local function wrapped(name: string, attributes: {string: string}, inside: {{Xml.Event}}): string
  local events: mut {Xml.Event} = { { kind = "start", name = name, attributes = attributes } }
  for _, list in ipairs(inside) do
    for _, e in ipairs(list) do events[#events + 1] = e end
  end
  events[#events + 1] = { kind = "end", name = name }
  return (assert(Xml.write(events)))
end

local function relationship(id: string, kind: string, target: string): {Xml.Event}
  return element("Relationship", { Id = id, Type = rel .. "/" .. kind, Target = target })
end

local out = Stream.collect()
local zip = Zip.writer(out)
assert(zip:add_file("[Content_Types].xml", wrapped("Types",
  { xmlns = "http://schemas.openxmlformats.org/package/2006/content-types" }, {
    element("Default", { Extension = "rels", ContentType = "application/vnd.openxmlformats-package.relationships+xml" }),
    element("Default", { Extension = "xml", ContentType = "application/xml" }),
    element("Override", { PartName = "/xl/workbook.xml", ContentType = office .. "sheet.main+xml" }),
    element("Override", { PartName = "/xl/worksheets/sheet1.xml", ContentType = office .. "worksheet+xml" }),
    element("Override", { PartName = "/xl/styles.xml", ContentType = office .. "styles+xml" }),
  })))
assert(zip:add_file("_rels/.rels", wrapped("Relationships", { xmlns = packaging }, {
  relationship("rId1", "officeDocument", "xl/workbook.xml"),
})))
assert(zip:add_file("xl/workbook.xml", wrapped("workbook", { xmlns = main, ["xmlns:r"] = rel }, {
  { { kind = "start", name = "sheets" } },
  element("sheet", { name = "Sales", sheetId = "1", ["r:id"] = "rId1" }),
  { { kind = "end", name = "sheets" } },
})))
assert(zip:add_file("xl/_rels/workbook.xml.rels", wrapped("Relationships", { xmlns = packaging }, {
  relationship("rId1", "worksheet", "worksheets/sheet1.xml"),
  relationship("rId2", "styles", "styles.xml"),
})))
```

## a date's style

A date is a number, the days since 1899-12-30, and only its style says it
is a date. That count holds from 1900-03-01 on: Excel counts 1900 as a
leap year, so an earlier date is a day off, as [reading a
spreadsheet](xlsx.md) says. The styles part lists the styles a cell's `s`
indexes: here style 0 is plain and style 1 shows built-in format 14, a
date. The fonts, fills and borders are the fewest a spreadsheet program
asks for, and the `Normal` style each style is based on keeps a reader
from warning that the workbook has none.

```teal continue
assert(zip:add_file("xl/styles.xml", wrapped("styleSheet", { xmlns = main }, {
  { { kind = "start", name = "fonts" } }, element("font"), { { kind = "end", name = "fonts" } },
  { { kind = "start", name = "fills" } },
  { { kind = "start", name = "fill" } }, element("patternFill", { patternType = "none" }), { { kind = "end", name = "fill" } },
  { { kind = "start", name = "fill" } }, element("patternFill", { patternType = "gray125" }), { { kind = "end", name = "fill" } },
  { { kind = "end", name = "fills" } },
  { { kind = "start", name = "borders" } }, element("border"), { { kind = "end", name = "borders" } },
  { { kind = "start", name = "cellStyleXfs" } }, element("xf", { numFmtId = "0" }),
  { { kind = "end", name = "cellStyleXfs" } },
  { { kind = "start", name = "cellXfs" } },
  element("xf", { numFmtId = "0", xfId = "0" }),
  element("xf", { numFmtId = "14", xfId = "0", applyNumberFormat = "1" }),
  { { kind = "end", name = "cellXfs" } },
  { { kind = "start", name = "cellStyles" } }, element("cellStyle", { name = "Normal", xfId = "0", builtinId = "0" }),
  { { kind = "end", name = "cellStyles" } },
})))

local epoch = assert(Time.parse_date("1899-12-30"))
local function serial(date: string): integer
  return (assert(Time.parse_date(date)) - epoch) // (86400 * 1000000000)
end
```

## the sheet

A cell's `r` names its place: its column's letters and its row's number.
Text is written in the cell as an inline string, which needs no shared
strings part; a number goes in `v`, in the fewest digits that read back
to it; a boolean is `t="b"` and 0 or 1; a
date is its serial with style 1.

A sheet can be large, so it is written with [`Xml.writer`], a row at a
time, straight into its entry in the zip: [`Zip.Writer`]'s `file_writer`
answers a [`Stream.Writer`] that compresses the body as it comes, so the
sheet is never held whole. Closing the XML writer closes the entry.

```teal continue
local function column(n: integer): string
  local letters = ""
  while n > 0 do
    letters = string.char(65 + (n - 1) % 26) .. letters
    n = (n - 1) // 26
  end
  return letters
end

--- A number as the fewest digits that read back to it; a cell holds no NaN or
--- infinity, which no spreadsheet reads.
local function number_text(n: number): string
  assert(n == n and n ~= math.huge and n ~= -math.huge, "a cell holds no NaN or infinity")
  for digits = 15, 16 do
    local text = string.format("%." .. tostring(digits) .. "g", n)
    if tonumber(text) == n then return text end
  end
  return string.format("%.17g", n)
end

local function cell(ref: string, value: Value): {Xml.Event}
  if value is string then
    return {
      { kind = "start", name = "c", attributes = { r = ref, t = "inlineStr" } },
      { kind = "start", name = "is" }, { kind = "start", name = "t" }, { kind = "text", text = value },
      { kind = "end", name = "t" }, { kind = "end", name = "is" }, { kind = "end", name = "c" },
    }
  end
  local attributes: mut {string: string} = { r = ref }
  local v: string
  if value is boolean then
    attributes["t"] = "b"
    v = if value then "1" else "0" end
  elseif value is number then
    v = number_text(value)
  else
    attributes["s"] = "1"
    v = tostring(serial(value.date))
  end
  return {
    { kind = "start", name = "c", attributes = attributes },
    { kind = "start", name = "v" }, { kind = "text", text = v }, { kind = "end", name = "v" },
    { kind = "end", name = "c" },
  }
end

local sheet = Xml.writer((assert(zip:file_writer("xl/worksheets/sheet1.xml"))))
assert(sheet:write({
  { kind = "start", name = "worksheet", attributes = { xmlns = main } },
  { kind = "start", name = "sheetData" },
}))
for r, row in ipairs(rows) do
  local events: mut {Xml.Event} = { { kind = "start", name = "row", attributes = { r = tostring(r) } } }
  for c, value in ipairs(row) do
    for _, e in ipairs(cell(column(c) .. tostring(r), value)) do events[#events + 1] = e end
  end
  events[#events + 1] = { kind = "end", name = "row" }
  assert(sheet:write(events))
end
assert(sheet:write({ { kind = "end", name = "sheetData" }, { kind = "end", name = "worksheet" } }))
assert(sheet:close())
assert(zip:close())
```

## reading it back

The workbook is read back from the zip's bytes: each row of the sheet,
each cell as its text or its `v`, with its style where it has one.

```teal continue
local book = assert(Zip.open_string(out:result()))
local entry = assert(book:entry("xl/worksheets/sheet1.xml"))
local root = assert(Xml.tree(assert(Stream.read_all((assert(entry:open())))), { local_names = true }))
for _, row in ipairs(Xml.children(assert(Xml.child(root, "sheetData")), "row")) do
  local cells: mut {string} = {}
  for _, c in ipairs(Xml.children(row, "c")) do
    local style = c.attributes["s"]
    local text = Xml.text(c) .. (if style ~= nil then " (style " .. style .. ")" else "" end)
    cells[#cells + 1] = text
  end
  print(table.concat(cells, ","))
end
assert(book:close())
```

```output
Region,Total,Closed,When
North & East,1250.5,1,45658 (style 1)
South,980,0,45702 (style 1)
```

## going further

- The zip itself goes to a file rather than a collector with
  [`Zip.writer`] over [`Stream.create`], so a workbook of any size is
  written without being held.
- Text repeated across many cells is smaller in a shared strings part,
  each cell holding its string's index, as [reading a
  spreadsheet](xlsx.md) reads them.
- More sheets are more `sheet` elements, relationships, content type
  overrides and sheet parts, each named alike.
- Text that begins or ends with spaces keeps them only where its `t`
  says `xml:space="preserve"`.

[`cosmic.time`]: ../../cosmic/time.tl
[`cosmic.xml`]: ../../cosmic/xml.tl
[`cosmic.zip`]: ../../cosmic/zip.tl
[`Stream.create`]: ../../cosmic/stream.tl
[`Stream.Writer`]: ../../cosmic/stream.tl
[`Xml.write`]: ../../cosmic/xml.tl
[`Xml.writer`]: ../../cosmic/xml.tl
[`Zip.Writer`]: ../../cosmic/zip.tl
