-- The carried patch riding 3p/tl/tl_pin.tl (see _make/patch.tl for the
-- mechanism). Two groups of edits.
--
-- The ast-cache-* group (whilp/cosmic#967) lets an embedder skip
-- tl's parse of its embedded prelude/stdlib d.tl sources — ~11 of the
-- ~16 ms every fresh process pays in its first tl.new_env():
--
-- - ast-cache-hooks-*: expose `tl.ast_hooks` (the node/type metatables
--   and the typeid allocator), the ingredients a serialized AST needs
--   to be rebuilt as real parser output.
-- - ast-cache-new-env (+ the -tl-tl twin for the Teal source, which is
--   the ground truth _types/gentl.tl verifies records against):
--   tl.new_env accepts `parsed_prelude`/`parsed_stdlib` — pre-parsed
--   programs standing in for the parse, with behavior byte-identical
--   when absent. cosmic generates the cache in _types/tlast_gen.tl and
--   thaws it in cosmic/_teal_ast.tl.
--
-- Four edits teach the checker that a nil union narrows through the
-- guards Lua programmers actually write:
--
-- - narrow-assert-decl (+ its -tl-tl twin): `assert` DECLARES that it
--   strips nil (`function<A, B>(A | nil, ? B, ...: any): A`), so it
--   narrows in expression position — `local db = assert(open(p))` —
--   and not only as a statement. tl's own declaration hands the union
--   straight back, `| nil` included, which is the trap a Lua
--   programmer hits before ever meeting `check.must`
--   (whilp/cosmic#1065).
--
-- - narrow-truthiness: `if r then` / `if not r then return end`. Lua
--   has no falsy tables, so for a union of nil with non-boolean
--   members, truthy means exactly "r is not nil" — the edit stamps the
--   same IsFact the fact machinery already uses for `is` guards. Unions
--   containing boolean/any/unknown are skipped: `false` is
--   truthy-unsafe.
-- - narrow-and-operand: `if x and x.field` / `if x and x:method()`.
--   tl already hands the left operand's facts to the right one; it
--   just never read that operand in boolean context, so a bare
--   variable there had no fact to hand over.
-- - narrow-assert: `assert(x)` applies the same fact — assert already
--   forwards its argument's facts to the following statements; the
--   edit gives a bare variable argument one.
-- - narrow-eq-nil: `x == nil` / `x ~= nil` is an exact type test
--   (`__eq` never fires with a nil operand), so it carries an IsFact —
--   whose negation narrows — instead of an EqFact, whose negation is
--   deliberately information-free. Sound for boolean unions too, which
--   truthiness cannot narrow.
--
-- Carried, not forked: each anchor must match the pinned tl.lua exactly
-- once, so a tl pin bump that moves this code fails the fetch loudly
-- until the patch is re-audited (or dropped, once upstream lands it).
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
  ["narrow-assert-decl"] = {
    file = "tl.lua",
    note = "whilp/cosmic#1065: assert strips nil, so it narrows in expression position",
    find = [=====[      assert: function<A, B>(A, ? B, ...: any): A --[[special_function]]
]=====],
    replace = [=====[      -- cosmic carried patch (whilp/cosmic#1065): assert's declared
      -- argument strips the nil, so `local db = assert(open(p))` and
      -- `local d2 = assert(d)` yield A rather than handing `A | nil`
      -- straight back. The statement form already narrowed (see
      -- narrow-assert below); this is the expression form, which is
      -- what a Lua programmer writes first.
      assert: function<A, B>(A | nil, ? B, ...: any): A --[[special_function]]
]=====],
  },
  ["narrow-assert-decl-tl-tl"] = {
    file = "tl.tl",
    note = "whilp/cosmic#1065: assert strips nil (Teal ground truth)",
    find = [=====[      assert: function<A, B>(A, ? B, ...: any): A --[[special_function]]
]=====],
    replace = [=====[      -- cosmic carried patch (whilp/cosmic#1065): assert's declared
      -- argument strips the nil, so `local db = assert(open(p))` and
      -- `local d2 = assert(d)` yield A rather than handing `A | nil`
      -- straight back. The statement form already narrowed (see
      -- narrow-assert below); this is the expression form, which is
      -- what a Lua programmer writes first.
      assert: function<A, B>(A | nil, ? B, ...: any): A --[[special_function]]
]=====],
  },
  ["narrow-and-operand"] = {
    file = "tl.lua",
    note = "whilp/cosmic#942: the left operand of `and` is read in boolean context",
    find = [=====[            if node.expected then
               if node.op.op == "and" then
                  node.e2.expected = node.expected
               elseif node.op.op == "or" then]=====],
    replace = [=====[            if node.expected then
               if node.op.op == "and" then
                  node.e2.expected = node.expected
                  -- cosmic carried patch (whilp/cosmic#942): the left
                  -- operand of `and` decides the branch, so inside a
                  -- boolean context it is read in one too -- which is
                  -- what gives `if st and st:is_dir()`, the idiom a Lua
                  -- programmer writes, its truthiness fact. tl already
                  -- applies e1's facts to e2 (before_e2), so the fact is
                  -- all that was missing. Only boolean_context
                  -- propagates: where a VALUE is expected, e1 is the
                  -- expression's own falsy result and keeps its type.
                  if node.expected.typename == "boolean_context" then
                     node.e1.expected = node.expected
                  end
               elseif node.op.op == "or" then]=====],
  },
  ["narrow-assert"] = {
    file = "tl.lua",
    note = "whilp/cosmic#942: assert(x) on a plain variable narrows its nil union",
    find = [=====[
      ["assert"] = function(self, node, a, b, argdelta)
         node.known = FACT_TRUTHY
         local r = self:type_check_function_call(node, a, b, argdelta)
         self:apply_facts(node, node.e2[1].known)
         return r
      end,]=====],
    replace = [=====[
      ["assert"] = function(self, node, a, b, argdelta)
         node.known = FACT_TRUTHY
         local r = self:type_check_function_call(node, a, b, argdelta)
         -- cosmic carried patch (whilp/cosmic#942): assert(x) on a plain
         -- variable of a nil union narrows like a truthiness guard --
         -- assert already applies its argument's facts to the statements
         -- that follow; this gives the argument one when it is a bare
         -- variable read. Same union rules as the boolean-context edit:
         -- unions containing boolean/any/unknown are skipped.
         local arg1 = node.e2[1]
         if arg1 and arg1.kind == "variable" and not arg1.known and b.tuple[1] then
            local rt = b.tuple[1]
            if rt.typename == "nominal" then
               rt = self:resolve_nominal(rt)
            end
            if rt.typename == "union" then
               local has_nil, safe, members = false, true, {}
               for _, m in ipairs(rt.types) do
                  local rm = m
                  if rm.typename == "nominal" then
                     rm = self:resolve_nominal(rm)
                  end
                  if rm.typename == "nil" then
                     has_nil = true
                  else
                     if rm.typename == "boolean" or rm.typename == "any" or
                        rm.typename == "unknown" or rm.typename == "boolean_context" or
                        rm.typename == "typevar" then
                        safe = false
                     end
                     table.insert(members, m)
                  end
               end
               if has_nil and safe and #members > 0 then
                  local typ = #members == 1 and members[1] or unite(arg1, members)
                  arg1.known = IsFact({ var = arg1.tk, typ = typ, w = arg1 })
               end
            end
         end
         self:apply_facts(node, node.e2[1].known)
         return r
      end,]=====],
  },
  ["narrow-eq-nil"] = {
    file = "tl.lua",
    note = "whilp/cosmic#942: == nil / ~= nil on a plain variable is an exact nil test",
    find = [=====[
               elseif self:is_a(ub, ua) or ua.typename == "typevar" then
                  if node.op.op == "==" and node.e1.kind == "variable" then
                     node.known = EqFact({ var = node.e1.tk, typ = ub, w = node })
                  end
               elseif self:is_a(ua, ub) or ub.typename == "typevar" then
                  if node.op.op == "==" and node.e2.kind == "variable" then
                     node.known = EqFact({ var = node.e2.tk, typ = ua, w = node })
                  end]=====],
    replace = [=====[
               elseif self:is_a(ub, ua) or ua.typename == "typevar" then
                  -- cosmic carried patch (whilp/cosmic#942): comparing a
                  -- variable against nil is an exact type test -- __eq
                  -- never fires with a nil operand -- so it carries an
                  -- IsFact, whose negation narrows, instead of an EqFact,
                  -- whose negation is deliberately information-free.
                  if node.e1.kind == "variable" and rb.typename == "nil" then
                     local f = IsFact({ var = node.e1.tk, typ = rb, w = node })
                     node.known = node.op.op == "==" and f or NotFact({ f1 = f, w = node })
                  elseif node.op.op == "==" and node.e1.kind == "variable" then
                     node.known = EqFact({ var = node.e1.tk, typ = ub, w = node })
                  end
               elseif self:is_a(ua, ub) or ub.typename == "typevar" then
                  if node.e2.kind == "variable" and ra.typename == "nil" then
                     local f = IsFact({ var = node.e2.tk, typ = ra, w = node })
                     node.known = node.op.op == "==" and f or NotFact({ f1 = f, w = node })
                  elseif node.op.op == "==" and node.e2.kind == "variable" then
                     node.known = EqFact({ var = node.e2.tk, typ = ua, w = node })
                  end]=====],
  },
  ["narrow-truthiness"] = {
    file = "tl.lua",
    note = "whilp/cosmic#942: truthiness narrows nil-unions of records/maps/arrays",
    find = [=====[
            if t.typename == "typedecl" then
               t = typedecl_to_nominal(node, node.tk, t, t)
            end

            return t]=====],
    replace = [=====[
            if t.typename == "typedecl" then
               t = typedecl_to_nominal(node, node.tk, t, t)
            end

            -- cosmic carried patch (whilp/cosmic#942): a plain variable
            -- read in boolean context carries a truthiness fact. Lua has
            -- no falsy tables, so for a union of nil with non-boolean
            -- members, truthy exactly means "not nil": the positive
            -- branch narrows to the members, and the negated
            -- early-return shape narrows below the guard. Unions
            -- containing boolean (or any/unknown) are skipped -- false
            -- is truthy-unsafe.
            do
               local rt = t
               if rt.typename == "nominal" then
                  rt = self:resolve_nominal(rt)
               end
               if node.expected and node.expected.typename == "boolean_context" and
                  rt.typename == "union" then
                  local has_nil, safe, members = false, true, {}
                  for _, m in ipairs(rt.types) do
                     local rm = m
                     if rm.typename == "nominal" then
                        rm = self:resolve_nominal(rm)
                     end
                     if rm.typename == "nil" then
                        has_nil = true
                     else
                        if rm.typename == "boolean" or rm.typename == "any" or
                           rm.typename == "unknown" or rm.typename == "boolean_context" or
                           rm.typename == "typevar" then
                           safe = false
                        end
                        table.insert(members, m)
                     end
                  end
                  if has_nil and safe and #members > 0 then
                     local typ = #members == 1 and members[1] or unite(node, members)
                     node.known = IsFact({ var = node.tk, typ = typ, w = node })
                  end
               end
            end

            return t]=====],
  },
}
