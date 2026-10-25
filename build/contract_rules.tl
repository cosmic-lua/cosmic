--- The data the error-slot discipline ([`build.syntax_contracts`]) is held to apart from its rules: the functions each rule
--- lets off, the methods whose failure a statement may ignore, the tables of C bindings, and which modules the discipline
--- covers.
---
--- The exemption tables key a function as `"file:function"`: see [`build.syntax_contracts`] for how a function is named.

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
--- tree's projection, not here: [`build.syntax_contracts`]'s `quieted` resolves them against
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
  local out: mut {string} = {}
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
