--- Atomic, generation-named directory claims for a future make writer lock.
--- This module deliberately says nothing about holder liveness.
local fs = require("cosmic.fs")
local uuid = require("cosmic.uuid")

local record Claim
  state: string
  token: string
  message: string
end

local record Observation
  state: string
  token: string
  payload: string
  message: string
end

local function claim(state: string, token?: string, message?: string): Claim
  return {state = state, token = token or "", message = message or ""}
end

local function observation(state: string,
  token?: string, payload?: string, message?: string): Observation
  return {state = state, token = token or "", payload = payload or "", message = message or ""}
end

--- fs formats failures as `operation: path: ERRNO: detail`. Paths can name
--- errno strings too, so only the final errno component describes the call.
local function errno_component(err: string): string
  return err:match(": (E[%u%d]+): [^:]*$") or ""
end

local function absent(err: string): boolean
  return errno_component(err) == "ENOENT"
end

local function uuid_token(token: string): boolean
  return token:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

local function checked_path(path: string): string, string
  if path == "" then return "", "lock path is empty" end
  if not fs.is_absolute(path) then return "", "lock path is not absolute" end
  return fs.normalize(path), ""
end

--- List a real directory's immediate names without following the lock path.
local function names(path: string): {string} | nil, string
  local st, serr = fs.stat_link(path)
  if not st then
    if absent(serr) then return {} end
    return nil, serr
  end
  if st:is_link() or not st:is_dir() then return nil, "lock path is not a directory" end
  local dir, derr = fs.open_dir(path)
  if not dir then return nil, derr end
  local got: {string} = {}
  while true do
    local name = dir:read()
    if not name then break end
    if name ~= "." and name ~= ".." then got[#got + 1] = name end
  end
  dir:close()
  table.sort(got)
  return got
end

local function same_names(a: {string}, b: {string}): boolean
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

--- A failed owner operation can be an ordinary malformed entry or a
--- generation turnover. Re-read the directory names to tell those apart.
local function changed_since(path: string, before: {string}): boolean
  local after = names(path)
  return after ~= nil and not same_names(before, after)
end

local function sole_owner(list: {string}): string, string
  if #list == 0 then return "", "vacant" end
  if #list ~= 1 then return "", "unexpected lock directory entries" end
  local token = list[1]:match("^owner%-(.*)$")
  if not token or not uuid_token(token) then return "", "invalid owner filename" end
  return token, ""
end

--- Remove only a failed call's sibling candidate. It never touches lockpath.
local function cleanup(candidate: string, owner: string): string
  local removed = fs.remove_dir(candidate)
  if removed then return "" end
  local file_removed, ferr = fs.remove(owner)
  if not file_removed and not absent(ferr) then return ferr end
  local dir_removed, derr = fs.remove_dir(candidate)
  if not dir_removed and not absent(derr) then return derr end
  return ""
end

--- Nonblocking atomic acquisition. A complete sibling is renamed into place.
local function try_acquire(path: string, payload: string): Claim
  local lockpath, perr = checked_path(path)
  if lockpath == "" then return claim("error", "", perr) end
  if #payload > 4096 then return claim("error", "", "lock payload exceeds 4096 bytes") end

  local token = uuid.v4()
  local parent = fs.dirname(lockpath)
  local candidate = fs.join(parent, "." .. fs.basename(lockpath) .. ".candidate-" .. token)
  local made, merr = fs.make_dir(candidate)
  if not made then return claim("error", "", merr) end
  local owner = fs.join(candidate, "owner-" .. token)
  local wrote, werr = fs.write(owner, payload)
  if not wrote then
    local cerr = cleanup(candidate, owner)
    if cerr ~= "" then return claim("error", "", cerr) end
    return claim("error", "", werr)
  end

  -- candidate and destination are siblings, so fs.move's EXDEV fallback
  -- cannot be a publication path.
  local moved, move_err = fs.move(candidate, lockpath)
  if moved then return claim("owned", token) end
  local cerr = cleanup(candidate, owner)
  if cerr ~= "" then return claim("error", "", cerr) end

  local existing, eerr = names(lockpath)
  if existing and #existing > 0 then return claim("busy") end
  if not existing then return claim("error", "", eerr) end
  return claim("error", "", move_err)
end

--- Read one stable generation. Filename recheck prevents mixed generations.
local function observe(path: string): Observation
  local lockpath, perr = checked_path(path)
  if lockpath == "" then return observation("error", "", "", perr) end
  local before, berr = names(lockpath)
  if not before then return observation("error", "", "", berr) end
  local token, terr = sole_owner(before)
  if terr == "vacant" then return observation("vacant") end
  if terr ~= "" then return observation("error", "", "", terr) end
  local owner = fs.join(lockpath, "owner-" .. token)
  local st, serr = fs.stat_link(owner)
  if not st then
    if changed_since(lockpath, before) then return observation("changed") end
    return observation("error", "", "", serr)
  end
  if st:is_link() or not st:is_file() then
    return observation("error", "", "", serr ~= "" and serr or "owner is not a regular file")
  end
  local payload, rerr = fs.read(owner)
  if not payload then
    if changed_since(lockpath, before) then return observation("changed") end
    return observation("error", "", "", rerr)
  end
  local after, aerr = names(lockpath)
  if not after then
    if absent(aerr) then return observation("changed") end
    return observation("error", "", "", aerr)
  end
  if not same_names(before, after) then return observation("changed") end
  local final, ferr = fs.stat_link(owner)
  if not final then
    if changed_since(lockpath, before) then return observation("changed") end
    return observation("error", "", "", ferr)
  end
  if final:is_link() or not final:is_file() then
    return observation("error", "", "", "owner is not a regular file")
  end
  if #payload > 4096 then return observation("error", "", "", "owner payload exceeds 4096 bytes") end
  return observation("present", token, payload)
end

--- Authorize retirement of exactly one named generation, never its successor.
local function retire(path: string, token: string): boolean, string
  local lockpath, perr = checked_path(path)
  if lockpath == "" then return false, perr end
  if not uuid_token(token) then return false, "invalid lock token" end
  local st, serr = fs.stat_link(lockpath)
  if not st then
    if absent(serr) then return true end
    return false, serr
  end
  if st:is_link() or not st:is_dir() then return false, "lock path is not a directory" end
  local removed, rerr = fs.remove(fs.join(lockpath, "owner-" .. token))
  if not removed then
    if absent(rerr) then return true end
    return false, rerr
  end
  local dir_removed, derr = fs.remove_dir(lockpath)
  if dir_removed or absent(derr) or errno_component(derr) == "ENOTEMPTY" then return true end
  return false, derr
end

local record Lockdir
  type Claim = Claim
  type Observation = Observation
  try_acquire: function(path: string, payload: string): Claim
  observe: function(path: string): Observation
  retire: function(path: string, token: string): boolean, string
end

local M: Lockdir = {try_acquire = try_acquire, observe = observe, retire = retire}
return M
