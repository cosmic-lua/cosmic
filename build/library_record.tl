--- What the databases the running binary carries record of the standard library's modules, as the position check
--- asks it ([`positions.check`]). It is a module of its own so that neither [`build.positions`], which reads no
--- database, nor the code the compiler's identity holds requires the other for it.

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local symbols = require("cosmic.internal.symbols")
local type positions = require("build.positions")

local record library_record
end

--- The modules the binary's databases record as public, and the library's modules they carry beside those and leave
--- out. Only a database that records a public module is read: a test's worker holds its rows in the store of its
--- closure, beside a database that carries modules and records none, and a module of that one is not known to be
--- kept. A project's own rows name none of the library's. Nil where no database records one; a database that cannot
--- be read counts as one that records none.
function library_record.read(): positions.Library?
  local public: mut {string: boolean} = {}
  local kept: mut {string: boolean} = {}
  local recorded = false
  for _, db in ipairs(Store.databases()) do
    local rows, _ = Sqlite.text_rows(db, "SELECT path FROM public_modules")
    if rows ~= nil and #rows > 0 then
      recorded = true
      for _, row in ipairs(rows) do public[row:text(1)] = true end
      local left, _ = Sqlite.text_rows(db, "SELECT path FROM modules WHERE " .. symbols.library_modules("path") ..
          " AND path NOT IN (SELECT path FROM public_modules)")
      for _, row in ipairs(left or {}) do kept[row:text(1)] = true end
    end
  end
  if not recorded then
    return nil
  end
  return { public = public, kept = kept }
end

return library_record
