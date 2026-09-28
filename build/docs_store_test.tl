--- `build.docs`'s tests that read every database a lookup answers from
--- -- the binary's own and the tree's o/cosmic.db -- rather than one a
--- test builds: apart from build/docs_test.tl's so those stand while the
--- tree moves.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local docs = require("build.docs")

--- The projection, asked directly, and whether the tree is cosmic's own.
Test.needs{ reads = { "core" }, store = true }

--- A project's own o/cosmic.db that is not a database is left out,
--- rather than failing every lookup: help and docs still answer from
--- the binary's own databases.
local function test_an_unreadable_own_database_is_left_out(dir: string)
  assert(Fs.mkdirs(dir .. "/o"))
  assert(Fs.write(dir .. "/o/cosmic.db", "not a database"))
  local before = assert(sys.getcwd())
  assert(sys.chdir(dir))
  local sources = docs.databases()
  assert(sys.chdir(before))
  local looked = assert(docs.view(sources.handles, sources.public))
  local found = assert(docs.lookup(looked, "Fs.read"))
  assert(#found > 0 and found.exact)
end

--- What a newcomer types first is the command or call they would have
--- used elsewhere. Each of these, looked up the way a project sees the
--- standard library, answers with the function that stands in for it
--- first, after any raw `cosmic.sys` binding of that name -- so a doc
--- comment that stops naming its command is caught here, not by the
--- next person who writes the function again.
local function test_a_familiar_command_finds_its_stand_in()
  -- Read from this tree's own o/cosmic.db, which the build rewrites
  -- before any test runs: a doc comment edit changes that file, and
  -- so this test's verdict key -- SQLite's open of it is observed like
  -- any other (build.filesystem_observations) -- and the test runs again.
  local handles = docs.databases().handles
  local public: {boolean} = {}
  for index = 1, #handles do public[index] = true end
  local looked = assert(docs.view(handles, public))
  local stand_ins: {{string}} = {
    { "which", "Proc.find" },
    { "command -v", "Proc.find" },
    { "Proc.which", "Proc.find" },
    { "cp -R", "Fs.copy_tree" },
    { "mkdir -p", "Fs.mkdirs" },
    { "rm -rf", "Fs.remove_tree" },
    { "unlink", "Fs.remove" },
    { "ls", "Fs.list" },
    { "find type", "Fs.walk" },
    { "mktemp", "Fs.mkdtemp" },
    { "realpath", "Fs.absolute" },
    { "mv", "Fs.rename" },
    { "ln -s", "Fs.symlink" },
    { "touch", "Fs.set_mtime" },
    { "nproc", "Proc.cpu_count" },
    { "isatty", "Proc.is_tty" },
    { "getpid", "Proc.pid" },
    { "curl", "Http.download" },
    { "wget", "Http.download" },
    { "tar -x", "Archive.extract" },
    { "unzip", "Archive.extract" },
    { "sha256sum", "Hash.hex_sha256" },
    { "sleep", "Time.sleep_ns" },
    { "getentropy", "Rand.entropy" },
    { "getenv", "Env.get" },
    { "urandom", "Rand.entropy" },
  }
  local wrong: {string} = {}
  for _, case in ipairs(stand_ins) do
    -- A raw binding of the same name may come first; what stands in
    -- for it must come right after.
    local found = assert(docs.lookup(looked, case[1]))
    local first = "nothing"
    for _, entry in ipairs(found) do
      if entry.module ~= "cosmic.sys" then
        first = entry.source_symbol
        break
      end
    end
    if first ~= case[2] then
      wrong[#wrong + 1] = case[1] .. " -> " .. first .. ", not " .. case[2]
    end
  end
  assert(#wrong == 0, table.concat(wrong, "; "))
end
