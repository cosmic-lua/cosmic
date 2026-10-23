--- The tests of [`build.migrate`]: each rewrite is held by a program the new checker refuses once translated and accepts once
--- migrated, whose Lua gives what the fork's Lua of the original gives; the rewrites go on to a fixed point; a file it has
--- nothing to do for is returned as it was; and what the rewrites do not cover is left and reported.
local GrammarMode = require("build.grammar_mode")
local Migrate = require("build.migrate")
local Test = require("cosmic.test")
local standalone = require("build.standalone")
local teal = require("build.teal")
local type compiler = require("build.compiler")

-- The new checker types a file against the declarations the tool carries, which only a worker that holds the tool's database
-- ("cosmic") has.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- The project `files` migrated, `rounds` rounds at most: none for the translation alone.
local function migrated(files: {string: string}, rounds?: integer): Migrate.Result
  local result, why = Migrate.run(files, { rounds = rounds })
  return (assert(result, why))
end

--- The Lua `grammar` ("teal" for the fork, "new") writes of `source`, or nil and the refusal.
local function lua_of(tmp: string, source: string, grammar: GrammarMode.Mode): string | nil, string
  local fork: compiler | nil = nil
  if grammar == "teal" then
    fork = assert(teal.load(true))
  end
  return standalone.code("m.tl", source, { XDG_CACHE_HOME = tmp .. "/cache" }, fork, grammar)
end

local type Entry = function(): any

--- What the Lua of a program answers: the program returns the function that is its entry point, and this calls it.
local function value_of(code: string): any
  local chunk = assert(load(code, "=m", "t"))
  local entry = chunk()
  if entry is Entry then
    return entry()
  end
  error("the program returns no function")
end

