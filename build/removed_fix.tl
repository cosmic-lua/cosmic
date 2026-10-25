--- What to write instead of a name cosmic removed, as the `fix` of the new checker's error for it.
---
--- [`cosmic.removed`] lists the standard globals and `package` fields cosmic withholds, the members its modules no longer
--- have, and the records that replaced a boolean argument. The checker's error for each is the ordinary one (a name that
--- nothing declares, a field the record lacks, a type the module does not declare, a boolean where a record is wanted), whose
--- fix is generic and would send the program to declare what cosmic removed on purpose. [`RemovedFix.fix`] reads the
--- program around the error and answers the catalog's words in its place, the same words [`core/surface.c`] raises with when a running program reaches the name:
---
--- - an undeclared `os` (or `io`, `debug`, `dofile`, `loadfile`), with the field read through it when there is one:
---   `os.getenv is not available: use Env.get(name) (...)`;
--- - a `require` of a removed library, and a field of `package` the runtime withholds;
--- - a field, method or type of a module that no longer has it (`Hash.hex`, `Zip.ZipReader`): `Hash.hex was removed: ...`;
--- - a boolean given where a record now goes (`Sqlite.open(path, true)`): `Sqlite.OpenOptions replaced a boolean
---   argument: ...`.
---
--- The error is read by its code and place (the tokens at it), the types it is about, and the module a name was bound to by
--- `local X = require("module")`, never by its words. The driver ([`build.driver`]) calls it as it makes each problem.
--
-- TODO: say a member's sentence through [`cosmic.removed`], once it words a member's hint itself (the same TODO is in
-- [`build.docs`]): `X.m was removed: ...` is spelled here, in `docs` and in the fork's `replacement`, each from the
-- catalog's `members`.
local Lexer = require("lang.lexer")
local Scopes = require("lang.scopes")

local record RemovedFix
  --- What the fix reads of a module: its tokens and its scopes.
  record Source
    tokens: Lexer.Tokens
    scoped: Scopes.Scoped
  end

  --- The index of the token that begins at `offset` in `tokens`, or nil.
  token_at: function(tokens: Lexer.Tokens, offset: integer): integer?

  --- The words to write instead for the error `code` at `offset` (`length` bytes) of the module `source`, whose types are
  --- `types`; nil where the error is not about a removed name, and where [`cosmic.removed`] cannot be loaded.
  fix: function(source: Source, code: string, offset: integer, length: integer, types: {string}): string?
end

--- What this reads of [`cosmic.removed`].
local record Catalog
  replacements: {string: string}
  names: {string: string}
  members: {string: string}
  arguments: {string: string}
  message: function(name: string, field?: string): string
end

--- The module this quotes, named by a constant rather than a literal so that no parse records a `require` of it: the
--- catalog decides only what an error says, so it is no part of the compiler's identity.
local catalog_module <const> = "cosmic.removed"

--- [`cosmic.removed`], or nil where it cannot be loaded (a test that does not require it).
local function catalog(): Catalog?
  local ok, loaded = pcall(require, catalog_module)
  if not ok or not (loaded is {string: any}) then
    return nil
  end
  local names, members, arguments, message = loaded["names"], loaded["members"], loaded["arguments"], loaded["message"]
  local replacements = loaded["replacements"]
  if names is {string: string} and members is {string: string} and arguments is {string: string} and
      replacements is {string: string} and message is function(name: string, field?: string): string then
    return { names = names, members = members, arguments = arguments, replacements = replacements, message = message }
  end
  return nil
end

function RemovedFix.token_at(tokens: Lexer.Tokens, offset: integer): integer?
  local offsets = tokens.offset
  local low, high = 1, #offsets
  while low <= high do
    local middle = (low + high) // 2
    local at = offsets[middle]
    if at == nil then
      return nil
    elseif at == offset then
      return middle
    elseif at < offset then
      low = middle + 1
    else
      high = middle - 1
    end
  end
  return nil
end

--- The text of the token at `at`, or "" where there is none.
local function text_at(tokens: Lexer.Tokens, at: integer): string
  return tokens.text[at] or ""
end

