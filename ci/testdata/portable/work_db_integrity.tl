--- Read-only integrity report for a preserved working database.
---
--- CI copies this outside the checkout before running it, so compiling the
--- helper cannot stage the product tree or touch the database being inspected.

local Sqlite = require("cosmic.sqlite")

local function scalar(db: Sqlite.Handle, sql: string): string | nil, string
  local rows, trouble = Sqlite.text_rows(db, sql)
  if rows == nil then
    return nil, trouble
  end
  local row = rows[1]
  if #rows ~= 1 or row == nil or row:count() ~= 1 then
    return nil, "query returned an unexpected shape"
  end
  return row:text(1), ""
end

return function(argv: {string}): integer
  local recover = argv[1] == "--recover-copy"
  local path = argv[1]
  if recover then path = argv[2] end
  if path == nil or path == "" then
    print("work database integrity: FAIL (usage: work_db_integrity.tl DATABASE)")
    return 2
  end
  -- A raw snapshot can include a hot rollback journal, or the write-ahead
  -- log holding commits not yet in the file. CI passes --recover-copy only
  -- for its second disposable copy, allowing SQLite to recover that copy,
  -- or read its log, before integrity checks. The preserved bytes remain
  -- unopened and retain their exact hashes, the journal's or log's too.
  -- This file runs only on the candidate's own binary (orchestration.tl's
  -- local and portable boundaries), so the options table is read as such,
  -- and a row is read through its accessors.
  local db, open_trouble = Sqlite.open(path, { writable = recover })
  if db == nil then
    print("work database integrity: FAIL (open: " .. open_trouble .. ")")
    return 1
  end
  local page_count, page_trouble = scalar(db, "PRAGMA page_count")
  local freelist, freelist_trouble = scalar(db, "PRAGMA freelist_count")
  local coverage, coverage_trouble = scalar(db, "SELECT count(*) FROM coverage")
  local by_test, by_test_trouble =
    scalar(db, "SELECT count(*) FROM coverage_by_test")
  local integrity, integrity_trouble = Sqlite.text_rows(db, "PRAGMA integrity_check")
  local closed, close_trouble = db:close()
  -- The first of these that says anything, the page count's before the rest.
  local trouble = integrity_trouble
  for _, each in ipairs({ by_test_trouble, coverage_trouble, freelist_trouble, page_trouble }) do
    if each ~= "" then trouble = each end
  end
  if trouble ~= "" then
    print("work database integrity: FAIL (" .. trouble .. ")")
    return 1
  end
  if not closed then
    print("work database integrity: FAIL (close: " .. close_trouble .. ")")
    return 1
  end
  local only: Sqlite.Row | nil = nil
  if integrity ~= nil and #integrity == 1 then only = integrity[1] end
  if only == nil or only:count() ~= 1 or only:text(1) ~= "ok" then
    local findings: {string} = {}
    for _, row in ipairs(integrity or {}) do
      findings[#findings + 1] = table.concat(row:texts(), " | ")
    end
    print("work database integrity: FAIL (" .. table.concat(findings, "; ") .. ")")
    return 1
  end
  print("work database integrity: PASS (SQLite " .. Sqlite.version ..
      ", " .. assert(page_count) .. " pages, " .. assert(freelist) .. " free, " ..
      assert(coverage) .. " coverage rows, " .. assert(by_test) .. " per-test rows)")
  return 0
end
