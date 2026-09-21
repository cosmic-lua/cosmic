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
  if #rows ~= 1 or #rows[1] ~= 1 then
    return nil, "query returned an unexpected shape"
  end
  return rows[1][1], ""
end

return function(argv: {string}): integer
  local recover = argv[1] == "--recover-copy"
  local path = recover and argv[2] or argv[1]
  if path == nil or path == "" then
    print("work database integrity: FAIL (usage: work_db_integrity.tl DATABASE)")
    return 2
  end
  -- A raw snapshot can include a hot rollback journal. CI passes
  -- --recover-copy only for its second disposable copy, allowing SQLite to
  -- recover that copy before integrity checks. The preserved bytes remain
  -- unopened and retain their exact database+journal hashes.
  local db, open_trouble = Sqlite.open(path, recover)
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
  local trouble = page_trouble ~= "" and page_trouble or
    freelist_trouble ~= "" and freelist_trouble or
    coverage_trouble ~= "" and coverage_trouble or
    by_test_trouble ~= "" and by_test_trouble or
    integrity_trouble
  if trouble ~= nil and trouble ~= "" then
    print("work database integrity: FAIL (" .. trouble .. ")")
    return 1
  end
  if not closed then
    print("work database integrity: FAIL (close: " .. close_trouble .. ")")
    return 1
  end
  if integrity == nil or #integrity ~= 1 or #integrity[1] ~= 1 or
     integrity[1][1] ~= "ok" then
    local findings: {string} = {}
    for _, row in ipairs(integrity or {}) do
      findings[#findings + 1] = table.concat(row, " | ")
    end
    print("work database integrity: FAIL (" .. table.concat(findings, "; ") .. ")")
    return 1
  end
  print("work database integrity: PASS (SQLite " .. Sqlite.version ..
    ", " .. page_count .. " pages, " .. freelist .. " free, " ..
    coverage .. " coverage rows, " .. by_test .. " per-test rows)")
  return 0
end
