--- `cosmic todos`: every `TODO:` comment in the tree, indexed into
--- `o/build.db`, each with the commit that last touched its line and
--- when -- what `git blame` says about it.
---
--- A TODO is a comment line whose text opens with `TODO:` after the
--- comment's own marker (`--`, `---`, `#`, `//`, `/*`, `*`, `;`), and
--- the lines under it that carry on the same paragraph: the same
--- indentation and marker, with text, up to a blank comment line, a
--- line that is not a comment, the next TODO, or a line that opens a
--- sentence after one that ended one -- a script's header often runs
--- its TODO straight into what the script does, with no blank line. A `TODO:` anywhere
--- else on a line -- in a string, in prose, after code -- is not one,
--- so a test can hold the text of a TODO without being listed.
---
--- The index is `todos` in `o/build.db`, one row per TODO, keyed by its
--- file and first line. A row is kept while its file hashes the same
--- and `HEAD` names the same commit, since blame is a function of the
--- two, so a run after an edit blames only the files that moved. With
--- no git, or outside a repository, TODOs are still found and listed,
--- with no commit.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local clock = require("build.clock")
local reboot = require("build.reboot")

local record todos
  --- One TODO where it is written: its first line, its last, and its
  --- text, the paragraph's lines joined by single spaces.
  record Found
    line: integer
    last: integer
    text: string
  end

  --- What blame says about one line.
  record Blame
    --- The commit's full hash; all zeros for a line not committed yet.
    commit: string
    --- When the commit was authored, in seconds since the epoch.
    author_time: integer
    --- The commit's subject line.
    summary: string
    --- Whether the commit is the edge of a shallow history, so the line
    --- may be older than it says.
    boundary: boolean
  end

  --- One row of the index.
  record Todo
    file: string
    line: integer
    last: integer
    text: string
    --- "" when the line was not blamed: no git, a file git does not
    --- track, or a line not committed yet.
    commit: string
    author_time: integer
    summary: string
    boundary: boolean
  end

  schema: string
  rule: string
end

--- The version of what `scan` finds in a file's text. A row's `sha256`
--- hashes it with the bytes, so a change to the rule bumps it and
--- every file is scanned again rather than answered from rows the old
--- rule wrote.
todos.rule = "2"

--- The index's table, made in `o/build.db` beside the build's own.
--- `sha256` and `head` are what a row is a function of: the file's
--- bytes, hashed with `rule`, and the commit `HEAD` named when it was
--- blamed ("" for none).
todos.schema = [[CREATE TABLE IF NOT EXISTS todos (path TEXT NOT NULL,
                                                   line INTEGER NOT NULL,
                                                   last INTEGER NOT NULL,
                                                   text TEXT NOT NULL,
                                                   sha256 TEXT NOT NULL,
                                                   head TEXT NOT NULL,
                                                   commit_id TEXT NOT NULL,
                                                   author_time INTEGER NOT NULL,
                                                   summary TEXT NOT NULL,
                                                   boundary INTEGER NOT NULL,
                                                   PRIMARY KEY (path, line)) WITHOUT ROWID]]

local function report(line: string)
  Fs.put(Fs.stdout, line .. "\n")
end

local function complain(line: string)
  Fs.put(Fs.stderr, "cosmic: " .. line .. "\n")
end

--- The comment markers a TODO may follow.
local markers: {string:boolean} = {
  ["--"] = true,
  ["---"] = true,
  ["#"] = true,
  ["##"] = true,
  ["//"] = true,
  ["///"] = true,
  ["/*"] = true,
  ["/**"] = true,
  ["*"] = true,
  [";"] = true,
  [";;"] = true,
}

--- A line as a comment: its indentation, its marker, and its text with
--- the space after the marker dropped. nil for a line that is not a
--- comment on its own.
local function comment_of(line: string): string, string, string
  local indent, marker, rest = line:match("^([ \t]*)([-#/*;]+)(.*)$")
  if indent == nil or not markers[marker] then
    return nil, nil, nil
  end
  if rest ~= "" and not rest:match("^[ \t]") then
    return nil, nil, nil
  end
  rest = rest:gsub("^[ \t]+", ""):gsub("[ \t]*%*/[ \t]*$", ""):gsub("[ \t]+$", "")
  return indent, marker, rest
end

