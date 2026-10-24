--- The data the error-slot discipline ([`build.contracts`] and [`build.syntax_contracts`]) is held to apart from its rules:
--- the functions each rule lets off, the methods whose failure a statement may ignore, the tables of C bindings, and
--- which modules the discipline covers. It is a module of its own so the port ([`build.syntax_contracts`]) reads it without
--- the fork's checker, and the fork's [`build.contracts`] can go at the switch without taking the entries with it.
---
--- The exemption tables key a function as `"file:function"`: see [`build.contracts`] for how a function is named.

local record rules
  --- The functions the rules let off, each table `"file:function"` to
  --- the reason; `check` holds a module to this module's own unless it
  --- is handed others.
  record Exemptions
    --- The functions rules 2 to 5, 10 and 11 do not hold.
    exempt: {string: string}
    --- The functions rule 6 does not hold.
    parsing: {string: string}
    --- The functions rule 7 lets cast.
    casts: {string: string}
    --- The string fields rule 9 lets be compared with literals, by
    --- `"file:Record.field"`.
    modes: {string: string}
  end
  --- Methods of one record whose failure a statement may ignore.
  record Quiet
    reason: string
    methods: {string: boolean}
  end
end

local exempt: {string: string} = {
  ["cosmic/child.tl:Child.wait_any"] =
    "a finished handle comes back with its group's lingering-member " ..
    "trouble, which a caller reports beside the handle's result",
}

local parsing: {string: string} = {
  ["test/terminal/pty.tl:assert_terminal_refusal"] =
    "the CI terminal fixture checks the public rejection diagnostic, not a recovery decision",
}

local casts: {string: string} = {
  ["build/assertions.tl:assertions.install"] =
    "_G is a record and rawset takes a map; the write is of a name the record does not declare",
  ["build/test_worker.tl:worker.install_checks"] =
    "_G is a record and rawset takes a map; the write is of a name the record does not declare",
  ["build/standalone.tl:standalone.run"] =
    "_G is a record and rawset takes a map; the write is of a name the record does not declare",
  ["build/dispatch.tl:run"] =
    "_G is a record and rawset takes a map; the write is of a name the record does not declare",
  ["cosmic/time.tl:make_zone"] =
    "Teal's metatable record has no __metatable, which Lua reads; rawset takes a map",
  ["cosmic/sqlite.tl:cells_of"] =
    "a stored row is a record with an array part for its slots, and the grammar has no record " ..
    "with an array part that also implements Sqlite.Row",
  ["cosmic/sqlite.tl:texts_of"] =
    "a stored row is a record with an array part for its slots, and the grammar has no record " ..
    "with an array part that also implements Sqlite.Row",

  ["test/terminal/pty.tl:process_table"] =
    "the CI fixture reaches cosmic.child's raw process loader argument to test " ..
    "the controlling-terminal spawn step; core/process.h declares its shape",

  ["build/sandbox_probe.tl:raw_process_table"] =
    "the store's searcher hands cosmic.child's loader the raw process " ..
    "table as its extra value, untyped as package.searchers returns it; " ..
    "cosmic.internal.process declares that table, core/process.h defines it",
  ["build/unix_socket.tl:raw_table"] =
    "the store's searcher hands cosmic.net's loader the raw socket " ..
    "table as its extra value, untyped as package.searchers returns it; " ..
    "cosmic.internal.socket declares that table, core/socket.h defines it",
  ["build/udp_fixture.tl:raw_table"] =
    "the store's searcher hands cosmic.net's loader the raw socket " ..
    "table as its extra value, untyped as package.searchers returns it; " ..
    "cosmic.internal.socket declares that table, core/socket.h defines it",
  ["build/confine.tl:policy_kind"] =
    "a record read raw, as the core reads it, so no metamethod answers for a field",
  ["build/confine.tl:plain_sandbox"] =
    "a record read raw, as the core reads it, so no metamethod answers for a field",
  ["build/ast/match.tl:arr"] =
    "tl's AST reached by reflection: a node's own array part, " ..
    "whose elements' shape depends on their kind",
  ["build/ast/match.tl:attach_predicates"] =
    "a cast node's casttype is a parsed type no Node field names",
  ["build/ast/match.tl:match_value"] =
    "a pattern matched field by field, by reflection: a candidate " ..
    "found under any field is bound as the Node it is",
  ["build/ast/match_cast.tl:matched"] =
    "a candidate cast node, reached by reflection, bound as the Node it is",
  ["build/ast/match_cast.tl:type_array"] =
    "a parsed type's fields, which no Node field names, by reflection",
  ["build/ast/match_cast.tl:type_view"] =
    "a parsed type's fields, which no Node field names, by reflection",
  ["build/ast/node.tl:parse"] =
    "tl hands its checked AST and type objects as any " ..
    "(build/compiler.d.tl)",
  ["build/ast/walk.tl:map_of"] =
    "a node's fields read by reflection: which it has depends on its kind",
  ["build/contracts.tl:exported_functions"] =
    "tl hands a module's checked type as any (build/compiler.d.tl)",
  ["build/contracts.tl:check_function"] =
    "build.ast declares tl's type objects as TypeNode and " ..
    "build.receivers as Type: two declarations of one thing",
  ["build/receivers.tl:receivers.record_named"] =
    "tl hands its checked AST and type objects as any " ..
    "(build/compiler.d.tl)",
  ["build/receivers.tl:receivers.references"] =
    "tl hands its checked AST and type objects as any " ..
    "(build/compiler.d.tl)",
  ["build/receivers.tl:reporter_for"] =
    "tl hands its checked AST and type objects as any " ..
    "(build/compiler.d.tl)",
  ["build/shape_specs.tl:view_of_node"] =
    "tl hands its type objects as TypeNode and any (build/compiler.d.tl)",
  ["build/shape_specs.tl:view_of_type"] =
    "tl hands its type objects as Type and any (build/compiler.d.tl)",
  ["build/teal.tl:teal.lazy.real"] =
    "the loaded compiler, indexed by whatever key the capsule is asked for",
  ["build/teal.tl:teal.lazy"] =
    "a capsule standing for the compiler until it loads",
  ["build/teal.tl:teal.load"] =
    "the one boundary where the compiler's untyped chunk " ..
    "becomes its declared surface (build/compiler.d.tl)",
  ["cosmic/shape.tl:Shape.into"] =
    "the one cast from any, to the caller's annotation, of a value " ..
    "walk has just built to the spec",
  ["cosmic/sqlite.tl:checked"] =
    "a caller's parameter table is checked for keys its " ..
    "declaration does not name, which only a map view of it lists",
  ["cosmic/web/dev.tl:injected"] =
    "a reply is copied by every key it holds, so a field the record " ..
    "gains later is kept; a record with fields of different types " ..
    "lists only through a map view, and back through a cast",
  ["cosmic/web/request.tl:get"] =
    "a request's slots hold values of every key's type in one table; " ..
    "`set` stores a T under its Key<T>, so the one read back is that T",
}

