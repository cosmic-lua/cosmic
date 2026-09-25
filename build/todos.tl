--- `cosmic todos`: every `TODO:` comment in the tree, each with the
--- commit that last touched its line and when -- what `git blame` says
--- about it.
---
--- The index is built by the build itself: `build.work.stage` scans
--- each file it stages (`build.todo_scan`) in the moment it reads it,
--- into `todos` in `o/build.db`, so the one walk covers every file in
--- the tree: what the build consumes -- Teal, and in cosmic's own tree
--- the C core, build.zig and bin/zig -- and, fingerprinted in `scanned`
--- and read only when it moves, everything else it walks past: scripts,
--- and in cosmic's own tree `bin/`, `eval/` and `ci/`. Blame is kept beside it, in `blames`, and only this verb runs
--- git. With no git, or outside a repository, TODOs are still listed,
--- with no commit.

local Child = require("cosmic.child")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local clock = require("build.clock")
local reboot = require("build.reboot")
local tree = require("build.tree")
local work = require("build.work")

local log = require("build.verdict").log

local record todos
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
    --- Its row in `todos`, shared by every file with the same bytes:
    --- what `search` answers with.
    id: integer
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

  --- What `list` found: every TODO, and how many files it had to blame.
  record Listing
    todos: {Todo}
    blamed: integer
  end
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

--- How long one git call may take before it is ended and its answer
--- taken as none: a TODO is listed unblamed rather than not at all.
local git_timeout_ms = 30 * 1000

