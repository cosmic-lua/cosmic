--- Versioned fuzz result files and byte-exact regression inputs.
local codec = require("cosmic.codec")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local json = require("cosmic.json")
local types = require("cosmic.fuzz.types")

local function new(name: string, seed: integer): types.Result
  return {status = "running", name = name, seed = seed, iteration = 0,
    generated = 0, corpus = 0, draws = 0, phase = "startup", failure_kind = "",
    message = "", has_input = false, input = "", signal = 0,
    reproduction = "not_attempted", saved_input = "", saved_result = ""}
end

--- The wire representation encodes all byte strings; JSON's UTF-8 policy
--- must never change a captured input or an error message.
local function write(path: string, r: types.Result): boolean, string
  local data, err = json.encode({version = 1, status = r.status, name = r.name,
      seed = r.seed, iteration = r.iteration, generated = r.generated,
      corpus = r.corpus, draws = r.draws, phase = r.phase,
      failure_kind = r.failure_kind, message = codec.encode_base64(r.message),
      has_input = r.has_input, input = codec.encode_base64(r.input), signal = r.signal,
      reproduction = r.reproduction, saved_input = r.saved_input,
      saved_result = r.saved_result})
  if not data then return false, err end
  -- A close before check is sufficient for a worker-process crash. A torn
  -- write is invalid JSON and is refused; machine/power failure is out of scope.
  return fs.write(path, data)
end

local function read(path: string): types.Result | nil, string
  local data, err = fs.read(path)
  if not data then return nil, err end
  local obj, why = json.decode_object(data)
  if not obj then return nil, why end
  if obj.version ~= 1 then return nil, "unsupported fuzz result version" end
  local r = new("", 0)
  -- Validate each field at the untrusted file boundary, before assigning it.
  local strings: {string} = {"status", "name", "phase", "failure_kind", "message",
    "input", "reproduction", "saved_input", "saved_result"}
  for _, key in ipairs(strings) do
    local value = obj[key]
    if not (value is string) then return nil, "invalid fuzz field: " .. key end
  end
  local numbers: {string} = {"seed", "iteration", "generated", "corpus", "draws", "signal"}
  for _, key in ipairs(numbers) do
    local n = obj[key]
    if not (n is integer) then return nil, "invalid fuzz integer: " .. key end
  end
  local has_input = obj.has_input
  if not (has_input is boolean) then return nil, "invalid fuzz has_input" end
  -- cast: validated wire record, with encoded bytes decoded immediately below
  r = obj as types.Result
  local input, ierr = codec.decode_base64(r.input)
  if not input then return nil, ierr end
  local message, merr = codec.decode_base64(r.message)
  if not message then return nil, merr end
  r.input, r.message = input, message
  return r
end

local function save(dir: string, r: types.Result): boolean, string
  local ok, err = fs.make_dirs(dir)
  if not ok then return false, err end
  if r.has_input then
    r.saved_input = fs.join(dir, hash.sha256_hex(r.input) .. ".input")
    ok, err = fs.write(r.saved_input, r.input, {atomic = true})
    if not ok then return false, err end
  end
  r.saved_result = fs.join(dir, "result.json")
  return write(r.saved_result, r)
end

--- Explicit promotion writes only the input, never the transient run metadata.
local function promote(r: types.Result, corpus_dir: string): boolean, string
  if not r.has_input then return false, "result has no captured input" end
  local dir = fs.join(corpus_dir, r.name)
  if not r.name:match("^[%w_.-]+$") or r.name == "." or r.name == ".." then
    return false, "invalid property name"
  end
  local ok, err = fs.make_dirs(dir)
  if not ok then return false, err end
  return fs.write(fs.join(dir, hash.sha256_hex(r.input) .. ".input"), r.input, {atomic = true})
end

return {new = new, read = read, write = write, save = save, promote = promote}
