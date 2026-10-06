--- `spawn`'s `promises` on a dynamic host program: the system's own shell,
--- which a loader starts and maps libraries into, as the stand-in of
--- core/promises_child_test.tl, a static core, does not. The loader's
--- calls -- on aarch64 an mprotect that adds PROT_EXEC with PROT_BTI --
--- must pass the basics, or a program that needs them does not start.
--- Where the host has no /bin/sh or no sandbox the tests are skipped, as
--- they require both of the host (off Linux, no sandbox, they are not
--- applicable); where the kernel still gives no seccomp filter, each skips
--- itself.

local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")
-- Required, so the module whose loader is handed the raw table is of this
-- test's import closure, and the store has it to hand it from.
local type _ = require("cosmic.child")

--- The system's own programs, which the shell and its libraries are, and
--- the shell itself, which the host must have.
Test.policy{
  profiles = { "system" },
  grants = { { path = "/bin/sh", letters = "r" } },
  requires = { "sandbox", "path:/bin/sh" },
}

local type Searcher = function(string): any, any

--- The raw table the store's searcher hands `wrapper`'s loader.
local function raw_behind(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error(wrapper .. " is handed no raw table")
end

local process = raw_behind("cosmic.child") as raw_process -- cast: the table core/process.h declares

local SHELL <const> = "/bin/sh"

--- How the shell ended running `script` under `promises`; skips the test
--- where the kernel gives no filter.
local function shell(promises: {string}, script: string): integer
  local pid, trouble = process.spawn(SHELL, { SHELL, "-c", script }, {}, nil, nil, nil, nil,
    false, nil, { promises = promises })
  if pid == nil then Test.skip("the kernel gives no seccomp filter: " .. tostring(trouble)) end
  return assert(process.waitpid(pid, false)).code
end

local function test_a_dynamic_program_starts_under_the_basics()
  local code = shell({}, "exit 0")
  assert(code == 0, "the shell ends with " .. code)
  assert(shell({}, "exit 7") == 7)
end

local function test_a_dynamic_program_forks_with_fork()
  -- A subshell is a fork, which the shell reports by its status.
  local code = shell({ "fork" }, "(exit 3); exit $?")
  assert(code == 3, "a subshell under fork ends with " .. code)
  assert(shell({ "fork", "jit", "fattr" }, "(exit 0)") == 0)
end