--- The kind of the token at `at`, or "" where there is none.
local function kind_at(tokens: Lexer.Tokens, at: integer): string
  return tokens.kind[at] or ""
end

--- The name a field or a member may have at the token `at`: an identifier, or a word the grammar reserves that a field may
--- be called (`t.type`). nil where the token is neither.
local function name_at(tokens: Lexer.Tokens, at: integer): string?
  local kind = kind_at(tokens, at)
  if kind == "identifier" or kind == "keyword" then
    return text_at(tokens, at)
  end
  return nil
end

--- The module that `name` is bound to, by `local name = require("module")`, among the bindings `visible` at the error: nil
--- where it is bound to no module, or to nothing.
local function module_of(visible: {string: Scopes.Var}, name: string): string?
  local v = visible[name]
  if v == nil or v.module == "" then
    return nil
  end
  return v.module
end

--- The name of the type the first of `types` is, where it is a whole name (`Hash`, `Hash?`): the record of a module is
--- named as the module is, and a record nested in it ([`Fs.Stat`]) is another record, whose fields the module's removed
--- members were not. nil for any other.
local function type_name(types: {string}): string?
  for _, first in ipairs(types) do
    return first:match("^([%a_][%w_]*)%??$")
  end
  return nil
end

--- `os.getenv`, an `os` the program does not declare, with the field read through it.
local function removed_global(removed: Catalog, tokens: Lexer.Tokens, at: integer): string?
  local name = text_at(tokens, at)
  if removed.names[name] == nil then
    return nil
  end
  local dot = text_at(tokens, at + 1)
  if dot == "." or dot == ":" then
    return removed.message(name, name_at(tokens, at + 2))
  end
  return removed.message(name)
end

--- `require("io")`.
local function removed_module(removed: Catalog, tokens: Lexer.Tokens, at: integer): string?
  if text_at(tokens, at) ~= "require" or kind_at(tokens, at + 1) ~= "(" or kind_at(tokens, at + 2) ~= "string" then
    return nil
  end
  local name = tokens.value[at + 2]
  if name == nil or removed.names[name] == nil then
    return nil
  end
  return removed.message(name)
end

--- A field, a method or a type `head.key` (or `head:key`, `head["key"]`) that `module` no longer has.
local function removed_member(removed: Catalog, module: string?, head: string, sep: string, key: string): string?
  if module == nil then
    return nil
  end
  local instead = removed.members[module .. "." .. key]
  if instead == nil then
    return nil
  end
  if sep == "[" then
    return head .. "[\"" .. key .. "\"] was removed: " .. instead
  end
  return head .. sep .. key .. " was removed: " .. instead
end

--- A boolean given as an argument where a record now goes: the record `wanted` names (`Sqlite.OpenOptions?`), the token
--- before the value at `at` being the `(` or `,` that an argument follows.
local function removed_argument(removed: Catalog, source: RemovedFix.Source, at: integer, types: {string}): string?
  local before = text_at(source.tokens, at - 1)
  local got = types[1]
  local wanted = types[2]
  if got ~= "boolean" or wanted == nil or (before ~= "(" and before ~= ",") then
    return nil
  end
  local plain = wanted:gsub("%?$", "")
  local owner, option = plain:match("^([%a_][%w_]*)%.([%a_][%w_]*)$")
  if owner == nil or option == nil then
    return nil
  end
  local module = module_of(Scopes.in_scope(source.scoped, at), owner)
  if module == nil then
    return nil
  end
  -- TODO: attach this only where the callee is the function the record replaced an argument of ([`Sqlite.open`]), once
  -- the checker's error names its callee: a user's own `g(a: boolean, o?: Sqlite.OpenOptions)` called `g(true, true)`
  -- gets the sentence about [`Sqlite.open`] today.
  local instead = removed.arguments[module .. "." .. option]
  if instead == nil then
    return nil
  end
  return owner .. "." .. option .. " replaced a boolean argument: " .. instead
end

