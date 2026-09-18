-- The real Lua 5.4 debug library, as the core provides it. Only the
-- three fields the coverage collector needs: enough to install and
-- remove a line hook and to name the module and line it fired on.

local record debug
  record Info
    -- What "S" fills in. `source` carries the chunk name verbatim
    -- (the leading '@' and all); `short_src` is what this runtime's
    -- chunk names decode to directly, since every module is loaded
    -- with a chunk name of exactly "@" followed by its import path
    -- (see build/importer.tl and core/store.c's `load_from`) -- never
    -- truncated here, since an import path is far short of Lua's
    -- LUA_IDSIZE.
    source: string
    short_src: string
    linedefined: integer
    lastlinedefined: integer
    what: string

    -- What "l" fills in.
    currentline: integer
  end

  -- Installs `hook` -- `function(event: string, line: integer)` -- to
  -- fire on every event `mask` selects ("c" call, "r" return, "l"
  -- line) and, when `count` is greater than zero, every `count` VM
  -- instructions as well. `hook` is `any` rather than a declared
  -- function type only because turning the hook off means passing
  -- `nil` for it instead, Lua's own sole way to remove one -- this is
  -- the C declaration layer design.md names as one of the few places
  -- `any` is expected, not an ordinary escape.
  sethook: function(hook: any, mask: string, count?: integer)

  -- The hook function currently installed (nil when there is none, or
  -- a plain external-hook marker string when the hook was not
  -- installed by this same debug library), its mask string, and its
  -- instruction count.
  gethook: function(): any, string, integer

  -- Info about the running function at stack `level`, restricted to
  -- the fields `what`'s letters select. This binding only ever asks
  -- for "S" and "l" (see `Info` above) from inside a line hook, where
  -- level 2 is the function whose line just executed: level 0 is
  -- `getinfo` itself, level 1 is the hook function calling it.
  getinfo: function(level: integer, what: string): Info
end

return debug
