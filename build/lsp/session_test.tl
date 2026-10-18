--- `cosmic lsp`'s sessions ([`build.lsp.session`], [`build.lsp.check`]):
--- the protocol's lifecycle, a document's diagnostics, where they are and
--- how they are worded, hover, formatting, and one session over a
--- loopback connection. What a `require` reads is in source_test.tl.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local build_paths = require("build.paths")
local docs_fixture = require("build.docs_fixture")
local session = require("build.lsp.session")
local session_fixture = require("build.lsp.session_fixture")

Test.policy{ loopback = { "127.0.0.1" } }

local type Ran = session_fixture.Ran
local answer, at, bodies = session_fixture.answer, session_fixture.at, session_fixture.bodies
local change, changes, close = session_fixture.change, session_fixture.changes, session_fixture.close
local counts, edge, failed = session_fixture.counts, session_fixture.edge, session_fixture.failed
local format, framed = session_fixture.format, session_fixture.framed
local initialize, initialized = session_fixture.initialize, session_fixture.initialized
local messages_of, nth, only = session_fixture.messages_of, session_fixture.nth, session_fixture.only
local open, published, served = session_fixture.open, session_fixture.published, session_fixture.served
local sent_of = session_fixture.sent
local EXIT, SHUTDOWN = session_fixture.EXIT, session_fixture.SHUTDOWN

local record Markup
  value: string
end

local record Hovered
  contents: Markup
end

local record HoverSent
  result: Hovered | nil
end

local HOVER_SENT <const> = Shape.record_of("HoverSent")

local record Edit
  newText: string
end

local record FormatSent
  result: {Edit}
end

local FORMAT_SENT <const> = Shape.record_of("FormatSent")

--- A docs database that documents [`cosmic.fs`] and its `read`.
local function fs_docs(root: string): Sqlite.Handle
  return docs_fixture.database(root, {
    ["cosmic/fs.tl"] = "--- Files.\nlocal Fs = {}\n--- Reads the whole of a file.\n" ..
      "function Fs.read(path: string): string return path end\nreturn Fs\n",
  })
end

--- The markdown of the hover `ran` answered request `id` with, or nil.
local function hovered(ran: Ran, id: integer): string | nil
  local shown = assert(HOVER_SENT:decode_into(answer(ran, id)))
  local result = shown.result
  if result == nil then return nil end
  return result.contents.value
end

--- What the loopback test's two tasks leave each other.
local record Exchange
  code: integer
  sent: string
end

local function test_a_type_error_is_published_where_it_is()
  local root = session_fixture.project()
  local text = 'local s = "é"\nlocal n: integer = s\nreturn n\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text), SHUTDOWN, EXIT })
  assert(ran.code == 0, ran.err)
  local init = initialized(answer(ran, 1))
  assert(init.capabilities.positionEncoding == "utf-16")
  assert(init.capabilities.textDocumentSync.change == 1)
  local diagnostics = published(ran)[1]
  assert(#diagnostics == 1, table.concat(ran.sent, "\n"))
  assert(diagnostics[1].message:find("got string, expected integer", 1, true), diagnostics[1].message)
  local start, finish = diagnostics[1].range["start"], diagnostics[1].range["end"]
  assert(start.line == 1 and start.character == 19)
  -- The range covers the word, `s`, not the place alone.
  assert(finish.line == 1 and finish.character == 20)
  assert(answer(ran, 99):find('"result":null', 1, true))
end

local function test_a_column_counts_utf16_units_or_bytes_as_negotiated()
  local root = session_fixture.project()
  -- "é" is two bytes and one UTF-16 unit; the error is at `nope`.
  local text = 'local _ = { "é", nope }\n'
  local wide = served(root, { initialize(root), open(root, "main.tl", text) })
  local found = published(wide)[1][1].range
  assert(found["start"].character == 17)
  assert(found["end"].character == 21, "the end is past the start, by the word `nope`")
  local narrow = served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8","utf-16"]}}'),
    open(root, "main.tl", text) })
  local init = initialized(answer(narrow, 1))
  assert(init.capabilities.positionEncoding == "utf-8")
  assert(published(narrow)[1][1].range["start"].character == 18)
end

