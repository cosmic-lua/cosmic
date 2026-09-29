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
    --- path and a file"), or nil for a verb whose arguments that prose
    --- states in its own words.
    takes: string | nil
    --- The sentence `cosmic help` gives a bare verb's output and exit codes
    --- ("`json` prints its value ... and exits 0 when it ..."), starting
    --- with its name in backticks. A line break inside it is kept where the
    --- help prose has always broken, so the help text stays byte for byte;
    --- one at its start stands in for the space that joins it to the
    --- sentence before.
    exits: string | nil
    --- Why build/verb_cases.tl holds the verb to no verdict-line case, when
    --- it has none.
    passthrough: string | nil
    --- Where `exits` falls among the sentences, when not at the verb's
    --- place in build/verb_list.tl: a rank above every place puts it last.
    prose_rank: integer | nil
  end
end

return verb_spec
