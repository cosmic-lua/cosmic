--- The declarations the new checker types a program against besides the program's own and the bindings of C: the prelude of the
--- fork ([`checker/tl.tl`]'s `prelude`, the types the language itself has) and the Lua standard library
--- ([`checker/stdlib.d.tl`]). The tool carries both as rows of `decls` ([`CheckerDeclarations.prelude_module`],
--- [`CheckerDeclarations.stdlib_module`]), as it does the bindings of C, so that a project outside cosmic's tree has globals
--- when `COSMIC_GRAMMAR=new` compiles it ([`build.pipeline`]'s `options`): they are no module, and nothing requires them.
---
--- A module of its own, because [`build.writer`] reads the tree for them and the writer's closure is part of the writer's
--- identity ([`build.identity`]): it reaches no more of the tree than the files and the store.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")

local record CheckerDeclarations
  --- The two texts, the prelude and the standard library's declarations.
  record Texts
    prelude: string
    stdlib: string
  end

  --- The name the prelude is carried under in `decls`.
  prelude_module: function(): string

  --- The name the standard library's declarations are carried under in `decls`.
  stdlib_module: function(): string

  --- The prelude in `tl`, the text of [`checker/tl.tl`]: the text between its `[=====[` marks, nil where it has none.
  prelude_of: function(tl: string): string | nil

  --- The texts the tree at `root` holds, for a tool being written from it: the files themselves, held to the hashes the
  --- working database `db` staged them with, so that a file edited during the build is no part of the tool. nil and "" where
  --- the database stages neither file (a project's tree, whose `checker/` is its own); nil and why where it stages them and
  --- they are not what it staged.
  staged: function(db: Sqlite.Handle, root: string): Texts | nil, string

  --- The texts the running tool carries, nil and why where it carries none (a tool older than this, or a worker's store of
  --- the modules a test reads).
  carried: function(): Texts | nil, string
end

local TL <const> = "checker/tl.tl"
local STDLIB <const> = "checker/stdlib.d.tl"

function CheckerDeclarations.prelude_module(): string
  return "checker.prelude"
end

function CheckerDeclarations.stdlib_module(): string
  return "checker.stdlib"
end

function CheckerDeclarations.prelude_of(tl: string): string | nil
  return tl:match("%[=====%[\n(.-)%]=====%]")
end

--- The text of `file` below `root`, held to `hash`.
local function read_as(root: string, file: string, hash: string): string | nil, string
  local text, why = Fs.read(root .. "/" .. file)
  if text == nil then
    return nil, why
  end
  if Hash.hex_sha256(text) ~= hash then
    return nil, file .. " changed while the tool was being built: the tool is written from the file as it was staged"
  end
  return text, ""
end

function CheckerDeclarations.staged(db: Sqlite.Handle, root: string): CheckerDeclarations.Texts | nil, string
  local rows, trouble = Sqlite.text_rows(db, "SELECT path, sha256 FROM tool WHERE path IN (?1, ?2) ORDER BY path",
    { { text = TL }, { text = STDLIB } })
  if rows == nil then
    return nil, trouble
  end
  if #rows == 0 then
    return nil, ""
  end
  local tl_hash: string | nil = nil
  local stdlib_hash: string | nil = nil
  for _, row in ipairs(rows) do
    if row:text(1) == TL then
      tl_hash = row:text(2)
    else
      stdlib_hash = row:text(2)
    end
  end
  if tl_hash == nil then
    return nil, "the working database stages " .. STDLIB .. " without " .. TL .. ", which the tool carries together"
  end
  if stdlib_hash == nil then
    return nil, "the working database stages " .. TL .. " without " .. STDLIB .. ", which the tool carries together"
  end
  local tl, tl_why = read_as(root, TL, tl_hash)
  if tl == nil then
    return nil, tl_why
  end
  local stdlib, stdlib_why = read_as(root, STDLIB, stdlib_hash)
  if stdlib == nil then
    return nil, stdlib_why
  end
  local prelude = CheckerDeclarations.prelude_of(tl)
  if prelude == nil then
    return nil, TL .. " has no prelude between `[=====[` marks, which the tool carries"
  end
  return { prelude = prelude, stdlib = stdlib }, ""
end

function CheckerDeclarations.carried(): CheckerDeclarations.Texts | nil, string
  local prelude, prelude_why = Store.source(CheckerDeclarations.prelude_module())
  if prelude == nil then
    return nil, CheckerDeclarations.prelude_module() .. ": " .. prelude_why
  end
  local stdlib, stdlib_why = Store.source(CheckerDeclarations.stdlib_module())
  if stdlib == nil then
    return nil, CheckerDeclarations.stdlib_module() .. ": " .. stdlib_why
  end
  return { prelude = prelude, stdlib = stdlib }, ""
end

return CheckerDeclarations
