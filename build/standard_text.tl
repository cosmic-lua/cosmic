--- What the checker reads for a standard-library module (`cosmic.*`) a program requires: the module's source or its stub from
--- the databases the running binary carries ([`cosmic.store`]).

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")

local record standard_text
  --- What is read for a standard-library module: [`standard_text.of`].
  record Standard
    text: string
    --- Whether `text` is the module's stub rather than its source.
    stubbed: boolean
  end

  --- What the checker reads for the standard-library module `name`: what [`Store.source`] answers, a declaration's source or
  --- the module's, but for a module with no declaration whose stub ([`build.syntax_stub`]) the binary's own database carries;
  --- nil for a name the binary holds neither of. A declaration wins: a stub is held to its module's source, never to a
  --- declaration beside it. It says which it is, so a compile keyed on one is never taken for one keyed on the other. A
  --- stub keeps every position of its source, so either is served under the module's own file name. A database without the
  --- table (a sealed worker's, or a tool's from before it) answers sources.
  of: function(name: string): Standard?

  --- What the checker reads for the module `name` of the running binary, whatever its name: the tool's own modules beside the
  --- standard library's, each as [`standard_text.of`] reads a standard-library module. `cosmic -e` takes them so, since it
  --- is the tool's one-liner; nothing else does.
  own: function(name: string): Standard?
end

local function read(name: string): standard_text.Standard?
  local databases = Store.databases()
  local binary = databases[#databases]
  if binary ~= nil then
    local rows, _ = Sqlite.text_rows(binary,
      "SELECT inflate(source) FROM stubs WHERE path = ?1 " ..
        "AND path NOT IN (SELECT path FROM decls)", { { text = name } })
    local row: Sqlite.Row? = nil
    if rows ~= nil then row = rows[1] end
    if row ~= nil then
      return { text = row:text(1), stubbed = true }
    end
  end
  local source, _ = Store.source(name)
  if source == nil then
    return nil
  end
  return { text = source, stubbed = false }
end

function standard_text.of(name: string): standard_text.Standard?
  if name:sub(1, 7) ~= "cosmic." then
    return nil
  end
  return read(name)
end

function standard_text.own(name: string): standard_text.Standard?
  return read(name)
end

return standard_text
