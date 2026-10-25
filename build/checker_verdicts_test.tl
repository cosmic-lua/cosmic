--- Tests of the verdict harness, [`build.checker_verdicts`]: its lines are a
--- function of the sources and the checker, they carry a finding at its place,
--- and the programs it dumps are the ones the checker's fuzz properties draw.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Fuzz = require("build.fuzz")
local Test = require("cosmic.test")
local programs = require("build.checker_programs")
local teal = require("build.teal")
local verdicts = require("build.checker_verdicts")
local type compiler = require("build.compiler")

-- `FUZZ_SEED` is declared because [`Fuzz.run`], which the seeding is compared
-- with, reads it.
Test.policy{ env = { "FUZZ_SEED" } }

local built = { value = nil as compiler? }

--- The tree's checker, loaded once.
local function checker(): compiler
  if built.value == nil then
    built.value = assert(teal.load(true))
  end
  return built.value
end

local function test_a_known_error_is_a_line_at_its_place()
  local text = verdicts.render(verdicts.program_lines(checker(), "bad.tl",
    'local n: integer = "a"\nreturn n\n'))
  assert(text == 'bad.tl\ttype.mismatch\t1\t20\tin local declaration: n: got string "a", expected integer\n',
    text)
end

local function test_a_warning_and_a_syntax_error_are_lines_too()
  local warned = verdicts.render(verdicts.program_lines(checker(), "w.tl", "local unused = 1\n"))
  assert(warned == "w.tl\twarning.unused\t1\t7\tunused variable unused: integer\n", warned)
  local cut = verdicts.render(verdicts.program_lines(checker(), "s.tl", "local x =\n"))
  assert(cut:find("^s%.tl\tsyntax%.[%w_]+\t") ~= nil, cut)
end

