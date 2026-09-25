-- The bridge: the only Lua in the tree that is not compiled from Teal,
-- because it is what makes Teal available. It builds the handful of
-- things the vendored compiler reaches for outside the pure libraries --
-- `io.open` and the handle it returns, `io.stderr`, `io.type`,
-- `os.getenv`, `package.path` and `package.searchers` -- over the syscall
-- table, so the compiler runs unpatched and never observes that those
-- names are gone. It also holds the one module that exists before any
-- file does, the syscall table's declaration, and serves it to the
-- checker from memory.
--
-- A boot (`cosmic-core --boot <root> ...`, core/boot.c) loads it from
-- the tree it boots, as it loads the vendored compiler, and runs it with
-- that root; nothing else does. It is part of the core's image
-- fingerprint (build/work.tl), since what it sets the compiler to shapes
-- what a boot compiles.
local root = ...
local sys = require('cosmic.sys')

local function read_all(path)
  local fd, err = sys.open(path, sys.O_RDONLY)
  if not fd then return nil, err end
  local parts = {}
  while true do
    local chunk, rerr = sys.read(fd, 65536)
    if not chunk then sys.close(fd); return nil, rerr end
    if #chunk == 0 then break end
    parts[#parts + 1] = chunk
  end
  sys.close(fd)
  return table.concat(parts)
end

local function make_handle(fd)
  local h = { is_boot_handle = true }
  function h:read(what)
    if what ~= '*a' and what ~= 'a' then
      error('the boot handle reads whole files only')
    end
    local parts = {}
    while true do
      local chunk, err = sys.read(fd, 65536)
      if not chunk then return nil, err end
      if #chunk == 0 then break end
      parts[#parts + 1] = chunk
    end
    return table.concat(parts)
  end
  function h:write(...)
    local n = select('#', ...)
    for i = 1, n do
      local data = tostring((select(i, ...)))
      local at = 1
      while at <= #data do
        local put, err = sys.write(fd, data:sub(at))
        if not put then return nil, err end
        at = at + put
      end
    end
    return self
  end
  function h:flush() return self end
  function h:close() return sys.close(fd) end
  return h
end

local shim_io = {
  stdout = make_handle(1),
  stderr = make_handle(2),
  type = function(value)
    if type(value) == 'table' and value.is_boot_handle then
      return 'file'
    end
    return nil
  end,
  open = function(path, mode)
    local flags = sys.O_RDONLY
    if mode and mode:find('w') then
      flags = sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC
    end
    local fd, err = sys.open(path, flags)
    if not fd then return nil, err end
    return make_handle(fd)
  end,
}

-- The pure libraries, read straight out of the global table. The
-- hint a removed name raises is for a program someone wrote; the
-- compiler is not one, and a name it does not find is nil, which
-- is what plain Lua does.
local environment = setmetatable({
  io = shim_io,
  os = { getenv = sys.getenv },
  package = { path = '', searchers = {}, loaded = {} },
}, { __index = function(_, name) return rawget(_G, name) end })

local function complain(file, result)
  local lines = {}
  local function gather(kind, list)
    for _, e in ipairs(list or {}) do
      lines[#lines + 1] = string.format('%s:%d:%d: %s: %s',
        e.filename or file, e.y or 0, e.x or 0, kind, e.msg)
    end
  end
  gather('syntax error', result and result.syntax_errors)
  gather('type error', result and result.type_errors)
  gather('warning', result and result.warnings)
  return table.concat(lines, '\n')
end

-- A module handed in as text, never written anywhere: the syscall
-- table's declaration, which boot generates with build.gen_syscalls
-- before the bridge checks any module, and which every module that
-- requires `cosmic.sys` is checked against.
local declared = {}

local function declare(name, text)
  declared[name] = text
end

local function text_handle(text)
  local h = { is_boot_handle = true }
  function h:read() return text end
  function h:close() return true end
  return h
end

local function searcher_for(tl)
  tl.path = root .. '/?.lua;' .. root .. '/?/init.lua'
  local disk_search = tl.search_module
  tl.search_module = function(name, search_all)
    local text = declared[name]
    if text then
      local stem = name:gsub('%.', '/')
      return root .. '/' .. stem .. '.d.tl', text_handle(text)
    end
    return disk_search(name, search_all)
  end
  local env = assert(tl.new_env({ defaults = {
    feat_lax = 'off', gen_compat = 'off', gen_target = '5.4',
  } }))
  return function(name)
    local stem = root .. '/' .. name:gsub('%.', '/')
    local file = stem .. '.tl'
    local source = read_all(file)
    if not source then
      local dir_file = stem .. '/init.tl'
      source = read_all(dir_file)
      if not source then
        return "\n\tno file '" .. file .. "'" ..
          "\n\tno file '" .. dir_file .. "'"
      end
      file = dir_file
    end
    local code, result = tl.gen(source, env, nil, 'tl')
    local trouble = complain(file, result)
    if not code or trouble ~= '' then
      error(file .. ': the compiler refused it\n' .. trouble, 0)
    end
    local chunk, err = load(code, '@' .. name, 't')
    if not chunk then error(file .. ': ' .. err, 0) end
    return chunk, file
  end
end

return { environment = environment, searcher_for = searcher_for,
         declare = declare }
