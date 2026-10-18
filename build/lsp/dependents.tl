--- When `cosmic lsp` ([`build.lsp.session`]) checks again the open
--- documents that require one whose text changed ([`publish.dependents`]):
--- only where what that document serves them changed, and one at a time,
--- each only while no message waits.
---
--- What a module serves the modules that require it is its served form
--- ([`source.served`]: its stub, a template's Teal, or its source), whose
--- type is all a `require` of it reads. Its key ([`key_of`]) is
--- the form's tokens and where each is, which leaves out its comments
--- and its whitespace but where they move a token: an edit that moves
--- none, such as one to a comment's words or to the spaces ending a
--- line, checks no dependent, and any change of a type changes a token.
--- A dependent's message that names a place in the module (a type
--- "inferred at" it) is checked again once the place moves.
---
--- What the dependents were last checked against is what was keyed of
--- the module, by its file: closing a document compares that with what
--- the module serves once closed, its stage's form, and so a change and
--- the close that reverts it, read together, still check the dependents
--- that were checked against the change.
---
--- An editor typing sends a change at each key, and a dependent can take
--- seconds to check: so a dependent is checked only while no message is
--- read and waiting, nor has arrived to be read ([`protocol.Frames`]'s
--- `waiting`), and those left are checked once that message is answered.

local Hash = require("cosmic.hash")
local check = require("build.lsp.check")
local publish = require("build.lsp.publish")
local source = require("build.lsp.source")

local record dependents
  --- One session's dependents yet to check.
  record Queue
    --- The files, by name, whose served form changed since their
    --- dependents were found.
    due: {string:boolean}
    --- The dependents found, by URI, in the order they are checked, and
    --- the set of them.
    waiting: {string}
    queued: {string:boolean}
    --- The key of what each open document served when last keyed, by
    --- URI, and the documents to key yet, by URI: "open" for one just
    --- opened, "change" for one whose text changed since.
    served: {string:string}
    keying: {string:string}
    --- The files of the documents closed, by name, and the key their
    --- dependents were last checked against: "?", which no key is, where
    --- that is not known.
    closing: {string:string}
    --- How many dependents were checked, all told: what a test reads.
    checked: integer
  end

  --- What one step of [`dependents.next`] did: the publications of the
  --- dependent it checked, and whether it checked one.
  record Step
    publications: {string}
    checked: boolean
  end
end

local type Queue = dependents.Queue

--- A session's queue, with nothing due.
function dependents.new(): Queue
  return { due = {}, waiting = {}, queued = {}, served = {}, keying = {}, closing = {}, checked = 0 }
end

--- What the file `name` serves the modules that require it now, as its
--- tokens and their places: "" where it is no module the stage lists,
--- which no `require` reads.
local function key_of(checker: check.Checker, name: string): string
  local listed = source.module(checker.source, name)
  if listed == nil then return "" end
  local built = check.compiler(checker)
  local served = source.served(checker.source, built, listed.path, check.open_files(checker), true)
  if served == nil then return "" end
  local tokens, _ = built.lex(served.text, served.file)
  local parts: {string} = {}
  for _, token in ipairs(tokens) do
    parts[#parts + 1] = tostring(token.y) .. ":" .. tostring(token.x) .. " " .. token.tk
  end
  return Hash.hex_sha256(table.concat(parts, "\0"))
end

--- Takes `uri` out of the dependents to check: its document was just
--- checked as it stands.
local function drop(q: Queue, uri: string)
  if q.queued[uri] == nil then return end
  q.queued[uri] = nil
  for i, waiting in ipairs(q.waiting) do
    if waiting == uri then
      table.remove(q.waiting, i)
      return
    end
  end
end

--- Notes that `document` was just opened and checked: what it serves is
--- keyed once its diagnostics are out ([`dependents.next`]).
function dependents.opened(q: Queue, document: check.Document)
  drop(q, document.uri)
  q.keying[document.uri] = "open"
end

--- Notes that `document`'s text changed, just checked: its dependents are
--- due where what it serves changed, as is found once its diagnostics are
--- out ([`dependents.next`]); and where what it served before was never
--- keyed, as a change read right after the open finds it.
function dependents.changed(q: Queue, document: check.Document)
  drop(q, document.uri)
  q.keying[document.uri] = "change"
end

--- Notes that the document `document` is closing, before the close is
--- checked: its dependents are due where what its file serves now is
--- not what they were last checked against, as is found once the close
--- is answered ([`dependents.next`]); but not where the close checks
--- every other open document again ([`check.regraphs`]).
function dependents.closed(q: Queue, checker: check.Checker, document: check.Document)
  local uri = document.uri
  drop(q, uri)
  if q.due[document.name] == nil and not check.regraphs(checker, document) then
    q.closing[document.name] = q.served[uri] or "?"
  end
  q.served[uri] = nil
  q.keying[uri] = nil
end

--- Keys what each document to key serves now, and finds which of those
--- that changed, or were closed, serve their dependents something else.
local function keyed(q: Queue, o: publish.Open)
  for name, before in pairs(q.closing) do
    if key_of(o.checker, name) ~= before then q.due[name] = true end
  end
  q.closing = {}
  for uri, why in pairs(q.keying) do
    local document = o.documents[uri]
    if document ~= nil then
      local key = key_of(o.checker, document.name)
      if why == "change" and q.served[uri] ~= key then q.due[document.name] = true end
      q.served[uri] = key
    end
  end
  q.keying = {}
end

--- Checks the next dependent, unless none is left to check or `waiting`
--- says a message waits. What each document opened or changed serves is
--- keyed first, then the dependents of each file due are found, in
--- order of name.
function dependents.next(q: Queue, o: publish.Open, waiting: function(): boolean): dependents.Step
  local none: dependents.Step = { publications = {}, checked = false }
  if waiting() then return none end
  keyed(q, o)
  if next(q.due) ~= nil then
    local names: {string} = {}
    for name in pairs(q.due) do names[#names + 1] = name end
    table.sort(names)
    q.due = {}
    for _, name in ipairs(names) do
      for _, found in ipairs(publish.dependents(o, name)) do
        if q.queued[found] == nil then
          q.queued[found] = true
          q.waiting[#q.waiting + 1] = found
        end
      end
    end
  end
  while #q.waiting > 0 do
    local uri = assert(table.remove(q.waiting, 1))
    q.queued[uri] = nil
    local document = o.documents[uri]
    if document ~= nil then
      q.checked = q.checked + 1
      return { publications = publish.again(o, document), checked = true }
    end
  end
  return none
end

return dependents
