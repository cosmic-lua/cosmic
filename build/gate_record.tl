--- Writes the verdict table of the switch's gate ([`lang.check_verdicts`]): [`testdata/gate/verdicts.json`], one row for
--- each program the fork's tests pin ([`build/teal_test.tl`]) and each input of the checker corpora. Run it from the
--- tree's root as `bin/cosmic build/gate_record.tl`, which gives each row the new checker's verdict and keeps what the
--- fork said, or with `--fork` to ask the fork again, which adds the programs the tests gained and changes what the
--- fork says of those it has.
---
--- The fork's side is frozen data: the fork goes at the switch, and the table is what is left of it. So the fork is
--- asked only on request, by running every test of [`build/teal_test.tl`] against a compiler that records what it is
--- given (the test file is read as text, and its helper that loads the compiler is replaced by that one), and every
--- corpus input as [`build/checker_fuzz_test.tl`] checks it.
---
-- TODO: move this script to lang/ and drop [`ask_fork`] and the fork's part in the table, once the fork is deleted at
-- the switch: after that only the new checker's side is written, which [`lang.check_verdicts`]'s test holds the file to.
local Fs = require("cosmic.fs")
local plural = require("build.plural")
local Shape = require("cosmic.shape")
local Verdicts = require("lang.check_verdicts")
local teal = require("build.teal")

--- What the fork said of one program, as the probe records it.
local record Forked
  source: string
  --- The tests that gave it the compiler.
  origins: {string}
  syntax: integer
  types: integer
  codes: {string}
end

local FORKED <const>: Shape.Typed<Forked> = Shape.record_of("Forked")

