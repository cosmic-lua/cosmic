local fuzz = require('cosmic.fuzz')
local env = require('cosmic.env')
local fs = require('cosmic.fs')
local json = require('cosmic.json')
local signal = require('cosmic.signal')
local time = require('cosmic.time')
local name = env.get('FUZZ_CASE') or 'pass'
local root = assert(env.get('FUZZ_ROOT'))
local calls = 0
local checks = 0
local opts = {
  name = name, seed = 42, iters = 8, artifact_dir = root .. '/artifacts',
  corpus_dir = root .. '/corpus',
  gen = function(src)
    calls = calls + 1
    if name == 'generator_throw' then error('generator broke') end
    if name == 'generator_crash' then signal.raise(signal.SIGKILL) end
    if name == 'shrink' or name == 'shrink_crash' then return fuzz.bytes(src, 32) end
    return tostring(calls) .. '\0\255'
  end,
  check = function(input)
    checks = checks + 1
    if name == 'crash' and input == '5\0\255' then signal.raise(signal.SIGKILL) end
    if name == 'stateful' and checks == 5 then return false, 'fifth check failed' end
    if name == 'timeout' then
      signal.sigaction(signal.SIGTERM, signal.SIG_IGN)
      assert(time.sleep_ms(5000))
    end
    if name == 'zero_exit' then os.exit(0) end
    if name == 'throw' then error('property threw') end
    if name == 'message_category' then return false, 'budget=100000 exceeded' end
    if name == 'budget' then while true do end end
    if name == 'shrink' then
      if #input < 4 then while true do end end
      return false, 'assertion remains'
    end
    if name == 'shrink_crash' then
      if #input < 4 then signal.raise(signal.SIGKILL) end
      return false, 'original assertion'
    end
    if name == 'corpus' then return input ~= 'saved\0\255', 'corpus failure' end
    return true
  end,
}
if name == 'timeout' then opts.timeout_ms = 500 end
if name == 'budget' or name == 'shrink' then opts.budget = 100000 end
if name == 'replay' then
  opts.replay_input = 'exact\0\255'
  opts.gen = function() error('replay called generator') end
  opts.check = function(input) return input == 'exact\0\255', 'wrong replay bytes' end
end
if name == 'ambient' then assert(env.set('FUZZ_ISOLATE', 'missing')) end
if name == 'stale_worker' then assert(env.set('COSMIC_FUZZ_WORKER', root .. '/missing')) end
local result = fuzz.run(opts)
print((assert(json.encode(result))))
