--- Writes the verdict table of the switch's gate again ([`lang.check_verdicts`]): [`testdata/gate/verdicts.json`], each row
--- given what the new checker says of its program now, and what the fork said of it, which is frozen data (the fork went
--- with the switch), kept as it is. Run it from the tree's root as `bin/cosmic build/gate_record.tl` and read the diff.
---
--- It adds no row: a program with none has no fork side to keep, which is the gap [`lang/check_verdicts.tl`] records.
local Fs = require("cosmic.fs")
local Verdicts = require("lang.check_verdicts")
local plural = require("build.plural")

local record GateRecord
  main: function(argv: {string}): integer
end

--- The table, from the tree's root.
local TABLE <const> = "testdata/gate/verdicts.json"

function GateRecord.main(_argv: {string}): integer
  local text, trouble = Fs.read(TABLE)
  if text == nil then
    local _, _ = Fs.put(Fs.stderr, "gate_record: " .. TABLE .. ": " .. tostring(trouble) .. " (run it from the tree's root)\n")
    return 2
  end
  local rows, why = Verdicts.read_rows(text)
  if rows == nil then
    local _, _ = Fs.put(Fs.stderr, "gate_record: " .. TABLE .. ": " .. tostring(why) .. "\n")
    return 2
  end
  local prelude, stdlib = assert(Fs.read("lang/prelude.d.tl")), assert(Fs.read("lang/stdlib.d.tl"))
  local judge = Verdicts.judge(prelude, stdlib)
  local judged: mut {Verdicts.Row} = {}
  local counts: mut {string: integer} = {}
  local changed = 0
  for _, row in ipairs(rows) do
    local made = Verdicts.with_new(row, judge(row.source))
    judged[#judged + 1] = made
    if made.new ~= row.new or made.new_stage ~= row.new_stage or made.new_codes ~= row.new_codes then
      changed = changed + 1
    end
    local key = "fork " .. made.fork .. ", new " .. made.new
    counts[key] = (counts[key] or 0) + 1
  end
  local written, write_why = Fs.write(TABLE, Verdicts.write_rows(judged))
  if not written then
    local _, _ = Fs.put(Fs.stderr, "gate_record: " .. TABLE .. ": " .. tostring(write_why) .. "\n")
    return 2
  end
  local keys: mut {string} = {}
  for key in pairs(counts) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  print(plural.count(#judged, "program") .. " written to " .. TABLE .. ", " .. tostring(changed) .. " with another verdict")
  for _, key in ipairs(keys) do
    print("  " .. key .. ": " .. tostring(counts[key]))
  end
  return 0
end

return GateRecord
