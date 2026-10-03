local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Fuzz = require("build.fuzz")
local Stateful = require("build.fuzz_stateful")
local Strategy = require("build.fuzz_strategy")

local record Savepoint
  name: string
  rows: {integer: integer}
end

local record Model
  rows: {integer: integer}
  before: {integer: integer}
  active: boolean
  explicit: boolean
  points: {Savepoint}
end

local function fresh(): Model
  return { rows = {}, active = false, explicit = false, points = {} }
end

local function copy(rows: {integer: integer}): {integer: integer}
  local out: {integer: integer} = {}
  for key, value in pairs(rows) do out[key] = value end
  return out
end

local function point(model: Model, name: string): integer
  for i = #model.points, 1, -1 do
    if model.points[i].name == name then return i end
  end
  return 0
end

local function apply(model: Model, operation: string): boolean
  local kind, argument, value = operation:match("^(%S+) ?(%S*) ?(%S*)$")
  if kind == "put" then
    model.rows[assert(math.tointeger(tonumber(argument)))] = assert(math.tointeger(tonumber(value)))
  elseif kind == "delete" then
    model.rows[assert(math.tointeger(tonumber(argument)))] = nil
  elseif kind == "begin" then
    if model.active then return false end
    model.before, model.active, model.explicit = copy(model.rows), true, true
  elseif kind == "commit" or kind == "rollback" then
    if not model.active then return false end
    if kind == "rollback" then model.rows = copy(model.before) end
    model.active, model.explicit, model.points = false, false, {}
  elseif kind == "save" then
    if not model.active then model.before, model.active = copy(model.rows), true end
    model.points[#model.points + 1] = { name = argument, rows = copy(model.rows) }
  elseif kind == "restore" or kind == "release" then
    local at = point(model, argument)
    if at == 0 then return false end
    if kind == "restore" then model.rows = copy(model.points[at].rows) end
    for i = #model.points, kind == "restore" and at + 1 or at, -1 do model.points[i] = nil end
    if #model.points == 0 and not model.explicit then model.active = false end
  else
    error("unknown model operation " .. operation)
  end
  return true
end

local integer = Strategy.integer(-3, 3)
local function draw(src: Fuzz.Source, model: Model): string
  local kind = Fuzz.pick(src, { "put", "delete", "begin", "commit", "rollback", "save", "restore", "release" })
  local valid = src:int(0, 2) ~= 0
  if valid then
    if kind == "begin" and model.active then kind = "save" end
    if (kind == "commit" or kind == "rollback") and not model.active then kind = "begin" end
    if (kind == "restore" or kind == "release") and #model.points == 0 then kind = "save" end
  end
  if kind == "put" then return ("put %d %d"):format(src:int(1, 3), integer(src)) end
  if kind == "delete" then return "delete " .. src:int(1, 3) end
  if kind == "save" then return "save " .. Fuzz.pick(src, { "a", "b" }) end
  if kind == "restore" or kind == "release" then
    local name = valid and model.points[src:int(1, #model.points)].name or Fuzz.pick(src, { "a", "b", "missing" })
    return kind .. " " .. name
  end
  return kind
end

local sequence = Stateful.sequence(fresh, draw,
  function(model: Model, operation: string) local _ = apply(model, operation) end, 40)

local function execute(db: Sqlite.Handle, operation: string, faulty_restore: boolean): boolean, string
  local kind, argument, value = operation:match("^(%S+) ?(%S*) ?(%S*)$")
  if kind == "put" then
    return Sqlite.run(db, "INSERT INTO entries VALUES (?1, ?2) ON CONFLICT(id) DO UPDATE SET value=excluded.value",
      { { integer = assert(math.tointeger(tonumber(argument))) }, { integer = assert(math.tointeger(tonumber(value))) } })
  elseif kind == "delete" then
    return Sqlite.run(db, "DELETE FROM entries WHERE id=?1", { { integer = assert(math.tointeger(tonumber(argument))) } })
  elseif kind == "save" then
    return db:exec("SAVEPOINT " .. argument)
  elseif kind == "restore" then
    if faulty_restore then return db:exec("RELEASE " .. argument) end
    return db:exec("ROLLBACK TO " .. argument)
  elseif kind == "release" then
    return db:exec("RELEASE " .. argument)
  end
  return db:exec(kind)
end

local function check_open(db: Sqlite.Handle, input: string, faulty_restore: boolean): boolean, string
  assert(db:exec("CREATE TABLE entries (id INTEGER PRIMARY KEY, value INTEGER NOT NULL)"))
  return Stateful.check(Fuzz.unpack(input), fresh(),
    function(model: Model, operation: string): boolean, string
      local expected = apply(model, operation)
      local held, why = execute(db, operation, faulty_restore)
      if expected ~= held then return false, "operation success differs" end
      if not held then
        assert(why ~= "", "a refused operation must explain why")
        Fuzz.label("invalid")
      end
      if operation:match("^put ") then Fuzz.label("write") end
      if operation:match("^save ") then Fuzz.label("savepoint") end
      if operation == "rollback" or operation:match("^restore ") then Fuzz.label("rollback") end
      return true, ""
    end,
    function(model: Model): boolean, string
      local rows = assert(Sqlite.rows(db, "SELECT id, value FROM entries ORDER BY id"))
      local seen: {integer: boolean} = {}
      for _, row in ipairs(rows) do
        local key, value = row[1].integer, row[2].integer
        if model.rows[key] ~= value then return false, "rows differ" end
        seen[key] = true
      end
      for key in pairs(model.rows) do
        if not seen[key] then return false, "rows differ" end
      end
      return true, ""
    end,
    function(operation: string): string return operation end)
end

local function check(input: string, faulty_restore: boolean): boolean, string
  local db = assert(Sqlite.memory())
  local called, held, why = pcall(check_open, db, input, faulty_restore)
  db:close()
  if not called then error(held, 0) end
  return held, why
end

local function test_sqlite_transactions_and_savepoints_match_a_model(tmp: string)
  Fuzz.run({ name = "sqlite transaction model", dir = tmp,
    gen = function(src: Fuzz.Source): string return Fuzz.pack(sequence(src)) end,
    check = function(input: string): boolean, string return check(input, false) end,
    failure_id = function(_input: string, why: string): string return why:match("^[^\n]+") end,
    requires = { "write", "savepoint", "rollback", "invalid" } })
end

local function test_savepoint_model_detects_a_seeded_restore_defect()
  local held, why = check(Fuzz.pack({ "save a", "put 1 1", "restore a" }), true)
  assert(not held and why:find("rows differ", 1, true), why)
  assert(why:find("1. save a\n  2. put 1 1\n  3. restore a", 1, true), why)
  assert(check(Fuzz.pack({ "save a", "put 1 1", "restore a" }), false))
end

local function test_savepoint_nesting_and_refusals_leave_rows_consistent()
  assert(check(Fuzz.pack({ "put 1 2", "save a", "put 1 -1", "save a", "put 2 3",
    "restore a", "release a", "restore a", "release a", "rollback" }), false))
  assert(check(Fuzz.pack({ "begin", "put 1 1", "save a", "put 2 2", "save b", "put 3 3",
    "release a", "rollback", "commit", "restore b" }), false))
end

local function test_fuzzing_minimizes_a_seeded_sqlite_restore_defect(tmp: string)
  local noise = Strategy.list(function(src: Fuzz.Source): string
    return "put 2 " .. src:int(0, 3)
  end, 8)
  local ok, why = pcall(Fuzz.run, { name = "sqlite restore defect", dir = tmp, iters = 1,
    gen = function(src: Fuzz.Source): string
      local operations = noise(src)
      operations[#operations + 1] = "save a"
      operations[#operations + 1] = "put 1 " .. src:int(1, 3)
      operations[#operations + 1] = "restore a"
      return Fuzz.pack(operations)
    end,
    check = function(input: string): boolean, string return check(input, true) end,
    failure_id = function(_input: string, message: string): string
      return message:match("^[^\n]+")
    end })
  assert(not ok, "the seeded SQLite restore defect escaped")
  local input = assert(Fs.read(tmp .. "/sqlite-restore-defect.input"))
  local operations = Fuzz.unpack(input)
  assert(table.concat(operations, ",") == "save a,put 1 1,restore a", tostring(why))
  assert(check(input, false), "the minimized sequence must pass the real implementation")
  assert(not check(input, true), "the minimized sequence must still expose the seeded defect")
end
