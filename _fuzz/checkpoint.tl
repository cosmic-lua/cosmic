--- Internal version-1 diagnostic checkpoints. A record describes only the
--- diagnostic child's last checkpoint; it cannot identify the original input.
local fd = require("cosmic.fd")
local fs = require("cosmic.fs")

local HEADER < const > = ">c8i8i8i8I1I1i8I4"
local HEADER_BYTES < const > = string.packsize(HEADER)
local INPUT_CAP < const > = 1048576

local record Snapshot
  seed: integer
  iters: integer
  iteration: integer
  phase: integer
  stage: integer
  draws: integer
  input: string
end

local record Decoded
  valid: boolean
  snapshot: Snapshot | nil
  error: string
end

local record Encoded
  valid: boolean
  bytes: string | nil
  error: string
end

local function invalid(message: string): Decoded
  return {valid = false, error = message}
end

local function metadata_error(s: Snapshot): string
  if math.type(s.seed) ~= "integer" or math.type(s.iters) ~= "integer"
  or math.type(s.iteration) ~= "integer" or math.type(s.draws) ~= "integer" then
    return "checkpoint counts must be integers"
  end
  if s.iters <= 0 or s.iteration < 1 or s.iteration > s.iters or s.draws < 0 then
    return "checkpoint counts out of range"
  end
  if s.phase ~= 1 and s.phase ~= 2 and s.phase ~= 3 and s.phase ~= 4 then
    return "unknown checkpoint phase"
  end
  if s.stage ~= 1 and s.stage ~= 2 and s.stage ~= 3 then
    return "unknown checkpoint stage"
  end
  if s.phase ~= 2 and (s.draws ~= 0 or s.input ~= "") then
    return "non-checking checkpoint carries input or draws"
  end
  return ""
end

local function encode(snapshot: Snapshot): Encoded
  local err = metadata_error(snapshot)
  if err ~= "" then return {valid = false, error = err} end
  local phase, draws, input = snapshot.phase, snapshot.draws, snapshot.input
  if phase == 2 and #input > INPUT_CAP then
    phase, draws, input = 4, 0, ""
  end
  local ok, header = pcall(string.pack, HEADER, "CFUZZ001", snapshot.seed,
    snapshot.iters, snapshot.iteration, phase, snapshot.stage, draws, #input)
  if not ok then return {valid = false, error = "checkpoint pack: " .. tostring(header)} end
  return {valid = true, bytes = header .. input, error = ""}
end

local function decode(bytes: string, seed: integer, iters: integer): Decoded
  if #bytes < HEADER_BYTES then return invalid("short checkpoint header") end
  if #bytes > HEADER_BYTES + INPUT_CAP then return invalid("checkpoint exceeds cap") end
  local ok, magic, stored_seed, stored_iters, iteration, phase, stage, draws, length =
  pcall(string.unpack, HEADER, bytes)
  if not ok then return invalid("checkpoint unpack: " .. tostring(magic)) end
  if magic ~= "CFUZZ001" then return invalid("invalid checkpoint magic") end
  if stored_seed ~= seed or stored_iters ~= iters then
    return invalid("checkpoint seed or iters mismatch")
  end
  if length > INPUT_CAP or length ~= #bytes - HEADER_BYTES then
    return invalid("invalid checkpoint payload length")
  end
  local snapshot: Snapshot = {seed = stored_seed, iters = stored_iters,
    iteration = iteration, phase = phase, stage = stage, draws = draws,
    input = bytes:sub(HEADER_BYTES + 1)}
  local err = metadata_error(snapshot)
  if err ~= "" then return invalid(err) end
  return {valid = true, snapshot = snapshot, error = ""}
end

local function write(path: string, snapshot: Snapshot): boolean, string
  local encoded = encode(snapshot)
  if not encoded.valid then return false, encoded.error end
  local bytes = encoded.bytes
  if not bytes then return false, "checkpoint encoding missing bytes" end
  local ok, written, err = pcall(fs.write, path, bytes,
    {atomic = true, mode = fs.octal("600")})
  if not ok then return false, "checkpoint write: " .. tostring(written) end
  if not written then return false, "checkpoint write: " .. tostring(err) end
  return true, ""
end

local function read(path: string, seed: integer, iters: integer): Decoded
  local h, err = fd.open(path, fd.O_RDONLY | fd.O_NONBLOCK | fd.O_NOFOLLOW)
  if not h then return invalid("checkpoint open: " .. tostring(err)) end
  local chunks: {string} = {}
  local remaining = HEADER_BYTES + INPUT_CAP + 1
  local stat, stat_err = fs.stat_fd(h:fd())
  local failure = ""
  if not stat then failure = "checkpoint stat: " .. tostring(stat_err)
  elseif not stat:is_file() then failure = "checkpoint is not a regular file" end
  while failure == "" and remaining > 0 do
    local chunk, read_err = h:read(math.min(65536, remaining))
    if not chunk then
      if read_err then failure = "checkpoint read: " .. read_err end
      break
    end
    chunks[#chunks + 1] = chunk
    remaining = remaining - #chunk
  end
  local closed, close_err = h:close()
  if not closed then
    failure = failure .. " checkpoint close: " .. tostring(close_err)
  end
  if failure ~= "" then return invalid(failure) end
  return decode(table.concat(chunks), seed, iters)
end

local record CheckpointModule
  type Snapshot = Snapshot
  type Decoded = Decoded
  type Encoded = Encoded
  encode: function(snapshot: Snapshot): Encoded
  decode: function(bytes: string, seed: integer, iters: integer): Decoded
  write: function(path: string, snapshot: Snapshot): boolean, string
  read: function(path: string, seed: integer, iters: integer): Decoded
end

local M: CheckpointModule = {encode = encode, decode = decode, write = write, read = read}
return M