--- Runs git in `root`, its output when it succeeds.
local function git(root: string, args: {string}): string | nil
  local found, _ = Proc.find("git")
  if found == nil then
    return nil
  end
  local argv: {string} = { found, "-C", root }
  for _, each in ipairs(args) do
    argv[#argv + 1] = each
  end
  local result, _ = Child.run(argv, {
    stdin = "null", stdout = "capture", stderr = "null", timeout_ms = git_timeout_ms,
  })
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

--- How many `git blame` calls run at once: one per processor, up to a
--- few, since each is a short process mostly waiting on the disk.
local function blame_jobs(): integer
  return math.max(1, math.min(8, Proc.cpu_count()))
end

--- Blame for the first line of each TODO in several files, by file,
--- running the calls `blame_jobs` at a time; a file git has nothing to
--- say about maps to an empty table. Stops once `guard` has caught a
--- signal, every git ended.
local function blame_all(root: string, lines: {string:{integer}}, order: {string},
                         guard: Child.Guard | nil): {string:{integer:todos.Blame}}
  local out: {string:{integer:todos.Blame}} = {}
  local limit = blame_jobs()
  local running: {Child.Handle} = {}
  local file_of: {Child.Handle:string} = {}
  local deadline_of: {Child.Handle:integer} = {}
  local next_file = 1
  while next_file <= #order or #running > 0 do
    while #running < limit and next_file <= #order do
      local file = order[next_file]
      next_file = next_file + 1
      out[file] = {}
      local argv: {string} = { "/usr/bin/env", "git", "-C", root, "blame",
        "--line-porcelain" }
      for _, line in ipairs(lines[file]) do
        argv[#argv + 1] = "-L"
        argv[#argv + 1] = line .. "," .. line
      end
      argv[#argv + 1] = "--"
      argv[#argv + 1] = file
      local handle, _ = Child.start(argv, { stdin = "null", stdout = "capture", stderr = "null" })
      if handle ~= nil then
        running[#running + 1] = handle
        file_of[handle] = file
        deadline_of[handle] = Time.monotonic_ns() + git_timeout_ms * 1000000
      end
    end
    if #running == 0 then
      break
    end
    if guard ~= nil and guard:cancelled() ~= 0 then
      break
    end
    local done, trouble = Child.wait_any(running, 100)
    local now = Time.monotonic_ns()
    local still: {Child.Handle} = {}
    for _, handle in ipairs(running) do
      if rawequal(handle, done) then
        local result, _ = handle:wait()
        if result ~= nil and result.ok and result.stdout ~= nil then
          out[file_of[handle]] = todos.parse_blame(result.stdout)
        end
      elseif (done == nil and trouble ~= "") or now >= deadline_of[handle] then
        -- Supervision failed, or git ran past its time: the file's
        -- TODOs are listed unblamed.
        local _, _ = handle:close()
      else
        still[#still + 1] = handle
      end
    end
    running = still
  end
  for _, handle in ipairs(running) do
    local _, _ = handle:close()
  end
  return out
end

--- `blame_all` under a `Child.guard`: SIGINT or SIGTERM ends every git
--- still running, then this process when the guard closes, as
--- `build.test` does for its workers. Unguarded when this process
--- already holds a guard (`todos.run` called in-process under one),
--- where a signal acts as it would.
local function blame_files(root: string,
                           lines: {string:{integer}},
                           order: {string}): {string:{integer:todos.Blame}}
  local opened, _ = Child.guard()
  if opened == nil then return blame_all(root, lines, order, nil) end
  local guard <close> = opened
  return blame_all(root, lines, order, guard)
end

--- Whether a commit hash is the one blame gives a line not committed.
local function uncommitted(commit: string): boolean
  return commit:match("^0+$") ~= nil
end

--- Every TODO in the staged tree with what is known of its blame, in
--- file and line order: a row with no blame for `head` has `commit` ""
--- and `blamed` false.
local record Row
  todo: todos.Todo
  sha256: string
  blamed: boolean
end

local function rows_of(db: Sqlite.Handle, head: string): {Row} | nil, string
  local rows, trouble = Sqlite.rows(db,
    "SELECT f.path, t.line, t.last, t.text, t.sha256, b.commit_id, " ..
    "b.author_time, b.summary, b.boundary, t.id FROM " ..
    "(SELECT path, sha256 FROM files UNION SELECT path, sha256 FROM tool " ..
    "UNION SELECT path, sha256 FROM scanned) f " ..
    "JOIN todos t ON t.sha256 = f.sha256 " ..
    "LEFT JOIN blames b ON b.path = f.path AND b.line = t.line " ..
    "AND b.sha256 = t.sha256 AND b.head = ?1 " ..
    "ORDER BY f.path, t.line", { { text = head } })
  if rows == nil then
    return nil, trouble
  end
  local out: {Row} = {}
  for _, row in ipairs(rows) do
    local blamed = row[6].kind ~= "null"
    out[#out + 1] = {
      todo = {
        id = row[10].integer,
        file = row[1].text,
        line = row[2].integer,
        last = row[3].integer,
        text = row[4].text,
        commit = blamed and row[6].text or "",
        author_time = blamed and row[7].integer or 0,
        summary = blamed and row[8].text or "",
        boundary = blamed and row[9].integer ~= 0,
      },
      sha256 = row[5].text,
      blamed = blamed,
    }
  end
  return out
end

--- Moves the blame recorded at an earlier `HEAD` on to `head`, for
--- every file the commits between them did not touch: git blames such
--- a file's lines on the same commits as before. That takes two git
--- calls per earlier `HEAD`, whatever the number of files. A file they
--- touched, or every file when the earlier `HEAD` is not an ancestor of
--- this one -- a rebase or a reset, which may have dropped the commits
--- the rows name -- is left to be blamed again.
local function carry_forward(db: Sqlite.Handle, root: string, head: string): boolean, string
  if head == "" then
    return true, ""
  end
  local heads, trouble = Sqlite.text_rows(db,
    "SELECT DISTINCT head FROM blames WHERE head != ?1 AND head != ''",
    { { text = head } })
  if heads == nil then
    return false, trouble
  end
  for _, row in ipairs(heads) do
    local old = row[1]
    local ancestor = git(root, { "merge-base", "--is-ancestor", old, head })
    local changed: string = nil
    if ancestor ~= nil then
      changed = git(root, { "diff", "--name-only", "--no-renames", "--relative",
        old, head, "--" })
    end
    if changed ~= nil then
      local touched: {string:boolean} = {}
      for path in changed:gmatch("([^\n]+)") do
        touched[path] = true
      end
      local kept, rows_trouble = Sqlite.text_rows(db,
        "SELECT DISTINCT path FROM blames WHERE head = ?1", { { text = old } })
      if kept == nil then
        return false, rows_trouble
      end
      for _, each in ipairs(kept) do
        if not touched[each[1]] then
          local ok, move_trouble = Sqlite.run(db,
            "UPDATE blames SET head = ?1 WHERE head = ?2 AND path = ?3",
            { { text = head }, { text = old }, { text = each[1] } })
          if not ok then
            return false, move_trouble
          end
        end
      end
    end
  end
  return true, ""
end

--- Blames every row not yet blamed for `head`, one git call per file,
--- keeping what it says in `blames`, and drops the rows there no TODO
--- stands on any more. Returns how many files it blamed.
local function blame_rows(db: Sqlite.Handle, root: string, head: string,
                          rows: {Row}): integer | nil, string
  local pruned, prune_trouble = Sqlite.run(db,
    "DELETE FROM blames WHERE head != ?1 OR NOT EXISTS (SELECT 1 FROM " ..
    "(SELECT path, sha256 FROM files UNION SELECT path, sha256 FROM tool " ..
    "UNION SELECT path, sha256 FROM scanned) f " ..
    "JOIN todos t ON t.sha256 = f.sha256 WHERE f.path = blames.path " ..
    "AND t.line = blames.line AND t.sha256 = blames.sha256)",
    { { text = head } })
  if not pruned then
    return nil, prune_trouble
  end
  if head == "" then
    return 0
  end
  local order: {string} = {}
  local pending: {string:{Row}} = {}
  for _, row in ipairs(rows) do
    if not row.blamed then
      local file = row.todo.file
      if pending[file] == nil then
        pending[file] = {}
        order[#order + 1] = file
      end
      table.insert(pending[file], row)
    end
  end
  local lines: {string:{integer}} = {}
  for _, file in ipairs(order) do
    lines[file] = {}
    for _, row in ipairs(pending[file]) do
      table.insert(lines[file], row.todo.line)
    end
  end
  local blamed = blame_files(root, lines, order)
  for _, file in ipairs(order) do
    local said = blamed[file]
    for _, row in ipairs(pending[file]) do
      local line = said[row.todo.line]
      local known = line ~= nil and not uncommitted(line.commit)
      local todo = row.todo
      todo.commit = known and line.commit or ""
      todo.author_time = known and line.author_time or 0
      todo.summary = known and line.summary or ""
      todo.boundary = known and line.boundary or false
      local ok, trouble = Sqlite.run(db,
        "INSERT OR REPLACE INTO blames (path, line, sha256, head, commit_id, " ..
        "author_time, summary, boundary) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        { { text = file }, { integer = todo.line }, { text = row.sha256 },
          { text = head }, { text = todo.commit }, { integer = todo.author_time },
          { text = todo.summary }, { integer = todo.boundary and 1 or 0 } })
      if not ok then
        return nil, file .. ": " .. trouble
      end
    end
  end
  return #order
end

--- Every TODO in the tree staged into `db`, blamed where git can,
--- in file and line order, and how many files had to be blamed.
function todos.list(db: Sqlite.Handle, root: string): todos.Listing | nil, string
  local head = head_of(root)
  local carried, carry_trouble = carry_forward(db, root, head)
  if not carried then
    return nil, carry_trouble
  end
  local rows, trouble = rows_of(db, head)
  if rows == nil then
    return nil, trouble
  end
  local blamed, blame_trouble = blame_rows(db, root, head, rows)
  if blamed == nil then
    return nil, blame_trouble
  end
  local out: {todos.Todo} = {}
  for _, row in ipairs(rows) do
    out[#out + 1] = row.todo
  end
  return { todos = out, blamed = blamed }, ""
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

--- `query`'s words as an FTS5 query every one of them must match, each
--- quoted so it reads as a literal rather than as FTS5 syntax -- as
--- `cosmic docs` searches.
local function quoted_words(query: string): string
  local words: {string} = {}
  for word in query:gmatch("[%w_]+") do
    words[#words + 1] = '"' .. word .. '"'
  end
  return table.concat(words, " ")
end

--- The TODOs whose text matches `query`, as the rank of each by `id`,
--- best first from 1. The query is FTS5's own syntax -- a "phrase",
--- OR, a prefix* -- when it parses as that, and its words, each quoted
--- and every one required, when it does not (`cosmic.sys`).
function todos.search(db: Sqlite.Handle, query: string): {integer:integer} | nil, string
  local sql = "SELECT rowid FROM todos_fts WHERE todos_fts MATCH ?1 ORDER BY rank"
  local first, _ = Sqlite.text_rows(db, sql, { { text = query } })
  local rows: {{string}} = {}
  if first ~= nil then
    rows = first
  else
    local words = quoted_words(query)
    if words == "" then
      return {}
    end
    local retried, trouble = Sqlite.text_rows(db, sql, { { text = words } })
    if retried == nil then
      return nil, trouble
    end
    rows = retried
  end
  local out: {integer:integer} = {}
  for index, row in ipairs(rows) do
    local id = math.tointeger(tonumber(row[1]))
    if id ~= nil then out[id] = index end
  end
  return out
end

--- Whether a TODO's file is one of the paths asked for, or under one.
local function wanted(file: string, paths: {string}): boolean
  if #paths == 0 then
    return true
  end
  for _, path in ipairs(paths) do
    if Fs.within(file, path) then
      return true
    end
  end
  return false
end

--- `cosmic todos [--oldest] [path...]`: stages the tree as a build
--- does, which indexes its TODOs, blames the ones not yet blamed, and
--- lists them one per line, in file order or, with `--oldest`, oldest
--- commit first, then a verdict line.
--- @param argv the command line, re-entered if this binary embeds a
---   stale copy of `build.todos` itself -- see `build.reboot.stale_exit`
function todos.run(argv: {integer:string}): integer
  local started = Time.monotonic_ns()
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    log:complain(root_trouble)
    return 1
  end
  -- TODO: list TODOs when only the core is stale, since nothing here
  -- runs it: after a C edit build.reboot's ensure boots before any verb goes on
  -- (or refuses, under COSMIC_AUTO_BOOT=0). A read-only verb could go
  -- on once the Teal side is fresh, which reboot.state would have to
  -- tell apart from both.
  local code = reboot.stale_exit(argv)
  if code ~= nil then
    return code
  end
  local parsed, parse_trouble = Flags.parse(argv, 2, { ["--oldest"] = false })
  if parsed == nil then
    log:complain("todos: " .. parse_trouble)
    return 2
  end
  local oldest = parsed.set["--oldest"] == true
  local paths: {string} = {}
  local words: {string} = {}
  for _, word in ipairs(parsed.words) do
    -- A path when it names one, and words to search for when not, as
    -- `cosmic docs` takes a symbol first and words after.
    local path = (word:gsub("^%./", ""):gsub("/+$", ""))
    -- A path that cannot be looked at is taken for words.
    local exists, _ = Fs.exists(root .. "/" .. path)
    if path ~= "" and exists then
      paths[#paths + 1] = path
    else
      words[#words + 1] = word
    end
  end
  local query = table.concat(words, " ")

  local own_tree, own_trouble = tree.is_own(root)
  if own_tree == nil then
    log:complain(own_trouble)
    return 1
  end
  local handle, open_trouble = work.open(root)
  if handle == nil then
    log:complain(open_trouble)
    return 1
  end
  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    local _, _ = work.abort(handle)
    log:complain(stage_trouble)
    return 1
  end
  local listing, list_trouble = todos.list(handle.db, root)
  if listing == nil then
    local _, _ = work.abort(handle)
    log:complain(list_trouble)
    return 1
  end
  local all, blamed = listing.todos, listing.blamed
  local ranks: {integer:integer} = nil
  if query ~= "" then
    local found, search_trouble = todos.search(handle.db, query)
    if found == nil then
      local _, _ = work.abort(handle)
      log:complain("todos: " .. search_trouble)
      return 1
    end
    ranks = found
  end
  local closed, close_trouble = work.close(handle)
  if not closed then
    log:complain(close_trouble)
    return 1
  end

  local listed: {todos.Todo} = {}
  for _, todo in ipairs(all) do
    if wanted(todo.file, paths) and (ranks == nil or ranks[todo.id] ~= nil) then
      listed[#listed + 1] = todo
    end
  end
  if ranks ~= nil and not oldest then
    -- Best match first; a TODO in several files with the same bytes
    -- shares one rank, so those keep file order among themselves.
    table.sort(listed, function(a: todos.Todo, b: todos.Todo): boolean
      if a.id ~= b.id then
        return ranks[a.id] < ranks[b.id]
      end
      return a.file < b.file
    end)
  end
  if ranks ~= nil and #listed == 0 then
    log:verdict("todos", false, "no TODO matches '" .. query .. "', " ..
      clock.elapsed_ms(started) .. " ms")
    return 1
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
    log:say(todos.render(todo))
    if not files[todo.file] then
      files[todo.file] = true
      file_count = file_count + 1
    end
  end
  log:verdict("todos", true, #listed .. " todos in " .. file_count .. " files, " ..
    tostring(blamed) .. " files blamed, " .. clock.elapsed_ms(started) .. " ms")
  return 0
end

return todos
