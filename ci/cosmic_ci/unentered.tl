--- Joins the checked core's shares' C coverage, for the merge queue
--- (`driver.tl unentered-join DIR`).
---
--- Every C function of the core must be one some test enters, which only
--- a whole run settles (build/test.tl, build/c_functions.tl). The queue
--- runs the checked suite in shares, each a job of its own (ci.yml's
--- `checked`), so no share could tell; main's push, which runs it whole,
--- was the first to: on 2026-11-27 three push runs of main failed on
--- `core/text.c:cosmic_open_text: a C function no test enters` after the
--- queue passed #4482. Each share now writes the functions its tests did
--- not enter (COSMIC_TEST_UNENTERED): a first line `shard I/N`, then one
--- key a line. A function in every share's file is one no test of the
--- whole suite entered, and fails the join, as it fails a whole run.
---
--- DIR holds each share's file, one each of 1 to N; a missing or second
--- one fails the join, since it cannot tell then.
local Fs = require("cosmic.fs")
local Plural = require("cosmic_ci.plural")

local record Unentered
  --- One share's file, read.
  record Share
    index: integer
    count: integer
    keys: {string}
  end
end

--- The share `text` holds, or nil and why.
function Unentered.parse(text: string): Unentered.Share?, string
  local head, rest = text:match("^([^\n]*)\n?(.*)$")
  local index, count = (head or ""):match("^shard (%d+)/(%d+)$")
  if index == nil or count == nil then return nil, "its first line is not `shard I/N`" end
  local keys: mut {string} = {}
  for line in (rest or ""):gmatch("[^\n]+") do keys[#keys + 1] = line end
  return { index = math.tointeger(tonumber(index)) or 0, count = math.tointeger(tonumber(count)) or 0,
    keys = keys }, ""
end

--- The functions every one of `shares` left unentered, sorted, or nil and
--- why they cannot tell: not one each of shares 1 to N.
function Unentered.join(shares: {Unentered.Share}): {string}?, string
  local first = shares[1]
  if first == nil then return nil, "no share wrote its list" end
  local count = first.count
  local seen: mut {integer: boolean} = {}
  for _, share in ipairs(shares) do
    if share.count ~= count then
      return nil, string.format("shares of %d and of %d", count, share.count)
    end
    if share.index < 1 or share.index > count then
      return nil, string.format("a share %d of %d", share.index, count)
    end
    if seen[share.index] == true then
      return nil, string.format("share %d of %d twice", share.index, count)
    end
    seen[share.index] = true
  end
  local missing: mut {string} = {}
  for i = 1, count do
    if seen[i] == nil then missing[#missing + 1] = tostring(i) end
  end
  if #missing > 0 then
    return nil, string.format("no list from share %s of %d", table.concat(missing, ", "), count)
  end
  local times: mut {string: integer} = {}
  for _, share in ipairs(shares) do
    for _, key in ipairs(share.keys) do times[key] = (times[key] or 0) + 1 end
  end
  local out: mut {string} = {}
  for key, n in pairs(times) do
    if n == count then out[#out + 1] = key end
  end
  table.sort(out)
  return out, ""
end

local function say(text: string)
  local _, _ = Fs.put(Fs.stdout, text .. "\n")
end

local function complain(text: string)
  local _, _ = Fs.put(Fs.stderr, "unentered-join: " .. text .. "\n")
end

--- `driver.tl unentered-join DIR`: 0 where some share entered every
--- function, 1 where none entered one or the files cannot tell.
function Unentered.command(argv: {string}): integer
  local dir = argv[1]
  if dir == nil or argv[2] ~= nil then
    complain("usage: driver.tl unentered-join DIR")
    return 2
  end
  local names, unlisted = Fs.list(dir)
  if names == nil then
    complain(dir .. ": " .. tostring(unlisted))
    return 1
  end
  local shares: mut {Unentered.Share} = {}
  for _, name in ipairs(names) do
    local path = dir .. "/" .. name
    local text, unread = Fs.read(path)
    if text == nil then
      complain(path .. ": " .. tostring(unread))
      return 1
    end
    local share, wrong = Unentered.parse(text)
    if share == nil then
      complain(path .. ": " .. wrong)
      return 1
    end
    shares[#shares + 1] = share
  end
  local keys, why = Unentered.join(shares)
  if keys == nil then
    complain("cannot tell which C functions no test enters: " .. why)
    return 1
  end
  local count = assert(shares[1]).count
  if #keys == 0 then
    say("unentered-join: every C function is entered by a test of one of " .. Plural.count(count, "share"))
    return 0
  end
  for _, key in ipairs(keys) do
    say("test: FAIL  " .. key .. ": a C function no test enters (in none of the checked suite's " ..
        Plural.count(count, "share") .. ")")
  end
  return 1
end

return Unentered
