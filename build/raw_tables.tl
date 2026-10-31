--- Typed access to the raw tables the core hands a module's loader.
---
--- core/store.c hands each wrapper of its `raw_modules` the C table behind
--- it ([`cosmic.internal.process`] to [`cosmic.child`], say) as the `extra`
--- value of the store's searcher, and `require` passes it on to the
--- loader. A test or a tool that calls the C bindings itself asks the
--- searchers for it by hand, which is no escalation: the table reaches
--- nothing the wrapper does not already. The searchers answer it only for
--- a module of the caller's closure, so a caller requires the wrapper:
---
---     local _ = require("cosmic.child")
---     local process = RawTables.process()
---
--- The searchers hand it back untyped. This module is the one place it is
--- checked and given its type: each accessor refuses, naming the wrapper
--- and what it lacked, a wrapper handed no table, a table with a key that
--- is no name, and a table that lacks the members it is asked to be a
--- table of. The members are a few of each declaration, enough to tell the
--- tables apart and to catch a wrapper handed another's; that the rest of
--- a declaration matches the core is core/declarations_test.tl's to hold.
--- What an accessor answers is the very table the loader is handed, not a
--- copy: a test that replaces a member of it ([`build.confine`]'s `spawn`,
--- say) replaces it for the module too. No `as` stands behind the type, only
--- [`cosmic.shape`]'s `into`, which the checks above precede.
---
--- A module that needs the table of a wrapper not named here names it:
--- `process("build.confine")`.
local Shape = require("cosmic.shape")
local type raw_process = require("cosmic.internal.process")
local type raw_socket = require("cosmic.internal.socket")

local record raw_tables
  --- The table core/store.c hands `wrapper`'s loader, by name. A reflection
  --- test reads the members of a table no declaration describes through
  --- it. Raises where `wrapper` is handed no table or one with a key that
  --- is no name.
  fields: function(wrapper: string): {string: any}
  --- The process table (core/process.h) handed `wrapper`, [`cosmic.child`]'s
  --- by default.
  process: function(wrapper?: string): raw_process
  --- The socket table (core/socket.h) handed `wrapper`, [`cosmic.net`]'s by
  --- default.
  socket: function(wrapper?: string): raw_socket
end

--- A table whose keys are all names, whatever it holds: `into` answers a copy of it, which a check can read by name.
--- `optional` lets the value [`Json.null`] (the raw json table holds it) through, which the copy leaves out.
local NAMED <const> = Shape.map(Shape.optional(Shape.any))

--- The table the store's searchers hand `wrapper`'s loader, as the `T` the caller names, which holds a function for
--- each of `required`: the members that tell this table from another's. It is the very table the loader is handed, not
--- a copy: a test that replaces a member of it replaces it for the module too.
local function table_behind<T>(wrapper: string, required: {string}): T
  for _, searcher in ipairs(package.searchers) do
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then
      local named, why = Shape.into(extra, NAMED)
      assert(named, wrapper .. " is handed a raw table that is no table of the core's: " .. why)
      for _, name in ipairs(required) do
        if type(named[name]) ~= "function" then
          error(wrapper .. " is handed a raw table with no function `" .. name .. "`: it is another wrapper's " ..
              "table, or the core is another build")
        end
      end
      -- The spec names the `T` the caller asked for and checks nothing, which is the claim of this module: the table is
      -- the core's own, and the checks above are the ones it can have. A [`Shape.Spec`] built by hand is no other
      -- spec's claim, so this is written out here and nowhere else.
      local claim: Shape.Spec<T> = { node = Shape.raw.any }
      local same, _ = Shape.into(extra, claim)
      return (assert(same, "a table is no missing value, which is all `Shape.raw.any` refuses"))
    end
  end
  error(wrapper .. " is handed no raw table: the store's searchers give one only for a module of the closure, " ..
      "so require " .. wrapper .. " at the top of the file, as `local _ = require(\"" .. wrapper .. "\")`")
end

function raw_tables.fields(wrapper: string): {string: any}
  return table_behind(wrapper, {})
end

function raw_tables.process(wrapper?: string): raw_process
  return table_behind(wrapper or "cosmic.child", { "spawn", "landlock_abi", "user" })
end

function raw_tables.socket(wrapper?: string): raw_socket
  return table_behind(wrapper or "cosmic.net", { "listen", "datagram", "connect" })
end

return raw_tables
