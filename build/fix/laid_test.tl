--- What `cosmic fix` keeps of a Teal file it found laid out ([`build.fix.laid`]): an answer is held for the same
--- dialect and text and the same code alone, and the code is the formatter's whole closure.
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local check_memo = require("build.check_memo")
local laid = require("build.fix.laid")

Test.policy{ cpu_features = true }

--- Whether `kept` holds that `source`, of `dialect`, is laid out as it stands.
local function held(kept: laid.Kept, dialect: string, source: string): boolean
  return check_memo.get(kept.memo, "laid", check_memo.key(kept.salt, dialect, source)) == "U"
end

--- A run over a memo of its own.
local function begun(): laid.Kept
  local db = assert(Sqlite.memory())
  return assert(laid.begin(db, "salt"))
end

--- A file laid out is kept and is not formatted again; one the formatter changes or refuses is not kept.
local function test_only_a_file_found_laid_out_is_kept()
  local kept = begun()
  assert(laid.format(kept, "local x = 1\n", "a.tl").text == "local x = 1\n")
  assert(held(kept, "tl", "local x = 1\n"))
  local changed = laid.format(kept, "local   x=1\n", "a.tl")
  assert(changed.text == "local x = 1\n")
  assert(not held(kept, "tl", "local   x=1\n"), "a file that was laid out was kept as it was")
  local refused = laid.format(kept, "local = \n", "a.tl")
  assert(refused.text == nil and refused.kind == "syntax")
  assert(not held(kept, "tl", "local = \n"))
  -- Without a memo the answer is the formatter's.
  assert(laid.format(nil, "local   x=1\n", "a.tl").text == "local x = 1\n")
end

--- A hit answers without the formatter: a memo that holds a text laid out badly says that it is laid out, which
--- only a memo can say. The answer is of the dialect and the text it was kept for.
local function test_a_hit_is_answered_from_the_memo_for_the_same_dialect_and_text_alone()
  local kept = begun()
  local source = "local record  R\nend\n"
  check_memo.put(kept.memo, "laid", check_memo.key(kept.salt, "tl", source), "U")
  assert(laid.format(kept, source, "a.tl").text == source)
  assert(laid.format(kept, source, "b.tl").text == source, "an answer is of the text, not the name")
  assert(laid.format(kept, source, "a.d.tl").text == "local record R\nend\n", "a declaration file got a program's answer")
  assert(laid.format(kept, "local record  S\nend\n", "a.tl").text == "local record S\nend\n",
    "a changed text got its old one's answer")
end

local function test_an_answer_of_other_code_is_not_held()
  local db = assert(Sqlite.memory())
  local first = assert(laid.begin(db, "one"))
  assert(laid.format(first, "x = 1\n", "a.tl").text == "x = 1\n")
  laid.finish(first, false)
  local same = assert(laid.begin(db, "one"))
  assert(held(same, "tl", "x = 1\n"))
  laid.finish(same, false)
  local other = assert(laid.begin(db, "two"))
  assert(not held(other, "tl", "x = 1\n"), "an answer of other code was held")
  laid.finish(other, false)
end

--- The formatter's code is named by its closure: the salt is the same for the same code, and the closure holds what
--- lays a file out.
local function test_the_salt_is_the_same_for_the_same_code_and_the_closure_is_the_formatters()
  local names: mut {string: boolean} = {}
  for _, name in ipairs(Store.closure({ "build.fix.format" })) do names[name] = true end
  for _, name in ipairs({ "build.fix.layout", "build.fix.equiv", "build.fix.breaks", "build.fix.roles", "build.fix.trivia",
      "lang.lexer", "lang.parser" }) do
    assert(names[name] == true, name .. " is not loaded by the formatter, so the salt would not name it")
  end
  local db = assert(Sqlite.memory())
  local first = laid.begin(db)
  if first == nil then
    Test.skip("this binary has no identity to name the code by")
  end
  local other = assert(Sqlite.memory())
  local second = assert(laid.begin(other))
  assert(#second.salt == 64, second.salt)
  assert(assert(first).salt == second.salt, "the salt of one code moved")
end

local function test_a_whole_run_drops_what_it_did_not_use()
  local db = assert(Sqlite.memory())
  local first = assert(laid.begin(db, "salt"))
  laid.format(first, "a = 1\n", "a.tl")
  laid.format(first, "b = 1\n", "b.tl")
  laid.finish(first, true)
  local second = assert(laid.begin(db, "salt"))
  assert(held(second, "tl", "a = 1\n"))
  laid.finish(second, true)
  local third = assert(laid.begin(db, "salt"))
  assert(held(third, "tl", "a = 1\n"))
  assert(not held(third, "tl", "b = 1\n"), "an answer no run used was kept")
  laid.finish(third, false)
  assert(check_memo.get(db, "laid", check_memo.key("salt", "tl", "a = 1\n")) == "U")
end
