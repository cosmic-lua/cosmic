local Fs = require("cosmic.fs")
local Fuzz = require("build.fuzz")
local Stateful = require("build.fuzz_stateful")

local record Model
  active: boolean
  value: integer
  saved: integer
end

local function fresh(): Model
  return { active = false, value = 0, saved = 0 }
end

local function advance(model: Model, operation: string)
  if operation == "begin" then
    model.active, model.saved = true, model.value
  elseif operation == "write" then
    model.value = 1
  elseif operation == "rollback" then
    model.active, model.value = false, model.saved
  end
end

local sequence = Stateful.sequence(fresh,
  function(src: Fuzz.Source, model: Model): string
    if not model.active then return "begin" end
    return Fuzz.pick(src, { "write", "rollback" })
  end, advance, 20)

local function describe(operation: string): string return operation end

local function test_stateful_generation_rebuilds_dependencies_per_case()
  Fuzz.run({ name = "stateful valid transitions", iters = 100,
    gen = function(src: Fuzz.Source): string return Fuzz.pack(sequence(src)) end,
    check = function(input: string): boolean, string
      local model = fresh()
      for _, operation in ipairs(Fuzz.unpack(input)) do
        assert((operation == "begin") ~= model.active, "invalid dependent operation")
        advance(model, operation)
      end
      return true, ""
    end })
end

local function test_stateful_invariants_follow_expected_refusals()
  local checks = 0
  local held, why = Stateful.check({ "refused", "accepted" }, fresh(),
    function(_model: Model, _operation: string): boolean, string return true, "" end,
    function(_model: Model): boolean, string
      checks = checks + 1
      return checks < 3, "invariant failed"
    end, describe)
  assert(not held and checks == 3, why)
  assert(why == "invariant failed\n  1. refused\n  2. accepted", why)
end

local function test_stateful_shrinking_finds_the_causal_transaction(tmp: string)
  local ok, why = pcall(Fuzz.run, { name = "faulty rollback", dir = tmp, iters = 100,
    gen = function(src: Fuzz.Source): string return Fuzz.pack(sequence(src)) end,
    failure_id = function(_input: string, message: string): string
      return message:match("^[^\n]+")
    end,
    check = function(input: string): boolean, string
      local actual = 0
      return Stateful.check(Fuzz.unpack(input), fresh(),
        function(model: Model, operation: string): boolean, string
          advance(model, operation)
          if operation == "write" then actual = 1 end
          -- The seeded defect forgets to restore the saved value.
          return true, ""
        end,
        function(model: Model): boolean, string return actual == model.value, "state mismatch" end,
        describe)
    end })
  assert(not ok, "the seeded rollback defect escaped")
  assert(tostring(why):find("state mismatch", 1, true), tostring(why))
  local minimal = Fuzz.unpack((assert(Fs.read(tmp .. "/faulty-rollback.input"))))
  assert(table.concat(minimal, ",") == "begin,write,rollback", table.concat(minimal, ","))
end