--- The program `source`, the fork's Teal, migrated. Its translation is refused with `code` and the migrated program is accepted,
--- and the Lua of the migrated program answers what the fork's Lua of `source` answers, which is `expected`. Answers the
--- result.
local function holds(tmp: string, source: string, code: string, expected: any): Migrate.Result
  local result = migrated({ ["m.tl"] = source })
  -- the translation of the program is refused for it, and the migration rewrites it away
  assert((result.before[code] or 0) >= 1 and (result.rewrites[code] or 0) >= 1, code .. " was not found and rewritten")
  assert((result.after[code] or 0) == 0 and #result.left == 0, table.concat(result.untranslated, "\n"))
  local migrated_text = assert(result.texts["m.tl"])
  local accepted, why = lua_of(tmp, migrated_text, "new")
  assert(accepted ~= nil, tostring(why) .. "\n" .. migrated_text)
  assert(value_of(accepted) == expected, tostring(value_of(accepted)))
  local original = assert(lua_of(tmp, source, "teal"))
  assert(value_of(original) == expected, tostring(value_of(original)))
  return result
end

local function test_a_local_that_is_written_is_declared_mut(tmp: string)
  local result = holds(tmp, table.concat({
    "return function(): string",
    "  local names: {string} = {}",
    "  names[#names + 1] = \"a\"",
    "  names[#names + 1] = \"b\"",
    "  return table.concat(names, \",\")",
    "end",
    "",
  }, "\n"), "view_written", "a,b")
  assert(assert(result.texts["m.tl"]):find("local names: mut {string} = {}", 1, true) ~= nil)
  -- the two writes need one `mut`
  assert(result.rewrites.view_written == 1, tostring(result.rewrites.view_written))
end

local function test_a_parameter_that_is_written_is_declared_mut_once_its_field_write_is_an_index_write(tmp: string)
  -- The translator declares a parameter `mut` for the index writes it sees, not for `env.NAME = v`, which is a field write
  -- until the map's field is read by its key.
  local source = table.concat({
    "local function name(env: {string: string}): string",
    "  env.NAME = \"n\"",
    "  env.OTHER = \"o\"",
    "  return env[\"NAME\"] or \"\"",
    "end",
    "return function(): string",
    "  return name({})",
    "end",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.rewrites.map_field == 2 and result.rewrites.view_written == 1 and #result.left == 0 and result.rounds == 2,
    table.concat(result.untranslated, "\n"))
  local text = assert(result.texts["m.tl"])
  assert(text:find("name(env: mut {string: string}): string\n  env[\"NAME\"] = \"n\"\n  env[\"OTHER\"] = \"o\"\n", 1, true) ~= nil, text)
  assert(value_of((assert(lua_of(tmp, text, "new")))) == "n")
  assert(value_of((assert(lua_of(tmp, source, "teal")))) == "n")
end

local function test_an_optional_collection_is_declared_mut_inside_the_question_mark(tmp: string)
  local source = table.concat({
    "local function name(env: {string: string} | nil): string",
    "  if env == nil then",
    "    return \"\"",
    "  end",
    "  env.NAME = \"n\"",
    "  return env[\"NAME\"] or \"\"",
    "end",
    "return function(): string",
    "  return name({})",
    "end",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(#result.left == 0, table.concat(result.untranslated, "\n"))
  local text = assert(result.texts["m.tl"])
  assert(text:find("name(env: mut {string: string}?): string", 1, true) ~= nil, text)
  assert(value_of((assert(lua_of(tmp, text, "new")))) == "n")
end

local function test_the_collection_a_field_holds_is_declared_mut(tmp: string)
  -- The translator declares the fields of a name it knows the record of; a field of a field it does not.
  local result = holds(tmp, table.concat({
    "local record Inner",
    "  items: {string}",
    "end",
    "local record Outer",
    "  inner: Inner",
    "end",
    "return function(): integer",
    "  local o: Outer = { inner = { items = {} } }",
    "  o.inner.items[#o.inner.items + 1] = \"a\"",
    "  return #o.inner.items",
    "end",
    "",
  }, "\n"), "view_written", 1)
  assert(assert(result.texts["m.tl"]):find("  items: mut {string}\n", 1, true) ~= nil)
end

local function test_a_field_that_is_assigned_after_the_record_is_made_is_declared_mut(tmp: string)
  local result = holds(tmp, table.concat({
    "local record Inner",
    "  count: integer",
    "end",
    "local record Outer",
    "  inner: Inner",
    "end",
    "return function(): integer",
    "  local o: Outer = { inner = { count = 1 } }",
    "  o.inner.count = o.inner.count + 1",
    "  return o.inner.count",
    "end",
    "",
  }, "\n"), "field_fixed", 2)
  assert(assert(result.texts["m.tl"]):find("  mut count: integer\n", 1, true) ~= nil)
end

local function test_a_field_of_a_map_is_read_by_its_key(tmp: string)
  local result = holds(tmp, table.concat({
    "local function home(env: {string: string}): string",
    "  return env.HOME or \"none\"",
    "end",
    "return function(): string",
    "  return home({ HOME = \"/home\" })",
    "end",
    "",
  }, "\n"), "map_field", "/home")
  assert(assert(result.texts["m.tl"]):find("return env[\"HOME\"] or \"none\"", 1, true) ~= nil)
end

local function test_a_field_of_a_map_read_through_a_place_a_test_showed_is_there_is_read_by_its_key(tmp: string)
  -- `leg` is a map or nil, and the test shows it is there: the checker names the map, and the type recorded for the read is
  -- the optional.
  local result = holds(tmp, table.concat({
    "local function runner(legs: {string: {string: string}}, one: string): string",
    "  local leg = legs[one]",
    "  if leg == nil then",
    "    return \"\"",
    "  end",
    "  return leg.runner or \"\"",
    "end",
    "return function(): string",
    "  return runner({ a = { runner = \"r\" } }, \"a\")",
    "end",
    "",
  }, "\n"), "map_field", "r")
  assert(assert(result.texts["m.tl"]):find("return leg[\"runner\"] or \"\"", 1, true) ~= nil)
end

local function test_a_read_of_a_field_of_a_map_inside_a_read_of_one_is_made_in_two_rounds()
  -- `groups.first.NAME` reads a field of a map, and so does the map that comes out of it once the first is read by its key.
  local source = table.concat({
    "local function name(groups: {string: {string: string}}): string",
    "  return groups.first.NAME or \"\"",
    "end",
    "return name",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.rewrites.map_field == 2 and result.rounds == 2, tostring(result.rewrites.map_field))
  local text = assert(result.texts["m.tl"])
  assert(text:find("return groups[\"first\"][\"NAME\"] or \"\"", 1, true) ~= nil, text)
end

local function test_only_the_read_of_the_map_is_rewritten_in_a_chain_of_reads()
  local source = table.concat({
    "local record Box",
    "  n: integer",
    "end",
    "local function size(boxes: {string: Box}): integer",
    "  return boxes.first.n",
    "end",
    "return size",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.rewrites.map_field == 1, tostring(result.rewrites.map_field))
  local text = assert(result.texts["m.tl"])
  assert(text:find("return boxes[\"first\"].n\n", 1, true) ~= nil, text)
end

local function test_a_ternary_whose_value_is_never_false_is_an_if_expression(tmp: string)
  local result = holds(tmp, table.concat({
    "local function pick(flag: boolean, name: string): string",
    "  return flag and name or \"none\"",
    "end",
    "return function(): string",
    "  return pick(true, \"x\") .. pick(false, \"y\")",
    "end",
    "",
  }, "\n"), "and_ternary", "xnone")
  assert(assert(result.texts["m.tl"]):find("return if flag then name else \"none\" end", 1, true) ~= nil)
end

local function test_a_ternary_whose_value_can_be_nil_is_left_as_it_answers_differently(tmp: string)
  local source = table.concat({
    "local function pick(flag: boolean, name: string | nil): string",
    "  return flag and name or \"none\"",
    "end",
    "return function(): string",
    "  return pick(true, nil)",
    "end",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.after.and_ternary == 1 and (result.rewrites.and_ternary or 0) == 0)
  assert(assert(result.texts["m.tl"]):find("flag and name or \"none\"", 1, true) ~= nil)
  local finding = assert(result.left[1])
  assert(finding.code == "and_ternary" and finding.note:find("false or nil", 1, true) ~= nil, finding.note)
  -- the two answer differently where `name` is nil, so the program is left to a person
  assert(value_of((assert(lua_of(tmp, source, "teal")))) == "none")
end

local function test_the_type_of_an_empty_local_is_a_map_when_its_first_write_keys_a_string(tmp: string)
  local keyed = holds(tmp, table.concat({
    "return function(): integer",
    "  local seen = {}",
    "  seen[\"a\"] = true",
    "  seen[\"b\"] = true",
    "  local n = 0",
    "  for _ in pairs(seen) do",
    "    n = n + 1",
    "  end",
    "  return n",
    "end",
    "",
  }, "\n"), "literal_needs_type", 2)
  assert(assert(keyed.texts["m.tl"]):find("local seen: mut {string: boolean} = {}", 1, true) ~= nil)
end

local function test_the_type_of_an_empty_local_is_an_array_when_its_first_write_appends(tmp: string)
  local appended = holds(tmp, table.concat({
    "return function(): integer",
    "  local words = {}",
    "  words[#words + 1] = \"x\"",
    "  table.insert(words, \"y\")",
    "  return #words",
    "end",
    "",
  }, "\n"), "literal_needs_type", 2)
  assert(assert(appended.texts["m.tl"]):find("local words: mut {string} = {}", 1, true) ~= nil)
end

local function test_the_type_of_an_empty_local_is_an_array_when_its_first_write_is_a_table_insert(tmp: string)
  local inserted = holds(tmp, table.concat({
    "return function(): integer",
    "  local words = {}",
    "  table.insert(words, 7)",
    "  return words[1] or 0",
    "end",
    "",
  }, "\n"), "literal_needs_type", 7)
  assert(assert(inserted.texts["m.tl"]):find("local words: mut {integer} = {}", 1, true) ~= nil)
end

local function test_the_element_type_of_an_empty_local_may_be_a_type_of_the_file(tmp: string)
  local result = holds(tmp, table.concat({
    "local record Item",
    "  n: integer",
    "end",
    "return function(): integer",
    "  local items = {}",
    "  local item: Item = { n = 4 }",
    "  items[#items + 1] = item",
    "  return #items + item.n",
    "end",
    "",
  }, "\n"), "literal_needs_type", 5)
  assert(assert(result.texts["m.tl"]):find("local items: mut {Item} = {}", 1, true) ~= nil)
end

local function test_an_empty_local_whose_first_write_shows_no_plain_type_is_left()
  local source = table.concat({
    "local slots = {}",
    "local function put(i: integer, name: string)",
    "  slots[i] = name",
    "end",
    "return put",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.after.literal_needs_type == 1 and (result.rewrites.literal_needs_type or 0) == 0)
  local finding = assert(result.left[1])
  assert(finding.code == "literal_needs_type" and finding.note ~= "", finding.note)
end

local function test_two_rewrites_in_one_expression_are_made_together(tmp: string)
  local result = holds(tmp, table.concat({
    "local function pick(env: {string: string}, ok: boolean, v: string): string",
    "  return ok and v or env.NAME or \"\"",
    "end",
    "return function(): string",
    "  return pick({ NAME = \"n\" }, false, \"v\")",
    "end",
    "",
  }, "\n"), "and_ternary", "n")
  assert(assert(result.texts["m.tl"]):find("return if ok then v else env[\"NAME\"] end or \"\"", 1, true) ~= nil)
  assert(result.rewrites.map_field == 1)
end

local function test_a_rewrite_after_a_splice_on_the_same_line_lands_where_it_belongs()
  -- The checker reads `Shape.record_of("Opts")` with a spec spliced after it, which moves the columns after the call on
  -- its line; the rewrite is made on the line as written.
  local source = table.concat({
    "local Shape = require(\"cosmic.shape\")",
    "local record Opts",
    "  name: string",
    "end",
    "return function(): integer",
    "  local spec = Shape.record_of(\"Opts\") local words: {string} = {} words[#words + 1] = \"a\"",
    "  if spec == nil then",
    "    return 0",
    "  end",
    "  return #words",
    "end",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.after.view_written == nil, table.concat(result.untranslated, "\n"))
  local text = assert(result.texts["m.tl"])
  assert(text:find("local words: mut {string} = {} words[#words + 1] = \"a\"", 1, true) ~= nil, text)
end

local function test_a_field_of_a_record_another_file_declares_is_declared_in_that_file()
  local pins = table.concat({
    "local record Pins",
    "  record Pin",
    "    url: string",
    "    keep: {string}",
    "  end",
    "  new: function(): Pins.Pin",
    "end",
    "function Pins.new(): Pins.Pin",
    "  return { url = \"\", keep = {} }",
    "end",
    "return Pins",
    "",
  }, "\n")
  local update = table.concat({
    "local Pins = require(\"pins\")",
    "local function update(pin: Pins.Pin, url: string)",
    "  pin.url = url",
    "  pin.keep[#pin.keep + 1] = url",
    "end",
    "return update",
    "",
  }, "\n")
  local before = migrated({ ["pins.tl"] = pins, ["update.tl"] = update }, 0)
  assert(before.before.field_fixed == 1 and before.before.view_written == 1)
  local result = migrated({ ["pins.tl"] = pins, ["update.tl"] = update })
  assert(result.after.field_fixed == nil and result.after.view_written == nil, table.concat(result.untranslated, "\n"))
  local declared = assert(result.texts["pins.tl"])
  assert(declared:find("    mut url: string\n", 1, true) ~= nil and declared:find("    keep: mut {string}\n", 1, true) ~= nil,
    declared)
  -- the file that wrote them is the one it was
  assert(result.texts["update.tl"] == update)
  assert(result.changed[1] == "pins.tl" and #result.changed == 1, table.concat(result.changed, ","))
end

local function test_a_field_is_declared_alike_in_the_interface_a_record_lists_and_in_what_lists_it(tmp: string)
  -- A type that lists an interface declares each field as it does, so the interface and the other record that lists it
  -- change with the record that is written.
  local result = holds(tmp, table.concat({
    "local interface Named",
    "  label: string",
    "end",
    "local record Item is Named",
    "  label: string",
    "  n: integer",
    "end",
    "local record Other is Named",
    "  label: string",
    "end",
    "local record Holder",
    "  item: Item",
    "  other: Other",
    "end",
    "return function(): string",
    "  local h: Holder = { item = { label = \"a\", n = 1 }, other = { label = \"c\" } }",
    "  h.item.label = \"b\"",
    "  return h.item.label .. h.other.label",
    "end",
    "",
  }, "\n"), "field_fixed", "bc")
  local text = assert(result.texts["m.tl"])
  assert(text:find("local interface Named\n  mut label: string\n", 1, true) ~= nil, text)
  assert(text:find("local record Item is Named\n  mut label: string\n", 1, true) ~= nil, text)
  assert(text:find("local record Other is Named\n  mut label: string\n", 1, true) ~= nil, text)
end

local function test_a_field_a_class_declares_as_a_method_is_never_declared_mut()
  -- A method is fixed, so the field its class implements stays fixed and the write that needs it is left to a person.
  local source = table.concat({
    "local interface Source",
    "  read: function(self: Source): string",
    "end",
    "local class Fixed is Source",
    "  function read(self): string",
    "    return \"x\"",
    "  end",
    "end",
    "local record Holder",
    "  source: Source",
    "end",
    "return function(h: Holder)",
    "  h.source.read = function(_self: Source): string",
    "    return \"y\"",
    "  end",
    "end",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.after.field_fixed == 1 and (result.rewrites.field_fixed or 0) == 0, tostring(result.after.field_fixed))
  assert(assert(result.texts["m.tl"]):find("mut", 1, true) == nil)
  local note = assert(result.left[1]).note
  assert(note:find("`Fixed` lists `Source` and declares `read` as a method", 1, true) ~= nil, note)
end

local function test_a_field_a_type_declares_mut_and_the_interface_it_lists_fixed_is_made_mut_in_both(tmp: string)
  -- The two interfaces are both called `Held`, so the translator, which follows the last name of a super within the file,
  -- cannot carry the `mut` of `Guard.flag` to `A.Held` and to `Other`, as it does for an interface of another file.
  local result = holds(tmp, table.concat({
    "local record A",
    "  interface Held",
    "    flag: boolean",
    "  end",
    "end",
    "local record B",
    "  interface Held",
    "    other: boolean",
    "  end",
    "end",
    "local record Guard is A.Held",
    "  flag: boolean",
    "end",
    "local record Other is A.Held",
    "  flag: boolean",
    "end",
    "return function(b: B.Held | nil): boolean",
    "  local g: Guard = { flag = false }",
    "  g.flag = true",
    "  local o: Other = { flag = true }",
    "  return g.flag and o.flag and b == nil",
    "end",
    "",
  }, "\n"), "interface_disagrees", true)
  local text = assert(result.texts["m.tl"])
  assert(text:find("  interface Held\n    mut flag: boolean\n", 1, true) ~= nil, text)
  assert(text:find("local record Guard is A.Held\n  mut flag: boolean\n", 1, true) ~= nil, text)
  assert(text:find("local record Other is A.Held\n  mut flag: boolean\n", 1, true) ~= nil, text)
  assert(text:find("    other: boolean\n", 1, true) ~= nil and text:find("mut other", 1, true) == nil, text)
end

local function test_a_record_nested_in_another_is_found_by_its_path(tmp: string)
  -- Written in the new grammar, which the translator takes as it is: the interface has `mut flag` and the nested record does not.
  local source = table.concat({
    "local record A",
    "  interface Held",
    "    mut flag: boolean",
    "  end",
    "end",
    "local record Ns",
    "  record Guard is A.Held",
    "    flag: boolean",
    "  end",
    "end",
    "return function(): boolean",
    "  local g: Ns.Guard = { flag = true }",
    "  return g.flag",
    "end",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.before.interface_disagrees == 1 and result.after.interface_disagrees == nil and #result.left == 0)
  local text = assert(result.texts["m.tl"])
  assert(text:find("  record Guard is A.Held\n    mut flag: boolean\n", 1, true) ~= nil, text)
  assert(value_of((assert(lua_of(tmp, text, "new")))) == true)
end

local function test_a_disagreement_of_a_type_is_left_for_a_person()
  local source = table.concat({
    "local interface Sized",
    "  n: integer",
    "end",
    "local record Box is Sized",
    "  n: string",
    "end",
    "return function(b: Box)",
    "  local _ = b",
    "end",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.after.interface_disagrees == 1 and next(result.rewrites) == nil)
  assert(result.texts["m.tl"] == source and assert(result.left[1]).note == "")
end

local function test_an_interface_field_a_class_declares_as_a_method_stays_in_disagreement()
  -- [`FdReader.skip`] is assigned, so the translator makes it and [`Reader.skip`] `mut`; `Fake` implements it as a method.
  local source = table.concat({
    "local interface Reader",
    "  skip: function(self: Reader, n: integer): boolean",
    "end",
    "local record FdReader is Reader",
    "  skip: function(self: FdReader, n: integer): boolean",
    "end",
    "local record Fake is Reader",
    "  skip: function(self: Fake, n: integer): boolean",
    "end",
    "local function file_skip(_self: FdReader, _n: integer): boolean",
    "  return true",
    "end",
    "function Fake:skip(_n: integer): boolean",
    "  return false",
    "end",
    "return function(r: FdReader)",
    "  r.skip = file_skip",
    "end",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.after.interface_disagrees == 1 and (result.rewrites.interface_disagrees or 0) == 0)
  local note = assert(result.left[1]).note
  assert(note:find("`Fake` declares `skip` as a method, which is never `mut`", 1, true) ~= nil, note)
end

local function test_a_field_an_interface_already_declares_mut_is_not_declared_twice()
  local source = table.concat({
    "local interface Named",
    "  mut label: string",
    "end",
    "local record Item is Named",
    "  label: string",
    "end",
    "local record Holder",
    "  item: Item",
    "end",
    "return function(h: Holder)",
    "  h.item.label = \"b\"",
    "end",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  local text = assert(result.texts["m.tl"])
  assert(text:find("local interface Named\n  mut label: string\n", 1, true) ~= nil and
      text:find("local record Item is Named\n  mut label: string\n", 1, true) ~= nil, text)
  assert(#result.left == 0)
end

local function test_a_record_in_a_declaration_file_is_given_its_mut_there()
  local pins = table.concat({
    "local record Pins",
    "  record Pin",
    "    url: string",
    "  end",
    "end",
    "return Pins",
    "",
  }, "\n")
  local update = table.concat({
    "local Pins = require(\"pins\")",
    "local function update(pin: Pins.Pin, url: string)",
    "  pin.url = url",
    "end",
    "return update",
    "",
  }, "\n")
  local result = migrated({ ["pins.d.tl"] = pins, ["update.tl"] = update })
  assert(result.after.field_fixed == nil, table.concat(result.untranslated, "\n"))
  assert(assert(result.texts["pins.d.tl"]):find("    mut url: string\n", 1, true) ~= nil)
  assert(result.changed[1] == "pins.d.tl" and #result.changed == 1)
end

local function test_a_function_assigned_to_the_table_of_a_module_is_left()
  local source = table.concat({
    "local Fs = require(\"cosmic.fs\")",
    "return function(): boolean",
    "  Fs.exists = function(_path: string): boolean | nil, string",
    "    return true, \"\"",
    "  end",
    "  return true",
    "end",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.after.field_fixed == 1 and (result.rewrites.field_fixed or 0) == 0)
  assert(assert(result.left[1]).note:find("table of the module's functions", 1, true) ~= nil)
end

local function test_a_field_of_the_standard_library_is_left()
  local source = table.concat({
    "local Http = require(\"cosmic.http\")",
    "local function options(digest: string): Http.Options",
    "  local given: Http.Options = {}",
    "  given.sha256 = digest",
    "  return given",
    "end",
    "return options",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.after.field_fixed == 1)
  local finding = assert(result.left[1])
  assert(finding.code == "field_fixed" and finding.note:find("which this run does not write", 1, true) ~= nil, finding.note)
end

local function test_a_local_made_from_a_view_is_left_and_not_declared_mut()
  local source = table.concat({
    "local function copy(names: {string}): {string}",
    "  local out: {string} = names",
    "  out[#out + 1] = \"x\"",
    "  return out",
    "end",
    "return copy",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.after.view_written == 1, tostring(result.after.view_written))
  assert(assert(result.texts["m.tl"]):find("local out: {string} = names", 1, true) ~= nil)
  assert(assert(result.left[1]).note:find("made from a view", 1, true) ~= nil)
end

--- The programs that need two rounds: `copy` is made from `names`, which is a view until the first round declares it `mut`.
local TWO_ROUNDS <const> = table.concat({
  "return function(): string",
  "  local names: {string} = {}",
  "  names[#names + 1] = \"a\"",
  "  local copy: {string} = names",
  "  copy[#copy + 1] = \"b\"",
  "  return table.concat(copy, \",\")",
  "end",
  "",
}, "\n")

local function test_the_rewrites_go_on_until_nothing_changes(tmp: string)
  local result = migrated({ ["m.tl"] = TWO_ROUNDS })
  assert(result.rounds == 2 and result.converged, tostring(result.rounds))
  assert(#result.left == 0)
  local text = assert(result.texts["m.tl"])
  assert(text:find("local names: mut {string} = {}", 1, true) ~= nil and text:find("local copy: mut {string} = names", 1, true) ~= nil,
    text)
  assert(value_of((assert(lua_of(tmp, text, "new")))) == "a,b")
  -- a project that is migrated is migrated to itself
  local again = migrated({ ["m.tl"] = text })
  assert(again.texts["m.tl"] == text and #again.changed == 0 and again.rounds == 0 and next(again.rewrites) == nil)
end

local function test_a_run_that_is_still_rewriting_at_its_last_round_says_so()
  local result = migrated({ ["m.tl"] = TWO_ROUNDS }, 1)
  assert(result.rounds == 1 and not result.converged)
  assert(result.after.view_written == 1, tostring(result.after.view_written))
end

local function test_a_file_with_nothing_to_rewrite_is_returned_as_it_is()
  local source = table.concat({
    "--- A box.",
    "local record Box",
    "  --- What it holds.",
    "  mut n: integer",
    "  tags: mut {string}",
    "end",
    "",
    "-- Sets the count.",
    "local function set(b: Box, n: integer?): integer -- the answer",
    "  b.n = n or 0",
    "  b.tags[#b.tags + 1] = \"x\"",
    "  return b.n",
    "end",
    "",
    "return set",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  local text = assert(result.texts["m.tl"])
  assert(text == source and #result.changed == 0 and next(result.rewrites) == nil and #result.left == 0, text)
end

local function test_comments_and_layout_outside_the_rewritten_tokens_stay()
  local source = table.concat({
    "local function pick(env: {string: string}, names: {string}, ok: boolean, word: string): string",
    "  -- the first comment",
    "  names[#names + 1] = env.HOME or \"\"   -- trailing",
    "",
    "",
    "  local out = ok and word or \"no\"   --   spaced",
    "\treturn out .. (names[1] or \"\")",
    "end",
    "return pick",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(#result.left == 0, table.concat(result.untranslated, "\n"))
  local expected = table.concat({
    "local function pick(env: {string: string}, names: mut {string}, ok: boolean, word: string): string",
    "  -- the first comment",
    "  names[#names + 1] = env[\"HOME\"] or \"\"   -- trailing",
    "",
    "",
    "  local out = if ok then word else \"no\" end   --   spaced",
    "\treturn out .. (names[1] or \"\")",
    "end",
    "return pick",
    "",
  }, "\n")
  local text = assert(result.texts["m.tl"])
  assert(text == expected, text)
end

local function test_what_the_rewrites_do_not_cover_is_left_and_reported_and_never_cast()
  local source = table.concat({
    "local function first(s: string | nil): string",
    "  return s",
    "end",
    "return first",
    "",
  }, "\n")
  local result = migrated({ ["m.tl"] = source })
  assert(result.after.nil_not_allowed == 1 and #result.left == 1)
  local finding = assert(result.left[1])
  assert(finding.path == "m.tl" and finding.y == 2 and finding.code == "nil_not_allowed" and finding.note == "", finding.msg)
  local text = assert(result.texts["m.tl"])
  assert(text:find(" as ", 1, true) == nil and text:find("any", 1, true) == nil, text)
end

local function test_a_form_the_translator_does_not_handle_is_told_and_the_other_files_are_migrated()
  local tuple = "local pair: {{string, integer}} = {}\nreturn pair\n"
  local plain = "local function f(s: string | nil): string | nil\n  return s\nend\nreturn f\n"
  local result = migrated({ ["tuple.tl"] = tuple, ["plain.tl"] = plain })
  assert(#result.untranslated == 1 and result.untranslated[1]:find("tuple.tl:1:", 1, true) == 1 and
      result.untranslated[1]:find("(tuple_type)", 1, true) ~= nil, table.concat(result.untranslated, "\n"))
  assert(assert(result.texts["plain.tl"]):find("(s: string?): string?", 1, true) ~= nil)
  assert(result.changed[1] == "plain.tl" or result.changed[2] == "plain.tl")
end

local function test_the_findings_before_and_after_are_counted_by_code()
  local result = migrated({ ["m.tl"] = TWO_ROUNDS })
  assert(result.before.view_written == 2 and result.after.view_written == nil)
  assert(result.rewrites.view_written == 2, tostring(result.rewrites.view_written))
end
