--- Doc comments as hashed word vectors: near-duplicates across modules,
--- or the docs nearest a free-text question.
local Sqlite = require("cosmic.sqlite")
local Vec = require("vec")

--- The cosmic checkout these scripts sit in, three levels up.
local root = "../../.."

return function(argv: {string})
  local dim = 512
  local db = assert(Sqlite.open(root .. "/o/cosmic.db"))
  local docs = assert((Sqlite.text_rows(db,
    "SELECT id, module, symbol, text FROM docs WHERE length(text) > 80")))
  local mem = assert(Sqlite.memory())
  assert(mem:exec("CREATE VIRTUAL TABLE t USING vec1(v, module)"))
  assert(mem:exec([[INSERT INTO t(cmd, arg) VALUES ('rebuild', '{index: "flat", distance: "cos"}')]]))
  local vecs: {string} = {}
  for i, d in ipairs(docs) do
    vecs[i] = Vec.pack(Vec.text(d[4]), dim)
    assert(Sqlite.run(mem, "INSERT INTO t(rowid, v, module) VALUES (?1, ?2, ?3)",
      { { integer = i }, { blob = vecs[i] }, { text = d[2] } }))
  end
  local function show(d: {string}): string
    return d[2] .. " " .. d[3] .. ": " .. d[4]:gsub("%s+", " "):sub(1, 90)
  end
  if argv[1] then
    local found = assert(Sqlite.rows(mem, "SELECT rowid, distance FROM t(?1, 6)",
      { { blob = Vec.pack(Vec.text(argv[1]), dim) } }))
    for _, r in ipairs(found) do
      print(string.format("%.2f  %s", r[2].number, show(docs[r[1].integer])))
    end
    return
  end
  print(#docs .. " doc comments")
  local shown = 0
  for i, d in ipairs(docs) do
    local found = assert(Sqlite.rows(mem, "SELECT rowid, distance FROM t(?1, 1) WHERE module != ?2",
      { { blob = vecs[i] }, { text = d[2] } }))
    local r = found[1]
    if r and r[1].integer > i and r[2].number < 0.25 and shown < 12 then
      shown = shown + 1
      print(string.format("%.2f  %s\n   ~  %s", r[2].number, show(d), show(docs[r[1].integer])))
    end
  end
end
