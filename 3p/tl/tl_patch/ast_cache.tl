-- The ast-cache-* half of the carried tl patch (whilp/cosmic#967):
-- lets an embedder skip tl's parse of its embedded prelude/stdlib
-- d.tl sources — ~11 of the ~16 ms a fresh process pays in its first
-- tl.new_env(). `ast-cache-hooks-*` exposes the node/type metatables
-- and the typeid allocator a thawed AST needs; `ast-cache-new-env`
-- (plus the -tl-tl twin for gentl's ground truth) accepts pre-parsed
-- programs in EnvOptions, byte-identical when absent — generated in
-- _types/tlast_gen.tl, thawed in cosmic/_teal_ast.tl.
--
-- The mechanism is _make/patch.tl: each entry is an exact `find`
-- string replaced by an exact `replace` string in one unpacked file,
-- and entry names share one namespace across every file in this
-- directory, applied in sorted-name order.
--
-- Carried, not forked: each anchor must match the pinned source exactly
-- once, so a tl pin bump that moves this code fails the fetch loudly
-- until the patch is re-audited (or dropped, once upstream lands it).
--
-- Probing an entry: reverse it with `_make.patch`'s `reverse`, which loads
-- the de-patched copy into `package.loaded`, the table `require` reads
-- before any searcher. A modified copy placed on `package.path` is ignored
-- instead: the binary's own `/zip` searcher outranks the file searcher, so
-- such a probe measures the shipped checker and reports a confident wrong
-- answer with nothing logged. A third form is inert for a third reason:
-- `cosmic --check types` on a file that preloads `tl` never runs that
-- file, so the shipped checker answers at exit 0 with nothing logged —
-- `cosmic --docs howto.narrow-nil` lays the three forms side by side.
return {
  ["ast-cache-envoptions-tl-tl"] = {
    file = "tl.tl",
    note = "whilp/cosmic#967: EnvOptions accepts pre-parsed prelude/stdlib ASTs",
    find = [=====[   record EnvOptions
      defaults: CheckOptions
      predefined_modules: {string}
   end
]=====],
    replace = [=====[   record EnvOptions
      defaults: CheckOptions
      predefined_modules: {string}
      -- cosmic carried patch (whilp/cosmic#967): pre-parsed
      -- programs for the embedded prelude/stdlib d.tl sources (from
      -- tl.parse of those exact texts); an embedder that caches them
      -- skips the parse that dominates a fresh process's first
      -- new_env(). Absent means parse, byte-identical behavior.
      parsed_prelude: any
      parsed_stdlib: any
   end
]=====],
  },
  ["ast-cache-hooks-nodemt"] = {
    file = "tl.lua",
    note = "whilp/cosmic#967: expose node_mt for AST cache thaw",
    find = [=====[   local node_mt = {
      __tostring = function(n)
         return n.f .. ":" .. n.y .. ":" .. n.x .. " " .. n.kind
      end,
   }
]=====],
    replace = [=====[   local node_mt = {
      __tostring = function(n)
         return n.f .. ":" .. n.y .. ":" .. n.x .. " " .. n.kind
      end,
   }

   -- cosmic carried patch (whilp/cosmic#967): the parser's node
   -- metatable, for rebuilding serialized ASTs (see ast_hooks below).
   tl.ast_hooks.node_mt = node_mt
]=====],
  },
  ["ast-cache-hooks-typemt"] = {
    file = "tl.lua",
    note = "whilp/cosmic#967: expose type_mt and new_typeid for AST cache thaw",
    find = [=====[local type_mt = {
   __tostring = function(t)
      return show_type(t)
   end,
}
]=====],
    replace = [=====[local type_mt = {
   __tostring = function(t)
      return show_type(t)
   end,
}

-- cosmic carried patch (whilp/cosmic#967): the ingredients a
-- serialized AST needs to be rebuilt as real parser output — the
-- node/type metatables and the typeid allocator (thawed type nodes
-- take fresh ids so later parses cannot collide with them).
tl.ast_hooks = { type_mt = type_mt, new_typeid = new_typeid }
]=====],
  },
  ["ast-cache-new-env"] = {
    file = "tl.lua",
    note = "whilp/cosmic#967: new_env accepts pre-parsed prelude/stdlib ASTs",
    find = [=====[      do
         local program, syntax_errors = tl.parse(prelude, "prelude.d.tl", "tl")
         assert_no_errors(syntax_errors, "prelude contains syntax errors")
         local result = tl.check(program, "@prelude", {}, env)
         assert_no_errors(result.type_errors, "prelude contains type errors")
      end

      do
         local program, syntax_errors = tl.parse(stdlib, "stdlib.d.tl", "tl")
         assert_no_errors(syntax_errors, "standard library contains syntax errors")
         local result = tl.check(program, "@stdlib", {}, env)
         assert_no_errors(result.type_errors, "standard library contains type errors")
      end
]=====],
    replace = [=====[      -- cosmic carried patch (whilp/cosmic#967): a pre-parsed
      -- program stands in for the parse of the embedded d.tl source;
      -- absent means parse, byte-identical behavior.
      do
         local program = opts.parsed_prelude
         if not program then
            local syntax_errors
            program, syntax_errors = tl.parse(prelude, "prelude.d.tl", "tl")
            assert_no_errors(syntax_errors, "prelude contains syntax errors")
         end
         local result = tl.check(program, "@prelude", {}, env)
         assert_no_errors(result.type_errors, "prelude contains type errors")
      end

      do
         local program = opts.parsed_stdlib
         if not program then
            local syntax_errors
            program, syntax_errors = tl.parse(stdlib, "stdlib.d.tl", "tl")
            assert_no_errors(syntax_errors, "standard library contains syntax errors")
         end
         local result = tl.check(program, "@stdlib", {}, env)
         assert_no_errors(result.type_errors, "standard library contains type errors")
      end
]=====],
  },
  ["ast-cache-new-env-tl-tl"] = {
    file = "tl.tl",
    note = "whilp/cosmic#967: new_env accepts pre-parsed ASTs (Teal ground truth)",
    find = [=====[      do
         local program, syntax_errors = tl.parse(prelude, "prelude.d.tl", "tl")
         assert_no_errors(syntax_errors, "prelude contains syntax errors")
         local result = tl.check(program, "@prelude", {}, env)
         assert_no_errors(result.type_errors, "prelude contains type errors")
      end

      do
         local program, syntax_errors = tl.parse(stdlib, "stdlib.d.tl", "tl")
         assert_no_errors(syntax_errors, "standard library contains syntax errors")
         local result = tl.check(program, "@stdlib", {}, env)
         assert_no_errors(result.type_errors, "standard library contains type errors")
      end
]=====],
    replace = [=====[      -- cosmic carried patch (whilp/cosmic#967): a pre-parsed
      -- program stands in for the parse of the embedded d.tl source;
      -- absent means parse, byte-identical behavior.
      do
         local program: Node = opts.parsed_prelude as Node
         if not program then
            local syntax_errors: {Error}
            program, syntax_errors = tl.parse(prelude, "prelude.d.tl", "tl")
            assert_no_errors(syntax_errors, "prelude contains syntax errors")
         end
         local result = tl.check(program, "@prelude", {}, env)
         assert_no_errors(result.type_errors, "prelude contains type errors")
      end

      do
         local program: Node = opts.parsed_stdlib as Node
         if not program then
            local syntax_errors: {Error}
            program, syntax_errors = tl.parse(stdlib, "stdlib.d.tl", "tl")
            assert_no_errors(syntax_errors, "standard library contains syntax errors")
         end
         local result = tl.check(program, "@stdlib", {}, env)
         assert_no_errors(result.type_errors, "standard library contains type errors")
      end
]=====],
  },
}
