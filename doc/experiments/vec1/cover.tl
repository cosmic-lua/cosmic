--- Each test as a vector of the lines it covers (IDF-weighted, so the
--- startup every test runs counts for nothing), indexed with vec1.
local Sqlite = require("cosmic.sqlite")
local Vec = require("vec")
local Time = require("cosmic.time")

--- The cosmic checkout these scripts sit in, three levels up.
local root = "../../.."

return function(argv: {string})
  local dim = 1024
  local t0 = (Time.monotonic_ns() as integer)
  local db = assert(Sqlite.open(root .. "/o/build.db"))
  local run = assert((Sqlite.text_rows(db,
    "SELECT ran_at_ns FROM coverage_by_test GROUP BY ran_at_ns ORDER BY count(DISTINCT test) DESC, ran_at_ns DESC LIMIT 1")))[1][1]
  local rows = assert((Sqlite.text_rows(db,
    "SELECT test, path || ':' || line FROM coverage_by_test WHERE ran_at_ns = " .. run)))
  local lines: {string: {string: number}} = {}
  local df: {string: integer} = {}
  local names: {string} = {}
  for _, r in ipairs(rows) do
    local f = lines[r[1]]
    if f == nil then f = {}; lines[r[1]] = f; names[#names + 1] = r[1] end
    f[r[2]] = 1
    df[r[2]] = (df[r[2]] or 0) + 1
  end
  local n = #names
  for _, f in pairs(lines) do
    for k in pairs(f) do f[k] = math.log(n / df[k]) end
  end
  table.sort(names)
  local mem = assert(Sqlite.memory())
  assert(mem:exec("CREATE VIRTUAL TABLE t USING vec1(v, module)"))
  assert(mem:exec([[INSERT INTO t(cmd, arg) VALUES ('rebuild', '{index: "flat", distance: "cos"}')]]))
  local vecs: {string} = {}
  for i, name in ipairs(names) do
    vecs[i] = Vec.pack(lines[name], dim)
    assert(Sqlite.run(mem, "INSERT INTO t(rowid, v, module) VALUES (?1, ?2, ?3)",
      { { integer = i }, { blob = vecs[i] }, { text = name:match("^(%S+)") } }))
  end
  local t1 = (Time.monotonic_ns() as integer)
  print(string.format("%d rows, %d tests, %d distinct lines, indexed in %.1fs",
    #rows, n, (function(): integer local c = 0 for _ in pairs(df) do c = c + 1 end return c end)(),
    (t1 - t0) / 1e9))

  if argv[1] == "near" then
    -- The tests nearest to a region of code: path from..to.
    local q: {string: number} = {}
    for l = tonumber(argv[3]) as integer, tonumber(argv[4]) as integer do
      local k = argv[2] .. ":" .. l
      if df[k] then q[k] = math.log(n / df[k]) end
    end
    for _, r in ipairs((assert(Sqlite.rows(mem, "SELECT rowid, distance FROM t(?1, 8)",
        { { blob = Vec.pack(q, dim) } })))) do
      print(string.format("%.3f  %s", r[2].number, names[r[1].integer]))
    end
    return
  end
  -- Pairs from different modules whose coverage is nearly the same.
  local pairs_: {{number, string, string}} = {}
  for i, name in ipairs(names) do
    for _, r in ipairs((assert(Sqlite.rows(mem,
        "SELECT rowid, distance FROM t(?1, 3) WHERE module != ?2",
        { { blob = vecs[i] }, { text = name:match("^(%S+)") } })))) do
      local j = r[1].integer
      if j > i and r[2].number < 0.10 then
        pairs_[#pairs_ + 1] = { r[2].number, name, names[j] }
      end
    end
  end
  table.sort(pairs_, function(a: {number, string, string}, b: {number, string, string}): boolean return a[1] < b[1] end)
  for k = 1, math.min(#pairs_, 25) do
    print(string.format("%.3f  %s\n       %s", pairs_[k][1], pairs_[k][2], pairs_[k][3]))
  end
  print(string.format("%d cross-module pairs under 0.10; queried in %.2fs", #pairs_, ((Time.monotonic_ns() as integer) - t1) / 1e9))
end
