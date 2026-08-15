#!/usr/bin/env cosmic
-- The reader every document ratchet stands on.
--
-- A ratchet that reads no rows passes everything, silently, and reads
-- exactly like a ratchet that read them all. That is the failure worth
-- testing for here: not "does it parse a table" but "does it come back
-- empty when it should have found something, and does it stop at the
-- heading it was given".

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local ratchet = require("_build.ratchet")

local DOC < const > = [[
# a document

## Verbs

| verb | what it does | today |
|---|---|---|
| `build` | compile the tree | yes |
| `reproducible` `offline` | policy lanes | planned |

prose between the tables.

## The project model

| marker | declares |
|:--|--:|
| `*_test.tl` | a test |
| everything else | never embedded |
]]

--- The fixture document, written into this run's temp directory.
--- @return string The path
local function doc(): string
  local path = fs.join(check.must(os.getenv("TEST_TMPDIR")), "doc.md")
  assert(fs.write(path, DOC))
  return path
end

--- The first cells of some rows.
--- @param rows {ratchet.Row} The rows
--- @return {string} Their cells, in order
local function cells(rows: {ratchet.Row}): {string}
  local out: {string} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = row.cell
  end
  return out
end

-- A heading confines the scan, and the header row and separator are
-- not rows. The separator pattern has to admit alignment colons --
-- `|:--|--:|` is a separator, and a reader that took it for a row
-- would report a cell of dashes as something the document teaches.
local function test_a_heading_confines_the_scan()
  local path = doc()
  local got = cells(check.must(ratchet.rows(path, "Verbs", "verb")))
  assert(#got == 2, "expected the two verb rows, got " .. #got ..
    ": " .. table.concat(got, " / "))
  assert(got[1] == "`build`", "got: " .. got[1])
  assert(got[2] == "`reproducible` `offline`", "got: " .. got[2])

  local model = cells((check.must(ratchet.rows(path, "The project model",
          "marker"))))
  assert(#model == 2, "expected the two model rows, got " .. #model)
  assert(model[1] == "`*_test.tl`", "got: " .. model[1])
end
test_a_heading_confines_the_scan()

-- No heading is every table in the file. This is what the checks that
-- sweep a whole document for a disallowed word use, and a reader that
-- quietly scoped itself to the first table would let the rest through.
local function test_no_heading_reads_every_table()
  local got = cells(check.must(ratchet.rows(doc())))
  assert(#got == 6, "expected every row of both tables plus the two " ..
    "unfiltered headers, got " .. #got .. ": " .. table.concat(got, " / "))
end
test_no_heading_reads_every_table()

-- A heading that is not there returns no rows rather than falling back
-- to the whole file. Empty is the honest answer; the CALLER is what
-- must refuse it, which is why every ratchet asserts on the count.
local function test_a_missing_heading_finds_nothing()
  local got = check.must(ratchet.rows(doc(), "Nonexistent", "verb"))
  assert(#got == 0, "a heading that is not in the document must " ..
    "match nothing, got " .. #got .. " rows")
end
test_a_missing_heading_finds_nothing()

-- A row's subject can name more than one thing.
local function test_a_cell_yields_its_backticked_names()
  local two = ratchet.names("`reproducible` `offline`")
  assert(#two == 2 and two[1] == "reproducible" and two[2] == "offline",
    "got: " .. table.concat(two, ", "))
  assert(#ratchet.names("everything else") == 0,
    "a cell with no backticks names nothing")
  local one = ratchet.names("`cmd/<name>/embed_gen.tl`")
  assert(#one == 1 and one[1] == "cmd/<name>/embed_gen.tl",
    "got: " .. table.concat(one, ", "))
end
test_a_cell_yields_its_backticked_names()

-- `bearing` searches first cells by substring, never by pattern: a
-- marker is full of `*`, `.` and `-`, and matching it as a pattern is
-- how a check passes against a row it did not actually find.
local function test_bearing_finds_a_row_by_substring()
  local rows = check.must(ratchet.rows(doc(), "The project model", "marker"))
  local hit = check.must(ratchet.bearing(rows, "`*_test.tl`"))
  assert(hit.line:find("a test", 1, true), "the whole line comes back " ..
    "so a check can read the other cells: " .. hit.line)
  assert(hit.where:find("doc.md:", 1, true), "got: " .. hit.where)
  assert(not ratchet.bearing(rows, "`*_bench.tl`"), "a marker no row " ..
    "carries must not be found")
end
test_bearing_finds_a_row_by_substring()

-- A document that is not there is an error, not an empty table. The
-- distinction is the whole point: nothing found and nothing read look
-- identical downstream.
local function test_a_missing_document_is_an_error()
  local rows, err = ratchet.rows("no/such/doc.md")
  assert(not rows, "a missing document must not read as an empty table")
  assert(err:find("no/such/doc.md", 1, true), "got: " .. err)
end
test_a_missing_document_is_an_error()

print("all ratchet reader tests passed")