local function test_a_change_that_fixes_the_error_clears_it()
  local root = session_fixture.project()
  local runs = published(served(root, {
    initialize(root),
    open(root, "main.tl", "local n: integer = 'x'\nreturn n\n"),
    change(root, "main.tl", "local n: integer = 1\nreturn n\n"),
    close(root, "main.tl"),
  }))
  assert(#runs == 3 and #runs[1] == 1 and #runs[2] == 0 and #runs[3] == 0)
end

local function test_hover_shows_the_docs_of_a_required_symbol()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- `F` is no name the docs know: only the `require` it is bound to says
  -- it is cosmic.fs.
  local text = 'local F = require("cosmic.fs")\nlocal unknown = 1\nlocal _ = F.read, unknown\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    at(2, "textDocument/hover", root, "main.tl", 2, 13),
    at(3, "textDocument/hover", root, "main.tl", 2, 19),
  }, { fs_docs(root) })
  local value = assert(hovered(ran, 2), ran.err)
  assert(value:find("cosmic.fs.read", 1, true) ~= nil and value:find("Reads the whole of a file.", 1, true) ~= nil,
    value)
  assert(hovered(ran, 3) == nil, "a name nothing documents")
end

--- A build writes the projection anew and renames it into place: a
--- hover reads the docs of the one there now, not the one it read first.
local function test_hover_reads_the_projection_a_build_wrote_again()
  local root = session_fixture.project()
  local projection = build_paths.under((assert(build_paths.directory(root)))).projection
  --- Writes, as the build does, a projection whose `lib.shapes.area` says `word`.
  local function built(word: string)
    local scratch = assert(Fs.mkdtemp("cosmic-lsp-docs-"))
    local db = docs_fixture.database(scratch, { ["lib/shapes.tl"] = "--- Shapes.\nlocal record shapes\nend\n\n" ..
        "--- " .. word .. " words.\nfunction shapes.area(): integer\n  return 1\nend\n\nreturn shapes\n" })
    -- One file, whole, as a build's projection is.
    assert(db:exec("VACUUM INTO '" .. scratch .. "/whole.db'"))
    assert(db:close())
    assert(Fs.rename(scratch .. "/whole.db", projection))
  end
  built("First")
  local text = 'local shapes = require("lib.shapes")\nlocal _ = shapes.area\nreturn shapes\n'
  local ran = session_fixture.served_between(root, {
    { initialize(root), open(root, "main.tl", text), at(2, "textDocument/hover", root, "main.tl", 1, 18) },
    { at(3, "textDocument/hover", root, "main.tl", 1, 18) },
  }, function(_after: integer) built("Second") end, {})
  local first = assert(hovered(ran, 2), ran.err)
  assert(first:find("First words.", 1, true) ~= nil, first)
  local second = assert(hovered(ran, 3), ran.err)
  assert(second:find("Second words.", 1, true) ~= nil, second)
end

local function test_hover_counts_utf16_units_before_the_cursor()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  -- "😀" is four bytes and two UTF-16 units, "é" two bytes and one unit.
  local text = 'local F = require("cosmic.fs")\nlocal _ = { "😀", F.read }\nlocal _ = { "é", F.read }\n'
  local ran = served(root, { initialize(root), open(root, "main.tl", text),
    -- The `r` of `read`, and the space before `F`, after the surrogate pair.
    at(2, "textDocument/hover", root, "main.tl", 1, 20),
    at(3, "textDocument/hover", root, "main.tl", 1, 17),
    -- The `r` of `read` after the two-byte character.
    at(4, "textDocument/hover", root, "main.tl", 2, 19),
  }, { fs_docs(root) })
  local after_pair = assert(hovered(ran, 2), ran.err)
  assert(after_pair:find("cosmic.fs.read", 1, true) ~= nil, after_pair)
  assert(hovered(ran, 3) == nil, "the space before F, not F")
  local after_two = assert(hovered(ran, 4), ran.err)
  assert(after_two:find("cosmic.fs.read", 1, true) ~= nil, after_two)
end

