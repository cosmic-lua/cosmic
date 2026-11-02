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
--- The file is `lsp-handoff-<pid>-<nonce>.json` in the build directory of
--- the tree the process was started in, version 1. It is written only
--- once the rebuild has succeeded, immediately before the exec
--- ([`reboot.recheck`]), and the nonce, drawn afresh, is handed to the
--- successor in its environment (`COSMIC_LSP_HANDOFF`): the successor
--- reads the one file that names, and removes it as it reads it, so
--- nothing is entered by it twice, and refuses a file of another
--- version, pid or nonce, or whose `root` is not absolute. A file left
--- by a process that died before its exec holds an editor's unsaved
--- text, so every put and every take removes those of this pid that are
--- not the one named, those of a process that is gone and those a day
--- old; and the process that was not replaced removes its own again.

local Json = require("cosmic.json")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Rand = require("cosmic.rand")
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
    --- What binds the file to the exec it was written for: "" in a session not yet handed ([`handoff.put`] sets it).
    nonce: string
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

--- The directory the files of the tree `launch`, the tree a process was
--- started in, are below, or nil and why it can have none.
local function directory_of(launch: string): string?, string
  return build_paths.directory(launch)
end

--- The name of the file of the process `pid` that `nonce` names.
local function name_of(pid: integer, nonce: string): string
  return "lsp-handoff-" .. tostring(pid) .. "-" .. nonce .. ".json"
end

--- A day, in seconds: how long a file of a live process may lie before it is taken for one left behind.
local OLD_SECONDS <const> = 24 * 3600

--- A fresh nonce, which binds a file to the one exec it is written for: 16 hex digits of the system's entropy. Nil
--- and why where there is none.
function handoff.nonce(): string?, string
  local bytes, trouble = Rand.entropy(8)
  if bytes == nil then return nil, trouble end
  local out: mut {string} = {}
  for i = 1, #bytes do out[#out + 1] = string.format("%02x", bytes:byte(i) or 0) end
  return table.concat(out), ""
end

--- Whether the process `pid` is gone.
local function gone(pid: integer): boolean
  local alive, _, errno = sys.kill(pid, 0)
  return not alive and errno == sys.ESRCH
end

--- Removes the files in `directory` that no process is to read: those of this process but `keep` (a predecessor of
--- this pid left them: the pid is this one's now), those of a process that is gone, and those a day old.
local function sweep(directory: string, keep: string)
  local names, _ = Fs.list(directory)
  if names == nil then return end
  local now = Clock.now_ns() // 1000000000
  for _, name in ipairs(names) do
    local pid_text = name:match("^lsp%-handoff%-(%d+)%-%x+%.json$")
    if pid_text ~= nil and name ~= keep then
      local pid = math.tointeger(tonumber(pid_text)) or 0
      local path = directory .. "/" .. name
      local old = false
      local st, _ = Fs.stat(path)
      if st ~= nil and now - st.mtime > OLD_SECONDS then old = true end
      if pid == sys.getpid() or old or gone(pid) then
        local _, _ = Fs.remove(path)
      end
    end
  end
end

--- Writes `session` for the successor of this process, started in the tree `launch`, under `nonce`, which only that
--- successor is told ([`handoff.take`]); first it removes the files nothing is to read ([`sweep`]). False and why
--- where it cannot be written: the caller does not replace its process then.
function handoff.put(launch: string, nonce: string, session: handoff.Session): boolean, string
  local directory, trouble = directory_of(launch)
  if directory == nil then return false, trouble end
  local name = name_of(session.pid, nonce)
  sweep(directory, name)
  local bound: handoff.Session = { version = session.version, pid = session.pid, nonce = nonce, root = session.root,
    encoding = session.encoding, watch = session.watch, snippets = session.snippets, lazy = session.lazy,
    told_outside = session.told_outside, documents = session.documents, input = session.input }
  local text, encode_trouble = Json.encode_any(bound)
  if text == nil then return false, encode_trouble end
  return Fs.write(directory .. "/" .. name, text, 0x180)
end

--- Removes the file `put` wrote under `nonce` for this process: it was not replaced.
function handoff.drop(launch: string, nonce: string)
  local directory, _ = directory_of(launch)
  if directory ~= nil then
    local _, _ = Fs.remove(directory .. "/" .. name_of(sys.getpid(), nonce))
  end
end

--- The session this process was entered with, started in the tree `launch`, as the file `nonce` names holds it; nil
--- and "" where none was left for it, `nonce` nil (nothing told a process of one). The files of this pid that
--- `nonce` does not name are removed unread, as are the files nothing is to read ([`sweep`]): a process of this pid
--- that died in the middle of a rebuild left one, which a reused pid is not to take for its own. The file is removed
--- as it is read. Nil and why where one was named and cannot be taken: the stream it holds the start of is then lost,
--- and the process ends.
function handoff.take(launch: string, nonce?: string): handoff.Session?, string
  local directory, path_trouble = directory_of(launch)
  if directory == nil then return nil, path_trouble end
  local named = ""
  if nonce ~= nil and nonce:match("^%x+$") ~= nil then named = name_of(sys.getpid(), nonce) end
  sweep(directory, named)
  if named == "" then return nil, "" end
  local path = directory .. "/" .. named
  local text, _ = Fs.read(path)
  if text == nil then return nil, "" end
  local _, _ = Fs.remove(path)
  local session, trouble = SESSION:decode_into(text)
  if session == nil then return nil, path .. ": " .. trouble end
  if session.version ~= VERSION then
    return nil, path .. ": version " .. tostring(session.version) .. ", not " .. tostring(VERSION)
  end
  if session.pid ~= sys.getpid() or session.nonce ~= nonce then
    return nil, path .. ": left by process " .. tostring(session.pid)
  end
  if session.root:sub(1, 1) ~= "/" then return nil, path .. ": the root is not absolute" end
  return session, ""
end

return handoff
