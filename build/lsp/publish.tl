--- What one session of `cosmic lsp` ([`build.lsp.session`]) publishes of
--- its open documents, and when: a document's diagnostics as it is
--- opened or changed ([`build.lsp.check`]), and those of the other open
--- documents whose diagnostics that may change, each published again
--- only where it changed.
---
--- - A save, or a change on disk the editor reports, stages the tree
---   again and checks every open document again.
--- - A check that finds a document requiring other modules than before
---   checks every other open document again, which a cycle of imports
---   may now reach ([`check.moved`]); so does closing a document that
---   stood for its file with another text than the stage's.
--- - A change of what a module serves the modules that require it, by an
---   edit or by closing its document, checks again the open documents
---   that require it, or require one that does ([`graph.dependents`]), one
---   at a time ([`build.lsp.dependents`]).

local check = require("build.lsp.check")
local graph = require("build.lsp.graph")
local protocol = require("build.lsp.protocol")

local record publish
  --- One session's open documents, by URI, its checker, and the units a
  --- position's character counts.
  record Open
    checker: check.Checker
    documents: {string:check.Document}
    encoding: string
  end
end

local type Open = publish.Open

--- The publication of `document`'s diagnostics.
local function one(o: Open, document: check.Document): string
  return protocol.publication(document.uri, check.diagnose(o.checker, document, o.encoding))
end

--- The publications of each of `documents` whose diagnostics changed
--- since it last published them, in the order given.
local function changed(o: Open, documents: {check.Document}): {string}
  local out: {string} = {}
  for _, document in ipairs(documents) do
    local before = document.published
    local now = check.diagnose(o.checker, document, o.encoding)
    if before == nil or table.concat(now, ",") ~= table.concat(before, ",") then
      out[#out + 1] = protocol.publication(document.uri, now)
    end
  end
  return out
end

--- Every open document but `except`, by URI.
local function others(o: Open, except: check.Document | nil): {check.Document}
  local uris: {string} = {}
  for uri, document in pairs(o.documents) do
    if document ~= except then uris[#uris + 1] = uri end
  end
  table.sort(uris)
  local out: {check.Document} = {}
  for _, uri in ipairs(uris) do
    local document = o.documents[uri]
    if document ~= nil then out[#out + 1] = document end
  end
  return out
end

--- Stages the tree again, then publishes each open document's
--- diagnostics that changed: a document may require a file saved or
--- changed on disk.
function publish.restaged(o: Open): {string}
  check.stale(o.checker)
  return changed(o, others(o, nil))
end

--- The publication of `document`'s diagnostics, then, where its check
--- found it requiring other modules than before, those of every other
--- open document that changed.
function publish.with(o: Open, document: check.Document): {string}
  local out: {string} = { one(o, document) }
  if not check.moved(o.checker) then return out end
  for _, publication in ipairs(changed(o, others(o, document))) do out[#out + 1] = publication end
  check.moved(o.checker)
  return out
end

--- What closing `document`, no longer among the open documents,
--- publishes: its diagnostics cleared, then, where it stood for its file
--- with another text or other requires than the stage's, those of every
--- other open document that changed.
function publish.closed(o: Open, document: check.Document): {string}
  check.closed(o.checker, document)
  local cleared: {string} = {}
  local out: {string} = { protocol.publication(document.uri, cleared) }
  if not check.moved(o.checker) then return out end
  for _, publication in ipairs(changed(o, others(o, nil))) do out[#out + 1] = publication end
  check.moved(o.checker)
  return out
end

--- The open documents but the file `name` that require its module, or
--- require one that does, and so on ([`graph.dependents`]), by URI, in
--- order: those whose diagnostics may change with what it serves.
function publish.dependents(o: Open, name: string): {string}
  local open = o.checker.open
  local opened: {string:{string}} = {}
  for file, other in pairs(open) do opened[file] = other.requires end
  local out: {string} = {}
  for _, file in ipairs(graph.dependents(o.checker.source, name, opened)) do
    local other = open[file]
    if other ~= nil and file ~= name then out[#out + 1] = other.uri end
  end
  return out
end

--- The publication of `document`'s diagnostics where they changed since
--- it last published them: one dependent checked again.
function publish.again(o: Open, document: check.Document): {string}
  return changed(o, { document })
end

return publish
