--- [`runs.tl`]: the database of rounds, in memory: a round and its arms, a run put and found again, a round that
--- goes on, an arm whose binary changed, and what an earlier round says.
local Runs = require("runs")
local Test = require("cosmic.test")

Test.policy{}

local function spent(refused: integer): Runs.Spent
  return { requests = 3, input = 10, output = 20, cache_read = 30, cache_write = 40, cost = 0.5, seconds = 2.5,
    tools = 4, runs = 3, refused = refused, codes = { field_unknown = refused }, causes = { ["lang: x"] = refused },
    layers = { lang = refused }, guesses = { ["Json.nope (field_unknown)"] = 1 }, resends = 1, sorts = 0,
    helpers = { sed = 2 }, first_read = 5 }
end

local function result(tool: string, task: string, rep: integer, grade: string, refused: integer): Runs.Result
  return { tool = tool, task = task, rep = rep, grade = grade, wall = 12.5, spent = spent(refused) }
end

local function open(): Runs.Store
  local db, why = Runs.open(":memory:")
  return (assert(db, why))
end

local function test_a_run_put_is_found_again_with_what_it_spent()
  local db = open()
  local arm: Runs.Arm = { name = "a", sha = "s1", path = "/c", effort = "low", drop = "Host.sed" }
  assert(Runs.begin(db, { id = "r1", model = "m", reps = 2, fixture = "f" }, { arm }))
  assert(Runs.known(db, "r1", "a", "t", 1) == nil)
  assert(Runs.put(db, "r1", arm, "m", result("a", "t", 1, "pass", 2)))
  local got = assert(Runs.known(db, "r1", "a", "t", 1))
  assert(got.grade == "pass" and got.wall == 12.5 and got.tool == "a")
  local s = assert(got.spent)
  assert(s.requests == 3 and s.refused == 2 and s.cost == 0.5 and s.codes["field_unknown"] == 2 and s.helpers["sed"] == 2)
  assert(s.layers["lang"] == 2 and s.first_read == 5 and s.resends == 1)
  -- A second put of the same run replaces it.
  assert(Runs.put(db, "r1", arm, "m", result("a", "t", 1, "fail", 0)))
  assert(assert(Runs.known(db, "r1", "a", "t", 1)).grade == "fail")
  assert(#assert(Runs.results(db, "r1")) == 1)
  local names = assert(Runs.arms(db, "r1"))
  assert(#names == 1 and names[1] == "a")
end

local function test_a_round_goes_on_but_not_with_another_binary()
  local db = open()
  local round: Runs.Round = { id = "r1", model = "m", reps = 1, fixture = "f" }
  assert(Runs.begin(db, round, { { name = "a", sha = "s1", path = "/c" } }))
  assert(Runs.begin(db, round, { { name = "a", sha = "s1", path = "/c" } }))
  local ok, why = Runs.begin(db, round, { { name = "a", sha = "s2", path = "/c" } })
  assert(ok == nil and why:find("arm a of round r1 ran binary s1", 1, true) ~= nil, tostring(why))
  -- A refused call notes nothing: the arm b it named stays unnoted.
  local refused, _ = Runs.begin(db, round, { { name = "b", sha = "s9", path = "/c" }, { name = "a", sha = "s2", path = "/c" } })
  assert(refused == nil and #assert(Runs.arms(db, "r1")) == 1)
  local other_model, model_why = Runs.begin(db, { id = "r1", model = "n", reps = 1, fixture = "f" }, {})
  assert(other_model == nil and model_why:find("began with model m", 1, true) ~= nil, tostring(model_why))
  local other_drop, _ = Runs.begin(db, round, { { name = "a", sha = "s1", path = "/c", drop = "Host.sed" } })
  assert(other_drop == nil)
  assert(Runs.stopped(db, "r1") == nil)
  assert(Runs.finish(db, "r1", "out of money"))
  assert(Runs.stopped(db, "r1") == "out of money")
  -- An arm that begins does not clear it: the call that starts the arms does, once.
  assert(Runs.begin(db, round, { { name = "a", sha = "s1", path = "/c" } }))
  assert(Runs.stopped(db, "r1") == "out of money")
  assert(Runs.reopen(db, "r1"))
  assert(Runs.stopped(db, "r1") == nil)
end

local function test_an_earlier_round_is_found_by_tool_with_its_causes_and_the_newest_other_round_is_the_default()
  local db = open()
  local arm: Runs.Arm = { name = "a", sha = "s1", path = "/c" }
  assert(Runs.begin(db, { id = "old", model = "m", reps = 1, fixture = "f" }, { arm }))
  assert(Runs.put(db, "old", arm, "m", result("a", "t", 1, "pass", 2)))
  assert(Runs.put(db, "old", arm, "m", result("a", "u", 1, "fail", 1)))
  assert(Runs.begin(db, { id = "new", model = "m", reps = 1, fixture = "f" }, { arm }))
  -- A round with no runs is not one to set a report against.
  assert(Runs.latest(db, "new") == "old" and Runs.latest(db, "old") == nil)
  local earlier = assert(Runs.earlier(db, "old"))
  local a = assert(earlier["a"])
  assert(a.refused == 3 and a.runs == 2 and a.causes["lang: x"] == 3 and a.layers["lang"] == 3)
end
