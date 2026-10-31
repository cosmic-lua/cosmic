--- Worked examples for [`cosmic.csv`], shown by `cosmic docs` and run by
--- `cosmic test`.

local Csv = require("cosmic.csv")
local Sqlite = require("cosmic.sqlite")

local Example = {}

--- Records keep quoted commas, quotes and line breaks; every field is
--- a string, and nothing is read as a number.
function Example.parse()
  local records, err = Csv.parse('id,name\n1,"Smith, Ann"\n2,"say ""hi"""\n')
  assert(records ~= nil, err)
  local smith, say = assert(records[2]), assert(records[3])
  assert(#records == 3 and smith[2] == "Smith, Ann" and say[2] == 'say "hi"')
end

--- `table` names the columns from the header, keys each record by them,
--- and refuses a record of another length, naming its line.
function Example.table()
  local made, err = Csv.table("id,name\r\n1,Ann\r\n2,Bob\r\n")
  assert(made ~= nil, err)
  assert(table.concat(made.columns, ",") == "id,name")
  local bob = assert(made.rows[2])
  assert(bob["name"] == "Bob")
  local none, why = Csv.table("id,name\n1\n")
  assert(none == nil)
  print(why) -- csv: line 2, column 1: the record has 1 field, the header 2
end

--- A row the caller refuses is named by its line: here the second
--- row's record begins on line 5, after a quoted line break and a blank
--- line.
function Example.lines()
  local made = assert(Csv.table('id,note\n1,"two\nlines"\n\n2,x\n'))
  local second = assert(made.rows[2])
  assert(second["id"] == "2" and made.lines[1] == 2 and made.lines[2] == 5)
  for index, row in ipairs(made.rows) do
    if row["note"] == "x" then
      print("line " .. tostring(made.lines[index]) .. ": a note too short") -- line 5: a note too short
    end
  end
end

--- `records` is `parse` with each record's line, so a caller can skip a
--- ragged record, saying where it was, instead of refusing the file as
--- `table` does.
function Example.records()
  local rows = assert(Csv.records('id,name\n1\n\n2,"Bo\nb"\n'))
  for _, row in ipairs(rows) do
    if #row.fields ~= 2 then
      print(("line %d: skipped"):format(row.line)) -- line 2: skipped
    end
  end
  local last = assert(rows[3])
  assert(#rows == 3 and last.line == 4 and last.fields[2] == "Bo\nb")
end

--- A tab-separated file is the same reader with another delimiter.
function Example.tsv()
  local records = assert(Csv.parse("a\tb,c\n1\t\n", { delimiter = "\t" }))
  local header, data = assert(records[1]), assert(records[2])
  assert(header[2] == "b,c" and data[2] == "")
end

--- Header fields that are empty or differ only in case are renamed, so
--- every column has a name of its own; `reserved` keeps a name free.
function Example.column_names()
  local names = Csv.column_names({ "id", "ID", "", "id" }, { "rowid" })
  assert(table.concat(names, ",") == "id,ID_2,_,id_3")
  assert(Csv.column_names({ "rowid" }, { "rowid" })[1] == "rowid_2")
end

--- `load` copies CSV into a table, in C, and types plain numbers, so a
--- query compares them as numbers.
function Example.load()
  local db = assert(Sqlite.memory())
  local loaded = assert(Csv.load(db, "sales", { text = "city,amount\nParis,120\nLagos,95.5\n" }))
  assert(loaded.count == 2)
  local rows = assert(Sqlite.text_rows(db, "SELECT city FROM sales WHERE amount > 100"))
  local paris = assert(rows[1])
  assert(#rows == 1 and paris:text(1) == "Paris")
  assert(db:close())
end

return Example
