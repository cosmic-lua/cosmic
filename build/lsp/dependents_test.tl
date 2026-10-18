--- When `cosmic lsp` checks again the open documents that require one
--- whose text changed ([`build.lsp.dependents`]): only where what it
--- serves them changed, after its own diagnostics are published, and one
--- at a time, a message that arrives meanwhile answered before the rest.

local Fs = require("cosmic.fs")
local session_fixture = require("build.lsp.session_fixture")

local at, change, initialize = session_fixture.at, session_fixture.change, session_fixture.initialize
local open, project, publications = session_fixture.open, session_fixture.project, session_fixture.publications
local sent_of, served = session_fixture.sent, session_fixture.served
local served_between = session_fixture.served_between

local integer = "local function twice(n: integer): integer return n * 2 end\nreturn { twice = twice }\n"
local text = "local function twice(n: integer): string return tostring(n * 2) end\n" ..
  "return { twice = twice }\n"

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
local function opened(root: string, names: {string}): {string}
  local out: {string} = { initialize(root), open(root, "helper.tl", integer) }
  for _, name in ipairs(names) do
    out[#out + 1] = open(root, name .. ".tl", (assert(Fs.read(root .. "/" .. name .. ".tl"))))
  end
  return out
end

--- Each batch the editor sends with time between: what a document serves
--- is keyed once no message waits.
local function test_a_change_to_a_comment_or_a_space_checks_no_dependent()
  local root = helped({ "main" })
  local batches: {{string}} = { opened(root, { "main" }),
    { change(root, "helper.tl", "-- Twice.\n" .. integer) },
    { change(root, "helper.tl", "-- Twice.\n\n" .. integer:gsub(" n %* 2", "  n  *  2")) } }
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
  asked: boolean
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
  local ran = session_fixture.served_arriving(root, messages, function(checked: integer): string | nil
    if checked < 1 or held.asked then return nil end
    held.asked = true
    return at(7, "textDocument/hover", root, "a.tl", 0, 0)
  end)
  assert(ran.dependents == 3, tostring(ran.dependents))
  local order: {string} = {}
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
