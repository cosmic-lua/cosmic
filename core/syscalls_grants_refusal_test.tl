--- A Landlock ruleset applies without making a user namespace: its
--- child reports the absent program only after being restricted.

local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")
local type _ = require("cosmic.child")

Test.policy{ requires = { "landlock" } }

local type Searcher = function(string): any, any

local function raw_table(): raw_process
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.child")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_process -- cast: the table core/process.h declares
    end
  end
  error("cosmic.child is handed no raw table")
end

local function test_a_grants_ruleset_is_applied_before_an_absent_program_is_refused(tmp: string)
  local path = tmp .. "/absent"
  local pid, why, errno = raw_table().spawn(path, { path }, nil, nil, nil, nil, nil,
    false, nil, { grants = {} })
  assert(pid == nil and errno == sys.ENOENT and why == "No such file or directory", why)
end
