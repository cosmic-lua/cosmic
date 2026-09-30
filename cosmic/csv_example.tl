--- Worked examples for [`cosmic.csv`], shown by `cosmic docs` and run by
--- `cosmic test`.

local Csv = require("cosmic.csv")

local Example = {}

--- Records keep quoted commas, quotes and line breaks; every field is
--- a string, and nothing is read as a number.
function Example.parse()
  local records, err = Csv.parse('id,name\n1,"Smith, Ann"\n2,"say ""hi"""\n')
  assert(records ~= nil, err)
  assert(#records == 3 and records[2][2] == "Smith, Ann" and records[3][2] == 'say "hi"')
end

--- `rows` keys each record by the header, and refuses a record of another
--- length, naming its line.
function Example.rows()
  local rows, err = Csv.rows("id,name\r\n1,Ann\r\n2,Bob\r\n")
  assert(rows ~= nil, err)
  assert(rows[2].name == "Bob")
  local none, why = Csv.rows("id,name\n1\n")
  assert(none == nil)
  print(why) -- line 2, column 1: the record has 1 field, the header 2
end

--- A tab-separated file is the same reader with another delimiter, and
--- `encode` writes what `parse` reads back.
function Example.encode()
  local text, err = Csv.encode({ { "a", "b\tc" }, { "d", "" } }, { delimiter = "\t" })
  assert(text ~= nil, err)
  local records = assert(Csv.parse(text, { delimiter = "\t" }))
  assert(records[1][2] == "b\tc" and records[2][2] == "")
end

return Example
