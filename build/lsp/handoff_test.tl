--- A session of `cosmic lsp` holding its tool to the tree at each stage, and handed to the tool that replaces its process
--- ([`build.lsp.handoff`], [`build.lsp.session`]'s `reenter`): the check made before the messages that stage the tree
--- and no others, the open documents and the unanswered messages that go with the session, a failed rebuild that leaves
--- it serving, and the file the hand-over is written as. The check of the tool itself ([`reboot.recheck`]) is in
--- build/rebuild_lock_tool_test.tl.

local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local build_paths = require("build.paths")
local handoff = require("build.lsp.handoff")
local lsp = require("build.lsp")
local protocol = require("build.lsp.protocol")
local session_fixture = require("build.lsp.session_fixture")

Test.policy{}

local type Ran = session_fixture.Ran
local initialize, open, save, change = session_fixture.initialize, session_fixture.open, session_fixture.save,
  session_fixture.change
local EXIT, SHUTDOWN = session_fixture.EXIT, session_fixture.SHUTDOWN

--- A document with a type error in it, and one without.
local BAD <const> = 'local s = "x"\nlocal n: integer = s\nreturn n\n'
local GOOD <const> = 'local n: integer = 1\nreturn n\n'

--- What the checks of the tool saw: each session handed, in order.
local record Seen
  states: mut {handoff.Session}
end

--- A check that is made, finds the tool the tree's and so returns, `code` where a rebuild failed.
local function checking(seen: Seen, code?: integer): function(root: string, state: function(): handoff.Session): integer?
  return function(_root: string, state: function(): handoff.Session): integer?
    local handed = state()
    seen.states[#seen.states + 1] = handed
    return code
  end
end

local function shown_of(ran: Ran): {string}
  local out: mut {string} = {}
  for _, body in ipairs(ran.sent) do
    local sent = session_fixture.sent(body)
    if sent.method == "window/showMessage" then out[#out + 1] = body end
  end
  return out
end

--- The tool is held to the tree before the messages that stage it, once for each, and a change of a document, which
--- stages nothing, is not one.
local function test_the_tool_is_checked_before_each_message_that_stages_the_tree()
  local root = session_fixture.project()
  local seen: Seen = { states = {} }
  local ran = session_fixture.served_holding(root, {
    initialize(root), '{"jsonrpc":"2.0","method":"initialized","params":{}}',
    open(root, "main.tl", GOOD), change(root, "main.tl", BAD), change(root, "main.tl", GOOD),
    save(root, "main.tl"), SHUTDOWN, EXIT,
  }, checking(seen))
  assert(ran.code == 0, ran.err)
  -- `initialized`, the open and the save: not `initialize`, the changes, nor `shutdown`.
  assert(#seen.states == 3, tostring(#seen.states))
  local first, last = assert(seen.states[1]), assert(seen.states[3])
  assert(#first.documents == 0 and #last.documents == 1)
  assert(last.root == root and last.pid == sys.getpid())
end

--- The session handed over holds the root, the encoding, and every open document with the text the editor holds,
--- which is not the file's; the successor serves the message that was about to be handled, and then the rest, and
--- answers for the documents without being told them again.
local function test_a_session_handed_over_keeps_its_documents_and_the_message_it_had_not_answered()
  local root = session_fixture.project()
  assert(Fs.write(root .. "/main.tl", GOOD))
  local seen: Seen = { states = {} }
  local capabilities = '{"general":{"positionEncodings":["utf-8"]}}'
  local before = session_fixture.served_holding(root, {
    initialize(root, capabilities), open(root, "main.tl", GOOD), change(root, "main.tl", BAD),
    save(root, "main.tl"),
    session_fixture.at(7, "textDocument/hover", root, "main.tl", 1, 19), SHUTDOWN, EXIT,
  }, checking(seen))
  assert(before.code == 0, before.err)
  local state = assert(seen.states[2])
  assert(state.encoding == "utf-8" and #state.documents == 1)
  local document = assert(state.documents[1])
  assert(document.text == BAD, "the editor's text, not the file's")
  -- The save is the message the predecessor was about to handle, and the hover waits behind it.
  local frames = protocol.frames(Stream.from_string(state.input))
  local save_body = assert(frames:next())
  assert(session_fixture.sent(save_body).method == "textDocument/didSave", save_body)
  local hover_body = assert(frames:next())
  assert(session_fixture.sent(hover_body).id == 7, hover_body)
  -- The successor: no `initialize`, and the document's error is still found in the unsaved text.
  local after = session_fixture.served_holding(root, { SHUTDOWN, EXIT }, checking({ states = {} }), state)
  assert(after.code == 0, after.err)
  assert(session_fixture.counts(after) == "1", session_fixture.counts(after))
  assert(session_fixture.nth(after, 1)[1] ~= nil)
  session_fixture.answer(after, 7)
  assert(not after.err:find("initialize", 1, true), after.err)
  -- The first process answered the hover itself, since it was not replaced: once there, once here.
  session_fixture.answer(before, 7)
end

--- A rebuild that fails leaves the session serving as it was and the person told once, whatever the number of stages
--- it fails at.
local function test_a_failed_rebuild_leaves_the_session_serving_and_is_told_once()
  local root = session_fixture.project()
  local seen: Seen = { states = {} }
  local ran = session_fixture.served_holding(root, {
    initialize(root), open(root, "main.tl", BAD), save(root, "main.tl"), save(root, "main.tl"),
    session_fixture.at(9, "textDocument/hover", root, "main.tl", 1, 19), SHUTDOWN, EXIT,
  }, checking(seen, 3))
  assert(ran.code == 0, ran.err)
  assert(#seen.states == 3, "the check is made again at each stage: " .. tostring(#seen.states))
  local shown = shown_of(ran)
  assert(#shown == 1, table.concat(shown, "\n"))
  assert(assert(shown[1]):find("could not be rebuilt", 1, true), shown[1])
  -- Still answering, and still publishing.
  session_fixture.answer(ran, 9)
  assert(#session_fixture.published(ran) >= 1)
end

--- The directory the files of the tree `launch` are in.
local function directory_of(launch: string): string
  return (assert(build_paths.directory(launch)))
end

--- The session a test hands over.
local function session_of(root: string, pid: integer): handoff.Session
  return { version = handoff.version(), pid = pid, nonce = "", root = root, encoding = "utf-16", watch = true,
    snippets = false, lazy = true, told_outside = false,
    documents = { { uri = "file://" .. root .. "/a.tl", text = "é\n" } }, input = protocol.frame('{"a":1}') }
end

--- A session is written for the exec that is to follow, under a nonce its successor is told, and read once, by that
--- successor alone: the file is gone as it is read, and one of another version or with no absolute root is refused.
local function test_a_handoff_is_read_once_and_only_as_written()
  local launch = session_fixture.project()
  local pid = sys.getpid()
  local nonce = assert(handoff.nonce())
  assert(handoff.put(launch, nonce, session_of(launch, pid)))
  local taken, trouble = handoff.take(launch, nonce)
  assert(taken ~= nil, trouble)
  assert(taken.root == launch and taken.watch and taken.lazy and not taken.snippets and taken.nonce == nonce)
  assert(assert(taken.documents[1]).text == "é\n" and taken.input == protocol.frame('{"a":1}'))
  local again, again_trouble = handoff.take(launch, nonce)
  assert(again == nil and again_trouble == "", "a handoff is read twice")

  local old = session_of(launch, pid)
  local newer: handoff.Session = { version = handoff.version() + 1, pid = old.pid, nonce = "", root = old.root,
    encoding = old.encoding, watch = false, snippets = false, lazy = false, told_outside = false, documents = {},
    input = "" }
  assert(handoff.put(launch, nonce, newer))
  local refused, why = handoff.take(launch, nonce)
  assert(refused == nil and why:find("version", 1, true) ~= nil, why)

  local loose = session_of("relative", pid)
  assert(handoff.put(launch, nonce, loose))
  local relative, relative_why = handoff.take(launch, nonce)
  assert(relative == nil and relative_why:find("absolute", 1, true) ~= nil, relative_why)

  assert(handoff.put(launch, nonce, old))
  handoff.drop(launch, nonce)
  local dropped, dropped_why = handoff.take(launch, nonce)
  assert(dropped == nil and dropped_why == "", "a handoff dropped was read")
end

--- A file a process of this pid left, dying between its write and its exec, is no handoff to a process that was not
--- told its nonce, whether it was told none or another: it is refused, and removed unread, since it holds an editor's
--- unsaved text.
local function test_a_file_left_at_this_pid_is_refused_and_removed()
  local launch = session_fixture.project()
  local directory = directory_of(launch)
  local pid = sys.getpid()
  local left = assert(handoff.nonce())
  assert(handoff.put(launch, left, session_of(launch, pid)))
  local file = directory .. "/lsp-handoff-" .. tostring(pid) .. "-" .. left .. ".json"
  assert(Fs.exists(file) == true)
  local none, none_why = handoff.take(launch, nil)
  assert(none == nil and none_why == "", "a file was taken with no nonce")
  assert(Fs.exists(file) == false, "the file was left")
  assert(handoff.put(launch, left, session_of(launch, pid)))
  local other, other_why = handoff.take(launch, (assert(handoff.nonce())))
  assert(other == nil and other_why == "", "a file was taken under another nonce")
  assert(Fs.exists(file) == false, "the file was left")
end

--- A write removes the files of a process that is gone, and leaves those of one that is not.
local function test_a_put_sweeps_the_files_of_dead_processes()
  local launch = session_fixture.project()
  local directory = directory_of(launch)
  local dead = directory .. "/lsp-handoff-4194303-abcd.json"
  local alive = directory .. "/lsp-handoff-1-abcd.json"
  assert(Fs.write(dead, "{}"))
  assert(Fs.write(alive, "{}"))
  local nonce = assert(handoff.nonce())
  assert(handoff.put(launch, nonce, session_of(launch, sys.getpid())))
  assert(Fs.exists(dead) == false, "a dead process's file was left")
  assert(Fs.exists(alive) == true, "a live process's file was removed")
  handoff.drop(launch, nonce)
  local _, _ = Fs.remove(alive)
end

--- The session is built and written only where the process is to be replaced, just before the exec, with a nonce
--- handed on; a process that was not replaced removes its file. A process a reboot entered is let rebuild again once
--- its first check has returned, not before, so a rebuild that never converges is refused at the first message it was
--- handed (the check answers stale) and cannot replace the process in a loop.
local function test_the_session_is_written_only_for_an_exec_and_the_entry_released_after_the_first_check()
  local launch = session_fixture.project()
  local log: mut {string} = {}
  local built = 0
  local function state(): handoff.Session
    built = built + 1
    return session_of(launch, sys.getpid())
  end
  local nonces: mut {string} = {}
  local function recheck(_root: string, before_enter: function(): {string:string}?, string): integer?
    log[#log + 1] = "recheck"
    -- A check that finds the tool fresh never asks.
    if #log == 1 then return 3 end
    local env, why = before_enter()
    assert(env ~= nil, why)
    local given = assert(env["COSMIC_LSP_HANDOFF"])
    nonces[#nonces + 1] = given
    local file = directory_of(launch) .. "/lsp-handoff-" .. tostring(sys.getpid()) .. "-" .. assert(nonces[1]) .. ".json"
    assert(Fs.exists(file) == true, "nothing was written for the exec")
    -- The exec failed, as it returns only then.
    return 3
  end
  local function release() log[#log + 1] = "release" end
  local holding = lsp.reentry(launch, recheck, release, function(_root: string): boolean
    return true
  end)
  assert(holding("/x", state) == 3)
  assert(built == 0, "the session was built for a check that found nothing to replace")
  assert(table.concat(log, ",") == "recheck,release", table.concat(log, ","))
  assert(holding("/x", state) == 3)
  assert(built == 1 and table.concat(log, ",") == "recheck,release,recheck", table.concat(log, ","))
  local file = directory_of(launch) .. "/lsp-handoff-" .. tostring(sys.getpid()) .. "-" .. assert(nonces[1]) .. ".json"
  assert(Fs.exists(file) == false, "a process that was not replaced left its file")
  local first = assert(nonces[1])
  assert(first:match("^%x+$") ~= nil and #first >= 16)
  -- A tree that is not cosmic's own has nothing to check.
  local foreign = lsp.reentry(launch, recheck, release, function(_root: string): boolean
    return false
  end)
  assert(foreign("/x", state) == nil)
end