local function test_two_runs_give_the_same_text()
  local source = programs.drawn("total", 1, 4)
  local function run(): string
    local lines: mut {verdicts.Line} = {}
    for n, text in ipairs(source) do
      for _, line in ipairs(verdicts.program_lines(checker(), "p" .. n .. ".tl", text)) do
        lines[#lines + 1] = line
      end
    end
    return verdicts.render(lines)
  end
  local first = run()
  assert(first ~= "", "the drawn programs gave no finding to compare")
  assert(first == run())
end

local function test_lines_are_sorted_by_file_then_position()
  local function line(file: string, y: integer, x: integer, message: string): verdicts.Line
    return { file = file, code = "type.other", y = y, x = x, message = message }
  end
  local text = verdicts.render({ line("b.tl", 1, 1, "m"), line("a.tl", 10, 1, "m"),
    line("a.tl", 2, 9, "m"), line("a.tl", 2, 3, "z"), line("a.tl", 2, 3, "y") })
  assert(text == table.concat({
    "a.tl\ttype.other\t2\t3\ty\n", "a.tl\ttype.other\t2\t3\tz\n", "a.tl\ttype.other\t2\t9\tm\n",
    "a.tl\ttype.other\t10\t1\tm\n", "b.tl\ttype.other\t1\t1\tm\n",
  }), text)
end

local function test_a_message_stays_on_its_line()
  local text = verdicts.render({ { file = "t\tab.tl", code = "type.other", y = 1, x = 1,
    message = "a\nb\tc\\d\r" } })
  assert(text == "t\\tab.tl\ttype.other\t1\t1\ta\\nb\\tc\\\\d\\r\n", text)
end

local function test_a_module_is_found_by_name_and_its_findings_are_its_own(tmp: string)
  local root = tmp .. "/tree"
  assert(Fs.mkdirs(root .. "/sub"))
  assert(Fs.write(root .. "/a.tl", 'local b = require("b")\nlocal s = require("sub")\nreturn b.n + s.m\n'))
  assert(Fs.write(root .. "/b.tl", 'local record B\n  n: integer\nend\nlocal v: string = 1\nreturn { n = 1 } as B\n'))
  assert(Fs.write(root .. "/sub/init.tl", 'local record S\n  m: integer\nend\nreturn { m = 2 } as S\n'))
  assert(Fs.mkdirs(root .. "/.hidden"))
  assert(Fs.write(root .. "/.hidden/h.tl", "this is not teal\n"))
  assert(Fs.mkdirs(root .. "/ci"))
  assert(Fs.write(root .. "/ci/c.tl", "this is not teal\n"))
  local names = verdicts.tree_names(root, {})
  assert(table.concat(names, ",") == "a.tl,b.tl,sub/init.tl", table.concat(names, ","))
  -- `a.tl` requires the other two, which are checked first.
  local order = table.concat(verdicts.tree_order(root, names), ",")
  assert(order == "b.tl,sub/init.tl,a.tl", order)
  local function run(): string
    return verdicts.render(verdicts.tree_lines(checker(), root, names))
  end
  local text = run()
  assert(text:find("b.tl\ttype.mismatch\t4\t19\t", 1, true) ~= nil, text)
  -- `a.tl` requires `b.tl`, whose finding is `b.tl`'s alone.
  assert(text:find("a.tl", 1, true) == nil, text)
  local _, first = text:find("b.tl\ttype.mismatch", 1, true)
  assert(first ~= nil and text:find("b.tl\ttype.mismatch", first, true) == nil, text)
  assert(run() == text)
  -- An environment apiece gives the same lines as the one shared.
  assert(verdicts.render(verdicts.tree_lines(checker(), root, names, true)) == text)
end

local function test_a_declaration_file_is_served_and_not_checked(tmp: string)
  local root = tmp .. "/decls"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/d.d.tl", "local record D\n  n: integer\nend\nreturn D\n"))
  assert(Fs.write(root .. "/use.tl", 'local D = require("d")\nlocal x: D = { n = 1 }\nreturn x\n'))
  local names = verdicts.tree_names(root, {})
  assert(table.concat(names, ",") == "use.tl", table.concat(names, ","))
  assert(verdicts.render(verdicts.tree_lines(checker(), root, names)) == "")
end

local function test_a_raise_of_the_checker_is_a_line()
  local stub: mut {string:any} = {}
  for key, value in pairs(checker() as {string:any}) do
    stub[key] = value
  end
  stub["gen"] = function(): string
    error("boom at table: 0x5581deadbeef", 0)
  end
  local text = verdicts.render(verdicts.program_lines(stub as compiler, "r.tl", "return 1\n"))
  assert(text == "r.tl\traised\t0\t0\tboom at table: 0xADDR\n", text)
end

local function test_the_environment_is_the_builds_less_its_database()
  local compiled = checker()
  local ours = verdicts.environment(compiled)
  local theirs = assert(teal.environment_for(compiled, assert(Sqlite.memory()), "/nonexistent"))
  for _, field in ipairs({ "feat_lax", "gen_compat", "gen_target", "runtime_checks" }) do
    assert(tostring((ours.defaults as {string:any})[field]) == tostring((theirs.defaults as {string:any})[field]),
      field .. " differs")
  end
  local ours_names: mut {string} = {}
  local their_names: mut {string} = {}
  for name in pairs(ours.globals) do ours_names[#ours_names + 1] = name end
  for name in pairs(theirs.globals) do their_names[#their_names + 1] = name end
  table.sort(ours_names)
  table.sort(their_names)
  assert(table.concat(ours_names, " ") == table.concat(their_names, " "))
end

--- The seed [`Fuzz.run`] draws from: `FUZZ_SEED`, else 1.
local function fuzz_seed(): integer
  return assert(math.tointeger(tonumber(Env.get_or("FUZZ_SEED", "1"))))
end

--- The inputs [`Fuzz.run`] hands a check, for `FUZZ_SEED`.
local function run_inputs(gen: function(Fuzz.Source): string, iters: integer): {string}
  local seen: {string} = {}
  Fuzz.run({
    name = "checker verdicts seeding",
    gen = gen,
    check = function(input: string): boolean, string
      seen[#seen + 1] = input
      return true, ""
    end,
    iters = iters,
  })
  return seen
end

local function test_the_programs_dumped_are_the_ones_the_fuzz_properties_draw()
  for _, kind in ipairs({ "total", "sound" }) do
    local gen = kind == "total" and programs.any or programs.well_formed
    local drawn = programs.drawn(kind, fuzz_seed(), 5)
    local seen = run_inputs(gen, 5)
    assert(#drawn == 5 and #seen == 5)
    for i = 1, 5 do
      assert(drawn[i] == seen[i], kind .. " program " .. i .. " differs from the fuzz run's")
    end
  end
  assert(programs.drawn("total", 2, 1)[1] ~= programs.drawn("total", 1, 1)[1])
  assert(programs.drawn("sound", 5, 3)[3] == programs.drawn("sound", 5, 4)[3])
end

local function test_dump_writes_the_drawn_programs_to_files(tmp: string)
  assert(verdicts.main({ "dump", tmp .. "/out", "3", "2" }) == 0)
  for _, kind in ipairs({ "total", "sound" }) do
    for n, text in ipairs(programs.drawn(kind, 3, 2)) do
      assert(Fs.read(("%s/out/%s-3-%04d.tl"):format(tmp, kind, n)) == text)
    end
  end
end
