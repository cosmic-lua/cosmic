--- When `cosmic lsp` checks again the open documents that require one
--- whose text changed or that closed ([`build.lsp.dependents`]): only
--- where what it serves them changed, a token or where one is, after its
--- own diagnostics are published, and one at a time, each once, a message
--- that arrives meanwhile answered before the rest.

local Fs = require("cosmic.fs")
local session_fixture = require("build.lsp.session_fixture")

local at, change, initialize = session_fixture.at, session_fixture.change, session_fixture.initialize
local open, project, publications = session_fixture.open, session_fixture.project, session_fixture.publications
local sent_of, served = session_fixture.sent, session_fixture.served
local served_between = session_fixture.served_between

local integer = "local record helper\nend\n\nfunction helper.twice(n: integer): integer\n  return n * 2\nend\n\nreturn helper\n"
local text = "local record helper\nend\n\nfunction helper.twice(n: integer): string\n  return tostring(n * 2)\nend\n\n" ..
  "return helper\n"

--- A project whose `helper` the modules `names` require, each on disk.
local function helped(names: {string}): string
  local root = project()
  assert(Fs.write(root .. "/helper.tl", integer))
  for _, name in ipairs(names) do
    assert(Fs.write(root .. "/" .. name .. ".tl",
      'local helper = require("helper")\nlocal n: integer = helper.twice(2)\nreturn n\n'))
  end
  return root
end