local function test_formatting_answers_the_fixed_text()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root), open(root, "main.tl", "local   n =  1\nreturn n\n"),
    format(2, root, "main.tl"), open(root, "bad.tl", "local = \n"), format(3, root, "bad.tl") })
  local body = answer(ran, 2)
  local formatted = assert(FORMAT_SENT:decode_into(body))
  assert(#formatted.result == 1)
  assert(formatted.result[1].newText == "local n = 1\nreturn n\n", formatted.result[1].newText)
  assert(body:find('"end":{"character":0,"line":2}', 1, true), body)
  assert(failed(answer(ran, 3)) == -32803)
end

local function test_the_lifecycle_is_held_to()
  local root = session_fixture.project()
  local early = served(root, { at(5, "textDocument/hover", root, "main.tl", 0, 0), EXIT })
  assert(failed(answer(early, 5)) == -32002)
  assert(early.code == 1, "exit without shutdown")
  local unknown = served(root, { initialize(root), '{"jsonrpc":"2.0","id":6,"method":"nosuch"}',
    '{"jsonrpc":"2.0","method":"$/nosuch"}', "{not json", SHUTDOWN,
    at(7, "textDocument/hover", root, "main.tl", 0, 0) })
  assert(failed(answer(unknown, 6)) == -32601)
  assert(failed(answer(unknown, 7)) == -32600)
  assert(table.concat(unknown.sent, "\n"):find('"code":-32700', 1, true))
  local twice = served(root, { initialize(root), initialize(root) })
  local refusals = 0
  for _, body in ipairs(twice.sent) do
    local sent = sent_of(body)
    local why = sent.error
    if why ~= nil then
      assert(why.code == -32600, body)
      refusals = refusals + 1
    end
  end
  assert(#twice.sent == 2 and refusals == 1, "the second initialize is refused")
  assert(unknown.code == 0, "the stream ending after shutdown")
  local broken = served(root, { initialize(root) })
  assert(broken.code == 1, "the stream ending before shutdown")
end

local function test_a_session_over_a_loopback_connection()
  local root = session_fixture.project()
  local listener <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local address = listener.address
  local exchange: Exchange = { code = -1, sent = "" }
  Poll.run(function()
    Poll.spawn(function()
      local conn <close> = assert(listener:accept(Clock.seconds(10)))
      exchange.code = session.serve(session.new(root), conn, function(text: string): boolean, string
        return conn:write(text)
      end)
    end)
    local client <close> = assert(Net.connect(address, { timeout_ns = Clock.seconds(10) }))
    assert(client:write(framed({ initialize(root), SHUTDOWN, EXIT })))
    assert(client:shutdown("write"))
    exchange.sent = assert(Stream.read_all(client))
  end)
  assert(exchange.code == 0)
  local init = initialized(assert(bodies(exchange.sent)[1]))
  assert(init.serverInfo.name == "cosmic")
end

local function test_each_wrong_message_has_its_code()
  local root = session_fixture.project()
  local ran = served(root, { initialize(root),
    '{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":5}}',
    '{"jsonrpc":"2.0","id":3,"method":5}',
    "[1,2]",
    "{not json",
  })
  assert(failed(answer(ran, 2)) == -32602, "params that do not fit")
  local codes: {integer} = {}
  for _, body in ipairs(ran.sent) do
    local sent = sent_of(body)
    local why = sent.error
    if why ~= nil and sent.id == nil then codes[#codes + 1] = why.code end
  end
  assert(table.concat(codes, ",") == "-32600,-32600,-32700", table.concat(codes, ","))
end

local function test_a_lone_carriage_return_ends_a_line()
  local root = session_fixture.project()
  for _, ending in ipairs({ "\r", "\r\n", "\n" }) do
    local text = "local x = 1" .. ending .. 'local n: integer = "s"' .. ending .. "return n + x" .. ending
    local diagnostics = published(served(root, { initialize(root), open(root, "main.tl", text) }))[1]
    assert(#diagnostics == 1, messages_of(diagnostics))
    local start = diagnostics[1].range["start"]
    assert(start.line == 1 and start.character == 19, tostring(ending:byte()) .. ": " ..
        tostring(start.line) .. ":" .. tostring(start.character))
  end
end

local function test_changes_already_read_are_checked_once()
  local root = session_fixture.project()
  local runs = published(served(root, {
    initialize(root),
    open(root, "main.tl", "return 1\n"),
    change(root, "main.tl", "local n: integer = 'x'\nreturn n\n"),
    change(root, "main.tl", "local n: integer = 1\nreturn n\n"),
    close(root, "main.tl"),
  }))
  assert(#runs == 3, "the first change is not checked: " .. tostring(#runs))
  assert(#runs[2] == 0, messages_of(assert(runs[2])))
end

local function test_a_record_shape_is_resolved_as_a_build_does()
  local root = session_fixture.project()
  local text = 'local Shape = require("cosmic.shape")\n' ..
    "local record R\n  n: integer\nend\n" ..
    'local R_SHAPE <const> = Shape.record_of("R"); local bad: integer = "x"\n' ..
    "local r = assert(R_SHAPE:into({ n = 1 }))\nlocal n: integer = r.n\nreturn n + bad\n"
  local diagnostics = published(served(root, { initialize(root), open(root, "main.tl", text) }))[1]
  assert(#diagnostics == 1, messages_of(diagnostics))
  -- At `"x"` in the text as written, not as the build's rewrite moved it.
  local start = diagnostics[1].range["start"]
  assert(start.line == 4 and start.character == 67, tostring(start.line) .. ":" .. tostring(start.character))
  -- A module required is rewritten too.
  local module = text:gsub('; local bad: integer = "x"', "")
  assert(Fs.write(root .. "/shaped.tl", (module:gsub("n %+ bad", "r"))))
  local user = 'local shaped = require("shaped")\nlocal n: integer = shaped.n\nreturn n\n'
  local through = published(served(root, { initialize(root), open(root, "user.tl", user) }))[1]
  assert(#through == 0, messages_of(through))
  -- Every call is at the top: the copy with no function bodies finds them.
  local tally = served(root, { initialize(root), open(root, "main.tl", text) }).tally
  assert(tally.bodiless_splices == 1 and tally.whole_splices == 0,
    tostring(tally.bodiless_splices) .. "," .. tostring(tally.whole_splices))
end

local function test_a_test_file_is_not_warned_of_its_tests()
  local root = session_fixture.project()
  local text = "local function test_it() assert(true) end\n"
  local runs = published(served(root, { initialize(root), open(root, "it_test.tl", text),
    open(root, "it.tl", text) }))
  assert(#runs[1] == 0, messages_of(assert(runs[1])))
  assert(#runs[2] == 1, "a warning is published: " .. messages_of(assert(runs[2])))
  assert(runs[2][1].message:find("unused", 1, true), messages_of(assert(runs[2])))
end

local function test_a_global_is_published_as_refused()
  local root = session_fixture.project()
  local refused = only(nth(served(root, { initialize(root),
    open(root, "main.tl", "local n = 1\nglobal shared_count: integer = n\nreturn shared_count\n") }), 1))
  assert(refused.message:find("a global is not allowed in a cosmic build", 1, true), refused.message)
  local start = edge(refused, "start")
  assert(start.line == 1 and start.character == 0, tostring(start.line) .. ":" .. tostring(start.character))
end

local function test_a_test_file_that_returns_a_value_is_refused()
  local root = session_fixture.project()
  local text = "local function test_it() assert(true) end\nreturn {}\n"
  local refused = only(nth(served(root, { initialize(root), open(root, "it_test.tl", text) }), 1))
  assert(refused.message:find("a test file may not both define test_* functions and return", 1, true),
    refused.message)
  assert(edge(refused, "start").line == 1, "at its return")
end

local function test_a_refused_record_shape_is_published_at_its_call()
  local root = session_fixture.project()
  local text = 'local Shape = require("cosmic.shape")\nlocal record R\n  n: integer\nend\n' ..
    'local name = "R"\nlocal R_SHAPE <const> = Shape.record_of(name)\nreturn R_SHAPE\n'
  local refused = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
  assert(refused.message:find("the name must be a string literal", 1, true), refused.message)
  assert(edge(refused, "start").line == 5, tostring(edge(refused, "start").line))
end

local function test_a_column_after_a_surrogate_pair_counts_two_units()
  local root = session_fixture.project()
  -- "😀" is four bytes and two UTF-16 units; the error is at `nope`.
  local text = 'local _ = { "😀", nope }\n'
  local wide = only(nth(served(root, { initialize(root), open(root, "main.tl", text) }), 1))
  assert(edge(wide, "start").character == 18, tostring(edge(wide, "start").character))
  assert(edge(wide, "end").character == 22, tostring(edge(wide, "end").character))
  local narrow = only(nth(served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8"]}}'),
    open(root, "main.tl", text) }), 1))
  assert(edge(narrow, "start").character == 20, tostring(edge(narrow, "start").character))
end

local function test_hover_counts_bytes_when_utf8_is_negotiated()
  local root = assert(Fs.mkdtemp("cosmic-lsp-"))
  local text = 'local F = require("cosmic.fs")\nlocal _ = { "😀", F.read }\n'
  local ran = served(root, { initialize(root, '{"general":{"positionEncodings":["utf-8"]}}'),
    open(root, "main.tl", text),
    -- Byte 25 is the `d` of `read`; as UTF-16 units it would be the `}`.
    at(2, "textDocument/hover", root, "main.tl", 1, 25),
    -- Byte 19 is the space before `F`.
    at(3, "textDocument/hover", root, "main.tl", 1, 19),
  }, { fs_docs(root) })
  local value = assert(hovered(ran, 2), ran.err)
  assert(value:find("cosmic.fs.read", 1, true) ~= nil, value)
  assert(hovered(ran, 3) == nil, "the space before F")
end

local function test_the_last_of_several_changes_is_the_text()
  local root = session_fixture.project()
  local good, bad = "local n: integer = 1\nreturn n\n", "local n: integer = 'x'\nreturn n\n"
  local fixed = served(root, { initialize(root), open(root, "main.tl", bad), changes(root, "main.tl", { bad, good }) })
  assert(counts(fixed) == "1,0", counts(fixed))
  local broken = served(root, { initialize(root), open(root, "main.tl", good), changes(root, "main.tl", { good, bad }) })
  assert(counts(broken) == "0,1", counts(broken))
end

local function test_a_message_with_no_method_is_never_answered()
  local root = session_fixture.project()
  local responses: {string} = {
    '{"jsonrpc":"2.0","id":null,"result":null}',
    '{"jsonrpc":"2.0","id":5,"result":1}',
    '{"jsonrpc":"2.0","id":6,"error":{"code":-32601,"message":"no"}}',
    '{"jsonrpc":"2.0"}',
  }
  local before = served(root, responses)
  assert(#before.sent == 0, table.concat(before.sent, "\n"))
  local messages: {string} = { initialize(root) }
  for _, response in ipairs(responses) do messages[#messages + 1] = response end
  local after = served(root, messages)
  assert(#after.sent == 1, table.concat(after.sent, "\n"))
  initialized(assert(after.sent[1]))
end

local function test_an_example_that_returns_nothing_is_refused()
  local root = session_fixture.project()
  local text = "local Example = {}\n--- One.\nfunction Example.one()\n  assert(true)\nend\n"
  local refused = only(nth(served(root, { initialize(root), open(root, "it_example.tl", text) }), 1))
  assert(refused.message:find("an example file must return the table", 1, true), refused.message)
  local fine = served(root, { initialize(root), open(root, "it_example.tl", text .. "return Example\n") })
  assert(counts(fine) == "0", messages_of(nth(fine, 1)))
end

local function test_a_policy_outside_a_test_is_refused_and_nothing_else()
  local root = session_fixture.project()
  local text = 'local Test = require("cosmic.test")\nlocal unused = 1\n' ..
    'Test.policy { loopback = { "127.0.0.1" } }\nreturn {}\n'
  local refused = only(nth(served(root, { initialize(root), open(root, "it.tl", text) }), 1))
  assert(refused.message:find("only a test or example module declares what its tests read", 1, true),
    refused.message)
  assert(edge(refused, "start").line == 2, tostring(edge(refused, "start").line))
end

local function test_a_policy_the_build_refuses_is_all_a_test_publishes()
  local root = session_fixture.project()
  local text = 'local Test = require("cosmic.test")\nTest.policy { reads = {} }\n' ..
    "local function test_x() assert(true) end\n"
  local refused = only(nth(served(root, { initialize(root), open(root, "it_test.tl", text) }), 1))
  assert(refused.message:find("test.policy", 1, true), refused.message)
  assert(refused.message:find("unused", 1, true) == nil, refused.message)
end

local function test_a_message_is_worded_as_a_build_words_it()
  local root = session_fixture.project()
  local text = "local function f(a: integer): integer\n  local b = 1\n  return a\nend\nreturn f\n"
  local unused = only(nth(served(root, { initialize(root), open(root, "it.tl", text) }), 1))
  assert(unused.message:find("-- name it _ or _<name> to mark it intentionally unused", 1, true),
    unused.message)
  assert(unused.code == "unused", tostring(unused.code))
end

local function test_a_record_shape_in_a_function_body_is_resolved_too()
  local root = session_fixture.project()
  -- One call at the top, one in a body, after a tab and a two-byte "é".
  local text = 'local Shape = require("cosmic.shape")\n' ..
    "local record R\n  n: integer\nend\n" ..
    'local TOP <const> = Shape.record_of("R")\n' ..
    "local function f(): integer\n" ..
    '\tlocal _ = "é"; local S = Shape.record_of("R"); local bad: integer = "x"\n' ..
    "  return assert(S:into({ n = 1 })).n + bad\nend\n" ..
    "return { f = f, n = assert(TOP:into({ n = 2 })).n }\n"
  local ran = served(root, { initialize(root), open(root, "main.tl", text) })
  local found = only(nth(ran, 1))
  assert(found.message:find("got string", 1, true), found.message)
  -- One call is in a body: the whole text is read for them.
  assert(ran.tally.bodiless_splices == 0 and ran.tally.whole_splices == 1,
    tostring(ran.tally.bodiless_splices) .. "," .. tostring(ran.tally.whole_splices))
  -- At `"x"`, counted in UTF-16 units: the tab and "é" are one each.
  local start = edge(found, "start")
  assert(start.line == 6 and start.character == 69, tostring(start.line) .. ":" .. tostring(start.character))
end