--- A read of a member in the tokens at `at`: `head.key`, `head:key`, `require("module").key`, or the string of
--- `head["key"]`.
local record Access
  --- How the program wrote what the member is read from (`Hash`, `h`, `require("cosmic.hash")`).
  head: string
  --- `.`, `:` or `[`.
  sep: string
  key: string
  --- The module a `require` call names, nil where the head is a name.
  module: string?
  --- The byte after the last token of the read, for `.` and `[`; a method call goes on to its arguments.
  ends: integer
end

--- The read at `at`, or nil where the tokens are not one of the four forms.
local function access_at(tokens: Lexer.Tokens, at: integer): Access?
  local first_text = text_at(tokens, at)
  local first_kind = kind_at(tokens, at)
  if first_kind == "" then
    return nil
  end
  local sep = text_at(tokens, at + 1)
  if first_kind == "identifier" and (sep == "." or sep == ":") then
    local key = name_at(tokens, at + 2)
    if key == nil then
      return nil
    end
    return { head = first_text, sep = sep, key = key, module = nil, ends = Lexer.stop(tokens, at + 2) }
  elseif first_kind == "string" and text_at(tokens, at - 1) == "[" and kind_at(tokens, at - 2) == "identifier" and
      text_at(tokens, at + 1) == "]" then
    -- the error of an index by a string is placed at the string
    local written = tokens.value[at]
    if written == nil then
      return nil
    end
    return { head = text_at(tokens, at - 2), sep = "[", key = written, module = nil, ends = Lexer.stop(tokens, at) }
  elseif first_text == "require" and kind_at(tokens, at + 1) == "(" and kind_at(tokens, at + 2) == "string" and
      text_at(tokens, at + 3) == ")" then
    local dot = text_at(tokens, at + 4)
    local key = name_at(tokens, at + 5)
    if (dot ~= "." and dot ~= ":") or key == nil then
      return nil
    end
    local value = tokens.value[at + 2]
    if value == nil then
      return nil
    end
    return {
      head = "require(\"" .. value .. "\")", sep = dot, key = key, module = value,
      ends = Lexer.stop(tokens, at + 5),
    }
  end
  return nil
end

--- A field, a method or a type read in the tokens at `at` that a module no longer has: the type of a variable that holds
--- a value of the module's own record is read through its own name (`local h: Hash`), and a type is named by a capital.
local function removed_through(removed: Catalog, source: RemovedFix.Source, code: string, at: integer, length: integer,
                               types: {string}): string?
  local tokens = source.tokens
  local access = access_at(tokens, at)
  local first = tokens.offset[at]
  if access == nil or first == nil or (access.sep ~= ":" and access.ends ~= first + length) then
    return nil
  end
  local visible = Scopes.in_scope(source.scoped, at)
  local head, sep, key = access.head, access.sep, access.key
  if code == "member_missing" then
    if sep ~= "." or access.module ~= nil or key:match("^%u") == nil then
      return nil
    end
    return removed_member(removed, module_of(visible, head), head, ".", key)
  end
  if head == "package" and sep ~= ":" and visible["package"] == nil and removed.replacements["package." .. key] ~= nil then
    return removed.message("package", key)
  end
  if access.module ~= nil then
    return removed_member(removed, access.module, head, sep, key)
  end
  -- The module is the one the name read through was bound to, or the one the record of the value was.
  local through = removed_member(removed, module_of(visible, head), head, sep, key)
  if through ~= nil then
    return through
  end
  local typename = type_name(types)
  if typename == nil then
    return nil
  end
  return removed_member(removed, module_of(visible, typename), head, sep, key)
end

function RemovedFix.fix(source: RemovedFix.Source, code: string, offset: integer, length: integer, types: {string}):
    string?
  local tokens = source.tokens
  local at = RemovedFix.token_at(tokens, offset)
  if at == nil then
    return nil
  end
  local removed = catalog()
  if removed == nil then
    return nil
  end
  if code == "unknown_variable" then
    return removed_global(removed, tokens, at)
  elseif code == "require_unknown" then
    return removed_module(removed, tokens, at)
  elseif code == "field_unknown" or code == "member_missing" then
    return removed_through(removed, source, code, at, length, types)
  elseif code == "not_assignable" then
    return removed_argument(removed, source, at, types)
  end
  return nil
end

return RemovedFix
