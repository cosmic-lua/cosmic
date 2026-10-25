--- What `cosmic fix` keeps of a file it left as it was ([`build.fix.laid`]): an answer is held only for the same name,
--- text and code, and the code's modules are those the layout requires.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")
local check_memo = require("build.check_memo")
local laid = require("build.fix.laid")

--- The sources of the layout's modules, which the test reads to hold the list of modules to what they require.
Test.policy{
  grants = {
    { path = "build/", letters = "r" },
    { path = "cosmic/", letters = "r" },
  },
}

--- A run over a memo of its own.
local function begun(): laid.Kept
  local db = assert(Sqlite.memory())
  return assert(laid.begin(db, "salt"))
end

local function test_the_modules_are_those_the_layout_calls()
  local held: mut {string: boolean} = {}
  for _, name in ipairs(laid.modules) do
    held[name] = true
  end
  -- What [`fix.source`] calls: the compiler's parse, the rules, the renderer and the equivalence; each loads the rest.
  local init = assert(Fs.read("build/fix/init.tl"))
  local from = assert(init:find("function fix.source(", 1, true))
  local upto = assert(init:find("\n--- The files one invocation covers", from, true))
  local body = init:sub(from, upto)
  for alias, module in pairs({ ast = "build.ast", equiv = "build.fix.equiv", render_mod = "build.fix.render",
      rule = "build.fix.rule" }) do
    if body:find(alias .. ".", 1, true) ~= nil then
      assert(held[module] == true, module .. " is called by the layout and is not in laid.modules")
    end
  end
  assert(held["build.fix"], "the layout's own module is held")
end

local function test_an_answer_is_held_for_the_same_name_and_text_alone()
  local kept = begun()
  assert(not laid.holds(kept, "a.tl", "local x = 1\n"))
  laid.keep(kept, "a.tl", "local x = 1\n")
  assert(laid.holds(kept, "a.tl", "local x = 1\n"))
  assert(not laid.holds(kept, "b.tl", "local x = 1\n"), "another file was answered with a.tl's")
  assert(not laid.holds(kept, "a.tl", "local x = 2\n"), "a changed text was answered with its old one's")
  assert(not laid.holds(kept, "a.tl", "local x = 1\n "), "a text with a space more was answered with the old one's")
end

local function test_an_answer_of_other_code_is_not_held()
  local kept = begun()
  laid.keep(kept, "a.tl", "x\n")
  local other: laid.Kept = { memo = kept.memo, salt = kept.salt .. "x" }
  assert(not laid.holds(other, "a.tl", "x\n"), "an answer of other code was held")
  assert(laid.holds(kept, "a.tl", "x\n"))
end

local function test_the_salt_moves_with_the_code_and_is_the_same_for_the_same()
  local first = laid.salt()
  if first == nil then
    Test.skip("this binary has no identity to name the code by")
  end
  assert(first == laid.salt())
  assert(#assert(first) == 64)
end

local function test_a_whole_run_drops_what_it_did_not_use()
  local db = assert(Sqlite.memory())
  local first = assert(laid.begin(db, "salt"))
  laid.keep(first, "a.tl", "a\n")
  laid.keep(first, "b.tl", "b\n")
  laid.finish(first, true)
  local second = assert(laid.begin(db, "salt"))
  assert(laid.holds(second, "a.tl", "a\n"))
  laid.finish(second, true)
  local third = assert(laid.begin(db, "salt"))
  assert(laid.holds(third, "a.tl", "a\n"))
  assert(not laid.holds(third, "b.tl", "b\n"), "an answer no run used was kept")
  laid.finish(third, false)
  assert(check_memo.get(db, "laid", check_memo.key(third.salt, "a.tl", "a\n")) == "U")
end
