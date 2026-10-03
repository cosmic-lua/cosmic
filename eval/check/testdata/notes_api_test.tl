--- The notes task's hidden API test: eval/check/grade.tl runs it
--- against a copy of a solver's project, never shown to the solver.
local notes = require("notes")

local function texts(found: {notes.Note}): string
  local out: {string} = {}
  for _, note in ipairs(found) do
    out[#out + 1] = note.id .. "=" .. note.text
  end
  return table.concat(out, ",")
end

local function test_a_store_adds_lists_searches_and_removes(dir: string)
  local store <close> = assert(notes.open(dir .. "/notes.db"))
  local first: integer = store:add("hello world")
  local second = store:add("50% off")
  local third = store:add("500 off")
  assert(first == 1 and second == 2 and third == 3, "ids " .. first .. "," .. second .. "," ..
      third)
  assert(texts(store:list()) == "1=hello world,2=50% off,3=500 off", texts(store:list()))
  assert(texts(store:search("world")) == "1=hello world", texts(store:search("world")))
  assert(texts(store:search("50%")) == "2=50% off", "search 50%: " .. texts(store:search("50%")))
  assert(texts(store:search("0_o")) == "", "search 0_o: " .. texts(store:search("0_o")))
  assert(store:remove(1) == true, "remove 1")
  assert(store:remove(1) == false, "remove 1 again")
  assert(store:remove(99) == false, "remove 99")
  assert(texts(store:list()) == "2=50% off,3=500 off", texts(store:list()))
end

local function test_notes_outlive_a_store_closed_by_its_scope(dir: string)
  local path = dir .. "/kept.db"
  do
    local store <close> = assert(notes.open(path))
    store:add("kept")
  end
  do
    local again <close> = assert(notes.open(path))
    assert(texts(again:list()) == "1=kept", texts(again:list()))
    assert(again:add("next") == 2)
  end
  local last = assert(notes.open(path))
  assert(#last:list() == 2)
  last:close()
end

local function test_open_refuses_what_is_no_database(dir: string)
  local store, why = notes.open(dir)
  assert(store == nil and why ~= nil and why ~= "", "opened a directory as a database")
end
