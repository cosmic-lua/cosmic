--- What `cosmic fix` keeps of laying out a Teal file that it left as it was, so that a run over a tree does not render
--- again the files that have not changed.
---
--- A file's layout ([`build.fix`]'s `source`) is a function of its text, its name and the code that makes it: the
--- compiler that parses it and the modules of the layout. The answer kept is that this text, under this name, was
--- laid out as it stands. It is kept in the check memo ([`build.check_memo`]) under the SHA-256 of the compiler's
--- bytecode and that of each module the layout runs, of the core's identity and of the name and text, so a
--- change to any of them misses and the layout runs. A file the layout changes or refuses is not kept: it is laid out
--- again each run, and a run that writes it keeps what it wrote as the next run's text.
---
--- A memo is an optimization and never an answer: where it cannot be opened, or the code that made an answer cannot be
--- named, a file is laid out.
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local check_memo = require("build.check_memo")

local record laid
  --- A run's use of the memo: its database, which is in a transaction until [`laid.finish`], and the salt its keys hold.
  record Kept
    memo: Sqlite.Handle
    salt: string
  end

  --- The modules the layout runs, which a test holds to what the layout's sources require
  --- ([`build/fix/laid_test.tl`]): those of [`fix.source`], which [`build.fix`] itself holds.
  modules: {string}

  --- The salt of the code that lays out a file, or nil where some of it cannot be named.
  salt: function(): string | nil
  --- Begins a run over the memo in `db`, nil where it cannot or where the code cannot be named. A test gives the `salt`
  --- it keys by.
  begin: function(db: Sqlite.Handle, salt?: string): laid.Kept | nil
  --- Whether `kept` holds that the text `source` of the file `name` is laid out as it stands.
  holds: function(kept: laid.Kept, name: string, source: string): boolean
  --- Keeps that `source` of `name` is laid out as it stands.
  keep: function(kept: laid.Kept, name: string, source: string)
  --- Ends the run: with `whole`, a run over every file, the answers it did not use are dropped.
  finish: function(kept: laid.Kept, whole: boolean)
end

laid.modules = { "build.fix", "build.fix.breaks", "build.fix.ctx", "build.fix.emit", "build.fix.equiv", "build.fix.expr",
  "build.fix.render", "build.fix.rule", "build.fix.sig", "build.fix.stmt", "build.fix.typescan", "build.ast",
  "build.ast.match", "build.ast.match_cast", "build.ast.node", "build.ast.requires", "build.ast.rewrite", "build.ast.walk",
  "build.plural", "cosmic.string" }

local KIND <const> = "laid"

function laid.salt(): string | nil
  local parts: {string} = { "laid 1" }
  -- The core's own digest: what the modules do runs on it. (The boot hash moves with every module of the tool, which the
  -- bytecode of the layout's own modules names more narrowly.)
  local identity = Store.meta("host_image")
  if identity == nil then
    return nil
  end
  parts[#parts + 1] = identity
  local compiler, _ = Store.bytecode("vendor.tl")
  if compiler == nil then
    return nil
  end
  parts[#parts + 1] = Hash.hex_sha256(compiler)
  for _, name in ipairs(laid.modules) do
    local bytes, _ = Store.bytecode(name)
    if bytes == nil then
      return nil
    end
    parts[#parts + 1] = name .. "=" .. Hash.hex_sha256(bytes)
  end
  return Hash.hex_sha256(table.concat(parts, "\0"))
end

function laid.begin(db: Sqlite.Handle, salt?: string): laid.Kept | nil
  local keyed = salt or laid.salt()
  if keyed == nil then
    return nil
  end
  local prepared, _ = check_memo.prepare(db, KIND)
  if not prepared then
    return nil
  end
  return { memo = db, salt = keyed }
end

function laid.holds(kept: laid.Kept, name: string, source: string): boolean
  return check_memo.get(kept.memo, KIND, check_memo.key(kept.salt, name, source)) == "U"
end

function laid.keep(kept: laid.Kept, name: string, source: string)
  check_memo.put(kept.memo, KIND, check_memo.key(kept.salt, name, source), "U")
end

function laid.finish(kept: laid.Kept, whole: boolean)
  if whole then
    check_memo.finish(kept.memo, KIND)
  else
    local _, _ = Sqlite.run(kept.memo, "COMMIT")
  end
end

return laid