--- The string fields rule 9 lets be compared with literals, each
--- with the reason its values are not a closed set.
local modes: {string: string} = {}

--- This module's own exemptions, which `check` holds a module to.
local own_exemptions: rules.Exemptions = {
  exempt = exempt, parsing = parsing, casts = casts, modes = modes,
}

--- The methods whose failures a statement may ignore without saying
--- so, by record, with the reason: a diagnostic written to a stream has
--- nowhere else to report that the write failed, as [`cosmic.log`] says.
--- Each method is named, so one a record gains later is held to rule 1
--- until it is listed here. Only a call standing alone as a statement
--- is let through; a result used any other way is held to rule 1 too.
--- A stale entry, one whose record no module declares or whose method
--- the record lacks, is refused by [`build.tree_checks`] over the whole
--- tree's projection, not here: [`build.contracts`]'s `quiet_records` resolves them against
--- whatever environment compiles the module at hand, which need not
--- have loaded the record's module, so a miss here is no proof.
local quieted: {string: rules.Quiet} = {
  ["cosmic.log Logger"] = {
    reason = "a line written for a person; its failure has nowhere to go",
    methods = { say = true, complain = true },
  },
}

--- The exemptions this module holds a module to, which [`build.syntax_contracts`] holds the new tree to as well: one
--- table of entries, each keyed by the file and the function it names, not two.
function rules.own_exemptions(): rules.Exemptions
  return own_exemptions
end

--- The methods a statement may ignore the failure of, by `<module> <record>` ([`rules.quieted_names`]), shared with
--- [`build.syntax_contracts`] as the exemptions are.
function rules.quiet_entries(): {string: rules.Quiet}
  return quieted
end

--- What `quieted` names, each as `<module> <symbol>`, sorted: every
--- record, and every method as `<record>.<method>`.
function rules.quieted_names(): {string}
  local out: {string} = {}
  for key, entry in pairs(quieted) do
    out[#out + 1] = key
    for method in pairs(entry.methods) do
      out[#out + 1] = key .. "." .. method
    end
  end
  table.sort(out)
  return out
end

--- The tables of C bindings, which answer `nil | false, error, errno`:
--- the public syscall table and the raw process and socket tables.
local binding_modules <const>: {string} = { "cosmic.sys", "cosmic.internal.process",
  "cosmic.internal.socket" }

--- The modules whose tables are C bindings, which answer `nil | false, error, errno`: [`cosmic.sys`], and the raw process and
--- socket tables.
function rules.binding_names(): {string}
  return binding_modules
end

--- Whether a module is held to the discipline: every module and main
--- of cosmic's own tree, not its tests, examples, declarations, or
--- generated doctests.
-- TODO: hold ci/'s modules to it too. ci/ builds as a tree of its own,
-- never cosmic's, so the importer never asks; and it runs on the
-- bootstrap pin's release, so a fix there must suit both.
--- @param kind the module's kind as the importer staged it
--- @param generated whether a generator wrote it
function rules.applies(kind: string, generated?: boolean): boolean
  return (kind == "module" or kind == "main") and not generated
end

return rules
