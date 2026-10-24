--- Tests of [`build.syntax_typed`]: the rows the port reads of a module, how they are kept, and where they differ from what
--- the fork's build wrote of the same module.
local Rules = require("build.contract_rules")
local Receivers = require("build.syntax_receivers")
local Test = require("cosmic.test")
local Typed = require("build.syntax_typed")

Test.policy{}

--- What a row has besides its uses.
local record Extra
  problems: {string}
  error_lines: {integer}
  known?: {string}
end

--- A use whose text starts with `^` is one the fork cannot find ([`Receivers.Reference`]'s `top`).
local function row(refs: {string}, extra?: Extra): Typed.Row
  local out: {Receivers.Reference} = {}
  for _, text in ipairs(refs) do
    local module, member, line = text:match("^%^?(%S+) (%S+) (%d+)$")
    local beyond: boolean | nil = nil
    if text:sub(1, 1) == "^" then
      beyond = true
    end
    out[#out + 1] = { module = module, member = member, line = math.tointeger(tonumber(line)) or 0, top = beyond }
  end
  return {
    applies = true, refs = out, problems = extra ~= nil and extra.problems or {}, used = {}, sites = {}, untyped = 0,
    error_lines = extra ~= nil and extra.error_lines or {}, known = extra ~= nil and extra.known or {}, judged = false,
    stub = "",
  }
end

local function fork_file(refs: {string}, refused?: boolean, kind?: string): Typed.ForkFile
  local made = row(refs)
  return { kind = kind or "module", refused = refused == true, refs = made.refs }
end

local function compare(file: string, port: Typed.Row, fork: Typed.ForkFile, moved?: boolean): Typed.Outcome
  return Typed.compare(file, port, fork, function(): boolean
    return moved == true
  end)
end

local function test_a_module_the_port_reads_as_the_fork_built_it_differs_nowhere_and_counts_what_it_compared()
  local found = compare("a.tl", row({ "cosmic.zip Writer.close 3", "cosmic.zip Writer.name 4" }),
    fork_file({ "cosmic.zip Writer.close 3", "cosmic.zip Writer.name 4" }))
  assert(#found.differences == 0, table.concat(found.differences, "\n"))
  assert(found.counts["typed refs"] == 2 and found.counts["contracts"] == 1 and found.counts["kind"] == 1)
end

--- A use of a method through a record at the top of its module's file is one the fork cannot find: counted apart and not
--- compared, while one it can find, and does not, is still told. The mark survives the memo.
local function test_a_use_the_fork_cannot_name_is_counted_apart_and_not_compared()
  local fork = fork_file({ "m A.x 3" })
  local found = compare("a.tl", row({ "m A.x 3", "^m B.y 4", "^m B.z 5" }), fork)
  assert(#found.differences == 0, table.concat(found.differences, "\n"))
  assert(found.counts["typed refs beyond the fork"] == 2 and found.counts["typed refs"] == 1)
  assert(#compare("a.tl", row({ "^m B.y 4" }), fork).differences == 1)
  local kept = Typed.decode(Typed.encode(row({ "m A.x 3", "^m B.y 4" })))
  assert(kept ~= nil)
  local marks = ""
  for _, r in ipairs(kept.refs) do
    marks = marks .. tostring(r.top) .. " "
  end
  assert(marks == "nil true ", marks)
  assert(#compare("a.tl", kept, fork).differences == 0)
end

local function test_a_use_one_side_lacks_or_reads_on_another_line_is_told_once_for_each_row()
  local fork = fork_file({ "m A.x 3", "m A.y 4" })
  -- a swapped pair is one row on each side alone, and a use missing is one
  assert(#compare("a.tl", row({ "m A.x 3", "m A.y 5" }), fork).differences == 2)
  local lacking = compare("a.tl", row({ "m A.x 3" }), fork)
  assert(#lacking.differences == 1 and lacking.differences[1]:find("^typed refs: the fork finds m A.y:4 and the port does not"),
    table.concat(lacking.differences, "\n"))
  local extra = compare("a.tl", row({ "m A.x 3", "m A.y 4", "m A.z 4" }), fork)
  assert(#extra.differences == 1 and extra.differences[1]:find("^typed refs: the port finds m A.z:4 and the fork does not"),
    table.concat(extra.differences, "\n"))
  assert(#compare("a.tl", row({ "m B.x 3", "m A.y 4" }), fork).differences == 2)
  assert(#compare("a.tl", row({ "m A.x 3", "m A.y 4" }), fork).differences == 0)
end

local function test_a_use_on_a_line_the_port_cannot_see_is_passed_over_and_counted()
  local fork = fork_file({ "m A.y 4", "m A.z 6" })
  local found = compare("a.tl", row({ "m A.z 6" }, { problems = {}, error_lines = { 4 } }), fork)
  assert(#found.differences == 0, table.concat(found.differences, "\n"))
  assert(found.counts["typed refs lost to an invalid value"] == 1)
  -- the record of a binding of C is no exception: its use is told like any other
  assert(#compare("a.tl", row({ "m A.z 6" }), fork_file({ "cosmic.sys Stat.kind 3", "m A.z 6" })).differences == 1)
  -- an error on another line explains nothing, and a use only the port finds is never explained by one
  assert(#compare("a.tl", row({ "m A.z 6" }, { problems = {}, error_lines = { 5 } }), fork).differences == 1)
  assert(#compare("a.tl", row({ "m A.z 6", "m A.w 6" }, { problems = {}, error_lines = { 4, 6 } }), fork).differences == 1)
end

local function test_a_use_the_fork_keys_by_position_is_explained_by_the_name_the_port_reads_through_a_known_type()
  -- the fork finds Result.run on line 3 where the port reads `run` through a value of a known type (a module), and the port
  -- finds Split.head on line 5 where the fork found nothing of that name but Other.head
  local fork = fork_file({ "m Result.run 3", "m Other.head 5" })
  local port = row({ "m Split.head 5" }, { problems = {}, error_lines = {}, known = { "3 run", "5 head" } })
  local found = compare("a.tl", port, fork)
  assert(#found.differences == 0, table.concat(found.differences, "\n"))
  assert(found.counts["typed refs the fork keys by position"] == 3)
  -- a name the port reads through no known type is not explained, nor is a use only the port finds with no such partner
  assert(#compare("a.tl", row({ "m Split.head 5" }, { problems = {}, error_lines = {}, known = { "5 head" } }), fork).differences == 1)
  assert(#compare("a.tl", row({ "m Split.head 5", "m Split.tail 7" }, { problems = {}, error_lines = {}, known = { "3 run", "5 head" } }),
    fork).differences == 1)
end

local function test_a_file_whose_lines_moved_is_compared_by_module_and_member_alone()
  local fork = fork_file({ "m A.x 3", "m A.y 4" })
  local port = row({ "m A.y 10", "m A.x 9" })
  assert(#compare("a.tl", port, fork).differences == 4)
  assert(#compare("a.tl", port, fork, true).differences == 0)
  -- by member too: a use that is another member differs even where the lines moved
  assert(#compare("a.tl", row({ "m A.y 10", "m A.z 9" }), fork, true).differences == 2)
  -- and a use the port lacks is explained only where the checker reported an error somewhere in the file
  assert(#compare("a.tl", row({ "m A.x 9" }), fork, true).differences == 1)
  assert(#compare("a.tl", row({ "m A.x 9" }, { problems = {}, error_lines = { 20 } }), fork, true).differences == 0)
end

local function test_the_fork_refusing_a_module_and_the_port_finding_nothing_is_told_and_so_is_the_reverse()
  local held = compare("a.tl", row({}), fork_file({}, true))
  assert(#held.differences == 1 and held.differences[1]:find("^contracts: the fork refuses it"), table.concat(held.differences, "\n"))
  local breached = compare("a.tl", row({}, { problems = { "a.tl:3: f: its failure is ignored" }, error_lines = {} }), fork_file({}))
  assert(#breached.differences == 1 and breached.differences[1]:find("^contracts: the fork holds it and the port finds 1"),
    table.concat(breached.differences, "\n"))
  local agree = compare("a.tl", row({}, { problems = { "a.tl:3: f: its failure is ignored" }, error_lines = {} }), fork_file({}, true))
  assert(#agree.differences == 0, table.concat(agree.differences, "\n"))
end

local function test_a_stub_the_port_does_not_hold_and_the_fork_does_is_told()
  local port = Typed.judged(row({}), "the stub types it differently")
  local found = compare("cosmic/a.tl", port, fork_file({}))
  assert(#found.differences == 1 and found.differences[1]:find("^stub: the fork holds it and the port finds: "),
    table.concat(found.differences, "\n"))
  assert(found.counts["stub"] == 1)
  port = Typed.judged(row({}), "")
  assert(#compare("cosmic/a.tl", port, fork_file({})).differences == 0)
  assert(#compare("cosmic/a.tl", port, fork_file({}, true)).differences == 1)
end

local function test_a_file_the_build_staged_as_another_kind_than_its_name_says_is_told()
  local found = compare("a_test.tl", row({}), fork_file({}, false, "module"))
  assert(#found.differences >= 1 and found.differences[1]:find("^kind: "), table.concat(found.differences, "\n"))
  local test = row({})
  test.applies = false
  assert(#compare("a_test.tl", test, fork_file({}, false, "test")).differences == 0)
  local main = row({})
  assert(#compare("cmd/x/main.tl", main, fork_file({}, false, "main")).differences == 0)
end

local function test_the_exemptions_the_two_sides_need_are_compared_over_the_tree()
  local own = Rules.own_exemptions()
  local key = ""
  for k in pairs(own.casts) do
    key = k
    break
  end
  local file = assert(key:match("^([^:]*):"))
  local fork: Typed.Fork = { files = { [file] = fork_file({}) } }
  local port = row({})
  local entries: {string} = {}
  for name, held in pairs({ exempt = own.exempt, parsing = own.parsing, casts = own.casts, modes = own.modes }) do
    for k in pairs(held) do
      if k:sub(1, #file + 1) == file .. ":" then
        entries[#entries + 1] = name .. " " .. k
      end
    end
  end
  port.used = entries
  local found = Typed.used({ [file] = port }, fork)
  assert(#found.differences == 0 and found.counts["contracts used"] == #entries, table.concat(found.differences, "\n"))
  -- the entries of every file the fork built that the port needs none of are told
  local none = Typed.used({ [file] = row({}) }, fork)
  assert(#none.differences == 1 and none.differences[1]:find("^contracts used: "), table.concat(none.differences, "\n"))
  -- no file the fork built, no entry the fork needs
  local empty = Typed.used({}, { files = {} })
  assert(#empty.differences == 0 and empty.counts["contracts used"] == 0)
end

local function test_a_row_is_kept_and_read_back_as_it_was()
  local made = row({ "m A.x 3", "m B.y 4" }, { problems = { "a.tl:3: boom" }, error_lines = { 7, 9 } })
  made.used, made.sites, made.judged, made.stub = { "casts a.tl:f" }, { calls = 4, casts = 1 }, true, "why not"
  local back = assert(Typed.decode(Typed.encode(made)))
  assert(back.applies and #back.refs == 2 and back.refs[2].member == "B.y" and back.refs[2].line == 4)
  assert(back.problems[1] == "a.tl:3: boom" and back.used[1] == "casts a.tl:f")
  assert(back.error_lines[1] == 7 and back.error_lines[2] == 9)
  assert(back.sites.calls == 4 and back.sites.casts == 1 and back.sites.functions == 0)
  assert(back.judged and back.stub == "why not")
  assert(Typed.decode({ { "R", "m", "A.x", "3" } }) == nil, "a row with no applies marker is no row")
  assert(Typed.decode({ { "A", "1" }, { "Z" } }) == nil)
  assert(Typed.decode({ { "A", "1" }, { "R", "m", "A.x", "three" } }) == nil)
end

local function test_a_standard_library_module_is_judged_for_its_stub_and_no_other_file_is()
  assert(Typed.judges_stub("cosmic/zip.tl", "cosmic.zip"))
  assert(not Typed.judges_stub("cosmic/zip_test.tl", "cosmic.zip_test"))
  assert(not Typed.judges_stub("cosmic/zip_example.tl", "cosmic.zip_example"))
  assert(not Typed.judges_stub("build/zip.tl", "build.zip"))
  assert(not Typed.judges_stub("cosmic/internal/hash.d.tl", "cosmic.internal.hash"))
end
