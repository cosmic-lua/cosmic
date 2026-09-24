local teal = require("build.teal")
local positions = require("build.positions")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Joins lines the way a real source file would read. Fixtures are
--- built from a table of plain string literals, assembled at run time,
--- rather than as a long-bracket literal sitting directly in THIS
--- file's own source: this file is itself a `_test.tl` module the real
--- importer discovers and parses, and a fixture string embedded here
--- as literal `[[...]]` text would put its own `local function
--- test_*` sample right into this file's real AST for the discovery
--- pass under test to find -- exactly the ambiguity `analyze`
--- no longer has to resolve, since a string built this way is never
--- anything but a "string" node's `conststr`, whichever implementation
--- reads it.
local function lines(parts: {string}): string
  return table.concat(parts, "\n") .. "\n"
end

--- `analyze` on `source`, asserting the parse itself succeeded, and
--- returning just its test names.
local function discover(source: string): {string}
  local found, err = positions.analyze(built, source, "fixture.tl")
  assert(found ~= nil, "analyze failed: " .. tostring(err))
  return found.tests
end

--- `analyze` on `source`, asserting the parse succeeded, and returning
--- just its top-level-return fact.
local function has_return(source: string): boolean
  local found, err = positions.analyze(built, source, "fixture.tl")
  assert(found ~= nil, "analyze failed: " .. tostring(err))
  return found.has_top_level_return
end

