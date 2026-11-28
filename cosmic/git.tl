--- A git repository read and written in place, with no `git` program
--- and no libgit2: the object store (loose objects and packs, deltas
--- resolved), refs (loose and packed), the index, and enough of the
--- write side to stage files and commit them, as `git add` and
--- `git commit` do.
---
---     local Git = require("cosmic.git")
---     local repo = assert(Git.open("."))
---     assert(repo:add({"README.md"}))
---     local oid = assert(repo:commit({ message = "Say hello" }))
---
--- What it refuses rather than gets wrong: SHA-256 repositories, the
--- reftable ref store, a split or sparse index, and any repository
--- extension it does not know. Every object it reads is hashed and
--- checked against the name it was asked for. Fetch, push, merge and
--- checkout are not here.

local Clock = require("cosmic.clock")
local Codec = require("cosmic.codec")
local Compress = require("cosmic.compress")
local Env = require("cosmic.env")
local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")

local record Git
  --- What an object is.
  enum Kind
    "commit"
    "tree"
    "blob"
    "tag"
  end

  --- One object of the store, as its bytes: what `git cat-file -p`
  --- shows for a blob.
  record Object
    --- Its name: 40 lowercase hex digits.
    oid: string
    --- What the object is.
    kind: Kind
    --- Its bytes, without the `<kind> <size>\0` header.
    data: string
  end

  --- Who wrote or committed a change, and when.
  record Person
    --- The name, `Ada Lovelace`.
    name: string
    --- The address, without the angle brackets.
    email: string
    --- Unix epoch seconds.
    time: integer
    --- The offset from UTC as git writes it: `+0000`, `-0800`.
    tz: string
  end

  --- A commit, parsed.
  record Commit
    --- Its name: 40 lowercase hex digits.
    oid: string
    --- The oid of its tree.
    tree: string
    --- The oids of its parents, first parent first; none for a root.
    parents: {string}
    --- Who wrote the change.
    author: Person
    --- Who made the commit.
    committer: Person
    --- The message, its trailing newline kept.
    message: string
  end

  --- One entry of a tree.
  record TreeEntry
    --- The mode as git writes it: `100644`, `100755`, `120000` (a
    --- symbolic link), `160000` (a submodule) or `40000` (a tree).
    mode: string
    --- The entry's name in its tree: one path part, no `/`.
    name: string
    --- The oid of the blob, tree or submodule commit it names.
    oid: string
  end

  --- How a path differs between two sides.
  enum ChangeKind
    "added"
    "modified"
    "deleted"
    --- A file that became a symbolic link, or the other way.
    "typechange"
  end

  record Change
    --- The path from the top of the worktree, with `/` between parts.
    path: string
    --- How it differs.
    kind: ChangeKind
  end

  --- What `git status -uall` reports.
  record Status
    --- The branch HEAD names, `main` for `refs/heads/main`; nil when
    --- HEAD is detached.
    branch?: string
    --- HEAD's commit; nil before the first commit.
    head?: string
    --- HEAD's tree against the index: what a commit would record.
    staged: {Change}
    --- The index against the worktree: what `add` would stage.
    unstaged: {Change}
    --- Paths with conflicts left by a merge.
    unmerged: {string}
    --- Files in the worktree that are not in the index and that no
    --- ignore rule (`.gitignore`, `info/exclude`, `core.excludesFile`)
    --- excludes, sorted, each file named as `git status -uall` names
    --- it. A nested repository is named once, as `dir/`.
    untracked: {string}
    --- Tracked files whose changes it cannot tell: their attributes ask
    --- for a conversion git would run on the way in (a clean filter such
    --- as LFS, ident, a working-tree encoding, a line-ending conversion
    --- of a file with a carriage return), which this module does not.
    --- They are left out of `unstaged`, and `add` refuses them.
    filtered: {string}
  end

  record CommitOptions
    --- The message. A newline is added if it lacks one.
    message: string
    --- Defaults to `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` and
    --- `GIT_AUTHOR_DATE`, then to `user.name` and `user.email` in the
    --- config, at the current time in the local zone (`TZ`, else the host's).
    author?: Person
    --- As `author`, from the `GIT_COMMITTER_*` variables.
    committer?: Person
    --- Commit even when the tree is the parent's.
    allow_empty?: boolean
  end

  record LogOptions
    --- Where to start: anything `rev` reads. Default HEAD.
    from?: string
    --- The most commits to return. Default all.
    limit?: integer
  end

  --- An open repository. Each method reads the files it needs when it
  --- runs, so it sees what other programs wrote meanwhile.
  interface Repo
    --- The directory of the repository's own files (HEAD, index).
    gitdir: string
    --- The directory of what worktrees share (objects, refs, config):
    --- `gitdir` itself, except in a linked worktree.
    commondir: string
    --- The top of the worktree.
    worktree: string

    --- The object `oid` names, or nil and a Failure.
    read: function(Repo, oid: string): (Object) | (nil, Failure)
    --- Whether the store holds `oid`.
    has: function(Repo, oid: string): boolean
    --- The commit `oid` names, parsed.
    commit_info: function(Repo, oid: string): (Commit) | (nil, Failure)
    --- The entries of the tree `oid` names, in the tree's order.
    tree: function(Repo, oid: string): ({TreeEntry}) | (nil, Failure)
    --- The oid a revision names: `HEAD`, a branch or tag (`main`,
    --- `refs/heads/main`), 4 to 40 hex digits, each followed by any
    --- number of `^`, `^N`, `~` and `~N`.
    rev: function(Repo, spec: string): (string) | (nil, Failure)
    --- HEAD's commit, or false before the first commit.
    head: function(Repo): (string | false) | (nil, Failure)
    --- The ref HEAD names, `refs/heads/main`; false when detached.
    head_ref: function(Repo): (string | false) | (nil, Failure)
    --- Commits newest first by committer time, as `git log` lists them.
    log: function(Repo, opts?: LogOptions): ({Commit}) | (nil, Failure)
    --- What `git status -uall` reports.
    status: function(Repo): (Status) | (nil, Failure)
    --- The untracked paths the worktree's own `.gitignore` files ignore, as
    --- `git ls-files --others --ignored --exclude-per-directory=.gitignore
    --- --directory` lists them: files by their path from the top, and
    --- directories, which are listed whole and not entered, as `dir/`.
    --- No `info/exclude`, `core.excludesFile` or global rule is read, and a
    --- nested repository is not entered; the configuration's `core.ignorecase`
    --- is read as everywhere in this module. Sorted.
    ignored: function(Repo): ({string}) | (nil, Failure)
    --- Stages files as `git add` does: each path, from the top of the
    --- worktree, is a file or a symbolic link to record, or a path no
    --- longer there to record as deleted. A directory is refused.
    add: function(Repo, paths: {string}): (true) | (nil, Failure)
    --- Writes the index as a tree and returns its oid.
    write_tree: function(Repo): (string) | (nil, Failure)
    --- Commits the index on top of HEAD, moves HEAD's branch (or a
    --- detached HEAD) to the new commit, and writes its reflogs.
    --- Returns the new commit's oid.
    commit: function(Repo, opts: CommitOptions): (string) | (nil, Failure)
  end
end

--- What a function of this module returns when it refuses what it
--- read or was asked: nil and a Failure of `why` under the module's
--- name. A failure it met (a read's, a write's) is passed on as it is.
local function refuse(why: string, path?: string): nil, Failure
  return nil, Failure.new("git: " .. why, path)
end

local ZERO_OID <const> = string.rep("0", 40)
--- The most deltas one object may stand on: git's own default depth is
--- 50, and pack-objects writes at most 4095.
local MAX_DELTA_DEPTH <const> = 4095
--- The most bytes one object may expand to: a small zlib stream or
--- delta can claim far more than it holds.
local MAX_OBJECT <const> = 1 << 28
--- The most bytes of resolved pack objects kept for delta bases.
local CACHE_BYTES <const> = 1 << 26
local NS <const> = Clock.seconds(1)
local U32 <const> = 0xFFFFFFFF

local KINDS: {integer:Git.Kind} = { [1] = "commit", [2] = "tree", [3] = "blob", [4] = "tag" }
local KIND_NAMES: {string:Git.Kind} = { commit = "commit", tree = "tree", blob = "blob", tag = "tag" }

--- The raw (20-byte) form of a hex oid already checked by [`is_oid`].
local function raw_of(oid: string): string
  return Codec.unhex(oid)!
end

