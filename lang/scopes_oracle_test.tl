--- The scope builder ([`lang.scopes`]) against the fork's checker
--- ([`build.checker_verdicts`]) as the oracle. The fork checks the same
--- programs with its own scoping, so where it finds no syntax error and the new
--- parser finds none that damages the tree, the two agree on the findings that
--- scoping decides: which declarations shadow a visible name (by line and
--- name), which assignments a function makes to a local outside it (`captured_assigned`),
--- and which names are declared nowhere (`unknown_variable`), by place and
--- name. The programs are the checker's own corpora, the programs its fuzz
--- generator draws and the programs of [`lang.scopes_programs`].
---
--- The two differ, and the cases below leave the difference out:
---
--- * After an unknown name the fork gives the variable declared with it a type
---   it then reports as unknown at every use, and it does not check the
---   declarations of a `for` whose header failed. Findings about a name the
---   fork reports unknown are left out of both sides.
--- * The fork's type errors (a type written after a name in `local x: T, y`) are
---   about the grammar, not scoping, and are not compared.
---
--- The fork resolves a type name by the scopes it is used in, not the ones it is
--- written in, so a record field of the type `Orchestration.Group` finds the
--- local `Orchestration` of a function that uses the record (ci/cosmic_ci/orchestration_test.tl
--- has two). The new builder reports each as `unknown_type`; they are pinned in
--- build/tree_checks.tl.

-- TODO: compare the fork's `unknown_type` with the builder's too, once build/checker_programs.tl and
-- the corpora write a declaration of two variables the way the new grammar does (`local a, b: T, U`):
-- they write `local x: T, y = ...`, which the new parser reads as the type list `T, y`.
local Fs = require("cosmic.fs")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Programs = require("lang.scopes_programs")
local Rand = require("cosmic.rand")
local Scopes = require("lang.scopes")
local Test = require("cosmic.test")
local checker_programs = require("build.checker_programs")
local teal = require("build.teal")
local verdicts = require("build.checker_verdicts")

Test.policy{
  grants = {
    { path = "testdata/fuzz/checker-total/", letters = "r" },
    { path = "testdata/fuzz/checker-sound/", letters = "r" },
    { path = "checker/stdlib.d.tl", letters = "r" },
    { path = "checker/tl.tl", letters = "r" },
  },
}

local built = assert(teal.load(true))

--- The kinds of parse error that leave a tree the builder cannot be held to.
local DAMAGING <const>: {string: boolean} = {
  unclosed = true, expected_token = true, expected_name = true, expected_expression = true, expected_type = true,
  unexpected_token = true, not_a_statement = true, bad_target = true, statement_after_return = true, too_deep = true,
  stray_byte = true, unterminated_string = true, unterminated_long_string = true, unterminated_long_comment = true,
  malformed_number = true, bad_escape = true,
}

--- The globals of the fork's environment, which a program may use.
local function fork_globals(): {string: Scopes.Global}
  local out: {string: Scopes.Global} = {}
  for name in pairs(verdicts.environment(built).globals) do
    -- The checker keeps names of its own in the table of globals: `@is_va` and `...`.
    if name:match("^[%a_][%w_]*$") then
      out[name] = { space = "both", const = false }
    end
  end
  out["_G"] = { space = "value", const = false }
  for _, name in ipairs({ "any", "thread", "userdata" }) do
    out[name] = { space = "type", const = false }
  end
  return out
end

local DECLARED <const> = fork_globals()

