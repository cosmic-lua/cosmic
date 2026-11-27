--- Run-length coding, a planted bug for the agent evals: [`Rle.encode`] writes each run of one byte as its length and the
--- byte (`aaabcc` is `3a1b2c`), and [`Rle.decode`] reads that back. Decoding what encoding wrote answers the first text.
local record Rle
end

--- The run-length text of `text`: for each run of one byte, the decimal length of the run and the byte.
function Rle.encode(text: string): string
  local out: mut {string} = {}
  local run = 0
  local last = ""
  for i = 1, #text do
    local byte = text:sub(i, i)
    if byte == last then
      run = run + 1
    else
      if run > 0 then out[#out + 1] = tostring(run) .. last end
      last = byte
      run = 1
    end
  end
  return table.concat(out)
end

--- The text a run-length text stands for. A length is one or more digits, then the byte it repeats.
function Rle.decode(coded: string): string
  local out: mut {string} = {}
  local count = 0
  for i = 1, #coded do
    local ch = coded:sub(i, i)
    local digit = if ch:match("^%d$") ~= nil then math.tointeger(tonumber(ch)) else nil end
    if digit ~= nil then
      count = digit
    else
      out[#out + 1] = string.rep(ch, count)
      count = 0
    end
  end
  return table.concat(out)
end

return Rle
