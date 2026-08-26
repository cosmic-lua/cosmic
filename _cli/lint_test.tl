#!/usr/bin/env cosmic

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local lint = require("_cli.lint")
local style = require("_tool.lint")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_check_file_length_under()
  local diags = style.check_file_length("test.tl", 100, 500)
  assert(#diags == 0, "expected no diagnostic for file under limit")
end
test_check_file_length_under()

local function test_check_file_length_at_limit()
  local diags = style.check_file_length("test.tl", 500, 500)
  assert(#diags == 0, "expected no diagnostic for file at limit")
end
test_check_file_length_at_limit()

local function test_check_file_length_over()
  local diags = style.check_file_length("test.tl", 501, 500)
  assert(#diags == 1, "expected diagnostic for file over limit")
  assert(diags[1].rule == "file-length", "expected file-length rule")
  assert(diags[1].file == "test.tl", "expected file name")
  assert(diags[1].message:match("501"), "expected line count in message")
  assert(diags[1].message:match("500"), "expected limit in message")
end
test_check_file_length_over()

local function test_lint_file_under_default()
  local path = fs.join(tmpdir, "short.tl")
  local lines: {string} = {}
  for i = 1, 100 do
    table.insert(lines, "-- line " .. tostring(i))
  end
  assert(fs.write(path, table.concat(lines, "\n") .. "\n"))

  local diagnostics = check.must(lint.lint_file(path))
  assert(#diagnostics == 0, "expected no diagnostics for short file, got: " .. tostring(#diagnostics))
end
test_lint_file_under_default()

local function test_lint_file_over_default()
  local path = fs.join(tmpdir, "long.tl")
  local lines: {string} = {}
  for i = 1, 501 do
    table.insert(lines, "-- line " .. tostring(i))
  end
  assert(fs.write(path, table.concat(lines, "\n") .. "\n"))

  local diagnostics = check.must(lint.lint_file(path))
  assert(#diagnostics == 1, "expected 1 diagnostic for long file, got: " .. tostring(#diagnostics))
  assert(diagnostics[1].rule == "file-length", "expected file-length rule")
end
test_lint_file_over_default()

-- A binary (or any non-Teal/Lua file) over the length limit gets the
-- .cosmicignore hint: "split this file" is not actionable advice for an
-- ELF binary the walk swept in.
local function test_lint_file_hints_cosmicignore_for_binary()
  local path = fs.join(tmpdir, "toolbinary")
  local chunk = "\0\1\2ELF junk line\n"
  assert(fs.write(path, chunk:rep(600)))

  local diagnostics = check.must(lint.lint_file(path))
  assert(#diagnostics == 1, "expected 1 diagnostic, got: " .. tostring(#diagnostics))
  assert(diagnostics[1].rule == "file-length", "expected file-length rule")
  assert(diagnostics[1].message:find("a binary file", 1, true),
    "expected the binary nature named, got: " .. diagnostics[1].message)
  assert(diagnostics[1].message:find(".cosmicignore", 1, true),
    "expected a .cosmicignore hint, got: " .. diagnostics[1].message)
end
test_lint_file_hints_cosmicignore_for_binary()

local function test_lint_file_hints_cosmicignore_for_non_source_text()
  local path = fs.join(tmpdir, "data.csv")
  local lines: {string} = {}
  for i = 1, 501 do
    table.insert(lines, "row," .. tostring(i))
  end
  assert(fs.write(path, table.concat(lines, "\n") .. "\n"))

  local diagnostics = check.must(lint.lint_file(path))
  assert(#diagnostics == 1, "expected 1 diagnostic, got: " .. tostring(#diagnostics))
  assert(diagnostics[1].message:find("not Teal/Lua source", 1, true),
    "expected the nature named, got: " .. diagnostics[1].message)
  assert(diagnostics[1].message:find(".cosmicignore", 1, true),
    "expected a .cosmicignore hint, got: " .. diagnostics[1].message)
end
test_lint_file_hints_cosmicignore_for_non_source_text()

-- Teal/Lua source over the limit keeps the plain message: the fix for
-- source really is to split it, and a .cosmicignore hint there would
-- teach people to ignore their own code.
local function test_lint_file_no_ignore_hint_for_source()
  local path = fs.join(tmpdir, "long2.tl")
  local lines: {string} = {}
  for i = 1, 501 do
    table.insert(lines, "-- line " .. tostring(i))
  end
  assert(fs.write(path, table.concat(lines, "\n") .. "\n"))

  local diagnostics = check.must(lint.lint_file(path))
  assert(#diagnostics == 1, "expected 1 diagnostic, got: " .. tostring(#diagnostics))
  assert(not diagnostics[1].message:find(".cosmicignore", 1, true),
    "source files should not get the ignore hint: " .. diagnostics[1].message)
end
test_lint_file_no_ignore_hint_for_source()

local function test_lint_file_skips_dtl()
  -- .d.tl files are type declarations for C bindings and are exempt from length checks
  local path = fs.join(tmpdir, "types.d.tl")
  local lines: {string} = {}
  for i = 1, 600 do
    table.insert(lines, "-- line " .. tostring(i))
  end
  assert(fs.write(path, table.concat(lines, "\n") .. "\n"))

  local diagnostics = check.must(lint.lint_file(path))
  assert(#diagnostics == 0, "expected no diagnostics for .d.tl file, got: " .. tostring(#diagnostics))
end
test_lint_file_skips_dtl()

local function test_default_file_lines()
  assert(style.DEFAULT_FILE_LINES == 500, "expected default to be 500")
end
test_default_file_lines()

-- cosmo-require: the forbidden pattern is spelled via concatenation below so
-- this file's own fixtures don't trip the rule (it is allowlisted anyway).
local REQ_COSMO = 'require("cosmo' .. '")'
local REQ_COSMO_UNIX = 'require("cosmo' .. '.unix")'

local function test_cosmo_require_flags_test_file()
  local lines = {"local unix = " .. REQ_COSMO_UNIX, "print(unix)"}
  local diags = lint.check_cosmo_require("cosmic/foo_test.tl", lines)
  assert(#diags == 1, "expected 1 diagnostic, got: " .. tostring(#diags))
  assert(diags[1].rule == "cosmo-require", "expected cosmo-require rule")
  assert(diags[1].line == 1, "expected line 1, got: " .. tostring(diags[1].line))
end
test_cosmo_require_flags_test_file()

local function test_cosmo_require_flags_bare_cosmo_in_example()
  local lines = {"local cosmo = " .. REQ_COSMO}
  local diags = lint.check_cosmo_require("cosmic/foo_example.tl", lines)
  assert(#diags == 1, "expected 1 diagnostic, got: " .. tostring(#diags))
end
test_cosmo_require_flags_bare_cosmo_in_example()

local function test_cosmo_require_ignores_non_test_files()
  local lines = {"local unix = " .. REQ_COSMO_UNIX}
  local diags = lint.check_cosmo_require("cosmic/foo.tl", lines)
  assert(#diags == 0, "library internals may require cosmo directly")
end
test_cosmo_require_ignores_non_test_files()

local function test_cosmo_require_ignores_cosmic_requires()
  local lines = {
    'local fs = require("cosmic.fs")',
    'local cosmos = require("cosmos")',
  }
  local diags = lint.check_cosmo_require("cosmic/foo_test.tl", lines)
  assert(#diags == 0, "cosmic.* and cosmos are not cosmo requires")
end
test_cosmo_require_ignores_cosmic_requires()

local function test_cosmo_require_honors_allowlist()
  local lines = {"local unix = " .. REQ_COSMO_UNIX}
  local diags = lint.check_cosmo_require("cosmic/child/init_test.tl", lines)
  assert(#diags == 0, "allowlisted files must not be flagged")
end
test_cosmo_require_honors_allowlist()

-- One implementation, split by what each half may require: the pure
-- checks stay in `_tool.lint` (inside the strip floor, where there is
-- no Teal compiler to require) and the lexer-based ones are here. The
-- assertion that matters is that `--check lint` and `--make lint` run
-- THIS one composition.
local function test_the_pure_checks_come_from_style()
  assert(style.check_file_length,
    "the pure checks are _tool.lint's")
  assert(lint.lint_file and lint.check_call_after_define
    and lint.check_cast_justification and lint.check_cosmo_require,
    "the composition and the lexer checks are this module's")
end
test_the_pure_checks_come_from_style()

-- The convention is a TEST file one, and it applies to the functions
-- that RUN: `test_*` and `Example_*`. A helper is defined once and
-- called from several tests, so flagging helpers would make the rule
-- unsatisfiable -- 121 of this repo's test files define at least one.
local function lines_of(src: string): {string}
  local out: {string} = {}
  for line in (src .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  return out
end

local function test_call_after_define_names_the_runnable_ones()
  local src = "local function helper()\n  return 1\nend\n\n" ..
  "local function test_a()\n  return helper()\nend\ntest_a()\n"
  local diags = lint.check_call_after_define("x_test.tl", src, lines_of(src))
  assert(#diags == 0,
    "a called test and an uncalled helper are both fine, got " .. #diags)

  local bad = "local function test_a()\n  return 1\nend\n" ..
  "local function test_b()\n  return 2\nend\ntest_a()\ntest_b()\n"
  diags = lint.check_call_after_define("x_test.tl", bad, lines_of(bad))
  assert(#diags == 2, "both are called too late, got " .. #diags)
  assert(diags[1].rule == "call-after-define", "got: " .. diags[1].rule)
end
test_call_after_define_names_the_runnable_ones()

-- D29 makes the rule two-moded: a file whose tests never self-call is
-- runner mode (the toolchain runs what discovery finds) and lints
-- clean; a MIX is the shape that must never pass, and the diagnostic
-- names exactly the uncalled half.
local function test_a_runner_mode_file_lints_clean()
  local src = "local function test_a()\n  return 1\nend\n\n" ..
  "local function test_b()\n  return 2\nend\n"
  local diags = lint.check_call_after_define("x_test.tl", src, lines_of(src))
  assert(#diags == 0, "no self-calls at all is runner mode, got " .. #diags
    .. (diags[1] and (": " .. diags[1].message) or ""))
end
test_a_runner_mode_file_lints_clean()

local function test_a_mixed_file_names_the_uncalled_test()
  local src = "local function test_a()\n  return 1\nend\ntest_a()\n\n" ..
  "local function test_b()\n  return 2\nend\n"
  local diags = lint.check_call_after_define("x_test.tl", src, lines_of(src))
  assert(#diags == 1, "only the uncalled half is flagged, got " .. #diags)
  assert(diags[1].rule == "call-after-define", "got: " .. diags[1].rule)
  assert(diags[1].message:find("test_b", 1, true),
    "the diagnostic names the test that would silently not run")
end
test_a_mixed_file_names_the_uncalled_test()

-- And it is a TOKEN scan, not a line scan: counting `function`/`end`
-- in source TEXT would let a fixture string holding either move the
-- depth, reporting a function whose call is on the very next line as
-- late -- a false positive a token scan does not have.
local function test_call_after_define_ignores_keywords_in_strings()
  local src = "local function test_a()\n" ..
  "  local fixture = \"local function f() end\"\n" ..
  "  return fixture\nend\ntest_a()\n"
  local diags = lint.check_call_after_define("x_test.tl", src, lines_of(src))
  assert(#diags == 0, "a keyword inside a string is not a block, got " ..
    #diags .. (diags[1] and (": " .. diags[1].message) or ""))
end
test_call_after_define_ignores_keywords_in_strings()

-- Blocks inside the body still close correctly -- the case a
-- depth-tracking implementation needs a corpus of examples for, and
-- the token scan answers uniformly.
local function test_call_after_define_handles_nested_blocks()
  local src = "local function test_a()\n  for i = 1, 2 do\n" ..
  "    if i > 1 then\n      local x = i\n    end\n  end\n" ..
  "  while false do\n    break\n  end\n  return 1\nend\ntest_a()\n"
  local diags = lint.check_call_after_define("x_test.tl", src, lines_of(src))
  assert(#diags == 0, "nested blocks must not move the closer, got " ..
    #diags .. (diags[1] and (": " .. diags[1].message) or ""))
end
test_call_after_define_handles_nested_blocks()

-- The rule does not apply outside test and example files, where "call
-- this function immediately after defining it" is not a convention
-- anyone follows or should.
local function test_call_after_define_is_scoped_to_tests()
  local src = "local function test_a()\n  return 1\nend\nreturn test_a\n"
  assert(#lint.check_call_after_define("mod.tl", src, lines_of(src)) == 0,
    "an ordinary module is not held to the test convention")
end
test_call_after_define_is_scoped_to_tests()

-- `find` with a variable needle is a pattern, and the bug it causes is
-- silent: a path with a `-` in it stops matching itself. The rule asks
-- the author to say which they meant, and exempts literals, which read
-- as patterns already.
local function test_find_needle_wants_the_intent_stated()
  local bare = 'local x = s:find(needle)\n'
  assert(#lint.check_find_needle("m.tl", bare) == 1, "a bare needle is flagged")

  for _, guarded in ipairs({
      'local x = s:find(needle, 1, true)\n',
      'local x = s:find(needle, 1, false)\n',
      'local x = s:find("lit%d+")\n',
      'local x = s:find("a" .. "b")\n',
      'local x = string.find(s, "literal")\n',
    }) do
    assert(#lint.check_find_needle("m.tl", guarded) == 0,
      "should pass: " .. guarded)
  end

  -- string.find passes the subject too, so its needle is the SECOND
  -- argument; counting from the first flags every literal call.
  assert(#lint.check_find_needle("m.tl", 'local x = string.find(s, n)\n') == 1,
    "the dot form is checked at its own needle position")

  -- Some other table's `find` is a different function entirely.
  assert(#lint.check_find_needle("m.tl", 'local x = list.find(t, v)\n') == 0,
    "only string.find is string.find")
end
test_find_needle_wants_the_intent_stated()

local function test_gsub_replacement_wants_the_intent_stated()

  -- nil-declaration: `local x = nil` with no annotation is the type nil
  -- forever; the rule fires at the declaration, where the fix
  -- is. The trap spelled inside a string fixture must never count.
  local function test_nil_declaration_flags_the_bare_form()
    local diags = lint.check_nil_declaration("m.tl", "local earliest = nil\n")
    assert(#diags == 1, "the bare form is flagged")
    assert(diags[1].rule == "nil-declaration", "rule name")
    assert(diags[1].line == 1, "flagged at the declaration")
    assert(diags[1].message:find("nil FOREVER", 1, true),
      "the message names the trap")

    local multi = lint.check_nil_declaration("m.tl", "local a, b = nil, nil\n")
    assert(#multi == 1, "an all-nil multi declaration is flagged")

    for _, ok in ipairs({
        "local x: integer | nil = nil\n", -- annotated: the honest optional
        "local x = nil_value\n", -- an identifier, not the nil keyword
        "local x = nil and true\n", -- an expression, inferred boolean
        "local a, b = nil, 1\n", -- mixed RHS: the checker's hint covers it
        "local x = 1\n",
        "local function f()\nend\nf()\n",
        'local s = "local x = nil"\n', -- the trap quoted in a string
      }) do
      assert(#lint.check_nil_declaration("m.tl", ok) == 0, "should pass: " .. ok)
    end
  end
  test_nil_declaration_flags_the_bare_form()
  local bare = 'local x = s:gsub("{{name}}", user_name)\n'
  assert(#lint.check_gsub_replacement("m.tl", bare, lines_of(bare)) == 1,
    "a variable replacement is flagged")
  local diag = lint.check_gsub_replacement("m.tl", bare, lines_of(bare))[1]
  assert(diag.rule == "gsub-replacement", "rule name")
  assert(diag.message:find("str.replace", 1, true),
    "the message names the literal-intent fix")

  for _, ok in ipairs({
      'local x = s:gsub(pat, "%1!")\n', -- literal: deliberate splicing
      'local x = s:gsub(pat, "a" .. "b")\n', -- concat of literals
      'local x = s:gsub("%s+", "")\n', -- empty literal
      'local x = s:gsub("%d", function(d: string): string return d end)\n',
      'local x = s:gsub("%a", {a = "b"})\n', -- table form does not interpolate
      'local x = s:gsub(pat)\n', -- no replacement argument at all
      'local x = s:gsub(pat, v) -- gsub: v is %%-escaped upstream\n',
      '-- gsub: v is a deliberate %1 template\nlocal x = s:gsub(pat, v)\n',
      'local x = list.gsub(t, a, b)\n', -- some other gsub entirely
    }) do
    assert(#lint.check_gsub_replacement("m.tl", ok, lines_of(ok)) == 0,
      "should pass: " .. ok)
  end

  -- string.gsub passes the subject too, so its replacement is THIRD.
  local dotted = 'local x = string.gsub(s, pat, v)\n'
  assert(#lint.check_gsub_replacement("m.tl", dotted, lines_of(dotted)) == 1,
    "the dot form is checked at its own replacement position")
  local dotted_lit = 'local x = string.gsub(s, pat, "lit")\n'
  assert(#lint.check_gsub_replacement("m.tl", dotted_lit, lines_of(dotted_lit)) == 0,
    "and a literal there passes")
end
test_gsub_replacement_wants_the_intent_stated()

-- A `check.needs` guard that returns is the failure the rule is named
-- for: the file runs on, exits 0, and the runner grades 0 as a pass, so
-- a test that opted out of running contributes a green tick. Only the
-- exit reaches the runner, which is why the shape is checkable at all.
-- `--check <kind>` refuses an unknown kind by naming the ones it has,
-- refuses a retired one by naming what replaced it, and refuses a
-- missing file by naming the project-wide verb — the three ways a
-- caller gets the grammar wrong.
local function test_check_kinds_are_named_when_wrong()
  local chk = require("_cli.check")
  -- The kind IS the verb, with `types` the one exception, because the
  -- identity would be `--check check`.
  for kind, verb in pairs(chk.KINDS) do
    assert(kind == verb or kind == "types",
      kind .. " should be spelled the same as its verb, got " .. verb)
  end
  assert(chk.KINDS.types == "check", "except types, which runs --make check")
  -- And every retired spelling names its replacement, which must be a
  -- kind that exists — the check that stops this becoming a map to
  -- nowhere the next time something is renamed.
  for old, now in pairs(chk.RETIRED) do
    assert(chk.KINDS[now], old .. " points at " .. now .. ", which is not a kind")
    assert(not chk.KINDS[old], old .. " must not still be a kind")
    assert(chk.run(old, {"x.tl"}, {}) == 1, old .. " must be refused")
  end
  assert(chk.run("bogus", {"x.tl"}, {}) == 1, "an unknown kind fails")
  assert(chk.run("types", {}, {}) == 1, "a missing file fails")
end
test_check_kinds_are_named_when_wrong()

-- The visibility rule: a shard require from outside cosmic/ is
-- flagged; the public parent, files inside cosmic/, and generators
-- are not. The fixture strings are concatenated so this file does not
-- flag itself.
local function test_visibility_flags_shard_requires_outside_cosmic()
  local vis = require("_cli.visibility")
  local shard = 'local t = require("cosmic.' .. 'fs.types")'
  local under = 'local s = require("cosmic.' .. '_seal_coverage")'
  local parent = 'local f = require("cosmic.' .. 'fs")'
  assert(#vis.check_shard_require("_make/x.tl", {shard}) == 1,
    "a shard require from _make/ is flagged")
  assert(#vis.check_shard_require("_make/x.tl", {under}) == 1,
    "an underscore module require from _make/ is flagged")
  assert(#vis.check_shard_require("_make/x.tl", {parent}) == 0,
    "the public parent is exactly what outside callers should use")
  assert(#vis.check_shard_require("cosmic/net/init.tl", {shard}) == 0,
    "a shard exists to be required by its siblings inside cosmic/")
  assert(#vis.check_shard_require("cmd/cosmic/embed_gen.tl", {shard}) == 0,
    "a generator runs under the current binary and keeps its surface")
  local d = vis.check_shard_require("_make/x.tl", {shard})[1]
  assert(d.rule == "visibility", "rule name is visibility")
  assert(d.message:find("cosmic." .. "fs.types", 1, true),
    "the message names the shard")
end
test_visibility_flags_shard_requires_outside_cosmic()

print("all lint tests passed")

-- The diagnostic renderer prints the offending line under each finding
-- (no snippet for file-length: it is about the whole file, and the
-- file may not even be text). Long lines truncate so one bad line
-- cannot flood the terminal.
local function test_render_diagnostics_snippets()
  local path = fs.join(tmpdir, "render_me.tl")
  local long_tail = string.rep("y", 150)
  assert(fs.write(path, "local a: any = {}\n"
      .. "local b = a as {string: any}\n"
      .. "local c = " .. long_tail .. " as string\n"
      .. "print(b, c)\n"))
  local diagnostics = check.must(lint.lint_file(path))
  assert(#diagnostics == 2, "two unjustified casts, got " .. #diagnostics)
  local render = require("_cli.lint_render")
  local text = render.render_diagnostics(path, diagnostics)
  assert(text:find("| local b = a as {string: any}", 1, true),
    "the offending line prints under its diagnostic: " .. text)
  assert(text:find("%.%.%.\n") ~= nil,
    "an over-long snippet truncates: " .. text)

  local binpath = fs.join(tmpdir, "notsource")
  assert(fs.write(binpath, string.rep("\0junk\n", 600)))
  local bindiags = check.must(lint.lint_file(binpath))
  assert(#bindiags == 1 and bindiags[1].rule == "file-length",
    "length finding expected")
  local bintext = render.render_diagnostics(binpath, bindiags)
  assert(not bintext:find("| ", 1, true),
    "file-length gets no snippet: " .. bintext)

  assert(render.render_diagnostics(path, {}) == "",
    "no diagnostics render as nothing")
end
test_render_diagnostics_snippets()
