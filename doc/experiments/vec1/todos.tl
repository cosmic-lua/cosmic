--- Every TODO: in the tree, indexed with vec1; each one's nearest.
local Sqlite = require("cosmic.sqlite")
local Child = require("cosmic.child")
local Vec = require("vec")

--- The cosmic checkout these scripts sit in, three levels up.
local root = "../../.."

return function(argv: {string})
  local dim = 256
  local out = assert(Child.run({ "/usr/bin/env", "git", "-C", root, "grep", "-n", "-A3", "TODO:", "--", ":!vendor" }, { stdout = "capture" }))
  local text = out.stdout as string
  -- git grep -A: "path:line:text" for the hit, "path-line-text" after it.
  local todos: {{string}} = {}
  local cur: {string} = nil
  for line in text:gmatch("[^\n]+") do
    local p, n, t = line:match("^([^:]+):(%d+):(.*)$")
    if p and t:find("TODO:", 1, true) then
      cur = { p .. ":" .. n, (t:match("TODO:%s*(.*)")) }
      todos[#todos + 1] = cur
    elseif cur and line ~= "--" then
      local rest = line:match("^[^%-]+%-%d+%-%s*[%-/%*#]*%s*(.*)$")
      if rest and rest ~= "" and not rest:find("^[%w_]+%s*[=(]") and #cur[2] < 400 then
        cur[2] = cur[2] .. " " .. rest
      else
        cur = nil
      end
    end
  end
  local db = assert(Sqlite.memory())
  assert(db:exec("CREATE VIRTUAL TABLE t USING vec1(v)"))
  assert(db:exec([[INSERT INTO t(cmd, arg) VALUES ('rebuild', '{index: "flat", distance: "cos"}')]]))
  for i, todo in ipairs(todos) do
    assert(Sqlite.run(db, "INSERT INTO t(rowid, v) VALUES (?1, ?2)",
      { { integer = i }, { blob = Vec.pack(Vec.text(todo[2]), dim) } }))
  end
  print(#todos .. " TODOs")
  local query = argv[1]
  if query then
    local rows = assert(Sqlite.rows(db, "SELECT rowid, distance FROM t(?1, 5)",
      { { blob = Vec.pack(Vec.text(query), dim) } }))
    for _, r in ipairs(rows) do
      local todo = todos[r[1].integer]
      print(string.format("%.2f  %s  %s", r[2].number, todo[1], todo[2]:sub(1, 110)))
    end
    return
  end
  for _, todo in ipairs(todos) do
    local rows = assert(Sqlite.rows(db, "SELECT rowid, distance FROM t(?1, 2)",
      { { blob = Vec.pack(Vec.text(todo[2]), dim) } }))
    local j, d = rows[2][1].integer, rows[2][2].number
    if d < 0.8 then
      print(string.format("%.2f  %s\n      %s\n   ~  %s\n      %s", d, todo[1], todo[2]:sub(1, 120),
        todos[j][1], todos[j][2]:sub(1, 120)))
    end
  end
end