--- The marker a line carrying a comment on is written with: a block
--- comment's lines go on with `*`, a column in or not, every other
--- comment with its own.
local function continued(marker: string): string
  if marker:sub(1, 1) == "/" and marker:sub(2, 2) == "*" then
    return "*"
  end
  return marker
end

--- Every TODO in one file's text, in order.
function todos.scan(source: string): {todos.Found}
  local lines: {string} = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = (line:gsub("\r$", ""))
  end
  if source:sub(-1) == "\n" then
    lines[#lines] = nil
  end
  local found: {todos.Found} = {}
  local index = 1
  while index <= #lines do
    local indent, marker, rest = comment_of(lines[index])
    local text = rest ~= nil and rest:match("^TODO:[ \t]*(.*)$") or nil
    if text == nil then
      index = index + 1
    else
      local first = index
      local parts: {string} = { text }
      local following = continued(marker)
      index = index + 1
      while index <= #lines do
        local next_indent, next_marker, next_rest = comment_of(lines[index])
        local aligned = next_indent == indent or
          (following ~= marker and next_indent == indent .. " ")
        if not aligned or
          (next_marker ~= marker and next_marker ~= following) or
          next_rest == "" or next_rest:match("^TODO:") or
          (parts[#parts]:match("%.$") and next_rest:match("^%u")) then
          break
        end
        parts[#parts + 1] = next_rest
        index = index + 1
      end
      found[#found + 1] = {
        line = first,
        last = index - 1,
        text = table.concat(parts, " "),
      }
    end
  end
  return found
end

--- What `git blame --line-porcelain` said, by final line number.
function todos.parse_blame(porcelain: string): {integer:todos.Blame}
  local out: {integer:todos.Blame} = {}
  local current: todos.Blame = nil
  local final: integer = nil
  for line in porcelain:gmatch("([^\n]*)\n?") do
    local commit, at = line:match("^(%x+) %d+ (%d+)")
    if commit ~= nil and #commit >= 40 then
      final = math.tointeger(tonumber(at))
      current = { commit = commit, author_time = 0, summary = "", boundary = false }
    elseif current ~= nil then
      if line:sub(1, 1) == "\t" then
        if final ~= nil then
          out[final] = current
        end
        current = nil
        final = nil
      elseif line:sub(1, 12) == "author-time " then
        current.author_time = math.tointeger(tonumber(line:sub(13))) or 0
      elseif line:sub(1, 8) == "summary " then
        current.summary = line:sub(9)
      elseif line == "boundary" then
        current.boundary = true
      end
    end
  end
  return out
end

--- Runs git in `root`, its output when it succeeds.
local function git(root: string, args: {string}): string | nil
  local argv: {string} = { "/usr/bin/env", "git", "-C", root }
  for _, each in ipairs(args) do
    argv[#argv + 1] = each
  end
  local result = Child.run(argv, { stdin = "null", stdout = "capture", stderr = "null" })
  if result == nil or not result.ok or result.stdout == nil then
    return nil
  end
  return result.stdout
end

--- The commit `HEAD` names, or "" with no git or no repository.
local function head_of(root: string): string
  local out = git(root, { "rev-parse", "--verify", "-q", "HEAD" })
  if out == nil then
    return ""
  end
  return out:match("^(%x+)") or ""
end

--- Blame for the first line of each TODO in one file; empty when git
--- has nothing to say about the file.
local function blame(root: string, file: string,
                     found: {todos.Found}): {integer:todos.Blame}
  local args: {string} = { "blame", "--line-porcelain" }
  for _, todo in ipairs(found) do
    args[#args + 1] = "-L"
    args[#args + 1] = todo.line .. "," .. todo.line
  end
  args[#args + 1] = "--"
  args[#args + 1] = file
  local out = git(root, args)
  if out == nil then
    return {}
  end
  return todos.parse_blame(out)
end

--- Whether a commit hash is the one blame gives a line not committed.
local function uncommitted(commit: string): boolean
  return commit:match("^0+$") ~= nil
end

--- The directories never walked: generated output, vendored trees, and
--- anything hidden.
local function skip(entry: string, name: string): boolean
  if name:sub(1, 1) == "." then
    return true
  end
  return entry == "o" or entry == "vendor" or entry == "ci/o"
end

--- The largest file read for TODOs; anything bigger is data.
local largest = 4 * 1024 * 1024

--- One file's rows as the index holds them.
local record Cached
  sha256: string
  head: string
  rows: {todos.Todo}
end

local function cached_rows(db: Sqlite.Handle): {string:Cached} | nil, string
  local rows, trouble = Sqlite.rows(db,
    "SELECT path, line, last, text, sha256, head, commit_id, author_time, " ..
    "summary, boundary FROM todos ORDER BY path, line")
  if rows == nil then
    return nil, trouble
  end
  local out: {string:Cached} = {}
  for _, row in ipairs(rows) do
    local path = row[1].text
    local entry = out[path]
    if entry == nil then
      entry = { sha256 = row[5].text, head = row[6].text, rows = {} }
      out[path] = entry
    end
    entry.rows[#entry.rows + 1] = {
      file = path,
      line = row[2].integer,
      last = row[3].integer,
      text = row[4].text,
      commit = row[7].text,
      author_time = row[8].integer,
      summary = row[9].text,
      boundary = row[10].integer ~= 0,
    }
  end
  return out
end

--- Replaces one file's rows.
local function put_rows(db: Sqlite.Handle, file: string, sha256: string,
                        head: string, rows: {todos.Todo}): boolean, string
  local ok, trouble = Sqlite.run(db, "DELETE FROM todos WHERE path = ?1",
    { { text = file } })
  if not ok then
    return false, trouble
  end
  for _, todo in ipairs(rows) do
    ok, trouble = Sqlite.run(db,
      "INSERT INTO todos (path, line, last, text, sha256, head, commit_id, " ..
      "author_time, summary, boundary) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
      { { text = file }, { integer = todo.line }, { integer = todo.last },
        { text = todo.text }, { text = sha256 }, { text = head },
        { text = todo.commit }, { integer = todo.author_time },
        { text = todo.summary }, { integer = todo.boundary and 1 or 0 } })
    if not ok then
      return false, file .. ": " .. trouble
    end
  end
  return true, ""
end

--- What one pass of `todos.index` did.
local record Indexed
  todos: {todos.Todo}
  --- How many files were blamed, rather than answered from the index.
  blamed: integer
end

--- Brings the index in `db` up to date with the tree under `root`,
--- blaming only a file whose bytes or `HEAD` moved since its rows were
--- written, and returns every TODO, in file and line order.
function todos.index(db: Sqlite.Handle, root: string): Indexed | nil, string
  local made, trouble = db:exec(todos.schema)
  if not made then
    return nil, trouble
  end
  local walked, walk_trouble = Fs.walk(root, skip)
  if walked == nil then
    return nil, walk_trouble
  end
  local cached, cache_trouble = cached_rows(db)
  if cached == nil then
    return nil, cache_trouble
  end
  local head = head_of(root)
  local out: Indexed = { todos = {}, blamed = 0 }
  for _, file in ipairs(walked) do
    local st = Fs.stat(root .. "/" .. file)
    local data: string = nil
    if st ~= nil and st.size <= largest then
      data = Fs.read(root .. "/" .. file)
    end
    if data ~= nil and data:find("TODO:", 1, true) ~= nil and
      data:find("\0", 1, true) == nil then
      local sha256 = Hash.hex_sha256(todos.rule .. "\0" .. data)
      local was = cached[file]
      cached[file] = nil
      local rows: {todos.Todo}
      if was ~= nil and was.sha256 == sha256 and was.head == head then
        rows = was.rows
      else
        local found = todos.scan(data)
        local blamed: {integer:todos.Blame} = {}
        if head ~= "" and #found > 0 then
          blamed = blame(root, file, found)
          out.blamed = out.blamed + 1
        end
        rows = {}
        for _, todo in ipairs(found) do
          local said = blamed[todo.line]
          local known = said ~= nil and not uncommitted(said.commit)
          rows[#rows + 1] = {
            file = file,
            line = todo.line,
            last = todo.last,
            text = todo.text,
            commit = known and said.commit or "",
            author_time = known and said.author_time or 0,
            summary = known and said.summary or "",
            boundary = known and said.boundary or false,
          }
        end
        local ok, put_trouble = put_rows(db, file, sha256, head, rows)
        if not ok then
          return nil, put_trouble
        end
      end
      for _, row in ipairs(rows) do
        out.todos[#out.todos + 1] = row
      end
    end
  end
  for file in pairs(cached) do
    local ok, put_trouble = put_rows(db, file, "", "", {})
    if not ok then
      return nil, put_trouble
    end
  end
  return out
end

--- A time in seconds since the epoch as its UTC date, `YYYY-MM-DD`.
function todos.date(seconds: integer): string
  -- Howard Hinnant's days-to-civil, for the proleptic Gregorian calendar.
  local z = seconds // 86400 + 719468
  local era = z // 146097
  local doe = z - era * 146097
  local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
  local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
  local mp = (5 * doy + 2) // 153
  local day = doy - (153 * mp + 2) // 5 + 1
  local month = mp < 10 and mp + 3 or mp - 9
  local year = yoe + era * 400 + (month <= 2 and 1 or 0)
  return string.format("%04d-%02d-%02d", year, month, day)
end

--- One TODO as `todos` lists it: where, when, which commit, and what.
function todos.render(todo: todos.Todo): string
  local when = "----------"
  local commit = "-------"
  if todo.commit ~= "" then
    when = todos.date(todo.author_time)
    commit = (todo.boundary and "^" or "") .. todo.commit:sub(1, 7)
  end
  return todo.file .. ":" .. todo.line .. ": " .. when .. " " .. commit ..
    " " .. todo.text
end

--- Whether a TODO's file is one of the paths asked for, or under one.
local function wanted(file: string, paths: {string}): boolean
  if #paths == 0 then
    return true
  end
  for _, path in ipairs(paths) do
    if file == path or file:sub(1, #path + 1) == path .. "/" then
      return true
    end
  end
  return false
end

--- `cosmic todos [--oldest] [path...]`: indexes the tree's TODOs and
--- lists them, one per line, in file order or, with `--oldest`, oldest
--- commit first, then a verdict line.
--- @param argv the command line, re-entered if this binary embeds a
---   stale copy of `build.todos` itself -- see `build.reboot.ensure`
function todos.run(argv: {integer:string}): integer
  local started = Time.monotonic_ns() or 0
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    complain(root_trouble)
    return 1
  end
  local code, reboot_trouble = reboot.ensure(root, argv)
  if code ~= nil then
    if reboot_trouble ~= "" then
      complain(reboot_trouble)
    end
    return code
  end
  local oldest = false
  local paths: {string} = {}
  local slot = 2
  while argv[slot] ~= nil do
    local option = argv[slot]
    if option == "--oldest" then
      oldest = true
    elseif option:sub(1, 1) == "-" then
      complain("todos: no such option: " .. option)
      return 2
    else
      paths[#paths + 1] = (option:gsub("^%./", ""):gsub("/+$", ""))
    end
    slot = slot + 1
  end

  local made, mkdir_trouble = Fs.mkdirs(root .. "/o")
  if not made then
    complain(mkdir_trouble)
    return 1
  end
  local path = root .. "/o/build.db"
  local db, open_trouble = Sqlite.open(path, true)
  if db == nil then
    complain(path .. ": " .. open_trouble)
    return 1
  end
  local indexed: Indexed = nil
  local ok, trouble = Sqlite.transact(db, function(): boolean, string
    local result, why = todos.index(db, root)
    if result == nil then
      return false, why
    end
    indexed = result
    return true, ""
  end)
  db:close()
  if not ok then
    complain(path .. ": " .. trouble)
    return 1
  end

  local listed: {todos.Todo} = {}
  for _, todo in ipairs(indexed.todos) do
    if wanted(todo.file, paths) then
      listed[#listed + 1] = todo
    end
  end
  if oldest then
    -- Unblamed rows last: a TODO not committed yet is the newest there is.
    table.sort(listed, function(a: todos.Todo, b: todos.Todo): boolean
      local a_known, b_known = a.commit ~= "", b.commit ~= ""
      if a_known ~= b_known then
        return a_known
      end
      if a.author_time ~= b.author_time then
        return a.author_time < b.author_time
      end
      if a.file ~= b.file then
        return a.file < b.file
      end
      return a.line < b.line
    end)
  end
  local files: {string:boolean} = {}
  local file_count = 0
  for _, todo in ipairs(listed) do
    report(todos.render(todo))
    if not files[todo.file] then
      files[todo.file] = true
      file_count = file_count + 1
    end
  end
  report("todos: PASS (" .. #listed .. " todos in " .. file_count .. " files, " ..
    indexed.blamed ..
    " files blamed, " .. clock.elapsed_ms(started) .. " ms)")
  return 0
end

return todos