--- A `local function test_*` at the chunk's own top level is
--- discovered, in the order it appears.
local function test_discovers_top_level_tests()
  local source = lines({
    "local function test_one()",
    "end",
    "",
    "local function test_two()",
    "end",
  })
  local found = discover(source)
  assert(#found == 2, "expected 2, got " .. #found)
  assert(found[1] == "test_one")
  assert(found[2] == "test_two")
end

--- A helper that is not named `test_*` is not a test.
local function test_ignores_non_test_functions()
  local source = lines({
    "local function helper()",
    "end",
    "",
    "local function test_uses_helper()",
    "end",
  })
  local found = discover(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_uses_helper")
end

--- A `local function test_*` declared inside another function is a
--- child of that OTHER function's own body, never a direct element of
--- the chunk's own top-level statement array, and is not a test some
--- other function happens to declare for itself.
local function test_ignores_indented_functions()
  local source = lines({
    "local function outer()",
    "  local function test_inner()",
    "  end",
    "  return test_inner",
    "end",
    "",
    "local function test_top()",
    "end",
  })
  local found = discover(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_top")
end

--- A module with no `local function test_*` at all discovers nothing.
local function test_discovers_nothing_when_there_is_no_test()
  local source = lines({ "local function helper()", "end" })
  local found = discover(source)
  assert(#found == 0, "expected 0, got " .. #found)
end

--- A source SAMPLE held as a `[[...]]` long-bracket string parses to a
--- single "string" node, never a chunk-level statement of its own kind
--- -- its own `local function test_something()` text is never a
--- candidate for `analyze` to find at all, structurally, rather
--- than excluded by tracking where the bracket opens and closes.
local function test_ignores_a_fake_test_inside_a_plain_long_bracket()
  local source = lines({
    "local sample = [[",
    "local function test_something()",
    "  return 1",
    "end",
    "]]",
  })
  local found = discover(source)
  assert(#found == 0, "expected 0, got " .. #found)
end

--- The same shape, but the bracket carries one `=` sign, `[=[...]=]`.
local function test_ignores_a_fake_test_inside_a_leveled_long_bracket()
  local source = lines({
    "local sample = [=[",
    "local function test_something()",
    "end",
    "]=]",
  })
  local found = discover(source)
  assert(#found == 0, "expected 0, got " .. #found)
end

--- A long COMMENT parses to no statement at all -- tl's lexer consumes
--- it as a comment attached to the following token, so it never
--- reaches the parser as source text in the first place.
local function test_ignores_a_fake_test_inside_a_long_comment()
  local source = lines({
    "--[[",
    "local function test_something()",
    "end",
    "]]",
  })
  local found = discover(source)
  assert(#found == 0, "expected 0, got " .. #found)
end

--- Discovery is not fooled by a string sample that precedes a real
--- test: a real test that follows one in the same file is still found.
local function test_discovers_a_real_test_after_a_bracket_region()
  local source = lines({
    "local sample = [[",
    "local function test_fake()",
    "end",
    "]]",
    "",
    "local function test_real()",
    "end",
  })
  local found = discover(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_real")
end

--- A string sample does not retroactively un-discover a real test that
--- came before it in the same file.
local function test_discovers_a_real_test_before_a_bracket_region()
  local source = lines({
    "local function test_real()",
    "end",
    "",
    "local sample = [[",
    "local function test_fake()",
    "end",
    "]]",
  })
  local found = discover(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_real")
end

--- An ordinary quoted string holding the same text as a plain literal,
--- on one line, parses to a "string" node either way; confirm this
--- still is not one.
local function test_ignores_a_quoted_string_naming_a_test()
  local source = lines({
    'local x = "local function test_x()"',
    "",
    "local function test_real()",
    "end",
  })
  local found = discover(source)
  assert(#found == 1, "expected 1, got " .. #found)
  assert(found[1] == "test_real")
end

--- A file with no top-level return has none to collide with a
--- generated tail.
local function test_has_top_level_return_false_when_absent()
  local source = lines({ "local function helper()", "end" })
  assert(not has_return(source))
end

--- A genuine top-level `return`, the file's own last statement.
local function test_has_top_level_return_true_for_a_real_one()
  local source = lines({
    "local function test_one()",
    "end",
    "",
    "return 0",
  })
  assert(has_return(source))
end

--- A `return` nested inside a function body is a child of that
--- function's own "statements" node, never a direct element of the
--- chunk's own top-level array.
local function test_has_top_level_return_false_when_only_nested()
  local source = lines({
    "local function helper()",
    "  return 1",
    "end",
  })
  assert(not has_return(source))
end

--- A `return` inside a long-bracket sample parses as part of a
--- "string" node's own text, not as a "return" statement.
local function test_has_top_level_return_false_inside_a_bracket()
  local source = lines({
    "local sample = [[",
    "return 0",
    "]]",
  })
  assert(not has_return(source))
end

--- A table constructor return is still a genuine top-level return:
--- `has_top_level_return` checks the statement's own `kind`, so what
--- the return's own expression happens to be shaped like never
--- matters, unlike a text pattern that has to special-case it.
local function test_has_top_level_return_true_for_a_table_constructor()
  local source = lines({ "return { 1, 2, 3 }" })
  assert(has_return(source))
end

--- A `return` immediately followed by a comment, with no value, is
--- still the chunk's genuine top-level return.
local function test_has_top_level_return_true_with_a_trailing_comment()
  local source = lines({ "return -- nothing to give back" })
  assert(has_return(source))
end

--- An ordinary snake_case identifier assignment that happens to start
--- with the six letters `return` parses to an `"assignment"` node, not
--- `"return"` -- there is no shared text prefix for a checker to get
--- wrong, unlike `%f[^%w_]` over raw source.
local function test_has_top_level_return_false_for_return_prefixed_assignment()
  local source = lines({
    "local function test_one()",
    "end",
    "",
    "return_code = 1",
  })
  assert(not has_return(source))
end

--- A function call whose name starts with `return_` parses to an
--- `"op"` (call) node, never `"return"`.
local function test_has_top_level_return_false_for_return_prefixed_call()
  local source = lines({ "return_value(x)" })
  assert(not has_return(source))
end

--- `return(x)`, a genuine return of a parenthesized expression with no
--- space before the `(`, must still be flagged: the two cases above
--- must not overcorrect and swallow this legitimate one.
local function test_has_top_level_return_true_for_a_parenthesized_return()
  local source = lines({ "return(x)" })
  assert(has_return(source))
end

--- `analyze` on `source`, asserting the parse succeeded, and returning
--- just its catalog.
local function catalog(source: string): {positions.CatalogEntry}
  local found, err = positions.analyze(built, source, "fixture.tl")
  assert(found ~= nil, "analyze failed: " .. tostring(err))
  return found.catalog
end

--- A top-level function yields one entry per literal `return nil, ...`
--- in its body, naming the function, the message text, and the
--- return's line -- documented or not: the guidance is looked up from
--- its docs later, and a function with none still names where the
--- message comes from.
local function test_catalogs_a_literal_failure()
  local source = lines({
    "local function open_thing(): boolean, string",
    "  return nil, \"the thing was not found\"",
    "end",
  })
  local found = catalog(source)
  assert(#found == 1, "expected one entry, got " .. #found)
  assert(found[1].symbol == "open_thing", found[1].symbol)
  assert(found[1].message == "the thing was not found", found[1].message)
  assert(found[1].line == 2, tostring(found[1].line))
end

--- `return false, ...` is an honest failure too, and is catalogued the
--- same way.
local function test_catalogs_a_false_return()
  local source = lines({
    "local function try_thing(): boolean, string",
    "  return false, \"the thing is busy right now\"",
    "end",
  })
  local found = catalog(source)
  assert(#found == 1)
  assert(found[1].message == "the thing is busy right now", found[1].message)
end

--- A concatenated message keeps its literal pieces and drops the
--- interpolated ones, so the entry holds exactly the text an error
--- would always contain.
local function test_message_keeps_only_the_literal_text()
  local source = lines({
    "local function open_thing(path: string): boolean, string",
    "  return nil, \"could not open \" .. path .. \" for reading\"",
    "end",
  })
  local found = catalog(source)
  assert(#found == 1)
  assert(found[1].message == "could not open  for reading", found[1].message)
end

--- A message that reduces to too little literal text to anchor a match
--- is left out rather than shipped as a near-universal false hit.
local function test_drops_a_mostly_interpolated_message()
  local source = lines({
    "local function open_thing(path: string): boolean, string",
    "  return nil, path .. \": \" .. describe()",
    "end",
    "local function pick(index: integer): boolean, string",
    "  return nil, \"no \" .. tostring(index)",
    "end",
  })
  assert(#catalog(source) == 0)
end

--- A record function's symbol names its owner the way it was declared,
--- with `.` for a plain function and `:` for a method.
local function test_record_function_symbols_name_their_owner()
  local source = lines({
    "local record Thing",
    "end",
    "function Thing.read(): boolean, string",
    "  return nil, \"the thing is not open\"",
    "end",
    "function Thing:write(): boolean, string",
    "  return nil, \"the thing is not open for writing\"",
    "end",
  })
  local found = catalog(source)
  assert(#found == 2, "expected two entries, got " .. #found)
  assert(found[1].symbol == "Thing.read", found[1].symbol)
  assert(found[2].symbol == "Thing:write", found[2].symbol)
end

--- A failure returned from a nested block is found; one returned by a
--- function declared inside the outer one is that inner function's,
--- and is not attributed to the outer one.
local function test_walks_nested_blocks_but_not_inner_functions()
  local source = lines({
    "local function open_thing(a: boolean): boolean, string",
    "  if a then",
    "    if not a then",
    "      return nil, \"the thing is deeply wrong\"",
    "    end",
    "  end",
    "  local function inner(): boolean, string",
    "    return nil, \"the inner thing is wrong\"",
    "  end",
    "  return inner()",
    "end",
  })
  local found = catalog(source)
  assert(#found == 1, "expected one entry, got " .. #found)
  assert(found[1].message == "the thing is deeply wrong", found[1].message)
  assert(found[1].line == 4, tostring(found[1].line))
end

--- `analyze` on `source`, asserting the parse succeeded, and returning
--- its documented symbols by symbol.
local function docs(source: string): {string: positions.DocEntry}, {positions.DocEntry}
  local found, err = positions.analyze(built, source, "fixture.tl")
  assert(found ~= nil, "analyze failed: " .. tostring(err))
  local by_symbol: {string: positions.DocEntry} = {}
  for _, entry in ipairs(found.docs) do
    by_symbol[entry.symbol] = entry
  end
  return by_symbol, found.docs
end

--- A function's doc comment is the run of comment lines directly above
--- it, leaders stripped, one line per source line; its signature is
--- its head as written, however the source wrapped it.
local function test_documents_a_function()
  local source = lines({
    "--- Opens a thing.",
    "---",
    "--- Returns nil when it is not there.",
    "local function open_thing(path: string,",
    "                          mode: string): boolean, string",
    "  return nil, \"the thing was not found\"",
    "end",
  })
  local by_symbol = docs(source)
  local entry = by_symbol["open_thing"]
  assert(entry ~= nil, "open_thing is not documented")
  assert(entry.kind == "function", entry.kind)
  assert(entry.text == "Opens a thing.\n\nReturns nil when it is not there.", entry.text)
  assert(entry.signature ==
    "local function open_thing(path: string, mode: string): boolean, string",
    entry.signature)
  assert(entry.line == 4, tostring(entry.line))
end

--- A function with no comment of its own is still a symbol, with an
--- empty text: `cosmic docs` can still say where it lives.
local function test_an_undocumented_function_is_still_a_symbol()
  local source = lines({
    "local function quiet()",
    "end",
  })
  local by_symbol = docs(source)
  assert(by_symbol["quiet"] ~= nil)
  assert(by_symbol["quiet"].text == "")
end

--- A comment separated from a declaration by a blank line is not its
--- documentation; when that comment opens the file, it is the module's.
local function test_the_opening_comment_documents_the_module()
  local source = lines({
    "--- The thing module.",
    "--- It has things in it.",
    "",
    "--- Opens a thing.",
    "local function open_thing()",
    "end",
  })
  local by_symbol = docs(source)
  local module = by_symbol[""]
  assert(module ~= nil, "no module doc")
  assert(module.kind == "module")
  assert(module.text == "The thing module.\nIt has things in it.", module.text)
  assert(by_symbol["open_thing"].text == "Opens a thing.", by_symbol["open_thing"].text)
end

--- A comment that opens the file with no blank line before the first
--- function is that function's, not the module's.
local function test_an_adjacent_opening_comment_belongs_to_the_function()
  local source = lines({
    "--- Opens a thing.",
    "local function open_thing()",
    "end",
  })
  local by_symbol = docs(source)
  assert(by_symbol[""] == nil, "the opening comment was taken as the module's")
  assert(by_symbol["open_thing"].text == "Opens a thing.")
end

--- A comment that opens the file directly above its first `local`
--- (a require, as most files begin) is the module's, and does not
--- make that local a documented value.
local function test_an_opening_comment_above_a_require_is_the_modules()
  local source = lines({
    "--- The thing module.",
    "local Fs = require(\"cosmic.fs\")",
    "--- How many.",
    "local count = 3",
  })
  local by_symbol = docs(source)
  assert(by_symbol[""] ~= nil and by_symbol[""].text == "The thing module.")
  assert(by_symbol["Fs"] == nil, "the require became a documented value")
  assert(by_symbol["count"].text == "How many.")
end

--- A file that is only a comment documents its module.
local function test_a_comment_only_file_documents_the_module()
  local by_symbol = docs(lines({ "--- Nothing but words." }))
  assert(by_symbol[""] ~= nil and by_symbol[""].text == "Nothing but words.")
end

--- A record is a symbol, and so is each field under it, in declaration
--- order, with a nested record or enum recursing under its own name.
--- Methods declared on the record join under the same prefix.
local function test_documents_a_record_and_its_fields()
  local source = lines({
    "--- A thing.",
    "local record Thing",
    "  --- Where it is.",
    "  path: string",
    "  --- How it is opened.",
    "  record Options",
    "    --- Whether to create it.",
    "    create: boolean",
    "  end",
    "  --- What kind it is.",
    "  enum Kind",
    "    \"file\"",
    "    \"dir\"",
    "  end",
    "end",
    "--- Reads it.",
    "function Thing:read(): string",
    "  return \"\"",
    "end",
    "return Thing",
  })
  local by_symbol, all = docs(source)
  assert(by_symbol["Thing"].kind == "record", by_symbol["Thing"].kind)
  assert(by_symbol["Thing"].signature == "local record Thing", by_symbol["Thing"].signature)
  assert(by_symbol["Thing"].text == "A thing.")
  assert(by_symbol["path"].kind == "field")
  assert(by_symbol["path"].source_symbol == "Thing.path")
  assert(by_symbol["path"].signature == "path: string", by_symbol["path"].signature)
  assert(by_symbol["path"].text == "Where it is.")
  assert(by_symbol["Options"].kind == "record")
  assert(by_symbol["Options"].text == "How it is opened.", by_symbol["Options"].text)
  assert(by_symbol["Options.create"].kind == "field")
  assert(by_symbol["Options.create"].text == "Whether to create it.")
  assert(by_symbol["Kind"].kind == "enum")
  assert(by_symbol["Kind.file"].kind == "value")
  assert(by_symbol["Kind.file"].signature == "\"file\"")
  assert(by_symbol["read"].kind == "method")
  assert(by_symbol["read"].text == "Reads it.")
  local order: {string} = {}
  for _, entry in ipairs(all) do
    order[#order + 1] = entry.symbol
  end
  assert(table.concat(order, " ") ==
    "Thing path Options Options.create Kind Kind.dir Kind.file read",
    table.concat(order, " "))
end

--- A type alias is a symbol of kind `type`; a documented top-level
--- value is one of kind `value`, and an undocumented one is not.
local function test_documents_aliases_and_documented_values()
  local source = lines({
    "--- A name for a map.",
    "local type Names = {string: string}",
    "--- How many.",
    "local count = 3",
    "local quiet = 4",
  })
  local by_symbol = docs(source)
  assert(by_symbol["Names"].kind == "type", by_symbol["Names"].kind)
  assert(by_symbol["Names"].signature == "local type Names = {string: string}")
  assert(by_symbol["count"].kind == "value")
  assert(by_symbol["count"].text == "How many.")
  assert(by_symbol["quiet"] == nil, "an undocumented local became a symbol")
end

--- The name a chunk returns is its export, and each `alias.member`
--- through a top-level require alias is a reference to that module,
--- once per member per line, in source order.
local function test_finds_the_export_and_the_references()
  local source = lines({
    "local Fs = require(\"cosmic.fs\")",
    "local Hash = require(\"cosmic.hash\")",
    "local record Thing",
    "end",
    "function Thing.go()",
    "  local data = Fs.read(\"x\")",
    "  return Hash.hex(Hash.sha256(data)), Fs.read(\"y\")",
    "end",
    "return Thing",
  })
  local found, err = positions.analyze(built, source, "fixture.tl")
  assert(found ~= nil, "analyze failed: " .. tostring(err))
  assert(found.export == "Thing", found.export)
  local seen: {string} = {}
  for _, r in ipairs(found.references) do
    seen[#seen + 1] = r.module .. " " .. r.member .. " " .. r.line
  end
  assert(table.concat(seen, ", ") ==
    "cosmic.fs read 6, cosmic.fs read 7, cosmic.hash hex 7, cosmic.hash sha256 7",
    table.concat(seen, ", "))
end

--- Reference identity follows the lexical binding, not the spelling. Every
--- shadow hides the import only in its own scope, while reassignment makes
--- later uses uncertain and therefore absent.
local function test_references_respect_shadowing_loops_and_reassignment()
  local source = lines({
    "local Fs = require(\"cosmic.fs\")",
    "Fs.read(\"before\")",
    "local function parameter(Fs: any)",
    "  Fs.read(\"shadowed parameter\")",
    "end",
    "do",
    "  local Fs = {}",
    "  Fs.read(\"shadowed block\")",
    "end",
    "for Fs in values do",
    "  Fs.read(\"shadowed loop\")",
    "end",
    "Fs.read(\"after scopes\")",
    "Fs = replacement",
    "Fs.read(\"after reassignment\")",
  })
  local found = assert(positions.analyze(built, source, "fixture.tl"))
  assert(#found.references == 2, tostring(#found.references))
  assert(found.references[1].line == 2, tostring(found.references[1].line))
  assert(found.references[2].line == 13, tostring(found.references[2].line))
end

--- A repeat body's locals remain in scope in its `until` condition. A local
--- with the import's spelling must therefore suppress that apparent member.
local function test_repeat_condition_uses_the_body_scope()
  local found = assert(positions.analyze(built, lines({
    'local Fs = require("cosmic.fs")',
    "repeat",
    "  local Fs = {}",
    "until Fs.done",
  }), "fixture.tl"))
  assert(#found.references == 0, tostring(#found.references))
end

--- A member read straight off a literal `require` is a use of that
--- module's member, as `cmd/cosmic/main.tl` reaches each verb's `run`;
--- a `require` of a computed name is not, since its target is unknown,
--- nor a call of a local or parameter that shadows `require`.
local function test_a_member_of_an_inline_require_is_a_reference()
  local found = assert(positions.analyze(built, lines({
    'local name = "cosmic.fs"',
    'require("build.test").run({})',
    'require(name).read("x")',
    'local function shadowed(require: function(string): any)',
    '  require("build.test").run({})',
    'end',
  }), "fixture.tl"))
  assert(#found.references == 1, tostring(#found.references))
  local reference = found.references[1]
  assert(reference.module == "build.test" and reference.member == "run"
    and reference.line == 2, reference.module .. " " .. reference.member)
end

--- Local import spellings are not target identity: two aliases of the same
--- module produce the same canonical module/member pair.
local function test_distinct_import_aliases_share_canonical_identity()
  local found = assert(positions.analyze(built, lines({
    'local Fs = require("cosmic.fs")',
    'local disk = require("cosmic.fs")',
    'Fs.read("one")',
    'disk.read("two")',
  }), "fixture.tl"))
  assert(#found.references == 2)
  for _, reference in ipairs(found.references) do
    assert(reference.module == "cosmic.fs" and reference.member == "read")
  end
end

--- The returned record name is display spelling. Renaming it leaves the same
--- canonical exported member and its original definition location.
local function test_export_record_name_is_not_symbol_identity()
  local first = assert(positions.analyze(built, lines({
    "local record First", "end", "function First.read()", "end", "return First",
  }), "first.tl"))
  local second = assert(positions.analyze(built, lines({
    "local record Renamed", "end", "function Renamed.read()", "end", "return Renamed",
  }), "second.tl"))
  assert(first.docs[2].symbol == "read", first.docs[2].symbol)
  assert(second.docs[2].symbol == "read", second.docs[2].symbol)
  assert(first.docs[2].source_symbol == "First.read")
  assert(second.docs[2].source_symbol == "Renamed.read")
  assert(first.docs[2].line == 3 and second.docs[2].line == 3)
end

--- A public record field assigned a documented local implementation is the
--- exported identity, but points at the implementation's docs and location.
--- The local declaration remains available for private inspection.
local function test_export_alias_points_to_implementation_definition()
  local found = assert(positions.analyze(built, lines({
    "local record Public",
    "  run: function(string): boolean",
    "end",
    "--- Runs the operation.",
    "local function implementation(value: string): boolean",
    "  return value ~= \"\"",
    "end",
    "Public.run = implementation",
    "return Public",
  }), "fixture.tl"))
  local by_symbol: {string: positions.DocEntry} = {}
  for _, entry in ipairs(found.docs) do by_symbol[entry.symbol] = entry end
  local public = assert(by_symbol["run"])
  assert(public.source_symbol == "Public.run")
  assert(public.kind == "function" and public.exported)
  assert(public.text == "Runs the operation.")
  assert(public.line == 5, tostring(public.line))
  local private = assert(by_symbol["implementation"])
  assert(not private.exported and private.line == 5)
end

--- Export assignment captures the function value at that point. Reassigning
--- the local later does not change the member that already received it.
local function test_export_alias_survives_later_local_reassignment()
  local found = assert(positions.analyze(built, lines({
    "local record Public", "  run: function(): boolean", "end",
    "--- The captured implementation.",
    "local function implementation(): boolean", "  return true", "end",
    "Public.run = implementation",
    "implementation = function(): boolean return false end",
    "return Public",
  }), "fixture.tl"))
  local exported: positions.DocEntry = nil
  for _, entry in ipairs(found.docs) do
    if entry.exported and entry.symbol == "run" then exported = entry end
  end
  assert(exported ~= nil and exported.line == 5)
  assert(exported.text == "The captured implementation.")
end

--- An assignment to a nested binding with the same spelling is unrelated to
--- the outer implementation captured by the public member.
local function test_nested_shadow_does_not_invalidate_export_alias()
  local found = assert(positions.analyze(built, lines({
    "local record Public", "  run: function(): boolean", "end",
    "--- The outer implementation.",
    "local function implementation(): boolean", "  return true", "end",
    "Public.run = implementation",
    "do",
    "  local implementation = function(): boolean return false end",
    "  implementation = function(): boolean return false end",
    "end",
    "return Public",
  }), "fixture.tl"))
  local exported: positions.DocEntry = nil
  for _, entry in ipairs(found.docs) do
    if entry.exported and entry.symbol == "run" then exported = entry end
  end
  assert(exported ~= nil and exported.line == 5)
  assert(exported.text == "The outer implementation.")
end

--- The last supported member write controls the public definition. An
--- unknown final value leaves only the truthful declared field exported;
--- earlier callable definitions remain private inspection rows.
local function test_final_unknown_member_write_removes_stale_callable_export()
  local found = assert(positions.analyze(built, lines({
    "local record Public", "  run: function(): boolean", "end",
    "--- The original callable.",
    "function Public.run(): boolean", "  return true", "end",
    "Public.run = unknown_value",
    "return Public",
  }), "fixture.tl"))
  local exported = 0
  local private_callable = 0
  for _, entry in ipairs(found.docs) do
    if entry.exported and entry.symbol == "run" then
      exported = exported + 1
      assert(entry.kind == "field", entry.kind)
      assert(entry.line == 2, tostring(entry.line))
    elseif not entry.exported and entry.source_symbol == "Public.run"
           and entry.kind == "function" then
      private_callable = private_callable + 1
    end
  end
  assert(exported == 1, tostring(exported))
  assert(private_callable == 1, tostring(private_callable))
end

--- A keyed table return is an equally explicit export surface even without a
--- named record. Its member aliases the local implementation canonically.
local function test_table_return_alias_points_to_implementation()
  local found = assert(positions.analyze(built, lines({
    "--- Runs the operation.",
    "local function implementation(): boolean",
    "  return true",
    "end",
    "return { run = implementation }",
  }), "fixture.tl"))
  local exported: positions.DocEntry = nil
  local private: positions.DocEntry = nil
  for _, entry in ipairs(found.docs) do
    if entry.symbol == "run" then exported = entry end
    if entry.symbol == "implementation" then private = entry end
  end
  assert(exported ~= nil and exported.exported and exported.line == 2)
  assert(exported.source_symbol == "run" and exported.text == "Runs the operation.")
  assert(private ~= nil and not private.exported)
end

--- An unsupported scalar value has no declaration identity. The empty
--- sentinel must never resolve to the module's own empty-symbol doc row.
local function test_unresolved_table_export_does_not_inherit_module_doc()
  local found = assert(positions.analyze(built, lines({
    "--- Public version.",
    "local version = \"1\"",
    "return { version = version, make = function(): string return \"x\" end }",
  }), "fixture.tl"))
  for _, entry in ipairs(found.docs) do
    assert(entry.symbol ~= "version", "scalar export inherited a declaration")
    assert(entry.symbol ~= "make", "function expression inherited a declaration")
  end
  assert(found.docs[1].symbol == "" and found.docs[1].kind == "module")
  assert(found.docs[1].text == "Public version.")
end

--- A chunk that returns nothing, or an expression that is not a plain
--- name, exports no name.
local function test_export_is_empty_without_a_named_return()
  local found = assert(positions.analyze(built, lines({ "return {}" }), "fixture.tl"))
  assert(found.export == "", found.export)
  found = assert(positions.analyze(built, lines({ "local x = 1" }), "fixture.tl"))
  assert(found.export == "", found.export)
end

--- `analyze` on `source`, asserting the parse succeeded, and returning
--- just its worked examples.
local function examples(source: string): {positions.ExampleEntry}
  local found, err = positions.analyze(built, source, "fixture.tl")
  assert(found ~= nil, "analyze failed: " .. tostring(err))
  return found.examples
end

--- A top-level `function Example.<name>()` is a worked example, found
--- by shape alone -- no tag, no comment above it required.
local function test_discovers_an_example_function()
  local source = lines({
    "local Example = {}",
    "function Example.read()",
    "  assert(1 == 1)",
    "end",
    "return Example",
  })
  local found = examples(source)
  assert(#found == 1, tostring(#found))
  assert(found[1].name == "read", found[1].name)
  assert(found[1].line == 2, tostring(found[1].line))
  assert(found[1].text == "", found[1].text)
end

--- An example is documentation too: the comment directly above it is
--- read the same way `docs_of` reads any other function's, and is
--- never mistaken for part of the source below it.
local function test_captures_an_examples_doc_comment()
  local source = lines({
    "local Example = {}",
    "--- Reads a file back and prints it.",
    "function Example.read()",
    "  assert(1 == 1)",
    "end",
    "return Example",
  })
  local found = examples(source)
  assert(#found == 1, tostring(#found))
  assert(found[1].text == "Reads a file back and prints it.", found[1].text)
  assert(not found[1].source:find("Reads a file back", 1, true),
    "the doc comment leaked into the captured source: " .. found[1].source)
end

--- An ordinary function, local or on any other record, is not an
--- example: only the exact shape `function Example.<name>()` is.
local function test_ignores_non_example_functions()
  local source = lines({
    "local record Fs",
    "end",
    "function Fs.read()",
    "end",
    "local function test_helper()",
    "end",
  })
  assert(#examples(source) == 0)
end

--- The captured source is the whole statement as written, every line,
--- up to but not including whatever sits after it -- a trailing blank
--- or comment-only line belongs to what follows, not to the example.
local function test_captures_the_whole_example_source()
  local source = lines({
    "local Example = {}",
    "",
    "function Example.read()",
    "  local ok = 1 == 1",
    "  assert(ok)",
    "end",
    "",
    "-- a comment about what comes next",
    "return Example",
  })
  local found = examples(source)
  assert(#found == 1, tostring(#found))
  assert(found[1].source == lines({
    "function Example.read()",
    "  local ok = 1 == 1",
    "  assert(ok)",
    "end",
  }):gsub("\n$", ""), found[1].source)
end

--- A worked example documents another module's symbol, not this
--- chunk's own: `docs_of` (read through `found.docs`) never lists it.
local function test_an_example_is_not_also_an_ordinary_doc_entry()
  local source = lines({
    "local Example = {}",
    "function Example.read()",
    "end",
    "return Example",
  })
  local found = assert(positions.analyze(built, source, "fixture.tl"))
  for _, entry in ipairs(found.docs) do
    assert(entry.symbol ~= "Example.read", "Example.read leaked into docs")
  end
end

--- A module record for `positions.check`: `file` decides its path and
--- kind the way the importer's `inputs` view does, and `requires` is
--- what it imports.
local function module_at(file: string, requires: {string}): positions.Module
  local base = file:gsub("/init%.tl$", ""):gsub("%.tl$", "")
  return {
    path = (base:gsub("/", ".")),
    file = file,
    kind = file:match("_test%.tl$") and "test" or
      file:match("_example%.tl$") and "example" or "module",
    source = "", source_hash = "", requires = requires, tests = {},
    has_top_level_return = true, generated = false, key = "", lua = "",
  }
end

--- `positions.check` over `files` (each file and what it requires), in a
--- project tree or in cosmic's own.
local function positioned(files: {{string}}, own_tree: boolean): boolean, string
  local modules: {positions.Module} = {}
  for _, row in ipairs(files) do
    local requires: {string} = {}
    for i = 2, #row do requires[#requires + 1] = row[i] end
    modules[#modules + 1] = module_at(row[1], requires)
  end
  return positions.check(modules, own_tree)
end

--- A directory's own `init.tl` is the one path in from outside: a
--- sibling beside it is reachable only from inside the directory.
local function test_position_keeps_an_entrys_siblings_inside()
  local ok, trouble = positioned({
    { "lib/init.tl" }, { "lib/part.tl" }, { "main.tl", "lib.part" },
  }, false)
  assert(not ok and trouble:find("main.tl: lib.part is private to lib/", 1, true), trouble)
  ok, trouble = positioned({
    { "lib/init.tl", "lib.part" }, { "lib/part.tl" }, { "main.tl", "lib" },
  }, false)
  assert(ok, trouble)
end

--- A nested directory with no `init.tl` has no entry, so nothing in it
--- is reachable from outside it -- not even when it holds one module --
--- while a file inside it still reaches its siblings.
local function test_position_closes_a_nested_directory_without_an_entry()
  local ok, trouble = positioned({
    { "tool/coverage/lines.tl" }, { "tool/test.tl", "tool.coverage.lines" },
  }, false)
  assert(not ok and trouble:find("tool/coverage/ has no init.tl entry", 1, true), trouble)
  ok, trouble = positioned({
    { "tool/coverage/lines.tl" },
    { "tool/coverage/report.tl", "tool.coverage.lines" },
    { "tool/coverage/lines_test.tl", "tool.coverage.lines" },
  }, false)
  assert(ok, trouble)
end

--- A top-level directory with no `init.tl` is a namespace of flat
--- modules, each public, the way `cosmic/fs.tl` is `cosmic.fs`; so is
--- the entry of a directory inside one.
local function test_position_opens_a_top_level_namespace()
  local ok, trouble = positioned({
    { "lib/fs.tl" }, { "lib/walk/init.tl" }, { "main.tl", "lib.fs", "lib.walk" },
    { "cmd/tool/main.tl", "lib.fs" },
  }, false)
  assert(ok, trouble)
end

--- A directory's own entry is a member of the directory around it: one
--- nested in a closed directory is reachable only from inside that one.
local function test_position_closes_an_entry_nested_in_a_closed_directory()
  local ok, trouble = positioned({
    { "lib/deep/inner/init.tl" }, { "main.tl", "lib.deep.inner" },
  }, false)
  assert(not ok and trouble:find("is private to lib/deep/", 1, true), trouble)
  ok, trouble = positioned({
    { "lib/deep/inner/init.tl" }, { "lib/deep/user.tl", "lib.deep.inner" },
  }, false)
  assert(ok, trouble)
end

--- In cosmic's own tree `build/` is private to the tool: the standard
--- library and its examples may not import it, while the binary, tests
--- and test support may. A project's own `build/` is its own business.
local function test_position_keeps_build_private_in_cosmics_own_tree()
  local ok, trouble = positioned({
    { "build/clock.tl" }, { "cosmic/time.tl", "build.clock" },
  }, true)
  assert(not ok and trouble:find("cosmic/time.tl: build.clock is private to build/", 1, true),
    trouble)
  ok, trouble = positioned({
    { "build/clock.tl" }, { "cosmic/time_example.tl", "build.clock" },
  }, true)
  assert(not ok, "an example may not import build/")
  ok, trouble = positioned({
    { "build/clock.tl" }, { "build/test.tl", "build.clock" },
    { "cmd/cosmic/main.tl", "build.clock" }, { "cosmic/time_test.tl", "build.clock" },
    { "test/portable/tool.tl", "build.clock" },
  }, true)
  assert(ok, trouble)
  ok, trouble = positioned({
    { "build/clock.tl" }, { "lib/time.tl", "build.clock" },
  }, false)
  assert(ok, trouble)
end

--- A test has no more reach than any other file: one outside a closed
--- directory is refused its siblings too.
local function test_position_refuses_a_test_outside_a_closed_directory()
  local ok, trouble = positioned({
    { "lib/init.tl" }, { "lib/part.tl" }, { "main_test.tl", "lib.part" },
  }, false)
  assert(not ok and trouble:find("main_test.tl: lib.part is private to lib/", 1, true), trouble)
  ok, trouble = positioned({
    { "lib/init.tl" }, { "lib/part.tl" }, { "lib/part_test.tl", "lib.part" },
  }, false)
  assert(ok, trouble)
end

--- An `init.tl` at the root is the module `init`, a flat file of the
--- root like any other: public, and it closes nothing.
local function test_position_treats_a_root_init_as_a_flat_module()
  local ok, trouble = positioned({
    { "init.tl", "notes" }, { "notes.tl" }, { "lib/fs.tl", "init" },
  }, false)
  assert(ok, trouble)
end

--- A top-level directory with its own `init.tl` is closed, yet its files
--- may import from a top-level namespace beside it, which is open.
local function test_position_lets_a_closed_directory_import_an_open_namespace()
  local ok, trouble = positioned({
    { "app/init.tl", "app.part", "lib.fs" }, { "app/part.tl", "lib.fs" },
    { "lib/fs.tl" },
  }, false)
  assert(ok, trouble)
  ok, trouble = positioned({
    { "app/init.tl" }, { "app/part.tl" }, { "lib/fs.tl", "app.part" },
  }, false)
  assert(not ok and trouble:find("lib/fs.tl: app.part is private to app/", 1, true), trouble)
end
