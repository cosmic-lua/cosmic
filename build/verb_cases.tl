--- The tables every verb `cosmic.cli` names is held to by
--- build/verbs_test.tl and build/verbs_tool_test.tl: the verbs that end
--- in no verdict line, one argument too many for each, and a command
--- line that passes and one that fails. Test support, kept in one place
--- so the test that classifies every verb and the tests that run each
--- one read the same tables.

local record verb_cases
  --- One command line that passes and one that fails, each run in `tree`
  --- unless it names another directory; a string for a failure no command
  --- line can bring about.
  record Case
    pass: {string}
    fail: {string} | string
    fail_in: string
  end

  passthrough: {string:string}
  surplus: {string:{string} | string}
end

--- The verbs that end in no verdict line: those whose words after the
--- file are the program's own, so no option or argument is theirs to
--- refuse, and whose output is the program's; `--version`, whose
--- one line is all it prints (build/version_tool_test.tl holds it); and
--- `json`, which does refuse options and arguments, held to that in
--- build/json_test.tl, but whose standard output is the value asked for.
verb_cases.passthrough = {
  run = "the words after the file are its program's argv",
  standalone = "the words after the file are its program's argv",
  eval = "the words after the chunk are its `...`",
  version = "it prints one line and no verdict",
  json = "its output is data for a pipe, so its exit status is the verdict (build/json_test.tl)",
  archive = "its output is data for a pipe, so its exit status is the verdict (build/archive_test.tl)",
  codec = "its output is data for a pipe, so its exit status is the verdict (build/codec_test.tl)",
}

--- A command line with one argument more than each verb takes, or why
--- the verb has none: it takes any number of words.
verb_cases.surplus = {
  test = "takes any number of selectors",
  fix = "takes any number of paths",
  build = "takes any number of paths",
  db = "takes any number of paths",
  docs = "takes any number of words to search for",
  uses = "takes a symbol and any number of paths",
  todos = "takes any number of paths and words",
  sql = { "sql", "SELECT 1", "extra" },
  help = { "help", "test", "fix" },
  bom = { "bom", "extra" },
  refresh = { "refresh", "-o", "out", "nosuch" },
}

--- Each verb's passing and failing command lines, `refresh`'s reading
--- the vendored CA bundle at `bundle` with no network.
function verb_cases.cases(bundle: string): {string:verb_cases.Case}
  return {
    test = { pass = { "test", "good" }, fail = { "test", "bad" } },
    fix = { pass = { "fix", "--check", "good" }, fail = { "fix", "--check", "messy.tl" } },
    build = { pass = { "build" }, fail = { "build" }, fail_in = "broken" },
    db = { pass = { "db" }, fail = { "db" }, fail_in = "empty" },
    docs = { pass = { "docs", "Fs.read" }, fail = { "docs", "zzqqx_nothing_named" } },
    uses = { pass = { "uses", "Fs.read" }, fail = { "uses", "zzqqx_nothing_named" } },
    todos = { pass = { "todos" }, fail = { "todos", "zzqqx_nothing_named" } },
    sql = { pass = { "sql", "SELECT 1" }, fail = { "sql", "SELECT * FROM zzqqx_no_table" } },
    help = { pass = { "help" }, fail = "help has nothing to fail on but its command line" },
    bom = { pass = { "bom" }, fail = { "bom", "--json", "no/such/directory/bom.json" } },
    refresh = { pass = { "refresh", "-o", "out", "--cacert", bundle },
      fail = { "refresh", "-o", "out", "--cacert", "no/such/cacert.pem" } },
  }
end

return verb_cases
