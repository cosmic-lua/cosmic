--- A draw-recording wrapper over cosmic.rand.Source.
--- Every draw a Recorder makes is appended to `draws` in order, so a
--- failing run's exact choice sequence can be replayed to reproduce it,
--- or -- a future slice -- shrunk to simplify it before it is reported.
--- Internal to `_fuzz`: no shrinking exists yet, so this is not ready to
--- be `cosmic.fuzz`'s public surface.

local rand = require("cosmic.rand")

--- One recorded draw. `kind` says which value field is meaningful:
--- "int" draws carry `lo`/`hi`/`ivalue`, "float" draws carry `fvalue`.
local record Draw
  kind: string
  lo: integer
  hi: integer
  ivalue: integer
  fvalue: number
end

--- A rand.Source-shaped wrapper that records (Recorder.new) or replays
--- (Recorder.replay) a sequence of draws.
local record Recorder
  draws: {Draw}
  int: function(Recorder, integer, integer): integer
  float: function(Recorder): number
end

--- Wrap a Source so every draw it produces is appended to `draws`.
--- @param src rand.Source The source to record draws from
--- @return Recorder A recording wrapper over src
local function new(src: rand.Source): Recorder
  local draws: {Draw} = {}
  local rec: Recorder = {draws = draws}
  rec.int = function(_self: Recorder, min: integer, max: integer): integer
    local v = src:int(min, max)
    draws[#draws + 1] = {kind = "int", lo = min, hi = max, ivalue = v}
    return v
  end
  rec.float = function(_self: Recorder): number
    local v = src:float()
    draws[#draws + 1] = {kind = "float", fvalue = v}
    return v
  end
  return rec
end

--- Replay a previously-recorded draw sequence: each call returns the
--- next recorded value in order, ignoring the bounds passed at replay
--- time (the recorded value is authoritative). Throws when asked for a
--- draw past the end of the sequence, or for a draw of the wrong kind
--- -- a replay whose generator diverged from the one that recorded it
--- is a bug to surface loudly, by position, not to silently truncate.
--- @param draws {Draw} A previously-recorded draw sequence
--- @return Recorder A source that replays draws in order
local function replay(draws: {Draw}): Recorder
  local pos = 0
  local function next_draw(kind: string): Draw
    pos = pos + 1
    local d = draws[pos]
    if d == nil then
      error("_fuzz.source.replay: no recorded draw at position " .. pos, 3)
    end
    if d.kind ~= kind then
      error(string.format(
          "_fuzz.source.replay: draw %d is %s, expected %s", pos, d.kind, kind), 3)
    end
    return d
  end
  local rec: Recorder = {draws = draws}
  rec.int = function(_self: Recorder, _min: integer, _max: integer): integer
    local d = next_draw("int")
    local v = d.ivalue
    if v == nil then
      error("_fuzz.source.replay: draw " .. pos .. " has no int value", 2)
    end
    return v
  end
  rec.float = function(_self: Recorder): number
    local d = next_draw("float")
    local v = d.fvalue
    if v == nil then
      error("_fuzz.source.replay: draw " .. pos .. " has no float value", 2)
    end
    return v
  end
  return rec
end

local record SourceModule
  type Draw = Draw
  type Recorder = Recorder
  new: function(src: rand.Source): Recorder
  replay: function(draws: {Draw}): Recorder
end

local M: SourceModule = {
  new = new,
  replay = replay,
}

return M
