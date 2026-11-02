--- A session of `cosmic lsp` ([`build.lsp.session`]) handed to the tool that
--- replaces its process, when the tree outdates the tool while the editor
--- is connected ([`reboot.recheck`]).
---
--- The new process is the process again (`exec` keeps the process id and
--- the standard descriptors), so the editor's stream is the same pipe, and
--- what is read of it already and not yet answered is the handoff's
--- `input`. What the new process needs besides is the session's: its
--- root, the encoding negotiated and the editor's capabilities that the
--- answers read (`watch`, `snippets`, `lazy`), whether the person was told
--- of a root that is none already, and the open documents, each by URI and
--- the text the editor holds. A document has no version here: the session
--- keeps none.
---
--- The file is `lsp-handoff-<pid>.json` in the build directory of the
--- tree the process was started in, version 1: a reader refuses a file
--- of another version, of another process, or one whose `root` is not
--- absolute, and takes the file away when it reads it, so nothing is
--- entered by it twice. It is written whole before the process is
--- replaced, and removed again where the check did not replace it. Only a
--- process that a reboot entered ([`reboot.entered`]) is to ask for one
--- ([`build.lsp`]): a file a process of the same id left behind is no
--- handoff to one that nothing entered.

local Json = require("cosmic.json")
local Fs = require("cosmic.fs")
local Shape = require("cosmic.shape")
local sys = require("cosmic.sys")
local build_paths = require("build.paths")

local record handoff
  --- One open document: the text the editor holds of it.
  record Document
    uri: string
    text: string
  end

  --- What a session leaves its successor.
  record Session
    version: integer
    --- The process id, which the successor shares.
    pid: integer
    root: string
    encoding: string
    watch: boolean
    snippets: boolean
    lazy: boolean
    told_outside: boolean
    documents: {Document}
    --- The messages read and not answered, framed, to be read before
    --- the stream goes on.
    input: string
  end
end

--- The version of the file's layout.
local VERSION <const> = 1

--- The version a session is written as.
function handoff.version(): integer
  return VERSION
end

local SESSION <const>: Shape.Typed<handoff.Session> = Shape.record_of("handoff.Session")

--- The file of the process `pid` below `launch`, the tree it was started
--- in, or nil and why it can have none.
local function path_of(launch: string, pid: integer): string?, string
  local directory, trouble = build_paths.directory(launch)
  if directory == nil then return nil, trouble end
  return directory .. "/lsp-handoff-" .. tostring(pid) .. ".json", ""
end

--- Writes `session` for the successor of this process, started in the
--- tree `launch`. False and why where it cannot be: the caller does not
--- replace its process then.
function handoff.put(launch: string, session: handoff.Session): boolean, string
  local path, path_trouble = path_of(launch, session.pid)
  if path == nil then return false, path_trouble end
  local text, encode_trouble = Json.encode_any(session)
  if text == nil then return false, encode_trouble end
  return Fs.write(path, text, 0x180)
end

--- Removes the file `put` wrote for this process: the process was not
--- replaced.
function handoff.drop(launch: string)
  local path, _ = path_of(launch, sys.getpid())
  if path ~= nil then
    local _, _ = Fs.remove(path)
  end
end

--- The session this process was entered with, started in the tree
--- `launch`; nil and "" where none was left for it. The caller asks only
--- where a reboot entered this process. The file is removed
--- as it is read. Nil and why where one was left and cannot be taken: the
--- stream it holds the start of is then lost, and the process ends.
function handoff.take(launch: string): handoff.Session?, string
  local path, path_trouble = path_of(launch, sys.getpid())
  if path == nil then return nil, path_trouble end
  local text, _ = Fs.read(path)
  if text == nil then return nil, "" end
  local _, _ = Fs.remove(path)
  local session, trouble = SESSION:decode_into(text)
  if session == nil then return nil, path .. ": " .. trouble end
  if session.version ~= VERSION then
    return nil, path .. ": version " .. tostring(session.version) .. ", not " .. tostring(VERSION)
  end
  if session.pid ~= sys.getpid() then
    return nil, path .. ": left by process " .. tostring(session.pid)
  end
  if session.root:sub(1, 1) ~= "/" then return nil, path .. ": the root is not absolute" end
  return session, ""
end

return handoff