--- The probe, in Lua so that it handles the compiler and the compiled tests as the untyped values they are. It runs
--- every test of the test file in `names` against a compiler that records each program given to `gen`, and answers
--- the programs, in the order they were first given, and the tests that raised.
local PROBE <const> = [==[
local real, lua, names = ...
local rows, by_source = {}, {}
local current = ""
local proxy = setmetatable({}, { __index = real })
function proxy.gen(source, env, options, dialect)
  local ok, code, result = pcall(real.gen, source, env, options, dialect)
  local row = by_source[source]
  if row == nil then
    row = { source = source, origins = {}, syntax = 0, types = 0, codes = {} }
    by_source[source] = row
    rows[#rows + 1] = row
    if ok and result ~= nil then
      row.syntax, row.types = #result.syntax_errors, #result.type_errors
      local seen = {}
      for _, group in ipairs({ result.syntax_errors, result.type_errors }) do
        for _, e in ipairs(group) do
          local c = tostring(e.code)
          if not seen[c] then
            seen[c] = true
            row.codes[#row.codes + 1] = c
          end
        end
      end
    end
  end
  local last = row.origins[#row.origins]
  if last ~= current then
    row.origins[#row.origins + 1] = current
  end
  if not ok then
    error(code, 0)
  end
  return code, result
end
local tests = {}
local env = setmetatable({ PROBE = { load = function() return proxy end, tests = tests } }, { __index = _G })
assert(load(lua, "=teal_test", "t", env))()
local raised = {}
for _, name in ipairs(names) do
  current = name
  local ok, err = pcall(tests[name])
  if not ok then
    raised[#raised + 1] = name .. ": " .. tostring(err)
  end
end
return rows, table.concat(raised, "; ")
]==]

local TEST_FILE <const> = "build/teal_test.tl"

--- The tests of the fork's parser timing: their programs are thousands of lines of one line repeated, to count what a
--- look-ahead reads, and say nothing of a rule, so the table leaves them out.
local TIMING <const>: {string: boolean} = {
  test_an_enum_named_variable_costs_what_it_reads = true,
  test_a_record_named_variable_costs_what_it_reads = true,
  test_a_record_named_variable_in_a_function_costs_what_it_reads = true,
  test_nested_record_named_variables_cost_what_they_read = true,
}

--- The test file made to give its compiler to the probe: the tests are fields of `PROBE.tests`, the compiler is
--- `PROBE.load()`, and the lazy-capsule tests (which the probe has no use for, and whose locals the chunk's limit
--- of 200 needs) and the policy are gone. Answers the text and the names of the tests, in file order.
local function probed(text: string): string, {string}
  text = text:gsub("assert%(teal%.load%(true%)%)", "assert(PROBE.load())")
  text = text:gsub("Test%.policy%b{}", "do end")
  text = text:gsub("\nlocal function test_lazy_[%w_]+%(%).-\nend\n", "\n")
  local names: {string} = {}
  for name in text:gmatch("\nlocal function (test_[%w_]+)%(") do
    names[#names + 1] = name
  end
  text = text:gsub("\nlocal function (test_[%w_]+)%(", "\nfunction PROBE.tests.%1(")
  return text, names
end

local function listed(dir: string): {string}
  local names = assert(Fs.list(dir))
  table.sort(names)
  local out: {string} = {}
  for _, name in ipairs(names) do
    if name:sub(-6) == ".input" then
      out[#out + 1] = dir .. "/" .. name
    end
  end
  return out
end

local CORPORA <const>: {string} = { "testdata/fuzz/checker-total", "testdata/fuzz/checker-sound" }

--- What the fork says of every program of the tests and the corpora, in that order.
local function ask_fork(): {Forked}
  local real = assert(teal.load(true))
  local text = assert(Fs.read(TEST_FILE))
  local source, names = probed(text)
  local lua = real.gen(source, nil, nil, "tl")
  assert(lua ~= nil, "the test file does not compile")
  local run = (assert(load(PROBE, "=probe", "t")))
  local found, raised = run(real, lua, names)
  local rows, trouble: {Forked} | nil, string = Shape.into(found, Shape.list(FORKED.spec))
  assert(rows ~= nil, trouble)
  -- The tests that read a file of the checkout or the loaded packages fail here; they are the ones that fail without
  -- the probe, and name no program the others lack.
  print("tests that raised: " .. tostring(raised))
  for _, dir in ipairs(CORPORA) do
    for _, path in ipairs(listed(dir)) do
      local input = assert(Fs.read(path))
      local env = assert(real.new_env({ defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" } }))
      local _, result = real.gen(input, env, nil, "tl")
      local row: Forked = { source = input, origins = { path }, syntax = 0, types = 0, codes = {} }
      row.syntax, row.types = #result.syntax_errors, #result.type_errors
      local seen: {string: boolean} = {}
      for _, group in ipairs({ result.syntax_errors, result.type_errors }) do
        for _, e in ipairs(group) do
          local code = tostring(e.code)
          if seen[code] ~= true then
            seen[code] = true
            row.codes[#row.codes + 1] = code
          end
        end
      end
      rows[#rows + 1] = row
    end
  end
  return rows
end

local TABLE <const> = "testdata/gate/verdicts.json"

--- Whether every test that gave `forked` its compiler is one of the timing tests.
local function timing_only(forked: Forked): boolean
  for _, origin in ipairs(forked.origins) do
    if TIMING[origin] ~= true then
      return false
    end
  end
  return true
end

--- The programs of `forked` once each, the places that gave a program the compiler (a test and a corpus input may be the
--- same program) joined, and the timing tests' left out.
local function distinct(forked: {Forked}): {Forked}
  local merged: {Forked} = {}
  local index: {string: integer} = {}
  for _, each in ipairs(forked) do
    if not timing_only(each) then
      local id = Verdicts.id(each.source)
      local at_id = index[id]
      if at_id == nil then
        merged[#merged + 1] = each
        index[id] = #merged
      else
        local first = merged[at_id]
        assert(first ~= nil)
        local both: {string} = {}
        for _, origin in ipairs(first.origins) do
          both[#both + 1] = origin
        end
        for _, origin in ipairs(each.origins) do
          both[#both + 1] = origin
        end
        merged[at_id] = { source = first.source, origins = both, syntax = first.syntax, types = first.types, codes = first.codes }
      end
    end
  end
  return merged
end

--- `rows` with what the fork said of the programs in `forked`: a row for each, kept in place where the table has it and
--- added at the end where it has not, and the new checker's side of a row kept.
local function with_fork(rows: {Verdicts.Row}, forked: {Forked}): {Verdicts.Row}
  local out: {Verdicts.Row} = {}
  local at: {string: integer} = {}
  for i, row in ipairs(rows) do
    out[i] = row
    at[row.id] = i
  end
  for _, each in ipairs(distinct(forked)) do
    local id = Verdicts.id(each.source)
    local origins: {string} = {}
    for _, origin in ipairs(each.origins) do
      origins[#origins + 1] = origin:find("^test_") and (TEST_FILE .. " " .. origin) or origin
    end
    local place = at[id]
    local old: Verdicts.Row | nil = nil
    if place ~= nil then
      old = out[place]
    end
    local row: Verdicts.Row = {
      id = id, origins = table.concat(origins, "; "), source = each.source,
      fork = each.syntax + each.types > 0 and "refused" or "accepted",
      fork_stage = each.syntax > 0 and "syntax" or each.types > 0 and "type" or "",
      fork_codes = table.concat(each.codes, " "),
      new = "", new_stage = "", new_codes = "",
    }
    if old ~= nil then
      row = Verdicts.with_new(row, { refused = old.new == "refused", stage = old.new_stage, silent = {},
        codes = { old.new_codes } })
    end
    if place ~= nil then
      out[place] = row
    else
      out[#out + 1] = row
      at[id] = #out
    end
  end
  return out
end

local function main(fork: boolean)
  local rows: {Verdicts.Row} = {}
  local there, _ = Fs.exists(TABLE)
  if there == true then
    local read, trouble = Verdicts.read_rows((assert(Fs.read(TABLE))))
    assert(read ~= nil, TABLE .. ": " .. tostring(trouble))
    rows = read
  end
  if fork or there ~= true then
    rows = with_fork(rows, ask_fork())
  end
  local tl = assert(Fs.read("checker/tl.tl"))
  local prelude = tl:match("%[=====%[\n(.-)%]=====%]")
  assert(prelude ~= nil, "checker/tl.tl has no prelude")
  local judge = Verdicts.judge(prelude, (assert(Fs.read("checker/stdlib.d.tl"))))
  local judged: {Verdicts.Row} = {}
  local counts: {string: integer} = {}
  for i, row in ipairs(rows) do
    local made = Verdicts.with_new(row, judge(row.source))
    judged[i] = made
    local key = "fork " .. made.fork .. ", new " .. made.new
    counts[key] = (counts[key] or 0) + 1
  end
  assert(Fs.mkdirs("testdata/gate"))
  assert(Fs.write(TABLE, Verdicts.write_rows(judged)))
  local keys: {string} = {}
  for key in pairs(counts) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  print(plural.count(#judged, "program") .. " written to " .. TABLE)
  for _, key in ipairs(keys) do
    print("  " .. key .. ": " .. tostring(counts[key]))
  end
end

main(arg[1] == "--fork")
