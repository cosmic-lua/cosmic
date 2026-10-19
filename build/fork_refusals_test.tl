--- Tests of [`build.fork_refusals`]: the templates of the fork's refusals read from its source, and the list of them that the switch's gate
--- holds the verdict table to ([`testdata/gate/fork_refusals.json`]).
local ForkRefusals = require("build.fork_refusals")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Verdicts = require("lang.check_verdicts")

Test.policy{ grants = {
  { path = "checker", letters = "r" },
  { path = "testdata/gate", letters = "r" },
} }

local NONE <const>: ForkRefusals.Notes = { extra = {}, skipped = {} }

--- The templates of the calls and hand-offs in `source`, in order, each as `kind template`.
local function templates(source: string, notes?: ForkRefusals.Notes): {string}
  local out: {string} = {}
  for _, site in ipairs(ForkRefusals.sites(ForkRefusals.tokens(source), notes or NONE)) do
    out[#out + 1] = site.kind .. " " .. site.template
  end
  return out
end

--- Whether `source` gives exactly `want`.
local function gives(source: string, want: {string}): boolean
  local got = templates(source)
  return table.concat(got, "\n") == table.concat(want, "\n")
end

local function test_the_tokens_drop_comments_and_decode_strings()
  local tokens = ForkRefusals.tokens("-- a\nlocal a = \"x\\ny\" --[[ b\nc ]] .. 'it''s' [==[z]==]\nb()")
  local texts: {string} = {}
  for _, token in ipairs(tokens) do
    texts[#texts + 1] = token.kind .. ":" .. token.text
  end
  assert(table.concat(texts, " ") == "name:local name:a symbol:= string:x\ny symbol:.. string:it string:s string:z name:b symbol:( symbol:)",
    table.concat(texts, " "))
  local last = tokens[#tokens]
  assert(last ~= nil and last.line == 4)
end

local function test_a_call_that_reports_gives_the_message_it_spells_with_its_variable_parts_as_one_placeholder()
  assert(gives("self.errs:add(node, \"cannot use \" .. name .. \" here\")", { "type cannot use %s here" }))
  assert(gives("self.errs:add(node, \"a \" .. x .. y .. \" b\")", { "type a %s b" }))
  assert(gives("self.errs:invalid_at(node, \"got %s, expected %d\", a, b)", { "type got %s, expected %s" }))
  assert(gives("self.errs:add_coded(node, Errors.make({ code = \"x\" }), \"one\")", { "type one" }))
  assert(gives("self.errs:add_coded_in_context(a, b, Errors.make(), \"two\")", { "type two" }))
  assert(gives("return { Err(\"three\", a) }", { "type three" }))
  assert(gives("fail(ps, i, \"expected \" .. kind)", { "syntax expected %s" }))
  assert(gives("error(\"four\")", { "internal four" }))
  assert(gives("return false, { Errors.coded(Errors.make({ code = \"x\" }),\n  \"five \" .. n .. \" six\", a) }", { "type five %s six" }))
  assert(gives("self.errs:add(w, (\"field '%s' is read-only\"):format(k))", { "type field '%s' is read-only" }))
end

local function test_a_call_on_another_object_or_a_declaration_or_a_method_of_something_else_reports_nothing()
  assert(gives("things:add(node, \"x\")", {}))
  assert(gives("function Errors:add(w, msg)\nend", {}))
  assert(gives("local function fail(ps, i, msg)\nend", {}))
  assert(gives("self.state:error(\"x\")", {}))
  assert(gives("self.errs:add(node, msg)", {}))
end

-- (a hand-off on the first lines of a file is the lexer's or the parser's)
local function test_a_function_that_hands_a_message_on_gives_it()
  assert(gives("return nil, \"abstract: \" .. tostring(def)", { "syntax abstract: %s" }))
  assert(gives("return false, \"cannot mix %s\"", { "syntax cannot mix %s" }))
  assert(gives("return nil, nil, \"malformed pattern\"", { "syntax malformed pattern" }))
  assert(gives("errm, erra = \"index \" .. n .. \" out\", ra", { "syntax index %s out" }))
  assert(gives("local msg = (\"a %d b\"):format(1)", { "syntax a %s b" }))
  assert(gives("emitted.err = \"gen\"", { "syntax gen" }))
  -- not a message: a number, a table field that is no message, an assignment to something else
  assert(gives("return nil, 1\nerr.code = \"mismatch\"\nlocal x = \"hello\"", {}))
end

local function test_the_kind_follows_the_line_of_a_hand_off_and_the_call_of_a_report()
  local text = string.rep("\n", 4800) .. "return nil, \"late\""
  assert(gives(text, { "type late" }))
  assert(gives("return nil, \"early\"", { "syntax early" }))
end

local function test_a_message_in_a_choice_is_told_until_its_lines_are_named()
  local source = "fail(ps, i, x\n  and \"one\"\n  or \"two\")"
  local made = ForkRefusals.collect(ForkRefusals.sites(ForkRefusals.tokens(source), NONE))
  assert(#made.refusals == 0 and #made.trouble == 1, tostring(#made.trouble))
  local named = ForkRefusals.sites(ForkRefusals.tokens(source), { extra = { [2] = true, [3] = true }, skipped = {} })
  local got: {string} = {}
  for _, site in ipairs(named) do
    got[#got + 1] = site.template
  end
  assert(table.concat(got, "|") == "one|two", table.concat(got, "|"))
  -- a line the rules read wrongly is skipped
  local skipped = ForkRefusals.sites(ForkRefusals.tokens("return nil, \"a file\""), { extra = {}, skipped = { [1] = true } })
  assert(#skipped == 0)
end

local function test_a_template_is_each_message_once_with_every_place_it_is_spelled()
  local source = "fail(ps, i, \"one\")\nfail(ps, i, \"two\")\nreturn nil, \"one\""
  local sites: {ForkRefusals.Site} = {}
  for _, site in ipairs(ForkRefusals.sites(ForkRefusals.tokens(source), NONE)) do
    sites[#sites + 1] = { file = "f.tl", line = site.line, head = site.head, kind = site.kind, template = site.template }
  end
  local made = ForkRefusals.collect(sites)
  assert(#made.refusals == 2 and #made.trouble == 0)
  for i, refusal in ipairs(made.refusals) do
    if i == 1 then
      assert(table.concat(refusal.sites, " ") == "f.tl:1 f.tl:3", table.concat(refusal.sites, " "))
      assert(refusal.id == ForkRefusals.id("syntax", "one"))
    else
      assert(refusal.template == "two")
    end
  end
  assert(ForkRefusals.id("syntax", "one") ~= ForkRefusals.id("type", "one"))
end

local function test_a_message_is_the_template_whose_fixed_parts_it_holds_in_order()
  assert(ForkRefusals.matches("got %s, expected %s", "got integer, expected string"))
  assert(ForkRefusals.matches("got %s, expected %s", "in assignment: got integer, expected string -- a note"))
  assert(not ForkRefusals.matches("got %s, expected %s", "expected string, got integer"))
  assert(not ForkRefusals.matches("unknown type %s", "unknown variable x"))
  -- the parts in order: `a ` and ` b` are both in `x b y a z`, the second before the first
  assert(not ForkRefusals.matches("a %s b", "x b y a z"))
  assert(ForkRefusals.matches("a %s b", "x a y b z"))
  assert(ForkRefusals.matches("%s", "anything"))
  assert(ForkRefusals.fixed("got %s, expected %s") == #"got , expected ")
end

local function test_the_templates_a_message_is_leave_out_a_general_case_of_another_and_keep_a_wrapper()
  local list: {ForkRefusals.Refusal} = {
    { id = "a", kind = "type", template = "got %s, expected %s", sites = {} },
    { id = "b", kind = "type", template = "in tuple entry %s: got %s, expected %s", sites = {} },
    { id = "c", kind = "type", template = "in map key: %s", sites = {} },
    { id = "d", kind = "syntax", template = "got %s, expected %s", sites = {} },
  }
  local function ids(kind: string, message: string): string
    return table.concat(ForkRefusals.best(list, kind, message), " ")
  end
  assert(ids("type", "in tuple entry 2: got a, expected b") == "b")
  assert(ids("type", "got a, expected b") == "a")
  assert(ids("type", "in map key: got a, expected b") == "a c")
  assert(ids("syntax", "got a, expected b") == "d")
  assert(ids("type", "nothing like it") == "")
end

--- The first difference between the templates of the source and the list, or "".
local function difference(read: {ForkRefusals.Refusal}, listed: {Verdicts.Refusal}): string
  if #read ~= #listed then
    return "the source has " .. tostring(#read) .. " templates and the list " .. tostring(#listed)
  end
  for i, each in ipairs(read) do
    local other = listed[i]
    if other == nil then
      return "template " .. tostring(i) .. " is `" .. each.template .. "` in the source and none in the list"
    end
    if each.id ~= other.id or each.kind ~= other.kind or each.template ~= other.template or
        table.concat(each.sites, " ") ~= other.sites then
      return "template " .. tostring(i) .. " is `" .. each.template .. "` at " .. table.concat(each.sites, " ") ..
        " in the source and `" .. other.template .. "` at " .. other.sites .. " in the list"
    end
  end
  return ""
end

local function listed(): {Verdicts.Refusal}
  local list, trouble = Verdicts.read_refusals((assert(Fs.read("testdata/gate/fork_refusals.json"))))
  assert(list ~= nil, trouble)
  return list
end

local function test_the_list_is_what_the_source_of_the_fork_says_in_order()
  local made = (assert(ForkRefusals.read()))
  assert(#made.trouble == 0, table.concat(made.trouble, "\n"))
  -- both sides hold templates: a list that compared nothing would agree with anything
  assert(#made.refusals == 287 and #listed() == 287, tostring(#made.refusals) .. " " .. tostring(#listed()))
  local told = difference(made.refusals, listed())
  assert(told == "", told .. ": run bin/cosmic build/gate_refusals.tl, and give each new template a program or a reason")
end

local function test_a_difference_between_the_source_and_the_list_is_told()
  local made = (assert(ForkRefusals.read()))
  local list = listed()
  -- a template lost, a template changed, a place moved
  local fewer: {Verdicts.Refusal} = {}
  for i, each in ipairs(list) do
    if i > 1 then
      fewer[#fewer + 1] = each
    end
  end
  assert(difference(made.refusals, fewer):find("287 templates and the list 286", 1, true) ~= nil)
  local first = list[1]
  assert(first ~= nil)
  local changed: {Verdicts.Refusal} = { { id = first.id, kind = first.kind, template = first.template .. "!", sites = first.sites,
    reason = "", why = "" } }
  for i, each in ipairs(list) do
    if i > 1 then
      changed[#changed + 1] = each
    end
  end
  assert(difference(made.refusals, changed):find("template 1 is", 1, true) ~= nil)
  local moved: {Verdicts.Refusal} = { { id = first.id, kind = first.kind, template = first.template, sites = first.sites .. " x:1",
    reason = "", why = "" } }
  for i, each in ipairs(list) do
    if i > 1 then
      moved[#moved + 1] = each
    end
  end
  assert(difference(made.refusals, moved):find("template 1 is", 1, true) ~= nil)
end

--- The lines of the fork's source that the list names as places a message is spelled, for `file`.
local function named_lines(file: string): {integer: boolean}
  local out: {integer: boolean} = {}
  for _, each in ipairs(listed()) do
    for place in each.sites:gmatch("%S+") do
      local at, line = place:match("^(.*):(%d+)$")
      local number = math.tointeger(tonumber(line))
      if at == file and number ~= nil then
        out[number] = true
      end
    end
  end
  return out
end

local function test_every_line_of_the_fork_that_calls_a_report_with_a_string_is_a_place_in_the_list()
  -- found by the text of each line and not by the tokens the tool reads, so that a call the tool misses is seen
  local named = named_lines("checker/tl.tl")
  local missing: {string} = {}
  local seen = 0
  local line_no = 0
  for line in (assert(Fs.read("checker/tl.tl")) .. "\n"):gmatch("(.-)\n") do
    line_no = line_no + 1
    local call = line:match("errs:([%a_]+)%(") or line:match("Errors%.(coded)%(")
    if call ~= nil and (call == "add" or call == "add_coded" or call == "invalid_at" or call == "invalid_coded" or
        call == "invalid_key_at" or call == "add_in_context" or call == "add_coded_in_context" or call == "coded") and line:find("\"[^\"]") ~= nil then
      seen = seen + 1
      -- `msg:format("T", "T", "T")` is the text of a message spelled at checker/tl.tl:15068
      if named[line_no] ~= true and not line:find("msg:format", 1, true) then
        missing[#missing + 1] = tostring(line_no) .. ": " .. line:gsub("^%s+", "")
      end
    end
  end
  assert(seen > 100, "the text holds " .. tostring(seen) .. " such lines")
  assert(#missing == 0, tostring(#missing) .. " lines call a report with a string and are no place in the list:\n" ..
      table.concat(missing, "\n", 1, math.min(#missing, 6)))
end
