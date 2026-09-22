--- The shape a project's own files take for cosmic to recognize them
--- as more than plain library code -- a name `build/positions.tl`
--- compares literally, or a file suffix `build/work.tl` matches, not
--- a symbol any one function's doc comment could state on its own.
--- `cosmic docs <word>` finds each field below directly.
local record Layout
  --- a worked example: a `<name>_example.tl` file must return a
  --- record literally named `Example`, one field per example --
  --- `function Example.<name>(): ... end`. `cosmic test` runs each
  --- one as a test; `cosmic docs <symbol>` shows the ones whose own
  --- code calls that symbol, matched by content, not by the
  --- example's own name
  Example: string
  --- a `<name>_test.tl` file's own top-level `local function test_*`
  --- functions -- direct elements of the file, never inside another
  --- statement -- are discovered and run by `cosmic test`. No return
  --- value and no registration; the name alone is the rule. Its
  --- verdict line's "N ran, M stood" is `test.Tally`: ran counts
  --- tests actually executed this time, stood the ones answered from
  --- an unchanged prior verdict instead
  test: string
  --- a project's own module is named by its path from the project's
  --- root, the working directory: `notes.tl` is `require("notes")`,
  --- `store/db.tl` is `require("store.db")`, and `store/init.tl` is
  --- `require("store")`. No registration and no search path; tests,
  --- examples and cmd/<name>/main.tl require them the same way.
  --- `cosmic.*` is the standard library's, never a project's
  require: string
end

local layout: Layout = {
  Example = "Example", test = "test", require = "require",
}

return layout