--- What the fork finds in `text`, as `kind y name` lines, or why it cannot be compared.
local function fork_findings(text: string): {string}, string
  local out: {string} = {}
  for _, line in ipairs(verdicts.program_lines(built, "p.tl", text)) do
    if line.code:match("^syntax") or line.code == "raised" then
      return out, "the fork finds no tree"
    elseif line.code == "warning.shadows" then
      out[#out + 1] = "shadows " .. line.y .. " " .. tostring(line.message:match("declaration of '(.-)'"))
    elseif line.code == "type.captured_assigned" then
      out[#out + 1] = "captured " .. line.y .. ":" .. line.x .. " " .. tostring(line.message:match("^'(.-)'"))
    elseif line.code == "type.unknown_variable" or line.code == "warning.unknown_variable" then
      out[#out + 1] = "unknown " .. line.y .. ":" .. line.x .. " " .. tostring(line.message:match("unknown variable: (.*)$"))
    end
  end
  table.sort(out)
  return out, ""
end

--- What the builder finds in `text`, in the same lines, or why it cannot be compared.
local function builder_findings(text: string): {string}, string
  local parsed = Parser.parse(Lexer.lex(text, "p.tl"), "p.tl", "tl")
  for _, e in ipairs(parsed.errors) do
    if DAMAGING[e.code] then
      return {}, "the tree is damaged by " .. e.code
    end
  end
  local out: {string} = {}
  for _, e in ipairs(Scopes.build(parsed.chunk, "p.tl", DECLARED).errors) do
    local name = e.msg:match("`(.-)`")
    if e.code == "shadows" then
      out[#out + 1] = "shadows " .. e.y .. " " .. tostring(name)
    elseif e.code == "captured_assigned" then
      out[#out + 1] = "captured " .. e.y .. ":" .. e.x .. " " .. tostring(name)
    elseif e.code == "unknown_variable" then
      out[#out + 1] = "unknown " .. e.y .. ":" .. e.x .. " " .. tostring(name)
    end
  end
  table.sort(out)
  return out, ""
end

local function name_of(finding: string): string
  return finding:match("%S+$") or ""
end

--- The first way the fork and the builder differ on `text`, "" where they agree, and
--- whether they could be compared.
local function difference(text: string): string, boolean
  local theirs, why = fork_findings(text)
  if why ~= "" then
    return "", false
  end
  local mine, why_mine = builder_findings(text)
  if why_mine ~= "" then
    return "", false
  end
  local unreliable: {string: boolean} = {}
  for _, finding in ipairs(theirs) do
    if finding:match("^unknown") then
      unreliable[name_of(finding)] = true
    end
  end
  local function counted(list: {string}): {string: integer}
    local out: {string: integer} = {}
    for _, finding in ipairs(list) do
      if not unreliable[name_of(finding)] then
        out[finding] = (out[finding] or 0) + 1
      end
    end
    return out
  end
  local a, b = counted(theirs), counted(mine)
  local lines: {string} = {}
  for finding, n in pairs(a) do
    if b[finding] ~= n then
      lines[#lines + 1] = "fork " .. finding .. " x" .. n .. ", builder x" .. (b[finding] or 0)
    end
  end
  for finding, n in pairs(b) do
    if a[finding] == nil then
      lines[#lines + 1] = "builder " .. finding .. " x" .. n .. ", fork x0"
    end
  end
  table.sort(lines)
  return table.concat(lines, "; "), true
end

--- Asserts the fork and the builder agree on every program of `texts`, which were drawn
--- as `label`, and that enough of them could be compared.
local function agree(label: string, texts: {string}, least: integer)
  local compared = 0
  for i, text in ipairs(texts) do
    local differs, comparable = difference(text)
    assert(differs == "", label .. " " .. i .. ": " .. differs .. "\n" .. text)
    if comparable then
      compared = compared + 1
    end
  end
  assert(compared >= least, label .. ": only " .. compared .. " of " .. #texts .. " programs could be compared")
end

local function corpus(dir: string): {string}
  local out: {string} = {}
  local files = assert(Fs.walk(dir))
  table.sort(files)
  for _, file in ipairs(files) do
    out[#out + 1] = assert(Fs.read(dir .. "/" .. file))
  end
  return out
end

local function test_the_globals_of_the_fork_are_the_ones_the_declaration_files_declare()
  local function declared_by(path: string, text: string): {string: Scopes.Global}
    return Scopes.declared(Parser.parse(Lexer.lex(text, path), path, "decl").chunk)
  end
  local tl = assert(Fs.read("checker/tl.tl"))
  local prelude = assert(tl:match("%[=====%[\n(.-)%]=====%]"))
  local mine = declared_by("prelude.d.tl", prelude)
  for name, g in pairs(declared_by("stdlib.d.tl", (assert(Fs.read("checker/stdlib.d.tl"))))) do
    mine[name] = g
  end
  -- The parser reads `global interface userdata is userdata` as the declaration of `interface`.
  mine["interface"] = nil
  mine["userdata"] = { space = "type", const = false }
  for _, name in ipairs(teal.withheld) do
    mine[name] = nil
  end
  mine["_G"] = DECLARED["_G"]
  local missing: {string} = {}
  for name in pairs(DECLARED) do
    if mine[name] == nil then
      missing[#missing + 1] = name
    end
  end
  for name in pairs(mine) do
    if DECLARED[name] == nil then
      missing[#missing + 1] = "extra " .. name
    end
  end
  table.sort(missing)
  assert(#missing == 0, "the fork and the declaration files differ on: " .. table.concat(missing, " "))
end

local function test_the_builder_agrees_with_the_fork_on_the_checkers_corpora()
  agree("checker-total", corpus("testdata/fuzz/checker-total"), 5)
  agree("checker-sound", corpus("testdata/fuzz/checker-sound"), 20)
end

local function test_the_builder_agrees_with_the_fork_on_the_programs_the_checkers_fuzz_draws()
  agree("sound", checker_programs.drawn("sound", 7, 40), 20)
  agree("total", checker_programs.drawn("total", 7, 40), 10)
end

local function test_the_builder_agrees_with_the_fork_on_programs_that_bind_names_in_every_way()
  local rng = Rand.new(11)
  local texts: {string} = {}
  for i = 1, 150 do
    texts[i] = Programs.generate(function(min: integer, max: integer): integer
      return rng:int(min, max)
    end, { unknown = true, loop_writes = false })
  end
  agree("generated", texts, 100)
end
