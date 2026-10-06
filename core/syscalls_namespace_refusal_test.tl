--- A strict raw start reports a namespace or idmapped-bind refusal
--- without needing the policy wrapper to map a user first. The start
--- names no executable and binds only this test's scratch.

local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")
local type _ = require("cosmic.child")

Test.policy{ promises = { "nest" } }

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

--- A missing executable proves that namespace preparation finished. A
--- known kernel refusal is explicit and earns no passing verdict.
local function start(tmp: string, sandbox: raw_process.Sandbox, stage: string, mapping?: boolean)
  local path = tmp .. "/absent"
  local pid, why, errno = raw_table().spawn(path, { path }, nil, nil, nil, nil, nil,
    false, nil, sandbox)
  assert(pid == nil, "an absent executable started")
  if errno == sys.EPERM or errno == sys.EACCES or errno == sys.ENOSPC or errno == sys.ENOSYS or
      errno == sys.EOPNOTSUPP or (errno == sys.EINVAL and why:find("an idmapped mount of", 1, true) ~= nil) or
      (errno == sys.ENOENT and stage == "an idmapped mount of" and why:find(stage, 1, true) ~= nil) then
    local names = assert(sys.uname())
    if names.sysname == "Linux" then
      assert(why:find(stage, 1, true) ~= nil or
          (errno == sys.EPERM and stage == "this sandbox's user, mount, pid or network namespace was refused" and
            why:find("this sandbox's root could not be built", 1, true) ~= nil) or
          (mapping and errno == sys.EPERM and why == "Operation not permitted"), why)
    else
      assert(errno == sys.ENOSYS and why == "Function not implemented", why)
    end
    Test.skip("the host refuses this raw sandbox start: " .. why)
  end
  assert(errno == sys.ENOENT and why == "No such file or directory", why)
end

local function test_a_strict_namespace_start_refuses_explicitly_before_exec(tmp: string)
  start(tmp, { strict = true, offline = true, unveil = { reads = {}, writes = {} },
    promises = { "nest" } }, "this sandbox's user, mount, pid or network namespace was refused")
end

local function test_a_mapped_user_start_refuses_explicitly_before_exec(tmp: string)
  local user = sys.getuid() == 1 and 2 or 1
  start(tmp, { strict = true, offline = true, unveil = { reads = {}, writes = {} },
    promises = { "nest" }, user = user, group = user },
    "this sandbox's user, mount, pid or network namespace was refused", true)
end

local function test_an_idmapped_bind_refuses_explicitly_before_exec(tmp: string)
  local path = tmp .. "/mapped"
  assert(Fs.mkdirs(path))
  local user = sys.getuid() == 1 and 2 or 1
  start(tmp, { strict = true, offline = true,
    unveil = { reads = {}, writes = {}, binds = { { path = path, at = "/mapped", idmap = true } } },
    promises = { "nest" }, user = user, group = user }, "an idmapped mount of")
end
