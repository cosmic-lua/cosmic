--- When `cosmic lsp` ([`build.lsp.session`]) checks again the open
--- documents that require one whose text changed ([`publish.dependents`]):
--- only where what that document serves them changed, and one at a time,
--- each only while no message waits.
---
--- What a module serves the modules that require it is its served form
--- ([`source.served`]: its stub, a template's Teal, or its source), whose
--- type is all a `require` of it reads. Its key ([`key_of`]) is
--- the form's tokens, which leaves out its comments and its whitespace: a
--- change that moves neither, such as an edit to a comment or to a
--- function's body, checks no dependent, and any change of a type moves
--- a token. A dependent's message that names a place in the module (a
--- type "inferred at" it) may then name the place as it was.
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
    --- The open documents, by URI, whose served form changed since their
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
  return { due = {}, waiting = {}, queued = {}, served = {}, keying = {}, checked = 0 }
end

--- What `document` serves the modules that require it, as tokens: ""
--- where it is no module the stage lists, which no `require` reads.
local function key_of(checker: check.Checker, document: check.Document): string
  local listed = source.module(checker.source, document.name)
  if listed == nil then return "" end
  local built = check.compiler(checker)
  local served = source.served(checker.source, built, listed.path, check.open_files(checker), true)
  if served == nil then return "" end
  local tokens, _ = built.lex(served.text, served.file)
  local parts: {string} = {}
  for _, token in ipairs(tokens) do parts[#parts + 1] = token.tk end
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

--- Forgets the document `uri`, closed.
function dependents.closed(q: Queue, uri: string)
  drop(q, uri)
  q.due[uri] = nil
  q.served[uri] = nil
  q.keying[uri] = nil
end

--- Keys what each document to key serves now, and finds which of those
--- that changed serve their dependents something else.
local function keyed(q: Queue, o: publish.Open)
  for uri, why in pairs(q.keying) do
    local document = o.documents[uri]
    if document ~= nil then
      local key = key_of(o.checker, document)
      if why == "change" and q.served[uri] ~= key then q.due[uri] = true end
      q.served[uri] = key
    end
  end
  q.keying = {}
end

--- Checks the next dependent, unless none is left to check or `waiting`
--- says a message waits. What each document opened or changed serves is
--- keyed first, then the dependents of each document due are found, in
--- order of URI.
function dependents.next(q: Queue, o: publish.Open, waiting: function(): boolean): dependents.Step
  local none: dependents.Step = { publications = {}, checked = false }
  if waiting() then return none end
  keyed(q, o)
  if next(q.due) ~= nil then
    local uris: {string} = {}
    for uri in pairs(q.due) do uris[#uris + 1] = uri end
    table.sort(uris)
    q.due = {}
    for _, uri in ipairs(uris) do
      local document = o.documents[uri]
      if document ~= nil then
        for _, found in ipairs(publish.dependents(o, document)) do
          if q.queued[found] == nil then
            q.queued[found] = true
            q.waiting[#q.waiting + 1] = found
          end
        end
      end
    end
  end
  while #q.waiting > 0 do
    local uri = table.remove(q.waiting, 1)
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
