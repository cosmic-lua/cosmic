--- The record every verb module's `spec` is, defined once so a verb is
--- registered by one value in its own module (listed in build/verb_list.tl)
--- rather than by a line in each place that has to know it: the dispatch
--- table, the set of verbs that print no verdict, the help prose that says
--- what a verb takes and how it exits, and the cases in build/verb_cases.tl.
--- What a person reads about a verb -- its description and options -- stays
--- in `cosmic.cli`.

local record verb_spec
  --- What a verb's module says about itself.
  record Spec
    --- The word that names it on the command line; `Cli.<name>` is its prose.
    name: string
    --- Runs the command line, `name` at slot 1, and answers the exit code.
    run: function(argv: {integer:string}): integer
    --- True when the verb ends in no verdict line, its output being data for
    --- a pipe: its exit status is the verdict, a usage error is complained
    --- about and nothing more, and the tool's staleness is not checked
    --- after it.
    bare: boolean
    --- True when a tool older than the tree rebuilds itself before the verb
    --- runs, for a verb that does not check as it goes (`build.reboot`'s
    --- `stale_exit`): one whose rows, or whose own code, are the tree's.
    fresh: boolean | nil
    --- What the verb takes after its name, as `cosmic help` phrases it ("a
    --- path and a file"); verbs that take the same share one clause there.
    takes: string
    --- The sentence `cosmic help` gives a bare verb's output and exit codes
    --- ("`json` prints its value ... and exits 0 when it ..."), starting
    --- with its name in backticks, on one line: help wraps it. Nil for a
    --- verb that ends in a verdict line.
    exits: string | nil
    --- Why build/verb_cases.tl holds the verb to no verdict-line case, when
    --- it has none.
    passthrough: string | nil
    --- The verb's section of doc/guides/quickstart.md: the text of its `## `
    --- heading, without the marks, or a string beginning "none: " that says
    --- why the quickstart has none. `build.tree_checks`' `verbs` holds it to
    --- a heading the guide has.
    guide: string
    --- The test modules of the verb ("build.json_test"), at least one, each a
    --- test of the tree, so a verb is never listed with nothing to hold it.
    tests: {string}
  end
end

return verb_spec
