--- What to write instead of a standard global cosmic withholds, as the `fix` of the new checker's error for it.
---
--- [`cosmic.removed`] lists the standard globals and `package` fields cosmic withholds. The checker's error for each is the
--- ordinary one (a name that nothing declares, a field the record lacks), whose fix is generic and would send the program to
--- declare what cosmic withholds on purpose. [`RemovedFix.fix`] reads the program around the error and returns the
--- catalog's words in its place, the same words [`core/surface.c`] raises with when a running program reaches the name:
---
--- - an undeclared `os` (or `io`, `debug`, `dofile`, `loadfile`), with the field read through it when there is one:
---   `os.getenv is not available: use Env.get(name) (...)`;
--- - a `require` of a removed library, and a field of `package` the runtime withholds.
---
--- The error is read by its code and place (the tokens at it), never by its words. The driver ([`build.driver`]) calls it
--- as it makes each problem.
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

  --- The words to write instead for the error `code` at `offset` (`length` bytes) of the module `source`; nil where the
  --- error is not about a withheld name, and where [`cosmic.removed`] cannot be loaded.
  fix: function(source: Source, code: string, offset: integer, length: integer): string?
end

--- What this reads of [`cosmic.removed`].
local record Catalog
  replacements: {string: string}
  names: {string: string}
  message: function(name: string, field?: string): string
end

--- [`cosmic.removed`] where the process has loaded it, else nil (a test that does not require it). This reads what
--- `package.loaded` holds and requires nothing by any name: the catalog decides only what an error says, so it is no part
--- of the compiler's identity. The tool's entry loads it ([`build.dispatch`]); a test that reads what it says requires it.
local function catalog(): Catalog?
  local loaded = package.loaded["cosmic.removed"]
  if not (loaded is {string: any}) then -- checked: is_on_record
    return nil
  end
  local function strings(key: string): {string: string}?
    local table_of = loaded[key]
    if table_of is {string: string} then -- checked: is_on_record
      return table_of
    end
    return nil
  end
  local names, replacements = strings("names"), strings("replacements")
  local message = loaded["message"]
  if names ~= nil and replacements ~= nil and
      message is function(name: string, field?: string): string then -- checked: is_on_record
    return { names = names, replacements = replacements, message = message }
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

--- A field of `package` the runtime withholds, read as `package.key` or `package["key"]` where the program declares no
--- `package` of its own.
local function removed_package_field(removed: Catalog, source: RemovedFix.Source, at: integer, length: integer): string?
  local tokens = source.tokens
  local first = tokens.offset[at]
  if first == nil then
    return nil
  end
  local key: string? = nil
  local ends = 0
  if text_at(tokens, at) == "package" and text_at(tokens, at + 1) == "." then
    key, ends = name_at(tokens, at + 2), Lexer.stop(tokens, at + 2)
  elseif kind_at(tokens, at) == "string" and text_at(tokens, at - 1) == "[" and text_at(tokens, at - 2) == "package" and
      text_at(tokens, at + 1) == "]" then
    -- the error of an index by a string is placed at the string
    key, ends = tokens.value[at], Lexer.stop(tokens, at)
  end
  if key == nil or ends ~= first + length or Scopes.in_scope(source.scoped, at)["package"] ~= nil or
      removed.replacements["package." .. key] == nil then
    return nil
  end
  return removed.message("package", key)
end

function RemovedFix.fix(source: RemovedFix.Source, code: string, offset: integer, length: integer): string?
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
  elseif code == "field_unknown" then
    return removed_package_field(removed, source, at, length)
  end
  return nil
end

return RemovedFix
