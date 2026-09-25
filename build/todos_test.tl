local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local todo_scan = require("build.todo_scan")
local todos = require("build.todos")
local narrow = require("build.narrow")
local work = require("build.work")
local observations = require("build.filesystem_observations")

-- What these tests start is git, the system's own.
observations.confine({})

--- Lines joined into one file's text, so no line of this file opens
--- with a comment marker and is listed itself.
local function text(lines: {string}): string
  return table.concat(lines, "\n") .. "\n"
end

local function test_a_todo_carries_on_through_its_paragraph()
  local found = todo_scan.scan(text({
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
  local found = todo_scan.scan(text({
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
  local found = todo_scan.scan(text({
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

local function test_a_c_comment_block()
  local found = todo_scan.scan(text({
    "/*",
    " * The allocator.",
    " *",
    " * TODO: keep blocks past 2 MiB too, once the",
    " * cache is bounded by bytes.",
    " */",
    "static int x;",
  }))
  assert(#found == 1 and found[1].line == 4 and found[1].last == 5)
  assert(found[1].text == "keep blocks past 2 MiB too, once the cache is bounded by bytes.",
    found[1].text)
end

local function test_block_comments_and_other_markers()
  local found = todo_scan.scan(text({
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
  local found = todo_scan.scan(text({
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
  local found = todo_scan.scan("-- TODO: one\r\n-- two\r\nx")
  assert(#found == 1 and found[1].text == "one two", found[1] and found[1].text)
  found = todo_scan.scan("# TODO: last line")
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

local function test_staging_indexes_what_it_reads_and_forgets_what_goes()
  local root = assert(Fs.mkdtemp("cosmic-todos-test-"))
  assert(Fs.mkdirs(root .. "/src"))
  assert(Fs.write(root .. "/src/a.tl", text({ "-- TODO: first", "local x = 1" })))
  assert(Fs.write(root .. "/src/b.tl", text({ "local y = 2" })))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local listed = assert(todos.list(handle.db, root)).todos
  assert(#listed == 1, "found " .. #listed)
  assert(listed[1].file == "src/a.tl" and listed[1].line == 1)
  assert(listed[1].text == "first" and listed[1].commit == "")

  -- Bytes already indexed are not scanned again, so their rows stand.
  assert(Sqlite.run(handle.db, "UPDATE todos SET text = 'from the index'"))
  assert(work.stage(handle, false))
  listed = assert(todos.list(handle.db, root)).todos
  assert(listed[1].text == "from the index", listed[1].text)

  -- A file that moved is read again, and bytes no file holds are dropped.
  assert(Fs.write(root .. "/src/b.tl", text({ "local y = 2", "  -- TODO: second" })))
  assert(Fs.write(root .. "/src/a.tl", text({ "local x = 1" })))
  assert(work.stage(handle, false))
  listed = assert(todos.list(handle.db, root)).todos
  assert(#listed == 1 and listed[1].file == "src/b.tl" and listed[1].line == 2)
  local rows = assert(Sqlite.text_rows(handle.db, "SELECT count(*) FROM todos"))
  assert(rows[1][1] == "1", rows[1][1])
  assert(work.close(handle))
  assert(Fs.remove_tree(root))
end

local function test_a_file_the_build_does_not_consume_is_scanned_all_the_same()
  local root = assert(Fs.mkdtemp("cosmic-todos-test-"))
  assert(Fs.mkdirs(root .. "/scripts"))
  assert(Fs.write(root .. "/scripts/release.sh",
    text({ "#!/bin/sh", "# TODO: sign the archive" })))
  assert(Fs.write(root .. "/big.txt",
    "# TODO: too big to be text\n" .. string.rep("x", 2 * 1024 * 1024)))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local listed = assert(todos.list(handle.db, root)).todos
  assert(#listed == 1, "found " .. #listed)
  assert(listed[1].file == "scripts/release.sh" and listed[1].line == 2)
  assert(listed[1].text == "sign the archive", listed[1].text)
  -- Scanned, not staged: nothing the build compiles or runs sees it.
  local rows = assert(Sqlite.text_rows(handle.db,
    "SELECT count(*) FROM files WHERE path = 'scripts/release.sh'"))
  assert(rows[1][1] == "0", rows[1][1])

  assert(Fs.remove(root .. "/scripts/release.sh"))
  assert(work.stage(handle, false))
  listed = assert(todos.list(handle.db, root)).todos
  assert(#listed == 0, "found " .. #listed)
  rows = assert(Sqlite.text_rows(handle.db, "SELECT count(*) FROM scanned"))
  assert(rows[1][1] == "0", rows[1][1])
  assert(work.close(handle))
  assert(Fs.remove_tree(root))
end

--- Runs git in `root`, for a test that builds a repository of its own.
local function git_in(root: string, args: {string}): boolean
  local argv: {string} = { assert(Proc.find("git")), "-C", root, "-c", "user.name=t",
    "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false" }
  for _, each in ipairs(args) do
    argv[#argv + 1] = each
  end
  local result = Child.run(argv, { stdin = "null", stdout = "null", stderr = "null" })
  return result ~= nil and result.ok
end

local function test_blame_carries_across_commits_that_leave_a_file_alone()
  local root = assert(Fs.mkdtemp("cosmic-todos-test-"))
  if not git_in(root, { "init", "-q" }) then
    assert(Fs.remove_tree(root))
    return
  end
  assert(Fs.write(root .. "/a.tl", text({ "-- TODO: first" })))
  assert(Fs.write(root .. "/b.tl", text({ "-- TODO: second" })))
  assert(git_in(root, { "add", "." }))
  assert(git_in(root, { "commit", "-q", "-m", "one" }))
  local handle = assert(work.open(root))
  local function listed(): {todos.Todo}, integer
    assert(work.stage(handle, false))
    local listing = assert(todos.list(handle.db, root))
    return listing.todos, listing.blamed
  end
  local all, blamed = listed()
  assert(blamed == 2, "blamed " .. blamed)
  assert(all[1].commit ~= "" and all[1].summary == "one", all[1].summary)

  -- A commit that touches neither file blames neither again.
  assert(Fs.write(root .. "/c.tl", text({ "local c = 3" })))
  assert(git_in(root, { "add", "c.tl" }))
  assert(git_in(root, { "commit", "-q", "-m", "two" }))
  all, blamed = listed()
  assert(blamed == 0, "blamed " .. blamed)
  assert(all[2].summary == "one", all[2].summary)

  -- One that touches a file blames that file alone.
  assert(Fs.write(root .. "/b.tl", text({ "-- TODO: second, reworded" })))
  assert(git_in(root, { "commit", "-q", "-am", "three" }))
  all, blamed = listed()
  assert(blamed == 1, "blamed " .. blamed)
  assert(all[1].summary == "one" and all[2].summary == "three", all[2].summary)

  -- A rewritten history may have dropped the commits a row names.
  assert(git_in(root, { "commit", "-q", "--amend", "-m", "three again" }))
  all, blamed = listed()
  assert(blamed == 2, "blamed " .. blamed)
  assert(all[2].summary == "three again", all[2].summary)
  assert(work.close(handle))
  assert(Fs.remove_tree(root))
end

local function test_search_takes_fts5_syntax_and_falls_back_to_words()
  local root = assert(Fs.mkdtemp("cosmic-todos-test-"))
  assert(Fs.write(root .. "/a.tl", text({
    "-- TODO: drop this cap once cosmic.sys carries ftruncate",
    "local a = 1",
    "-- TODO: read the JSON form once cosmic carries a decoder",
  })))
  assert(Fs.write(root .. "/b.sh", text({ "# TODO: replace with a Teal script" })))
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local all = assert(todos.list(handle.db, root)).todos
  local line_of: {integer:string} = {}
  for _, todo in ipairs(all) do
    line_of[todo.id] = todo.file .. ":" .. todo.line
  end
  local function found(query: string): {string}
    local ranks = assert(todos.search(handle.db, query))
    local out: {string} = {}
    for id, rank in pairs(ranks) do
      out[rank] = line_of[id]
    end
    return out
  end
  local hits = found("ftruncate")
  assert(#hits == 1 and hits[1] == "a.tl:1", table.concat(hits, " "))
  hits = found("ftrunc*")
  assert(#hits == 1 and hits[1] == "a.tl:1", table.concat(hits, " "))
  hits = found("\"cosmic carries\"")
  assert(#hits == 1 and hits[1] == "a.tl:3", table.concat(hits, " "))
  hits = found("decoder OR teal")
  assert(#hits == 2, table.concat(hits, " "))
  -- Not FTS5 syntax: its words, every one required.
  hits = found("cosmic.sys")
  assert(#hits == 1 and hits[1] == "a.tl:1", table.concat(hits, " "))
  assert(#found("nowhere") == 0)

  -- The index follows the rows it is built over.
  assert(Fs.write(root .. "/a.tl", text({ "-- TODO: something else" })))
  assert(work.stage(handle, false))
  local function count(query: string): integer
    local n = 0
    for _ in pairs((assert(todos.search(handle.db, query)))) do
      n = n + 1
    end
    return n
  end
  assert(count("ftruncate") == 0)
  assert(count("else") == 1)
  assert(handle.db:exec("INSERT INTO todos_fts (todos_fts) VALUES ('integrity-check')"))
  assert(work.close(handle))
  assert(Fs.remove_tree(root))
end

local function test_a_path_naming_the_tree_or_a_directory_in_it_is_a_path()
  local made = assert(Fs.mkdtemp("cosmic-todos-test-"))
  local root = assert(Fs.absolute(made))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.mkdirs(root .. "/core"))
  assert(Fs.write(root .. "/build/a.tl", ""))
  -- Which of build/a.tl and core/b.tl the paths hold, then the words.
  local function split(argv: {string}): string
    local split_up = todos.arguments(root, argv)
    local held: {string} = {}
    for _, file in ipairs({ "build/a.tl", "core/b.tl" }) do
      if narrow.holds(split_up.paths, file) then
        held[#held + 1] = file
      end
    end
    return table.concat(held, ",") .. "|" .. table.concat(split_up.words, ",")
  end
  local both = "build/a.tl,core/b.tl"
  local cases: {{string}} = {
    -- The tree itself, however written, holds everything.
    { both .. "|", "." }, { both .. "|", "./" }, { both .. "|", root },
    { both .. "|", ".", "build" }, { both .. "|ftruncate", ".", "ftruncate" },
    -- A directory or file in it, however written, holds what is under it.
    { "build/a.tl|", "build" }, { "build/a.tl|", "./build/" },
    { "core/b.tl|", "build/../core" }, { "core/b.tl|", root .. "/core" },
    { "build/a.tl|", "build/a.tl" },
    -- A name nothing has is words; so is the empty word.
    { both .. "|ftruncate,cosmic.sys", "ftruncate", "cosmic.sys" },
    { both .. "|", "" },
    -- A place outside the tree is a path all the same, holding nothing.
    { "|", ".." },
  }
  for _, case in ipairs(cases) do
    local argv = table.move(case, 2, #case, 1, {})
    local got = split(argv)
    assert(got == case[1], table.concat(argv, " ") .. ": " .. got)
  end
  assert(#todos.arguments(root, { "" }).words == 1)
  assert(Fs.remove_tree(root))
end