--- The messages that open `names` below `root` as they are on disk.
local function opened(root: string, names: {string}): mut {string}
  local out: mut {string} = { initialize(root), open(root, "helper.tl", integer) }
  for _, name in ipairs(names) do
    out[#out + 1] = open(root, name .. ".tl", (assert(Fs.read(root .. "/" .. name .. ".tl"))))
  end
  return out
end

--- What main is told, opened, checked against the helper returning a
--- string, then against the helper as on disk.
local CHECKED_AGAIN <const> = "[][`helper.twice(2)` is `string`, where `integer` is wanted as the value of `n` " ..
  "(not_assignable): pass a value of type `integer`, or change the declaration to `string`][]"

--- What `ran` told main at each of its publications.
local function told_main(ran: session_fixture.Ran): string
  local told = ""
  for _, publication in ipairs(publications(ran)) do
    if publication.uri:sub(-8) == "/main.tl" then
      told = told .. "[" .. session_fixture.messages_of(publication.diagnostics) .. "]"
    end
  end
  return told
end

--- A comment or a space that moves no token checks no dependent. Each
--- batch the editor sends with time between: what a document serves is
--- keyed once no message waits.
local function test_a_change_to_a_comment_or_a_space_checks_no_dependent()
  local root = helped({ "main" })
  local batches: mut {{string}} = { opened(root, { "main" }),
    { change(root, "helper.tl", integer .. "-- Twice.\n") },
    { change(root, "helper.tl", integer:gsub("\n", "  \n") .. "-- Doubled.\n\n") } }
  local function between(_after: integer) end
  local quiet = served_between(root, batches, between)
  assert(quiet.dependents == 0, tostring(quiet.dependents))
  batches[#batches + 1] = { change(root, "helper.tl", text) }
  local typed = served_between(root, batches, between)
  assert(typed.dependents == 1, tostring(typed.dependents))
  local last = assert(publications(typed)[#publications(typed)])
  assert(last.uri:sub(-8) == "/main.tl" and #last.diagnostics == 1, last.uri)
  -- A change read with the open, before what it served was keyed, is
  -- taken to change what it serves.
  local together = served(root, { initialize(root), open(root, "helper.tl", integer),
    open(root, "main.tl", (assert(Fs.read(root .. "/main.tl")))), change(root, "helper.tl", "-- Twice.\n" .. integer) })
  assert(together.dependents == 1, tostring(together.dependents))
end

--- Whether the request was sent.
local record Asked
  mut asked: boolean
end

--- The changed document's diagnostics are published before any of its
--- dependents is checked, and a request that arrives while they are is
--- answered before the dependents left.
local function test_a_request_is_answered_before_the_dependents_left()
  local names = { "a", "b", "c" }
  local root = helped(names)
  local messages = opened(root, names)
  messages[#messages + 1] = change(root, "helper.tl", text)
  local held: Asked = { asked = false }
  local ran = session_fixture.served_arriving(root, messages, function(checked: integer): string?
    if checked < 1 or held.asked then return nil end
    held.asked = true
    return at(7, "textDocument/hover", root, "a.tl", 0, 0)
  end)
  assert(ran.dependents == 3, tostring(ran.dependents))
  local order: mut {string} = {}
  for i, body in ipairs(ran.sent) do
    local sent = sent_of(body)
    if sent.id == 7 then
      order[#order + 1] = "answer@" .. tostring(ran.checked[i])
    elseif sent.method == "textDocument/publishDiagnostics" then
      local uri = body:match('"uri":"[^"]*/([%w_]+)%.tl"') or "?"
      order[#order + 1] = uri .. "@" .. tostring(ran.checked[i])
    end
  end
  -- The opens, then helper's change with no dependent checked yet, a,
  -- the answer, and the dependents left.
  assert(table.concat(order, " ") == "helper@0 a@0 b@0 c@0 helper@0 a@1 answer@1 b@2 c@3",
    table.concat(order, " "))
end

--- A change, then its undoing read with the close of the changed
--- document (an editor's revert and close): the dependent checked
--- against the change is checked again against the file on disk.
local function test_a_change_reverted_as_it_closes_checks_its_dependents_again()
  local root = helped({ "main" })
  local function between(_after: integer) end
  local ran = served_between(root, { opened(root, { "main" }),
    { change(root, "helper.tl", text) },
    { change(root, "helper.tl", integer), session_fixture.close(root, "helper.tl") } }, between)
  assert(told_main(ran) == CHECKED_AGAIN, told_main(ran))
end

--- An edit that moves where a module's types are, and nothing else,
--- checks its dependents again, and what they are told is what a session
--- started after the edit tells them. (No message of the checker names a
--- place in another module today, so what is told is the same; the key
--- of what a module serves still holds the place of each token.)
local function test_an_edit_that_moves_a_type_checks_its_dependents_again()
  local root = project()
  local main = 'local h = require("helper")\nlocal s: string = h.twice(2)\nreturn s\n'
  assert(Fs.write(root .. "/helper.tl", integer))
  assert(Fs.write(root .. "/main.tl", main))
  local function between(_after: integer) end
  local start = { initialize(root), open(root, "helper.tl", integer), open(root, "main.tl", main) }
  local moved = served_between(root, { start, { change(root, "helper.tl", "\n\n" .. integer) } }, between)
  local fresh = served(root, { initialize(root), open(root, "helper.tl", "\n\n" .. integer),
    open(root, "main.tl", main) })
  local function last_of_main(ran: session_fixture.Ran): string
    local told = ""
    for _, publication in ipairs(publications(ran)) do
      if publication.uri:sub(-8) == "/main.tl" then
        told = session_fixture.messages_of(publication.diagnostics)
      end
    end
    return told
  end
  local wrong = "`h.twice(2)` is `integer`, where `string` is wanted as the value of `s` (not_assignable): " ..
    "pass a value of type `string`, or change the declaration to `integer`"
  assert(last_of_main(served(root, start)) == wrong, last_of_main(served(root, start)))
  assert(moved.dependents == 1, tostring(moved.dependents))
  assert(last_of_main(moved) == wrong and last_of_main(fresh) == wrong,
    last_of_main(moved) .. " | " .. last_of_main(fresh))
end

--- A dependent of two documents changed together is checked once.
local function test_a_dependent_of_two_changed_documents_is_checked_once()
  local root = helped({})
  assert(Fs.write(root .. "/other.tl", integer))
  local main = 'local helper = require("helper")\nlocal other = require("other")\n' ..
    'local n: integer = helper.twice(other.twice(2))\nreturn n\n'
  assert(Fs.write(root .. "/main.tl", main))
  local function between(_after: integer) end
  local ran = served_between(root, { { initialize(root), open(root, "helper.tl", integer),
    open(root, "other.tl", integer), open(root, "main.tl", main) },
    { change(root, "helper.tl", text), change(root, "other.tl", text) } }, between)
  assert(ran.dependents == 1, tostring(ran.dependents))
  local last = assert(publications(ran)[#publications(ran)])
  assert(last.uri:sub(-8) == "/main.tl" and #last.diagnostics > 0, last.uri)
end

--- Closing a document whose text is its file's checks no dependent:
--- what its file serves once it is closed is what it served open.
local function test_closing_an_unchanged_document_checks_no_dependent()
  local root = helped({ "main" })
  local function between(_after: integer) end
  local ran = served_between(root, { opened(root, { "main" }),
    { session_fixture.close(root, "helper.tl") } }, between)
  assert(ran.dependents == 0, tostring(ran.dependents))
  assert(ran.checks["main.tl"] == 1, tostring(ran.checks["main.tl"]))
end

--- A document opened with another text than its file's and closed in
--- the same batch, before what it served was keyed: a dependent checked
--- against it meanwhile is checked again against the file.
local function test_a_document_opened_and_closed_together_checks_its_dependents_again()
  local root = helped({ "main" })
  local main = assert(Fs.read(root .. "/main.tl"))
  local function between(_after: integer) end
  local ran = served_between(root, { { initialize(root), open(root, "main.tl", main) },
    { open(root, "helper.tl", text), change(root, "main.tl", main), session_fixture.close(root, "helper.tl") } },
    between)
  assert(told_main(ran) == CHECKED_AGAIN, told_main(ran))
end

--- Closing a document whose text is not its file's checks each of its
--- dependents once, against the file: one at a time where only its type
--- changed, and with every other open document where its requires did.
local function test_closing_a_changed_document_checks_each_dependent_once()
  local root = helped({ "main" })
  assert(Fs.write(root .. "/other.tl", integer))
  local requiring = 'local other = require("other")\nlocal record helper\nend\n\n' ..
    "function helper.twice(n: integer): string\n  return tostring(other.twice(n))\nend\n\nreturn helper\n"
  local function between(_after: integer) end
  for changed_text, queued in pairs({ [text] = 1, [requiring] = 0 }) do
    local start, change_it = opened(root, { "main" }), { change(root, "helper.tl", changed_text) }
    local changed = served_between(root, { start, change_it }, between)
    local closed = served_between(root, { start, change_it, { session_fixture.close(root, "helper.tl") } },
      between)
    local before, after = changed.checks["main.tl"] or 0, closed.checks["main.tl"] or 0
    assert(after - before == 1, tostring(before) .. " then " .. tostring(after))
    assert(closed.dependents - changed.dependents == queued, tostring(closed.dependents))
    assert(told_main(closed) == CHECKED_AGAIN, told_main(closed))
  end
end
