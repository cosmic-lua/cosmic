-- The real Lua debug library, as the core provides it. Only what the
-- coverage collector needs: enough to install and remove a line hook
-- and to name the module a line fired in.

local record debug
  record Info
    -- What "S" fills in. Every module is loaded with a chunk name of
    -- "@" followed by its import path (see core/store.c's `load_from`),
    -- so `short_src` is that path, never truncated.
    short_src: string
  end

  -- Installs `hook` -- `function(event: string, line: integer)` -- to
  -- fire on every event `mask` selects ("c" call, "r" return, "l"
  -- line) and, when `count` is greater than zero, every `count` VM
  -- instructions as well. `hook` is `any` because turning the hook off
  -- means passing `nil`, Lua's only way to remove one.
  sethook: function(hook: any, mask: string, count?: integer)

  -- Info about the running function at stack `level`. Called with "S"
  -- from inside a line hook, where level 2 is the function whose line
  -- just executed.
  getinfo: function(level: integer, what: string): Info
end

return debug
