--- The records [`cosmic.doc`] answers with: a view, its entries, lookups, examples, answers and uses. [`cosmic.doc`]
--- names each of them ([`Doc.View`] is this module's [`View`]); they are declared here so its parts share them.
--- @public

local Sqlite = require("cosmic.sqlite")
local alias_members = require("cosmic.internal.alias_members")

local record Types
  --- A command of the view's program, which a row of `docs` describes: `cosmic test`, documented by the
  --- overview of [`cosmic.cli.test`]. A lookup of `name` that also names a module points to the command,
  --- its row's page shows its `usage`, `about`, `options` and `examples` under it, and a search reads them with
  --- the row's own text.
  record Command
    --- The word that runs it.
    name: string
    --- The row that documents it, by its `module` and `symbol` as `docs` holds them.
    module: string
    --- That row's `symbol`: a field's own name where the module returns the record that declares it, "" for the
    --- module's own row.
    symbol: string
    --- Its options as its help prints them, nil for a command that takes none.
    options?: string
    --- Its one line on what it does, as its help prints it; nil for none.
    about?: string
    --- The line it is typed as, as its help's usage line has it ("prog pair [options] <device>"); nil for none.
    usage?: string
    --- Its examples as its help prints them, a line each; nil for none.
    examples?: string
  end
  --- One ordered database view and the owner of every module in it.
  record View
    --- The databases, in the order they are read.
    databases: {Sqlite.Handle}
    --- Which databases are public sources, by index: one covers only
    --- the modules it records as public ([`symbols.public_modules`]),
    --- the standard library's in the binary a project builds with, which
    --- is what the project sees of it. A project's own database, and
    --- every database inside cosmic's own tree, cover everything.
    public: {integer: boolean}
    --- The index of the database that covers each module: the first that holds it.
    owners: {string: integer}
    --- How many places refer to a module/symbol pair, keyed by
    --- `use_key` -- computed on demand, once per command, by
    --- `effective_counts`, and cached here so several entries or
    --- renders naming the same symbol query `uses` only once.
    use_counts: mut {string: integer}
    --- How many links name a module/symbol pair, as `use_counts`.
    link_counts: mut {string: integer}
    --- The record each module's value is typed as (`""` for none), by
    --- module, as `value_record` reads it, cached as `use_counts` is.
    value_records: mut {string: string}
    --- The modules each database records as public, by the database's
    --- index ([`symbols.public_modules`]), cached as `use_counts` is.
    public_modules: mut {integer: {string: boolean}}
    --- The module each module binds each name to, by module and name,
    --- as [`symbols.add_bound`] reads them: nil until a type's
    --- reference asks, then cached as `use_counts` is.
    mut bound?: {string: string}
    --- The commands of the documented program, none unless the caller sets them.
    mut commands: {Command}
    --- The documented program, as its user types it, where it is not the tool ([`cosmic.doc.program`]): a page's
    --- hints name its `docs` command, and no page counts the uses and links of a symbol, a program having no
    --- command that lists them. Nil for the tool.
    mut program?: string
    --- Who alone may require each module of a database of the tree's own, by module, as [`Summary`]'s
    --- `closed` says it: what the list of every module marks. Nil marks none.
    mut marks?: function(db: Sqlite.Handle): {string: string}
  end

  --- One worked example, matched to a symbol by content rather than by
  --- name -- see `examples_for`.
  record Example
    --- The example function's name.
    name: string
    --- Its doc comment.
    text: string
    --- The file that holds it, from the root.
    file: string
    --- The line of `file` it starts on.
    line: integer
    --- Its source.
    source: string
  end

  --- One row of `docs`, with where it came from.
  record Entry is alias_members.Declared
    --- The module that declares it.
    mut module: string
    --- Its name as a caller of the module writes it; "" for the module's own row.
    mut symbol: string
    --- Its name as its file declares it.
    mut source_symbol: string
    --- Whether the module's value offers it.
    mut exported: boolean
    --- What it is: "module", "function", "record", "field" and the like.
    kind: string
    --- Its declaration, as its page shows it.
    signature: string
    --- Its doc comment.
    text: string
    --- The file that declares it, from the root; "" where none is recorded.
    file: string
    --- The line of `file` it is declared on; 0 where none is recorded.
    line: integer
    --- How many places in shipped modules refer to it.
    mut uses: integer
    --- How many links in their comments name it (`links`).
    mut links: integer
    --- How many worked examples match it -- see `examples_for`. A
    --- listing count, not the examples themselves: `render` fetches
    --- those separately, only for the one entry it is showing.
    examples: integer
    --- Examples whose comments or checked source matched a free-text
    --- search. Kept on the result only; the database remains unchanged.
    related: {Example}
  end

  record Lookup is {Entry}
    --- Whether the query names its entries, which a search's entries only relate to.
    exact: boolean
    --- How many entries, from the first, are named by the query; any
    --- after them stand in for a raw binding it named (see `stand_ins`).
    named: integer
    --- Whether no entry carries every word of the query, and these carry
    --- some of them (see `closest`).
    closest: boolean
    --- The query as it was looked up, where a word of it that no documentation holds was taken for the
    --- nearest word one does; nil where the query was looked up as given.
    mut respelled?: string
    --- The verb `cosmic <query>` when the query names a library module of
    --- the same name: `page` in [`cosmic.doc`] ends the module's entries with a line
    --- pointing to it, and it is not one of the entries. Nil otherwise.
    mut verb?: Entry
    --- How many entries, from the first, are the modules the query names;
    --- the line for `verb` follows them. 0 when there are none.
    mut modules: integer
  end

  --- What `cosmic docs` prints for its words, short of its summary:
  --- see [`cosmic.doc.answer`].
  record Answer
    --- The page, a line each.
    lines: {string}
    --- Whether every word found something: the run's pass.
    found: boolean
    --- What the summary counts ("2 named", "7 found"), led, when a
    --- word found nothing, by the words that found nothing.
    said: string
  end

  --- One module as the index lists it.
  record Summary
    --- The module's name.
    module: string
    --- The first sentence of its documentation; "" when it has none.
    text: string
    --- Who alone may require it: "private to rules/returns/" for a module of a closed directory, "internal to
    --- app/" for one an `internal` directory scopes, "" for one any module may. [`cosmic.doc.index`] leaves it "": only
    --- the list of every module judges it, by the view's `marks`.
    closed: string
  end

  --- An exported function with a parameter of a given name ([`cosmic.doc.taking`]).
  record Taking
    --- The module that exports it.
    module: string
    --- Its name as a caller of the module writes it ([`Fs.basename`]).
    symbol: string
  end

  --- One row of `uses`, or of `links` (`link`): a link names the
  --- symbol `module` and `symbol` name, or the file at `path` and, when
  --- it is not "", the heading `anchor` of it.
  record Use
    --- The module that declares what is referred to; "" for a link to a file.
    module: string
    --- The symbol referred to; "" for the module itself.
    symbol: string
    --- The module that refers to it; "" for a file that is no module.
    from_module: string
    --- The file that refers to it, from the root.
    from_file: string
    --- The line of `from_file` that does.
    line: integer
    --- Whether a link in a comment or a document refers to it, not code.
    link: boolean
    --- The file a link names, from the root; "" for a link to a symbol.
    path: string
    --- The heading of `path` a link names; "" for none.
    anchor: string
  end
end

return Types
