--- The tests of [`build.code_fingerprint`]: the tokens of a source, with its comments and layout taken away, which the
--- identities of the code that reads and checks hash in place of the source.
local CodeFingerprint = require("build.code_fingerprint")

local normal = CodeFingerprint.normal
local of = CodeFingerprint.of

--- Whether `a` and `b` have one form and one digest.
local function alike(a: string, b: string): boolean
  return normal(a, "m") == normal(b, "m") and of(a, "m") == of(b, "m")
end

--- A comment, a doc comment, a blank line, an indent, a line break and a trailing space move nothing: they are no
--- token, and no code is made of them.
local function test_a_comment_and_the_layout_of_a_source_change_nothing()
  local plain = "local x = 1\nreturn x\n"
  assert(alike(plain, "-- a comment\nlocal x = 1\nreturn x\n"))
  assert(alike(plain, "--- a doc comment\n---\n--- of two lines\nlocal x = 1 -- and a tail\nreturn x\n"))
  assert(alike(plain, "\n\n\nlocal x = 1\n\n\n\nreturn x\n\n\n"))
  assert(alike(plain, "local    x   =\n\n  1\n\treturn   x   \r\n"))
  assert(alike(plain, "local x=1 return x"))
  assert(alike(plain, "#!/usr/bin/env cosmic\nlocal x = 1\nreturn x\n"))
  assert(alike("", "-- nothing but a comment\n"))
  assert(normal("-- nothing but a comment\n", "m") == "")
end

--- Every token moves it: a name, a keyword, an operator, a string's contents, a number as it is written.
local function test_a_token_of_a_source_changes_the_form()
  local plain = "local x = 1\nreturn x\n"
  assert(not alike(plain, "local y = 1\nreturn y\n"))
  assert(not alike(plain, "local x = 1\nreturn x, x\n"))
  assert(not alike("local s = 'a'", "local s = 'b'"))
  assert(not alike("local s = 'a'", 'local s = "a"'))
  assert(not alike("local s = 'a b'", "local s = 'a  b'"))
  assert(not alike("local s = [[a]]", "local s = [=[a]=]"))
  assert(not alike("local s = [[a]]", "local s = [[a ]]"))
  assert(not alike("local s = [[\na]]", "local s = [[a]]"))
  assert(not alike("local n = 1", "local n = 1.0"))
  assert(not alike("local n = 1", "local n = 0x1"))
  assert(not alike("local n = 1", "local n = 1e0"))
  assert(not alike("local n = 10", "local n = 01"))
  assert(not alike("local b = a + b", "local b = a - b"))
  assert(not alike("local b = a < b", "local b = a <= b"))
end

--- Tokens that read differently stay apart whatever separates them: a space written between two is no part of either, so
--- the form cannot make `a b` and `ab`, or a string and two names, one.
local function test_sources_that_read_differently_have_forms_that_differ()
  assert(not alike("a b", "ab"))
  assert(not alike("a .. b", "a . . b"))
  assert(not alike("local s = 'x y'", "local s = x y"))
  assert(not alike("local s = 'x' .. 'y'", "local s = 'xy'"))
  assert(not alike("a - -b", "a --b"))
end

--- A string keeps its bytes whatever they are: a line break, a space, the bytes of a comment or of a separator.
local function test_a_string_keeps_every_byte_it_is_written_with()
  local source = "local s = [[\n-- not a comment\n  a b\r\nc]]\nlocal t = '-- no comment ' .. \"  \"\n"
  local form = normal(source, "m")
  assert(form:find("-- not a comment", 1, true) ~= nil and form:find("a b\r\nc", 1, true) ~= nil, form)
  assert(form:find("'-- no comment '", 1, true) ~= nil and form:find('"  "', 1, true) ~= nil, form)
  assert(not alike(source, (source:gsub("not a comment", "no comment"))))
end

--- A form is a source that reads as the tokens it came from, so it is its own form. That is what lets a pure store keep
--- the form in place of the source and the identities come out the same of either.
local function test_a_form_is_its_own_form()
  local sources: {string} = {
    "local x = 1\nreturn x\n",
    "local s = [[\n-- a\n]] .. [==[ ]] ]==] .. 'q' .. \"\\\"\"",
    "local a = b - -c --d\nlocal e = f // g\nreturn ...",
    "local n = {1, 0x10, 1e3, 2.5, 3 // 2}\nreturn n[1]",
    "local function f(...: integer): integer?, string\n  return ...\nend\n",
    "x = a.b.c(d)(e):f(g)[h]\n",
    "local s = 'a\\\nb'\n",
    "local s = [[a\r\nb]]\r\n",
  }
  for _, source in ipairs(sources) do
    local form = normal(source, "m")
    assert(normal(form, "m") == form, "the form of " .. source .. " is not its own")
    assert(of(form, "m") == of(source, "m"), "the digest of the form of " .. source .. " is not that of the source")
  end
end

--- A source that does not lex raises, and names the module, rather than giving a form that two broken sources share.
local function test_a_source_that_does_not_lex_raises()
  for _, source in ipairs({ "local s = 'unterminated\n", "local s = [[unterminated", "local x = 1;", "::label::", "local x = 1 @" }) do
    local ok, why = pcall(function(): string
      return normal(source, "build.thing")
    end)
    assert(not ok, source .. " gave a form")
    assert(tostring(why):find("build.thing does not lex", 1, true) ~= nil, tostring(why))
    ok, why = pcall(function(): string
      return of(source, "build.thing")
    end)
    assert(not ok, source .. " gave a digest")
  end
end

--- The digest is a hex SHA-256 and names the form's version, so it is not the digest of the form alone.
local function test_the_digest_is_a_hex_sha256_of_the_versioned_form()
  local digest = of("return 1", "m")
  assert(#digest == 64 and digest:find("^%x+$") ~= nil, digest)
  assert(of("return 1", "m") == digest and of("return 2", "m") ~= digest)
end
