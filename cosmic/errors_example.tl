--- Worked examples for [`cosmic.errors`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Errors = require("cosmic.errors")
local Sqlite = require("cosmic.sqlite")
local Test = require("cosmic.test")

--- The whole projection: the guidance shown is a catalog row of
--- cosmic.coverage, outside this module's closure, which only the
--- whole projection holds by a key.
Test.needs{ store = true }

local Example = {}

--- The call stack as text, under the message, for a failure a person
--- will read.
function Example.trace()
  local text = Errors.trace("could not load the config")
  print(text)
  assert(text:find("could not load the config", 1, true) == 1, text)
  assert(text:find("traceback", 1, true) ~= nil, text)
end

--- What cosmic prints beneath an error nothing caught: the doc comment
--- of the function the message came from, found in the error catalog by
--- the words the two share.
function Example.guidance()
  local text = Errors.guidance("coverage: collection is already active")
  print(text)
  assert(text ~= nil and text:find("Coverage.start (cosmic/coverage.tl:", 1, true) ~= nil,
    tostring(text))
  assert(Errors.guidance("nothing whatever like any message") == nil)
end

--- What to do about an error Lua itself raised, read from its message:
--- here a method called on a record's value made as a table literal,
--- which never gets the record's methods without a metatable, and the
--- same value made as the hint says. An error nothing caught prints
--- this beneath it, and a failed test under its failure line.
function Example.hint()
  local record Counter
    n: integer
  end
  function Counter:bump()
    self.n = self.n + 1
  end
  local bare: Counter = { n = 0 }
  local ok, err = pcall(function() bare:bump() end)
  assert(not ok)
  local text = Errors.hint(tostring(err))
  print(text)
  assert(text == "'bump' is nil on that value: either it was made as a table literal, " ..
      "which gets none of R's methods (make it with `setmetatable({ ... }, { __index = R })`), " ..
      "or R declares 'bump' and nothing defines `function R:bump`", tostring(text))
  assert(Errors.guidance(tostring(err)) == "cosmic: hint: " .. text .. "\n")
  local made: Counter = setmetatable({ n = 0 }, { __index = Counter })
  made:bump()
  assert(made.n == 1)
  assert(Errors.hint("nothing whatever like any message") == nil)
  assert(Errors.hint("wrapped: x.tl:3: attempt to call a nil value (method 'bump'): retried") == nil)
end

--- What one database's error catalog says of a message, asked of that
--- database alone: here a project's own catalog, one row whose words a
--- failure shares, indexed as a projection's is.
function Example.guidance_in()
  local db = assert(Sqlite.memory())
  assert(db:exec([[
    CREATE TABLE catalog (id INTEGER PRIMARY KEY, kind TEXT NOT NULL,
      module TEXT NOT NULL, symbol TEXT, message TEXT, text TEXT,
      file TEXT NOT NULL, line INTEGER NOT NULL);
    CREATE TABLE docs (id INTEGER PRIMARY KEY, module TEXT NOT NULL,
      source_symbol TEXT NOT NULL, text TEXT NOT NULL);
    CREATE VIRTUAL TABLE catalog_fts USING fts5(message, text,
      content=catalog, content_rowid=id);
    INSERT INTO catalog (kind, module, symbol, message, text, file, line)
      VALUES ('extracted', 'app.config', 'Config.load', 'config file is missing',
        'Run `app init` to write a config file.', 'app/config.tl', 42);
    INSERT INTO catalog_fts(catalog_fts) VALUES ('rebuild');
  ]]))
  local text = Errors.guidance_in(db, "app: config file is missing: ./app.toml")
  print(text)
  assert(text == "cosmic: Config.load (app/config.tl:42): " ..
      "Run `app init` to write a config file.\n", tostring(text))
  assert(Errors.guidance_in(db, "the network is unreachable") == nil)
  assert(db:close())
end

return Example
