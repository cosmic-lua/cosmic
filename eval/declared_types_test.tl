--- The declarations of the eval harness tell the truth about nil: a path
--- that is none, a tier that does not apply, a home directory a word
--- does not name and an option the command line leaves out answer nil
--- only where their types say so. A checked run
--- (`cosmic test --check-types`) says whether a value crossed a typed
--- boundary as a kind its type does not admit; in any other run the
--- tests skip.
--- Until a compile writes the boundary checks (build/type_watch.tl), they skip in a checked run too.

local Json = require("cosmic.json")
local Round = require("eval.round")
local Solve = require("eval.solve")
local Summarize = require("eval.summarize")
local TypeWatch = require("build.type_watch")

--- Fails, listing what `during` met under eval/, unless it met nothing.
local function honest(what: string, fn: function())
  local found = TypeWatch.during(fn, "eval/")
  assert(#found == 0, what .. ": " .. #found .. " violations:\n" .. table.concat(found, "\n"))
end

local function call(id: string, name: string, input: {string: any}): string
  return (assert(Json.encode_any({ type = "assistant", message = { content = {
    { type = "tool_use", id = id, name = name, input = input },
  } } })))
end

--- A report over calls that name a path in the arena, in a system
--- location, in the checkout, in /tmp and elsewhere, a home directory in
--- each spelling and a word that is no path: each of the helpers that
--- answer no path, no tier or no home directory is asked.
local function test_the_report_answers_what_it_declares_for_every_kind_of_path()
  honest("summarize", function()
    local text = table.concat({
      call("1", "Bash", { command = "cat /work/arena/a ~/b $HOME/c ${HOME}/d ~root/e /usr/lib/f /src/cosmic/g" }),
      call("2", "Bash", { command = "grep -F -e pat -- /tmp/h ../i /var/j; sed -n 1p k; awk -F/ '{print $1}' l" }),
      call("3", "Bash", { command = "sh -c 'cat /etc/passwd' ; echo VAR=$HOME http://x/y 12/3 \"a b\"" }),
      call("4", "Grep", { pattern = "x", path = "/work/arena/project", glob = "*.tl" }),
      call("5", "Glob", { pattern = "/home/user/*.md", path = "/work/arena" }),
      call("6", "Read", { file_path = "/proc/1/root/x" }),
      call("7", "Write", { file_path = "/work/arena/project/CLAUDE.md", content = "x" }),
    }, "\n") .. "\n"
    local _ = Summarize.report(text, "/work/arena", "/src/cosmic")
    local _ = Summarize.paths("Bash", { command = "cat ~/x ~user/y $HOME" }, "/work/arena/project")
  end)
end

--- A command line that leaves out the options it may leave out, and one
--- that names a bad number, an unknown option and no arena.
local function test_the_option_readers_answer_what_they_declare()
  honest("options", function()
    for _, argv in ipairs({
        { "all", "--model", "m" }, { "all", "--model", "m", "--tool", "/t", "--out", "/o" },
        { "all", "--model", "m", "--run", "0" }, { "all", "--model", "m", "--run" }, { "nope" }, {},
        { "all", "--model", "m", "--bogus", "1" },
    }) do
      local _, _ = Round.parse(argv)
    end
    for _, argv in ipairs({
        { "/a", "--model", "m" }, { "/a", "--model", "m", "--timeout", "x" }, { "/a" }, { "--model", "m" },
        { "/a", "/b", "--model", "m" }, { "/a", "--model" },
    }) do
      local _, _ = Solve.parse(argv)
    end
  end)
end