--- Whether `name` is a ref name git accepts (check-ref-format): HEAD,
--- or under refs/ with no `..`, `@{`, empty or dot-led part, `.lock`
--- part end, control byte or any of ` ~^:?*[\`.
local function valid_ref(name: string): boolean
  if name == "HEAD" then return true end
  if name:find("^refs/") == nil or name:sub(-1) == "/" or name:sub(-1) == "." then return false end
  if name:find("..", 1, true) ~= nil or name:find("@{", 1, true) ~= nil or name:find("//", 1, true) ~= nil then
    return false
  end
  if name:find("[%z\1-\31\127 ~%^:%?%*%[\\]") ~= nil then return false end
  for part in name:gmatch("[^/]+") do
    if part:sub(1, 1) == "." or part:sub(-5) == ".lock" then return false end
  end
  return true
end

--- Why git would refuse `path` as an index path (verify_path), or nil:
--- empty parts, `.` or `..`, `.git` in any spelling a case-folding
--- or NTFS file system reads as it, or a NUL.
local function path_trouble(path: string): string?
  if path == "" then return "an empty path names no file" end
  if path:find("%z") ~= nil then return "path holds a NUL" end
  if path:sub(1, 1) == "/" or path:sub(-1) == "/" or path:find("//", 1, true) ~= nil then
    return "path holds an empty part"
  end
  for part in path:gmatch("[^/]+") do
    local folded = part:lower():gsub("[%. ]+$", "")
    if part == "." or part == ".." or folded == ".git" or folded == "git~1" then
      return "path holds a \"" .. part .. "\" part"
    end
  end
  return nil
end

local function is_oid(s: string): boolean
  return #s == 40 and s:find("^[0-9a-f]+$") ~= nil
end

--- The hex name of an object, hashed with collision detection, as git
--- does: nil and a Failure for an object that holds a block of a known
--- SHA-1 collision attack, which could share its name with another.
local function name_of(kind: string, data: string): (string) | (nil, Failure)
  local digest, trouble = Hash.sha1dc(kind .. " " .. tostring(#data) .. "\0" .. data)
  if digest == nil then return nil, Failure.within(trouble, "git: a " .. kind .. " object") end
  return Codec.hex(digest)
end

------------------------------------------------------------------
-- config
------------------------------------------------------------------

--- The Lua pattern class of each POSIX class a bracket may name, as
--- `[[:digit:]]`.
local POSIX_CLASSES <const>: {string:string} = {
  alnum = "%w", alpha = "%a", blank = "[ \t]", cntrl = "%c", digit = "%d", graph = "%g", lower = "%l",
  print = "[%g ]", punct = "%p", space = "%s", upper = "%u", xdigit = "%x",
}

--- Whether `text` matches the glob `pattern` as git's wildmatch does
--- with WM_PATHNAME: `*` and `?` stop at `/`, `**` bounded by `/`
--- spans directories, `[...]` is a class (`!` or `^` negates, and
--- `[:digit:]` and the other POSIX classes may appear in it), and `\`
--- quotes. A bracket left open, or an unknown POSIX class, matches
--- nothing, as in git. `fold` compares ASCII letters without case.
--- Results are kept by position, so a pattern of many stars stays
--- polynomial.
local function wildmatch(pattern: string, text: string, fold: boolean): boolean
  local p = if fold then pattern:lower() else pattern end
  local t = if fold then text:lower() else text end
  local width = #t + 2
  local memo: mut {integer:boolean} = {}
  local function at(pi: integer, ti: integer): boolean
    local key = pi * width + ti
    local known = memo[key]
    if known ~= nil then return known end
    local result = false
    if pi > #p then
      result = ti > #t
    else
      local c = p:sub(pi, pi)
      if c == "*" then
        local double = p:sub(pi + 1, pi + 1) == "*" and (pi == 1 or p:sub(pi - 1, pi - 1) == "/") and
          (pi + 2 > #p or p:sub(pi + 2, pi + 2) == "/")
        if double then
          if pi + 2 > #p then
            result = true
          else
            result = at(pi + 3, ti)
            local k = ti
            while not result and k <= #t do
              if t:sub(k, k) == "/" then result = at(pi + 3, k + 1) end
              k = k + 1
            end
          end
        else
          local next_pi = pi
          while p:sub(next_pi, next_pi) == "*" do next_pi = next_pi + 1 end
          local k = ti
          while true do
            if at(next_pi, k) then
              result = true
              break
            end
            if k > #t or t:sub(k, k) == "/" then break end
            k = k + 1
          end
        end
      elseif ti > #t then
        result = false
      elseif c == "?" then
        result = t:sub(ti, ti) ~= "/" and at(pi + 1, ti + 1)
      elseif c == "[" then
        local ch = t:sub(ti, ti)
        local i = pi + 1
        local negate = p:sub(i, i) == "!" or p:sub(i, i) == "^"
        if negate then i = i + 1 end
        local matched = false
        local first = true
        local closed = false
        local malformed = false
        while i <= #p do
          local a = p:sub(i, i)
          if a == "]" and not first then
            closed = true
            break
          end
          first = false
          local stop: integer? = if a == "[" and p:sub(i + 1, i + 1) == ":" then p:find(":]", i + 2, true) else nil end
          if stop ~= nil then
            local class = POSIX_CLASSES[p:sub(i + 2, stop - 1)]
            if class == nil then
              malformed = true
              break
            end
            -- Under ignorecase git lets [:upper:] and [:lower:] match a letter of either case.
            if ch:find(class) ~= nil or (fold and (class == "%u" or class == "%l") and ch:find("%a") ~= nil) then
              matched = true
            end
            i = stop + 2
          else
            if a == "\\" and i < #p then
              i = i + 1
              a = p:sub(i, i)
            end
            if p:sub(i + 1, i + 1) == "-" and i + 2 <= #p and p:sub(i + 2, i + 2) ~= "]" then
              local b = p:sub(i + 2, i + 2)
              if ch >= a and ch <= b then matched = true end
              i = i + 3
            else
              if ch == a then matched = true end
              i = i + 1
            end
          end
        end
        if not closed or malformed then
          -- git's wildmatch gives up on the whole match (WM_ABORT_ALL): the pattern matches nothing.
          result = false
        else
          result = ch ~= "/" and matched ~= negate and at(i + 1, ti + 1)
        end
      elseif c == "\\" and pi < #p then
        result = t:sub(ti, ti) == p:sub(pi + 1, pi + 1) and at(pi + 2, ti + 1)
      else
        result = t:sub(ti, ti) == c and at(pi + 1, ti + 1)
      end
    end
    memo[key] = result
    return result
  end
  return at(1, 1)
end

--- A config: every value of each `section.key` (or
--- `section.subsection.key`), in the order read. Section and key
--- names are lowercased, as git compares them; a subsection keeps its
--- case.
local type Config = mut {string: mut {string}}

--- A value's text: quotes dropped, escapes read, a comment cut off.
--- As git's parse_value since 2.46: whitespace outside quotes stays as
--- it is between words, and goes at the start and the end. (Before
--- 2.46, git read each such byte as one space.)
local function config_value(raw: string): string
  local out: mut {string} = {}
  local quoted = false
  local spaces, length = "", 0
  local function put(s: string)
    if spaces ~= "" and length > 0 then out[#out + 1] = spaces end
    spaces = ""
    out[#out + 1] = s
    length = length + #s
  end
  local i = 1
  while i <= #raw do
    local c = raw:sub(i, i)
    if c == "\"" then
      put("")
      quoted = not quoted
    elseif c == "\\" then
      local n = raw:sub(i + 1, i + 1)
      put(if n == "n" then "\n" elseif n == "t" then "\t" elseif n == "b" then "\b" else n end)
      i = i + 1
    elseif (c == "#" or c == ";") and not quoted then
      break
    elseif c:find("^%s") ~= nil and not quoted then
      spaces = spaces .. c
    else
      put(c)
    end
    i = i + 1
  end
  return table.concat(out)
end

--- Where a config text came from, for its includes: the file (an
--- include is read relative to its directory), the repository's
--- gitdir and HEAD's branch (for `includeIf`), and how deep the
--- includes go, and how many files the includes of one open read.
local record ConfigSource
  file: string
  gitdir?: string
  branch?: string
  depth: integer
  included: IncludeCount
end

--- How many files the includes of one open have read.
local record IncludeCount
  mut files: integer
end

--- Includes deeper than this are refused, as git refuses them.
local MAX_INCLUDE_DEPTH <const> = 10
--- The most files the includes of one open may read. git has no such
--- limit, but ten levels of twenty includes each would read 20^10.
local MAX_INCLUDED_FILES <const> = 1000

--- `text` split into logical lines, as git reads it: a UTF-8 BOM at the
--- start goes, CRLF reads as LF, and a backslash that ends a line in a
--- value (past its `=`, outside a comment) joins it to the next. One
--- that ends a line anywhere else is kept, for the line to be refused.
local function config_lines(text: string): {string}
  if text:sub(1, 3) == "\xEF\xBB\xBF" then text = text:sub(4) end
  text = text:gsub("\r\n", "\n")
  local lines: mut {string} = {}
  local current: mut {string} = {}
  local quoted, comment, value = false, false, false
  local i = 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == "\n" then
      lines[#lines + 1] = table.concat(current)
      current = {}
      quoted, comment, value = false, false, false
    elseif c == "\\" and not comment then
      local n = text:sub(i + 1, i + 1)
      if n == "\n" and value then
        i = i + 1
      elseif n == "\n" then
        current[#current + 1] = c
      else
        current[#current + 1] = c .. n
        i = i + 1
      end
    else
      if c == "\"" and not comment then quoted = not quoted end
      if (c == "#" or c == ";") and not quoted then comment = true end
      if c == "=" and not quoted and not comment then value = true end
      current[#current + 1] = c
    end
    i = i + 1
  end
  lines[#lines + 1] = table.concat(current)
  return lines
end

--- `path` with a leading `~/` read as HOME.
local function expand_home(path: string): string
  if path:sub(1, 2) == "~/" then
    local home = Env.get("HOME")
    if home ~= nil then return home .. path:sub(2) end
  end
  return path
end

--- Whether the `includeIf` condition `cond` holds for `from`.
local function include_holds(cond: string, from: ConfigSource): boolean
  local kind, pattern = cond:match("^([%w/]+):(.*)$")
  if kind == nil or pattern == nil then return false end
  if kind == "gitdir" or kind == "gitdir/i" then
    local gitdir = from.gitdir
    if gitdir == nil then return false end
    pattern = expand_home(pattern)
    if pattern:sub(1, 2) == "./" then
      pattern = Fs.dirname(from.file) .. pattern:sub(2)
    elseif pattern:sub(1, 1) ~= "/" then
      pattern = "**/" .. pattern
    end
    if pattern:sub(-1) == "/" then pattern = pattern .. "**" end
    return wildmatch(pattern, gitdir, kind == "gitdir/i")
  elseif kind == "onbranch" then
    local branch = from.branch
    if branch == nil then return false end
    if pattern:sub(-1) == "/" then pattern = pattern .. "**" end
    return wildmatch(pattern, branch, false)
  end
  return false
end

--- Reads the config text `text` into `into`, with the files it
--- includes read in place. Refuses an include deeper than git allows.
local function parse_config(text: string, into: Config, from: ConfigSource): (true) | (nil, Failure)
  local section = ""
  for number, raw_line in ipairs(config_lines(text)) do
    local bad = "bad config line " .. tostring(number) .. ", which git refuses too"
    local line = raw_line:gsub("^%s+", "")
    if line:sub(1, 1) == "[" then
      local name, sub = line:match("^%[%s*([%w%.%-]+)%s+\"(.*)\"%s*%]")
      if name ~= nil and sub ~= nil then
        section = name:lower() .. "." .. sub:gsub("\\(.)", "%1")
      else
        local plain = line:match("^%[%s*([%w%.%-]+)%s*%]")
        if plain == nil then return refuse(bad, from.file) end
        section = plain:lower()
      end
      line = line:gsub("^%b[]%s*", "")
    end
    if line ~= "" and line:sub(1, 1) ~= "#" and line:sub(1, 1) ~= ";" then
      local key, rest = line:match("^(%a[%w%-]*)%s*(.*)$")
      if section == "" or key == nil or rest == nil or not (rest == "" or rest:find("^[=#;]") ~= nil) then
        return refuse(bad, from.file)
      end
      do
        local value = "true"
        if rest:sub(1, 1) == "=" then value = config_value((rest:sub(2):gsub("^%s+", ""))) end
        local name = section .. "." .. key:lower()
        local list = into[name]
        if list == nil then
          into[name] = { value }
        else
          list[#list + 1] = value
        end
        local cond = section:match("^includeif%.(.*)$")
        if key:lower() == "path" and (section == "include" or (cond ~= nil and include_holds(cond, from))) then
          if from.depth >= MAX_INCLUDE_DEPTH then
            return refuse("config includes nest deeper than git allows", from.file)
          end
          local target = expand_home(value)
          if target:sub(1, 1) ~= "/" then target = Fs.dirname(from.file) .. "/" .. target end
          from.included.files = from.included.files + 1
          if from.included.files > MAX_INCLUDED_FILES then
            return refuse("config includes read more than " .. tostring(MAX_INCLUDED_FILES) .. " in all", from.file)
          end
          local included, _ = Fs.read(target)
          if included ~= nil then
            local ok, trouble = parse_config(included, into, {
              file = target, gitdir = from.gitdir, branch = from.branch, depth = from.depth + 1,
              included = from.included })
            if not ok then return nil, trouble end
          end
        end
      end
    end
  end
  return true
end

--- The last value of `name`, or nil.
local function config_get(c: Config, name: string): string?
  local list = c[name]
  if list == nil then return nil end
  return list[#list]
end

local function config_bool(c: Config, name: string, default: boolean): boolean
  local v = config_get(c, name)
  if v == nil then return default end
  v = v:lower()
  if v == "true" or v == "yes" or v == "on" then return true end
  if v == "false" or v == "no" or v == "off" or v == "" then return false end
  local n = math.tointeger(tonumber(v))
  if n ~= nil then return n ~= 0 end
  return default
end

--- Repository extensions this module reads correctly, as their
--- lowercased names map to what they need. Any other is refused.
local KNOWN_EXTENSIONS: {string:boolean} = {
  noop = true, preciousobjects = true, partialclone = true,
  worktreeconfig = true, objectformat = true, refstorage = true,
}

------------------------------------------------------------------
-- ignore rules
------------------------------------------------------------------

--- Whether the directory `dir` is the worktree of a repository of its
--- own, as git's is_nonbare_repository_dir tells: `dir/.git` is a
--- directory, or a file naming one (`gitdir: path`), that holds HEAD,
--- objects and refs.
local function holds_repository(dir: string): boolean
  local dotgit = dir .. "/.git"
  local st, _ = sys.lstat(dotgit)
  if st == nil then return false end
  if st.kind == "file" then
    local text, _ = Fs.read(dotgit)
    local named = if text ~= nil then text:match("^gitdir: *([^\n]-)%s*$") else nil end
    if named == nil or named == "" then return false end
    dotgit = if named:sub(1, 1) == "/" then named else dir .. "/" .. named end
  elseif st.kind ~= "dir" then
    return false
  end
  local head, _ = sys.stat(dotgit .. "/HEAD")
  local objects, _ = sys.stat(dotgit .. "/objects")
  local refs, _ = sys.stat(dotgit .. "/refs")
  return head ~= nil and head.kind == "file" and objects ~= nil and objects.kind == "dir" and refs ~= nil and
    refs.kind == "dir"
end

--- The commit HEAD names in the repository checked out at `dir`, or nil where it cannot be told (no HEAD, an unborn
--- branch, an unreadable ref). It reads the files and opens nothing, so it works for a submodule git absorbed
--- (its gitdir under the superproject's, with `core.worktree` set) and ignores GIT_DIR and the like, which git clears
--- for a submodule.
local function submodule_head(dir: string): string?
  local gitdir = dir .. "/.git"
  local st, _ = sys.lstat(gitdir)
  if st ~= nil and st.kind == "file" then
    local text, _ = Fs.read(gitdir)
    local named = if text ~= nil then text:match("^gitdir: *([^\n]-)%s*$") else nil end
    if named == nil or named == "" then return nil end
    gitdir = if named:sub(1, 1) == "/" then named else dir .. "/" .. named end
  end
  local head, _ = Fs.read(gitdir .. "/HEAD")
  if head == nil then return nil end
  head = (head:gsub("%s+$", ""))
  local ref = head:match("^ref: *(.+)$")
  if ref == nil then return head:match("^%x+$") end
  if not valid_ref(ref) then return nil end
  local loose, _ = Fs.read(gitdir .. "/" .. ref)
  if loose ~= nil then return (loose:gsub("%s+$", ""):match("^%x+$")) end
  local common = gitdir
  local pointer, _ = Fs.read(gitdir .. "/commondir")
  if pointer ~= nil then
    local named = (pointer:gsub("%s+$", ""))
    common = if named:sub(1, 1) == "/" then named else gitdir .. "/" .. named end
  end
  local packed, _ = Fs.read(common .. "/packed-refs")
  if packed == nil then return nil end
  for line in packed:gmatch("[^\n]+") do
    local oid, name = line:match("^(%x+) (.+)$")
    if name == ref then return oid end
  end
  return nil
end

--- One line of an ignore file.
local record IgnoreRule
  pattern: string
  --- A `!` line: it puts back what an earlier line excluded.
  negate: boolean
  --- A line that ended in `/`: it matches only directories.
  dir_only: boolean
  --- A line with a `/` before its end: matched against the path from
  --- `base`, not against the last part alone.
  anchored: boolean
  --- The directory of the file that holds it, from the top of the
  --- worktree: `""` or `src/lib/`.
  base: string
end

--- The rules of an ignore file's text, for paths under `base`.
local function parse_ignore(text: string, base: string, into: mut {IgnoreRule})
  if text:sub(1, 3) == "\xEF\xBB\xBF" then text = text:sub(4) end
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw:gsub("\r$", "")
    -- Trailing spaces go, unless a backslash quotes the last one.
    while line:sub(-1) == " " and line:sub(-2, -2) ~= "\\" do line = line:sub(1, -2) end
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local negate = false
      if line:sub(1, 1) == "!" then
        negate = true
        line = line:sub(2)
      end
      local dir_only = false
      if line:sub(-1) == "/" then
        dir_only = true
        line = line:sub(1, -2)
      end
      local anchored = line:find("/", 1, true) ~= nil
      if line:sub(1, 1) == "/" then line = line:sub(2) end
      if line ~= "" then
        into[#into + 1] = { pattern = line, negate = negate, dir_only = dir_only, anchored = anchored, base = base }
      end
    end
  end
end

--- Whether `rules` exclude `path` (from the top of the worktree): the
--- last rule that matches decides.
local function is_ignored(rules: {IgnoreRule}, path: string, is_dir: boolean, fold: boolean): boolean
  for i = #rules, 1, -1 do
    local r = rules[i]!
    if (is_dir or not r.dir_only) and path:sub(1, #r.base) == r.base then
      local rel = path:sub(#r.base + 1)
      local target = if r.anchored then rel else (rel:match("[^/]*$") or rel) end
      if wildmatch(r.pattern, target, fold) then return not r.negate end
    end
  end
  return false
end

------------------------------------------------------------------
-- attributes
------------------------------------------------------------------

--- One attribute a line of a .gitattributes file gives a path.
local record AttrSetting
  name: string
  --- "set" (`text`), "unset" (`-text`), "unspecified" (`!text`) or
  --- "value" (`eol=lf`).
  how: string
  value: string
end

--- One line of an attributes file: what it gives the paths its pattern
--- matches.
local record AttrRule
  pattern: string
  anchored: boolean
  --- The directory of the file that holds it, from the top of the worktree.
  base: string
  settings: {AttrSetting}
end

--- The settings of `words` (the line after its pattern), with a macro
--- replaced by the settings it stands for. `binary` is git's own.
local function attr_settings(words: {string}, macros: {string:{AttrSetting}}): {AttrSetting}
  local out: mut {AttrSetting} = {}
  for _, word in ipairs(words) do
    local how, name, value = "set", word, ""
    if word:sub(1, 1) == "-" then
      how, name = "unset", word:sub(2)
    elseif word:sub(1, 1) == "!" then
      how, name = "unspecified", word:sub(2)
    else
      local n, v = word:match("^([^=]+)=(.*)$")
      if n ~= nil and v ~= nil then how, name, value = "value", n, v end
    end
    local macro = if how == "set" then macros[name] else nil end
    if macro ~= nil then
      out[#out + 1] = { name = name, how = "set", value = "" }
      for _, inner in ipairs(macro) do out[#out + 1] = inner end
    elseif how == "set" and name == "binary" then
      out[#out + 1] = { name = "diff", how = "unset", value = "" }
      out[#out + 1] = { name = "merge", how = "unset", value = "" }
      out[#out + 1] = { name = "text", how = "unset", value = "" }
    else
      out[#out + 1] = { name = name, how = how, value = value }
    end
  end
  return out
end

--- The rules of an attributes file's text, for paths under `base`; the
--- macros it defines (`[attr]name settings`) go in `macros`. A pattern
--- git refuses (one ending in `/`, or with a negation) is left out, as
--- git leaves it out.
local function parse_attributes(text: string, base: string, into: mut {AttrRule}, macros: mut {string:{AttrSetting}})
  if text:sub(1, 3) == "\xEF\xBB\xBF" then text = text:sub(4) end
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw:gsub("\r$", ""):gsub("^%s+", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local pattern, rest = line:match("^(%S+)%s*(.*)$")
      if pattern == nil then
        pattern = line
        rest = ""
      end
      if pattern:sub(1, 1) == '"' then
        local quoted, tail = line:match('^"([^"\\]*)"%s*(.*)$')
        pattern, rest = quoted, tail
      end
      local words: mut {string} = {}
      for word in (rest or ""):gmatch("%S+") do words[#words + 1] = word end
      if pattern ~= nil and pattern:sub(1, 6) == "[attr]" then
        macros[pattern:sub(7)] = attr_settings(words, macros)
      elseif pattern ~= nil and pattern:sub(-1) ~= "/" and pattern:sub(1, 1) ~= "!" and #words > 0 then
        local anchored = pattern:find("/", 1, true) ~= nil
        if pattern:sub(1, 1) == "/" then pattern = pattern:sub(2) end
        local settings = attr_settings(words, macros)
        into[#into + 1] = { pattern = pattern, anchored = anchored, base = base, settings = settings }
      end
    end
  end
end

--- The setting `rules` give the attribute `name` to `path`: the last
--- line that names it and whose pattern matches decides. Nil when none
--- does.
local function attr_setting(rules: {AttrRule}, name: string, path: string, fold: boolean): AttrSetting?
  for i = #rules, 1, -1 do
    local r = rules[i]!
    if path:sub(1, #r.base) == r.base then
      local rel = path:sub(#r.base + 1)
      local target = if r.anchored then rel else (rel:match("[^/]*$") or rel) end
      if wildmatch(r.pattern, target, fold) then
        for j = #r.settings, 1, -1 do
          local setting = r.settings[j]!
          if setting.name == name then return setting end
        end
      end
    end
  end
  return nil
end

------------------------------------------------------------------
-- byte helpers
------------------------------------------------------------------

--- Git's offset varint (OFS_DELTA, index v4 prefixes): big-endian
--- base 128, each continuation adding one. The value and the position
--- after it.
local function offset_varint(s: string, at: integer): integer, integer
  local c = s:byte(at) or 0
  local value = c & 0x7F
  at = at + 1
  while c & 0x80 ~= 0 do
    c = s:byte(at) or 0
    at = at + 1
    value = ((value + 1) << 7) | (c & 0x7F)
  end
  return value, at
end

--- A delta's size varint: little-endian base 128.
local function size_varint(s: string, at: integer): integer, integer
  local value, shift = 0, 0
  while true do
    local c = s:byte(at)
    if c == nil then return -1, at end
    at = at + 1
    value = value | ((c & 0x7F) << shift)
    shift = shift + 7
    if c & 0x80 == 0 or shift > 56 then break end
  end
  return value, at
end

--- `base` with the delta `delta` applied.
local function apply_delta(base: string, delta: string): (string) | (nil, Failure)
  local src_size, at = size_varint(delta, 1)
  local dst_size: integer
  dst_size, at = size_varint(delta, at)
  if src_size ~= #base then return refuse("delta base size mismatch") end
  if dst_size < 0 or dst_size > MAX_OBJECT then return refuse("delta result too large") end
  local out: mut {string} = {}
  local made = 0
  while at <= #delta do
    local op = delta:byte(at)!
    at = at + 1
    if op & 0x80 ~= 0 then
      local offset, size = 0, 0
      for bit = 0, 3 do
        if op & (1 << bit) ~= 0 then
          local c = delta:byte(at)
          if c == nil then return refuse("delta copy runs past its end") end
          offset = offset | (c << (8 * bit))
          at = at + 1
        end
      end
      for bit = 0, 2 do
        if op & (1 << (4 + bit)) ~= 0 then
          local c = delta:byte(at)
          if c == nil then return refuse("delta copy runs past its end") end
          size = size | (c << (8 * bit))
          at = at + 1
        end
      end
      if size == 0 then size = 0x10000 end
      if offset + size > #base then return refuse("delta copies past its base") end
      out[#out + 1] = base:sub(offset + 1, offset + size)
      made = made + size
    elseif op ~= 0 then
      if at + op - 1 > #delta then return refuse("delta insert runs past its end") end
      out[#out + 1] = delta:sub(at, at + op - 1)
      at = at + op
      made = made + op
    else
      return refuse("delta holds a reserved opcode")
    end
    if made > dst_size then return refuse("delta result larger than it says") end
  end
  if made ~= dst_size then return refuse("delta result size mismatch") end
  return table.concat(out)
end

--- Reads `count` bytes at `offset` of the descriptor, all of them.
local function pread_all(fd: integer, count: integer, offset: integer, path: string): (string) | (nil, Failure)
  local parts: mut {string} = {}
  local got = 0
  while got < count do
    local data, _, errno = sys.pread(fd, count - got, offset + got)
    if data == nil then return nil, Failure.system(errno, path) end
    if #data == 0 then return refuse("file ends early", path) end
    parts[#parts + 1] = data
    got = got + #data
  end
  return table.concat(parts)
end

------------------------------------------------------------------
-- packs
------------------------------------------------------------------

--- One pack and its index, read when first asked about.
local record Pack
  --- The `.pack` file's path.
  path: string
  --- The `.idx` file's bytes.
  idx: string
  count: integer
  --- Where the oids, offsets and large offsets start in `idx`, 1-based.
  oids_at: integer
  offsets_at: integer
  large_at: integer
  --- Every entry's offset, sorted, for where each entry ends.
  sorted: {integer}
  --- The `.pack` file's size.
  mut size?: integer
end

local function load_pack(idx_path: string): (Pack) | (nil, Failure)
  local idx, trouble = Fs.read(idx_path)
  if idx == nil then return nil, trouble end
  if #idx < 8 + 1024 + 40 or idx:sub(1, 4) ~= "\255tOc" then
    return refuse("not a version 2 pack index", idx_path)
  end
  if string.unpack(">I4", idx, 5) ~= 2 then
    return refuse("not a version 2 pack index", idx_path)
  end
  local count = string.unpack(">I4", idx, 9 + 255 * 4)
  local oids_at = 9 + 1024
  local offsets_at = oids_at + 24 * count
  local large_at = offsets_at + 4 * count
  if #idx < large_at - 1 + 40 then return refuse("pack index is truncated", idx_path) end
  local previous = 0
  for byte = 0, 255 do
    local through = string.unpack(">I4", idx, 9 + 4 * byte)
    if through < previous or through > count then
      return refuse("pack index fanout is malformed", idx_path)
    end
    previous = through
  end
  local larges = (#idx - 40 - (large_at - 1)) // 8
  local sorted: mut {integer} = {}
  for i = 0, count - 1 do
    local off = string.unpack(">I4", idx, offsets_at + 4 * i)
    if off & 0x80000000 ~= 0 then
      local which = off & 0x7FFFFFFF
      if which >= larges then
        return refuse("pack index names a large offset it lacks", idx_path)
      end
      off = string.unpack(">I8", idx, large_at + 8 * which)
    end
    if off < 12 then
      return refuse("pack index names an offset inside the pack header", idx_path)
    end
    sorted[#sorted + 1] = off
  end
  table.sort(sorted)
  return {
    path = idx_path:sub(1, -5) .. ".pack", idx = idx, count = count,
    oids_at = oids_at, offsets_at = offsets_at, large_at = large_at, sorted = sorted,
  }
end

--- The raw oid of entry `i` (0-based).
local function pack_oid(p: Pack, i: integer): string
  local at = p.oids_at + 20 * i
  return p.idx:sub(at, at + 19)
end

local function pack_offset(p: Pack, i: integer): integer
  local off = string.unpack(">I4", p.idx, p.offsets_at + 4 * i)
  if off & 0x80000000 ~= 0 then
    off = string.unpack(">I8", p.idx, p.large_at + 8 * (off & 0x7FFFFFFF))
  end
  return off
end

--- The first entry whose raw oid is not below `raw`, from the fanout
--- table and a binary search, and the end of `raw`'s first byte's range.
local function pack_lower(p: Pack, raw: string): integer, integer
  local first = raw:byte(1)!
  local lo = if first == 0 then 0 else string.unpack(">I4", p.idx, 9 + 4 * (first - 1)) end
  local hi = string.unpack(">I4", p.idx, 9 + 4 * first)
  local stop = hi
  while lo < hi do
    local mid = (lo + hi) // 2
    if pack_oid(p, mid) < raw then lo = mid + 1 else hi = mid end
  end
  return lo, stop
end

local function pack_find(p: Pack, raw: string): integer?
  local i, stop = pack_lower(p, raw)
  if i < stop and pack_oid(p, i) == raw then return pack_offset(p, i) end
  return nil
end

--- Where the entry at `offset` ends: the next entry's offset, or the
--- pack's trailing checksum.
local function pack_entry_end(p: Pack, offset: integer): (integer) | (nil, Failure)
  local sorted = p.sorted
  local size = p.size
  if size == nil then
    local st, trouble = Fs.stat(p.path)
    if st == nil then return nil, trouble end
    size = st.size
    p.size = size
  end
  local lo, hi = 1, #sorted + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if sorted[mid]! <= offset then lo = mid + 1 else hi = mid end
  end
  return if lo <= #sorted then sorted[lo]! else size - 20 end
end

------------------------------------------------------------------
-- the index
------------------------------------------------------------------

local record Entry
  ctime: integer
  ctime_ns: integer
  mtime: integer
  mtime_ns: integer
  dev: integer
  ino: integer
  --- The mode as an integer: 0o100644, 0o100755, 0o120000, 0o160000.
  mode: integer
  uid: integer
  gid: integer
  size: integer
  --- The raw (20-byte) oid.
  oid: string
  --- The flags less the name length: assume-valid, extended, stage.
  flags: integer
  --- The extended flags (skip-worktree, intent-to-add); 0 if none.
  xflags: integer
  path: string
end

local FLAG_EXTENDED <const> = 0x4000
local XFLAG_SKIP_WORKTREE <const> = 0x4000
local XFLAG_INTENT_TO_ADD <const> = 0x2000

local function stage_of(e: Entry): integer
  return (e.flags >> 12) & 3
end

local record Index
  entries: {Entry}
  --- The version it was read as (2 where there was no file): `add` writes it back as it was.
  mut version: integer
  --- The index file's mtime, for telling racily clean entries.
  mtime: integer
  mtime_ns: integer
end

local function read_index(path: string): (Index) | (nil, Failure)
  local data, trouble = Fs.read(path)
  if data == nil then
    if trouble.errno == sys.ENOENT then
      return { entries = {}, version = 2, mtime = 0, mtime_ns = 0 }
    end
    return nil, trouble
  end
  local st, strouble = Fs.stat(path)
  if st == nil then return nil, strouble end
  if #data < 32 or data:sub(1, 4) ~= "DIRC" then return refuse("not an index file", path) end
  local body = data:sub(1, -21)
  local sum = data:sub(-20)
  if sum ~= string.rep("\0", 20) and Hash.digest("sha1", body) ~= sum then
    return refuse("index checksum mismatch", path)
  end
  local version, count = string.unpack(">I4I4", data, 5)
  if version < 2 or version > 4 then
    return refuse("index version " .. tostring(version) .. " is not supported", path)
  end
  local entries: mut {Entry} = {}
  local at = 13
  local previous = ""
  for _ = 1, count do
    if at + 62 > #body then return refuse("index is truncated", path) end
    local ctime, ctime_ns, mtime, mtime_ns, dev, ino, mode, uid, gid, size, oid, flags, next_at =
      string.unpack(">I4I4I4I4I4I4I4I4I4I4c20I2", body, at)
    at = next_at
    local xflags = 0
    if flags & FLAG_EXTENDED ~= 0 then
      if version < 3 then return refuse("extended flags in a version 2 index", path) end
      if at + 1 > #body then return refuse("index is truncated", path) end
      xflags, at = string.unpack(">I2", body, at)
    end
    local entry_path: string
    if version == 4 then
      local strip: integer
      strip, at = offset_varint(body, at)
      local nul = body:find("\0", at, true)
      if nul == nil or strip > #previous then return refuse("index entry is malformed", path) end
      entry_path = previous:sub(1, #previous - strip) .. body:sub(at, nul - 1)
      at = nul + 1
    else
      local nul = body:find("\0", at, true)
      if nul == nil then return refuse("index entry is malformed", path) end
      local start = at
      entry_path = body:sub(at, nul - 1)
      local fixed = if flags & FLAG_EXTENDED ~= 0 then 64 else 62 end
      local len = fixed + #entry_path
      at = start + (len + 8) // 8 * 8 - fixed
    end
    previous = entry_path
    entries[#entries + 1] = {
      ctime = ctime, ctime_ns = ctime_ns, mtime = mtime, mtime_ns = mtime_ns,
      dev = dev, ino = ino, mode = mode, uid = uid, gid = gid, size = size,
      oid = oid, flags = flags & 0xF000, xflags = xflags, path = entry_path,
    }
  end
  while at + 8 <= #body do
    local sig, len = string.unpack(">c4I4", body, at)
    local first = sig:byte(1)!
    if first < 65 or first > 90 then
      return refuse("index extension \"" .. sig .. "\" is not supported", path)
    end
    if sig == "sdir" then return refuse("a sparse index is not supported", path) end
    at = at + 8 + len
  end
  return { entries = entries, version = version, mtime = st.mtime, mtime_ns = st.mtime_ns }
end

--- The offset varint of `n`: what [`offset_varint`] reads.
local function offset_varint_bytes(n: integer): string
  local out: mut {string} = { string.char(n & 0x7F) }
  n = n >> 7
  while n > 0 do
    n = n - 1
    table.insert(out, 1, string.char(0x80 | (n & 0x7F)))
    n = n >> 7
  end
  return table.concat(out)
end

--- The index's bytes in `version` (4 for path-compressed entries, as a
--- repository with index.version 4 keeps them); version 2, or 3 when an
--- entry has extended flags, otherwise. No extensions: the cache tree
--- (TREE), the untracked cache (UNTR), the resolve-undo list (REUC), the
--- file system monitor token (FSMN) and the entry offset tables (EOIE,
--- IEOT) are optional, and each is a cache git rebuilds or a note that
--- no longer holds once the entries change. An entry whose mtime is not
--- before `now` (seconds) is written with size 0, so its content is
--- checked next time ("racily clean").
local function index_bytes(entries: {Entry}, now: integer, version: integer): string
  local compressed = version == 4
  version = 2
  if compressed then version = 4 end
  for _, e in ipairs(entries) do
    if e.xflags ~= 0 and version == 2 then version = 3 end
  end
  local parts: mut {string} = { string.pack(">c4I4I4", "DIRC", version, #entries) }
  local previous = ""
  for _, e in ipairs(entries) do
    local size = if e.mtime >= now then 0 else e.size end
    local flags = (e.flags & 0x3000) | (if #e.path < 0xFFF then #e.path else 0xFFF end)
    if e.xflags ~= 0 then flags = flags | FLAG_EXTENDED end
    local fixed = 62
    parts[#parts + 1] = string.pack(">I4I4I4I4I4I4I4I4I4I4c20I2",
      e.ctime & U32, e.ctime_ns & U32, e.mtime & U32, e.mtime_ns & U32, e.dev & U32, e.ino & U32,
      e.mode, e.uid & U32, e.gid & U32, size & U32, e.oid, flags)
    if e.xflags ~= 0 then
      parts[#parts + 1] = string.pack(">I2", e.xflags)
      fixed = 64
    end
    if compressed then
      local common = 0
      local limit = math.min(#previous, #e.path)
      while common < limit and previous:byte(common + 1) == e.path:byte(common + 1) do
        common = common + 1
      end
      parts[#parts + 1] = offset_varint_bytes(#previous - common) .. e.path:sub(common + 1) .. "\0"
      previous = e.path
    else
      local len = fixed + #e.path
      parts[#parts + 1] = e.path .. string.rep("\0", (len + 8) // 8 * 8 - len)
    end
  end
  local body = table.concat(parts)
  return body .. Hash.digest("sha1", body)
end

--- The offset from UTC of the local zone at `time` (Unix seconds), as
--- git writes it: `+0000`, `-0800`. The zone is `TZ`'s, or the host's
--- (/etc/localtime) where `TZ` is unset, as git reads them; UTC where
--- that names no zone.
local function local_offset(time: integer): string
  local Time = require("cosmic.time")
  local tz = Env.get("TZ")
  local zone, _ = Time.local_zone({ tz = tz, unset = tz == nil })
  -- git reads a zone it cannot use as UTC.
  if zone == nil then return "+0000" end
  local seconds = Time.civil(time * NS, zone).offset
  local sign = if seconds < 0 then "-" else "+" end
  seconds = math.abs(seconds)
  return string.format("%s%02d%02d", sign, seconds // 3600, seconds % 3600 // 60)
end

--- Whether `a` sorts before `b` in the index: by path, then stage.
local function entry_before(a: Entry, b: Entry): boolean
  if a.path ~= b.path then return a.path < b.path end
  return stage_of(a) < stage_of(b)
end

------------------------------------------------------------------
-- files under a lock
------------------------------------------------------------------

--- Takes `path`'s lock as git does: creates `path.lock`, which no
--- other writer may then create, and writes `data` to it. The lock is
--- committed with [`commit_lock`] or dropped with [`drop_lock`].
local function take_lock(path: string, data: string): (string) | (nil, Failure)
  local lock = path .. ".lock"
  local fd, _, errno = sys.open(lock, sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, 0x1a4)
  if fd == nil then
    if errno == sys.EEXIST then
      return refuse("another git process holds the lock; remove it if none runs", lock)
    end
    return nil, Failure.system(errno, lock)
  end
  local ok, trouble = Fs.put(fd, data)
  local closed, ctrouble = Fs.close(fd)
  if not ok then
    local _, _ = Fs.remove(lock)
    return nil, trouble
  end
  if not closed then
    local _, _ = Fs.remove(lock)
    return nil, ctrouble
  end
  return lock
end

local function commit_lock(lock: string): (true) | (nil, Failure)
  local ok, trouble = Fs.rename(lock, lock:sub(1, -6))
  if not ok then
    local _, _ = Fs.remove(lock)
    return nil, trouble
  end
  return true
end

local function drop_lock(lock: string)
  local _, _ = Fs.remove(lock)
end

------------------------------------------------------------------
-- objects
------------------------------------------------------------------

local function parse_person(line: string): Git.Person?
  local name, email, time, tz = line:match("^(.-) <(.-)> (%-?%d+) ([%+%-]%d%d%d%d)$")
  if name == nil or email == nil or time == nil or tz == nil then return nil end
  return { name = name, email = email, time = math.tointeger(tonumber(time)) or 0, tz = tz }
end

local function format_person(p: Git.Person): string
  return p.name .. " <" .. p.email .. "> " .. tostring(p.time) .. " " .. p.tz
end

local function parse_commit(oid: string, data: string): (Git.Commit) | (nil, Failure)
  local header_end = data:find("\n\n", 1, true)
  local header = if header_end ~= nil then data:sub(1, header_end) else data .. "\n" end
  local message = if header_end ~= nil then data:sub(header_end + 2) else "" end
  local tree: string?
  local parents: mut {string} = {}
  local author, committer: Git.Person?, Git.Person?
  for line in header:gmatch("([^\n]*)\n") do
    local key, value = line:match("^(%S+) (.*)$")
    if key == nil or value == nil then
      -- a continuation line of a multi-line header (gpgsig, mergetag)
    elseif key == "tree" and tree == nil then
      tree = value
    elseif key == "parent" then
      parents[#parents + 1] = value
    elseif key == "author" and author == nil then
      author = parse_person(value)
    elseif key == "committer" and committer == nil then
      committer = parse_person(value)
    end
  end
  if tree == nil or not is_oid(tree) or author == nil or committer == nil then
    return refuse("commit " .. oid .. " is malformed")
  end
  return {
    oid = oid, tree = tree, parents = parents,
    author = author, committer = committer, message = message,
  }
end

local function parse_tree(oid: string, data: string): ({Git.TreeEntry}) | (nil, Failure)
  local entries: mut {Git.TreeEntry} = {}
  local at = 1
  while at <= #data do
    local space = data:find(" ", at, true)
    local nul = space and data:find("\0", space, true)
    if space == nil or nul == nil or nul + 20 > #data then
      return refuse("tree " .. oid .. " is malformed")
    end
    entries[#entries + 1] = {
      mode = data:sub(at, space - 1),
      name = data:sub(space + 1, nul - 1),
      oid = Codec.hex(data:sub(nul + 1, nul + 20)),
    }
    at = nul + 21
  end
  return entries
end

--- The mode in a tree entry as the integer an index entry holds.
local function mode_number(mode: string): integer
  return math.tointeger(tonumber(mode, 8)) or 0
end

local function mode_text(mode: integer): string
  return string.format("%o", mode)
end

--- A tree's entries sort by name, a subtree's name as if it ended in `/`.
local function tree_key(name: string, mode: integer): string
  return if mode == 0x4000 then name .. "/" else name end
end

------------------------------------------------------------------
-- the repository
------------------------------------------------------------------

--- A path and what is recorded for it: the mode and raw oid.
local record Recorded
  mode: integer
  oid: string
end

--- What is at a worktree path.
local record Seen
  --- Its lstat; nil when nothing is there.
  st?: sys.Stat
  --- Its bytes as a blob (a link's target); nil unless a file or link.
  blob?: string
  --- What `add` would record for it; nil unless a file or link.
  recorded?: Recorded
end

--- The attributes files read so far for one `add` or `status`.
local record AttrCache
  --- Rules of the files under the worktree, by directory (`""`, `src/`).
  mut dirs: mut {string:{AttrRule}}
  mut macros: mut {string:{AttrSetting}}
  --- The global file's rules and the repository's own (info/attributes),
  --- the lowest and the highest in rank; nil until read.
  mut global?: {AttrRule}
  mut info?: {AttrRule}
end

local class Repository is Git.Repo
  gitdir: string
  commondir: string
  worktree: string
  --- The index file: `gitdir`/index, or GIT_INDEX_FILE.
  index_file: string
  config: Config
  --- Every object directory: the repository's, then its alternates.
  object_dirs: {string}
  --- The packs of each object directory, read when first needed.
  mut packs?: {Pack}
  --- Commits whose parents a shallow clone left out.
  mut shallow?: {string:boolean}
  --- Resolved pack objects by "<pack path>@<offset>", for delta bases.
  mut cache: mut {string:Git.Object}
  --- The bytes of data `cache` holds.
  mut cached: integer
  --- Why the first pack that could not be read was skipped, to name
  --- when an object is then not found.
  mut pack_trouble?: Failure

  function list_packs(self): ({Pack}) | (nil, Failure)
    local packs = self.packs
    if packs ~= nil then return packs end
    local found: mut {Pack} = {}
    for _, dir in ipairs(self.object_dirs) do
      local names, _ = sys.readdir(dir .. "/pack")
      if names ~= nil then
        local sorted: mut {string} = {}
        for name in pairs(names) do
          if name:find("%.idx$") then sorted[#sorted + 1] = name end
        end
        table.sort(sorted)
        for _, name in ipairs(sorted) do
          -- A pack whose index cannot be read is skipped, as git skips
          -- it: the other packs and the loose objects still read.
          local p, trouble = load_pack(dir .. "/pack/" .. name)
          if p ~= nil then
            found[#found + 1] = p
          elseif self.pack_trouble == nil then
            self.pack_trouble = trouble
          end
        end
      end
    end
    self.packs = found
    return found
  end

  --- The pack entry at `offset`, its deltas applied.
  function read_packed(self, p: Pack, offset: integer, depth: integer): (Git.Object) | (nil, Failure)
    if depth > MAX_DELTA_DEPTH then return refuse("delta chain too deep", p.path) end
    local key = p.path .. "@" .. tostring(offset)
    local hit = self.cache[key]
    if hit ~= nil then return hit end
    local stop, strouble = pack_entry_end(p, offset)
    if stop == nil then return nil, strouble end
    if stop <= offset then return refuse("pack entry has no end", p.path) end
    local fd, otrouble = Fs.open_read(p.path)
    if fd == nil then return nil, otrouble end
    local raw, rtrouble = pread_all(fd, stop - offset, offset, p.path)
    local _, _ = Fs.close(fd)
    if raw == nil then return nil, rtrouble end
    local c = raw:byte(1)!
    local kind_number = (c >> 4) & 7
    local size = c & 0x0F
    local shift = 4
    local at = 2
    while c & 0x80 ~= 0 do
      c = raw:byte(at) or 0
      at = at + 1
      size = size | ((c & 0x7F) << shift)
      shift = shift + 7
    end
    if size < 0 or size > MAX_OBJECT or shift > 60 then
      return refuse("pack entry too large", p.path)
    end
    local base: Git.Object?
    if kind_number == 6 then
      local back: integer
      back, at = offset_varint(raw, at)
      if back <= 0 or back > offset then return refuse("delta base outside the pack", p.path) end
      local b, btrouble = self:read_packed(p, offset - back, depth + 1)
      if b == nil then return nil, btrouble end
      base = b
    elseif kind_number == 7 then
      local base_oid = Codec.hex(raw:sub(at, at + 19))
      at = at + 20
      local b, btrouble = self:read_object(base_oid, depth + 1)
      if b == nil then return nil, btrouble end
      base = b
    end
    local plain_kind = KINDS[kind_number]
    if base == nil and plain_kind == nil then
      return refuse("pack entry of unknown type " .. tostring(kind_number), p.path)
    end
    local data, dtrouble = Compress.decode("zlib", raw:sub(at), { max_bytes = size })
    if data == nil then return nil, dtrouble end
    if #data ~= size then return refuse("pack entry size mismatch", p.path) end
    local object: Git.Object
    if base ~= nil then
      local result, atrouble = apply_delta(base.data, data)
      if result == nil then return nil, atrouble end
      local oid, ntrouble = name_of(base.kind, result)
      if oid == nil then return nil, ntrouble end
      object = { oid = oid, kind = base.kind, data = result }
    elseif plain_kind ~= nil then
      local oid, ntrouble = name_of(plain_kind, data)
      if oid == nil then return nil, ntrouble end
      object = { oid = oid, kind = plain_kind, data = data }
    else
      return refuse("pack entry of unknown type " .. tostring(kind_number), p.path)
    end
    if self.cached + #object.data > CACHE_BYTES then
      self.cache = {}
      self.cached = 0
    end
    self.cache[key] = object
    self.cached = self.cached + #object.data
    return object
  end

  function read_loose(self, oid: string): (Git.Object | false) | (nil, Failure)
    for _, dir in ipairs(self.object_dirs) do
      local path = dir .. "/" .. oid:sub(1, 2) .. "/" .. oid:sub(3)
      local packed, trouble = Fs.read(path)
      if packed ~= nil then
        local raw, dtrouble = Compress.decode("zlib", packed, { max_bytes = MAX_OBJECT })
        if raw == nil then return nil, dtrouble end
        local kind_name, size, nul = raw:match("^(%a+) (%d+)()\0")
        local kind = KIND_NAMES[kind_name or ""]
        if kind == nil or nul == nil then
          return refuse("loose object is malformed", path)
        end
        local data = raw:sub(nul + 1)
        if tonumber(size) ~= #data then return refuse("loose object size mismatch", path) end
        return { oid = oid, kind = kind, data = data }
      elseif trouble.errno ~= sys.ENOENT and trouble.errno ~= sys.ENOTDIR then
        return nil, trouble
      end
    end
    return false
  end

  function read_object(self, oid: string, depth: integer, rescanned?: boolean): (Git.Object) | (nil, Failure)
    if not is_oid(oid) then return refuse("not an object name: " .. oid) end
    local loose, ltrouble = self:read_loose(oid)
    if loose == nil then return nil, ltrouble end
    local object: Git.Object? = if loose ~= false then loose else nil end
    if object == nil then
      local packs, ptrouble = self:list_packs()
      if packs == nil then return nil, ptrouble end
      local raw = raw_of(oid)
      for _, p in ipairs(packs) do
        local offset = pack_find(p, raw)
        if offset ~= nil then
          local found, trouble = self:read_packed(p, offset, depth)
          if found == nil then return nil, trouble end
          object = found
          break
        end
      end
    end
    if object == nil and self.packs ~= nil and rescanned ~= true then
      -- Another program may have repacked since the packs were listed:
      -- list them again, once.
      self.packs = nil
      self.pack_trouble = nil
      self.cache = {}
      self.cached = 0
      return self:read_object(oid, depth, true)
    end
    if object == nil then
      local skipped = self.pack_trouble
      if skipped ~= nil then
        return refuse("object " .. oid .. " is not in the store, and a pack was skipped: " .. tostring(skipped))
      end
      return refuse("object " .. oid .. " is not in the store")
    end
    local named, ntrouble = name_of(object.kind, object.data)
    if named == nil then return nil, ntrouble end
    if named ~= oid then
      return refuse("object " .. oid .. " is corrupt: its content hashes to another name")
    end
    return object
  end

  function read(self, oid: string): (Git.Object) | (nil, Failure)
    return self:read_object(oid, 0)
  end

  function has(self, oid: string): boolean
    if not is_oid(oid) then return false end
    for _, dir in ipairs(self.object_dirs) do
      local st, _ = sys.lstat(dir .. "/" .. oid:sub(1, 2) .. "/" .. oid:sub(3))
      if st ~= nil then return true end
    end
    local packs, _ = self:list_packs()
    if packs == nil then return false end
    local raw = raw_of(oid)
    for _, p in ipairs(packs) do
      if pack_find(p, raw) ~= nil then return true end
    end
    return false
  end

  function read_kind(self, oid: string, kind: Git.Kind): (Git.Object) | (nil, Failure)
    local object, trouble = self:read(oid)
    if object == nil then return nil, trouble end
    if object.kind ~= kind then
      return refuse(oid .. " is a " .. object.kind .. ", not a " .. kind)
    end
    return object
  end

  function commit_info(self, oid: string): (Git.Commit) | (nil, Failure)
    local object, trouble = self:read_kind(oid, "commit")
    if object == nil then return nil, trouble end
    return parse_commit(oid, object.data)
  end

  function tree(self, oid: string): ({Git.TreeEntry}) | (nil, Failure)
    local object, trouble = self:read_kind(oid, "tree")
    if object == nil then return nil, trouble end
    return parse_tree(oid, object.data)
  end

  --- Writes an object to the store as a loose object, unless it is
  --- there already, and returns its oid.
  function write_object(self, kind: Git.Kind, data: string): (string) | (nil, Failure)
    local oid, ntrouble = name_of(kind, data)
    if oid == nil then return nil, ntrouble end
    if self:has(oid) then return oid end
    local dir = self.object_dirs[1]! .. "/" .. oid:sub(1, 2)
    local made, mtrouble = Fs.mkdirs(dir)
    if not made then return nil, mtrouble end
    local packed, ctrouble = Compress.encode("zlib", kind .. " " .. tostring(#data) .. "\0" .. data)
    if packed == nil then return nil, ctrouble end
    local ok, trouble = Fs.write(dir .. "/" .. oid:sub(3), packed, 0x124)
    if not ok then return nil, trouble end
    return oid
  end

  ----------------------------------------------------------------
  -- refs
  ----------------------------------------------------------------

  --- Where a ref's loose file lives: HEAD and per-worktree refs in the
  --- gitdir, the rest in the commondir.
  function ref_path(self, name: string): string
    if name == "HEAD" or name:find("^refs/") == nil or name:find("^refs/bisect/") ~= nil or
        name:find("^refs/worktree/") ~= nil or name:find("^refs/rewritten/") ~= nil then
      return self.gitdir .. "/" .. name
    end
    return self.commondir .. "/" .. name
  end

  --- A ref's own value: an oid, `ref: <name>` for a symbolic ref, or
  --- false when it does not exist.
  function ref_value(self, name: string): (string | false) | (nil, Failure)
    local text, trouble = Fs.read(self:ref_path(name))
    if text ~= nil then
      text = text:gsub("%s+$", "")
      if text:find("^ref: ") ~= nil or is_oid(text) then return text end
      return refuse("ref " .. name .. " is malformed")
    end
    if trouble.errno ~= sys.ENOENT and trouble.errno ~= sys.ENOTDIR and trouble.errno ~= sys.EISDIR then
      return nil, trouble
    end
    local packed, ptrouble = Fs.read(self.commondir .. "/packed-refs")
    if packed == nil then
      if ptrouble.errno == sys.ENOENT then return false end
      return nil, ptrouble
    end
    for line in packed:gmatch("[^\n]+") do
      local oid, ref = line:match("^(%x+) (.+)$")
      if ref == name and oid ~= nil and is_oid(oid) then return oid end
    end
    return false
  end

  --- Follows symbolic refs from `name` to an oid; false when the last
  --- ref does not exist (an unborn branch). The second result is the
  --- last ref's name.
  function resolve_ref(self, name: string): (string | false, string) | (nil, Failure)
    for _ = 1, 10 do
      local value, trouble = self:ref_value(name)
      if value == nil then return nil, trouble end
      if value == false then return false, name end
      if not value:find("^ref: ") then return value, name end
      name = value:sub(6)
      if not valid_ref(name) then return refuse("symbolic ref to a malformed name: " .. name) end
    end
    return refuse("symbolic refs loop at " .. name)
  end

  function head(self): (string | false) | (nil, Failure)
    local oid, trouble = self:resolve_ref("HEAD")
    if oid == nil then return nil, trouble end
    return oid
  end

  function head_ref(self): (string | false) | (nil, Failure)
    local value, trouble = self:ref_value("HEAD")
    if value == nil then return nil, trouble end
    if value == false then return refuse("HEAD is missing") end
    if value:find("^ref: ") then
      local name = value:sub(6)
      if not valid_ref(name) then return refuse("HEAD names a malformed ref: " .. name) end
      return name
    end
    return false
  end

  --- The single oid starting with `prefix` (4 to 39 hex digits).
  function expand_prefix(self, prefix: string): (string) | (nil, Failure)
    local found: mut {string:boolean} = {}
    for _, dir in ipairs(self.object_dirs) do
      local names, _ = sys.readdir(dir .. "/" .. prefix:sub(1, 2))
      if names ~= nil then
        for name in pairs(names) do
          local oid = prefix:sub(1, 2) .. name
          if is_oid(oid) and oid:sub(1, #prefix) == prefix then found[oid] = true end
        end
      end
    end
    local packs, ptrouble = self:list_packs()
    if packs == nil then return nil, ptrouble end
    local even = prefix:sub(1, #prefix // 2 * 2)
    local raw_low = raw_of(even .. string.rep("0", 40 - #even))
    for _, p in ipairs(packs) do
      local i, stop = pack_lower(p, raw_low)
      while i < stop do
        local oid = Codec.hex(pack_oid(p, i))
        if oid:sub(1, #prefix) ~= prefix then
          if oid:sub(1, #even) ~= even then break end
        else
          found[oid] = true
        end
        i = i + 1
      end
    end
    local only: string?
    for oid in pairs(found) do
      if only ~= nil then return refuse("short name " .. prefix .. " is ambiguous") end
      only = oid
    end
    if only == nil then return refuse("no object starts with " .. prefix) end
    return only
  end

  --- What a name with no suffixes means, tried as git tries it.
  function rev_name(self, name: string): (string) | (nil, Failure)
    if is_oid(name) then return name end
    local candidates = { name, "refs/" .. name, "refs/tags/" .. name, "refs/heads/" .. name,
      "refs/remotes/" .. name, "refs/remotes/" .. name .. "/HEAD" }
    if name == "HEAD" or name:find("^refs/") ~= nil then candidates = { name } end
    for _, ref in ipairs(candidates) do
      if ref == "HEAD" or ref:find("^refs/") ~= nil then
        local oid, trouble = self:resolve_ref(ref)
        if oid == nil then return nil, trouble end
        if oid ~= false then return oid end
      end
    end
    if name == "HEAD" then return refuse("HEAD has no commit yet") end
    if #name >= 4 and #name < 40 and name:find("^%x+$") ~= nil then
      return self:expand_prefix(name:lower())
    end
    return refuse("unknown revision " .. name)
  end

  --- The commit `oid` stands for, peeling annotated tags.
  function peel(self, oid: string): (string) | (nil, Failure)
    for _ = 1, 10 do
      local object, trouble = self:read(oid)
      if object == nil then return nil, trouble end
      if object.kind == "commit" then return oid end
      if object.kind ~= "tag" then
        return refuse(oid .. " is a " .. object.kind .. ", not a commit")
      end
      local target = object.data:match("^object (%x+)\n")
      if target == nil then return refuse("tag " .. oid .. " is malformed") end
      oid = target
    end
    return refuse("tags nest too deep at " .. oid)
  end

  function rev(self, spec: string): (string) | (nil, Failure)
    local name = spec:match("^[^%^~]+")
    if name == nil then return refuse("unknown revision " .. spec) end
    local oid, trouble = self:rev_name(name)
    if oid == nil then return nil, trouble end
    local at = #name + 1
    while at <= #spec do
      local op = spec:sub(at, at)
      local digits = spec:match("^%d*", at + 1) or ""
      local n = if digits == "" then 1 else math.tointeger(tonumber(digits)) end
      if n == nil then return refuse("revision count out of range in " .. spec) end
      at = at + 1 + #digits
      if op ~= "^" and op ~= "~" then return refuse("unknown revision " .. spec) end
      local steps = if op == "~" then n else 1 end
      local parent_index = if op == "^" then n else 1 end
      for _ = 1, steps do
        local peeled, ptrouble = self:peel(oid)
        if peeled == nil then return nil, ptrouble end
        if op == "^" and n == 0 then
          oid = peeled
        else
          local c, ctrouble = self:commit_info(peeled)
          if c == nil then return nil, ctrouble end
          local parent = c.parents[parent_index]
          if parent == nil then
            return refuse(spec .. ": " .. peeled .. " has no parent " .. tostring(parent_index))
          end
          oid = parent
        end
      end
    end
    return oid
  end

  function shallow_set(self): {string:boolean}
    local set = self.shallow
    if set ~= nil then return set end
    local made: mut {string:boolean} = {}
    local text, _ = Fs.read(self.commondir .. "/shallow")
    if text ~= nil then
      for line in text:gmatch("%x+") do made[line] = true end
    end
    self.shallow = made
    return made
  end

  function log(self, opts?: Git.LogOptions): ({Git.Commit}) | (nil, Failure)
    local from = opts and opts.from or "HEAD"
    local limit = opts and opts.limit or math.maxinteger
    local start, trouble = self:rev(from)
    if start == nil then return nil, trouble end
    local peeled, ptrouble = self:peel(start)
    if peeled == nil then return nil, ptrouble end
    local shallow = self:shallow_set()
    local seen: mut {string:boolean} = { [peeled] = true }
    local first, ftrouble = self:commit_info(peeled)
    if first == nil then return nil, ftrouble end
    local queue: mut {Git.Commit} = { first }
    local out: mut {Git.Commit} = {}
    while #queue > 0 and #out < limit do
      local c = table.remove(queue, 1)!
      out[#out + 1] = c
      if shallow[c.oid] == nil then
        for _, parent in ipairs(c.parents) do
          if seen[parent] == nil then
            seen[parent] = true
            local pc, pctrouble = self:commit_info(parent)
            if pc == nil then return nil, pctrouble end
            local i = #queue + 1
            while i > 1 and queue[i - 1]!.committer.time < pc.committer.time do i = i - 1 end
            table.insert(queue, i, pc)
          end
        end
      end
    end
    return out
  end

  ----------------------------------------------------------------
  -- trees, the index and the worktree
  ----------------------------------------------------------------

  --- Every blob, link and submodule under a tree, by path.
  function flatten(self, tree_oid: string, prefix: string, into: mut {string:Recorded}): (true) | (nil, Failure)
    -- The tree's bytes are read here, not through parse_tree: its oids stay raw, and only a subtree's is spelled
    -- in hex, so a tree of thousands of files costs no hex round trip for each.
    local object, trouble = self:read_kind(tree_oid, "tree")
    if object == nil then return nil, trouble end
    local data = object.data
    local at = 1
    while at <= #data do
      local space = data:find(" ", at, true)
      local nul = space and data:find("\0", space, true)
      if space == nil or nul == nil or nul + 20 > #data then
        return refuse("tree " .. tree_oid .. " is malformed")
      end
      local mode = mode_number(data:sub(at, space - 1))
      local name = data:sub(space + 1, nul - 1)
      local oid = data:sub(nul + 1, nul + 20)
      at = nul + 21
      if mode == 0x4000 then
        local ok, ftrouble = self:flatten(Codec.hex(oid), prefix .. name .. "/", into)
        if not ok then return nil, ftrouble end
      else
        into[prefix .. name] = { mode = mode, oid = oid }
      end
    end
    return true
  end

  function index_path(self): string
    return self.index_file
  end

  --- What is at the worktree's `path`, and what `add` would record
  --- for it. `keep_mode` is the mode to keep where core.filemode is
  --- false.
  function hash_worktree(self, path: string, keep_mode?: integer): (Seen) | (nil, Failure)
    local full = self.worktree .. "/" .. path
    local st, _, errno = sys.lstat(full)
    if st == nil then
      if errno == sys.ENOENT or errno == sys.ENOTDIR then return {} end
      return nil, Failure.system(errno, full)
    end
    if st.kind == "link" then
      local target, trouble = Fs.readlink(full)
      if target == nil then return nil, trouble end
      local oid, ntrouble = name_of("blob", target)
      if oid == nil then return nil, ntrouble end
      return { st = st, blob = target, recorded = { mode = 0xA000, oid = raw_of(oid) } }
    end
    if st.kind ~= "file" then return { st = st } end
    local data, trouble = Fs.read(full)
    if data == nil then return nil, trouble end
    local mode = 0x81A4
    if config_bool(self.config, "core.filemode", true) then
      if st.mode & 0x40 ~= 0 then mode = 0x81ED end
    elseif keep_mode ~= nil and keep_mode & 0xF000 == 0x8000 then
      mode = keep_mode
    end
    local oid, ntrouble = name_of("blob", data)
    if oid == nil then return nil, ntrouble end
    return { st = st, blob = data, recorded = { mode = mode, oid = raw_of(oid) } }
  end

  --- How a submodule's directory differs from the commit its gitlink
  --- entry names: "modified" where the submodule's HEAD is another
  --- commit, "deleted" where the directory is gone, false where it is
  --- the same, or an empty directory or not yet cloned (git, too, says
  --- nothing of a submodule it has not set up). What is changed inside
  --- the submodule is not looked at.
  function submodule_change(self, e: Entry): (Git.ChangeKind | false) | (nil, Failure)
    local full = self.worktree .. "/" .. e.path
    local st, _, errno = sys.lstat(full)
    if st == nil then
      if errno == sys.ENOENT or errno == sys.ENOTDIR then return "deleted" end
      return nil, Failure.system(errno, full)
    end
    if st.kind ~= "dir" or not holds_repository(full) then return false end
    local head = submodule_head(full)
    if head == nil then return false end
    if head ~= Codec.hex(e.oid) then return "modified" end
    return false
  end

  --- The attributes of `path` that make `add` record other bytes than
  --- the file holds, as a reason in words; nil where git would record
  --- `content` as it is. This module runs no filter, so a path git would
  --- change by one is refused rather than hashed as it lies.
  function filter_trouble(self, cache: AttrCache, path: string, content: string): string?
    local fold = config_bool(self.config, "core.ignorecase", false)
    local autocrlf = (config_get(self.config, "core.autocrlf") or "false"):lower()
    if cache.global == nil then
      local into: mut {AttrRule} = {}
      local file = config_get(self.config, "core.attributesfile")
      if file == nil then
        local xdg = Env.get("XDG_CONFIG_HOME")
        local home = Env.get("HOME")
        file = if xdg ~= nil and xdg ~= "" then xdg .. "/git/attributes" elseif home ~= nil then home .. "/.config/git/attributes" else nil end
      end
      local text: string? = nil
      if file ~= nil then
        local got, _ = Fs.read(expand_home(file))
        text = got
      end
      if text ~= nil then parse_attributes(text, "", into, cache.macros) end
      cache.global = into
      local own: mut {AttrRule} = {}
      local info_text, _ = Fs.read(self.commondir .. "/info/attributes")
      if info_text ~= nil then parse_attributes(info_text, "", own, cache.macros) end
      cache.info = own
    end
    local rules: mut {AttrRule} = {}
    local global_rules: {AttrRule} = cache.global or {}
    for _, r in ipairs(global_rules) do rules[#rules + 1] = r end
    local dirs: mut {string} = { "" }
    local at = 0
    while true do
      local slash = path:find("/", at + 1, true)
      if slash == nil then break end
      dirs[#dirs + 1] = path:sub(1, slash)
      at = slash
    end
    for _, dir in ipairs(dirs) do
      local found = cache.dirs[dir]
      if found == nil then
        local own: mut {AttrRule} = {}
        local full = if dir == "" then self.worktree else self.worktree .. "/" .. dir:sub(1, -2) end
        -- git reads no .gitattributes that is a symbolic link: its text would come from outside the tree.
        local st, _ = sys.lstat(full .. "/.gitattributes")
        if st ~= nil and st.kind == "file" then
          local text, _ = Fs.read(full .. "/.gitattributes")
          if text ~= nil then parse_attributes(text, dir, own, cache.macros) end
        end
        cache.dirs[dir] = own
        found = own
      end
      for _, r in ipairs(found) do rules[#rules + 1] = r end
    end
    local info_rules: {AttrRule} = cache.info or {}
    for _, r in ipairs(info_rules) do rules[#rules + 1] = r end
    local function setting(name: string): AttrSetting?
      local found = attr_setting(rules, name, path, fold)
      if found ~= nil and found.how == "unspecified" then return nil end
      return found
    end
    local filter = setting("filter")
    if filter ~= nil and filter.how == "value" then
      local name = filter.value
      if name == "lfs" or config_get(self.config, "filter." .. name .. ".clean") ~= nil or
          config_get(self.config, "filter." .. name .. ".process") ~= nil then
        return "the " .. name .. " filter, which this module does not run"
      end
    end
    local ident = setting("ident")
    if ident ~= nil and ident.how == "set" then
      return "the ident attribute, which this module does not run"
    end
    local encoding = setting("working-tree-encoding")
    if encoding ~= nil and encoding.how == "value" then
      local named = encoding.value:lower():gsub("[^%w]", "")
      if named ~= "utf8" then
        return "working-tree-encoding " .. encoding.value .. ", which this module does not run"
      end
    end
    if content:find("\r", 1, true) == nil then return nil end
    -- A file with a carriage return is the only one a line-ending conversion changes on its way in. Git's auto mode
    -- (text=auto, core.autocrlf) leaves a file it takes for binary, one with a NUL or a lone CR.
    local binaryish = content:find("\0", 1, true) ~= nil or content:find("\r[^\n]") ~= nil or
      content:sub(-1) == "\r"
    local text, eol, crlf = setting("text"), setting("eol"), setting("crlf")
    local converts = false
    -- git reads `text`, then the older `crlf`, then `eol` (lf or crlf alone), then core.autocrlf.
    local action = "unspecified"
    if text ~= nil and text.how == "set" then
      action = "text"
    elseif text ~= nil and text.how == "unset" then
      action = "binary"
    elseif text ~= nil and text.how == "value" and text.value == "auto" then
      action = "auto"
    elseif crlf ~= nil and crlf.how == "set" then
      action = "text"
    elseif crlf ~= nil and crlf.how == "unset" then
      action = "binary"
    elseif crlf ~= nil and crlf.how == "value" and crlf.value == "input" then
      action = "text"
    elseif eol ~= nil and eol.how == "value" and (eol.value == "lf" or eol.value == "crlf") then
      action = "text"
    end
    if action == "unspecified" then
      if autocrlf == "input" or config_bool(self.config, "core.autocrlf", false) then
        action = "auto"
      end
    end
    if action == "text" then
      converts = true
    elseif action == "auto" then
      converts = not binaryish
    end
    if converts then
      return "a line-ending conversion (text, eol or core.autocrlf), which this module does not run"
    end
    return nil
  end

  --- How the worktree's `path` differs from its index entry, or nil
  --- when it does not.
  function worktree_change(self, e: Entry, index: Index, attrs: AttrCache,
                           filtered: mut {string}): (Git.ChangeKind | false) | (nil, Failure)
    if e.xflags & (XFLAG_SKIP_WORKTREE | XFLAG_INTENT_TO_ADD) ~= 0 then return false end
    if e.mode == 0xE000 then return self:submodule_change(e) end
    local full = self.worktree .. "/" .. e.path
    local st, _, errno = sys.lstat(full)
    if st == nil then
      if errno == sys.ENOENT or errno == sys.ENOTDIR then return "deleted" end
      return nil, Failure.system(errno, full)
    end
    local is_link = e.mode == 0xA000
    if st.kind == "dir" then return "deleted" end
    if (st.kind == "link") ~= is_link then return "typechange" end
    if not is_link and config_bool(self.config, "core.filemode", true) and
        (st.mode & 0x40 ~= 0) ~= (e.mode == 0x81ED) then
      return "modified"
    end
    local racy = e.mtime > index.mtime or (e.mtime == index.mtime and e.mtime_ns >= index.mtime_ns)
    local same_stat = e.mtime == st.mtime & U32 and e.mtime_ns == st.mtime_ns & U32 and
      e.size == st.size & U32 and e.ino == st.ino & U32 and e.ctime == st.ctime & U32
    if same_stat and not racy then return false end
    local seen, trouble = self:hash_worktree(e.path, e.mode)
    if seen == nil then return nil, trouble end
    local now = seen.recorded
    if now == nil then return "deleted" end
    -- Where the index holds what the file holds, git converts nothing on the way in: it is clean.
    if now.oid == e.oid then return false end
    if seen.blob ~= nil and not is_link and self:filter_trouble(attrs, e.path, seen.blob) ~= nil then
      filtered[#filtered + 1] = e.path
      return false
    end
    if e.size ~= 0 and e.size ~= st.size & U32 then return "modified" end
    if now.oid ~= e.oid then return "modified" end
    return false
  end

  function status(self): (Git.Status) | (nil, Failure)
    local ref, rtrouble = self:head_ref()
    if ref == nil then return nil, rtrouble end
    local head, htrouble = self:head()
    if head == nil then return nil, htrouble end
    local recorded: mut {string:Recorded} = {}
    if head ~= false then
      local c, ctrouble = self:commit_info(head)
      if c == nil then return nil, ctrouble end
      local ok, ftrouble = self:flatten(c.tree, "", recorded)
      if not ok then return nil, ftrouble end
    end
    local index, itrouble = read_index(self:index_path())
    if index == nil then return nil, itrouble end
    local staged: mut {Git.Change} = {}
    local unstaged: mut {Git.Change} = {}
    local unmerged: mut {string} = {}
    local filtered: mut {string} = {}
    local attrs: AttrCache = { dirs = {}, macros = {} }
    local in_index: mut {string:boolean} = {}
    for _, e in ipairs(index.entries) do
      if stage_of(e) ~= 0 then
        if in_index[e.path] == nil then unmerged[#unmerged + 1] = e.path end
        in_index[e.path] = true
      elseif e.xflags & XFLAG_INTENT_TO_ADD ~= 0 then
        in_index[e.path] = true
      else
        in_index[e.path] = true
        local was = recorded[e.path]
        if was == nil then
          staged[#staged + 1] = { path = e.path, kind = "added" }
        elseif (was.mode & 0xF000) ~= (e.mode & 0xF000) then
          staged[#staged + 1] = { path = e.path, kind = "typechange" }
        elseif was.oid ~= e.oid or was.mode ~= e.mode then
          staged[#staged + 1] = { path = e.path, kind = "modified" }
        end
        local change, wtrouble = self:worktree_change(e, index, attrs, filtered)
        if change == nil then return nil, wtrouble end
        if change ~= false then unstaged[#unstaged + 1] = { path = e.path, kind = change } end
      end
    end
    for path in pairs(recorded) do
      if in_index[path] == nil then staged[#staged + 1] = { path = path, kind = "deleted" } end
    end
    table.sort(staged, function(a: Git.Change, b: Git.Change): boolean return a.path < b.path end)
    local untracked, utrouble = self:untracked(index)
    if untracked == nil then return nil, utrouble end
    return {
      untracked = untracked,
      branch = if ref ~= false then ref:gsub("^refs/heads/", "") else nil end,
      head = if head ~= false then head else nil end,
      staged = staged, unstaged = unstaged, unmerged = unmerged, filtered = filtered,
    }
  end

  --- The worktree's untracked files, as `git status -uall` lists them.
  function untracked(self, index: Index): ({string}) | (nil, Failure)
    local tracked: mut {string:boolean} = {}
    local tracked_dirs: mut {string:boolean} = {}
    local gitlinks: mut {string:boolean} = {}
    for _, e in ipairs(index.entries) do
      tracked[e.path] = true
      if e.mode == 0xE000 then gitlinks[e.path] = true end
      local at = 0
      while true do
        local slash = e.path:find("/", at + 1, true)
        if slash == nil then break end
        tracked_dirs[e.path:sub(1, slash - 1)] = true
        at = slash
      end
    end
    local fold = config_bool(self.config, "core.ignorecase", false)
    local base_rules: mut {IgnoreRule} = {}
    local excludes = config_get(self.config, "core.excludesfile")
    if excludes == nil then
      local xdg = Env.get("XDG_CONFIG_HOME")
      local home = Env.get("HOME")
      excludes = if xdg ~= nil then xdg .. "/git/ignore" elseif home ~= nil then home .. "/.config/git/ignore" else nil end
    end
    local user_file = if excludes ~= nil then expand_home(excludes) else "" end
    for _, file in ipairs({ user_file, self.commondir .. "/info/exclude" }) do
      if file ~= "" then
        local text, _ = Fs.read(file)
        if text ~= nil then parse_ignore(text, "", base_rules) end
      end
    end
    local found: mut {string} = {}
    local function walk(dir: string, inherited: {IgnoreRule}): (true) | (nil, Failure)
      local full = if dir == "" then self.worktree else self.worktree .. "/" .. dir:sub(1, -2) end
      local rules = inherited
      -- git reads no .gitignore that is a symbolic link (O_NOFOLLOW): its text would come from outside the tree.
      local ignore_st, _ = sys.lstat(full .. "/.gitignore")
      local own: string? = nil
      if ignore_st ~= nil and ignore_st.kind == "file" then
        local text, _ = Fs.read(full .. "/.gitignore")
        own = text
      end
      if own ~= nil then
        local more: mut {IgnoreRule} = {}
        for _, r in ipairs(inherited) do more[#more + 1] = r end
        parse_ignore(own, dir, more)
        rules = more
      end
      -- readdir names each entry's kind as lstat would (it asks lstat where the file system does not say), so
      -- the walk needs no lstat of its own.
      local kinds, _, lerrno = sys.readdir(full)
      -- git warns of a directory it cannot open below the top, and goes on.
      if kinds == nil then
        if dir == "" then return nil, Failure.system(lerrno, full) end
        return true
      end
      local names: mut {string} = {}
      for name in pairs(kinds) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do
        local path = dir .. name
        local kind = kinds[name]!
        if name ~= ".git" then
          if kind == "dir" then
            if gitlinks[path] == nil and not is_ignored(rules, path, true, fold) then
              if tracked_dirs[path] == nil and holds_repository(full .. "/" .. name) then
                found[#found + 1] = path .. "/"
              else
                local ok, wtrouble = walk(path .. "/", rules)
                if not ok then return nil, wtrouble end
              end
            end
          elseif tracked[path] == nil and not is_ignored(rules, path, false, fold) then
            found[#found + 1] = path
          end
        end
      end
      return true
    end
    local ok, trouble = walk("", base_rules)
    if not ok then return nil, trouble end
    table.sort(found)
    return found
  end

  function ignored(self): ({string}) | (nil, Failure)
    local index, itrouble = read_index(self:index_path())
    if index == nil then return nil, itrouble end
    local tracked: mut {string:boolean} = {}
    local tracked_dirs: mut {string:boolean} = {}
    local gitlinks: mut {string:boolean} = {}
    for _, e in ipairs(index.entries) do
      tracked[e.path] = true
      if e.mode == 0xE000 then gitlinks[e.path] = true end
      local at = 0
      while true do
        local slash = e.path:find("/", at + 1, true)
        if slash == nil then break end
        tracked_dirs[e.path:sub(1, slash - 1)] = true
        at = slash
      end
    end
    local fold = config_bool(self.config, "core.ignorecase", false)
    local found: mut {string} = {}
    local function walk(dir: string, inherited: {IgnoreRule}): (true) | (nil, Failure)
      local full = if dir == "" then self.worktree else self.worktree .. "/" .. dir:sub(1, -2) end
      local rules = inherited
      local ignore_st, _ = sys.lstat(full .. "/.gitignore")
      local own: string? = nil
      if ignore_st ~= nil and ignore_st.kind == "file" then
        local text, _ = Fs.read(full .. "/.gitignore")
        own = text
      end
      if own ~= nil then
        local more: mut {IgnoreRule} = {}
        for _, r in ipairs(inherited) do more[#more + 1] = r end
        parse_ignore(own, dir, more)
        rules = more
      end
      local kinds, _, lerrno = sys.readdir(full)
      if kinds == nil then
        if dir == "" then return nil, Failure.system(lerrno, full) end
        return true
      end
      local names: mut {string} = {}
      for name in pairs(kinds) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do
        local path = dir .. name
        local kind = kinds[name]!
        if name ~= ".git" then
          if kind == "dir" then
            if gitlinks[path] == nil then
              if tracked_dirs[path] == nil and is_ignored(rules, path, true, fold) then
                found[#found + 1] = path .. "/"
              elseif tracked_dirs[path] == nil and holds_repository(full .. "/" .. name) then
                -- A nested repository is not this one's to read.
              else
                local ok, wtrouble = walk(path .. "/", rules)
                if not ok then return nil, wtrouble end
              end
            end
          elseif tracked[path] == nil and is_ignored(rules, path, false, fold) then
            found[#found + 1] = path
          end
        end
      end
      return true
    end
    local ok, trouble = walk("", {})
    if not ok then return nil, trouble end
    table.sort(found)
    return found
  end

  --- `path` as an index path: relative to the top of the worktree,
  --- with no `.`, `..` or `.git` part.
  function index_name(self, path: string): (string) | (nil, Failure)
    if path:sub(1, 1) == "/" then
      local inside, _ = Fs.relative(path, self.worktree)
      if inside == nil or not Fs.within(path, self.worktree) then
        return refuse("path is outside the worktree", path)
      end
      path = inside
    end
    path = path:gsub("^%./", ""):gsub("/+$", "")
    local bad = path_trouble(path)
    if bad ~= nil then return refuse(bad, path) end
    -- Every directory on the way must be a real one: a link there would
    -- read, and record, a file from wherever it points.
    local walked = self.worktree
    local parts: mut {string} = {}
    for part in path:gmatch("[^/]+") do parts[#parts + 1] = part end
    for i = 1, #parts - 1 do
      walked = walked .. "/" .. parts[i]!
      local st, _, errno = sys.lstat(walked)
      if st == nil then
        if errno == sys.ENOENT or errno == sys.ENOTDIR then break end
        return nil, Failure.system(errno, walked)
      end
      if st.kind ~= "dir" then
        return refuse("path goes through a symbolic link or a file", path)
      end
    end
    return path
  end

  function add(self, paths: {string}): (true) | (nil, Failure)
    local index_file = self:index_path()
    local lock, ltrouble = take_lock(index_file, "")
    if lock == nil then return nil, ltrouble end
    local function fail(why: Failure): nil, Failure
      drop_lock(lock)
      return nil, why
    end
    local index, itrouble = read_index(index_file)
    if index == nil then return fail(itrouble) end
    local by_path: mut {string:Entry} = {}
    for _, e in ipairs(index.entries) do
      if stage_of(e) == 0 then by_path[e.path] = e end
    end
    if index.mtime == 0 and #index.entries == 0 then
      local wanted = config_get(self.config, "index.version")
      if wanted == "4" or (wanted == nil and config_bool(self.config, "feature.manyfiles", false)) then
        index.version = 4
      end
    end
    local attrs: AttrCache = { dirs = {}, macros = {} }
    local drop: mut {string:boolean} = {}
    local put: mut {string:Entry} = {}
    for _, given in ipairs(paths) do
      local path, ntrouble = self:index_name(given)
      if path == nil then return fail(ntrouble) end
      local old = by_path[path]
      local seen, strouble = self:hash_worktree(path, if old ~= nil then old.mode else nil end)
      if seen == nil then return fail(strouble) end
      drop[path] = true
      local now, st, blob = seen.recorded, seen.st, seen.blob
      if now ~= nil and now.mode == 0xA000 and path:lower():match("[^/]*$") == ".gitmodules" then
        return fail(Failure.new("git: .gitmodules may not be a symbolic link", path))
      end
      if now ~= nil and st ~= nil and blob ~= nil then
        local why: string? = nil
        if now.mode ~= 0xA000 then why = self:filter_trouble(attrs, path, blob) end
        if why ~= nil then
          return fail(Failure.new("git: not added: " .. path .. " needs " .. why, path))
        end
        local oid, wtrouble = self:write_object("blob", blob)
        if oid == nil then return fail(wtrouble) end
        put[path] = {
          ctime = st.ctime, ctime_ns = st.ctime_ns, mtime = st.mtime, mtime_ns = st.mtime_ns,
          dev = st.dev, ino = st.ino, mode = now.mode, uid = st.uid, gid = st.gid, size = st.size,
          oid = now.oid, flags = 0, xflags = 0, path = path,
        }
      elseif st ~= nil then
        return fail(Failure.new("git: not a file or a symbolic link; name the files in a directory", path))
      elseif old == nil then
        local any = false
        for _, e in ipairs(index.entries) do
          if e.path == path then any = true end
        end
        if not any then
          return fail(Failure.new("git: no such file, and none in the index", path))
        end
      end
    end
    local entries: mut {Entry} = {}
    for _, e in ipairs(index.entries) do
      local gone = drop[e.path] == true
      if not gone then
        -- A file put where a directory was drops the directory's
        -- entries, and a file put under what was a file drops the file.
        for path in pairs(put) do
          if e.path:sub(1, #path + 1) == path .. "/" or path:sub(1, #e.path + 1) == e.path .. "/" then
            gone = true
          end
        end
      end
      if not gone then entries[#entries + 1] = e end
    end
    for _, e in pairs(put) do entries[#entries + 1] = e end
    table.sort(entries, entry_before)
    local now = Clock.now_ns() // NS
    local fd, _, errno = sys.open(lock, sys.O_WRONLY | sys.O_TRUNC)
    if fd == nil then return fail(Failure.system(errno, lock)) end
    local ok, wtrouble = Fs.put(fd, index_bytes(entries, now - 1, index.version))
    local closed, ctrouble = Fs.close(fd)
    if not ok then return fail(wtrouble) end
    if not closed then return fail(ctrouble) end
    return commit_lock(lock)
  end

  function write_tree(self): (string) | (nil, Failure)
    local index, trouble = read_index(self:index_path())
    if index == nil then return nil, trouble end
    return self:tree_of(index.entries)
  end

  --- Writes the trees the entries make and returns the top one's oid.
  function tree_of(self, entries: {Entry}): (string) | (nil, Failure)
    local record Node
      files: mut {string:Recorded}
      dirs: mut {string:Node}
    end
    local top: Node = { files = {}, dirs = {} }
    for _, e in ipairs(entries) do
      if stage_of(e) ~= 0 then return refuse("the index has unmerged paths: " .. e.path) end
      if e.xflags & XFLAG_INTENT_TO_ADD == 0 then
        local bad = path_trouble(e.path)
        if bad ~= nil then return refuse("the index holds a path git refuses: " .. bad, e.path) end
        local kind = e.mode & 0xF000
        local mode = if kind == 0x8000 then (if e.mode & 0x49 ~= 0 then 0x81ED else 0x81A4 end)
          elseif kind == 0xA000 or kind == 0xE000 then kind else 0 end
        if mode == 0 then return refuse("the index holds an entry of unknown mode", e.path) end
        local node = top
        local parts: mut {string} = {}
        for part in e.path:gmatch("[^/]+") do parts[#parts + 1] = part end
        for i = 1, #parts - 1 do
          local part = parts[i]!
          if node.files[part] ~= nil then
            return refuse("the index holds a file and a directory at once", e.path)
          end
          local next_node = node.dirs[part]
          if next_node == nil then
            next_node = { files = {}, dirs = {} }
            node.dirs[part] = next_node
          end
          node = next_node
        end
        local leaf = parts[#parts]!
        if node.files[leaf] ~= nil or node.dirs[leaf] ~= nil then
          return refuse("the index holds a path twice, or a file and a directory at once", e.path)
        end
        node.files[leaf] = { mode = mode, oid = e.oid }
      end
    end
    local function write(node: Node): (string) | (nil, Failure)
      local keys: mut {string} = {}
      local bytes: mut {string:string} = {}
      for name, f in pairs(node.files) do
        local key = tree_key(name, f.mode)
        keys[#keys + 1] = key
        bytes[key] = mode_text(f.mode) .. " " .. name .. "\0" .. f.oid
      end
      for name, sub in pairs(node.dirs) do
        local oid, trouble = write(sub)
        if oid == nil then return nil, trouble end
        keys[#keys + 1] = name .. "/"
        bytes[name .. "/"] = "40000 " .. name .. "\0" .. raw_of(oid)
      end
      table.sort(keys)
      local body: mut {string} = {}
      for _, key in ipairs(keys) do body[#body + 1] = bytes[key]! end
      return self:write_object("tree", table.concat(body))
    end
    return write(top)
  end

  --- Who did something, from the environment or the config.
  function identity(self, role: string): (Git.Person) | (nil, Failure)
    local upper = role:upper()
    local name = Env.get("GIT_" .. upper .. "_NAME") or config_get(self.config, "user.name")
    local email = Env.get("GIT_" .. upper .. "_EMAIL") or config_get(self.config, "user.email")
    if name == nil or email == nil or name == "" then
      return refuse("no " .. role .. " identity: set user.name and user.email in the config")
    end
    local time = Clock.now_ns() // NS
    local tz = local_offset(time)
    local date = Env.get("GIT_" .. upper .. "_DATE")
    if date ~= nil then
      local secs, zone = date:match("^@?(%d+) ([%+%-]%d%d%d%d)$")
      if secs == nil or zone == nil then
        return refuse("GIT_" .. upper .. "_DATE must be \"<seconds> <+zone>\"")
      end
      time = math.tointeger(tonumber(secs)) or time
      tz = zone
    end
    return { name = name, email = email, time = time, tz = tz }
  end

  --- Moves `ref` from `old` (an oid, or nil for one that must not
  --- exist) to `new` under its lock, and logs the move.
  function update_ref(self, ref: string, old: string?, new: string, reason: string,
                      who: Git.Person): (true) | (nil, Failure)
    if not valid_ref(ref) then return refuse("not a ref name: " .. ref) end
    local path = self:ref_path(ref)
    local made, mtrouble = Fs.mkdirs(Fs.dirname(path))
    if not made then return nil, mtrouble end
    local lock, ltrouble = take_lock(path, new .. "\n")
    if lock == nil then return nil, ltrouble end
    local current, ctrouble = self:ref_value(ref)
    if current == nil then
      drop_lock(lock)
      return nil, ctrouble
    end
    if (if current == false then nil else current end) ~= old then
      drop_lock(lock)
      return refuse(ref .. " moved while committing; nothing was changed")
    end
    -- The reflog is written under the lock, before the ref moves, as git
    -- does: a failure leaves the ref where it was.
    local line = (old or ZERO_OID) .. " " .. new .. " " .. format_person(who) .. "\t" ..
      reason:gsub("\n.*", "") .. "\n"
    local logs: {string} = { ref }
    if ref ~= "HEAD" then logs = { ref, "HEAD" } end
    local log_all = config_bool(self.config, "core.logallrefupdates", true)
    for _, name in ipairs(logs) do
      local log_path = (if name == "HEAD" then self.gitdir else self.commondir end) .. "/logs/" .. name
      local present, _ = sys.lstat(log_path)
      if log_all or present ~= nil then
        local dir_ok, dtrouble = Fs.mkdirs(Fs.dirname(log_path))
        if not dir_ok then
          drop_lock(lock)
          return nil, dtrouble
        end
        local logged, atrouble = Fs.append(log_path, line)
        if not logged then
          drop_lock(lock)
          return nil, atrouble
        end
      end
    end
    return commit_lock(lock)
  end

  --- Holds the index's lock for the whole commit, as git does, so no
  --- `git add` changes the index between the tree written and HEAD
  --- moved.
  function commit(self, opts: Git.CommitOptions): (string) | (nil, Failure)
    local lock, ltrouble = take_lock(self:index_path(), "")
    if lock == nil then return nil, ltrouble end
    local oid, trouble = self:commit_held(opts)
    drop_lock(lock)
    if oid == nil then return nil, trouble end
    return oid
  end

  function commit_held(self, opts: Git.CommitOptions): (string) | (nil, Failure)
    if opts.message:gsub("%s", "") == "" then return refuse("an empty commit message") end
    local ref, rtrouble = self:head_ref()
    if ref == nil then return nil, rtrouble end
    local target = if ref ~= false then ref else "HEAD" end
    local parent, ptrouble = self:resolve_ref(target)
    if parent == nil then return nil, ptrouble end
    local tree, ttrouble = self:write_tree()
    if tree == nil then return nil, ttrouble end
    local parent_oid: string? = if parent ~= false then parent else nil end
    if parent_oid ~= nil and opts.allow_empty ~= true then
      local pc, pctrouble = self:commit_info(parent_oid)
      if pc == nil then return nil, pctrouble end
      if pc.tree == tree then return refuse("nothing to commit: the index matches HEAD") end
    end
    local author = opts.author
    if author == nil then
      local a, atrouble = self:identity("author")
      if a == nil then return nil, atrouble end
      author = a
    end
    local committer = opts.committer
    if committer == nil then
      local c, ctrouble = self:identity("committer")
      if c == nil then return nil, ctrouble end
      committer = c
    end
    for _, who in ipairs({ author, committer }) do
      if (who.name .. who.email):find("[<>\n%z]") ~= nil or who.name == "" then
        return refuse("an identity may not hold <, >, a newline or a NUL: " .. who.name .. " <" .. who.email .. ">")
      end
      if who.tz:find("^[%+%-]%d%d%d%d$") == nil or who.time < 0 then
        return refuse("an identity's time must be seconds and a +hhmm zone: " .. who.tz)
      end
    end
    local message = opts.message
    if message:find("%z") ~= nil then return refuse("a commit message may not hold a NUL") end
    if message:sub(-1) ~= "\n" then message = message .. "\n" end
    local lines: mut {string} = { "tree " .. tree }
    if parent_oid ~= nil then lines[#lines + 1] = "parent " .. parent_oid end
    lines[#lines + 1] = "author " .. format_person(author)
    lines[#lines + 1] = "committer " .. format_person(committer)
    local oid, wtrouble = self:write_object("commit", table.concat(lines, "\n") .. "\n\n" .. message)
    if oid == nil then return nil, wtrouble end
    local reason = (if parent_oid == nil then "commit (initial): " else "commit: " end) .. message
    local ok, utrouble = self:update_ref(target, parent_oid, oid, reason, committer)
    if not ok then return nil, utrouble end
    return oid
  end
end

------------------------------------------------------------------
-- opening
------------------------------------------------------------------

--- The gitdir a `.git` path names: itself when a directory, or the
--- directory a `gitdir: ` file points at.
local function gitdir_of(dot_git: string): (string | false) | (nil, Failure)
  local st, _, errno = sys.stat(dot_git)
  if st == nil then
    if errno == sys.ENOENT or errno == sys.ENOTDIR then return false end
    return nil, Failure.system(errno, dot_git)
  end
  if st.kind == "dir" then return dot_git end
  local text, trouble = Fs.read(dot_git)
  if text == nil then return nil, trouble end
  local target = text:match("^gitdir: (.-)%s*$")
  if target == nil then return refuse("a .git file without a gitdir line", dot_git) end
  if target:sub(1, 1) ~= "/" then target = Fs.dirname(dot_git) .. "/" .. target end
  return target
end

--- Opens the repository whose worktree holds `path` (default the
--- current directory), looking up from it for `.git` as git does. A
--- bare repository is refused: this module works on a worktree.
---
--- The environment says what it does to git. GIT_DIR names the
--- repository's own directory, and the worktree is then `path` (git:
--- the current directory) unless GIT_WORK_TREE names it; GIT_WORK_TREE
--- alone moves the worktree of the repository found by looking up from
--- `path`; GIT_INDEX_FILE names the index file. With `plain` true none of
--- the three is read: the repository is the one found by looking up from `path`.
function Git.open(path?: string, plain?: boolean): (Git.Repo) | (nil, Failure)
  local start, atrouble = Fs.absolute(path or ".")
  if start == nil then return nil, atrouble end
  local top = start:gsub("/+$", "")
  local gitdir: string
  local given_dir = if plain == true then nil else Env.get("GIT_DIR") end
  if given_dir ~= nil and given_dir ~= "" then
    local named, ntrouble = Fs.absolute(given_dir)
    if named == nil then return nil, ntrouble end
    local found, trouble = gitdir_of(named)
    if found == nil then return nil, trouble end
    if found == false then return refuse("GIT_DIR names no repository", given_dir) end
    gitdir = found
  else
    while true do
      local found, trouble = gitdir_of((if top == "" then "" else top end) .. "/.git")
      if found == nil then return nil, trouble end
      if found ~= false then
        gitdir = found
        break
      end
      if top == "" then return refuse("not inside a git worktree", start) end
      top = top:match("^(.*)/[^/]*$") or ""
    end
  end
  local given_tree = if plain == true then "" else Env.get("GIT_WORK_TREE") or "" end
  local env_tree = given_tree ~= ""
  if env_tree then
    local named, ntrouble = Fs.absolute(given_tree)
    if named == nil then return nil, ntrouble end
    top = named:gsub("/+$", "")
  end
  if top == "" then top = "/" end
  local index_file = gitdir .. "/index"
  local given_index = if plain == true then nil else Env.get("GIT_INDEX_FILE") end
  if given_index ~= nil and given_index ~= "" then
    local named, ntrouble = Fs.absolute(given_index)
    if named == nil then return nil, ntrouble end
    index_file = named
  end
  local commondir = gitdir
  local common_text, _ = Fs.read(gitdir .. "/commondir")
  if common_text ~= nil then
    local named = common_text:gsub("%s+$", "")
    commondir = if named:sub(1, 1) == "/" then named else gitdir .. "/" .. named end
    local real, _ = Fs.absolute(commondir)
    if real ~= nil then commondir = real end
  end
  local config: Config = {}
  local real_gitdir, _ = Fs.absolute(gitdir)
  local head_text, _ = Fs.read(gitdir .. "/HEAD")
  local branch: string? = if head_text ~= nil then head_text:match("^ref: refs/heads/(%S+)") else nil end
  local included: IncludeCount = { files = 0 }
  local function source(file: string): ConfigSource
    return { file = file, gitdir = real_gitdir or gitdir, branch = branch, depth = 0, included = included }
  end
  local home = Env.get("HOME")
  local xdg = Env.get("XDG_CONFIG_HOME") or (home and home .. "/.config")
  local global_file = Env.get("GIT_CONFIG_GLOBAL")
  local user_files: {string} = if global_file ~= nil then { global_file } else {
    xdg and xdg .. "/git/config" or "", home and home .. "/.gitconfig" or "" } end
  for _, file in ipairs(user_files) do
    if file ~= "" then
      local text, _ = Fs.read(file)
      if text ~= nil then
        local ok, trouble = parse_config(text, config, source(file))
        if not ok then return nil, trouble end
      end
    end
  end
  local repo_config: Config = {}
  local text, ctrouble = Fs.read(commondir .. "/config")
  if text == nil then return nil, ctrouble end
  local parsed, ptrouble = parse_config(text, repo_config, source(commondir .. "/config"))
  if not parsed then return nil, ptrouble end
  if config_bool(repo_config, "extensions.worktreeconfig", false) then
    local wt, _ = Fs.read(gitdir .. "/config.worktree")
    if wt ~= nil then
      local ok, trouble = parse_config(wt, repo_config, source(gitdir .. "/config.worktree"))
      if not ok then return nil, trouble end
    end
  end
  local version = config_get(repo_config, "core.repositoryformatversion") or "0"
  if version ~= "0" and version ~= "1" then
    return refuse("repository format version " .. version .. " is not supported", commondir)
  end
  for name, values in pairs(repo_config) do
    local ext = name:match("^extensions%.(.+)$")
    if ext ~= nil and version == "1" then
      if KNOWN_EXTENSIONS[ext] == nil then
        return refuse("repository extension " .. ext .. " is not supported", commondir)
      end
      local value = (values[#values] or ""):lower()
      if ext == "objectformat" and value ~= "sha1" then
        return refuse("object format " .. value .. " is not supported", commondir)
      end
      if ext == "refstorage" and value ~= "files" then
        return refuse("ref storage " .. value .. " is not supported", commondir)
      end
    end
  end
  if config_bool(repo_config, "core.bare", false) and common_text == nil and not env_tree then
    return refuse("a bare repository has no worktree", commondir)
  end
  if config_get(repo_config, "core.worktree") ~= nil and not env_tree then
    return refuse("core.worktree is not supported", commondir)
  end
  for name, values in pairs(repo_config) do
    local list = config[name]
    if list == nil then
      config[name] = values
    else
      for _, v in ipairs(values) do list[#list + 1] = v end
    end
  end
  local object_dirs: mut {string} = { commondir .. "/objects" }
  local alternates, _ = Fs.read(commondir .. "/objects/info/alternates")
  if alternates ~= nil then
    for line in alternates:gmatch("[^\n]+") do
      if line:sub(1, 1) ~= "#" then
        object_dirs[#object_dirs + 1] = if line:sub(1, 1) == "/" then line else commondir .. "/objects/" .. line end
      end
    end
  end
  local repo: Repository = {
    gitdir = gitdir, commondir = commondir, worktree = top, index_file = index_file, config = config,
    object_dirs = object_dirs, packs = nil, shallow = nil, cache = {}, cached = 0, pack_trouble = nil,
  }
  return repo
end

return Git
