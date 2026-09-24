local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local todos = require("build.todos")

--- Lines joined into one file's text, so no line of this file opens
--- with a comment marker and is listed itself.
local function text(lines: {string}): string
  return table.concat(lines, "\n") .. "\n"
end

local function test_a_todo_carries_on_through_its_paragraph()
  local found = todos.scan(text({
    "local x = 1",
    "  -- TODO: drop the cast once the pin names a cosmic",
    "  -- carrying patch/tl/24.",
    "  --",
    "  -- Not part of it.",
    "  return x",
  }))
  assert(#found == 1, "found " .. #found)
  assert(found[1].line == 2 and found[1].last == 3)
  assert(found[1].text ==
    "drop the cast once the pin names a cosmic carrying patch/tl/24.",
    found[1].text)
end

local function test_a_paragraph_ends_at_code_a_new_marker_or_the_next_todo()
  local found = todos.scan(text({
    "# TODO: first",
    "# TODO: second",
    "  # indented, so another comment",
    "-- TODO: third",
    "x = 1",
    "--- TODO: fourth",
    "-- another marker",
  }))
  assert(#found == 4, "found " .. #found)
  for index, want in ipairs({ "first", "second", "third", "fourth" }) do
    assert(found[index].text == want, found[index].text)
    assert(found[index].last == found[index].line)
  end
end

local function test_a_sentence_opened_on_a_new_line_starts_a_new_paragraph()
  local found = todos.scan(text({
    "#!/bin/sh",
    "# TODO: replace with a Teal script run by `cosmic --standalone`,",
    "# as bin/zig is.",
    "# Runs this checkout's CI job on this machine.",
  }))
  assert(#found == 1 and found[1].last == 3, found[1] and found[1].last)
  assert(found[1].text ==
    "replace with a Teal script run by `cosmic --standalone`, as bin/zig is.",
    found[1].text)
end

local function test_block_comments_and_other_markers()
  local found = todos.scan(text({
    "/* TODO: a block comment",
    " * that goes on */",
    "// TODO: a line comment",
    ";; TODO: lisp */",
  }))
  assert(#found == 3, "found " .. #found)
  assert(found[1].text == "a block comment that goes on", found[1].text)
  assert(found[1].last == 2)
  assert(found[2].text == "a line comment", found[2].text)
  assert(found[3].text == "lisp", found[3].text)
end

local function test_todo_outside_a_comment_of_its_own_is_not_one()
  local found = todos.scan(text({
    "Leave `TODO:` comments as the work goes.",
    "x = 1 -- TODO: after code",
    "s = \"-- TODO: in a string\"",
    "--TODO: no space after the marker",
    "-- a TODO: not at the start",
    "-> TODO: not a marker",
  }))
  assert(#found == 0, "found " .. #found)
end

local function test_crlf_and_a_missing_final_newline()
  local found = todos.scan("-- TODO: one\r\n-- two\r\nx")
  assert(#found == 1 and found[1].text == "one two", found[1] and found[1].text)
  found = todos.scan("# TODO: last line")
  assert(#found == 1 and found[1].text == "last line")
end

local function test_parse_blame_reads_line_porcelain()
  local a = string.rep("a", 40)
  local zero = string.rep("0", 40)
  local found = todos.parse_blame(text({
    a .. " 10 12 1",
    "author A",
    "author-time 1700000000",
    "summary fix: something",
    "boundary",
    "filename x.tl",
    "\t-- TODO: one",
    zero .. " 30 31 1",
    "author Not Committed Yet",
    "author-time 1800000000",
    "summary Version of x.tl from x.tl",
    "filename x.tl",
    "\t-- TODO: two",
  }))
  local one = found[12]
  assert(one ~= nil and one.commit == a and one.author_time == 1700000000)
  assert(one.summary == "fix: something" and one.boundary)
  local two = found[31]
  assert(two ~= nil and two.commit == zero and not two.boundary)
  assert(found[10] == nil and found[30] == nil)
end

local function test_date_is_utc()
  assert(todos.date(0) == "1970-01-01")
  assert(todos.date(951782400) == "2000-02-29", todos.date(951782400))
  assert(todos.date(1700000000) == "2023-11-14", todos.date(1700000000))
  assert(todos.date(4107542400 - 1) == "2100-02-28", todos.date(4107542400 - 1))
end

local function test_render_marks_unblamed_and_boundary_rows()
  local row: todos.Todo = {
    file = "a.tl", line = 3, last = 3, text = "do it", commit = "",
    author_time = 0, summary = "", boundary = false,
  }
  assert(todos.render(row) == "a.tl:3: ---------- ------- do it", todos.render(row))
  row.commit = "0123456789abcdef0123456789abcdef01234567"
  row.author_time = 1700000000
  row.boundary = true
  assert(todos.render(row) == "a.tl:3: 2023-11-14 ^0123456 do it", todos.render(row))
end

local function test_index_keeps_rows_until_a_file_moves()
  local root = assert(Fs.mkdtemp("cosmic-todos-test-"))
  assert(Fs.mkdirs(root .. "/src"))
  assert(Fs.mkdirs(root .. "/o"))
  assert(Fs.write(root .. "/src/a.tl", text({ "-- TODO: first", "local x = 1" })))
  assert(Fs.write(root .. "/o/skipped.tl", text({ "-- TODO: generated" })))
  assert(Fs.write(root .. "/src/b.tl", text({ "local y = 2" })))
  local db = assert(Sqlite.memory())

  local first = assert(todos.index(db, root))
  assert(#first.todos == 1, "found " .. #first.todos)
  assert(first.todos[1].file == "src/a.tl" and first.todos[1].text == "first")

  -- An unchanged file is answered from its rows...
  assert(Sqlite.run(db, "UPDATE todos SET text = 'from the index'"))
  local second = assert(todos.index(db, root))
  assert(second.todos[1].text == "from the index", second.todos[1].text)

  -- So is one the rule would read differently now.
  local rule = todos.rule
  todos.rule = rule .. "-next"
  local reread = assert(todos.index(db, root))
  todos.rule = rule
  assert(reread.todos[1].text == "first", reread.todos[1].text)

  -- A file that moved is read again, and one with no TODO left is dropped.
  assert(Fs.write(root .. "/src/b.tl", text({ "# TODO: second" })))
  assert(Fs.write(root .. "/src/a.tl", text({ "local x = 1" })))
  local third = assert(todos.index(db, root))
  assert(#third.todos == 1 and third.todos[1].file == "src/b.tl")
  local rows = assert(Sqlite.text_rows(db, "SELECT path FROM todos"))
  assert(#rows == 1 and rows[1][1] == "src/b.tl")
  db:close()
  assert(Fs.remove_tree(root))
end
